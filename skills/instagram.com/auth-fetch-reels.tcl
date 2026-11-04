#!/usr/bin/env tclsh
# A profile's reels with their play counts, read from the profile's Reels tab.
#
#     browser-serialiser instagram.com/auth-fetch-reels reels <handle> [--limit N] [--since YYYY-MM-DD]

source [file join [file dirname [info script]] lib fetch-recent-posts.tcl]

proc serialiser_run {skillArgs} {
    set usage "Usage: instagram.com/auth-fetch-reels reels <handle> \[--limit N\] \[--since YYYY-MM-DD\]"
    if {[lindex $skillArgs 0] ne "reels"} { emit [envelope_fault $usage]; return }
    set handle ""
    set limit ""
    set since 0
    set rest [lrange $skillArgs 1 end]
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $rest $i] }
            --since {
                incr i
                if {[catch {clock scan [lindex $rest $i] -format {%Y-%m-%d} -gmt 1} since]} {
                    emit [envelope_fault "--since takes YYYY-MM-DD, got \"[lindex $rest $i]\""]
                    return
                }
            }
            default { set handle [string trimleft $a @] }
        }
    }
    if {$handle eq ""} { emit [envelope_fault $usage]; return }
    # With --since alone the date bounds the read; the ceiling only stops a
    # runaway scroll. Without it, a dozen reels, the tab's first page.
    if {$limit eq ""} { set limit [expr {$since ? 500 : 12}] }

    nav "https://www.instagram.com/" --wait 3
    set st [state]
    if {[dict get $st terminal] ne ""} {
        emit [envelope_fault "login_wall: Not logged in to Instagram ([dict get $st terminal])."]
        return
    }
    set uid [ig::sv_resolve_user_id $handle]
    if {[ig::dget $uid error ""] ne ""} { emit [envelope_fault [dict get $uid error]]; return }

    try {
        set items [ig::sv_fetch_reels $handle $uid $limit $since more]
    } trap {IG REELS private} {msg} {
        emit [envelope_ok [dict create result [ig::jenc [ig::n_obj [list \
            handle [ig::n_str $handle] user_id [ig::n_str $uid] is_private [ig::n_bool 1] \
            reel_count [ig::n_int 0] note [ig::n_str $msg] reels [ig::n_arr {}]]]]]]
        return
    } trap {IG REELS missing} {msg} {
        emit [envelope_fault $msg]
        return
    }
    emit [envelope_ok [dict create hasMore $more result [ig::jenc [ig::n_obj [list \
        handle [ig::n_str $handle] user_id [ig::n_str $uid] \
        reel_count [ig::n_int [llength $items]] \
        reels [ig::n_arr [ig::reel_nodes $items]]]]]]]
}
