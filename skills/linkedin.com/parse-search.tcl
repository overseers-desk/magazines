#!/usr/bin/env tclsh
# Parse LinkedIn people search results HTML to extract profile URLs and headlines.
#
# Serialiser path (see SKILL.md): browser-serialiser linkedin.com/parse-search "<search terms>"
#   navigates to the people-search URL, dumps the rendered DOM, and runs the
#   identical parser over the in-memory HTML.
# Direct path (legacy, file-fed): tclsh parse-search.tcl <html-file>
#
# LinkedIn's DOM uses randomised class names, so we cannot select by class.
# Instead we:
#   1. Find all /in/ profile slugs in the HTML
#   2. For each slug, extract nearby visible text to identify the person's name/headline
#   3. Output: URL, inferred name, inferred headline

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
# Tcl notes: the ARE word boundary is \y (\b is a backspace here); and Tcl's
# leftmost-longest matching makes .*?</nav> span past the first </nav>, so the
# content is matched tempered-greedy ((?!</nav>).)* to stop at the first close,
# reproducing Python's non-greedy .*? exactly.
proc strip_viewer_content {html} {
    regsub -all {(?i)<nav\y[^>]*>(?:(?!</nav>)(?:.|\n))*</nav>} $html {} html
    regsub -all {(?i)<aside\y[^>]*>(?:(?!</aside>)(?:.|\n))*</aside>} $html {} html
    return $html
}

# Render the search-results report from an HTML string, returning the report
# text (the same lines the legacy path printed). A login/expired page returns the
# single sentinel "@@LOGIN@@" so each caller can map it to its own exit/terminal
# handling. The body is byte-identical to the predecessor's stdout.
proc render_search_results {html} {
    set html [strip_viewer_content $html]

    # Check if this is a login page.
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

    # Extract profile slugs (catches all /in/ references).
    set slugs [regexp -all -inline {linkedin\.com/in/([a-zA-Z0-9_-]+)} $html]
    set seen {}
    set unique {}
    # regexp -all -inline returns flat {fullmatch submatch fullmatch submatch ...}
    foreach {full s} $slugs {
        if {![dict exists $seen $s]} {
            dict set seen $s 1
            lappend unique $s
        }
    }

    if {![llength $unique]} {
        lappend out "No profiles found in search results."
        lappend out "Possible causes: login required, empty results, or DOM structure changed."
        return [join $out "\n"]
    }

    lappend out "Found [llength $unique] unique profiles:"
    lappend out ""

    foreach slug $unique {
        # Find the slug in HTML and extract nearby visible text.
        set idx [string first "/in/$slug" $html]
        if {$idx < 0} { continue }

        set wstart [expr {$idx - 2000}]
        if {$wstart < 0} { set wstart 0 }
        set wend [expr {$idx + 3000}]
        set window [string range $html $wstart $wend]

        # Visible text between tags. The Python regex >([^<]{3,300})< keeps runs
        # of 3-300 non-< chars; a run over 300 chars yields no fragment at all.
        # Tcl's ARE caps a bounded repetition at 255, so match any >run< and
        # filter by code-point length 3-300 instead (identical effect).
        set fragments [regexp -all -inline {>([^<]+)<} $window]

        set clean_parts {}
        set fseen {}
        foreach {full frag} $fragments {
            set flen [cp_length $frag]
            if {$flen < 3 || $flen > 300} { continue }
            set frag [string trim $frag]
            # Decode HTML entities.
            set frag [string map {&amp; & &lt; < &gt; >} $frag]
            if {$frag eq "" || [dict exists $fseen $frag]} { continue }
            if {[regexp {_[0-9a-f]{8}|componentkey|tabindex|aria-|data-display|function\s|var |\.video|padding|margin:|display:|font-|overflow|opacity|cursor:|visibility|pointer-events} $frag]} {
                continue
            }
            if {[cp_length $frag] < 5} { continue }
            # Skip connection degree indicators (e.g. "• 3er+", "• 2nd").
            if {[regexp {^[•·]\s*\d} $frag]} { continue }
            dict set fseen $frag 1
            lappend clean_parts $frag
        }

        if {[llength $clean_parts]} {
            set headline [join [lrange $clean_parts 0 4] " | "]
        } else {
            set headline "(no text extracted)"
        }

        # Truncate.
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
proc parse_search_results {html_path} {
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

# ---------------------------------------------------------------------------
# Serialiser entry: navigate to the people-search results, dump the rendered DOM,
# and run the identical render over the in-memory HTML (no file read; Plane 1
# removes file access). Emits the same report text.
#
#     browser-serialiser linkedin.com/parse-search "<search terms>"
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set terms [lindex $skillArgs 0]
    if {$terms eq ""} {
        emit "Usage: linkedin.com/parse-search \"<search terms>\""
        return
    }
    set enc [serialiser_urlencode $terms]
    nav "https://www.linkedin.com/search/results/people/?keywords=$enc&origin=GLOBAL_SEARCH_HEADER" --wait 5
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

# Percent-encode search terms (spaces and reserved chars) for the keywords param.
proc serialiser_urlencode {s} {
    set out ""
    foreach ch [split $s ""] {
        if {[regexp {[A-Za-z0-9._~-]} $ch]} {
            append out $ch
        } else {
            foreach byte [split [encoding convertto utf-8 $ch] ""] {
                scan $byte %c code
                append out [format %%%02X [expr {$code & 0xff}]]
            }
        }
    }
    return $out
}

# Direct-tclsh entry: one HTML path. Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts "Usage: parse-search.tcl <search-results.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_search_results [lindex $argv 0]
}
