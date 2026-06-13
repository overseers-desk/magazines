#!/usr/bin/env tclsh
# reddit-saved.tcl - return a Reddit account's saved items (posts and comments),
# newest first, fetched in a single browser session over the policed serialiser
# surface.
#
# The saved listing is private: it resolves only for the logged-in account that
# owns it, so this reads it through the authenticated old.reddit.com origin (the
# user's Chromium cookies, carried by the serialiser's session). It follows
# Reddit's after cursor across pages internally and returns up to --limit items,
# so the caller asks for a count and never handles a cursor. A saved list
# interleaves posts (kind t3) and comments (kind t1); both are printed, labelled.
#
# Invoked by reference through browser-serialiser:
#   browser-serialiser reddit.com/reddit-saved --user NAME [--limit 25]

source [file dirname [info script]]/reddit.tcl

# The harness entry proc. Parses the same arguments as the legacy CLI, drives the
# policed flow (nav to establish the origin, then `api` per page following the
# after cursor), renders with the shared print_saved captured into the emit.
proc serialiser_run {skillArgs} {
    set user ""
    set limit 25
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set arg [lindex $skillArgs $i]
        switch -- $arg {
            --user  { incr i; set user [lindex $skillArgs $i] }
            --limit { incr i; set limit [lindex $skillArgs $i] }
            default {
                emit "reddit-saved.tcl: unknown argument: $arg"
                return
            }
        }
    }
    if {$user eq ""} {
        emit "reddit-saved.tcl: --user is required (the logged-in account whose saved list to read)"
        return
    }

    # Settle on the origin so the `api` replay carries the account's cookies.
    nav "https://old.reddit.com/" --wait 3
    if {[dict get [state] terminal] ne ""} {
        emit "reddit: not reachable ([dict get [state] terminal]); log in as u/$user via a Chrome-compatible browser first."
        return
    }

    set collected {}
    set after ""
    while {[llength $collected] < $limit} {
        set url "https://old.reddit.com/user/$user/saved.json?limit=100&raw_json=1"
        if {$after ne ""} {
            append url "&after=$after&count=[llength $collected]"
        }
        set res [reddit::sv_fetch_json $url]
        if {[lindex $res 0] eq "error"} {
            emit "saved fetch failed: [lindex $res 1]"
            return
        }
        set page [lindex $res 1]
        if {![dict exists $page data] || ![reddit::IsDict [dict get $page data]]} {
            # Reddit returns {"message":"Not Found","error":404} for a saved
            # list it will not show: not logged in, wrong account, or the
            # session is not this user's.
            set msg [reddit::get $page message $page]
            emit "no saved listing for u/$user (login as that account, browser closed; Reddit said: $msg)"
            return
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
        dwell 1  ;# pace requests
    }

    set collected [lrange $collected 0 [expr {$limit-1}]]
    if {[llength $collected] == 0} {
        emit "u/$user has no saved items."
        return
    }
    reddit::sv_capture rendered {
        puts "# [llength $collected] saved item(s) for u/$user (newest first)\n"
        reddit::print_saved $collected $limit
    }
    emit $rendered
}
