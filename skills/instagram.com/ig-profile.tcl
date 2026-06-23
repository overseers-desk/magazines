# ig-profile.tcl - the Instagram profile-read interaction, shared VERBATIM by the
# overseer-toolbox skill and the BI overseer's type-B playbook. Both ends source
# this same file (the BI side carries a vendored copy beside its playbooks); the
# only per-end difference is the filename the two systems address it by.
# Home: overseer-toolbox/skills/instagram.com/ig-profile.tcl
#
# It reads the profile the dom-dump way (navigate as a human views it, dump the
# rendered outerHTML, parse what the page shows) -- never the private
# api/v1/web_profile_info endpoint, which earned an HTTP 429. It emits the
# canonical envelope {result, cursor, hasMore, fault}; `result` is the SUPERSET
# both consumers project from: the server validates its required subset against
# social/api/contracts/ig-profile.schema.json and discards the rest, while a skill
# caller reads whichever fields it wants. A removed / non-existent profile emits a
# distinct fault (shape "removed"); a login wall emits shape "login_wall".
#
# Only the policed verbs nav/dump/dwell/log/emit are used, all present under both
# the serialiser harness and the overseer's playbook harness, so the one file runs
# unchanged on either side. Generic JSON/envelope helpers are kept self-contained
# here (ig-canonical.tcl keeps its own copies for the inbox/thread/posts playbooks,
# which this file does not touch); the HTML helpers come from the shared ig-html.tcl.

package require json
package require json::write
::json::write indented 0
::json::write aligned 0

source [file join [file dirname [info script]] ig-html.tcl]

# ===========================================================================
# Generic helpers (self-contained: the skill end has no ig-canonical.tcl)
# ===========================================================================
proc dict_get_or {d key default} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}
# A correct JSON string escaper (tcllib json::write string does not escape control
# chars, and bios carry literal newlines): ", \, the C0 set, and non-BMP as a
# UTF-16 surrogate pair so the output stays pure ASCII.
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
proc j_str {s}       { return [jq $s] }
proc j_strornull {s} { return [expr {$s eq "" || $s eq "null" ? "null" : [jq $s]}] }
proc j_bool {b}      { return [expr {$b ? "true" : "false"}] }
proc j_intornull {v} { return [expr {$v eq "" || $v eq "null" ? "null" : $v}] }
proc j_boolornull {v} { return [expr {$v eq "" ? "null" : ($v ? "true" : "false")}] }

proc fault_shape_of {detail} {
    if {[regexp {^([a-z_]+):\s} $detail -> tag] && [lsearch -exact {removed login_wall} $tag] >= 0} {
        return $tag
    }
    return unrecognised
}
proc envelope_ok {r} {
    set cursor [dict get $r cursor]
    set c [expr {$cursor eq "" ? "null" : [json::write string $cursor]}]
    set h [expr {[dict get $r hasMore] ? "true" : "false"}]
    return [json::write object result [dict get $r result] cursor $c hasMore $h fault null]
}
proc envelope_fault {detail} {
    set f [json::write object shape [json::write string [fault_shape_of $detail]] \
                                detail [json::write string [string range $detail 0 200]]]
    return [json::write object result null cursor null hasMore false fault $f]
}

# URL-encode a path segment (the viewed handle), self-contained so the file does
# not depend on the http package (unavailable in the harness's safe interp).
proc url_quote {s} {
    set out ""
    foreach ch [split $s ""] {
        if {[string match {[A-Za-z0-9._~-]} $ch]} {
            append out $ch
        } else {
            foreach b [split [encoding convertto utf-8 $ch] ""] {
                scan $b %c code
                append out [format %%%02X [expr {$code & 0xff}]]
            }
        }
    }
    return $out
}

# ===========================================================================
# Profile-specific HTML extractors (the rendered page is the source of truth for
# the viewed profile; never the viewer's embedded JSON)
# ===========================================================================
# Exact count rendered in the header: the numeric span text before the English
# word ("followers"/"following"/"posts"). "" if not present.
proc html_rendered_count {html word} {
    set re {([0-9][0-9.,KMBkmb]*)</span></span>[^<]*}
    append re $word
    if {[regexp $re $html -> n]} { return [count_to_int $n] }
    return ""
}
# Exact follower count from the title="27,449" attribute on the followers anchor
# (the visible text is rounded; the title carries the precise value). "" if none.
proc html_follower_title {html} {
    if {[regexp {title="([0-9,]+)"(?:(?!title=).)*?</span></span>[^<]*followers} $html -> t]} {
        return [count_to_int $t]
    }
    return ""
}
# The VIEWED profile's biography from <meta name="description">, the quoted tail of
# "<counts> - <name> (@<handle>) on Instagram: \"<BIO>\"". Untruncated, the viewed
# profile's (the meta names the viewed @handle). "" when the profile has no bio.
proc html_bio {html} {
    set c [html_meta_named $html description]
    if {$c eq ""} { return "" }
    if {[regexp {on Instagram: &quot;(.*)&quot;[^&]*$} $c -> bio]} {
        return [html_unescape $bio]
    }
    return ""
}
# The VIEWED profile's external link as the rendered "link in bio" anchor shows it
# (routed through l.instagram.com, displayed as the clean host/path). NOT the
# viewer's embedded external_url. "" when no link is shown.
proc html_external_url {html} {
    if {![regexp {href="https?://l\.instagram\.com/\?u=[^"]*"[^>]*>(?:<[^>]*>)*([^<]+)<} $html -> txt]} {
        return ""
    }
    set txt [string trim [html_unescape $txt]]
    if {$txt eq ""} { return "" }
    if {![regexp {^https?://} $txt]} { set txt "https://$txt" }
    return $txt
}
# A removed / non-existent profile renders the "this page isn't available" state
# with no server-rendered og:title. Two OR'd confirmers: the structural,
# locale-independent one (a noindexed page that still carries this profile URL's
# og:url skeleton, and is not a login wall), and Instagram's English copy.
proc html_profile_removed {html} {
    if {[html_meta $html "og:url"] ne ""
        && [regexp -nocase {<meta[^>]*name="robots"[^>]*content="[^"]*noindex} $html]
        && ![html_login_wall $html]} { return 1 }
    if {[regexp -nocase {<title>[^<]*Profile isn't available[^<]*</title>} $html]} { return 1 }
    if {[regexp -nocase {<title>[^<]*Page Not Found[^<]*</title>} $html]} { return 1 }
    if {[regexp -nocase {Sorry, this page isn't available} $html]} { return 1 }
    return 0
}
# A genuine login wall (not logged in / session expired): the login form / route
# markers, only meaningful when no profile data was found.
proc html_login_wall {html} {
    if {[regexp -nocase {<title>[^<]*Login\s*[•·]\s*Instagram[^<]*</title>} $html]} { return 1 }
    if {[regexp {name="username"[^>]*>.*name="password"} $html]} { return 1 }
    if {[regexp {action="/accounts/login/} $html]} { return 1 }
    return 0
}

# ===========================================================================
# Extra superset fields a skill caller uses (raw rounded counts, caption, avatar,
# the og/meta passthrough, and any inline-hydrated fields)
# ===========================================================================
proc re_escape {s} { return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}] }
# Three raw count tokens from og:description, locale-agnostic ("27K"/"4,566"/...).
proc parse_count_triple {og_desc} {
    if {$og_desc eq ""} { return "" }
    set head $og_desc
    if {[regexp {(?s)^(.*?)\s[-–—]\s} $og_desc -> h]} { set head $h } \
    elseif {[regexp {(?s)^(.*?)\s•\s} $og_desc -> h]} { set head $h }
    set nums [regexp -all -inline -nocase {[0-9][0-9.,]*[KMB]?} $head]
    if {[llength $nums] >= 3} { return [lrange $nums 0 2] }
    return ""
}
# The recent-post caption snippet from <meta name="description"> ("... on Instagram: "caption"").
proc parse_recent_caption {meta_description} {
    if {$meta_description eq ""} { return "" }
    if {[regexp {Instagram:\s*["“](.+?)["”]} $meta_description -> cap]} { return [string trim $cap] }
    return ""
}
# Python-equivalent code-point length (Tcl 8.6 counts a non-BMP char as 2 units).
proc cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}
proc decode_json_string {body} {
    if {[catch {json::json2dict "\"$body\""} v]} { return $body }
    return $v
}
# Inline-hydrated fields near '"username":"<handle>"' (present mainly for the
# viewer's own profile; usually absent for a third party). Returns a dict of
# {field {type value}} for the fields found.
proc extract_json_fields_for_handle {html handle} {
    if {$handle eq ""} { return {} }
    set out [dict create]
    set he [re_escape $handle]
    set start 0
    set pat "\"username\"\\s*:\\s*\"$he\""
    while {[regexp -indices -start $start $pat $html mIdx]} {
        lassign $mIdx ms me
        set wstart [expr {$ms - 3000}]; if {$wstart < 0} { set wstart 0 }
        set window [string range $html $wstart [expr {$me + 5000}]]
        foreach field {biography full_name external_url category_name business_category_name fbid_v2} {
            set fpat "\"$field\"\\s*:\\s*\"(\[^\"\]*?)\""
            if {![dict exists $out $field] && [regexp $fpat $window -> raw]} {
                dict set out $field [list str [decode_json_string $raw]]
            }
        }
        foreach field {follower_count following_count media_count} {
            set fpat "\"$field\"\\s*:\\s*(\\d+)"
            if {![dict exists $out $field] && [regexp $fpat $window -> num]} { dict set out $field [list int $num] }
        }
        foreach field {is_verified is_private} {
            set fpat "\"$field\"\\s*:\\s*(true|false)"
            if {![dict exists $out $field] && [regexp $fpat $window -> b]} { dict set out $field [list bool $b] }
        }
        set start [expr {$me + 1}]
    }
    return $out
}
# A hydrated field's value or "" (for the optional extras).
proc hydrated_or {extra field} {
    if {[dict exists $extra $field]} { return [lindex [dict get $extra $field] 1] }
    return ""
}

# ===========================================================================
# The parse: handle + dumped HTML -> the superset `result` JSON. Throws a tagged
# error for a fault page (removed:/login_wall:/...); the caller maps it to a fault.
# ===========================================================================
proc parse_profile_superset {handle html} {
    if {$handle eq ""} { error "no handle given" }
    if {$html eq "" || [string length $html] < 200} {
        error "empty/short profile page for $handle ([string length $html] chars)"
    }
    set ogTitle [html_unescape [html_meta $html "og:title"]]
    set ogDesc  [html_unescape [html_meta $html "og:description"]]
    set ogImage [html_meta $html "og:image"]
    set metaDesc [html_unescape [html_meta_named $html description]]

    # Removed / non-existent: page loaded but renders the unavailable state with no
    # og:title. The leading "removed:" tag is read by envelope_fault.
    if {$ogTitle eq "" && [html_profile_removed $html]} {
        error "removed: profile page unavailable/removed: $handle"
    }

    set username $handle
    set full_name ""
    if {[regexp {^(.*?)\s*\(@([^)]+)\)} $ogTitle -> fn un]} {
        set full_name [string trim $fn]
        if {$un ne ""} { set username $un }
    }

    set pk ""
    if {[regexp {"profile_id":"([0-9]+)"} $html -> p]} { set pk $p }
    # The account-level fbid_v2 (the long "17841…" Graph id): preferred from the
    # hydrated fields near the handle, else the first one on the page. Mirrors the
    # inbox's account-level id; "" when the page does not hydrate it.
    set fbid_v2 ""
    if {[regexp {"fbid_v2":"?([0-9]+)"?} $html -> fb]} { set fbid_v2 $fb }

    # Counts: prefer the live precise rendered header, fall back to the rounded
    # og:description triple (also kept verbatim as *_raw for skill callers).
    set triple [parse_count_triple $ogDesc]
    set followers_raw [expr {[llength $triple] ? [lindex $triple 0] : ""}]
    set following_raw [expr {[llength $triple] ? [lindex $triple 1] : ""}]
    set posts_raw     [expr {[llength $triple] ? [lindex $triple 2] : ""}]
    set follower_count [html_follower_title $html]
    if {$follower_count eq ""} { set follower_count [html_rendered_count $html followers] }
    if {$follower_count eq ""} { set follower_count [count_to_int $followers_raw] }
    set following_count [html_rendered_count $html following]
    if {$following_count eq ""} { set following_count [count_to_int $following_raw] }
    set media_count [html_rendered_count $html posts]
    if {$media_count eq ""} { set media_count [count_to_int $posts_raw] }

    if {$pk eq "" && $follower_count eq "" && $ogTitle eq ""} {
        if {[html_login_wall $html]} {
            error "login_wall: login wall, no profile data for $handle (session not logged in?)"
        }
        error "no profile data on page for $handle (not a profile page?)"
    }

    set is_private [expr {[regexp -nocase {This Account is Private|This account is private} $html] ? 1 : 0}]
    set biography    [html_bio $html]
    set external_url [html_external_url $html]
    set caption_snippet [parse_recent_caption $metaDesc]
    set extra [expr {$username ne "" ? [extract_json_fields_for_handle $html $username] : {}}]
    # Prefer the fbid_v2 hydrated in the handle's own window over the first on the page.
    set hydratedFbid [hydrated_or $extra fbid_v2]
    if {$hydratedFbid ne ""} { set fbid_v2 $hydratedFbid }

    return [json::write object \
        username       [j_str $username] \
        full_name      [j_str $full_name] \
        pk             [j_str $pk] \
        fbid_v2        [j_strornull $fbid_v2] \
        is_private     [j_bool $is_private] \
        follower_count  [j_intornull $follower_count] \
        following_count [j_intornull $following_count] \
        media_count     [j_intornull $media_count] \
        category_name  null \
        biography      [j_strornull $biography] \
        external_url   [j_strornull $external_url] \
        url            [j_str "https://www.instagram.com/$username/"] \
        followers_raw  [j_strornull $followers_raw] \
        following_raw  [j_strornull $following_raw] \
        posts_raw      [j_strornull $posts_raw] \
        avatar         [j_strornull $ogImage] \
        caption_snippet [j_strornull $caption_snippet] \
        og_description [j_strornull $ogDesc] \
        meta_description [j_strornull $metaDesc] \
        html_size      [cp_length $html] \
        is_verified    [j_boolornull [hydrated_or $extra is_verified]] \
        business_category_name [j_strornull [hydrated_or $extra business_category_name]]]
}

# Poll the rendered DOM until the header hydrates (counts), the private notice, or
# the removed state appears, then return that HTML. dump/dwell/log are harness verbs.
proc profile_html {} {
    set html ""
    for {set i 0} {$i < 20} {incr i} {
        set html [dump]
        if {[regexp {</span></span>[^<]*(followers|posts)} $html]
            || [regexp -nocase {This Account is Private} $html]
            || [html_profile_removed $html]} { break }
        dwell 0.3
    }
    log "dom.dump outerHTMLBytes=[string length $html]"
    return $html
}

# handle + html -> the canonical envelope (ok with the superset, or a fault).
proc profile_envelope {handle html} {
    if {[catch {parse_profile_superset $handle $html} r]} {
        return [envelope_fault $r]
    }
    return [envelope_ok [dict create result $r cursor "" hasMore 0]]
}

# ===========================================================================
# Entry: identical on both ends. Accepts the playbook's {handle ...} dict form and
# the skill's bare-handle CLI form. nav, poll the DOM, emit the canonical envelope.
# ===========================================================================
proc serialiser_run {skillArgs} {
    set a [lindex $skillArgs 0]
    set handle ""
    if {[expr {[llength $a] % 2 == 0}] && [dict exists $a handle]} {
        set handle [dict get $a handle]
    } else {
        foreach x $skillArgs { if {![string match "--*" $x]} { set handle [string trimleft $x @]; break } }
    }
    if {$handle eq ""} { emit [envelope_fault "no handle given"]; return }
    nav "https://www.instagram.com/[url_quote $handle]/"
    emit [profile_envelope $handle [profile_html]]
}
