#!/usr/bin/env tclsh
# collab-expand: walk Instagram handles, surface collab-partner candidates.
#
# For each input handle, scans recent posts (paginated via the feed API,
# no per-post page-open required) and accumulates handles found in four
# collab-signal fields:
#
#   - tagged_users   (the "tag people" feature on the post)
#   - coauthors      (the collab-post co-author feature)
#   - sponsors       (branded-content sponsor tags)
#   - mentions       (@-mentions in caption text; weaker signal)
#
# Outputs candidate handles NOT already in the input set, ranked by
# explicit collab signal first (tagged + coauthor + sponsor) and then
# by caption-mention count and number of distinct source handles.
#
# This script does single-level expansion; recursive "spider" expansion is the
# orchestrator's call (feed top-N candidates back as the next run's input).
#
# Invoked by reference through the serialiser (see SKILL.md §7):
#     browser-serialiser instagram.com/collab-expand expand handle1,handle2 [--posts-per-handle N]
#
# The serialiser path (serialiser_run) walks each handle over the policed verbs,
# reusing the library's sv_resolve_user_id / sv_fetch_feed; the ranking and
# rendering procs are shared with the legacy path, so output is byte-faithful.
# (--from <file> is a legacy-only convenience; file reads are a host capability
# the safe interp removes, so the serialiser form takes the CSV positional.)

source [file dirname [info script]]/fetch-recent-posts.tcl

# Signal field -> output column name.
set SIGNAL_FIELDS {tagged_users coauthors sponsors mentions}
array set SIGNAL_TO_COL {
    tagged_users tagged
    coauthors    coauthor
    sponsors     sponsor
    mentions     mention
}

# Accumulate one handle's parsed posts into the candidate dict (passed by name).
# Shared by the legacy and serialiser walkers so the signal-accumulation logic
# has a single home. $input_lower is the case-folded input set; $handle is the
# source handle whose posts these are.
proc accumulate_post_signals {candidatesVar input_lower handle posts} {
    global SIGNAL_FIELDS SIGNAL_TO_COL
    upvar 1 $candidatesVar candidates
    foreach post $posts {
        foreach field $SIGNAL_FIELDS {
            set col $SIGNAL_TO_COL($field)
            foreach cand [ig::dget $post $field {}] {
                set cand_lower [string tolower $cand]
                if {[dict exists $input_lower $cand_lower] || \
                    $cand_lower eq [string tolower $handle]} {
                    continue
                }
                if {![dict exists $candidates $cand_lower]} {
                    dict set candidates $cand_lower [dict create \
                        handle $cand_lower tagged 0 coauthor 0 sponsor 0 \
                        mention 0 total 0 sources {}]
                }
                set entry [dict get $candidates $cand_lower]
                dict incr entry $col
                dict incr entry total
                set srcs [dict get $entry sources]
                if {[lsearch -exact $srcs $handle] < 0} {
                    lappend srcs $handle
                    dict set entry sources $srcs
                }
                dict set candidates $cand_lower $entry
            }
        }
    }
}

# Sort and finalise the accumulated candidate dict into a ranked list.
proc finalise_candidates {candidates} {
    set out {}
    dict for {k entry} $candidates {
        dict set entry sources [lsort [dict get $entry sources]]
        lappend out $entry
    }
    # Rank: explicit-collab signals first, then mentions, then breadth of
    # sources, then handle (tie-break). Python sorts on a tuple of negatives;
    # mirror with a custom comparator.
    return [lsort -command rank_candidates $out]
}

# Walk input handles; return a list of ranked candidate dicts. Each candidate
# carries per-signal counts plus a sorted `sources` list of input handles whose
# posts surfaced it.
proc expand_handles {c handles posts_per_handle {pause_between_handles 2}} {
    set input_lower {}
    foreach h $handles { dict set input_lower [string tolower $h] 1 }
    set candidates [dict create]

    foreach handle $handles {
        puts stderr "\n=== $handle ==="
        set uid [ig::resolve_user_id $c $handle]
        if {[ig::dget $uid error ""] ne ""} {
            puts stderr "  skipped: [dict get $uid error]"
            continue
        }
        set user_id $uid

        after 2000
        set items [ig::fetch_user_feed_paginated $c $user_id $posts_per_handle]
        set posts [ig::parse_media_items $items]
        puts stderr "  fetched [llength $posts] posts"

        accumulate_post_signals candidates $input_lower $handle $posts
        after [expr {int($pause_between_handles * 1000)}]
    }
    return [finalise_candidates $candidates]
}

# Comparator implementing Python's sort key:
#   (-(coauthor+sponsor+tagged), -mention, -len(sources), handle)
proc rank_candidates {a b} {
    set ea [expr {[dict get $a coauthor] + [dict get $a sponsor] + [dict get $a tagged]}]
    set eb [expr {[dict get $b coauthor] + [dict get $b sponsor] + [dict get $b tagged]}]
    if {$ea != $eb} { return [expr {$eb - $ea}] }
    set ma [dict get $a mention]
    set mb [dict get $b mention]
    if {$ma != $mb} { return [expr {$mb - $ma}] }
    set sa [llength [dict get $a sources]]
    set sb [llength [dict get $b sources]]
    if {$sa != $sb} { return [expr {$sb - $sa}] }
    return [string compare [dict get $a handle] [dict get $b handle]]
}

# Render a candidate dict as a typed JSON node.
proc candidate_node {e} {
    return [ig::n_obj [list \
        handle [ig::n_str [dict get $e handle]] \
        tagged [ig::n_int [dict get $e tagged]] \
        coauthor [ig::n_int [dict get $e coauthor]] \
        sponsor [ig::n_int [dict get $e sponsor]] \
        mention [ig::n_int [dict get $e mention]] \
        total [ig::n_int [dict get $e total]] \
        sources [ig::n_strarr [dict get $e sources]]]]
}

# Render the full expand result (indent=2). Field order matches Python:
# input_handles, posts_per_handle, candidates, candidate_count.
proc render_expand {input_handles posts_per_handle candidates} {
    set candElems {}
    foreach e $candidates { lappend candElems [candidate_node $e] }
    return [ig::jenc [ig::n_obj [list \
        input_handles [ig::n_strarr $input_handles] \
        posts_per_handle [ig::n_int $posts_per_handle] \
        candidates [ig::n_arr $candElems] \
        candidate_count [ig::n_int [llength $candidates]]]]]
}

# ---------------------------------------------------------------------------
# Serialiser entry: walk each handle over the policed surface, reusing the
# library's sv_resolve_user_id / sv_fetch_feed, and the shared accumulate/rank
# helpers. nav to the IG home is the session check; each handle's profile nav is
# the covering view for that handle's feed api (inside sv_resolve_user_id).
# ---------------------------------------------------------------------------

proc sv_expand_handles {handles posts_per_handle} {
    set input_lower {}
    foreach h $handles { dict set input_lower [string tolower $h] 1 }
    set candidates [dict create]

    foreach handle $handles {
        puts stderr "\n=== $handle ==="
        set uid [ig::sv_resolve_user_id $handle]
        if {[ig::dget $uid error ""] ne ""} {
            puts stderr "  skipped: [dict get $uid error]"
            continue
        }
        set user_id $uid
        set items [ig::sv_fetch_feed $user_id $posts_per_handle]
        set posts [ig::parse_media_items $items]
        puts stderr "  fetched [llength $posts] posts"
        accumulate_post_signals candidates $input_lower $handle $posts
    }
    return [finalise_candidates $candidates]
}

# De-dupe a handle list preserving order, case-insensitively. Single home for
# the dedup shared by the legacy file/CSV path and the serialiser CSV path.
proc dedup_handles {handles} {
    set seen {}
    set deduped {}
    foreach h $handles {
        set lo [string tolower $h]
        if {![dict exists $seen $lo]} {
            dict set seen $lo 1
            lappend deduped $h
        }
    }
    return $deduped
}

# Parse a CSV handle string into a de-duped (case-insensitive, order-preserving)
# list with leading @ stripped.
proc parse_handles_csv {handles_csv} {
    set handles {}
    foreach h [split $handles_csv ","] {
        set h [string trim $h]
        if {$h ne ""} { lappend handles [string trimleft $h @] }
    }
    return [dedup_handles $handles]
}

proc serialiser_run {skillArgs} {
    if {![llength $skillArgs] || [lindex $skillArgs 0] ne "expand"} {
        emit [ig::render_flat [dict create error "Usage: instagram.com/collab-expand expand <handle1,handle2,...> \[--posts-per-handle N\]"]]
        return
    }
    set rest [lrange $skillArgs 1 end]
    set posts_per_handle 24
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --posts-per-handle { incr i; set posts_per_handle [lindex $rest $i] }
            default { lappend positional $a }
        }
    }
    set handles [parse_handles_csv [lindex $positional 0]]
    if {![llength $handles]} {
        emit [ig::render_flat [dict create error "No input handles. Pass as positional CSV (handle1,handle2,...)."]]
        return
    }

    nav "https://www.instagram.com/" --wait 3
    if {[dict get [state] terminal] ne ""} {
        emit [ig::render_flat [dict create error "Not logged in to Instagram ([dict get [state] terminal]). Log in via a Chrome-compatible browser first."]]
        return
    }

    set candidates [sv_expand_handles $handles $posts_per_handle]
    emit [render_expand $handles $posts_per_handle $candidates]
}

proc main {} {
    global argv
    if {![llength $argv] || [lindex $argv 0] ne "expand"} {
        puts "Usage: collab-expand.tcl expand <handle1,handle2,...> \[--posts-per-handle N\]"
        puts "       collab-expand.tcl expand --from <file> \[--posts-per-handle N\]"
        exit 1
    }
    set rest [lrange $argv 1 end]
    set handles_csv ""
    set from_file ""
    set posts_per_handle 24
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --from { incr i; set from_file [lindex $rest $i] }
            --posts-per-handle { incr i; set posts_per_handle [lindex $rest $i] }
            default { lappend positional $a }
        }
    }
    set handles_csv [lindex $positional 0]

    set handles {}
    if {$handles_csv ne ""} {
        foreach h [split $handles_csv ","] {
            set h [string trim $h]
            if {$h ne ""} { lappend handles [string trimleft $h @] }
        }
    }
    if {$from_file ne ""} {
        set f [open $from_file r]
        fconfigure $f -encoding utf-8
        foreach line [split [read $f] "\n"] {
            set line [string trim $line]
            if {$line eq "" || [string index $line 0] eq "#"} { continue }
            lappend handles [string trimleft $line @]
        }
        close $f
    }
    set handles [dedup_handles $handles]
    if {![llength $handles]} {
        puts [ig::render_flat [dict create error "No input handles. Pass as positional CSV or --from <file>."]]
        exit 1
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh collab-expand.tcl ..."
        exit 1
    }

    set c [cdp::connect]
    $c cdp Page.enable
    $c cdp Network.enable
    ig::navigate_and_wait $c "https://www.instagram.com/" 3

    if {![ig::check_logged_in $c]} {
        puts [ig::render_flat [dict create error "Not logged in to Instagram. Log in via Chromium first."]]
        exit 1
    }

    set candidates [expand_handles $c $handles $posts_per_handle]
    puts [render_expand $handles $posts_per_handle $candidates]
    $c close
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
