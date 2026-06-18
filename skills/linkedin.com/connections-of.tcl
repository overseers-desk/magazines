#!/usr/bin/env tclsh
# List the connections of a given person that are visible to the logged-in viewer.
#
# Serialiser path (see SKILL.md):
#   browser-serialiser linkedin.com/connections-of <profile-id-or-urn> [network]
#     navigates to the faceted people-search URL with the connectionOf facet set to
#     the target person, dumps the rendered DOM, and runs the identical parser used
#     by parse-search over the in-memory HTML.
#
# What LinkedIn actually exposes (the result set is gated, not arbitrary):
#   - network "F" (default): people in YOUR 1st-degree who are connected to the
#     target — i.e. your MUTUAL connections with them. Always available for any
#     target whose profile you can open.
#   - network "F,S": adds the target's 2nd-degree connections visible to you. Only
#     populated when the target is your 1st-degree AND has not hidden their
#     connection list; otherwise it degrades to the mutuals-only set.
#
# The connectionOf facet keys on the profile id — the "ACoAA..." token from a
# urn:li:fsd_profile:ACoAA... URN, which parse-profile emits as its `urn` field.
# Pass that id (or the full URN; the prefix is stripped) as the first argument.
#
# Direct path (legacy, file-fed): tclsh connections-of.tcl <html-file>
#   parses an already-saved search-results DOM, identical to parse-search.
#
# LinkedIn's DOM uses randomised class names, so the parser below is byte-identical
# to parse-search's render_search_results — the connection view is the same people
# list under a different query, so it shares the same extraction.

# Code-point length matching Python's len(): Tcl 8.6 stores a non-BMP char as a
# surrogate pair (2 units), so subtract the high-surrogate count.
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

# Remove the logged-in viewer's own profile data from the page.
proc strip_viewer_content {html} {
    regsub -all {(?i)<nav\y[^>]*>(?:(?!</nav>)(?:.|\n))*</nav>} $html {} html
    regsub -all {(?i)<aside\y[^>]*>(?:(?!</aside>)(?:.|\n))*</aside>} $html {} html
    return $html
}

# Render the search-results report from an HTML string. A login/expired page
# returns the single sentinel "@@LOGIN@@" so each caller maps it to its own
# terminal handling.
proc render_search_results {html} {
    set html [strip_viewer_content $html]

    set title ""
    if {[regexp {(?s)<title[^>]*>(.*?)</title>} $html -> t]} {
        set title [string trim $t]
    }
    set tl [string tolower $title]
    foreach marker {"sign in" "log in" "iniciar"} {
        if {[string first $marker $tl] >= 0} {
            return "@@LOGIN@@"
        }
    }

    set out {}
    lappend out "Page title: $title"
    lappend out "HTML size: [commafy [cp_length $html]] bytes"
    lappend out ""

    set slugs [regexp -all -inline {linkedin\.com/in/([a-zA-Z0-9_-]+)} $html]
    set seen {}
    set unique {}
    foreach {full s} $slugs {
        if {![dict exists $seen $s]} {
            dict set seen $s 1
            lappend unique $s
        }
    }

    if {![llength $unique]} {
        lappend out "No connections found in the result set."
        lappend out "Possible causes: login required, the target hides their connections,"
        lappend out "you share no mutual connections, or the DOM structure changed."
        return [join $out "\n"]
    }

    lappend out "Found [llength $unique] unique profiles:"
    lappend out ""

    foreach slug $unique {
        set idx [string first "/in/$slug" $html]
        if {$idx < 0} { continue }

        set wstart [expr {$idx - 2000}]
        if {$wstart < 0} { set wstart 0 }
        set wend [expr {$idx + 3000}]
        set window [string range $html $wstart $wend]

        set fragments [regexp -all -inline {>([^<]+)<} $window]

        set clean_parts {}
        set fseen {}
        foreach {full frag} $fragments {
            set flen [cp_length $frag]
            if {$flen < 3 || $flen > 300} { continue }
            set frag [string trim $frag]
            set frag [string map {&amp; & &lt; < &gt; >} $frag]
            if {$frag eq "" || [dict exists $fseen $frag]} { continue }
            if {[regexp {_[0-9a-f]{8}|componentkey|tabindex|aria-|data-display|function\s|var |\.video|padding|margin:|display:|font-|overflow|opacity|cursor:|visibility|pointer-events} $frag]} {
                continue
            }
            if {[cp_length $frag] < 5} { continue }
            if {[regexp {^[•·]\s*\d} $frag]} { continue }
            dict set fseen $frag 1
            lappend clean_parts $frag
        }

        if {[llength $clean_parts]} {
            set headline [join [lrange $clean_parts 0 4] " | "]
        } else {
            set headline "(no text extracted)"
        }

        if {[cp_length $headline] > 300} {
            set headline "[string range $headline 0 299]..."
        }

        lappend out "  https://www.linkedin.com/in/$slug/"
        lappend out "    $headline"
        lappend out ""
    }
    return [join $out "\n"]
}

# Direct path: read the file and print the report, exiting 1 on a login page.
proc parse_connections_results {html_path} {
    set f [open $html_path r]
    fconfigure $f -encoding utf-8
    set html [read $f]
    close $f

    set report [render_search_results $html]
    if {$report eq "@@LOGIN@@"} {
        puts "ERROR: LinkedIn session expired. Log in via a Chrome-compatible browser first."
        exit 1
    }
    puts $report
}

# Reduce a profile id or full URN to the bare ACoAA... facet id.
proc normalize_profile_id {raw} {
    set id [string trim $raw]
    # Strip a urn:li:fsd_profile: / urn:li:member: prefix if present.
    if {[regexp {([A-Za-z0-9_-]+)$} $id -> tail]} {
        set id $tail
    }
    return $id
}

# ---------------------------------------------------------------------------
# Serialiser entry: navigate to the connectionOf faceted people-search, dump the
# rendered DOM, and run the shared render over it.
#
#     browser-serialiser linkedin.com/connections-of <profile-id-or-urn> [network]
#   network defaults to "F" (mutuals); pass "FS" to also request 2nd-degree.
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set raw [lindex $skillArgs 0]
    if {$raw eq ""} {
        emit "Usage: linkedin.com/connections-of <profile-id-or-urn> \[network\]"
        emit "  profile-id is the ACoAA... token from parse-profile's `urn` field."
        emit "  network: F (default, mutual connections) or FS (also 2nd-degree)."
        return
    }
    set id [normalize_profile_id $raw]

    set net [string toupper [lindex $skillArgs 1]]
    if {$net eq "FS" || $net eq "F,S"} {
        set netparam "%5B%22F%22%2C%22S%22%5D"
    } else {
        set netparam "%5B%22F%22%5D"
    }

    set conn "%5B%22$id%22%5D"
    nav "https://www.linkedin.com/search/results/people/?connectionOf=$conn&network=$netparam&origin=FACETED_SEARCH" --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: LinkedIn session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set html [dump]
    set report [render_search_results $html]
    if {$report eq "@@LOGIN@@"} {
        emit "ERROR: LinkedIn session expired. Log in via a Chrome-compatible browser first."
        return
    }
    emit $report
}

# Direct-tclsh entry: one HTML path. Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts "Usage: connections-of.tcl <search-results.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_connections_results [lindex $argv 0]
}
