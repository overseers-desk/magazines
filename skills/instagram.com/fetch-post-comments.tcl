#!/usr/bin/env tclsh
# fetch-post-comments: read the comment list on an Instagram post.
#
# Given a shortcode (e.g. DXsPrn5AvNH) or a full post_id from the feed
# API (e.g. 3893054209352269936_1746949701), this script calls the
# internal `/api/v1/media/<media_id>/comments/` endpoint via fetch()
# from inside an authenticated CDP session and returns one row per
# comment with the four free significance signals:
#
#   - username, full_name, is_verified
#   - has_default_avatar (true when profile_pic_url is the default ghost)
#   - text, text_length_words
#   - comment_like_count
#
# Shortcode-to-media-id conversion is local (base64 decoding of the
# shortcode alphabet), so no extra fetch is needed to resolve.
#
# Invoked by reference through the serialiser (see SKILL.md §8):
#     browser-serialiser instagram.com/fetch-post-comments comments <shortcode|post_id|media_id> [--limit N]
#
# The serialiser path (serialiser_run) navigates to the post permalink (the
# covering view) and reads the declared comments endpoint via the policed `api`
# verb. Parsing/rendering reuse the identical helpers, so output is byte-faithful.

source [file dirname [info script]]/fetch-recent-posts.tcl

# ---------------------------------------------------------------------------
# Shortcode <-> media_id (Instagram's base64 encoding; pure local conversion).
# Tcl's expr handles arbitrary-precision integers, so the bignum math is exact.
# ---------------------------------------------------------------------------

set SHORTCODE_ALPHABET "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

proc shortcode_to_media_id {shortcode} {
    global SHORTCODE_ALPHABET
    set result 0
    foreach ch [split $shortcode ""] {
        set idx [string first $ch $SHORTCODE_ALPHABET]
        if {$idx < 0} {
            error "shortcode contains invalid char: $ch"
        }
        set result [expr {$result * 64 + $idx}]
    }
    return $result
}

# Accept a shortcode, a full post_id (id_userid), or a bare media_id. Return the
# bare media_id string. Raises on a malformed post_id. Digit checks use a regex
# (mirroring Python str.isdigit) so 19-digit media ids are not truncated the way
# Tcl's native-int `string is integer` would.
proc is_digits {s} {
    return [expr {$s ne "" && [regexp {^\d+$} $s]}]
}
proc resolve_post_ref {post_ref} {
    if {[string first "_" $post_ref] >= 0} {
        set head [lindex [split $post_ref "_"] 0]
        if {[is_digits $head]} { return $head }
        error "post_ref looks like post_id but head is not numeric: $post_ref"
    }
    if {[is_digits $post_ref]} { return $post_ref }
    return [shortcode_to_media_id $post_ref]
}

# ---------------------------------------------------------------------------
# Comment parsing.
# ---------------------------------------------------------------------------

set DEFAULT_AVATAR_HINTS {
    44884218_345707102882519_2446069589734326272_n
    instagram_default_avatar
    anonymous_user
}

proc has_default_avatar {profile_pic_url has_anon_flag} {
    global DEFAULT_AVATAR_HINTS
    if {$has_anon_flag} { return 1 }
    if {$profile_pic_url eq ""} { return 1 }
    foreach h $DEFAULT_AVATAR_HINTS {
        if {[string first $h $profile_pic_url] >= 0} { return 1 }
    }
    return 0
}

proc word_count {text} {
    if {$text eq ""} { return 0 }
    return [llength [regexp -all -inline {\w+} $text]]
}

# Convert the raw comments API response into structured comment rows.
proc parse_comments_response {data} {
    set comments [ig::dget $data comments {}]
    set rows {}
    foreach c $comments {
        set user [ig::dget $c user {}]
        set profile_pic [ig::dget $user profile_pic_url ""]
        set has_anon [ig::truthy [ig::dget $user has_anonymous_profile_picture false]]
        set text [ig::dget $c text ""]
        set pk [ig::dget $c pk ""]
        if {$pk eq ""} { set pk [ig::dget $c id ""] }
        set created [ig::dget $c created_at_utc ""]
        if {$created eq ""} { set created [ig::dget $c created_at 0] }
        lappend rows [dict create \
            username [ig::dget $user username ""] \
            full_name [ig::dget $user full_name ""] \
            is_verified [ig::truthy [ig::dget $user is_verified false]] \
            has_default_avatar [has_default_avatar $profile_pic $has_anon] \
            text $text \
            text_length_words [word_count $text] \
            comment_like_count [comment_like_count $c] \
            created_at $created \
            comment_id $pk]
    }
    return $rows
}

proc comment_like_count {c} {
    set v [ig::dget $c comment_like_count 0]
    if {$v eq "" || $v eq "null"} { return 0 }
    if {[string is integer -strict $v]} { return $v }
    return 0
}

# Fetch first-page comments for a single post. Returns the result dict.
proc cmd_comments {c post_ref limit} {
    if {[catch {resolve_post_ref $post_ref} media_id]} {
        return [dict create error $media_id]
    }

    set js {
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const resp = await fetch('/api/v1/media/@MID@/comments/?can_support_threading=true&permalink_enabled=false', {
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
    set js [string map [list @MID@ $media_id] $js]
    set result [ig::eval_js $c $js]
    if {[ig::dget $result error ""] ne ""} { return $result }

    set comments [parse_comments_response $result]
    set total [ig::dget $result comment_count ""]
    if {$total eq "" || $total eq "null"} { set total [llength $comments] }
    if {[llength $comments] > $limit} {
        set comments [lrange $comments 0 [expr {$limit - 1}]]
    }
    return [dict create \
        post_ref $post_ref \
        media_id $media_id \
        comment_count_total $total \
        comment_count_returned [llength $comments] \
        has_more [ig::truthy [ig::dget $result has_more_comments false]] \
        comments $comments]
}

# Render a comment row as a typed JSON node.
proc comment_node {r} {
    return [ig::n_obj [list \
        username [ig::n_str [dict get $r username]] \
        full_name [ig::n_str [dict get $r full_name]] \
        is_verified [ig::n_bool [dict get $r is_verified]] \
        has_default_avatar [ig::n_bool [dict get $r has_default_avatar]] \
        text [ig::n_str [dict get $r text]] \
        text_length_words [ig::n_int [dict get $r text_length_words]] \
        comment_like_count [ig::n_int [dict get $r comment_like_count]] \
        created_at [ig::n_int [dict get $r created_at]] \
        comment_id [ig::n_str [dict get $r comment_id]]]]
}

proc render_comments {result} {
    set commentElems {}
    foreach r [dict get $result comments] { lappend commentElems [comment_node $r] }
    return [ig::jenc [ig::n_obj [list \
        post_ref [ig::n_str [dict get $result post_ref]] \
        media_id [ig::n_str [dict get $result media_id]] \
        comment_count_total [ig::n_int [dict get $result comment_count_total]] \
        comment_count_returned [ig::n_int [dict get $result comment_count_returned]] \
        has_more [ig::n_bool [dict get $result has_more]] \
        comments [ig::n_arr $commentElems]]]]
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the post permalink (the covering view), then read the
# declared comments endpoint via the policed `api` verb. The shortcode-to-media-id
# resolution, parse, and render reuse the identical procs above.
# ---------------------------------------------------------------------------

# Build the post permalink for the covering nav. A shortcode gives the natural
# /p/<code>/ page; a bare post_id/media_id has no permalink we can form locally,
# so the IG home is the covering view in that case.
proc sv_cover_url {post_ref} {
    if {[string first "_" $post_ref] < 0 && ![is_digits $post_ref]} {
        return "https://www.instagram.com/p/$post_ref/"
    }
    return "https://www.instagram.com/"
}

# Fetch and parse first-page comments over the policed surface. Returns the same
# result dict cmd_comments returns, so render_comments renders byte-identically.
proc sv_cmd_comments {post_ref limit} {
    if {[catch {resolve_post_ref $post_ref} media_id]} {
        return [dict create error $media_id]
    }
    set body [api "/api/v1/media/$media_id/comments/" \
        --params "can_support_threading=true&permalink_enabled=false" \
        --headers [ig::api_headers]]
    if {[catch {json::json2dict $body} result]} {
        return [dict create error "comments response was not JSON"]
    }
    if {[ig::dget $result error ""] ne ""} { return $result }

    set comments [parse_comments_response $result]
    set total [ig::dget $result comment_count ""]
    if {$total eq "" || $total eq "null"} { set total [llength $comments] }
    if {[llength $comments] > $limit} {
        set comments [lrange $comments 0 [expr {$limit - 1}]]
    }
    return [dict create \
        post_ref $post_ref \
        media_id $media_id \
        comment_count_total $total \
        comment_count_returned [llength $comments] \
        has_more [ig::truthy [ig::dget $result has_more_comments false]] \
        comments $comments]
}

proc serialiser_run {skillArgs} {
    if {![llength $skillArgs] || [lindex $skillArgs 0] ne "comments"} {
        emit [ig::render_flat [dict create error "Usage: instagram.com/fetch-post-comments comments <shortcode|post_id|media_id> \[--limit N\]"]]
        return
    }
    set rest [lrange $skillArgs 1 end]
    set limit 50
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $rest $i] }
            default { lappend positional $a }
        }
    }
    set post_ref [lindex $positional 0]
    if {$post_ref eq ""} {
        emit [ig::render_flat [dict create error "No post reference. Usage: instagram.com/fetch-post-comments comments <shortcode|post_id|media_id> \[--limit N\]"]]
        return
    }

    nav [sv_cover_url $post_ref] --wait 4
    if {[dict get [state] terminal] ne ""} {
        emit [ig::render_flat [dict create error "Not logged in to Instagram ([dict get [state] terminal]). Log in via a Chrome-compatible browser first."]]
        return
    }

    set result [sv_cmd_comments $post_ref $limit]
    if {[dict exists $result comments]} {
        emit [render_comments $result]
    } else {
        emit [ig::render_flat $result]
    }
}

proc main {} {
    global argv
    if {![llength $argv] || [lindex $argv 0] ne "comments"} {
        puts "Usage: fetch-post-comments.tcl comments <shortcode|post_id|media_id> \[--limit N\]"
        exit 1
    }
    set rest [lrange $argv 1 end]
    set limit 50
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $rest $i] }
            default { lappend positional $a }
        }
    }
    set post_ref [lindex $positional 0]

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh fetch-post-comments.tcl ..."
        exit 1
    }

    set c [cdp::connect]
    $c cdp Page.enable
    ig::navigate_and_wait $c "https://www.instagram.com/" 3

    if {![ig::check_logged_in $c]} {
        puts [ig::render_flat [dict create error "Not logged in to Instagram. Log in via Chromium first."]]
        exit 1
    }

    set result [cmd_comments $c $post_ref $limit]
    if {[dict exists $result comments]} {
        puts [render_comments $result]
    } else {
        puts [ig::render_flat $result]
    }
    $c close
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
