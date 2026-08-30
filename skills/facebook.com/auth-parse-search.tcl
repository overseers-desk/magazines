#!/usr/bin/env tclsh
# Parse Facebook people-search results to extract profile URLs and context.
#
# Serialiser path (see SKILL.md §1-2): browser-serialiser facebook.com/auth-parse-search [--pages] <search terms>
#   navigates to /search/people/?q=... (or /search/pages/), dumps the rendered DOM, and runs the identical parse.
# Direct path (legacy, file-fed): tclsh auth-parse-search.tcl <html-file>
#
# Facebook's DOM uses randomised class names, so we cannot select by class.
# Instead we:
#   1. Find all facebook.com profile URLs (both /username and /profile.php?id=)
#   2. For each URL, extract nearby visible text to identify the person
#   3. Output: URL, inferred name, and context (location, mutual friends, etc.)

source [file join [file dirname [info script]] lib fb-common.tcl]

# Paths that look like a vanity username but are Facebook chrome, not a person.
set ::NON_PROFILE_PATHS {
    search groups pages marketplace watch events
    gaming bookmarks saved friends messages notifications
    settings help privacy policies login recover
    signup photo.php photo hashtag stories reels
    ads business developers places offers fundraisers
    notes flx ajax api plugins sharer dialog
    share l.php checkpoint reg bluebar public
    directory pages_reaction_units ufi composer
}

# True when every char of $s, with "." removed, is alphanumeric (Python
# str.replace(".","").isalnum(): false on empty string).
proc isalnum_nodot {s} {
    set t [string map {. ""} $s]
    if {$t eq ""} { return 0 }
    return [regexp {^[[:alnum:]]+$} $t]
}

proc parse_search_results {html_path} {
    parse_search_results_html [fb::read_file $html_path]
}

proc parse_search_results_html {html} {
    set title [fb::title $html ""]
    if {[fb::title_is_login $title] || [string first "facebook – log in" [string tolower $title]] >= 0} {
        puts "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        exit 1
    }

    puts "Page title: [fb::name_from_title $title]"
    puts "HTML size: [fb::commafy [fb::cp_length $html]] bytes"
    puts ""

    # Only the result region is read. The signed-in chrome around it (left
    # navigation, chat list, notifications tray, "People you may know") is
    # made of profile links, and read whole the document yields the same two
    # hundred profiles whatever the query. Facebook answers an empty search
    # in that region with a notice, which is the result then; a region with
    # neither rows nor the notice is a read that did not happen.
    set main [fb::main_region $html]
    if {[string length $main] == [string length $html]} {
        puts "ERROR: unrecognised: no result region (role=main) in the search page"
        exit 1
    }
    if {[regexp {We didn.t find any results} $main]} {
        puts "No results: Facebook answers \"We didn't find any results\" for this query."
        return
    }
    if {![regexp {role="article"} $main]} {
        puts "ERROR: unrecognised: the result region carries neither result rows nor the no-results notice"
        exit 1
    }
    set html $main

    # One profile per result row: each role="article" row links its profile
    # (twice, picture and name). Anything read outside the rows, the script
    # payloads after them in particular, is not a result.
    set starts {}
    foreach pair [regexp -all -inline -indices {<[a-z]+[^>]*\srole="article"} $html] {
        lappend starts [lindex $pair 0]
    }
    set seen {}
    set profiles {}
    for {set i 0} {$i < [llength $starts]} {incr i} {
        set from [lindex $starts $i]
        set to [expr {$i + 1 < [llength $starts] ? [lindex $starts $i+1] - 1 : "end"}]
        set row [string range $html $from $to]
        if {[regexp {href="https?://(?:www\.)?facebook\.com/profile\.php\?id=(\d+)} $row -> nid]} {
            if {[dict exists $seen $nid]} continue
            dict set seen $nid 1
            lappend profiles [list numeric $nid $row]
        } elseif {[regexp {href="https?://(?:www\.)?facebook\.com/([a-zA-Z0-9._]+?)(?:\?|"|/)} $row -> username]} {
            set key [string trimright [string tolower $username] "."]
            if {$key in $::NON_PROFILE_PATHS || [dict exists $seen $key]} continue
            dict set seen $key 1
            lappend profiles [list vanity $username $row]
        }
    }

    if {![llength $profiles]} {
        puts "ERROR: unrecognised: result rows present but none carries a profile link"
        exit 1
    }

    puts "Found [llength $profiles] unique profiles:"
    puts ""

    set noise_re {_[0-9a-f]{8}|x[0-9a-z]{6,}|componentkey|tabindex|aria-|function\s|var |\.video|padding|margin:|display:|font-|overflow|opacity|cursor:|visibility|pointer-events|webpack|__MODULE|require\(|exports\.|React\.}

    foreach prof $profiles {
        lassign $prof ptype pid window
        if {$ptype eq "vanity"} {
            set url "https://www.facebook.com/$pid"
        } else {
            set url "https://www.facebook.com/profile.php?id=$pid"
        }

        # The row's visible text between tags (>text<), 3..300 chars.
        set clean_parts {}
        set frag_seen {}
        foreach {whole frag} [regexp -all -inline -- {>([^<]+)<} $window] {
            set L [string length $frag]
            if {$L < 3 || $L > 300} { continue }
            set frag [string trim $frag]
            set frag [fb::decode_entities $frag]
            if {$frag eq "" || [dict exists $frag_seen $frag]} { continue }
            if {[regexp -- $noise_re $frag]} { continue }
            if {[string length $frag] < 4} { continue }
            dict set frag_seen $frag 1
            lappend clean_parts $frag
        }

        if {[llength $clean_parts]} {
            set headline [join [lrange $clean_parts 0 5] " | "]
        } else {
            set headline "(no text extracted)"
        }
        if {[string length $headline] > 400} {
            set headline "[string range $headline 0 399]..."
        }

        puts "  $url"
        puts "    $headline"
        puts ""
    }
}

# Return the list of capture-group-1 values for every non-overlapping match of
# $pat in $text (regexp -all -inline interleaves whole match then captures).
proc capture_list {text pat} {
    set out {}
    foreach {whole cap} [regexp -all -inline -- $pat $text] {
        lappend out $cap
    }
    return $out
}

# Append every element of $more to the list in variable $varname.
proc lappend_all {varname more} {
    upvar 1 $varname v
    foreach e $more { lappend v $e }
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the people-search results, dump the rendered DOM, run
# the identical parse under fb::report, emit the report.
#
# Invoked by reference through the serialiser (see SKILL.md §1-2):
#     browser-serialiser facebook.com/auth-parse-search <search terms>
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    # --pages searches the Pages vertical; the default, people, lists no Page,
    # so a business looked for there reads as absent.
    set vertical people
    set words {}
    foreach a $skillArgs {
        if {$a eq "--pages"} { set vertical pages } else { lappend words $a }
    }
    set terms [join $words " "]
    if {$terms eq ""} {
        emit [envelope_fault "Usage: facebook.com/auth-parse-search \[--pages\] <search terms>"]
        return
    }
    set q [string map {" " %20} $terms]
    nav "https://www.facebook.com/search/$vertical/?q=$q" --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit [envelope_fault "login_wall: Facebook session expired. Log in via a Chrome-compatible browser first."]
        return
    }
    set html [dump]
    emit [fb::report out { parse_search_results_html $html }]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts "Usage: auth-parse-search.tcl <search-results.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_search_results [lindex $argv 0]
}
