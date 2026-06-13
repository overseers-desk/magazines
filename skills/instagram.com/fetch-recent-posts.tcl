#!/usr/bin/env tclsh
# Instagram recent posts fetcher.
#
# Given a public handle, returns the last N posts (default 12) with:
# caption, like count, comment count, posted timestamp (ISO 8601), post type
# (image/carousel/reel), is_paid_partnership flag, location tag, hashtags
# extracted from caption, and mentioned handles.
#
# Usage:
#     not-google-chrome --cdp -- tclsh fetch-recent-posts.tcl posts <handle> [--limit N]
#
# This file is the shared IG library: every sibling sources it for the ig::
# helpers (JSON eval, user-id resolution, feed paging, the typed-JSON encoder).
# The serialiser path of each sibling reuses ig::sv_resolve_user_id /
# ig::sv_fetch_feed / ig::parse_media_items so byte-output matches this keystone.

package require json

# Legacy CDP engine, kept for the direct-tclsh path (ig::main and each sibling's
# own main, which call cdp::connect when run as `tclsh X.tcl ...` outside the
# serialiser). Sourced only when not already present, so loading this file under
# the serialiser harness (where the policed verbs replace raw CDP) is a no-op
# rather than a re-definition. The harness path uses serialiser_run.
if {![namespace exists cdp]} {
    catch { source [file dirname [info script]]/../lib/cdp-client.tcl }
}

namespace eval ig { variable LastRaw "" }

# ---------------------------------------------------------------------------
# CDP plumbing built on the shared cdp::Client. eval_js mirrors the Python
# helper: run Runtime.evaluate (returnByValue, awaitPromise), then return the
# JSON-parsed value, or {error ...} on a JS exception / null, or {raw <value>}
# when the returned string is not JSON.
# ---------------------------------------------------------------------------

proc ig::eval_js {c expression} {
    variable LastRaw
    set LastRaw ""
    set resp [$c cdp Runtime.evaluate [dict create \
        expression $expression awaitPromise true returnByValue true]]
    set result [dict get $resp result]
    if {[dict exists $result exceptionDetails]} {
        set exc [dict get $result exceptionDetails]
        set text "JS exception"
        if {[dict exists $exc text]} { set text [dict get $exc text] }
        return [dict create error $text]
    }
    if {![dict exists $result result value]} {
        return [dict create error "No value returned from JS"]
    }
    set val [dict get $result result value]
    set LastRaw $val
    if {[catch {json::json2dict $val} parsed]} {
        return [dict create raw $val]
    }
    return $parsed
}

# The raw JSON string from the most recent eval_js call, before parsing.
proc ig::last_raw {} {
    variable LastRaw
    return $LastRaw
}

proc ig::navigate_and_wait {c url {wait_seconds 5}} {
    $c cdp Page.navigate [dict create url $url]
    after [expr {int($wait_seconds * 1000)}]
}

proc ig::check_logged_in {c} {
    set title [ig::scalar [ig::eval_js $c "document.title"]]
    if {[string first "Log in" $title] >= 0 || \
        [string first "Login" $title] >= 0 || \
        [string first "Sign in" $title] >= 0} {
        return 0
    }
    set url [ig::scalar [ig::eval_js $c "window.location.href"]]
    if {[string first "accounts/login" $url] >= 0} { return 0 }
    return 1
}

# Extract a plain scalar string from an eval result. document.title and
# window.location.href are bare strings, so the helper returns {raw <s>}.
proc ig::scalar {r} {
    if {[dict exists $r raw]} { return [dict get $r raw] }
    if {[dict exists $r error]} { return "" }
    return $r
}

# ---------------------------------------------------------------------------
# Field helpers.
# ---------------------------------------------------------------------------

proc ig::dget {d key {default ""}} {
    if {[catch {dict exists $d $key} ok]} { return $default }
    if {$ok} { return [dict get $d $key] }
    return $default
}

proc ig::seconds_to_iso {ts} {
    if {[catch {clock format [expr {int($ts)}] -format {%Y-%m-%dT%H:%M:%S+00:00} -gmt 1} out]} {
        return $ts
    }
    return $out
}

# Dedupe-preserving #hashtag extraction. Tcl \w is Unicode-aware, matching
# Python re's default \w behaviour.
proc ig::extract_hashtags {caption} {
    return [ig::_extract_tagged $caption {#(\w+)}]
}
proc ig::extract_mentions {caption} {
    return [ig::_extract_tagged $caption {@(\w+)}]
}
proc ig::_extract_tagged {caption pat} {
    if {$caption eq ""} { return {} }
    set tokens [regexp -all -inline $pat $caption]
    set seen {}
    set res {}
    foreach {full grp} $tokens {
        if {![dict exists $seen $grp]} {
            dict set seen $grp 1
            lappend res $grp
        }
    }
    return $res
}

proc ig::post_type {item} {
    set media_type [ig::dget $item media_type 0]
    set product_type [ig::dget $item product_type ""]
    if {$media_type == 1} { return "image" }
    if {$media_type == 2} {
        if {$product_type in {clips reels}} { return "reel" }
        return "video"
    }
    if {$media_type == 8} { return "carousel" }
    return "unknown"
}

# Pull tagged usernames from the "tag people" feature; aggregate carousel slides.
proc ig::extract_usertags {item} {
    set handles {}
    set seen {}
    ig::_pull_usertags $item seen handles
    foreach slide [ig::dget $item carousel_media {}] {
        ig::_pull_usertags $slide seen handles
    }
    return $handles
}
proc ig::_pull_usertags {node seenVar handlesVar} {
    upvar 1 $seenVar seen $handlesVar handles
    set ut [ig::dget [ig::dget $node usertags {}] in {}]
    foreach entry $ut {
        set u [ig::dget [ig::dget $entry user {}] username ""]
        if {$u ne "" && ![dict exists $seen $u]} {
            dict set seen $u 1
            lappend handles $u
        }
    }
}

proc ig::extract_coauthors {item} {
    set handles {}
    foreach c [ig::dget $item coauthor_producers {}] {
        set u [ig::dget $c username ""]
        if {$u ne ""} { lappend handles $u }
    }
    return $handles
}

proc ig::extract_sponsors {item} {
    set handles {}
    foreach s [ig::dget $item sponsor_tags {}] {
        set u [ig::dget [ig::dget $s sponsor {}] username ""]
        if {$u ne ""} { lappend handles $u }
    }
    return $handles
}

# A value that is JSON-null when absent (mirrors Python item.get(x) -> None).
# Returns the sentinel \x00null so the JSON emitter renders it as null.
proc ig::dget_null {d key} {
    if {[catch {dict exists $d $key} ok]} { return "\x00null" }
    if {$ok} {
        set v [dict get $d $key]
        if {$v eq "null"} { return "\x00null" }
        return $v
    }
    return "\x00null"
}

# Map a JSON bool / truthy value to 0/1 the way Python bool() would.
proc ig::truthy {v} {
    if {$v eq "true"} { return 1 }
    if {$v eq "false" || $v eq "" || $v eq "0" || $v eq "null"} { return 0 }
    return 1
}

# Convert raw media items into structured post dicts.
proc ig::parse_media_items {items} {
    set posts {}
    foreach item $items {
        set caption_text [ig::dget [ig::dget $item caption {}] text ""]
        set location_name [ig::dget [ig::dget $item location {}] name ""]
        set code [ig::dget $item code ""]

        set post [dict create]
        dict set post post_id [ig::dget $item id ""]
        dict set post shortcode $code
        dict set post url "https://www.instagram.com/p/$code/"
        dict set post post_type [ig::post_type $item]
        dict set post taken_at_iso [ig::seconds_to_iso [ig::dget $item taken_at 0]]
        dict set post like_count [ig::dget $item like_count 0]
        dict set post comment_count [ig::dget $item comment_count 0]
        dict set post play_count [ig::dget_null $item play_count]
        dict set post ig_play_count [ig::dget_null $item ig_play_count]
        dict set post fb_play_count [ig::dget_null $item fb_play_count]
        dict set post view_count [ig::dget_null $item view_count]
        dict set post media_repost_count [ig::dget_null $item media_repost_count]
        dict set post fb_like_count [ig::dget_null $item fb_like_count]
        dict set post fb_comment_count [ig::dget_null $item fb_comment_count]
        dict set post video_duration [ig::dget_null $item video_duration]
        dict set post like_and_view_counts_disabled \
            [ig::truthy [ig::dget $item like_and_view_counts_disabled false]]
        dict set post caption $caption_text
        dict set post hashtags [ig::extract_hashtags $caption_text]
        dict set post mentions [ig::extract_mentions $caption_text]
        dict set post tagged_users [ig::extract_usertags $item]
        dict set post coauthors [ig::extract_coauthors $item]
        dict set post sponsors [ig::extract_sponsors $item]
        dict set post is_paid_partnership \
            [ig::truthy [ig::dget $item is_paid_partnership false]]
        dict set post location $location_name
        lappend posts $post
    }
    return $posts
}

# ---------------------------------------------------------------------------
# Profile / feed.
# ---------------------------------------------------------------------------

# Navigate to a profile page and resolve the handle to its numeric user_id.
# Returns the user_id string, or a dict {error ...} on failure.
proc ig::resolve_user_id {c handle} {
    set profile_url "https://www.instagram.com/$handle/"
    puts stderr "Navigating to $profile_url..."
    $c cdp Page.navigate [dict create url $profile_url]
    after 4000

    set current_url [ig::scalar [ig::eval_js $c "window.location.href"]]
    if {[string first "accounts/login" $current_url] >= 0} {
        return [dict create error "Redirected to login. Session may be expired or rate-limited."]
    }

    set js_extract_id {
    (async () => {
        const scripts = Array.from(document.querySelectorAll('script:not([src])'));
        for (const s of scripts) {
            const t = s.textContent || '';
            const m = t.match(/"user_id"\s*:\s*"(\d+)"/);
            if (m) return JSON.stringify({user_id: m[1]});
            const m2 = t.match(/"id"\s*:\s*"(\d+)".*?"is_private"/s);
            if (m2) return JSON.stringify({user_id: m2[1]});
        }
        try {
            const sd = window._sharedData;
            if (sd) {
                const uid = sd?.entry_data?.ProfilePage?.[0]?.graphql?.user?.id;
                if (uid) return JSON.stringify({user_id: uid});
            }
        } catch(e) {}
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const infoResp = await fetch('/api/v1/users/web_profile_info/?username=' + encodeURIComponent(location.pathname.replace(/\//g, '')), {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (infoResp.ok) {
            const info = await infoResp.json();
            const uid = info?.data?.user?.id;
            if (uid) return JSON.stringify({user_id: uid, source: 'web_profile_info'});
        }
        return JSON.stringify({error: 'user_id not found'});
    })()
    }
    set id_result [ig::eval_js $c $js_extract_id]
    if {[ig::dget $id_result user_id ""] ne ""} {
        return [dict get $id_result user_id]
    }
    return [dict create error "Could not determine user_id for @$handle" detail $id_result]
}

# Fetch one page of /api/v1/feed/user/<user_id>/. Returns the parsed dict (with
# items, more_available, next_max_id) or {error ...}.
proc ig::fetch_user_feed_page {c user_id {max_id ""} {count 12}} {
    set params_parts [list "count=$count"]
    if {$max_id ne ""} { lappend params_parts "max_id=$max_id" }
    set params_str [join $params_parts "&"]
    set js {
    (async () => {
        const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
        const resp = await fetch('/api/v1/feed/user/@USERID@/?@PARAMS@', {
            credentials: 'include',
            headers: {
                'X-IG-App-ID': '936619743392459',
                'X-CSRFToken': csrf,
                'X-Requested-With': 'XMLHttpRequest',
            }
        });
        if (!resp.ok) return JSON.stringify({error: 'HTTP ' + resp.status});
        return JSON.stringify(await resp.json());
    })()
    }
    set js [string map [list @USERID@ $user_id @PARAMS@ $params_str] $js]
    return [ig::eval_js $c $js]
}

# Paginate the user feed until limit items collected or more_available=false.
# When rawVar is given, it is filled with a list of byte-faithful per-page
# items-array JSON strings, so --raw-out can reconstruct the unparsed feed bytes.
proc ig::fetch_user_feed_paginated {c user_id limit {pause_between 2} {rawVar ""}} {
    if {$rawVar ne ""} { upvar 1 $rawVar rawpages }
    set rawpages {}
    set items {}
    set max_id ""
    set page_num 0
    while {[llength $items] < $limit} {
        incr page_num
        set page [ig::fetch_user_feed_page $c $user_id $max_id 12]
        set raw_page [ig::last_raw]
        if {[ig::dget $page error ""] ne ""} {
            puts stderr "Page $page_num fetch error: [dict get $page error]"
            break
        }
        set page_items [ig::dget $page items {}]
        if {![llength $page_items]} {
            puts stderr "Page $page_num returned no items; stopping."
            break
        }
        foreach it $page_items { lappend items $it }
        if {$rawVar ne ""} {
            lappend rawpages [ig::extract_json_array_after_key $raw_page items]
        }
        puts stderr "Page $page_num: [llength $page_items] items (cumulative [llength $items])"
        if {[ig::dget $page more_available false] ne "true"} { break }
        set max_id [ig::dget $page next_max_id ""]
        if {$max_id eq ""} { break }
        if {[llength $items] >= $limit} { break }
        after [expr {int($pause_between * 1000)}]
    }
    if {[llength $items] > $limit} {
        set items [lrange $items 0 [expr {$limit - 1}]]
    }
    return $items
}

# Fetch recent posts for a handle. Returns the result dict.
proc ig::cmd_posts {c handle limit {raw_out ""}} {
    set uid [ig::resolve_user_id $c $handle]
    if {[ig::dget $uid error ""] ne ""} { return $uid }
    set user_id $uid

    after 2000
    if {$raw_out ne ""} {
        set items [ig::fetch_user_feed_paginated $c $user_id $limit 2 rawpages]
        if {[catch {ig::write_raw_out $raw_out $handle $user_id $rawpages $limit} err]} {
            puts stderr "Failed to write --raw-out $raw_out: $err"
        } else {
            puts stderr "Raw feed items written to $raw_out"
        }
    } else {
        set items [ig::fetch_user_feed_paginated $c $user_id $limit]
    }
    if {![llength $items]} {
        return [dict create handle $handle user_id $user_id post_count 0 \
            note "Feed returned no items. Account may be private or feed empty." \
            posts {}]
    }
    set posts [ig::parse_media_items $items]
    return [dict create handle $handle user_id $user_id \
        post_count [llength $posts] posts $posts]
}

# ---------------------------------------------------------------------------
# Byte-faithful JSON-array extraction/splitting for --raw-out.
# ---------------------------------------------------------------------------

# Extract the JSON array text following "<key>": in a JSON document, by a
# balanced-bracket scan from the opening '['. Returns the literal substring.
proc ig::extract_json_array_after_key {json key} {
    set idx [string first "\"$key\"" $json]
    if {$idx < 0} { return "\[\]" }
    set rel [string first "\[" [string range $json $idx end]]
    if {$rel < 0} { return "\[\]" }
    set start [expr {$idx + $rel}]
    set depth 0; set instr 0; set esc 0
    set n [string length $json]
    for {set i $start} {$i < $n} {incr i} {
        set ch [string index $json $i]
        if {$instr} {
            if {$esc} { set esc 0 } elseif {$ch eq "\\"} { set esc 1 } elseif {$ch eq "\""} { set instr 0 }
            continue
        }
        switch -- $ch {
            "\"" { set instr 1 }
            "\[" { incr depth }
            "\]" { incr depth -1; if {$depth == 0} { return [string range $json $start $i] } }
        }
    }
    return "\[\]"
}

# Split a top-level JSON array string into its element substrings (byte-faithful).
proc ig::split_json_array {arr} {
    set arr [string trim $arr]
    if {[string index $arr 0] ne "\["} { return {} }
    set n [string length $arr]
    set depth 0; set instr 0; set esc 0
    set elems {}; set cur ""
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $arr $i]
        if {$instr} {
            append cur $ch
            if {$esc} { set esc 0 } elseif {$ch eq "\\"} { set esc 1 } elseif {$ch eq "\""} { set instr 0 }
            continue
        }
        switch -- $ch {
            "\[" { incr depth; if {$depth == 1} { continue }; append cur $ch }
            "\]" {
                incr depth -1
                if {$depth == 0} {
                    set t [string trim $cur]
                    if {$t ne ""} { lappend elems $t }
                    break
                }
                append cur $ch
            }
            "\{" { incr depth; append cur $ch }
            "\}" { incr depth -1; append cur $ch }
            "," {
                if {$depth == 1} {
                    set t [string trim $cur]
                    if {$t ne ""} { lappend elems $t }
                    set cur ""
                } else { append cur $ch }
            }
            "\"" { set instr 1; append cur $ch }
            default { append cur $ch }
        }
    }
    return $elems
}

# Write the --raw-out file: {handle, user_id, items: [...]} with the items
# preserved as the byte-faithful feed-API JSON captured during pagination.
proc ig::write_raw_out {path handle user_id rawpages limit} {
    set elems {}
    foreach arr $rawpages {
        foreach el [ig::split_json_array $arr] {
            lappend elems $el
            if {[llength $elems] >= $limit} { break }
        }
        if {[llength $elems] >= $limit} { break }
    }
    set items_json "\[[join $elems ,]\]"
    set out "{\"handle\":[ig::jstr $handle],\"user_id\":[ig::jstr $user_id],\"items\":$items_json}"
    set f [open $path w]
    fconfigure $f -encoding utf-8
    puts -nonewline $f $out
    close $f
}

# ---------------------------------------------------------------------------
# JSON emission for the parsed result (indent=2, ensure_ascii=False).
# ---------------------------------------------------------------------------

# Emit a JSON string literal with proper escaping (UTF-8 preserved as raw chars).
proc ig::jstr {s} {
    set out "\""
    foreach ch [split $s ""] {
        switch -- $ch {
            "\"" { append out {\"} }
            "\\" { append out {\\} }
            "\n" { append out {\n} }
            "\r" { append out {\r} }
            "\t" { append out {\t} }
            default {
                scan $ch %c code
                if {$code < 0x20} {
                    append out [format {\u%04x} $code]
                } else {
                    append out $ch
                }
            }
        }
    }
    append out "\""
    return $out
}

# A bare JSON scalar for a leaf value: integer/double/bool/null pass through,
# the null sentinel becomes null, everything else is a string.
proc ig::jscalar {v} {
    if {$v eq "\x00null"} { return null }
    if {$v in {true false null}} { return $v }
    if {[string is integer -strict $v]} { return $v }
    if {[string is double -strict $v]} { return $v }
    return [ig::jstr $v]
}

# Render a list of strings as a JSON array at the given indent.
proc ig::jstrlist {lst indent} {
    if {![llength $lst]} { return {[]} }
    set pad [string repeat " " $indent]
    set inner [string repeat " " [expr {$indent + 2}]]
    set parts {}
    foreach v $lst { lappend parts "$inner[ig::jstr $v]" }
    return "\[\n[join $parts ",\n"]\n$pad\]"
}

# Render a post dict as a JSON object. The five string-list fields are arrays;
# two fields are booleans; the id-shaped and text fields are strings; the rest
# are leaf scalars (integer counts, or the null sentinel rendered as null).
proc ig::jpost {post indent} {
    set pad [string repeat " " $indent]
    set inner [string repeat " " [expr {$indent + 2}]]
    set listfields {hashtags mentions tagged_users coauthors sponsors}
    set boolfields {like_and_view_counts_disabled is_paid_partnership}
    set strfields {post_id shortcode url post_type taken_at_iso caption location}
    set parts {}
    dict for {k v} $post {
        if {$k in $listfields} {
            set rendered [ig::jstrlist $v [expr {$indent + 2}]]
        } elseif {$k in $boolfields} {
            set rendered [expr {$v ? "true" : "false"}]
        } elseif {$k in $strfields} {
            set rendered [ig::jstr $v]
        } else {
            set rendered [ig::jscalar $v]
        }
        lappend parts "$inner[ig::jstr $k]: $rendered"
    }
    return "{\n[join $parts ",\n"]\n$pad}"
}

# Render a list of post dicts as a JSON array of objects.
proc ig::jpostlist {posts indent} {
    if {![llength $posts]} { return {[]} }
    set pad [string repeat " " $indent]
    set inner [string repeat " " [expr {$indent + 2}]]
    set parts {}
    foreach p $posts { lappend parts "$inner[ig::jpost $p [expr {$indent + 2}]]" }
    return "\[\n[join $parts ",\n"]\n$pad\]"
}

# Render the top-level posts result (indent=2): `posts` is a list of post
# objects; `handle`, `user_id`, `note` are strings (user_id is a numeric string
# from IG, kept quoted); `post_count` is an integer.
proc ig::render_posts_result {result} {
    set strfields {handle user_id note}
    set parts {}
    dict for {k v} $result {
        if {$k eq "posts"} {
            set rendered [ig::jpostlist $v 2]
        } elseif {$k in $strfields} {
            set rendered [ig::jstr $v]
        } else {
            set rendered [ig::jscalar $v]
        }
        lappend parts "  [ig::jstr $k]: $rendered"
    }
    return "{\n[join $parts ",\n"]\n}"
}

# Render a flat dict (scalar values only) at indent=2.
proc ig::render_flat {d} {
    set parts {}
    dict for {k v} $d {
        lappend parts "  [ig::jstr $k]: [ig::jscalar $v]"
    }
    return "{\n[join $parts ",\n"]\n}"
}

# ---------------------------------------------------------------------------
# Generic typed-JSON encoder for the drivers with nested output shapes
# (followers, comments, inbox, threads). A value is a tagged 2-list so the
# Tcl dict/list ambiguity never bites:
#   {obj {k1 v1 k2 v2 ...}}   JSON object (values are themselves tagged)
#   {arr {v1 v2 ...}}         JSON array (elements are tagged)
#   {str s}                   JSON string
#   {int n}                   bare number
#   {bool b}                  true/false (b is 1/0/true/false)
#   {null}                    JSON null
#   {rawjson text}            already-encoded JSON spliced in verbatim
# Output matches Python json.dumps(..., indent=2, ensure_ascii=False).
# Re-indent a compact JSON document to match Python json.dumps(indent=2,
# ensure_ascii=False), with the top-level value starting at column `base`.
# Pure lexical transform over the token stream, so arbitrarily nested raw
# structures reformat without the Tcl dict/list ambiguity. Strings (and their
# escapes) pass through verbatim, so UTF-8 content is preserved.
proc ig::reindent_json {json base} {
    set n [string length $json]
    set out ""
    set depth 0
    set instr 0
    set esc 0
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $json $i]
        if {$instr} {
            append out $ch
            if {$esc} { set esc 0 } elseif {$ch eq "\\"} { set esc 1 } elseif {$ch eq "\""} { set instr 0 }
            continue
        }
        switch -- $ch {
            "\"" { set instr 1; append out $ch }
            "\{" - "\[" {
                set close [expr {$ch eq "\{" ? "\}" : "\]"}]
                # Empty container stays on one line.
                set j [expr {$i + 1}]
                while {$j < $n && [string index $json $j] in {" " "\t" "\n" "\r"}} { incr j }
                if {$j < $n && [string index $json $j] eq $close} {
                    append out $ch$close
                    set i $j
                } else {
                    incr depth
                    append out $ch "\n" [string repeat " " [expr {$base + 2 * $depth}]]
                }
            }
            "\}" - "\]" {
                incr depth -1
                append out "\n" [string repeat " " [expr {$base + 2 * $depth}]] $ch
            }
            "," {
                append out ",\n" [string repeat " " [expr {$base + 2 * $depth}]]
            }
            ":" {
                append out ": "
            }
            " " - "\t" - "\n" - "\r" {
                # Insignificant whitespace between tokens; drop it.
            }
            default { append out $ch }
        }
    }
    return $out
}

proc ig::jenc {node {indent 0}} {
    set tag [lindex $node 0]
    set pad [string repeat " " $indent]
    set inner [string repeat " " [expr {$indent + 2}]]
    switch -- $tag {
        str  { return [ig::jstr [lindex $node 1]] }
        int  { return [lindex $node 1] }
        rawjson { return [ig::reindent_json [lindex $node 1] $indent] }
        null { return null }
        bool {
            set b [lindex $node 1]
            return [expr {($b eq "1" || $b eq "true") ? "true" : "false"}]
        }
        obj {
            set pairs [lindex $node 1]
            if {![llength $pairs]} { return "{}" }
            set parts {}
            foreach {k v} $pairs {
                lappend parts "$inner[ig::jstr $k]: [ig::jenc $v [expr {$indent + 2}]]"
            }
            return "{\n[join $parts ",\n"]\n$pad}"
        }
        arr {
            set elems [lindex $node 1]
            if {![llength $elems]} { return {[]} }
            set parts {}
            foreach el $elems {
                lappend parts "$inner[ig::jenc $el [expr {$indent + 2}]]"
            }
            return "\[\n[join $parts ",\n"]\n$pad\]"
        }
        default { error "ig::jenc: unknown tag '$tag'" }
    }
}

# Convenience constructors for typed nodes.
proc ig::n_str {s}  { return [list str $s] }
proc ig::n_int {n}  { return [list int $n] }
proc ig::n_bool {b} { return [list bool $b] }
proc ig::n_null {}  { return [list null] }
proc ig::n_obj {pairs} { return [list obj $pairs] }
proc ig::n_arr {elems} { return [list arr $elems] }

# A typed string-array from a flat list of strings.
proc ig::n_strarr {lst} {
    set elems {}
    foreach v $lst { lappend elems [ig::n_str $v] }
    return [ig::n_arr $elems]
}

# ---------------------------------------------------------------------------
# Serialiser entry: the policed-surface path. The harness sources this file into
# a safe interp and calls serialiser_run with the skill args; the flow drives
# the verbs (nav/eval/api/emit) instead of cdp::connect. Parsing and rendering
# reuse the identical ig:: helpers above, so byte-output matches the legacy path.
# ---------------------------------------------------------------------------

# Standard IG private-API headers, passed to `api`. The CSRF token and
# X-Requested-With are added by the harness; IG also needs its web app id.
proc ig::api_headers {} {
    return [list X-IG-App-ID 936619743392459]
}

# Resolve a handle to its numeric user_id over the policed surface: nav to the
# profile (the covering view for the feed api), then eval the same extraction JS
# the legacy path uses. Returns the user_id string or a dict {error ...}.
proc ig::sv_resolve_user_id {handle} {
    nav "https://www.instagram.com/$handle/" --wait 4
    set st [state]
    if {[dict get $st terminal] ne ""} {
        return [dict create error "Redirected to a wall ([dict get $st terminal]). Session may be expired or rate-limited."]
    }
    set js_extract_id {
    (async () => {
        const scripts = Array.from(document.querySelectorAll('script:not([src])'));
        for (const s of scripts) {
            const t = s.textContent || '';
            const m = t.match(/"user_id"\s*:\s*"(\d+)"/);
            if (m) return JSON.stringify({user_id: m[1]});
            const m2 = t.match(/"id"\s*:\s*"(\d+)".*?"is_private"/s);
            if (m2) return JSON.stringify({user_id: m2[1]});
        }
        try {
            const sd = window._sharedData;
            if (sd) {
                const uid = sd?.entry_data?.ProfilePage?.[0]?.graphql?.user?.id;
                if (uid) return JSON.stringify({user_id: uid});
            }
        } catch(e) {}
        return JSON.stringify({error: 'user_id not found in page'});
    })()
    }
    set raw [eval $js_extract_id]
    if {[catch {json::json2dict $raw} parsed]} {
        return [dict create error "Could not parse user_id extraction result"]
    }
    if {[ig::dget $parsed user_id ""] ne ""} {
        return [dict get $parsed user_id]
    }
    # Fall back to the web_profile_info endpoint via the policed api verb.
    set body [api "/api/v1/users/web_profile_info/" \
        --params "username=$handle" --headers [ig::api_headers]]
    if {![catch {json::json2dict $body} info]} {
        set uid [ig::dget [ig::dget [ig::dget $info data {}] user {}] id ""]
        if {$uid ne ""} { return $uid }
    }
    return [dict create error "Could not determine user_id for @$handle"]
}

# Page the user feed over the policed api verb (the harness paces and bounds it),
# returning the raw items list, identical in shape to the legacy paginator.
proc ig::sv_fetch_feed {user_id limit} {
    set items {}
    set max_id ""
    set page_num 0
    while {[llength $items] < $limit} {
        incr page_num
        set params "count=12"
        if {$max_id ne ""} { append params "&max_id=$max_id" }
        set body [api "/api/v1/feed/user/$user_id/" \
            --params $params --headers [ig::api_headers]]
        if {[catch {json::json2dict $body} page]} {
            puts stderr "Page $page_num: response was not JSON; stopping."
            break
        }
        set page_items [ig::dget $page items {}]
        if {![llength $page_items]} {
            puts stderr "Page $page_num returned no items; stopping."
            break
        }
        foreach it $page_items { lappend items $it }
        puts stderr "Page $page_num: [llength $page_items] items (cumulative [llength $items])"
        if {[ig::dget $page more_available false] ne "true"} { break }
        set max_id [ig::dget $page next_max_id ""]
        if {$max_id eq ""} { break }
        if {[llength $items] >= $limit} { break }
    }
    if {[llength $items] > $limit} {
        set items [lrange $items 0 [expr {$limit - 1}]]
    }
    return $items
}

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
        emit [ig::render_flat [dict create error "Usage: instagram.com/fetch-recent-posts posts <handle> \[--limit N\]"]]
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
        puts "Usage: fetch-recent-posts.tcl posts <handle> \[--limit N\] \[--raw-out PATH\]"
        exit 1
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh fetch-recent-posts.tcl ..."
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
