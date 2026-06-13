#!/usr/bin/env tclsh
# Search a Facebook profile for specific keywords and show context.
#
# Serialiser path (see SKILL.md §8): browser-serialiser facebook.com/keyword-search <handle|profile-url> keyword1 keyword2 ...
#   navigates to the profile, dumps the rendered DOM, and runs the identical search.
# Direct path (legacy, file-fed): tclsh keyword-search.tcl <html-file> keyword1 keyword2 ...
#
# For each keyword found, prints the count and surrounding text (with HTML tags
# stripped). Useful for checking whether a profile mentions specific companies,
# roles, locations, or topics without reading the entire DOM.

source [file dirname [info script]]/fb-common.tcl

# Quote a string for use as a literal inside a Tcl regexp.
proc re_escape {s} {
    return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}]
}

# Tcl 8.6 stores a non-BMP char as a surrogate pair (2 string units), so byte
# offsets from regexp -indices and slices from string range count it as 2,
# whereas Python's str counts one code point. The context window and the
# [:100]/[:400] slices are defined in Python by code-point offsets, so to stay
# byte-identical we work in code-point space: cp_list turns a string into a
# list with exactly one element per Python code point (high surrogates folded
# into the following low surrogate), cp_index maps a unit offset to a code-point
# offset, and cp_slice/cp_substr index that list the way Python indexes str.
proc cp_list {s} {
    set out {}
    set n [string length $s]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $s $i]
        scan $ch %c code
        if {$code >= 0xD800 && $code <= 0xDBFF && $i + 1 < $n} {
            # High surrogate: pair it with the following low surrogate as one
            # code point (the original two-unit substring round-trips on join).
            append ch [string index $s [expr {$i+1}]]
            incr i
        }
        lappend out $ch
    }
    return $out
}

# Number of code points before Tcl-unit offset $unit in $s: the unit count
# minus the high surrogates in s[0:unit] (each non-BMP char is one fewer code
# point than units).
proc cp_offset {s unit} {
    set prefix [string range $s 0 [expr {$unit-1}]]
    set hi [regexp -all {[\uD800-\uDBFF]} $prefix]
    return [expr {$unit - $hi}]
}

# Python s[a:b] on a code-point list (b may exceed length; a<0 clamps to 0).
proc cp_slice {cps a b} {
    set n [llength $cps]
    if {$a < 0} { set a 0 }
    if {$b > $n} { set b $n }
    if {$a >= $b} { return "" }
    return [join [lrange $cps $a [expr {$b-1}]] ""]
}

proc keyword_search {html_path keywords} {
    keyword_search_html [fb::read_file $html_path] $keywords
}

proc keyword_search_html {html keywords} {
    # The whole document as a code-point list, so every offset and slice below
    # matches Python's str indexing regardless of emoji in the markup.
    set cps [cp_list $html]
    set ncp [llength $cps]

    set title [fb::title $html "NOT FOUND"]
    puts "Profile: $title"
    puts "HTML size: [fb::commafy $ncp] bytes"
    puts ""

    set found_any 0
    foreach kw $keywords {
        # Case-insensitive literal-keyword matches; -indices are Tcl-unit
        # offsets, converted to code-point offsets to index $cps.
        set kwre [re_escape $kw]
        set matches [regexp -all -inline -nocase -indices -- $kwre $html]
        if {![llength $matches]} {
            puts "  $kw: NOT FOUND"
            continue
        }

        set found_any 1
        puts "  $kw: [llength $matches] occurrences"

        # Show up to 3 unique context snippets.
        set seen_contexts {}
        set shown 0
        foreach m $matches {
            if {$shown >= 3} { break }
            lassign $m mstart mend
            # Convert unit offsets to code-point offsets. mend is the unit index
            # of the last matched unit; Python's m.end() is one past the match,
            # so map the unit just after the match.
            set cp_start [cp_offset $html $mstart]
            set cp_end [cp_offset $html [expr {$mend+1}]]
            # Window: 200 code points before m.start(), 300 after m.end().
            set start [expr {$cp_start - 200}]
            if {$start < 0} { set start 0 }
            set end [expr {$cp_end + 300}]
            if {$end > $ncp} { set end $ncp }
            set ctx [cp_slice $cps $start $end]
            # Strip tags, collapse whitespace.
            set clean [regsub -all {<[^>]+>} $ctx " "]
            set clean [string trim [regsub -all {\s+} $clean " "]]
            set clean_cps [cp_list $clean]

            # Skip framework noise.
            set is_noise 0
            foreach noise {__MODULE webpack require(} {
                if {[string first $noise $clean] >= 0} { set is_noise 1; break }
            }
            if {$is_noise} { continue }
            if {[llength $clean_cps] < 30} { continue }

            # Deduplicate similar contexts on the first 100 code points.
            set sig [cp_slice $clean_cps 0 100]
            if {[dict exists $seen_contexts $sig]} { continue }
            dict set seen_contexts $sig 1

            puts "    ...[cp_slice $clean_cps 0 400]..."
            incr shown
        }

        puts ""
    }

    if {!$found_any} {
        puts "None of the keywords were found in this profile."
    }
}

# Resolve a profile reference (handle, numeric id, or full URL) to a URL.
proc fb_profile_url {ref} {
    if {[string match "http*://*" $ref]} { return $ref }
    if {[regexp {^\d+$} $ref]} {
        return "https://www.facebook.com/profile.php?id=$ref"
    }
    return "https://www.facebook.com/[string trimleft $ref @/]"
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the profile, dump the rendered DOM, run the identical
# keyword search under fb::capture, emit the report. The first argument is the
# profile reference; the rest are the keywords.
#
# Invoked by reference through the serialiser (see SKILL.md §8):
#     browser-serialiser facebook.com/keyword-search <handle|profile-url> keyword1 [keyword2 ...]
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    if {[llength $skillArgs] < 2} {
        emit "Usage: facebook.com/keyword-search <handle|profile-url> keyword1 \[keyword2 ...\]"
        return
    }
    set target [lindex $skillArgs 0]
    set keywords [lrange $skillArgs 1 end]
    nav [fb_profile_url $target] --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set html [dump]
    emit [fb::capture out { keyword_search_html $html $keywords }]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 2} {
        puts "Usage: keyword-search.tcl <profile.html> keyword1 \[keyword2 ...\]"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    keyword_search [lindex $argv 0] [lrange $argv 1 end]
}
