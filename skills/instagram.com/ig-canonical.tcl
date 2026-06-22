# ig-canonical.tcl - the canonical IG parsers and envelope builders the overseer's
# Home: overseer-toolbox/skills/instagram.com/ig-canonical.tcl
# B-job playbooks share.
#
# A playbook (ig-inbox.tcl, ig-thread.tcl, ig-profile.tcl, ig-posts.tcl) runs inside
# the serialiser harness's safe interp: it `nav`s to the page a human views, fetches
# the body with `api`/`dump`, feeds that body through the parsers here, and `emit`s the
# CANONICAL envelope {result, cursor, hasMore, fault} the BI server's persist consumes.
# The parse lives on the overseer (not the server) so a worker can fix a broken parser
# on their own overseer without touching the shared server; the server is a pure DB
# writer that ingests the canonical object.
#
# The parsers and envelope builders are pure Tcl over tcllib json - no socket, no
# exec, no file - so they run unchanged in the harness's safe interp. The harness
# adds a playbook's own directory to the safe interp access path, so each playbook
# `source`s this sibling for the ig:: helpers, the parsers, and the envelope.
#
# The canonical `result` per pageType:
#   ig-thread  {igThreadId, senderPks:[int], messages:[{item_id, sender_user_pk,
#               sent_at, item_type, body}], complete}
#   ig-inbox   {viewerId:int, threads:[{ig_thread_id, ig_thread_v2_id, is_group,
#               last_activity, unseen, username, full_name, primaryPk, memberPks}]}
#   ig-profile {dom-dumped profile fields}      ig-posts {posts:[...]}

package require json
package require json::write

::json::write indented 0
::json::write aligned 0


# ===========================================================================
# Small utilities (ported from social/lib/ig.js + helpers)
# ===========================================================================

proc dict_get_or {d key default} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}
# value or "" ; a present JSON null (json2dict -> "null") is treated as absent.
proc dstr {d key} {
    if {[dict exists $d $key]} { set v [dict get $d $key]; if {$v eq "null"} { return "" }; return $v }
    return ""
}
# truthy: JSON true / 1.
proc dbool {d key} {
    set v [dstr $d $key]
    return [expr {($v eq "true" || $v eq "1") ? 1 : 0}]
}
# social/lib/ig.js userPk: pk, else id, else ''. ("null" -> absent)
proc user_pk {u} {
    set pk [dstr $u pk]; if {$pk ne ""} { return $pk }
    set id [dstr $u id]; if {$id ne ""} { return $id }
    return ""
}

# The account-level long id (fbid_v2 / "17841…" Graph id), carried beside the
# classic pk on every inbox user object. Empty when absent.
proc user_fbid {u} { return [dstr $u fbid_v2] }
# Why an IG response carried no payload. A failure body leads with a `message`
# (login_required / checkpoint_required / feedback_required) and a `status`; a
# missing-field fault appends this so it says WHY, not merely that the field was
# absent. Empty when the response looks normal (the field was genuinely missing).
proc ig_fail_reason {d} {
    set parts {}
    foreach k {message status} { set v [dstr $d $k]; if {$v ne ""} { lappend parts $v } }
    return [join $parts " "]
}
# The web private API (/api/v1/...) identifies the caller by the Instagram web app
# id. Without this header the endpoint rejects a browser-UA request with HTTP 400
# "useragent mismatch". Pass it through the api verb's --headers on every /api/v1
# fetch. (The standalone skills inline the same constant; this is the shared home
# for the type-B primitives that source ig-canonical.)
proc ig_api_headers {} { return [list X-IG-App-ID 936619743392459] }
# IG µs since epoch -> ISO-8601 with millis (parity with lib/ig.js microsToIso).
# Returns "" when there is no timestamp; the caller emits JSON null for "".
proc micros_to_iso {us} {
    if {$us eq "" || $us eq "null"} { return "" }
    if {![regexp {^-?\d+$} $us]} { return "" }
    set secs   [expr {$us / 1000000}]
    set millis [expr {($us / 1000) % 1000}]
    return "[clock format $secs -gmt 1 -format %Y-%m-%dT%H:%M:%S].[format %03d $millis]Z"
}
# ISO-8601 (any offset, optional fractional seconds) -> naive UTC MySQL DATETIME
# "YYYY-MM-DD HH:MM:SS". The Tcl port of jobs.js isoToMysql: any offset is
# converted to UTC (matching the migration tool's astimezone(utc)) so a stored
# value is comparable regardless of source offset. Returns "" for an absent or
# unparseable input (the caller emits JSON null), the parity of JS returning null.
proc iso_to_mysql {iso} {
    if {$iso eq "" || $iso eq "null"} { return "" }
    # Fractional seconds are dropped to the second (MySQL DATETIME granularity);
    # %z/%S consume neither, so strip "[.]ddd" before the offset/Z.
    regsub {\.[0-9]+} $iso "" iso
    if {![catch {clock scan $iso -format {%Y-%m-%dT%H:%M:%S%z}} secs]} {
        return [clock format $secs -gmt 1 -format {%Y-%m-%d %H:%M:%S}]
    }
    # No offset present: interpret as UTC (the migration tool's naive-as-UTC rule).
    if {![catch {clock scan $iso -gmt 1 -format {%Y-%m-%dT%H:%M:%S}} secs]} {
        return [clock format $secs -gmt 1 -format {%Y-%m-%d %H:%M:%S}]
    }
    return ""
}

# --- JSON value emitters (build output with explicit shapes, never guessing) ---
# A correct JSON string escaper: tcllib's json::write string does NOT escape
# control characters, and DM text / bios carry literal newlines, so we escape
# them ourselves (", \, the C0 control set, and the short forms).
proc jq {s} {
    set out "\""
    foreach ch [split $s ""] {
        switch -- $ch {
            "\"" { append out {\"} }
            "\\" { append out {\\} }
            "\n" { append out {\n} }
            "\r" { append out {\r} }
            "\t" { append out {\t} }
            "\b" { append out {\b} }
            "\f" { append out {\f} }
            default {
                scan $ch %c code
                if {$code < 0x20} {
                    append out [format {\u%04x} $code]
                } elseif {$code < 0x7f} {
                    append out $ch
                } elseif {$code > 0xffff} {
                    # non-BMP (e.g. emoji): emit a UTF-16 surrogate pair so the
                    # output stays pure ASCII (avoids any stdout encoding hazard).
                    set c [expr {$code - 0x10000}]
                    append out [format {\u%04x\u%04x} [expr {0xd800 + ($c >> 10)}] [expr {0xdc00 + ($c & 0x3ff)}]]
                } else {
                    append out [format {\u%04x} $code]
                }
            }
        }
    }
    return "$out\""
}
proc j_str {s}      { return [jq $s] }
proc j_strornull {s} { return [expr {$s eq "" || $s eq "null" ? "null" : [jq $s]}] }
proc j_bool {b}     { return [expr {$b ? "true" : "false"}] }
proc j_iso  {us}    { set s [micros_to_iso $us]; return [expr {$s eq "" ? "null" : [jq $s]}] }
# MySQL-datetime-or-null: an ISO string (any offset) -> the quoted naive-UTC MySQL
# datetime, "" for an absent/unparseable input -> JSON null (parity with isoToMysql).
proc j_mysqlornull {iso} { set s [iso_to_mysql $iso]; return [expr {$s eq "" ? "null" : [jq $s]}] }
# integer-or-null: missing/null -> null, else the numeric literal.
proc j_intornull {v} { return [expr {$v eq "" || $v eq "null" ? "null" : $v}] }
proc j_arrstr {items} {
    set js {}
    foreach x $items { lappend js [jq $x] }
    return [json::write array {*}$js]
}
# JSON array of bare integer literals (canonical pk lists). Each item is already
# all-digits (the callers parse-int before adding), so it round-trips as a number.
proc j_arrint {items} {
    return "\[[join $items ,]\]"
}

# ===========================================================================
# ig-thread parser (port of jobs.js parseThread)
# ===========================================================================
proc thread_item_text {it itemType} {
    if {$itemType eq "text"} { return [dstr $it text] }
    if {$itemType eq "like"} { return "\[like\]" }
    if {$itemType eq "media_share"} {
        set cap ""; if {[dict exists $it media_share caption text]} { set cap [dict get $it media_share caption text] }
        return [string trim "\[shared post\] $cap"]
    }
    if {$itemType eq "reel_share"} {
        set t ""; if {[dict exists $it reel_share text]} { set t [dict get $it reel_share text] }
        return [string trim "\[reel-share\] $t"]
    }
    if {$itemType eq "raven_media"} { return "\[disappearing media\]" }
    if {$itemType eq "story_share"} { return "\[story-share\]" }
    if {$itemType eq "media"} { return "\[media\]" }
    if {$itemType eq "link"} {
        set url ""; if {[dict exists $it link link_context link_url]} { set url [dict get $it link link_context link_url] }
        set lt ""; if {[dict exists $it link text]} { set lt [dict get $it link text] }
        return [string trim "\[link\] $url $lt"]
    }
    if {$itemType eq "action_log"} {
        set d ""; if {[dict exists $it action_log description]} { set d [dict get $it action_log description] }
        return [string trim "\[action\] $d"]
    }
    return "\[$itemType\]"
}

# parseInt of an IG user id: the leading run of digits as a bare integer, "" when
# there is none (parity with JS parseInt(x,10), which stops at the first non-digit
# and yields NaN -> dropped for an all-non-digit input). Used to coerce sender and
# member pks to canonical numbers.
proc pk_int {v} {
    if {$v eq "" || $v eq "null"} { return "" }
    if {[regexp {^\s*(-?[0-9]+)} $v -> n]} { return [expr {$n + 0}] }
    return ""
}

# parse_thread: the Tcl port of jobs.js parseThread, operating on the same input
# shape the JS parser consumed - {messages:[{item_id, from_user_id, timestamp_iso,
# item_type, text}], complete}. Returns the CANONICAL thread result JSON. The parse
# now lives on the overseer (not the server), so this is the one place message
# field-extraction/filtering happens; pb_ig_thread builds the input from raw IG and
# the fixture self-test feeds a saved parser-input file. The server's persistThread
# attaches its own thread DB key, so threadPk is NOT embedded here.
#   - keep only messages with BOTH item_id and from_user_id
#   - senderPks: unique parseInt(from_user_id) over every message that HAS one
#   - each kept msg -> {item_id, sender_user_pk:int, sent_at(naive UTC), item_type, body}
proc parse_thread {igThreadId res} {
    set msgs [dict_get_or $res messages {}]
    set msgJsons {}
    set senderPks {}
    set senderSeen [dict create]
    foreach m $msgs {
        set fromId [dstr $m from_user_id]
        if {$fromId ne ""} {
            set spk [pk_int $fromId]
            if {$spk ne "" && ![dict exists $senderSeen $spk]} {
                dict set senderSeen $spk 1; lappend senderPks $spk
            }
        }
        set iid [dstr $m item_id]
        if {$iid eq "" || $fromId eq ""} { continue }
        lappend msgJsons [json::write object \
            item_id        [j_str $iid] \
            sender_user_pk [pk_int $fromId] \
            sent_at        [j_mysqlornull [dstr $m timestamp_iso]] \
            item_type      [j_str [dstr $m item_type]] \
            body           [j_str [dstr $m text]]]
    }
    set complete [expr {[dict exists $res complete] ? [dbool $res complete] : 0}]
    return [json::write object \
        igThreadId [j_str $igThreadId] \
        senderPks  [j_arrint $senderPks] \
        messages   [json::write array {*}$msgJsons] \
        complete   [j_bool $complete]]
}

# ===========================================================================
# ig-inbox parser (port of jobs.js parseInbox)
# ===========================================================================
# Build the parser-input thread shape (jobs.js parseInbox's per-thread input keys)
# from one raw IG inbox thread. The canonical mapping is parse_inbox's job; this
# only flattens the raw IG fields the parser reads.
proc inbox_thread_input {t viewerId} {
    set users [dict_get_or $t users {}]
    set u0 [expr {[llength $users] ? [lindex $users 0] : {}}]
    set lastActivity [dstr $t last_activity_at]
    set unseen [dbool $t marked_as_unread]
    if {$viewerId ne "" && [dict exists $t last_seen_at $viewerId timestamp] && [regexp {^\d+$} $lastActivity]} {
        set ts [dict get $t last_seen_at $viewerId timestamp]
        if {[regexp {^\d+$} $ts] && $lastActivity > $ts} { set unseen 1 }
    }
    set userIds {}
    set userFbids {}
    foreach u $users {
        set pk [user_pk $u]
        if {$pk ne "" && $pk ne "undefined"} { lappend userIds $pk; lappend userFbids [user_fbid $u] }
    }
    return [dict create \
        thread_id    [dstr $t thread_id] \
        thread_v2_id [dstr $t thread_v2_id] \
        is_group     [dbool $t is_group] \
        last_activity_iso [micros_to_iso $lastActivity] \
        user_id      [user_pk $u0] \
        user_fbid    [user_fbid $u0] \
        user_ids     $userIds \
        user_fbids   $userFbids \
        username     [dstr $u0 username] \
        full_name    [dstr $u0 full_name] \
        unseen       $unseen]
}

# parse_inbox: the Tcl port of jobs.js parseInbox, operating on the same input
# shape the JS parser consumed - {viewer_id, threads:[{thread_id, thread_v2_id,
# is_group, last_activity_iso, user_id, user_ids, username, full_name, unseen}]}.
# Returns one CANONICAL page result JSON. The parse now lives on the overseer; this
# is the one place inbox thread field-extraction/filtering happens.
#   - viewerId: parseInt(viewer_id) (null when absent)
#   - drop entries with no thread_id
#   - each -> {ig_thread_id, ig_thread_v2_id||null, is_group:0|1, last_activity(naive
#             UTC), unseen:bool, username||null, full_name||null,
#             primaryPk: parseInt(user_id) or first user_ids, memberPks: unique
#             parseInt(user_ids[]) (truthy only, parity with JS .filter(Boolean))}
proc parse_inbox {res} {
    set vid [dstr $res viewer_id]
    set viewerId [expr {$vid ne "" ? [pk_int $vid] : ""}]
    set tj {}
    foreach t [dict_get_or $res threads {}] {
        set tid [dstr $t thread_id]
        if {$tid eq ""} { continue }
        set userIds [dict_get_or $t user_ids {}]
        set userFbids [dict_get_or $t user_fbids {}]
        # pk_int(user) -> fbid_v2, from the parallel lists inbox_thread_input built.
        set pk2fbid [dict create]
        foreach x $userIds fb $userFbids {
            set p [pk_int $x]
            if {$p ne "" && $fb ne "" && ![dict exists $pk2fbid $p]} { dict set pk2fbid $p $fb }
        }
        set uid [dstr $t user_id]
        if {$uid ne ""} {
            set primaryPk [pk_int $uid]
        } elseif {[llength $userIds]} {
            set primaryPk [pk_int [lindex $userIds 0]]
        } else {
            set primaryPk ""
        }
        set memberPks {}
        set memberFbids {}
        set memberSeen [dict create]
        foreach x $userIds {
            set p [pk_int $x]
            # JS .filter(Boolean): a falsy parse (NaN or 0) is dropped.
            if {$p ne "" && $p != 0 && ![dict exists $memberSeen $p]} {
                dict set memberSeen $p 1; lappend memberPks $p
                lappend memberFbids [dict_get_or $pk2fbid $p ""]
            }
        }
        lappend tj [json::write object \
            ig_thread_id    [j_str $tid] \
            ig_thread_v2_id [j_strornull [dstr $t thread_v2_id]] \
            is_group        [expr {[dbool $t is_group] ? 1 : 0}] \
            last_activity   [j_mysqlornull [dstr $t last_activity_iso]] \
            unseen          [j_bool [dbool $t unseen]] \
            username        [j_strornull [dstr $t username]] \
            full_name       [j_strornull [dstr $t full_name]] \
            primaryPk       [j_intornull $primaryPk] \
            primaryFbid     [j_strornull [dstr $t user_fbid]] \
            memberPks       [j_arrint $memberPks] \
            memberFbids     [j_arrstr $memberFbids]]
    }
    return [json::write object \
        viewerId [j_intornull $viewerId] \
        threads  [json::write array {*}$tj]]
}

# ===========================================================================
# ig-posts parser (port of ig-posts.js)
# ===========================================================================
proc post_type {item} {
    set mt [dstr $item media_type]; if {$mt eq ""} { set mt 0 }
    set pt [dstr $item product_type]
    if {$mt == 1} { return image }
    if {$mt == 2} { return [expr {($pt eq "clips" || $pt eq "reels") ? "reel" : "video"}] }
    if {$mt == 8} { return carousel }
    return unknown
}
proc post_coauthors {item} {
    set out {}
    foreach c [dict_get_or $item coauthor_producers {}] { set u [dstr $c username]; if {$u ne ""} { lappend out $u } }
    return $out
}
proc post_sponsors {item} {
    set out {}
    foreach s [dict_get_or $item sponsor_tags {}] {
        if {[dict exists $s sponsor username]} { set u [dict get $s sponsor username]; if {$u ne "" && $u ne "null"} { lappend out $u } }
    }
    return $out
}
# nullable count with a default (JS ?? def). missing/null -> def.
proc dnum {d key def} { set v [dstr $d $key]; return [expr {$v eq "" ? $def : $v}] }
proc post_json {item} {
    set capText ""
    if {[dict exists $item caption text]} { set capText [dict get $item caption text] }
    set locName ""
    if {[dict exists $item location name]} { set locName [dict get $item location name] }
    set takenAt [dstr $item taken_at]; if {$takenAt eq ""} { set takenAt 0 }
    return [json::write object \
        post_id        [j_str [dstr $item id]] \
        taken_at_iso   [j_iso [expr {$takenAt * 1000000}]] \
        caption        [j_str $capText] \
        post_type      [j_str [post_type $item]] \
        location       [j_str $locName] \
        like_count     [j_intornull [dnum $item like_count 0]] \
        comment_count  [j_intornull [dnum $item comment_count 0]] \
        play_count     [j_intornull [dnum $item play_count null]] \
        view_count     [j_intornull [dnum $item view_count null]] \
        media_repost_count [j_intornull [dnum $item media_repost_count null]] \
        fb_like_count    [j_intornull [dnum $item fb_like_count null]] \
        fb_comment_count [j_intornull [dnum $item fb_comment_count null]] \
        fb_play_count    [j_intornull [dnum $item fb_play_count null]] \
        video_duration   [j_intornull [dnum $item video_duration null]] \
        coauthors      [j_arrstr [post_coauthors $item]] \
        sponsors       [j_arrstr [post_sponsors $item]] \
        is_paid_partnership [j_bool [dbool $item is_paid_partnership]] \
        like_and_view_counts_disabled [j_bool [dbool $item like_and_view_counts_disabled]]]
}

# ===========================================================================
# Envelope
# ===========================================================================
proc envelope_ok {r} {
    set cursor [dict get $r cursor]
    set c [expr {$cursor eq "" ? "null" : [json::write string $cursor]}]
    set h [expr {[dict get $r hasMore] ? "true" : "false"}]
    return [json::write object result [dict get $r result] cursor $c hasMore $h fault null]
}
# The fault shape lets the engine discriminate a terminal "removed" page (skip the
# handle / terminate a dead thread) from a transient unrecognised fault (retry).
# A playbook signals a non-default shape by leading its error with "<shape>: "
# (e.g. "removed: ..."); we strip the recognised tag so the detail stays human and
# default to "unrecognised" for everything else. Only known tags are honoured.
proc fault_shape_of {detail} {
    if {[regexp {^([a-z_]+):\s} $detail -> tag] && [lsearch -exact {removed login_wall} $tag] >= 0} {
        return $tag
    }
    return unrecognised
}
proc envelope_fault {detail} {
    set f [json::write object shape [json::write string [fault_shape_of $detail]] \
                                detail [json::write string [string range $detail 0 200]]]
    return [json::write object result null cursor null hasMore false fault $f]
}
