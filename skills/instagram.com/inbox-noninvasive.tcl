#!/usr/bin/env tclsh
# Instagram DM inbox metadata reader — NONINVASIVE.
#
# This script reads inbox thread metadata only: who sent the last message,
# when, a short snippet, and whether the thread is marked unread. It MUST NOT
# mark any thread as read. It MUST NOT open individual threads or fetch message
# content.
#
# If you need message content from a specific thread, that is a separate,
# invasive operation — write a different script with a different name.
#
# Any future code change that adds thread-opening, message fetching,
# or any is_seen=true/seen-mutation call must be a separate script,
# not an addition here. The "noninvasive" word in this filename is load-bearing.
#
# Seen-mutation requests are intercepted at the CDP Fetch domain (armed before
# the first navigation) for the patterns below: a matching request is paused and
# never released, so it cannot leave the browser. The inbox-metadata endpoint
# this script calls does not match those patterns and is itself read-only.
#
# Invoked by reference through the serialiser (see SKILL.md §5):
#     browser-serialiser instagram.com/inbox-noninvasive list
#
# The serialiser path (serialiser_run) declares the seen-mutation guard via the
# `veto` verb (the harness refuses any matching request before it leaves the
# browser), then reads the inbox-metadata endpoint via the policed `api` verb.
# Parsing/rendering reuse the identical procs, so output is byte-faithful.

source [file dirname [info script]]/fetch-recent-posts.tcl

# Patterns that identify seen-mutation requests. These must NEVER leave the browser.
set SEEN_BLOCK_PATTERNS {
    */seen/*
    */mark_seen*
    *item_seen*
    *direct_thread*
}

# Arm CDP Fetch interception for the seen-mutation URL patterns. A matching
# request is paused at the Request stage and never continued, so it never
# leaves the browser. (Non-matching traffic, including the inbox-metadata fetch,
# is not intercepted.)
proc enable_fetch_blocking {c} {
    global SEEN_BLOCK_PATTERNS
    set patterns {}
    foreach p $SEEN_BLOCK_PATTERNS {
        lappend patterns [dict create urlPattern $p requestStage Request]
    }
    $c cdp Fetch.enable [dict create patterns $patterns]
}

proc micros_to_iso {ts_micros} {
    if {[catch {expr {int(double($ts_micros) / 1000000)}} secs]} {
        return $ts_micros
    }
    if {[catch {clock format $secs -format {%Y-%m-%dT%H:%M:%S+00:00} -gmt 1} out]} {
        return $ts_micros
    }
    return $out
}

# Parse the direct_v2/inbox API response into a list of thread summaries.
# Read-state: unseen when marked_as_unread OR the viewer's last_seen_at
# timestamp is earlier than last_activity_at (both microseconds since epoch).
proc parse_inbox_response {data} {
    set inbox [ig::dget $data inbox $data]
    set threads [ig::dget $inbox threads {}]
    set viewer [ig::dget $data viewer {}]
    set viewer_id [viewer_id_of $viewer]
    set results {}
    foreach t $threads {
        set users [ig::dget $t users {}]
        if {[llength $users]} {
            set u0 [lindex $users 0]
            set username [ig::dget $u0 username ""]
            set full_name [ig::dget $u0 full_name ""]
            set user_id [pk_of $u0]
        } else {
            set username [ig::dget $t thread_title ""]
            set full_name ""
            set user_id ""
        }
        set user_ids {}
        foreach u $users { lappend user_ids [pk_of $u] }

        set last_activity_ts [ig::dget $t last_activity_at 0]
        set last_activity_iso [micros_to_iso $last_activity_ts]

        set snippet ""
        set lpi [ig::dget $t last_permanent_item {}]
        if {[llength $lpi]} {
            set item_type [ig::dget $lpi item_type ""]
            switch -- $item_type {
                text { set snippet [string range [ig::dget $lpi text ""] 0 119] }
                like { set snippet "\[like\]" }
                media_share { set snippet "\[shared post\]" }
                reel_share {
                    set rs [ig::dget $lpi reel_share {}]
                    set rtext [string range [ig::dget $rs text ""] 0 79]
                    set snippet "\[reel: $rtext\]"
                }
                "" { set snippet "" }
                default { set snippet "\[$item_type\]" }
            }
        }

        set marked [ig::truthy [ig::dget $t marked_as_unread false]]
        set unseen_by_timestamp 0
        set last_seen_at [ig::dget $t last_seen_at {}]
        if {$viewer_id ne "" && [dict_has $last_seen_at $viewer_id]} {
            set seen_ts_str [ig::dget [dict get $last_seen_at $viewer_id] timestamp 0]
            if {![catch {expr {[scan_int $last_activity_ts] > [scan_int $seen_ts_str]}} cmp]} {
                set unseen_by_timestamp $cmp
            }
        }
        set unseen [expr {$marked || $unseen_by_timestamp}]

        lappend results [dict create \
            username $username \
            full_name $full_name \
            user_id $user_id \
            user_ids $user_ids \
            thread_id [ig::dget $t thread_id ""] \
            thread_v2_id [ig::dget_null $t thread_v2_id] \
            last_activity_iso $last_activity_iso \
            last_snippet $snippet \
            unseen $unseen \
            is_group [ig::truthy [ig::dget $t is_group false]]]
    }
    return $results
}

proc viewer_id_of {viewer} {
    set v [ig::dget $viewer pk ""]
    if {$v eq ""} { set v [ig::dget $viewer id ""] }
    return $v
}
proc pk_of {u} {
    set v [ig::dget $u pk ""]
    if {$v eq ""} { set v [ig::dget $u id ""] }
    return $v
}
proc dict_has {d key} {
    if {[catch {dict exists $d $key} ok]} { return 0 }
    return $ok
}
proc scan_int {v} {
    if {[string is integer -strict $v]} { return $v }
    if {[regexp {^-?\d+} $v m]} { return $m }
    return 0
}

set INBOX_PAGE_SIZE 20

# Fetch one page of /api/v1/direct_v2/inbox/ metadata (does not change read
# state). cursor pages to older threads; omit for the first page.
proc fetch_inbox_page {c {cursor ""} {limit 20}} {
    if {$cursor ne ""} {
        set set_cursor "params.set('cursor', [ig::jstr $cursor]);"
    } else {
        set set_cursor ""
    }
    set js {
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const params = new URLSearchParams({
            visual_message_return_type: 'unseen',
            thread_message_limit: '1',
            persistentBadging: 'true',
            limit: '@LIMIT@',
        });
        @SETCURSOR@
        const resp = await fetch('/api/v1/direct_v2/inbox/?' + params.toString(), {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        const status = resp.status;
        if (!resp.ok) return JSON.stringify({error: 'HTTP ' + status, status: status});
        return JSON.stringify({status: status, data: await resp.json()});
    })()
    }
    set js [string map [list @LIMIT@ $limit @SETCURSOR@ $set_cursor] $js]
    return [ig::eval_js $c $js]
}

# Enumerate the whole DM inbox (metadata only) by paging the inbox cursor.
proc cmd_list {c {max_threads 2000} {pace 5.0} {start_cursor ""}} {
    set all_threads {}
    set seen_ids {}
    set viewer_id ""
    set cursor $start_cursor
    set pages 0
    set has_older "\x00null"
    set oldest_cursor "\x00null"
    while {1} {
        set result [fetch_inbox_page $c $cursor]
        if {[ig::dget $result error ""] ne ""} {
            if {[llength $all_threads]} { break }
            return $result
        }
        set status [ig::dget $result status ""]
        if {$status in {401 403}} {
            return [dict create error "Instagram returned HTTP $status. Session may be expired or rate-limited."]
        }
        set data [ig::dget $result data {}]
        set inbox [ig::dget $data inbox $data]
        if {$viewer_id eq ""} {
            set viewer_id [viewer_id_of [ig::dget $data viewer {}]]
        }
        incr pages
        set before [llength $all_threads]
        foreach t [parse_inbox_response $data] {
            set tid [dict get $t thread_id]
            if {$tid ne "" && [dict exists $seen_ids $tid]} { continue }
            if {$tid ne ""} { dict set seen_ids $tid 1 }
            lappend all_threads $t
        }
        set has_older [ig::dget_null $inbox has_older]
        set oldest_cursor [ig::dget_null $inbox oldest_cursor]
        if {[llength $all_threads] == $before} { break }
        if {[llength $all_threads] >= $max_threads || \
            $has_older eq "\x00null" || $has_older eq "false" || \
            $oldest_cursor eq "\x00null" || $oldest_cursor eq ""} { break }
        set cursor $oldest_cursor
        after [expr {int($pace * 1000)}]
    }
    set complete [expr {$has_older eq "false"}]
    return [dict create \
        viewer_id $viewer_id \
        threads $all_threads \
        thread_count [llength $all_threads] \
        pages_fetched $pages \
        has_older_final $has_older \
        oldest_cursor_final $oldest_cursor \
        complete $complete]
}

# Run list twice with a 45-second sleep; check no unseen thread flipped to seen.
proc cmd_verify_noninvasive {c} {
    puts stderr "verify-noninvasive: first fetch..."
    set first [cmd_list $c]
    if {[ig::dget $first error ""] ne ""} { return $first }

    puts stderr "verify-noninvasive: sleeping 45 seconds..."
    after 45000

    puts stderr "verify-noninvasive: second fetch..."
    set second [cmd_list $c]
    if {[ig::dget $second error ""] ne ""} { return $second }

    set first_map [dict create]
    foreach t [dict get $first threads] { dict set first_map [dict get $t thread_id] $t }
    set second_map [dict create]
    foreach t [dict get $second threads] { dict set second_map [dict get $t thread_id] $t }

    set flipped {}
    dict for {tid t1} $first_map {
        if {[dict exists $second_map $tid]} {
            set t2 [dict get $second_map $tid]
            if {[dict get $t1 unseen] && ![dict get $t2 unseen]} {
                lappend flipped [dict create \
                    thread_id $tid \
                    username [dict get $t1 username] \
                    was_unseen true \
                    now_unseen false]
            }
        }
    }

    if {[llength $flipped]} {
        return [dict create \
            result FAIL \
            message "At least one thread changed from unseen to seen between runs." \
            flipped_threads $flipped]
    }
    return [dict create \
        result PASS \
        message "No unseen threads changed state between the two reads." \
        threads_checked [dict size $first_map]]
}

# Return the raw inbox API response (for diagnosing parser issues).
proc cmd_raw {c} {
    set js {
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const params = new URLSearchParams({
            visual_message_return_type: 'unseen',
            thread_message_limit: '1',
            persistentBadging: 'true',
            limit: '20',
        });
        const resp = await fetch('/api/v1/direct_v2/inbox/?' + params.toString(), {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        return JSON.stringify({status: resp.status, data: resp.ok ? await resp.json() : null});
    })()
    }
    return [ig::eval_js $c $js]
}

# ---------------------------------------------------------------------------
# JSON rendering for the inbox shapes.
# ---------------------------------------------------------------------------

proc thread_node {t} {
    return [ig::n_obj [list \
        username [ig::n_str [dict get $t username]] \
        full_name [ig::n_str [dict get $t full_name]] \
        user_id [ig::n_str [dict get $t user_id]] \
        user_ids [ig::n_strarr [dict get $t user_ids]] \
        thread_id [ig::n_str [dict get $t thread_id]] \
        thread_v2_id [null_or_str [dict get $t thread_v2_id]] \
        last_activity_iso [ig::n_str [dict get $t last_activity_iso]] \
        last_snippet [ig::n_str [dict get $t last_snippet]] \
        unseen [ig::n_bool [dict get $t unseen]] \
        is_group [ig::n_bool [dict get $t is_group]]]]
}

# A typed node for a value that is either the null sentinel or a string.
proc null_or_str {v} {
    if {$v eq "\x00null"} { return [ig::n_null] }
    return [ig::n_str $v]
}
# A typed node for has_older/oldest_cursor (null sentinel, bool literal, or str).
proc null_or_scalar {v} {
    if {$v eq "\x00null"} { return [ig::n_null] }
    if {$v in {true false}} { return [ig::n_bool $v] }
    return [ig::n_str $v]
}

proc render_list {result} {
    set threadElems {}
    foreach t [dict get $result threads] { lappend threadElems [thread_node $t] }
    return [ig::jenc [ig::n_obj [list \
        viewer_id [ig::n_str [dict get $result viewer_id]] \
        threads [ig::n_arr $threadElems] \
        thread_count [ig::n_int [dict get $result thread_count]] \
        pages_fetched [ig::n_int [dict get $result pages_fetched]] \
        has_older_final [null_or_scalar [dict get $result has_older_final]] \
        oldest_cursor_final [null_or_scalar [dict get $result oldest_cursor_final]] \
        complete [ig::n_bool [dict get $result complete]]]]]
}

proc render_verify {result} {
    if {[dict get $result result] eq "PASS"} {
        return [ig::jenc [ig::n_obj [list \
            result [ig::n_str PASS] \
            message [ig::n_str [dict get $result message]] \
            threads_checked [ig::n_int [dict get $result threads_checked]]]]]
    }
    set flippedElems {}
    foreach fl [dict get $result flipped_threads] {
        lappend flippedElems [ig::n_obj [list \
            thread_id [ig::n_str [dict get $fl thread_id]] \
            username [ig::n_str [dict get $fl username]] \
            was_unseen [ig::n_bool true] \
            now_unseen [ig::n_bool false]]]
    }
    return [ig::jenc [ig::n_obj [list \
        result [ig::n_str FAIL] \
        message [ig::n_str [dict get $result message]] \
        flipped_threads [ig::n_arr $flippedElems]]]]
}

# ---------------------------------------------------------------------------
# Serialiser entry: declare the seen-mutation veto guard, nav to the IG home
# (covering view + session check; this script never navigates to /direct/), then
# page the inbox-metadata endpoint via the policed `api` verb. parse_inbox_response
# and render_list are shared with the legacy path, so output is byte-faithful.
# ---------------------------------------------------------------------------

# Fetch one inbox-metadata page over the policed `api` verb. Returns the parsed
# response dict (the raw inbox JSON), or {error ...} on a non-JSON body.
proc sv_fetch_inbox_page {{cursor ""} {limit 20}} {
    set params "visual_message_return_type=unseen&thread_message_limit=1&persistentBadging=true&limit=$limit"
    if {$cursor ne ""} { append params "&cursor=$cursor" }
    set body [api "/api/v1/direct_v2/inbox/" --params $params --headers [ig::api_headers]]
    if {[catch {json::json2dict $body} data]} {
        return [dict create error "inbox response was not JSON"]
    }
    return $data
}

# Enumerate the whole DM inbox (metadata only) over the policed surface. Mirrors
# cmd_list's paging and dedup, feeding the shared parse_inbox_response.
proc sv_cmd_list {{max_threads 2000} {start_cursor ""}} {
    set all_threads {}
    set seen_ids {}
    set viewer_id ""
    set cursor $start_cursor
    set pages 0
    set has_older "\x00null"
    set oldest_cursor "\x00null"
    while {1} {
        set data [sv_fetch_inbox_page $cursor]
        if {[ig::dget $data error ""] ne ""} {
            if {[llength $all_threads]} { break }
            return $data
        }
        set inbox [ig::dget $data inbox $data]
        if {$viewer_id eq ""} {
            set viewer_id [viewer_id_of [ig::dget $data viewer {}]]
        }
        incr pages
        set before [llength $all_threads]
        foreach t [parse_inbox_response $data] {
            set tid [dict get $t thread_id]
            if {$tid ne "" && [dict exists $seen_ids $tid]} { continue }
            if {$tid ne ""} { dict set seen_ids $tid 1 }
            lappend all_threads $t
        }
        set has_older [ig::dget_null $inbox has_older]
        set oldest_cursor [ig::dget_null $inbox oldest_cursor]
        if {[llength $all_threads] == $before} { break }
        if {[llength $all_threads] >= $max_threads || \
            $has_older eq "\x00null" || $has_older eq "false" || \
            $oldest_cursor eq "\x00null" || $oldest_cursor eq ""} { break }
        set cursor $oldest_cursor
    }
    set complete [expr {$has_older eq "false"}]
    return [dict create \
        viewer_id $viewer_id \
        threads $all_threads \
        thread_count [llength $all_threads] \
        pages_fetched $pages \
        has_older_final $has_older \
        oldest_cursor_final $oldest_cursor \
        complete $complete]
}

proc serialiser_run {skillArgs} {
    global SEEN_BLOCK_PATTERNS
    set command "list"
    set max_threads 2000
    set start_cursor ""
    if {[llength $skillArgs]} {
        set command [lindex $skillArgs 0]
        set rest [lrange $skillArgs 1 end]
        for {set i 0} {$i < [llength $rest]} {incr i} {
            set a [lindex $rest $i]
            switch -- $a {
                --max { incr i; set max_threads [lindex $rest $i] }
                --cursor { incr i; set start_cursor [lindex $rest $i] }
            }
        }
    }

    # Declare the seen-mutation guard BEFORE any navigation: a matching request
    # is refused by the harness and never leaves the browser.
    foreach p $SEEN_BLOCK_PATTERNS { veto $p }

    nav "https://www.instagram.com/" --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit [ig::render_flat [dict create error "Not logged in to Instagram ([dict get [state] terminal]). Log in via a Chrome-compatible browser first."]]
        return
    }

    switch -- $command {
        list {
            set result [sv_cmd_list $max_threads $start_cursor]
            if {[dict exists $result threads]} {
                emit [render_list $result]
            } else {
                emit [ig::render_flat $result]
            }
        }
        default {
            emit [ig::render_flat [dict create error "Unknown command: $command (the serialiser path supports 'list')"]]
        }
    }
}

proc main {} {
    global argv
    set command "list"
    set max_threads 2000
    set start_cursor ""
    if {[llength $argv]} {
        set command [lindex $argv 0]
        set rest [lrange $argv 1 end]
        for {set i 0} {$i < [llength $rest]} {incr i} {
            set a [lindex $rest $i]
            switch -- $a {
                --max { incr i; set max_threads [lindex $rest $i] }
                --cursor { incr i; set start_cursor [lindex $rest $i] }
            }
        }
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh inbox-noninvasive.tcl ..."
        exit 1
    }

    set c [cdp::connect]
    $c cdp Page.enable

    # Arm Fetch blocking BEFORE any navigation so mutations are caught even if
    # they fire during page load.
    enable_fetch_blocking $c

    ig::navigate_and_wait $c "https://www.instagram.com/" 5

    if {![ig::check_logged_in $c]} {
        puts [ig::render_flat [dict create error "Not logged in to Instagram. Log in via a Chrome-compatible browser first."]]
        exit 1
    }

    switch -- $command {
        list {
            set result [cmd_list $c $max_threads 5.0 $start_cursor]
            if {[dict exists $result threads]} {
                puts [render_list $result]
            } else {
                puts [ig::render_flat $result]
            }
        }
        verify-noninvasive {
            set result [cmd_verify_noninvasive $c]
            if {[dict exists $result result]} {
                puts [render_verify $result]
            } else {
                puts [ig::render_flat $result]
            }
        }
        raw {
            set result [cmd_raw $c]
            # raw is opaque; emit the captured JSON faithfully.
            puts [ig::last_raw]
        }
        default {
            puts [ig::render_flat [dict create error "Unknown command: $command"]]
        }
    }
    $c close
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
