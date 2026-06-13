#!/usr/bin/env tclsh
# reddit-saved.tcl - return a Reddit account's saved items (posts and comments),
# newest first, fetched in a single browser session over CDP.
#
# The saved listing is private: it resolves only for the logged-in account that
# owns it, so this reads it through the authenticated old.reddit.com origin (the
# user's Chromium cookies, carried by the --cdp wrapper). It follows Reddit's
# after cursor across pages internally and returns up to --limit items, so the
# caller asks for a count and never handles a cursor. A saved list interleaves
# posts (kind t3) and comments (kind t1); both are printed, labelled.
#
# Usage (driven by the headless-browser wrapper's CDP mode):
#   not-google-chrome --cdp -- tclsh reddit-saved.tcl --user NAME [--limit 25]

source [file dirname [info script]]/../lib/cdp-client.tcl
source [file dirname [info script]]/reddit.tcl

package require json

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

proc main {argv} {
    set user ""
    set limit 25
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        switch -- $arg {
            --user  { incr i; set user [lindex $argv $i] }
            --limit { incr i; set limit [lindex $argv $i] }
            default {
                puts stderr "reddit-saved.tcl: unknown argument: $arg"
                exit 2
            }
        }
    }
    if {$user eq ""} {
        puts stderr "reddit-saved.tcl: --user is required (the logged-in account whose saved list to read)"
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

        set collected {}
        set after ""
        while {[llength $collected] < $limit} {
            set url "https://old.reddit.com/user/$user/saved.json?limit=100&raw_json=1"
            if {$after ne ""} {
                append url "&after=$after&count=[llength $collected]"
            }
            set res [fetch_json $cdp $url]
            if {[lindex $res 0] eq "error"} {
                puts stderr "saved fetch failed: [lindex $res 1]"
                exit 1
            }
            set page [lindex $res 1]
            if {![dict exists $page data] || ![reddit::IsDict [dict get $page data]]} {
                # Reddit returns {"message":"Not Found","error":404} for a saved
                # list it will not show: not logged in, wrong account, or the
                # session is not this user's.
                set msg [reddit::get $page message $page]
                puts stderr "no saved listing for u/$user (login as that account, browser closed; Reddit said: $msg)"
                exit 1
            }
            set data [dict get $page data]
            set children {}
            if {[dict exists $data children]} {
                set children [dict get $data children]
            }
            if {[llength $children] == 0} {
                break
            }
            set collected [concat $collected $children]
            set after [reddit::get $data after]
            if {$after eq ""} {
                break  ;# last page
            }
            after 1000  ;# pace requests
        }

        set collected [lrange $collected 0 [expr {$limit-1}]]
        if {[llength $collected] == 0} {
            puts "u/$user has no saved items."
            return
        }
        puts "# [llength $collected] saved item(s) for u/$user (newest first)\n"
        reddit::print_saved $collected $limit
    } finally {
        $cdp close
    }
}

main $argv
