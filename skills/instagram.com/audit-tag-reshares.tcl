#!/usr/bin/env tclsh
# Audit Instagram tag reshares for a brand account.
#
# Use case: SOP D40 requires the service team to reshare customer-tagged stories
# immediately. This audits compliance by checking which tags since a given date
# were not reshared to the target's own story.
#
# Pipeline:
#   1. Resolve target user_id.
#   2. Verify logged-in identity (some data is target-account only).
#   3. Pull feed posts where target is tagged since --since (permanent).
#   4. Pull activity-inbox story-mention notifications (retention limited).
#   5. Pull target's currently-live story tray (<24h).
#   6. If logged in as target, pull own story archive since --since.
#   7. Cross-reference each tag against own stories; report unreshared items.
#
# Data-window reality:
#   - Tagged feed posts: full coverage since --since.
#   - Story tag notifications: Instagram retains roughly the last 14-30 days in
#     the activity inbox. Anything older is unrecoverable.
#   - Customer-side stories: gone 24h after posting regardless.
#   - Own story archive: only readable when logged in AS the target account.
#
# Invoked by reference through the serialiser (see SKILL.md §11):
#     browser-serialiser instagram.com/audit-tag-reshares audit <handle> --since YYYY-MM-DD
#
# The serialiser path navigates to the IG home (session) and the target profile
# (covering view), then reads the declared private endpoints via the policed `api`
# verb. The reshare-match heuristic inspects reshared_reel.id, imported_taken_at,
# and reel_mentions[].user_id and is best-effort.

package require json

# Shared IG helpers (ig::dget, ig::truthy, ig::seconds_to_iso, the typed-JSON
# encoder, sv_resolve_user_id, api_headers) live in the keystone library.
source [file dirname [info script]]/fetch-recent-posts.tcl

namespace eval audit {}

# ---------------------------------------------------------------------------
# Audit-specific API helpers. Each does one fetch over the policed `api` verb.
# ---------------------------------------------------------------------------

# Return {username <u> user_id <id>} of the logged-in viewer, or {error ...}.
proc audit::viewer_identity {} {
    set body [api "/api/v1/accounts/current_user/" --params "edit=true" \
        --headers [ig::api_headers]]
    if {[catch {json::json2dict $body} j]} {
        return [dict create error "current_user response was not JSON"]
    }
    if {[ig::dget $j error ""] ne ""} { return [dict create error [dict get $j error]] }
    set u [ig::dget $j user {}]
    set pk [ig::dget $u pk ""]
    if {$pk eq ""} { set pk [ig::dget $u id ""] }
    return [dict create username [ig::dget $u username ""] user_id $pk]
}

# Paginate /api/v1/usertags/<user_id>/feed/ until items predate $since_ts.
# Returns a list of tagged-post dicts (the Python field shape).
proc audit::fetch_tagged_feed {user_id since_ts} {
    set items {}
    set max_id ""
    set page 0
    while {1} {
        incr page
        set params "count=18"
        if {$max_id ne ""} { append params "&max_id=$max_id" }
        set body [api "/api/v1/usertags/$user_id/feed/" --params $params \
            --headers [ig::api_headers]]
        if {[catch {json::json2dict $body} data]} {
            puts stderr "tagged-feed page $page: response was not JSON"
            break
        }
        if {[ig::dget $data error ""] ne ""} {
            puts stderr "tagged-feed page $page: [dict get $data error]"
            break
        }
        set raw_items [ig::dget $data items {}]
        if {![llength $raw_items]} break
        set oldest_on_page ""
        foreach it $raw_items {
            set ts [ig::dget $it taken_at 0]
            if {$oldest_on_page eq "" || $ts < $oldest_on_page} { set oldest_on_page $ts }
            set owner [ig::dget $it user {}]
            set short [ig::dget $it code ""]
            if {$short eq ""} { set short [ig::dget $it shortcode ""] }
            set owner_id [ig::dget $owner pk ""]
            if {$owner_id eq ""} { set owner_id [ig::dget $owner id ""] }
            set media_id [ig::dget $it pk ""]
            if {$media_id eq ""} { set media_id [ig::dget $it id ""] }
            set captionNode [ig::dget $it caption {}]
            set caption "\x00null"
            if {[llength $captionNode]} { set caption [ig::dget $captionNode text ""] }
            lappend items [dict create \
                media_id $media_id \
                shortcode $short \
                taken_at $ts \
                taken_at_iso [audit::iso_or_null $ts] \
                owner_username [audit::str_or_null [ig::dget $owner username "\x00null"]] \
                owner_id $owner_id \
                media_type [audit::media_type_label [ig::dget $it media_type ""]] \
                url [expr {$short ne "" ? "https://www.instagram.com/p/$short/" : "\x00null"}] \
                caption $caption]
        }
        puts stderr "tagged-feed page $page: [llength $raw_items] items (cum [llength $items])"
        if {$oldest_on_page ne "" && $oldest_on_page < $since_ts} break
        if {[ig::dget $data more_available false] ne "true"} break
        set max_id [ig::dget $data next_max_id ""]
        if {$max_id eq ""} break
    }
    # Keep only items at or after since_ts with a real taken_at.
    set out {}
    foreach x $items {
        set ts [dict get $x taken_at]
        if {$ts ne "" && $ts != 0 && $ts >= $since_ts} { lappend out $x }
    }
    return $out
}

# Pull /api/v1/news/inbox/ and filter for story-mention + post-tag rows.
# Returns a list of notification dicts (newest first), or {error ...}.
proc audit::fetch_activity_inbox {since_ts} {
    set body [api "/api/v1/news/inbox/" --params "mark_as_seen=false" \
        --headers [ig::api_headers]]
    if {[catch {json::json2dict $body} data]} {
        return [dict create error "news inbox response was not JSON"]
    }
    if {[ig::dget $data error ""] ne ""} { return [dict create error [dict get $data error]] }

    set buckets {}
    foreach key {new_stories old_stories stories counts} {
        set v [ig::dget $data $key {}]
        if {[llength $v]} { foreach e $v { lappend buckets $e } }
    }
    foreach w [ig::dget $data subscriptions {}] {
        set st [ig::dget $w stories {}]
        if {[llength $st]} { foreach e $st { lappend buckets $e } }
    }

    set notifs {}
    foreach n $buckets {
        set args [ig::dget $n args {}]
        set ts [ig::dget $args timestamp ""]
        if {$ts eq ""} { set ts [ig::dget $n timestamp ""] }
        if {$ts eq ""} continue
        set ts_int [audit::scan_int $ts]
        if {$ts_int < $since_ts} continue
        set text [ig::dget $args text ""]
        if {$text eq ""} { set text [ig::dget $n text ""] }
        set story_type [ig::dget $n story_type "\x00null"]
        set kind [audit::classify_notif $text $story_type]
        if {$kind eq "skip"} continue
        set actor_username [ig::dget $args profile_name ""]
        if {$actor_username eq ""} { set actor_username [ig::dget $args username ""] }
        set actor_id [ig::dget $args profile_id ""]
        if {$actor_username eq ""} {
            set links [ig::dget $args links {}]
            if {[llength $links]} {
                set actor_username [ig::dget [lindex $links 0] title ""]
            }
        }
        if {$actor_username eq ""} { set actor_username "\x00null" }
        set media_id ""
        foreach k {media_id media story_media_id} {
            set v [ig::dget $args $k ""]
            if {$v ne "" && [audit::scalar_p $v]} { set media_id $v; break }
        }
        if {$media_id eq ""} {
            set ml [ig::dget $args media {}]
            if {[llength $ml]} {
                set m0 [lindex $ml 0]
                set media_id [ig::dget $m0 id ""]
                if {$media_id eq ""} { set media_id [ig::dget $m0 media_id ""] }
            }
        }
        lappend notifs [dict create \
            kind $kind \
            timestamp $ts_int \
            timestamp_iso [ig::seconds_to_iso $ts_int] \
            actor_username $actor_username \
            actor_id $actor_id \
            media_id $media_id \
            story_type $story_type \
            text $text]
    }
    return [lsort -command audit::notif_ts_desc $notifs]
}

# Sort notifications newest-first by timestamp (Python sorted(reverse=True)).
proc audit::notif_ts_desc {a b} {
    return [expr {[dict get $b timestamp] - [dict get $a timestamp]}]
}

# Fetch the target's currently-active stories (<24h). Returns a list of story
# items with reshare metadata, or {error ...}.
proc audit::fetch_live_story_tray {user_id} {
    set body [api "/api/v1/feed/user/$user_id/story/" --headers [ig::api_headers]]
    if {[catch {json::json2dict $body} data]} {
        return [dict create error "story tray response was not JSON"]
    }
    if {[ig::dget $data error ""] ne ""} { return [dict create error [dict get $data error]] }
    set reel [ig::dget $data reel {}]
    set out {}
    foreach it [ig::dget $reel items {}] { lappend out [audit::extract_story_item $it] }
    return $out
}

# Pull own story archive day-shells back to $since_ts. Only works when the viewer
# IS the target. Returns a list of story items, or {error ...}.
proc audit::fetch_own_story_archive {viewer_user_id target_user_id since_ts} {
    if {$viewer_user_id ne $target_user_id} {
        return [dict create error "archive_not_accessible" \
            detail "Story archive is only readable when logged in AS the target account."]
    }
    set body [api "/api/v1/archive/reel/day_shells/" --headers [ig::api_headers]]
    if {[catch {json::json2dict $body} shells]} {
        return [dict create error "archive shells response was not JSON"]
    }
    if {[ig::dget $shells error ""] ne ""} {
        return [dict create error "archive shells: [dict get $shells error]"]
    }
    set items {}
    set day_shells [ig::dget $shells day_shells {}]
    if {![llength $day_shells]} { set day_shells [ig::dget $shells items {}] }
    foreach shell $day_shells {
        set ts [ig::dget $shell created_at ""]
        if {$ts eq ""} { set ts [ig::dget $shell timestamp ""] }
        if {$ts eq ""} { set ts [ig::dget $shell date ""] }
        if {[string match {*-*-*} $ts]} {
            set shell_ts [audit::date_to_ts $ts]
        } else {
            set shell_ts [audit::scan_int $ts]
        }
        if {$shell_ts ne "" && $shell_ts != 0 && $shell_ts < [expr {$since_ts - 86400}]} continue
        set reel_id [ig::dget $shell id ""]
        if {$reel_id eq ""} { set reel_id [ig::dget $shell reel_id ""] }
        if {$reel_id eq ""} { set reel_id [ig::dget $shell pk ""] }
        if {$reel_id eq ""} continue
        set rbody [api "/api/v1/archive/reel/seen_media/" --params "reel_ids=$reel_id" \
            --headers [ig::api_headers]]
        if {[catch {json::json2dict $rbody} reel_data]} continue
        if {[ig::dget $reel_data error ""] ne ""} continue
        set reels [ig::dget $reel_data reels {}]
        foreach {_ reel} $reels {
            foreach it [ig::dget $reel items {}] {
                if {[ig::dget $it taken_at 0] >= $since_ts} {
                    lappend items [audit::extract_story_item $it]
                }
            }
        }
    }
    return $items
}

# ---------------------------------------------------------------------------
# Heuristics.
# ---------------------------------------------------------------------------

proc audit::media_type_label {t} {
    switch -- $t {
        1 { return "image" }
        2 { return "video" }
        8 { return "carousel" }
        default { return "unknown_$t" }
    }
}

proc audit::classify_notif {text story_type} {
    set lc [string tolower $text]
    if {[string first "mentioned you in their story" $lc] >= 0 || \
        [string first "mentioned you in a story" $lc] >= 0} {
        return "story_mention"
    }
    if {[string first "tagged you in" $lc] >= 0 && \
        ([string first "photo" $lc] >= 0 || [string first "post" $lc] >= 0 || \
         [string first "reel" $lc] >= 0)} {
        return "post_tag"
    }
    return "skip"
}

# Pull reshare-relevant fields off a reel_media item (three reshare signals).
proc audit::extract_story_item {it} {
    set rs [ig::dget $it reshared_reel {}]
    if {![llength $rs]} { set rs [ig::dget $it reshared_reel_id {}] }
    if {[audit::dict_p $rs]} {
        set reshared_media_id [ig::dget $rs id ""]
        if {$reshared_media_id eq ""} { set reshared_media_id [ig::dget $rs media_id ""] }
        set ru [ig::dget $rs user {}]
        set reshared_owner_id [ig::dget $ru pk ""]
        if {$reshared_owner_id eq ""} { set reshared_owner_id [ig::dget $rs user_id ""] }
    } else {
        set reshared_media_id [expr {$rs ne "" ? $rs : ""}]
        set reshared_owner_id ""
    }
    set reel_mentions {}
    foreach m [ig::dget $it reel_mentions {}] {
        set u [ig::dget $m user {}]
        set un [ig::dget $u username ""]
        if {$un ne ""} {
            set uid [ig::dget $u pk ""]
            if {$uid eq ""} { set uid [ig::dget $u id ""] }
            lappend reel_mentions [dict create username $un user_id $uid]
        }
    }
    set ts [ig::dget $it taken_at 0]
    set media_id [ig::dget $it pk ""]
    if {$media_id eq ""} { set media_id [ig::dget $it id ""] }
    return [dict create \
        media_id $media_id \
        taken_at $ts \
        taken_at_iso [audit::iso_or_null $ts] \
        media_type [audit::media_type_label [ig::dget $it media_type ""]] \
        imported_taken_at [ig::dget_null $it imported_taken_at] \
        reshared_media_id $reshared_media_id \
        reshared_owner_id $reshared_owner_id \
        reel_mentions $reel_mentions]
}

# Return the own-story dict that reshares $tag, or "" when none.
#   A) reshared_media_id equals the tag's media_id, OR
#   B) any reel_mentions[].user_id equals the tag's actor/owner id AND the story
#      was posted within $window_seconds after the tag.
proc audit::match_reshare {tag own_stories {window_seconds 86400}} {
    set tag_media [audit::tag_field $tag media_id]
    set tag_actor [audit::tag_field $tag actor_id]
    if {$tag_actor eq ""} { set tag_actor [audit::tag_field $tag owner_id] }
    set tag_ts [audit::tag_field $tag timestamp]
    if {$tag_ts eq ""} { set tag_ts [audit::tag_field $tag taken_at] }
    if {$tag_ts eq ""} { set tag_ts 0 }
    foreach s $own_stories {
        if {$tag_media ne "" && [ig::dget $s reshared_media_id ""] eq $tag_media} {
            return $s
        }
        if {$tag_actor ne ""} {
            foreach m [ig::dget $s reel_mentions {}] {
                if {[ig::dget $m user_id ""] eq $tag_actor} {
                    set dt [expr {[ig::dget $s taken_at 0] - $tag_ts}]
                    if {$dt >= 0 && $dt <= $window_seconds} { return $s }
                }
            }
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# Small typed/scalar utilities mirroring Python's loose dict access.
# ---------------------------------------------------------------------------

proc audit::tag_field {tag key} {
    if {[catch {dict exists $tag $key} ok]} { return "" }
    if {$ok} {
        set v [dict get $tag $key]
        if {$v eq "\x00null"} { return "" }
        return $v
    }
    return ""
}
proc audit::scan_int {v} {
    if {[string is integer -strict $v]} { return $v }
    if {[string is double -strict $v]} { return [expr {int($v)}] }
    if {[regexp {^-?\d+} $v m]} { return $m }
    return 0
}
proc audit::scalar_p {v} {
    return [expr {![audit::dict_p $v]}]
}
# A heuristic for "this value is a JSON object/list" vs a scalar, used where the
# Python truthiness check on a possibly-nested field matters.
proc audit::dict_p {v} {
    if {![string is list -strict $v]} { return 0 }
    return [expr {[llength $v] >= 2 && [llength $v] % 2 == 0}]
}
proc audit::date_to_ts {s} {
    if {[catch {clock scan $s -format {%Y-%m-%d} -gmt 1} t]} { return 0 }
    return $t
}
proc audit::iso_or_null {ts} {
    if {$ts eq "" || $ts == 0} { return "\x00null" }
    return [ig::seconds_to_iso $ts]
}
proc audit::str_or_null {v} {
    if {$v eq "\x00null" || $v eq ""} { return "\x00null" }
    return $v
}

# ---------------------------------------------------------------------------
# The audit and its JSON rendering (json.dumps(indent=2, ensure_ascii=False)).
# ---------------------------------------------------------------------------

proc audit::run_audit {handle since_iso} {
    set since_ts [audit::date_to_ts $since_iso]
    if {$since_ts == 0} {
        return [ig::n_obj [list error [ig::n_str "Bad --since date: $since_iso. Use YYYY-MM-DD."]]]
    }

    set viewer [audit::viewer_identity]
    if {[ig::dget $viewer error ""] ne ""} {
        return [ig::n_obj [list error [ig::n_str "viewer identity: [dict get $viewer error]"]]]
    }

    set uid [ig::sv_resolve_user_id $handle]
    if {[ig::dget $uid error ""] ne ""} {
        return [audit::flat_error_node $uid]
    }
    set user_id $uid

    set tagged_posts [audit::fetch_tagged_feed $user_id $since_ts]

    set activity [audit::fetch_activity_inbox $since_ts]
    set activity_err [expr {[audit::dict_err $activity] ? [ig::dget $activity error ""] : ""}]
    set activity_list [expr {$activity_err eq "" ? $activity : {}}]

    set live_stories [audit::fetch_live_story_tray $user_id]
    set live_err [expr {[audit::dict_err $live_stories] ? [ig::dget $live_stories error ""] : ""}]
    set live_list [expr {$live_err eq "" ? $live_stories : {}}]

    set archive [audit::fetch_own_story_archive [dict get $viewer user_id] $user_id $since_ts]
    set archive_err [expr {[audit::dict_err $archive] ? [ig::dget $archive error ""] : ""}]
    set archive_list [expr {$archive_err eq "" ? $archive : {}}]

    set own_stories [concat $live_list $archive_list]

    set missed_post_reshares {}
    set matched_post_reshares {}
    foreach p $tagged_posts {
        set tag [dict create media_id [dict get $p media_id] \
            owner_id [dict get $p owner_id] taken_at [dict get $p taken_at]]
        if {[audit::match_reshare $tag $own_stories] ne ""} {
            lappend matched_post_reshares $p
        } else {
            lappend missed_post_reshares $p
        }
    }

    set missed_story_tags {}
    set matched_story_tags {}
    foreach n $activity_list {
        if {[dict get $n kind] ne "story_mention"} continue
        set tag [dict create media_id [dict get $n media_id] \
            actor_id [dict get $n actor_id] timestamp [dict get $n timestamp]]
        if {[audit::match_reshare $tag $own_stories] ne ""} {
            lappend matched_story_tags $n
        } else {
            lappend missed_story_tags $n
        }
    }

    set now_ts [clock seconds]
    set notes {}
    if {$archive_err eq "archive_not_accessible"} {
        lappend notes "Story archive unreadable: session is logged in as @[dict get $viewer username], not @$handle. Reshare evidence older than 24h is not visible. To get a complete audit, log in as @$handle and re-run."
    } elseif {$archive_err ne ""} {
        lappend notes "Story archive fetch failed: $archive_err"
    }
    if {$activity_err ne ""} {
        lappend notes "Activity inbox fetch failed: $activity_err"
    }
    lappend notes "Activity inbox typically retains story-mention notifications for roughly 14-30 days. Tags older than that window are unrecoverable and not counted in 'story_tags_*' figures."
    lappend notes "Customer-side stories expire 24h after posting. The audit can only confirm a tag existed if Instagram still shows the notification."

    set story_mentions_total 0
    foreach n $activity_list { if {[dict get $n kind] eq "story_mention"} { incr story_mentions_total } }

    return [ig::n_obj [list \
        target_handle [ig::n_str $handle] \
        target_user_id [ig::n_str $user_id] \
        viewer [ig::n_obj [list \
            username [ig::n_str [dict get $viewer username]] \
            user_id [ig::n_str [dict get $viewer user_id]]]] \
        since [ig::n_str $since_iso] \
        since_ts [ig::n_int $since_ts] \
        as_of_iso [ig::n_str [ig::seconds_to_iso $now_ts]] \
        coverage [ig::n_obj [list \
            tagged_posts [ig::n_str "full"] \
            story_tag_notifications [ig::n_str [expr {$activity_err eq "" ? "limited_to_instagram_retention" : "failed"}]] \
            own_live_stories [ig::n_str [expr {$live_err eq "" ? "ok" : "failed: $live_err"}]] \
            own_story_archive [ig::n_str [expr {$archive_err eq "" ? "ok" : $archive_err}]]]] \
        summary [ig::n_obj [list \
            tagged_posts_total [ig::n_int [llength $tagged_posts]] \
            tagged_posts_reshared [ig::n_int [llength $matched_post_reshares]] \
            tagged_posts_missed [ig::n_int [llength $missed_post_reshares]] \
            story_tags_in_activity_total [ig::n_int $story_mentions_total] \
            story_tags_reshared [ig::n_int [llength $matched_story_tags]] \
            story_tags_missed [ig::n_int [llength $missed_story_tags]]]] \
        missed_post_reshares [audit::post_arr $missed_post_reshares] \
        missed_story_tags [audit::notif_arr $missed_story_tags] \
        matched_post_reshares [audit::post_arr $matched_post_reshares] \
        matched_story_tags [audit::notif_arr $matched_story_tags] \
        notes [ig::n_strarr $notes]]]
}

proc audit::dict_err {v} {
    if {[catch {dict exists $v error} ok]} { return 0 }
    return $ok
}

proc audit::flat_error_node {d} {
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

# A tagged-post dict as a typed JSON node (Python field order/types).
proc audit::post_node {p} {
    return [ig::n_obj [list \
        media_id [ig::n_str [dict get $p media_id]] \
        shortcode [ig::n_str [dict get $p shortcode]] \
        taken_at [ig::n_int [dict get $p taken_at]] \
        taken_at_iso [audit::null_or_str [dict get $p taken_at_iso]] \
        owner_username [audit::null_or_str [dict get $p owner_username]] \
        owner_id [ig::n_str [dict get $p owner_id]] \
        media_type [ig::n_str [dict get $p media_type]] \
        url [audit::null_or_str [dict get $p url]] \
        caption [audit::null_or_str [dict get $p caption]]]]
}
proc audit::post_arr {lst} {
    set e {}
    foreach p $lst { lappend e [audit::post_node $p] }
    return [ig::n_arr $e]
}

# A notification dict as a typed JSON node.
proc audit::notif_node {n} {
    return [ig::n_obj [list \
        kind [ig::n_str [dict get $n kind]] \
        timestamp [ig::n_int [dict get $n timestamp]] \
        timestamp_iso [ig::n_str [dict get $n timestamp_iso]] \
        actor_username [audit::null_or_str [dict get $n actor_username]] \
        actor_id [ig::n_str [dict get $n actor_id]] \
        media_id [ig::n_str [dict get $n media_id]] \
        story_type [audit::null_or_scalar [dict get $n story_type]] \
        text [ig::n_str [dict get $n text]]]]
}
proc audit::notif_arr {lst} {
    set e {}
    foreach n $lst { lappend e [audit::notif_node $n] }
    return [ig::n_arr $e]
}

proc audit::null_or_str {v} {
    if {$v eq "\x00null"} { return [ig::n_null] }
    return [ig::n_str $v]
}
proc audit::null_or_scalar {v} {
    if {$v eq "\x00null"} { return [ig::n_null] }
    if {$v in {true false}} { return [ig::n_bool $v] }
    if {[string is integer -strict $v]} { return [ig::n_int $v] }
    return [ig::n_str $v]
}

# ---------------------------------------------------------------------------
# Serialiser entry.
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    if {![llength $skillArgs] || [lindex $skillArgs 0] ne "audit"} {
        emit [ig::jenc [ig::n_obj [list error [ig::n_str "Usage: instagram.com/audit-tag-reshares audit <handle> --since YYYY-MM-DD"]]]]
        return
    }
    set rest [lrange $skillArgs 1 end]
    set since ""
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --since { incr i; set since [lindex $rest $i] }
            --debug { }
            default { lappend positional $a }
        }
    }
    set handle [string trimleft [lindex $positional 0] @]
    if {$handle eq "" || $since eq ""} {
        emit [ig::jenc [ig::n_obj [list error [ig::n_str "Usage: instagram.com/audit-tag-reshares audit <handle> --since YYYY-MM-DD"]]]]
        return
    }

    nav "https://www.instagram.com/" --wait 3
    if {[dict get [state] terminal] ne ""} {
        emit [ig::jenc [ig::n_obj [list error [ig::n_str "Not logged in to Instagram ([dict get [state] terminal]). Log in via a Chrome-compatible browser first."]]]]
        return
    }

    emit [ig::jenc [audit::run_audit $handle $since]]
}
