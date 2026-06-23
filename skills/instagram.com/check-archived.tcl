#!/usr/bin/env tclsh
# check-archived: decide whether one or more Instagram posts are ARCHIVED.
#
# An archived Instagram post is removed from the owner's public profile grid
# (the feed/user listing) yet stays reachable at its permalink by the logged-in
# owner, who sees it only in the Archive section. So neither signal alone is
# enough: the permalink DOM of an archived post renders just like a live one,
# and the grid simply omits it (indistinguishable from a deleted or
# never-existed post). The discriminator is the cross-check:
#
#     archived  ==  permalink still renders the post   (owner-visible media)
#                   AND its shortcode is absent from the grid feed.
#
# A post present in the grid is live (archived=false). A shortcode whose
# permalink no longer renders the post (an "unavailable"/removed page) is not
# archived but removed/deleted (permalink_exists=false), reported distinctly.
#
# Efficiency: the grid is fetched ONCE per run and reused for every shortcode,
# so checking N posts costs one feed pagination plus N permalink navigations.
#
# Usage (policed serialiser path; see SKILL.md):
#     browser-serialiser instagram.com/check-archived <handle> <shortcode>[,<shortcode>...] [--grid-limit N]
#
# The shortcode list is comma-separated; a full permalink
# (https://www.instagram.com/reel/<code>/ or /p/<code>/) is also accepted and
# reduced to its shortcode.
#
# Authoritative absence requires the grid to be EXHAUSTED, because the
# "absent from grid + permalink renders = archived" inference only holds when
# absence means "not in the listing", not "beyond how far we paged". So the grid
# is paged to exhaustion by default (--grid-limit is a high safety ceiling, not
# the normal stop). The output carries grid_complete: when true (paging hit
# more_available=false), an absent-yet-rendering post is reported archived=true;
# when false (an account so large the ceiling was reached first), such a post is
# reported archived=null (inconclusive) rather than risk a false positive, and
# the caller may raise --grid-limit. grid_count and grid_oldest_iso are reported
# for context.
#
# This file sources fetch-recent-posts.tcl for the ig:: library: handle->user_id
# resolution (ig::sv_resolve_user_id), grid paging (ig::sv_fetch_feed), media
# parsing (ig::parse_media_items), and the typed-JSON emitters (ig::jenc /
# ig::n_*). No detection logic is duplicated from the keystone.

source [file dirname [info script]]/fetch-recent-posts.tcl

# ---------------------------------------------------------------------------
# Shortcode normalisation.
# ---------------------------------------------------------------------------

# Reduce a permalink or bare shortcode to the bare shortcode. Accepts
# /reel/<code>/, /p/<code>/, /tv/<code>/ with or without scheme/host/query, or a
# bare code. Returns "" when no shortcode-shaped token is found.
proc ca_shortcode_of {ref} {
    set ref [string trim $ref]
    if {[regexp {/(?:reel|p|tv)/([A-Za-z0-9_-]+)} $ref -> code]} { return $code }
    if {[regexp {^[A-Za-z0-9_-]+$} $ref]} { return $ref }
    return ""
}

# Split a comma-separated list of refs into a deduped list of bare shortcodes,
# preserving caller order. Blank and unparseable entries are dropped.
proc ca_parse_shortcodes {arg} {
    set out {}
    set seen {}
    foreach ref [split $arg ,] {
        set code [ca_shortcode_of $ref]
        if {$code ne "" && ![dict exists $seen $code]} {
            dict set seen $code 1
            lappend out $code
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Grid set.
# ---------------------------------------------------------------------------

# Build the grid lookup from parsed grid posts: a dict shortcode -> taken_at_iso,
# plus the oldest taken_at_iso seen. Returns {set <dict> oldest <iso>}.
proc ca_grid_index {posts} {
    set idx [dict create]
    set oldest ""
    foreach p $posts {
        set code [ig::dget $p shortcode ""]
        set iso [ig::dget $p taken_at_iso ""]
        if {$code ne ""} { dict set idx $code $iso }
        if {$iso ne "" && ($oldest eq "" || [string compare $iso $oldest] < 0)} {
            set oldest $iso
        }
    }
    return [dict create set $idx oldest $oldest]
}

# ---------------------------------------------------------------------------
# Permalink existence (the DOM signal calibrated against live + archived posts).
# ---------------------------------------------------------------------------

# An existing post (live OR archived) renders its own shortcode in the DOM and
# carries none of the "unavailable"/removed phrases. A removed/deleted post
# shows the unavailable page (no media, the phrase present). Returns 1 / 0; on a
# DOM that could not be read returns "" (inconclusive).
proc ca_permalink_exists {html shortcode} {
    if {$html eq ""} { return "" }
    foreach phrase {"page isn't available" "may have been removed" "Sorry, this page"} {
        if {[string first $phrase $html] >= 0} { return 0 }
    }
    if {[string first $shortcode $html] >= 0} { return 1 }
    # Shortcode absent and no unavailable phrase: an empty/slow render. Treat as
    # inconclusive rather than asserting either way.
    return ""
}

# ---------------------------------------------------------------------------
# Per-shortcode verdict.
# ---------------------------------------------------------------------------

# Decide one shortcode's archived status from the grid index and the permalink's
# rendered DOM. gridIdx is the dict from ca_grid_index's `set`; gridOldest is its
# oldest ISO; html is the permalink DOM ("" if unfetched). Returns a result dict
# carrying archived (1/0/"" for inconclusive), permalink_exists, in_grid, and a
# human reason.
proc ca_verdict {shortcode gridIdx gridOldest html} {
    set inGrid [dict exists $gridIdx $shortcode]
    set exists [ca_permalink_exists $html $shortcode]

    if {$inGrid} {
        # Present in the grid: live by definition, whatever the permalink shows.
        return [dict create shortcode $shortcode archived 0 \
            permalink_exists $exists in_grid 1 \
            grid_taken_at_iso [dict get $gridIdx $shortcode] \
            reason "present in profile grid (live)"]
    }
    if {$exists eq ""} {
        return [dict create shortcode $shortcode archived "" \
            permalink_exists "" in_grid 0 grid_taken_at_iso "" \
            reason "permalink DOM inconclusive (empty/slow render); re-run to confirm"]
    }
    if {$exists == 0} {
        return [dict create shortcode $shortcode archived 0 \
            permalink_exists 0 in_grid 0 grid_taken_at_iso "" \
            reason "permalink unavailable (post removed/deleted, not archived)"]
    }
    # Permalink renders but absent from grid: the archived signature, UNLESS the
    # post predates the fetched grid depth, in which case "absent" is just beyond
    # reach and the verdict is inconclusive. We cannot read the permalink's own
    # taken_at from the DOM cheaply, so we gate on grid reach: if the grid hit no
    # more_available (its oldest is the true oldest) the absence is authoritative.
    return [dict create shortcode $shortcode archived 1 \
        permalink_exists 1 in_grid 0 grid_taken_at_iso "" \
        reason "permalink renders for owner but shortcode absent from grid (archived)"]
}

# ---------------------------------------------------------------------------
# Rendering: one row per shortcode plus the grid-reach context.
# ---------------------------------------------------------------------------

proc ca_n_tri {v} {
    # tri-state: 1 -> true, 0 -> false, "" -> null.
    if {$v eq ""} { return [ig::n_null] }
    return [ig::n_bool $v]
}

proc ca_render {handle gridCount gridOldest gridComplete rows} {
    set rowElems {}
    foreach r $rows {
        lappend rowElems [ig::n_obj [list \
            shortcode [ig::n_str [dict get $r shortcode]] \
            url [ig::n_str "https://www.instagram.com/reel/[dict get $r shortcode]/"] \
            archived [ca_n_tri [dict get $r archived]] \
            permalink_exists [ca_n_tri [dict get $r permalink_exists]] \
            in_grid [ig::n_bool [dict get $r in_grid]] \
            grid_taken_at_iso [expr {[dict get $r grid_taken_at_iso] eq "" \
                ? [ig::n_null] : [ig::n_str [dict get $r grid_taken_at_iso]]}] \
            reason [ig::n_str [dict get $r reason]]]]
    }
    return [ig::jenc [ig::n_obj [list \
        handle [ig::n_str $handle] \
        grid_count [ig::n_int $gridCount] \
        grid_oldest_iso [expr {$gridOldest eq "" ? [ig::n_null] : [ig::n_str $gridOldest]}] \
        grid_complete [ig::n_bool $gridComplete] \
        posts [ig::n_arr $rowElems]]]]
}

# ---------------------------------------------------------------------------
# Serialiser entry: resolve the handle, fetch the grid once, then nav each
# permalink and dump its DOM. View-before-fetch is satisfied: sv_resolve_user_id
# navs the profile (covering the feed api), and each permalink nav covers its own
# dump.
# ---------------------------------------------------------------------------

proc serialiser_run {skillArgs} {
    set positional {}
    set grid_limit 5000
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --grid-limit { incr i; set grid_limit [lindex $skillArgs $i] }
            default { lappend positional $a }
        }
    }
    set handle [lindex $positional 0]
    set codes [ca_parse_shortcodes [lindex $positional 1]]
    if {$handle eq "" || ![llength $codes]} {
        emit [ig::render_flat [dict create error "Usage: instagram.com/check-archived <handle> <shortcode>\[,<shortcode>...\] \[--grid-limit N\]"]]
        return
    }

    nav "https://www.instagram.com/" --wait 3
    if {[dict get [state] terminal] ne ""} {
        emit [ig::render_flat [dict create error "Not logged in to Instagram ([dict get [state] terminal]). Log in via a Chrome-compatible browser first."]]
        return
    }

    set uid [ig::sv_resolve_user_id $handle]
    if {[ig::dget $uid error ""] ne ""} {
        emit [ig::render_flat $uid]
        return
    }
    set gridItems [ig::sv_fetch_feed $uid $grid_limit]
    set gridPosts [ig::parse_media_items $gridItems]
    set gi [ca_grid_index $gridPosts]
    set gridIdx [dict get $gi set]
    set gridOldest [dict get $gi oldest]
    # The grid is complete (its absence is authoritative for ANY age) only when
    # paging stopped on exhaustion, not on the limit cap.
    set gridComplete [expr {[llength $gridItems] < $grid_limit}]

    set rows {}
    foreach code $codes {
        nav "https://www.instagram.com/reel/$code/" --wait 5
        if {[dict get [state] terminal] ne ""} {
            # A wall mid-run: record what we have and stop walking permalinks.
            lappend rows [dict create shortcode $code archived "" \
                permalink_exists "" in_grid [dict exists $gridIdx $code] \
                grid_taken_at_iso "" reason "hit a wall ([dict get [state] terminal]); not checked"]
            break
        }
        if {[catch {dump} html]} { set html "" }
        set v [ca_verdict $code $gridIdx $gridOldest $html]
        # Downgrade a true verdict to inconclusive when the grid did not reach
        # the post's era: an absent shortcode could be beyond the fetched depth.
        if {[dict get $v archived] == 1 && !$gridComplete} {
            dict set v archived ""
            dict set v reason "permalink renders but absent from a grid capped at $grid_limit (oldest $gridOldest); raise --grid-limit to confirm archived"
        }
        lappend rows $v
    }

    emit [ca_render $handle [llength $gridPosts] $gridOldest $gridComplete $rows]
}

# ---------------------------------------------------------------------------
# Direct-tclsh entry (parity with the serialiser path; uses the legacy CDP
# engine the sourced keystone provides via ig::). Kept so the script runs under
# `tclsh check-archived.tcl ...` for development, mirroring its siblings.
# ---------------------------------------------------------------------------

proc main {} {
    global argv
    set positional {}
    set grid_limit 5000
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        switch -- $a {
            --grid-limit { incr i; set grid_limit [lindex $argv $i] }
            default { lappend positional $a }
        }
    }
    set handle [lindex $positional 0]
    set codes [ca_parse_shortcodes [lindex $positional 1]]
    if {$handle eq "" || ![llength $codes]} {
        puts "Usage: check-archived.tcl <handle> <shortcode>\[,<shortcode>...\] \[--grid-limit N\]"
        exit 1
    }
    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser instagram.com/check-archived ..."
        exit 1
    }

    set c [cdp::connect]
    $c cdp Page.enable
    ig::navigate_and_wait $c "https://www.instagram.com/" 3
    if {![ig::check_logged_in $c]} {
        puts [ig::render_flat [dict create error "Not logged in to Instagram. Log in via Chromium first."]]
        exit 1
    }

    set uid [ig::resolve_user_id $c $handle]
    if {[ig::dget $uid error ""] ne ""} {
        puts [ig::render_flat $uid]
        $c close
        exit 1
    }
    after 2000
    set gridItems [ig::fetch_user_feed_paginated $c $uid $grid_limit]
    set gridPosts [ig::parse_media_items $gridItems]
    set gi [ca_grid_index $gridPosts]
    set gridIdx [dict get $gi set]
    set gridOldest [dict get $gi oldest]
    set gridComplete [expr {[llength $gridItems] < $grid_limit}]

    set rows {}
    foreach code $codes {
        ig::navigate_and_wait $c "https://www.instagram.com/reel/$code/" 5
        set html [ig::scalar [ig::eval_js $c "document.documentElement.outerHTML"]]
        set v [ca_verdict $code $gridIdx $gridOldest $html]
        if {[dict get $v archived] == 1 && !$gridComplete} {
            dict set v archived ""
            dict set v reason "permalink renders but absent from a grid capped at $grid_limit (oldest $gridOldest); raise --grid-limit to confirm archived"
        }
        lappend rows $v
    }
    puts [ca_render $handle [llength $gridPosts] $gridOldest $gridComplete $rows]
    $c close
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
