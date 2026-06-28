#!/usr/bin/env tclsh
# Parse Facebook people-search results to extract profile URLs and context.
#
# Serialiser path (see SKILL.md §1-2): browser-serialiser facebook.com/parse-search <search terms>
#   navigates to /search/people/?q=..., dumps the rendered DOM, and runs the identical parse.
# Direct path (legacy, file-fed): tclsh parse-search.tcl <html-file>
#
# Facebook's DOM uses randomised class names, so we cannot select by class.
# Instead we:
#   1. Find all facebook.com profile URLs (both /username and /profile.php?id=)
#   2. For each URL, extract nearby visible text to identify the person
#   3. Output: URL, inferred name, and context (location, mutual friends, etc.)

source [file dirname [info script]]/fb-common.tcl

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

    puts "Page title: $title"
    puts "HTML size: [fb::commafy [fb::cp_length $html]] bytes"
    puts ""

    # Extract profile URLs — vanity (/username) and numeric (/profile.php?id=),
    # from href attributes and raw text, in the same order the Python appended.
    set vanity_matches [capture_list $html {href="https?://(?:www\.)?facebook\.com/([a-zA-Z0-9._]+?)(?:\?|"|/)}]
    set numeric_matches [capture_list $html {href="https?://(?:www\.)?facebook\.com/profile\.php\?id=(\d+)}]
    # Also non-href contexts (data attributes, JSON), appended after.
    lappend_all vanity_matches [capture_list $html {facebook\.com/([a-zA-Z0-9._]{5,})(?:[?"/&\s])}]
    lappend_all numeric_matches [capture_list $html {facebook\.com/profile\.php\?id=(\d+)}]
    # JSON-escaped form: facebook.com\/username (backslash before each slash).
    lappend_all vanity_matches [capture_list $html {facebook\.com\\/([a-zA-Z0-9._]{5,})(?:[?"\\/&\s])}]
    lappend_all numeric_matches [capture_list $html {facebook\.com\\/profile\.php\\?id=(\d+)}]

    set seen {}
    set profiles {}

    foreach username $vanity_matches {
        set username_lower [string trimright [string tolower $username] "."]
        if {$username_lower in $::NON_PROFILE_PATHS} { continue }
        if {[dict exists $seen $username_lower]} { continue }
        # Skip if it looks like a file or resource path.
        if {[string first "." $username_lower] >= 0 && ![isalnum_nodot $username_lower]} {
            continue
        }
        dict set seen $username_lower 1
        lappend profiles [list vanity $username]
    }

    foreach nid $numeric_matches {
        if {[dict exists $seen $nid]} { continue }
        dict set seen $nid 1
        lappend profiles [list numeric $nid]
    }

    if {![llength $profiles]} {
        puts "No profiles found in search results."
        puts "Possible causes: login required, empty results, or DOM structure changed."
        return
    }

    puts "Found [llength $profiles] unique profiles:"
    puts ""

    # NB the embedded empty alternative (display:||font-) is carried verbatim
    # from the Python source: it makes this alternation match every string, so
    # the headline is always "(no text extracted)". Reproduced for byte-identical
    # output with the predecessor (a forward-only port preserves behaviour, not
    # the latent intent).
    set noise_re {_[0-9a-f]{8}|x[0-9a-z]{6,}|componentkey|tabindex|aria-|function\s|var |\.video|padding|margin:|display:||font-|overflow|opacity|cursor:|visibility|pointer-events|webpack|__MODULE|require\(|exports\.|React\.}

    foreach prof $profiles {
        lassign $prof ptype pid
        if {$ptype eq "vanity"} {
            set url "https://www.facebook.com/$pid"
            set search_term "/$pid"
        } else {
            set url "https://www.facebook.com/profile.php?id=$pid"
            set search_term "id=$pid"
        }

        set idx [string first $search_term $html]
        if {$idx < 0} { continue }

        # Window of HTML around the profile link.
        set ws [expr {$idx - 2000}]
        if {$ws < 0} { set ws 0 }
        set we [expr {$idx + 3000}]
        set window [string range $html $ws $we]

        # Visible text between tags (>text<), 3..300 chars.
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
# the identical parse under fb::capture, emit the report.
#
# Invoked by reference through the serialiser (see SKILL.md §1-2):
#     browser-serialiser facebook.com/parse-search <search terms>
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set terms [join $skillArgs " "]
    if {$terms eq ""} {
        emit "Usage: facebook.com/parse-search <search terms>"
        return
    }
    set q [string map {" " %20} $terms]
    nav "https://www.facebook.com/search/people/?q=$q" --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set html [dump]
    emit [fb::capture out { parse_search_results_html $html }]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts "Usage: parse-search.tcl <search-results.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_search_results [lindex $argv 0]
}
