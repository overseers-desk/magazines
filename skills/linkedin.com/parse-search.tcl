#!/usr/bin/env tclsh
# People search: a keyword, LinkedIn's filters, and several people's networks in
# one call.
# Home: skills/linkedin.com/parse-search.tcl
#
# Serialiser path (see SKILL.md):
#   browser-serialiser linkedin.com/parse-search "<search terms>"
#   browser-serialiser linkedin.com/parse-search '{"keywords":"loan","connectionOf":["ACoAA..."]}'
#
# Direct path (offline parser test against a saved page):
#   tclsh9.0 parse-search.tcl <search-results.html>
#
# Filter keys are LinkedIn's own, taken from the people-search filter-bar request
# the site embeds in the page (example-cul-quota-wall.html carries one). A key
# outside that vocabulary is refused by name rather than folded into the URL: a
# key LinkedIn does not recognise is dropped in silence and the search returns a
# plausible result set for a filter that never applied. That is not
# hypothetical - titleFreeText was recommended here for months and returned
# identical results for six different job titles (BUGS.md). The working key is
# `title`.
#
# Cost: LinkedIn meters people search per account per calendar month, does not
# report what remains, and degrades rather than errors when the meter runs out.
# So a run reports what it spent, and reads one page unless asked for more.

source [file join [file dirname [info script]] li-canonical.tcl]

# LinkedIn's people-search vocabulary. Keys not in `LI_SEARCH_TEXT` take the
# filter encoding, a percent-encoded JSON array, whether the caller passes one
# value or several.
set ::LI_SEARCH_TEXT {keywords origin firstName lastName title company schoolFreetext}
set ::LI_SEARCH_FILTERS {
    network geoUrn schoolFilter connectionOf followerOf currentCompany pastCompany
    industry serviceCategory profileLanguage eventAttending activelyHiringForJobTitles
    companyHQBingGeo companySizeV2 seniorityV2 openToVolunteer functionV2
}
set ::LI_SEARCH_BASE "https://www.linkedin.com/search/results/people/"

# LinkedIn stops a free account at 100 pages, and answers page 101 with page one
# rather than an error, so a caller reading past the ceiling re-reads the start.
set ::LI_SEARCH_PAGE_CEILING 100

# A full page of people search. A page returning fewer is the last one, which is
# the only end-of-results signal available: the page states no total.
set ::LI_SEARCH_PAGE_SIZE 10

# value(s) -> the query fragment for one key.
proc search_param {key values} {
    if {[lsearch -exact $::LI_SEARCH_TEXT $key] >= 0} {
        return "$key=[url_qcomp $values]"
    }
    set parts {}
    foreach v $values { lappend parts [url_qcomp $v] }
    return "$key=%5B%22[join $parts {%22%2C%22}]%22%5D"
}

# A filter dict -> one people-search URL. `origin` follows the query's shape the
# way the site's own links do: the faceted origin when a filter is set, the
# header origin for a bare keyword.
proc search_url {filters page} {
    set pairs {}
    set faceted 0
    dict for {k v} $filters {
        if {$k eq "origin"} { continue }
        if {[lsearch -exact $::LI_SEARCH_FILTERS $k] >= 0} { set faceted 1 }
        lappend pairs [search_param $k $v]
    }
    if {[dict exists $filters origin]} {
        lappend pairs "origin=[url_qcomp [dict get $filters origin]]"
    } else {
        lappend pairs [expr {$faceted ? "origin=FACETED_SEARCH" : "origin=GLOBAL_SEARCH_HEADER"}]
    }
    if {$page > 1} { lappend pairs "page=$page" }
    return "$::LI_SEARCH_BASE?[join $pairs &]"
}

# Read the caller's argument: a JSON object, or a bare string meaning a keyword
# search. Returns {filters <dict> page <n> maxPages <n>}.
proc search_args {raw} {
    set raw [string trim $raw]
    if {$raw eq ""} { error "no search given: pass search terms, or a JSON object of filters" }
    if {[string index $raw 0] ne "\{"} {
        return [dict create filters [dict create keywords $raw] page 1 maxPages 1]
    }
    if {[catch {::json::json2dict $raw} a]} { error "arguments are not JSON: $a" }

    set filters [dict create]
    set page 1
    set maxPages 1
    dict for {k v} $a {
        switch -- $k {
            page     { set page $v }
            maxPages { set maxPages $v }
            default {
                if {[lsearch -exact $::LI_SEARCH_TEXT $k] < 0
                 && [lsearch -exact $::LI_SEARCH_FILTERS $k] < 0} {
                    set hint ""
                    if {$k eq "titleFreeText"} { set hint "; the role filter is `title`" }
                    error "'$k' is not a LinkedIn people-search key (SKILL.md lists them)$hint"
                }
                if {$v ne ""} { dict set filters $k $v }
            }
        }
    }
    if {![dict size $filters]} { error "no search given: the filter set is empty" }
    foreach {name n} [list page $page maxPages $maxPages] {
        if {![string is integer -strict $n] || $n < 1} { error "$name must be a positive integer" }
    }
    if {$page + $maxPages - 1 > $::LI_SEARCH_PAGE_CEILING} {
        error "page $page plus maxPages $maxPages passes LinkedIn's ceiling of\
            $::LI_SEARCH_PAGE_CEILING pages, past which it serves page one again"
    }
    return [dict create filters $filters page $page maxPages $maxPages]
}

# Reduce a profile id or full URN to the bare ACoAA... id the connectionOf
# filter keys on. A vanity slug is refused rather than passed through: LinkedIn
# takes the id alone, and answers a slug with an empty result set rather than an
# error, so the caller would read "nobody matched" for a filter that never
# named anyone.
proc profile_id_of {raw} {
    set id [string trim $raw " \t\n/"]
    regexp {([A-Za-z0-9_-]+)$} $id -> id
    if {![string match {ACoAA*} $id]} {
        error "connectionOf takes a profile id, not '$id': pass the ACoAA... id\
            (parse-profile emits it as `urn`, and a search result carries it as\
            `profile_id`)"
    }
    return $id
}

# Read one query, following pages up to `maxPages`. Returns
# {state <s> total <n> pages <n> exhausted <0|1> rows <list of card dicts>}.
# Stops early on a page that yields nothing new, which is how the end of the
# result set and the 100-page ceiling both present; `exhausted` records that it
# stopped for that reason rather than on the caller's page limit, which is the
# only signal LinkedIn gives that a result set continues (the page states no
# total).
proc read_query {filters firstPage maxPages} {
    set rows {}
    set seen [dict create]
    set state ok
    set total ""
    set pages 0
    set exhausted 0
    for {set i 0} {$i < $maxPages} {incr i} {
        set page [expr {$firstPage + $i}]
        nav [search_url $filters $page] --wait 5
        incr pages
        if {[dict get [state] terminal] ne ""} {
            error "login_wall: LinkedIn walled the session ([dict get [state] terminal])"
        }
        set parsed [parse_people_search [dump]]
        if {[dict get $parsed state] eq "login"} {
            error "login_wall: LinkedIn served a sign-in page"
        }
        if {[dict get $parsed state] ne "ok"} { set state [dict get $parsed state] }
        if {$total eq ""} { set total [dict get $parsed total] }
        set fresh 0
        foreach r [dict get $parsed results] {
            set slug [dict get $r slug]
            if {[dict exists $seen $slug]} { continue }
            dict set seen $slug 1
            lappend rows $r
            incr fresh
        }
        # A short page ends the result set; a page repeating what came before
        # is the 100-page ceiling serving page one again. Either way there is
        # nothing further to ask for.
        if {[llength [dict get $parsed results]] < $::LI_SEARCH_PAGE_SIZE} {
            set exhausted 1
            break
        }
        if {!$fresh} { set exhausted 1; break }
    }
    return [dict create state $state total $total pages $pages \
        exhausted $exhausted rows $rows]
}

# The search proper. Several people in the connectionOf filter are read one
# query each and merged here, because LinkedIn reads only the FIRST id in that
# filter and discards the rest. Measured 2026-08-14: two first-degree members
# with disjoint mutual sets (4 and 5 people) returned, when named together,
# exactly the first one's 4 - not the union of 9, and not the empty
# intersection. So one query per person is the only way to reach several
# networks, and the merge below is what makes them one result set.
proc run_search {a} {
    set filters [dict get $a filters]

    set targets {}
    if {[dict exists $filters connectionOf]} {
        foreach t [dict get $filters connectionOf] { lappend targets [profile_id_of $t] }
        dict set filters connectionOf $targets
    }

    set queries {}
    if {[llength $targets] > 1} {
        foreach t $targets {
            lappend queries [list $t [dict replace $filters connectionOf [list $t]]]
        }
    } else {
        lappend queries [list $targets $filters]
    }

    set merged [dict create]
    set order {}
    set state ok
    set total ""
    set pages 0
    set more 0
    foreach q $queries {
        lassign $q via qfilters
        set got [read_query $qfilters [dict get $a page] [dict get $a maxPages]]
        incr pages [dict get $got pages]
        if {![dict get $got exhausted]} { set more 1 }
        if {[dict get $got state] ne "ok"} { set state [dict get $got state] }
        if {$total eq "" || [llength $queries] > 1} { set total [dict get $got total] }
        foreach r [dict get $got rows] {
            set slug [dict get $r slug]
            if {![dict exists $merged $slug]} {
                dict set merged $slug [dict set r via {}]
                lappend order $slug
            }
            set rec [dict get $merged $slug]
            dict set rec via [lsort -unique [concat [dict get $rec via] $via]]
            dict set merged $slug $rec
        }
    }
    # A merge across several queries has no single stated total to report.
    if {[llength $queries] > 1} { set total "" }

    set rows {}
    foreach slug $order {
        set r [dict get $merged $slug]
        set shared {}
        foreach m [dict get $r mutuals] {
            lappend shared [json::write object \
                slug [j_str [lindex $m 0]] name [j_str [lindex $m 1]] \
                profile_url [j_str "https://www.linkedin.com/in/[lindex $m 0]/"]]
        }
        set via {}
        foreach v [dict get $r via] { lappend via [j_str $v] }
        lappend rows [json::write object \
            slug               [j_str $slug] \
            profile_id         [j_strornull [dict get $r profile_id]] \
            profile_url        [j_str "https://www.linkedin.com/in/$slug/"] \
            name               [j_strornull [dict get $r name]] \
            headline           [j_strornull [dict get $r headline]] \
            location           [j_strornull [dict get $r location]] \
            degree             [j_intornull [dict get $r degree]] \
            shared_connections [json::write array {*}$shared] \
            via                [json::write array {*}$via]]
    }

    set echo {}
    dict for {k v} [dict get $a filters] {
        if {[lsearch -exact $::LI_SEARCH_TEXT $k] >= 0} {
            lappend echo $k [j_str $v]
        } else {
            set vs {}; foreach x $v { lappend vs [j_str $x] }
            lappend echo $k [json::write array {*}$vs]
        }
    }

    set result [json::write object \
        query   [json::write object {*}$echo] \
        state   [j_str $state] \
        total   [j_intornull $total] \
        cost    [json::write object queries [llength $queries] pages $pages] \
        count   [llength $rows] \
        results [json::write array {*}$rows]]

    # More to read when a query stopped on the caller's page limit rather than
    # on a page that brought nothing new, or when a stated total outruns what
    # came back. The cursor is the page to resume at, which is what a caller
    # needs to spend one more search rather than repeat the ones already paid
    # for.
    set hasMore $more
    if {$total ne "" && [llength $rows] < $total} { set hasMore 1 }
    set cursor ""
    if {$hasMore} { set cursor [expr {[dict get $a page] + [dict get $a maxPages]}] }
    return [dict create result $result cursor $cursor hasMore $hasMore]
}

proc serialiser_run {skillArgs} {
    if {[catch {run_search [search_args [lindex $skillArgs 0]]} r]} {
        emit [envelope_fault $r]
        return
    }
    emit [envelope_ok $r]
}

# Direct-tclsh entry: parse a saved page, the offline half of the verb.
# Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts stderr "Usage: parse-search.tcl <search-results.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    set f [open [lindex $argv 0] r]; fconfigure $f -encoding utf-8
    set html [read $f]; close $f
    set p [parse_people_search $html]
    puts "state: [dict get $p state]"
    puts "total: [dict get $p total]"
    puts "cards: [llength [dict get $p results]]"
    foreach r [dict get $p results] {
        puts ""
        puts "  https://www.linkedin.com/in/[dict get $r slug]/"
        puts "    [dict get $r name] - [dict get $r headline]"
        puts "    [dict get $r location]"
        foreach m [dict get $r mutuals] { puts "    shared: [lindex $m 1]" }
    }
}
