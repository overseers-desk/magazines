#!/usr/bin/env tclsh
# Instagram recent posts fetcher.
#
# Given a public handle, returns the last N posts (default 12) with:
# caption, like count, comment count, posted timestamp (ISO 8601), post type
# (image/carousel/reel), is_paid_partnership flag, location tag, hashtags
# extracted from caption, and mentioned handles.
#
# Usage:
#     browser-serialiser instagram.com/auth-fetch-recent-posts posts <handle> [--limit N]

source [file join [file dirname [info script]] lib fetch-recent-posts.tcl]


# The entry proc the harness calls: parses `posts <handle> [--limit N]`, reads the
# profile grid, and emits the rendered JSON.
proc serialiser_run {skillArgs} {
    set command ""
    set handle ""
    set limit 12
    if {[llength $skillArgs] && [lindex $skillArgs 0] eq "posts"} {
        set command posts
        set rest [lrange $skillArgs 1 end]
        set positional {}
        for {set i 0} {$i < [llength $rest]} {incr i} {
            set a [lindex $rest $i]
            switch -- $a {
                --limit { incr i; set limit [lindex $rest $i] }
                default { lappend positional $a }
            }
        }
        set handle [lindex $positional 0]
    }
    if {$command eq "" || $handle eq ""} {
        emit [envelope_fault "Usage: instagram.com/auth-fetch-recent-posts posts <handle> \[--limit N\]"]
        return
    }

    # Establish the session: view the IG home, then check for a wall.
    nav "https://www.instagram.com/" --wait 3
    set st [state]
    if {[dict get $st terminal] ne ""} {
        emit [envelope_fault "login_wall: Not logged in to Instagram ([dict get $st terminal]). Log in via a Chrome-compatible browser first."]
        return
    }

    set uid [ig::sv_resolve_user_id $handle]
    if {[ig::dget $uid error ""] ne ""} {
        emit [envelope_fault [dict get $uid error]]
        return
    }
    set user_id $uid

    try {
        set items [ig::sv_fetch_feed $handle $limit more]
    } trap {IG FEED private} {msg} {
        emit [envelope_ok [dict create result [ig::render_posts_result \
            [dict create handle $handle user_id $user_id is_private true \
                post_count 0 note $msg posts {}]]]]
        return
    } trap {IG FEED missing} {msg} {
        emit [envelope_fault $msg]
        return
    }
    if {![llength $items]} {
        emit [envelope_ok [dict create result [ig::render_posts_result \
            [dict create handle $handle user_id $user_id post_count 0 \
                note "The account has no posts." posts {}]]]]
        return
    }
    set posts [ig::parse_media_items $items]
    set stop [expr {[llength $posts] >= $limit ? "limit" : ($more ? "stalled" : "end")}]
    set result [dict create handle $handle user_id $user_id \
        post_count [llength $posts] stop_reason $stop posts $posts]
    emit [envelope_ok [dict create hasMore $more result [ig::render_posts_result $result]]]
}
