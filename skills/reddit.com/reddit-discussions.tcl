#!/usr/bin/env tclsh
# reddit-discussions.tcl - return full Reddit discussions (post body + comment
# tree) for a search or a subreddit listing, fetched in a single browser session
# over CDP.
#
# A Reddit search hit is always a post (submission); its comments/<id>.json
# endpoint returns the post and its comment tree together, so one fetch per hit
# yields the whole discussion. This searches (or lists a subreddit), then fetches
# each result's discussion via in-page fetch() inside the authenticated
# old.reddit.com origin, so cookies and the configured locale apply.
#
# Usage (driven by the headless-browser wrapper's CDP mode):
#   not-google-chrome --cdp -- tclsh reddit-discussions.tcl \
#       --query "SEARCH TERMS" [--subreddit SUB] \
#       [--sort relevance|new|top|comments] [--time all|year|month|week|day] \
#       [--limit 5] [--comments 15]
#   not-google-chrome --cdp -- tclsh reddit-discussions.tcl \
#       --subreddit SUB [--sort hot|new|top] [--limit 5] [--comments 15]

source [file dirname [info script]]/../lib/cdp-client.tcl
source [file dirname [info script]]/reddit.tcl

package require json

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

# Run fetch() inside the page and return [list ok <dict>] or [list error <msg>].
# Mirrors the Python fetch_json: distinguishes a browser-side pre-origin failure
# from a real Reddit response, and a non-JSON body (block/login wall).
proc fetch_json {cdp url} {
    set expr "fetch([json::write string $url], {credentials: 'include', headers: {'Accept': 'application/json'}}).then(r => r.text()).catch(e => 'FETCHERR:' + e)"
    set resp [$cdp cdp Runtime.evaluate [dict create \
        expression $expr awaitPromise true returnByValue true]]
    set result [reddit::get $resp result]
    if {[dict exists $result exceptionDetails]} {
        set exc [dict get $result exceptionDetails]
        return [list error [reddit::get $exc text "JS exception"]]
    }
    # The fetch().then(r => r.text()) resolves to a string, surfaced as
    # result.result.value. Its absence means the JS produced no string value
    # (Python's "no value").
    if {![dict exists $result result value]} {
        return [list error "no value"]
    }
    set val [dict get $result result value]
    if {[string match "FETCHERR:*" $val]} {
        set loc_resp [$cdp cdp Runtime.evaluate [dict create \
            expression "document.location.href" returnByValue true]]
        set loc ""
        if {[dict exists $loc_resp result result value]} {
            set loc [dict get $loc_resp result result value]
        }
        if {$loc eq "" || [string match "about:*" $loc] || [string match "chrome-error://*" $loc]} {
            set shown [expr {$loc eq "" ? "<unknown>" : $loc}]
            return [list error "in-page fetch before origin established (browser-side, not a Reddit response; location=$shown): $val"]
        }
        return [list error "$val (page location=$loc)"]
    }
    if {[catch {json::json2dict $val} data]} {
        return [list error "non-JSON response (blocked or login wall): [string range $val 0 119]"]
    }
    return [list ok $data]
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

proc main {argv} {
    set query ""
    set subreddit ""
    set sort "relevance"
    set time "all"
    set limit 5
    set comments 15
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        switch -- $arg {
            --query     { incr i; set query [lindex $argv $i] }
            --subreddit { incr i; set subreddit [lindex $argv $i] }
            --sort      { incr i; set sort [lindex $argv $i] }
            --time      { incr i; set time [lindex $argv $i] }
            --limit     { incr i; set limit [lindex $argv $i] }
            --comments  { incr i; set comments [lindex $argv $i] }
            default {
                puts stderr "reddit-discussions.tcl: unknown argument: $arg"
                exit 2
            }
        }
    }
    if {$query eq "" && $subreddit eq ""} {
        puts stderr "give --query and/or --subreddit"
        exit 2
    }
    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "CDP_WS_URL not set (run via: not-google-chrome --cdp -- tclsh ...)"
        exit 78
    }

    set cdp [cdp::connect]
    try {
        $cdp cdp Page.enable
        $cdp cdp Page.navigate [dict create url "https://old.reddit.com/"]
        after 3000  ;# settle on origin so fetch() carries cookies and locale
        set settle [$cdp cdp Runtime.evaluate [dict create \
            expression "document.location.href + ' | ' + document.title" returnByValue true]]
        set settle_val "<no result>"
        if {[dict exists $settle result result value]} {
            set settle_val [dict get $settle result result value]
        }
        puts stderr "settle: $settle_val"

        set listing [fetch_json $cdp [build_listing_url $query $subreddit $sort $time $limit]]
        if {[lindex $listing 0] eq "error"} {
            puts stderr "listing fetch failed: [lindex $listing 1]"
            exit 1
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
            puts "No posts matched."
            return
        }

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
            set res [fetch_json $cdp $url]
            puts "\n===== DISCUSSION $i/$total ====="
            if {[lindex $res 0] eq "error"} {
                puts "(comments fetch failed for $permalink: [lindex $res 1])"
                puts "# [reddit::clean [reddit::get $p title]]"
                continue
            }
            reddit::cmd_thread [lindex $res 1] $comments
            after 1000  ;# pace requests
        }
    } finally {
        $cdp close
    }
}

main $argv
