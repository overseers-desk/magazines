#!/usr/bin/env tclsh
# Search a LinkedIn profile HTML for specific keywords and show context.
#
# Serialiser path (see SKILL.md): browser-serialiser linkedin.com/keyword-search <slug> keyword1 keyword2 ...
#   navigates to /in/<slug>/, dumps the rendered DOM, and runs the identical
#   keyword scan over the in-memory HTML.
# Direct path (legacy, file-fed): tclsh keyword-search.tcl <html-file> keyword1 keyword2 ...
#
# For each keyword found, prints the count and surrounding text (with HTML tags
# stripped). Useful for quickly checking whether a profile mentions specific
# companies, roles, locations, or topics without reading the entire DOM.

# Code-point length matching Python's len() (Tcl 8.6 surrogate-pair aware).
proc cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}

# Insert thousands separators into a non-negative integer string (Python {:,}).
proc commafy {n} {
    set s $n
    set out ""
    while {[string length $s] > 3} {
        set out ",[string range $s end-2 end]$out"
        set s [string range $s 0 end-3]
    }
    return "$s$out"
}

# Quote a string for use as a literal inside a Tcl ARE (mirrors re.escape).
proc re_escape {s} {
    return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}]
}

# Code-point-aware substring: characters [first..last] inclusive, counting one
# unit per code point as Python slicing does (Tcl 8.6 stores non-BMP as a
# surrogate pair). Returns the substring as a code-point range of $s.
proc cp_range {s first last} {
    # Fast path: no non-BMP chars, units == code points.
    if {![regexp {[\uD800-\uDBFF]} $s]} {
        return [string range $s $first $last]
    }
    set out ""
    set cp 0
    set len [string length $s]
    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $s $i]
        # A high surrogate plus its following low surrogate are one code point.
        scan $ch %c code
        if {$code >= 0xD800 && $code <= 0xDBFF && $i+1 < $len} {
            set ch "$ch[string index $s [expr {$i+1}]]"
            incr i
        }
        if {$cp >= $first && $cp <= $last} { append out $ch }
        incr cp
        if {$cp > $last} break
    }
    return $out
}

# Remove the logged-in viewer's own profile data from the page.
# Tcl notes: the ARE word boundary is \y; and .*?</tag> is matched
# tempered-greedy so Tcl's leftmost-longest rule stops at the first close,
# reproducing Python's non-greedy .*?.
proc strip_viewer_content {html} {
    regsub -all {(?i)<nav\y[^>]*>(?:(?!</nav>)(?:.|\n))*</nav>} $html {} html
    regsub -all {(?i)<aside\y[^>]*>(?:(?!</aside>)(?:.|\n))*</aside>} $html {} html
    foreach marker {
        "People also viewed"
        "People you may know"
        "You might also know"
        "Explore collaborative articles"
        "Add profile section"
        "More profiles for you"
    } {
        set idx [string first $marker $html]
        if {$idx > 5000} {
            set html [string range $html 0 [expr {$idx-1}]]
            break
        }
    }
    return $html
}

# Render the keyword-search report from an HTML string and a keyword list,
# returning the report text (the same lines the legacy path printed).
proc render_keyword_search {html keywords} {
    set html [strip_viewer_content $html]

    set title "NOT FOUND"
    if {[regexp {(?s)<title[^>]*>(.*?)</title>} $html -> t]} {
        set title [string trim $t]
    }
    set out {}
    lappend out "Profile: $title"
    lappend out "HTML size: [commafy [cp_length $html]] bytes"
    lappend out ""

    set found_any 0
    foreach kw $keywords {
        set kwpat [re_escape $kw]
        # Case-insensitive, with -indices to get each match span.
        set matches {}
        set start 0
        while {[regexp -nocase -indices -start $start $kwpat $html m]} {
            lappend matches $m
            lassign $m a b
            set start [expr {$b+1}]
        }
        if {![llength $matches]} {
            lappend out "  $kw: NOT FOUND"
            continue
        }

        set found_any 1
        lappend out "  $kw: [llength $matches] occurrences"

        # Show up to 3 unique context snippets.
        set seen_contexts {}
        set shown 0
        foreach m $matches {
            if {$shown >= 3} break
            lassign $m mstart mend
            set s [expr {$mstart - 200}]
            if {$s < 0} { set s 0 }
            set e [expr {$mend + 300}]
            set maxe [expr {[string length $html] - 1}]
            if {$e > $maxe} { set e $maxe }
            set ctx [string range $html $s $e]
            # Strip tags, collapse whitespace.
            regsub -all {<[^>]+>} $ctx { } clean
            regsub -all {\s+} $clean { } clean
            set clean [string trim $clean]

            if {[string first "componentkey" $clean] >= 0 || [cp_length $clean] < 30} {
                continue
            }

            set sig [cp_range $clean 0 99]
            if {[dict exists $seen_contexts $sig]} { continue }
            dict set seen_contexts $sig 1

            lappend out "    ...[cp_range $clean 0 399]..."
            incr shown
        }

        lappend out ""
    }

    if {!$found_any} {
        lappend out "None of the keywords were found in this profile."
    }
    return [join $out "\n"]
}

# Direct path: read the file and print the report.
proc keyword_search {html_path keywords} {
    set f [open $html_path r]
    fconfigure $f -encoding utf-8
    set html [read $f]
    close $f
    puts [render_keyword_search $html $keywords]
}

# ---------------------------------------------------------------------------
# Serialiser entry: navigate to the profile, dump the rendered DOM, and run the
# identical keyword scan over the in-memory HTML (no file read; Plane 1 removes
# file access). Emits the same report text.
#
#     browser-serialiser linkedin.com/keyword-search <slug> keyword1 keyword2 ...
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    if {[llength $skillArgs] < 2} {
        emit "Usage: linkedin.com/keyword-search <slug> keyword1 \[keyword2 ...\]"
        return
    }
    set slug [string trim [lindex $skillArgs 0] /]
    set keywords [lrange $skillArgs 1 end]
    nav "https://www.linkedin.com/in/$slug/" --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: LinkedIn session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set html [dump]
    emit [render_keyword_search $html $keywords]
}

# Direct-tclsh entry: an HTML path plus keywords. Skipped when sourced as a skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 2} {
        puts "Usage: keyword-search.tcl <profile.html> keyword1 \[keyword2 ...\]"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    keyword_search [lindex $argv 0] [lrange $argv 1 end]
}
