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


# The entry proc the harness calls. Parses the same `posts <handle> [--limit N]`
# arguments, drives the policed flow, and emits the rendered JSON (byte-identical
# to the legacy ig::main output for the same feed).
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
        emit [ig::render_flat [dict create error "Usage: instagram.com/auth-fetch-recent-posts posts <handle> \[--limit N\]"]]
        return
    }

    # Establish the session: view the IG home, then check for a wall.
    nav "https://www.instagram.com/" --wait 3
    set st [state]
    if {[dict get $st terminal] ne ""} {
        emit [ig::render_flat [dict create error "Not logged in to Instagram ([dict get $st terminal]). Log in via a Chrome-compatible browser first."]]
        return
    }

    set uid [ig::sv_resolve_user_id $handle]
    if {[ig::dget $uid error ""] ne ""} {
        emit [ig::render_flat $uid]
        return
    }
    set user_id $uid

    set items [ig::sv_fetch_feed $user_id $limit]
    if {![llength $items]} {
        emit [ig::render_posts_result [dict create handle $handle user_id $user_id \
            post_count 0 \
            note "Feed returned no items. Account may be private or feed empty." \
            posts {}]]
        return
    }
    set posts [ig::parse_media_items $items]
    set result [dict create handle $handle user_id $user_id \
        post_count [llength $posts] posts $posts]
    emit [ig::render_posts_result $result]
}

# ---------------------------------------------------------------------------
# Main entry (skipped when this file is sourced as a library).
# ---------------------------------------------------------------------------

proc ig::main {} {
    global argv
    set args $argv
    set command ""
    set handle ""
    set limit 12
    set raw_out ""

    if {[llength $args] && [lindex $args 0] eq "posts"} {
        set command posts
        set args [lrange $args 1 end]
        set positional {}
        for {set i 0} {$i < [llength $args]} {incr i} {
            set a [lindex $args $i]
            switch -- $a {
                --limit { incr i; set limit [lindex $args $i] }
                --raw-out { incr i; set raw_out [lindex $args $i] }
                default { lappend positional $a }
            }
        }
        set handle [lindex $positional 0]
    }

    if {$command eq ""} {
        puts "Usage: auth-fetch-recent-posts.tcl posts <handle> \[--limit N\] \[--raw-out PATH\]"
        exit 1
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser instagram.com/auth-fetch-recent-posts posts <handle> \[--limit N\]"
        exit 1
    }

    set c [cdp::connect]
    $c cdp Page.enable
    ig::navigate_and_wait $c "https://www.instagram.com/" 3

    if {![ig::check_logged_in $c]} {
        puts [ig::render_flat [dict create error "Not logged in to Instagram. Log in via a Chrome-compatible browser first."]]
        exit 1
    }

    after 3000

    if {$command eq "posts"} {
        set result [ig::cmd_posts $c $handle $limit $raw_out]
    } else {
        set result [dict create error "Unknown command: $command"]
    }

    if {[dict exists $result posts]} {
        puts [ig::render_posts_result $result]
    } else {
        puts [ig::render_flat $result]
    }
    $c close
}

# Run main only when executed directly, not when sourced.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    ig::main
}
