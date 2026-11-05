# The shared instagram.com library, in the ig:: namespace: CDP plumbing, JSON
# eval, user-id resolution, feed paging, media parsing, and the typed-JSON
# encoder that renders a result.
#
# Every action in this skill sources it, and their serialiser paths share
# ig::sv_resolve_user_id, ig::sv_fetch_feed and ig::parse_media_items, so the
# bytes they emit for the same feed match.

package require json

# The legacy cdp package, for the siblings that keep a direct-tclsh main, which
# calls cdp::connect when run as `tclsh X.tcl ...` outside the serialiser.
# Sourced only when not already present, so loading this file under
# the serialiser harness (where the policed verbs replace raw CDP) is a no-op
# rather than a re-definition. The harness path uses serialiser_run.
if {![namespace exists cdp]} {
    catch { ::tcl::tm::path add [file normalize [file join [file dirname [info script]] .. .. .. lib]]; package require cdp }
}

namespace eval ig {
    variable LastRaw ""
    # Scrolls in a row that bring no new item before a paging loop gives up
    # while the connection still reports a next page. A profile grid runs up
    # to 4 empty scrolls between pages (2 s dwell each), observed 2026-11-05.
    variable ScrollPatience 8
}

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
        # Where the creator hid likes, like_count is a placeholder (3 on every
        # hidden reel checked, 2026-11-05), so it is no count at all.
        set hidden [ig::truthy [ig::dget $item like_and_view_counts_disabled false]]
        dict set post like_count [expr {$hidden ? "\x00null" : [ig::dget_null $item like_count]}]
        dict set post comment_count [ig::dget_null $item comment_count]
        dict set post view_count [ig::dget_null $item view_count]
        dict set post media_repost_count [ig::dget_null $item media_repost_count]
        dict set post fb_like_count [ig::dget_null $item fb_like_count]
        dict set post fb_comment_count [ig::dget_null $item fb_comment_count]
        dict set post like_and_view_counts_disabled $hidden
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
# Shortcode <-> media_id (Instagram's base64 encoding; pure local conversion).
# Tcl's expr handles arbitrary-precision integers, so the bignum math is exact.
# ---------------------------------------------------------------------------

set ::ig::ShortcodeAlphabet "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

proc ig::shortcode_to_media_id {shortcode} {
    set result 0
    foreach ch [split $shortcode ""] {
        set idx [string first $ch $::ig::ShortcodeAlphabet]
        if {$idx < 0} {
            error "shortcode contains invalid char: $ch"
        }
        set result [expr {$result * 64 + $idx}]
    }
    return $result
}

# Accept a shortcode, a permalink, a full post_id (id_userid), or a bare media_id. Return the
# bare media_id string. Raises on a malformed post_id. Digit checks use a regex
# (mirroring Python str.isdigit) so 19-digit media ids are not truncated the way
# Tcl's native-int `string is integer` would.
proc ig::is_digits {s} {
    return [expr {$s ne "" && [regexp {^\d+$} $s]}]
}
proc ig::is_post_id {s} {
    return [regexp {^\d+_\d+$} $s]
}
proc ig::resolve_post_ref {post_ref} {
    regexp {/(?:p|reels?|tv)/([A-Za-z0-9_-]+)} $post_ref -> post_ref
    # A shortcode's alphabet includes "_", so only digits_digits is a post_id.
    if {[ig::is_post_id $post_ref]} { return [lindex [split $post_ref "_"] 0] }
    if {[ig::is_digits $post_ref]} { return $post_ref }
    return [ig::shortcode_to_media_id $post_ref]
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

# ---------------------------------------------------------------------------
# Byte-faithful JSON-array extraction/splitting (auth-read-seen-thread).
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
# the verbs (nav/eval/api/emit) instead of cdp::connect.
# ---------------------------------------------------------------------------

# Standard IG private-API headers, passed to `api`. The CSRF token and
# X-Requested-With are added by the harness; IG also needs its web app id.
proc ig::api_headers {} {
    return [list X-IG-App-ID 936619743392459]
}

# Resolve a handle to its numeric user_id over the policed surface: nav to the
# profile, then read the id out of the page the nav already fetched. Returns the user_id string or a dict {error ...}.
#
# Two fields in that page look alike and only one is the profile's. A bare
# "user_id" in an inline script belongs to the SIGNED-IN VIEWER, so matching it
# returns the operator's own id for every handle asked for, and the feed then
# fetched is the operator's own. That produced a wrong feed for four different
# targets, reported as post_count 0, which reads as a fact about the target.
# "profile_id" is the one scoped to the profile being viewed; ig-profile.tcl
# reads the same field for its pk.
#
# web_profile_info answers the same question and is keyed on the username, but
# it sits last: the endpoint returns 429 for a session whose profile navigation
# is being served normally, so reaching for it first turns a working read into a
# terminal rate-limited run.
proc ig::sv_resolve_user_id {handle} {
    # A numeric pk is not a handle. Instagram's profile URL takes a username, so
    # a pk here navigates to a "page not found" whose scripts still describe the
    # viewer. Say so rather than resolving something else.
    if {[regexp {^\d+$} $handle]} {
        return [dict create error "\"$handle\" is a numeric user id, not a handle. Pass the @username; look it up with auth-ig-profile if only the id is known."]
    }
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
            const m = t.match(/"profile_id"\s*:\s*"(\d+)"/);
            if (m) return JSON.stringify({user_id: m[1]});
        }
        for (const s of scripts) {
            const t = s.textContent || '';
            const m = t.match(/"id"\s*:\s*"(\d+)".*?"is_private"/s);
            if (m) return JSON.stringify({user_id: m[1]});
        }
        try {
            const sd = window._sharedData;
            const uid = sd?.entry_data?.ProfilePage?.[0]?.graphql?.user?.id;
            if (uid) return JSON.stringify({user_id: uid});
        } catch(e) {}
        return JSON.stringify({error: 'user_id not found in page'});
    })()
    }
    set raw [eval $js_extract_id]
    if {![catch {json::json2dict $raw} parsed]} {
        if {[ig::dget $parsed user_id ""] ne ""} {
            return [dict get $parsed user_id]
        }
    }
    set body [api "/api/v1/users/web_profile_info/" \
        --params "username=$handle" --headers [ig::api_headers]]
    if {![catch {json::json2dict $body} info]} {
        set uid [ig::dget [ig::dget [ig::dget $info data {}] user {}] id ""]
        if {$uid ne ""} { return $uid }
    }
    return [dict create error "Could not determine user_id for @$handle"]
}

# Page a profile's grid the way the profile page does: capture the page, whose
# own GraphQL query (xdt_api__v1__feed__user_timeline_graphql_connection) carries
# twelve items in the REST item shape, then scroll for each further page while
# the connection reports one. The REST feed, /api/v1/feed/user/<id>/, answers
# Instagram's HTML 404 page (observed 2026-10-29; last JSON 2026-09-20). Returns
# the raw items list; $moreVar, when named, is set to whether the timeline still
# reported a next page where reading stopped (1 also when scrolling stalled).
#
# No items is a result only for an account with no posts. A private account
# throws {IG FEED private}, and a public page that loaded no timeline throws
# {IG FEED missing}, so a caller never reports either as an empty account. Both
# facts come from the page's own user query (is_private, media_count), which is
# locale-agnostic.
proc ig::sv_fetch_feed {handle limit {moreVar ""}} {
    if {$moreVar ne ""} { upvar 1 $moreVar more }
    set conn xdt_api__v1__feed__user_timeline_graphql_connection
    set items {}
    set captured [capture "https://www.instagram.com/$handle/" --seconds 8 --match {*graphql*}]
    set more [ig::sv_take_connection $captured $conn items]
    if {![llength $items]} {
        set user [ig::sv_profile_user $captured $handle]
        if {[ig::truthy [ig::dget $user is_private false]]} {
            throw {IG FEED private} "@$handle is private; its posts are not visible to this account"
        }
        if {$more eq "" && [ig::dget $user media_count ""] ne "0"} {
            throw {IG FEED missing} "the profile page of @$handle loaded no post timeline"
        }
        set more 0
        return {}
    }
    set idle 0
    while {[llength $items] < $limit && $more && $idle < $::ig::ScrollPatience} {
        eval {window.scrollTo(0, document.body.scrollHeight)}
        dwell 2
        set n [llength $items]
        set m [ig::sv_take_connection [harvest --match {*graphql*}] $conn items]
        if {$m ne ""} { set more $m }
        if {[llength $items] == $n} { incr idle } else { set idle 0 }
    }
    if {[llength $items] > $limit} { set more 1 }
    log "feed @$handle: [llength $items] items, more=$more"
    return [lrange $items 0 [expr {$limit - 1}]]
}

# Page a profile's Reels tab the way the tab does: capture /<handle>/reels/,
# whose own user query (data.fetch__XDTUserDict, id = $user_id) carries
# clips_connection, about a dozen reels on the first page and five per scroll.
# Its media nodes carry play_count, the number the tab prints on each tile, which
# the grid query does not select. Paging stops at $limit reels, or at the first
# unpinned reel older than $since (epoch seconds, 0 for none), or when the
# connection reports no next page; a pinned reel older than $since is dropped.
# The tab also lists collab reels another account hosts. Returns the raw media list; $moreVar as in
# ig::sv_fetch_feed. Throws {IG REELS private} and {IG REELS missing} as
# sv_fetch_feed does for the grid.
proc ig::sv_fetch_reels {handle user_id limit since {moreVar ""}} {
    if {$moreVar ne ""} { upvar 1 $moreVar more }
    set items {}
    set captured [capture "https://www.instagram.com/$handle/reels/" --seconds 10 --match {*graphql*}]
    set more [ig::sv_take_clips $captured $user_id items]
    if {$more eq ""} {
        set user [ig::sv_profile_user $captured $handle]
        if {[ig::truthy [ig::dget $user is_private false]]} {
            throw {IG REELS private} "@$handle is private; its reels are not visible to this account"
        }
        throw {IG REELS missing} "the reels tab of @$handle loaded no reels connection"
    }
    set idle 0
    while {$more && $idle < $::ig::ScrollPatience && [llength $items] < $limit
           && ![ig::reels_past_since $items $since]} {
        eval {window.scrollTo(0, document.body.scrollHeight)}
        dwell 2
        set n [llength $items]
        set m [ig::sv_take_clips [harvest --match {*graphql*}] $user_id items]
        if {$m ne ""} { set more $m }
        if {[llength $items] == $n} { incr idle } else { set idle 0 }
    }
    set kept {}
    foreach m $items {
        if {[llength $kept] >= $limit} { set more 1; break }
        if {$since && [ig::pk_time [ig::dget $m pk ""]] < $since} {
            if {[ig::reel_pinned $m]} continue
            set more 0; break
        }
        lappend kept $m
    }
    log "reels @$handle: [llength $kept] of [llength $items] read, more=$more"
    return $kept
}

# Append the media of every clips_connection page for user $user_id among
# captured triples to the caller's $itemsVar, skipping a pk already held.
# Returns the last page's has_next_page (0 or 1), or "" when none was captured.
proc ig::sv_take_clips {captured user_id itemsVar} {
    upvar 1 $itemsVar items
    set seen {}
    foreach it $items { dict set seen [ig::dget $it pk ""] 1 }
    set more ""
    foreach r $captured {
        set body [lindex $r 2]
        if {[string first clips_connection $body] < 0} continue
        if {[catch {json::json2dict $body} d]} continue
        set u [ig::dget [ig::dget $d data {}] fetch__XDTUserDict {}]
        if {[ig::dget $u id ""] ne $user_id} continue
        set c [ig::dget $u clips_connection {}]
        foreach e [ig::dget $c edges {}] {
            set m [ig::dget [ig::dget $e node {}] media {}]
            set pk [ig::dget $m pk ""]
            if {$pk eq "" || [dict exists $seen $pk]} continue
            dict set seen $pk 1
            lappend items $m
        }
        set more [expr {[ig::dget [ig::dget $c page_info {}] has_next_page false] eq "true"}]
    }
    return $more
}

# A reel the owner pinned to the top of the tab sits out of date order.
proc ig::reel_pinned {m} {
    return [expr {[llength [ig::dget $m clips_tab_pinned_user_ids {}]] > 0}]
}

# Whether the reels held already reach back past $since, so paging can stop.
proc ig::reels_past_since {items since} {
    if {!$since} { return 0 }
    foreach m [lreverse $items] {
        if {[ig::reel_pinned $m]} continue
        return [expr {[ig::pk_time [ig::dget $m pk ""]] < $since}]
    }
    return 0
}

# Reel media from ig::sv_fetch_reels as typed JSON nodes, for ig::jenc.
proc ig::reel_nodes {items} {
    set out {}
    foreach m $items {
        set code [ig::dget $m code ""]
        set hidden [ig::truthy [ig::dget $m like_and_view_counts_disabled false]]
        lappend out [ig::n_obj [list \
            post_id [ig::n_str [ig::dget $m id ""]] \
            shortcode [ig::n_str $code] \
            url [ig::n_str "https://www.instagram.com/reel/$code/"] \
            owner [ig::n_str [ig::dget [ig::dget $m user {}] username ""]] \
            taken_at_iso [ig::n_str [ig::seconds_to_iso [ig::pk_time [ig::dget $m pk ""]]]] \
            play_count [ig::count_node [ig::dget $m play_count null]] \
            like_count [expr {$hidden ? [ig::n_null] : [ig::count_node [ig::dget $m like_count null]]}] \
            comment_count [ig::count_node [ig::dget $m comment_count null]] \
            like_and_view_counts_disabled [ig::n_bool $hidden] \
            pinned [ig::n_bool [ig::reel_pinned $m]]]]
    }
    return $out
}

proc ig::count_node {v} {
    if {[string is integer -strict $v]} { return [ig::n_int $v] }
    return [ig::n_null]
}

# Append the nodes of every page of GraphQL connection $conn among captured
# {url status body} triples to the caller's $itemsVar, skipping a pk already
# held. Returns the last page's has_next_page (0 or 1), or "" when no page of
# $conn was among them.
proc ig::sv_take_connection {captured conn itemsVar} {
    upvar 1 $itemsVar items
    set seen {}
    foreach it $items { dict set seen [ig::dget $it pk ""] 1 }
    set more ""
    foreach r $captured {
        set body [lindex $r 2]
        if {[string first $conn $body] < 0} continue
        if {[catch {json::json2dict $body} d]} continue
        set c [ig::dget [ig::dget $d data {}] $conn {}]
        foreach e [ig::dget $c edges {}] {
            set node [ig::dget $e node {}]
            set pk [ig::dget $node pk ""]
            if {$pk eq "" || [dict exists $seen $pk]} continue
            dict set seen $pk 1
            lappend items $node
        }
        set more [expr {[ig::dget [ig::dget $c page_info {}] has_next_page false] eq "true"}]
    }
    return $more
}

# The creation time, in epoch seconds, that an Instagram media id encodes: its
# top bits are milliseconds since Instagram's epoch (1314220021721 ms,
# 2011-08-24). It matched taken_at within 5 seconds on all 14 timeline posts
# checked on 2026-10-29. "" for a non-numeric id.
proc ig::pk_time {pk} {
    if {![string is digit -strict $pk]} { return "" }
    return [expr {(($pk >> 23) + 1314220021721) / 1000}]
}

# The profile page's own user query for $handle (data.user, carrying
# is_private and media_count) among captured triples, or {} when absent.
proc ig::sv_profile_user {captured handle} {
    foreach r $captured {
        set body [lindex $r 2]
        if {[string first {"user":} $body] < 0} continue
        if {[catch {json::json2dict $body} d]} continue
        set u [ig::dget [ig::dget $d data {}] user {}]
        if {[string equal -nocase [ig::dget $u username ""] $handle]} { return $u }
    }
    return {}
}
