#!/usr/bin/env tclsh
# reddit-discussions.tcl - return full Reddit discussions (post body + comment
# tree) for a search or a subreddit listing, fetched in a single browser session
# over the policed serialiser surface.
#
# A Reddit search hit is always a post (submission); its comments/<id>.json
# endpoint returns the post and its comment tree together, so one fetch per hit
# yields the whole discussion. This searches (or lists a subreddit), then fetches
# each result's discussion via the `api` verb inside the authenticated
# old.reddit.com origin (same-origin replay, so cookies and the configured locale
# apply), and emits the rendered discussions.
#
# Invoked by reference through browser-serialiser:
#   browser-serialiser reddit.com/reddit-discussions \
#       --query "SEARCH TERMS" [--subreddit SUB] \
#       [--sort relevance|new|top|comments] [--time all|year|month|week|day] \
#       [--limit 5] [--comments 15]
#   browser-serialiser reddit.com/reddit-discussions \
#       --subreddit SUB [--sort hot|new|top] [--limit 5] [--comments 15]

source [file dirname [info script]]/reddit.tcl

# Percent-encode a query string for a URL (RFC 3986 unreserved kept literal).
proc quote_plus {s} {
    set out ""
    foreach ch [split $s ""] {
        if {[string match {[A-Za-z0-9._~-]} $ch]} {
            append out $ch
        } elseif {$ch eq " "} {
            append out "+"
        } else {
            foreach byte [split [encoding convertto utf-8 $ch] ""] {
                append out [format %%%02X [scan $byte %c]]
            }
        }
    }
    return $out
}

proc build_listing_url {query subreddit sort time limit} {
    if {$query ne ""} {
        set q [quote_plus $query]
        if {$subreddit ne ""} {
            return "https://old.reddit.com/r/$subreddit/search.json?q=$q&restrict_sr=on&sort=$sort&t=$time&limit=$limit"
        }
        return "https://old.reddit.com/search.json?q=$q&sort=$sort&t=$time&limit=$limit"
    }
    # No query: subreddit listing.
    if {$sort ni {hot new top rising}} {
        set sort "hot"
    }
    return "https://old.reddit.com/r/$subreddit/$sort.json?limit=$limit&t=$time"
}

# The harness entry proc. Parses the same arguments as the legacy CLI, drives the
# policed flow (nav to establish the origin, then `api` per fetch), renders with
# the shared printers captured into the emitted string.
proc serialiser_run {skillArgs} {
    set query ""
    set subreddit ""
    set sort "relevance"
    set time "all"
    set limit 5
    set comments 15
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set arg [lindex $skillArgs $i]
        switch -- $arg {
            --query     { incr i; set query [lindex $skillArgs $i] }
            --subreddit { incr i; set subreddit [lindex $skillArgs $i] }
            --sort      { incr i; set sort [lindex $skillArgs $i] }
            --time      { incr i; set time [lindex $skillArgs $i] }
            --limit     { incr i; set limit [lindex $skillArgs $i] }
            --comments  { incr i; set comments [lindex $skillArgs $i] }
            default {
                emit "reddit-discussions.tcl: unknown argument: $arg"
                return
            }
        }
    }
    if {$query eq "" && $subreddit eq ""} {
        emit "give --query and/or --subreddit"
        return
    }

    # Settle on the origin so the `api` replay carries cookies and locale.
    nav "https://old.reddit.com/" --wait 3
    if {[dict get [state] terminal] ne ""} {
        emit "reddit: not reachable ([dict get [state] terminal]); log in via a Chrome-compatible browser first."
        return
    }

    set listing [reddit::sv_fetch_json [build_listing_url $query $subreddit $sort $time $limit]]
    if {[lindex $listing 0] eq "error"} {
        emit "listing fetch failed: [lindex $listing 1]"
        return
    }
    set listing_data [lindex $listing 1]
    set children {}
    if {[dict exists $listing_data data children]} {
        set children [dict get $listing_data data children]
    }
    set posts {}
    foreach c $children {
        if {[reddit::get $c kind] eq "t3"} {
            lappend posts [dict get $c data]
        }
    }
    set posts [lrange $posts 0 [expr {$limit-1}]]
    if {[llength $posts] == 0} {
        emit "No posts matched."
        return
    }

    reddit::sv_capture rendered {
        set head "# [llength $posts] discussion(s) for "
        if {$query ne ""} { append head "q='$query'" }
        if {$subreddit ne ""} { append head " in r/$subreddit" }
        puts "$head\n"
        set total [llength $posts]
        set i 0
        foreach p $posts {
            incr i
            set permalink [reddit::get $p permalink]
            set url "https://old.reddit.com$permalink.json?limit=$comments&sort=top"
            set res [reddit::sv_fetch_json $url]
            puts "\n===== DISCUSSION $i/$total ====="
            if {[lindex $res 0] eq "error"} {
                puts "(comments fetch failed for $permalink: [lindex $res 1])"
                puts "# [reddit::clean [reddit::get $p title]]"
                continue
            }
            reddit::cmd_thread [lindex $res 1] $comments
            dwell 1  ;# pace requests
        }
    }
    emit $rendered
}
