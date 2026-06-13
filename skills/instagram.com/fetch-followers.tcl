#!/usr/bin/env tclsh
# fetch-followers: list a profile's followers or following set.
#
# Given a public handle, paginates the authenticated friendships API and
# emits one row per user. Works for the followers list and the following
# list (same endpoint shape, different path segment).
#
# Endpoints (called via fetch() from inside an authenticated CDP session):
#   /api/v1/friendships/<user_id>/followers/?count=N&max_id=...
#   /api/v1/friendships/<user_id>/following/?count=N&max_id=...
#
# Output: JSON to stdout by default, or CSV when --csv PATH is given.
#
# Per-entry fields:
#   user_id, username, full_name, is_verified, is_private,
#   has_default_avatar, profile_pic_url
#
# Invoked by reference through the serialiser (see SKILL.md §10):
#     browser-serialiser instagram.com/fetch-followers followers <handle> [--limit N]
#     browser-serialiser instagram.com/fetch-followers following <handle> [--limit N]
#
# The serialiser path (serialiser_run) drives the policed verbs; the friendships
# endpoint is a declared private endpoint (api), covered by the profile nav.

source [file dirname [info script]]/fetch-recent-posts.tcl

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

proc parse_user_row {u} {
    set profile_pic [ig::dget $u profile_pic_url ""]
    set has_anon [ig::truthy [ig::dget $u has_anonymous_profile_picture false]]
    set pk [ig::dget $u pk ""]
    if {$pk eq ""} { set pk [ig::dget $u id ""] }
    return [dict create \
        user_id $pk \
        username [ig::dget $u username ""] \
        full_name [ig::dget $u full_name ""] \
        is_verified [ig::truthy [ig::dget $u is_verified false]] \
        is_private [ig::truthy [ig::dget $u is_private false]] \
        has_default_avatar [has_default_avatar $profile_pic $has_anon] \
        profile_pic_url $profile_pic]
}

# Fetch one page of /api/v1/friendships/<user_id>/<kind>/. Returns the parsed
# dict (with users, big_list, next_max_id) or {error ...}.
proc fetch_friendships_page {c user_id kind {max_id ""} {count 25}} {
    if {$kind ni {followers following}} {
        return [dict create error "invalid kind: $kind"]
    }
    set parts [list "count=$count"]
    if {$max_id ne ""} { lappend parts "max_id=$max_id" }
    set qs [join $parts "&"]
    set js {
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const resp = await fetch('/api/v1/friendships/@UID@/@KIND@/?@QS@', {
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
    set js [string map [list @UID@ $user_id @KIND@ $kind @QS@ $qs] $js]
    return [ig::eval_js $c $js]
}

# Paginate the friendships endpoint. Returns {rows stop_reason} where stop_reason
# is one of "limit", "exhausted", "error:<detail>".
proc fetch_friendships_paginated {c user_id kind limit {pause_between 2.5}} {
    set rows {}
    set max_id ""
    set page_num 0
    while {[llength $rows] < $limit} {
        incr page_num
        set page [fetch_friendships_page $c $user_id $kind $max_id 25]
        if {[ig::dget $page error ""] ne ""} {
            puts stderr "Page $page_num fetch error: [dict get $page error]"
            return [list $rows "error:[dict get $page error]"]
        }
        set users [ig::dget $page users {}]
        if {![llength $users]} {
            puts stderr "Page $page_num returned no users; stopping."
            return [list $rows "exhausted"]
        }
        foreach u $users {
            lappend rows [parse_user_row $u]
            if {[llength $rows] >= $limit} { break }
        }
        puts stderr "Page $page_num: [llength $users] users (cumulative [llength $rows])"
        if {[llength $rows] >= $limit} { return [list $rows "limit"] }
        set next_max [ig::dget $page next_max_id ""]
        if {$next_max eq ""} { return [list $rows "exhausted"] }
        set max_id $next_max
        after [expr {int($pause_between * 1000)}]
    }
    return [list $rows "limit"]
}

# Write rows to a CSV file. Field values are quoted per RFC 4180 when they
# contain a comma, quote, or newline; mirrors Python csv.DictWriter defaults.
proc write_csv {path rows} {
    set fieldnames {user_id username full_name is_verified is_private has_default_avatar profile_pic_url}
    set f [open $path w]
    fconfigure $f -encoding utf-8 -translation crlf
    puts $f [csv_join $fieldnames]
    foreach r $rows {
        set vals {}
        foreach fn $fieldnames {
            set v [dict get $r $fn]
            # Booleans render as Python's True/False in csv output.
            if {$fn in {is_verified is_private has_default_avatar}} {
                set v [expr {$v ? "True" : "False"}]
            }
            lappend vals $v
        }
        puts $f [csv_join $vals]
    }
    close $f
}

proc csv_field {v} {
    # Quote only when the field carries the delimiter, a quote, or a line break
    # (RFC 4180 / Python csv QUOTE_MINIMAL).
    if {[string first "," $v] >= 0 || [string first "\"" $v] >= 0 || \
        [string first "\n" $v] >= 0 || [string first "\r" $v] >= 0} {
        return "\"[string map [list "\"" "\"\""] $v]\""
    }
    return $v
}
proc csv_join {vals} {
    set out {}
    foreach v $vals { lappend out [csv_field $v] }
    return [join $out ,]
}

proc cmd_friendships {c handle kind limit csv_path} {
    set uid [ig::resolve_user_id $c $handle]
    if {[ig::dget $uid error ""] ne ""} { return $uid }
    set user_id $uid

    after 2000
    lassign [fetch_friendships_paginated $c $user_id $kind $limit] rows stop_reason

    set result [dict create \
        handle $handle user_id $user_id kind $kind \
        count_returned [llength $rows] \
        limit_requested $limit \
        stop_reason $stop_reason \
        rows $rows]
    if {$csv_path ne ""} {
        write_csv $csv_path $rows
        dict set result csv_path [file normalize $csv_path]
        dict set result rows __omit__
    }
    return $result
}

# Render the friendships result as JSON (indent=2). When csv_path is present the
# `users` array is omitted (rows == __omit__); otherwise rows are emitted as a
# `users` array of user objects, matching the Python output.
proc render_friendships {result} {
    set rows [dict get $result rows]
    set pairs {}
    lappend pairs handle [ig::n_str [dict get $result handle]]
    lappend pairs user_id [ig::n_str [dict get $result user_id]]
    lappend pairs kind [ig::n_str [dict get $result kind]]
    lappend pairs count_returned [ig::n_int [dict get $result count_returned]]
    lappend pairs limit_requested [ig::n_int [dict get $result limit_requested]]
    lappend pairs stop_reason [ig::n_str [dict get $result stop_reason]]
    if {[dict exists $result csv_path]} {
        lappend pairs csv_path [ig::n_str [dict get $result csv_path]]
    } else {
        set userElems {}
        foreach r $rows { lappend userElems [user_node $r] }
        lappend pairs users [ig::n_arr $userElems]
    }
    return [ig::jenc [ig::n_obj $pairs]]
}

proc user_node {r} {
    return [ig::n_obj [list \
        user_id [ig::n_str [dict get $r user_id]] \
        username [ig::n_str [dict get $r username]] \
        full_name [ig::n_str [dict get $r full_name]] \
        is_verified [ig::n_bool [dict get $r is_verified]] \
        is_private [ig::n_bool [dict get $r is_private]] \
        has_default_avatar [ig::n_bool [dict get $r has_default_avatar]] \
        profile_pic_url [ig::n_str [dict get $r profile_pic_url]]]]
}

# ---------------------------------------------------------------------------
# Serialiser entry: the policed-surface path. nav to the profile (the covering
# view for the friendships api), then page the declared friendships endpoint via
# the policed `api` verb. Parsing/rendering reuse the identical helpers above, so
# the byte-output matches the legacy path for the same response.
# ---------------------------------------------------------------------------

# Page the friendships endpoint over the policed api verb (the harness paces and
# bounds it). Returns {rows stop_reason}, identical in shape to the legacy
# paginator, so render_friendships renders byte-identically.
proc sv_fetch_friendships {user_id kind limit} {
    set rows {}
    set max_id ""
    set page_num 0
    while {[llength $rows] < $limit} {
        incr page_num
        set params "count=25"
        if {$max_id ne ""} { append params "&max_id=$max_id" }
        set body [api "/api/v1/friendships/$user_id/$kind/" \
            --params $params --headers [ig::api_headers]]
        if {[catch {json::json2dict $body} page]} {
            puts stderr "Page $page_num: response was not JSON; stopping."
            return [list $rows "error:not-json"]
        }
        set users [ig::dget $page users {}]
        if {![llength $users]} {
            puts stderr "Page $page_num returned no users; stopping."
            return [list $rows "exhausted"]
        }
        foreach u $users {
            lappend rows [parse_user_row $u]
            if {[llength $rows] >= $limit} { break }
        }
        puts stderr "Page $page_num: [llength $users] users (cumulative [llength $rows])"
        if {[llength $rows] >= $limit} { return [list $rows "limit"] }
        set next_max [ig::dget $page next_max_id ""]
        if {$next_max eq ""} { return [list $rows "exhausted"] }
        set max_id $next_max
    }
    return [list $rows "limit"]
}

proc serialiser_run {skillArgs} {
    set command [lindex $skillArgs 0]
    if {$command ni {followers following}} {
        emit [ig::render_flat [dict create error "Usage: instagram.com/fetch-followers followers|following <handle> \[--limit N\]"]]
        return
    }
    set rest [lrange $skillArgs 1 end]
    set limit 500
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $rest $i] }
            default { lappend positional $a }
        }
    }
    set handle [lindex $positional 0]
    if {$handle eq ""} {
        emit [ig::render_flat [dict create error "No handle. Usage: instagram.com/fetch-followers followers|following <handle> \[--limit N\]"]]
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
    set user_id $uid

    lassign [sv_fetch_friendships $user_id $command $limit] rows stop_reason
    set result [dict create \
        handle $handle user_id $user_id kind $command \
        count_returned [llength $rows] \
        limit_requested $limit \
        stop_reason $stop_reason \
        rows $rows]
    emit [render_friendships $result]
}

proc main {} {
    global argv
    if {![llength $argv]} {
        puts "Usage: fetch-followers.tcl followers|following <handle> \[--limit N\] \[--csv PATH\]"
        exit 1
    }
    set command [lindex $argv 0]
    if {$command ni {followers following}} {
        puts "Usage: fetch-followers.tcl followers|following <handle> \[--limit N\] \[--csv PATH\]"
        exit 1
    }
    set rest [lrange $argv 1 end]
    set limit 500
    set csv_path ""
    set positional {}
    for {set i 0} {$i < [llength $rest]} {incr i} {
        set a [lindex $rest $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $rest $i] }
            --csv { incr i; set csv_path [lindex $rest $i] }
            default { lappend positional $a }
        }
    }
    set handle [lindex $positional 0]

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh fetch-followers.tcl ..."
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
    set result [cmd_friendships $c $handle $command $limit $csv_path]
    if {[dict exists $result rows]} {
        puts [render_friendships $result]
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
