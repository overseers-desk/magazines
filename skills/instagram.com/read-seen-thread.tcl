#!/usr/bin/env tclsh
# read-seen-thread: fetch message history from an Instagram DM thread, but ONLY
# when the thread is already marked SEEN by the operator. Refuses unread threads.
#
# The hyphen-delimited word "seen" in the filename is load-bearing. This script
# exists alongside `inbox-noninvasive.tcl` because reading a thread's message
# content is fundamentally an invasive operation in the general case: if the
# thread carries unread messages, the fetch will mark them seen and that change
# is visible to the other party.
#
# The seen-only guarantee is enforced by checking the thread's unread status
# (via the same /api/v1/direct_v2/inbox/ call inbox-noninvasive uses) BEFORE
# issuing any thread-content fetch. If the thread is unread, the script returns
# an error and exits without making the thread-content call. The defensive Fetch
# block list is also armed: a matching seen-mutation request is paused and never
# released, so it cannot leave the browser.
#
# Invoked by reference through the serialiser (see SKILL.md §9):
#     browser-serialiser instagram.com/read-seen-thread thread <thread_id> [--limit N]
#     browser-serialiser instagram.com/read-seen-thread by-handle <handle> [--limit N]
#     browser-serialiser instagram.com/read-seen-thread all-seen [--limit N]
#
# The serialiser path (serialiser_run) declares the seen-mutation guard via the
# `veto` verb, checks the seen gate against the inbox endpoint (api) BEFORE any
# thread-content fetch, and reads thread content via the policed `api` verb. The
# seen gate, parse, and render procs are shared with the legacy path.

source [file dirname [info script]]/fetch-recent-posts.tcl

# Patterns identifying potential seen-mutation requests. Paused and never
# released, so they cannot leave the browser; the script never navigates to a
# thread page, so the React bundle should never fire one in our context anyway.
set SEEN_BLOCK_PATTERNS {
    */seen/*
    */mark_seen*
    *item_seen*
    */items/*/seen*
}

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

proc scan_int {v} {
    if {[string is integer -strict $v]} { return $v }
    if {[regexp {^-?\d+} $v m]} { return $m }
    return 0
}
proc viewer_id_of {viewer} {
    set v [ig::dget $viewer pk ""]
    if {$v eq ""} { set v [ig::dget $viewer id ""] }
    return $v
}
proc dict_has {d key} {
    if {[catch {dict exists $d $key} ok]} { return 0 }
    return $ok
}

# ---------------------------------------------------------------------------
# Inbox-state checking. Same metadata-only call inbox-noninvasive uses.
# ---------------------------------------------------------------------------

proc fetch_inbox {c} {
    set js {
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const params = new URLSearchParams({
            visual_message_return_type: 'unseen',
            thread_message_limit: '1',
            persistentBadging: 'true',
            limit: '50',
        });
        const resp = await fetch('/api/v1/direct_v2/inbox/?' + params.toString(), {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (!resp.ok) return JSON.stringify({error: 'HTTP ' + resp.status, status: resp.status});
        return JSON.stringify(await resp.json());
    })()
    }
    return [ig::eval_js $c $js]
}

# marked_as_unread OR (viewer's last_seen_at timestamp < last_activity_at).
proc is_thread_unseen {thread viewer_id} {
    if {[ig::truthy [ig::dget $thread marked_as_unread false]]} { return 1 }
    set last_seen_at [ig::dget $thread last_seen_at {}]
    if {$viewer_id ne "" && [dict_has $last_seen_at $viewer_id]} {
        set seen_ts [scan_int [ig::dget [dict get $last_seen_at $viewer_id] timestamp 0]]
        set act_ts [scan_int [ig::dget $thread last_activity_at 0]]
        if {$act_ts > $seen_ts} { return 1 }
    }
    return 0
}

# Locate the matching thread in the inbox response. Returns {thread viewer_id};
# thread is "" when not found.
proc find_thread {inbox_data {thread_id ""} {handle ""}} {
    set viewer_id [viewer_id_of [ig::dget $inbox_data viewer {}]]
    set inbox [ig::dget $inbox_data inbox $inbox_data]
    set threads [ig::dget $inbox threads {}]
    if {$thread_id ne ""} {
        foreach t $threads {
            if {[ig::dget $t thread_id ""] eq $thread_id} { return [list $t $viewer_id] }
        }
        return [list "" $viewer_id]
    }
    if {$handle ne ""} {
        set h [string tolower $handle]
        foreach t $threads {
            foreach u [ig::dget $t users {}] {
                if {[string tolower [ig::dget $u username ""]] eq $h} {
                    return [list $t $viewer_id]
                }
            }
        }
        return [list "" $viewer_id]
    }
    return [list "" $viewer_id]
}

# ---------------------------------------------------------------------------
# Thread message fetch (only invoked after the seen gate has passed).
# ---------------------------------------------------------------------------

proc fetch_thread_messages {c thread_id message_limit {cursor ""}} {
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
            direction: 'older',
            limit: '@LIMIT@',
        });
        @SETCURSOR@
        const resp = await fetch('/api/v1/direct_v2/threads/@TID@/?' + params.toString(), {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (!resp.ok) return JSON.stringify({error: 'HTTP ' + resp.status, status: resp.status});
        return JSON.stringify(await resp.json());
    })()
    }
    set js [string map [list @LIMIT@ $message_limit @TID@ $thread_id @SETCURSOR@ $set_cursor] $js]
    return [ig::eval_js $c $js]
}

set THREAD_PAGE_SIZE 100

# Page a thread from newest backwards until exhausted or max_messages reached.
# Returns a dict {items pages_fetched has_older_final ?error?}. items is a list
# of {parsed rawjson} pairs preserving raw item text for unknown types.
proc fetch_thread_all {c thread_id max_messages {page_size 100} {pace 5.0}} {
    set all_items {}
    set raw_items {}
    set seen_ids {}
    set cursor ""
    set pages 0
    set has_older "\x00null"
    while {1} {
        set msg_data [fetch_thread_messages $c $thread_id $page_size $cursor]
        set raw_page [ig::last_raw]
        if {[ig::dget $msg_data error ""] ne ""} {
            return [dict create items $all_items raw_items $raw_items \
                pages_fetched $pages has_older_final $has_older \
                error [dict get $msg_data error]]
        }
        set thread [ig::dget $msg_data thread {}]
        incr pages
        # Raw item texts for this page, for byte-faithful passthrough of unknown
        # item types via the `raw` field.
        set page_raw_items [ig::split_json_array \
            [ig::extract_json_array_after_key $raw_page items]]
        set parsed_items [ig::dget $thread items {}]
        set k 0
        foreach it $parsed_items {
            set iid [ig::dget $it item_id ""]
            if {$iid ne "" && [dict exists $seen_ids $iid]} { incr k; continue }
            if {$iid ne ""} { dict set seen_ids $iid 1 }
            lappend all_items $it
            lappend raw_items [lindex $page_raw_items $k]
            incr k
        }
        set has_older [ig::dget_null $thread has_older]
        set oldest_cursor [ig::dget_null $thread oldest_cursor]
        if {[llength $all_items] >= $max_messages || \
            $has_older eq "\x00null" || $has_older eq "false" || \
            $oldest_cursor eq "\x00null" || $oldest_cursor eq ""} { break }
        set cursor $oldest_cursor
        after [expr {int($pace * 1000)}]
    }
    return [dict create items $all_items raw_items $raw_items \
        pages_fetched $pages has_older_final $has_older]
}

# Convert raw thread.items into structured message rows. For an unrecognised
# item_type the raw item JSON is carried under `raw` so no content is discarded.
proc parse_thread_items {items raw_items viewer_id} {
    set rows {}
    set i 0
    foreach it $items {
        set user_id [ig::dget $it user_id ""]
        set item_type [ig::dget $it item_type ""]
        set ts [ig::dget $it timestamp 0]

        set raw_node ""
        switch -- $item_type {
            text { set text [ig::dget $it text ""] }
            like { set text "\[like\]" }
            media_share {
                set ms [ig::dget $it media_share {}]
                set cap [ig::dget $ms caption {}]
                set cap_text [ig::dget $cap text ""]
                set text [string trim "\[shared post\] $cap_text"]
            }
            reel_share {
                set rs [ig::dget $it reel_share {}]
                set text [string trim "\[reel-share\] [ig::dget $rs text ""]"]
            }
            raven_media { set text "\[disappearing media\]" }
            story_share { set text "\[story-share\]" }
            media { set text "\[media\]" }
            link {
                set ln [ig::dget $it link {}]
                set ctx [ig::dget $ln link_context {}]
                set text [string trim "\[link\] [ig::dget $ctx link_url ""] [ig::dget $ln text ""]"]
            }
            action_log {
                set al [ig::dget $it action_log {}]
                set text [string trim "\[action\] [ig::dget $al description ""]"]
            }
            default {
                set text "\[$item_type\]"
                set raw_node [lindex $raw_items $i]
            }
        }

        if {$viewer_id ne ""} {
            set is_from_viewer [ig::n_bool [expr {$user_id eq $viewer_id}]]
        } else {
            set is_from_viewer [ig::n_null]
        }
        set fields [list \
            is_from_viewer $is_from_viewer \
            from_user_id [ig::n_str $user_id] \
            item_type [ig::n_str $item_type] \
            timestamp_iso [ig::n_str [micros_to_iso $ts]] \
            text [ig::n_str $text] \
            item_id [ig::n_str [ig::dget $it item_id ""]]]
        if {$raw_node ne ""} {
            lappend fields raw [list rawjson $raw_node]
        }
        lappend rows [ig::n_obj $fields]
        incr i
    }
    return $rows
}

# Combine inbox-side metadata with the paged message list into one result node.
proc build_thread_result {target paged viewer_id} {
    set items [dict get $paged items]
    set raw_items [dict get $paged raw_items]
    set users [ig::dget $target users {}]
    set other_party ""
    if {[llength $users]} { set other_party [ig::dget [lindex $users 0] username ""] }
    set has_older_final [dict get $paged has_older_final]
    set has_err [dict exists $paged error]

    set msgNodes [parse_thread_items $items $raw_items $viewer_id]
    set complete [expr {$has_older_final eq "false" && !$has_err}]

    set fields [list \
        thread_id [null_or_str [ig::dget $target thread_id "\x00null"]] \
        thread_v2_id [null_or_str [ig::dget_null $target thread_v2_id]] \
        other_party [ig::n_str $other_party] \
        is_group [ig::n_bool [ig::truthy [ig::dget $target is_group false]]] \
        last_activity_iso [ig::n_str [micros_to_iso [ig::dget $target last_activity_at 0]]] \
        viewer_id [ig::n_str $viewer_id] \
        message_count_returned [ig::n_int [llength $items]] \
        pages_fetched [ig::n_int [dict get $paged pages_fetched]] \
        has_older_final [null_or_bool $has_older_final] \
        complete [ig::n_bool $complete] \
        messages [ig::n_arr $msgNodes]]
    if {$has_err} {
        lappend fields error [ig::n_str [dict get $paged error]]
    }
    return [ig::n_obj $fields]
}

proc null_or_str {v} {
    if {$v eq "\x00null"} { return [ig::n_null] }
    return [ig::n_str $v]
}
proc null_or_bool {v} {
    if {$v eq "\x00null"} { return [ig::n_null] }
    if {$v in {true false}} { return [ig::n_bool $v] }
    return [ig::n_str $v]
}

# ---------------------------------------------------------------------------
# Commands. Each returns {kind <k> node <jsonNode>} or {kind error dict <d>}.
# ---------------------------------------------------------------------------

# If target is unseen, return a refusal node; else "".
proc seen_or_refuse {target viewer_id} {
    if {$target eq ""} {
        return [ig::n_obj [list error [ig::n_str "thread not found in current inbox snapshot"]]]
    }
    if {[is_thread_unseen $target $viewer_id]} {
        set last_seen_at [ig::dget $target last_seen_at {}]
        set last_seen ""
        if {[dict_has $last_seen_at $viewer_id]} {
            set last_seen [dict get $last_seen_at $viewer_id]
        }
        set other_party ""
        set users [ig::dget $target users {}]
        if {[llength $users]} { set other_party [ig::dget [lindex $users 0] username ""] }
        if {$last_seen ne ""} {
            set lsby [ig::n_str [micros_to_iso [ig::dget $last_seen timestamp 0]]]
        } else {
            set lsby [ig::n_null]
        }
        return [ig::n_obj [list \
            error [ig::n_str "REFUSED: thread is unread; reading would mark messages as seen"] \
            thread_id [ig::n_str [ig::dget $target thread_id ""]] \
            other_party [ig::n_str $other_party] \
            unread_state [ig::n_obj [list \
                marked_as_unread [ig::n_bool [ig::truthy [ig::dget $target marked_as_unread false]]] \
                last_activity_iso [ig::n_str [micros_to_iso [ig::dget $target last_activity_at 0]]] \
                last_seen_by_viewer_iso $lsby]]]]
    }
    return ""
}

proc cmd_thread {c thread_id max_messages {ungated 0}} {
    if {$ungated} {
        set paged [fetch_thread_all $c $thread_id $max_messages]
        if {[dict exists $paged error]} {
            return [ig::n_obj [list \
                thread_id [ig::n_str $thread_id] \
                ungated [ig::n_bool true] \
                error [ig::n_str [dict get $paged error]]]]
        }
        set msgNodes [parse_thread_items [dict get $paged items] [dict get $paged raw_items] ""]
        set has_older_final [dict get $paged has_older_final]
        return [ig::n_obj [list \
            thread_id [ig::n_str $thread_id] \
            ungated [ig::n_bool true] \
            message_count_returned [ig::n_int [llength [dict get $paged items]]] \
            pages_fetched [ig::n_int [dict get $paged pages_fetched]] \
            has_older_final [null_or_bool $has_older_final] \
            complete [ig::n_bool [expr {$has_older_final eq "false"}]] \
            messages [ig::n_arr $msgNodes]]]
    }
    set inbox_data [fetch_inbox $c]
    if {[ig::dget $inbox_data error ""] ne ""} { return [flat_node $inbox_data] }
    lassign [find_thread $inbox_data $thread_id] target viewer_id
    set refused [seen_or_refuse $target $viewer_id]
    if {$refused ne ""} { return $refused }
    after 5000
    set paged [fetch_thread_all $c $thread_id $max_messages]
    return [build_thread_result $target $paged $viewer_id]
}

proc cmd_by_handle {c handle max_messages} {
    set inbox_data [fetch_inbox $c]
    if {[ig::dget $inbox_data error ""] ne ""} { return [flat_node $inbox_data] }
    lassign [find_thread $inbox_data "" $handle] target viewer_id
    set refused [seen_or_refuse $target $viewer_id]
    if {$refused ne ""} { return $refused }
    after 5000
    set paged [fetch_thread_all $c [ig::dget $target thread_id ""] $max_messages]
    return [build_thread_result $target $paged $viewer_id]
}

proc cmd_all_seen {c max_messages} {
    set inbox_data [fetch_inbox $c]
    if {[ig::dget $inbox_data error ""] ne ""} { return [flat_node $inbox_data] }
    set viewer_id [viewer_id_of [ig::dget $inbox_data viewer {}]]
    set inbox [ig::dget $inbox_data inbox $inbox_data]
    set threads [ig::dget $inbox threads {}]

    set threadNodes {}
    set refusedNodes {}
    foreach t $threads {
        set users [ig::dget $t users {}]
        set username ""
        if {[llength $users]} { set username [ig::dget [lindex $users 0] username ""] }
        set tid [ig::dget $t thread_id ""]
        if {[is_thread_unseen $t $viewer_id]} {
            lappend refusedNodes [ig::n_obj [list \
                thread_id [ig::n_str $tid] \
                other_party [ig::n_str $username] \
                reason [ig::n_str unread] \
                marked_as_unread [ig::n_bool [ig::truthy [ig::dget $t marked_as_unread false]]]]]
            continue
        }
        after 5000
        set paged [fetch_thread_all $c $tid $max_messages]
        lappend threadNodes [build_thread_result $t $paged $viewer_id]
    }
    return [ig::n_obj [list \
        viewer_id [ig::n_str $viewer_id] \
        threads [ig::n_arr $threadNodes] \
        refused [ig::n_arr $refusedNodes]]]
}

# A typed node for a flat error dict (scalar string/int values).
proc flat_node {d} {
    set pairs {}
    dict for {k v} $d {
        if {[string is integer -strict $v]} {
            lappend pairs $k [ig::n_int $v]
        } else {
            lappend pairs $k [ig::n_str $v]
        }
    }
    return [ig::n_obj $pairs]
}

# ---------------------------------------------------------------------------
# Serialiser entry: declare the seen-mutation veto, check the seen gate against
# the inbox endpoint (api) BEFORE any thread-content fetch, then read thread
# content via the policed `api` verb. find_thread, is_thread_unseen, seen_or_refuse,
# parse_thread_items, and build_thread_result are shared with the legacy path.
# ---------------------------------------------------------------------------

# Fetch the inbox metadata over the policed `api` verb. Returns the parsed dict
# or {error ...} on a non-JSON body.
proc sv_fetch_inbox {} {
    set params "visual_message_return_type=unseen&thread_message_limit=1&persistentBadging=true&limit=50"
    set body [api "/api/v1/direct_v2/inbox/" --params $params --headers [ig::api_headers]]
    if {[catch {json::json2dict $body} data]} {
        return [dict create error "inbox response was not JSON"]
    }
    return $data
}

# Page a thread from newest backwards over the policed `api` verb. Same return
# shape as fetch_thread_all (items, raw_items, pages_fetched, has_older_final),
# so build_thread_result renders byte-identically. The raw body from `api` is the
# byte-faithful page used for unknown-item-type passthrough.
proc sv_fetch_thread_all {thread_id max_messages {page_size 100}} {
    set all_items {}
    set raw_items {}
    set seen_ids {}
    set cursor ""
    set pages 0
    set has_older "\x00null"
    while {1} {
        set params "visual_message_return_type=unseen&direction=older&limit=$page_size"
        if {$cursor ne ""} { append params "&cursor=$cursor" }
        set raw_page [api "/api/v1/direct_v2/threads/$thread_id/" \
            --params $params --headers [ig::api_headers]]
        if {[catch {json::json2dict $raw_page} msg_data]} {
            return [dict create items $all_items raw_items $raw_items \
                pages_fetched $pages has_older_final $has_older \
                error "thread response was not JSON"]
        }
        if {[ig::dget $msg_data error ""] ne ""} {
            return [dict create items $all_items raw_items $raw_items \
                pages_fetched $pages has_older_final $has_older \
                error [dict get $msg_data error]]
        }
        set thread [ig::dget $msg_data thread {}]
        incr pages
        set page_raw_items [ig::split_json_array \
            [ig::extract_json_array_after_key $raw_page items]]
        set parsed_items [ig::dget $thread items {}]
        set k 0
        foreach it $parsed_items {
            set iid [ig::dget $it item_id ""]
            if {$iid ne "" && [dict exists $seen_ids $iid]} { incr k; continue }
            if {$iid ne ""} { dict set seen_ids $iid 1 }
            lappend all_items $it
            lappend raw_items [lindex $page_raw_items $k]
            incr k
        }
        set has_older [ig::dget_null $thread has_older]
        set oldest_cursor [ig::dget_null $thread oldest_cursor]
        if {[llength $all_items] >= $max_messages || \
            $has_older eq "\x00null" || $has_older eq "false" || \
            $oldest_cursor eq "\x00null" || $oldest_cursor eq ""} { break }
        set cursor $oldest_cursor
    }
    return [dict create items $all_items raw_items $raw_items \
        pages_fetched $pages has_older_final $has_older]
}

proc sv_cmd_thread {thread_id max_messages} {
    set inbox_data [sv_fetch_inbox]
    if {[ig::dget $inbox_data error ""] ne ""} { return [flat_node $inbox_data] }
    lassign [find_thread $inbox_data $thread_id] target viewer_id
    set refused [seen_or_refuse $target $viewer_id]
    if {$refused ne ""} { return $refused }
    set paged [sv_fetch_thread_all $thread_id $max_messages]
    return [build_thread_result $target $paged $viewer_id]
}

proc sv_cmd_by_handle {handle max_messages} {
    set inbox_data [sv_fetch_inbox]
    if {[ig::dget $inbox_data error ""] ne ""} { return [flat_node $inbox_data] }
    lassign [find_thread $inbox_data "" $handle] target viewer_id
    set refused [seen_or_refuse $target $viewer_id]
    if {$refused ne ""} { return $refused }
    set paged [sv_fetch_thread_all [ig::dget $target thread_id ""] $max_messages]
    return [build_thread_result $target $paged $viewer_id]
}

proc sv_cmd_all_seen {max_messages} {
    set inbox_data [sv_fetch_inbox]
    if {[ig::dget $inbox_data error ""] ne ""} { return [flat_node $inbox_data] }
    set viewer_id [viewer_id_of [ig::dget $inbox_data viewer {}]]
    set inbox [ig::dget $inbox_data inbox $inbox_data]
    set threads [ig::dget $inbox threads {}]

    set threadNodes {}
    set refusedNodes {}
    foreach t $threads {
        set users [ig::dget $t users {}]
        set username ""
        if {[llength $users]} { set username [ig::dget [lindex $users 0] username ""] }
        set tid [ig::dget $t thread_id ""]
        if {[is_thread_unseen $t $viewer_id]} {
            lappend refusedNodes [ig::n_obj [list \
                thread_id [ig::n_str $tid] \
                other_party [ig::n_str $username] \
                reason [ig::n_str unread] \
                marked_as_unread [ig::n_bool [ig::truthy [ig::dget $t marked_as_unread false]]]]]
            continue
        }
        set paged [sv_fetch_thread_all $tid $max_messages]
        lappend threadNodes [build_thread_result $t $paged $viewer_id]
    }
    return [ig::n_obj [list \
        viewer_id [ig::n_str $viewer_id] \
        threads [ig::n_arr $threadNodes] \
        refused [ig::n_arr $refusedNodes]]]
}

proc serialiser_run {skillArgs} {
    global SEEN_BLOCK_PATTERNS
    if {![llength $skillArgs]} {
        emit [ig::jenc [ig::n_obj [list error [ig::n_str "Usage: instagram.com/read-seen-thread thread|by-handle|all-seen ..."]]]]
        return
    }
    set command [lindex $skillArgs 0]
    set rest [lrange $skillArgs 1 end]
    set limit 2000
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $rest $i] }
            default { lappend positional $a }
        }
    }
    if {$command ni {thread by-handle all-seen}} {
        emit [ig::jenc [ig::n_obj [list error [ig::n_str "Usage: instagram.com/read-seen-thread thread|by-handle|all-seen ..."]]]]
        return
    }

    # Declare the seen-mutation guard BEFORE any navigation.
    foreach p $SEEN_BLOCK_PATTERNS { veto $p }

    nav "https://www.instagram.com/" --wait 4
    if {[dict get [state] terminal] ne ""} {
        emit [ig::jenc [ig::n_obj [list error [ig::n_str "Not logged in to Instagram ([dict get [state] terminal]). Log in via a Chrome-compatible browser first."]]]]
        return
    }

    switch -- $command {
        thread    { set node [sv_cmd_thread [lindex $positional 0] $limit] }
        by-handle { set node [sv_cmd_by_handle [lindex $positional 0] $limit] }
        all-seen  { set node [sv_cmd_all_seen $limit] }
    }
    emit [ig::jenc $node]
}

proc main {} {
    global argv
    if {![llength $argv]} {
        puts "Usage: read-seen-thread.tcl thread|by-handle|all-seen ..."
        exit 1
    }
    set command [lindex $argv 0]
    set rest [lrange $argv 1 end]
    set limit 2000
    set ungated 0
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $rest $i] }
            --ungated { set ungated 1 }
            default { lappend positional $a }
        }
    }

    if {$command ni {thread by-handle all-seen}} {
        puts "Usage: read-seen-thread.tcl thread|by-handle|all-seen ..."
        exit 1
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh read-seen-thread.tcl ..."
        exit 1
    }

    set c [cdp::connect]
    $c cdp Page.enable

    # Arm defensive Fetch interception BEFORE the first navigation.
    enable_fetch_blocking $c

    ig::navigate_and_wait $c "https://www.instagram.com/" 4

    if {![ig::check_logged_in $c]} {
        puts [ig::render_flat [dict create error "Not logged in to Instagram. Log in via Chromium first."]]
        exit 1
    }

    switch -- $command {
        thread   { set node [cmd_thread $c [lindex $positional 0] $limit $ungated] }
        by-handle { set node [cmd_by_handle $c [lindex $positional 0] $limit] }
        all-seen { set node [cmd_all_seen $c $limit] }
    }
    puts [ig::jenc $node]
    $c close
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
