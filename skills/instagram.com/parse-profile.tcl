#!/usr/bin/env tclsh
# Parse an Instagram profile page HTML.
#
# Serialiser path (see SKILL.md §3-4): browser-serialiser instagram.com/parse-profile <handle>
#   navigates to the profile, dumps the rendered DOM, and emits the JSON form.
# Direct path (legacy, file-fed): tclsh parse-profile.tcl [--json] <html-file>
#
# With --json, emit one JSON object (handle, name, followers_raw/following_raw/
# posts_raw, avatar, caption_snippet, and the hydrated fields when present) for
# machine consumers; otherwise print the human-readable report.
#
# Third-party profile dumps in a headless browser reliably contain:
#   <meta property="og:title">        — "Display Name (@handle) • ..."
#   <meta property="og:description">  — "N followers, M following, K posts - ..."
#   <meta property="og:url">          — canonical URL, source of truth for handle
#   <meta property="og:image">        — avatar
#   <meta name="description">         — same counts + a snippet of a recent caption
#
# GraphQL-hydrated JSON fields (biography, external_url, is_verified) are usually
# NOT populated within a normal virtual-time-budget for a profile the viewer does
# not already follow. The logged-in user's OWN profile data often IS in the dump
# (hydrated in the left-nav app shell) — the parser filters those out by keying
# on the og:url handle.
#
# Counts are parsed locale-agnostically: the og:description contains three
# numbers in a fixed order (followers, following, posts) regardless of language.

package require json::write

# Minimal HTML entity unescape mirroring Python's html.unescape for the entities
# Instagram emits in meta content. Named entities plus numeric (decimal/hex).
proc html_unescape {s} {
    set s [string map {&lt; < &gt; > &quot; \" &#39; ' &apos; ' &nbsp; " "} $s]
    # Numeric decimal entities: &#NNN;
    while {[regexp {&#(\d+);} $s -> num]} {
        set ch [format %c $num]
        regsub -all "&#$num;" $s $ch s
    }
    # Numeric hex entities: &#xHH;
    while {[regexp -nocase {&#x([0-9a-f]+);} $s -> hx]} {
        scan $hx %x code
        set ch [format %c $code]
        regsub -all -nocase "&#x$hx;" $s $ch s
    }
    # &amp; last so it does not double-decode the above.
    set s [string map {&amp; &} $s]
    return $s
}

# Quote a string for use as a literal inside a Tcl regexp.
proc re_escape {s} {
    return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}]
}

# Return content of <meta {key_attr}='{key_value}' content='...'> — both orders.
proc get_meta {html key_attr key_value} {
    set kv [re_escape $key_value]
    set patterns [list \
        "<meta\[^>\]*$key_attr=\"$kv\"\[^>\]*content=\"(\[^\"\]*)\"" \
        "<meta\[^>\]*content=\"(\[^\"\]*)\"\[^>\]*$key_attr=\"$kv\""]
    foreach p $patterns {
        if {[regexp $p $html -> m]} {
            return [html_unescape $m]
        }
    }
    return ""
}

# From 'N followers, M following, K posts - ...' extract three number strings.
# Locale-agnostic: the three numeric tokens always appear in the same order.
proc parse_count_triple {og_desc} {
    if {$og_desc eq ""} { return "" }
    # Cut off at the first " - " (any dash) or " • " — counts precede that.
    set head $og_desc
    if {[regexp {(?s)^(.*?)\s[-–—]\s} $og_desc -> h]} {
        set head $h
    } elseif {[regexp {(?s)^(.*?)\s•\s} $og_desc -> h]} {
        set head $h
    }
    # Tokens that look like numbers, optionally with a K/M/B suffix.
    set nums [regexp -all -inline -nocase {[0-9][0-9.,]*[KMB]?} $head]
    if {[llength $nums] >= 3} {
        return [lrange $nums 0 2]
    }
    return ""
}

# og:title looks like 'Display Name (@handle) • ...'; og:url is the
# authoritative source for the handle. Returns {handle name}.
proc parse_handle_and_name {og_title og_url} {
    set handle ""
    set name ""
    if {$og_url ne ""} {
        if {[regexp {instagram\.com/([A-Za-z0-9_.]+)/?} $og_url -> h]} {
            set handle $h
        }
    }
    if {$og_title ne ""} {
        if {[regexp {^(.*?)\s*\(@([A-Za-z0-9_.]+)\)} $og_title -> n h2]} {
            set name [string trim $n]
            if {$handle eq ""} { set handle $h2 }
        }
    }
    return [list $handle $name]
}

# The <meta name='description'> tag includes: 'Name (@handle) on/en Instagram: "caption"'.
proc parse_recent_caption {meta_description} {
    if {$meta_description eq ""} { return "" }
    if {[regexp {Instagram:\s*["“](.+?)["”]} $meta_description -> cap]} {
        return [string trim $cap]
    }
    return ""
}

# Decode a JSON string body (the inside of a "..." literal) into its text value,
# resolving \uXXXX, \n, etc. Mirrors Python json.loads('"' + group + '"').
proc decode_json_string {body} {
    if {[catch {json::json2dict "\"$body\""} v]} {
        return $body
    }
    return $v
}

# When the profile's own data is hydrated inline (e.g. the logged-in user's own
# profile), JSON objects contain biography / external_url / follower_count. Look
# for any JSON object within a window around '"username":"<handle>"'. Returns a
# dict of any fields found, each tagged with its type for emission.
proc extract_json_fields_for_handle {html handle} {
    if {$handle eq ""} { return {} }
    set out [dict create]
    set he [re_escape $handle]
    set start 0
    set pat "\"username\"\\s*:\\s*\"$he\""
    while {[regexp -indices -start $start $pat $html mIdx]} {
        lassign $mIdx ms me
        set wstart [expr {$ms - 3000}]
        if {$wstart < 0} { set wstart 0 }
        set wend [expr {$me + 5000}]
        set window [string range $html $wstart $wend]

        foreach field {biography full_name external_url category_name business_category_name} {
            # Non-greedy match to the closing quote. Python bounded this at 500
            # chars (a defensive window cap); a JSON string value is quote-
            # terminated well within that, so the effect is identical here.
            set fpat "\"$field\"\\s*:\\s*\"(\[^\"\]*?)\""
            if {![dict exists $out $field] && [regexp $fpat $window -> raw]} {
                dict set out $field [list str [decode_json_string $raw]]
            }
        }
        foreach field {follower_count following_count media_count} {
            set fpat "\"$field\"\\s*:\\s*(\\d+)"
            if {![dict exists $out $field] && [regexp $fpat $window -> num]} {
                dict set out $field [list int $num]
            }
        }
        foreach field {is_verified is_private} {
            set fpat "\"$field\"\\s*:\\s*(true|false)"
            if {![dict exists $out $field] && [regexp $fpat $window -> b]} {
                dict set out $field [list bool $b]
            }
        }
        set start [expr {$me + 1}]
    }
    return $out
}

# A typed field's display string (for the human report). Bools render as
# Python's bool repr (True/False) to match the predecessor's output.
proc field_display {typed} {
    lassign $typed t v
    if {$t eq "bool"} {
        return [expr {$v eq "true" ? "True" : "False"}]
    }
    return $v
}

# Python-equivalent code-point length: Tcl 8.6 stores a non-BMP char as a
# surrogate pair (2 units), so subtract the count of high surrogates to match
# Python's len() which counts one code point per character.
proc cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}

# A typed field rendered as a JSON scalar.
proc field_json {typed} {
    lassign $typed t v
    switch -- $t {
        int  { return $v }
        bool { return $v }
        default { return [json::write string $v] }
    }
}

# Order of hydrated fields in both the report and the JSON object.
set ::HYDRATED_ORDER {full_name biography external_url category_name \
    business_category_name follower_count following_count media_count \
    is_verified is_private}

proc build_profile_json {html} {
    set og_title [get_meta $html property og:title]
    set og_desc  [get_meta $html property og:description]
    set og_url   [get_meta $html property og:url]
    set og_image [get_meta $html property og:image]
    set meta_desc [get_meta $html name description]

    lassign [parse_handle_and_name $og_title $og_url] handle name
    set counts [parse_count_triple $og_desc]
    set caption_snippet [parse_recent_caption $meta_desc]
    if {$handle ne ""} {
        set extra [extract_json_fields_for_handle $html $handle]
    } else {
        set extra {}
    }

    set followers [expr {[llength $counts] ? [lindex $counts 0] : ""}]
    set following [expr {[llength $counts] ? [lindex $counts 1] : ""}]
    set posts     [expr {[llength $counts] ? [lindex $counts 2] : ""}]

    # Assemble the JSON object preserving the Python field order. A field that is
    # null in Python is emitted as JSON null here.
    set pairs {}
    lappend pairs "\"handle\": [json_or_null $handle str]"
    if {$handle ne ""} {
        lappend pairs "\"url\": [json::write string https://www.instagram.com/$handle/]"
    } else {
        lappend pairs "\"url\": null"
    }
    lappend pairs "\"name\": [json_or_null $name str]"
    lappend pairs "\"followers_raw\": [json_or_null $followers str]"
    lappend pairs "\"following_raw\": [json_or_null $following str]"
    lappend pairs "\"posts_raw\": [json_or_null $posts str]"
    lappend pairs "\"avatar\": [json_or_null $og_image str]"
    lappend pairs "\"caption_snippet\": [json_or_null $caption_snippet str]"
    lappend pairs "\"og_description\": [json_or_null $og_desc str]"
    lappend pairs "\"meta_description\": [json_or_null $meta_desc str]"
    lappend pairs "\"html_size\": [cp_length $html]"
    foreach k $::HYDRATED_ORDER {
        if {[dict exists $extra $k]} {
            lappend pairs "[json::write string $k]: [field_json [dict get $extra $k]]"
        } else {
            lappend pairs "[json::write string $k]: null"
        }
    }
    return "{[join $pairs {, }]}"
}

# Emit a JSON string for $v, or null when $v is empty (Python None).
proc json_or_null {v type} {
    if {$v eq ""} { return null }
    return [json::write string $v]
}

proc main {path as_json} {
    set f [open $path r]
    fconfigure $f -encoding utf-8
    set html [read $f]
    close $f

    # Login redirect check.
    set head30 [string range $html 0 29999]
    set head50 [string range $html 0 49999]
    if {[string first "/accounts/login" $head30] >= 0 && \
        [string first "og:url" $head50] < 0} {
        if {$as_json} {
            puts {{"error": "login_redirect"}}
        } else {
            puts "ERROR: redirected to /accounts/login/. Log in via a Chrome-compatible browser first."
        }
        exit 1
    }

    if {$as_json} {
        puts [build_profile_json $html]
        return
    }

    set og_title [get_meta $html property og:title]
    set og_desc  [get_meta $html property og:description]
    set og_url   [get_meta $html property og:url]
    set og_image [get_meta $html property og:image]
    set meta_desc [get_meta $html name description]

    lassign [parse_handle_and_name $og_title $og_url] handle name
    set counts [parse_count_triple $og_desc]
    set caption_snippet [parse_recent_caption $meta_desc]

    # HTML size with thousands separators, mirroring Python's {:,}.
    puts "HTML size: [commafy [cp_length $html]] bytes"
    if {$og_title eq "" && $og_url eq ""} {
        puts "WARNING: no og:* tags found. Page may be a login redirect or an error page."
    }

    puts ""
    if {$handle ne ""} {
        puts "handle:   @$handle"
        puts "url:      https://www.instagram.com/$handle/"
    }
    if {$name ne ""} {
        puts "name:     $name"
    }
    if {[llength $counts]} {
        puts "followers: [lindex $counts 0]"
        puts "following: [lindex $counts 1]"
        puts "posts:     [lindex $counts 2]"
    }
    if {$og_image ne ""} {
        puts "avatar:   $og_image"
    }

    if {$handle ne ""} {
        set extra [extract_json_fields_for_handle $html $handle]
    } else {
        set extra {}
    }
    if {[dict size $extra]} {
        puts ""
        puts "Hydrated JSON fields (when present):"
        foreach k $::HYDRATED_ORDER {
            if {[dict exists $extra $k]} {
                puts "  $k: [field_display [dict get $extra $k]]"
            }
        }
    }

    if {$caption_snippet ne ""} {
        puts ""
        puts "recent-post caption snippet: $caption_snippet"
    }

    puts ""
    puts "--- og:description (raw) ---"
    puts [expr {$og_desc ne "" ? $og_desc : "(none)"}]
    puts ""
    puts "--- meta name=description (raw) ---"
    puts [expr {$meta_desc ne "" ? $meta_desc : "(none)"}]
}

# Insert thousands separators into a non-negative integer string.
proc commafy {n} {
    set s $n
    set out ""
    while {[string length $s] > 3} {
        set out ",[string range $s end-2 end]$out"
        set s [string range $s 0 end-3]
    }
    return "$s$out"
}

# ---------------------------------------------------------------------------
# Serialiser entry: the policed-surface path. nav to the profile, dump the
# rendered DOM, and run the identical build_profile_json over the in-memory HTML
# (no file read; Plane 1 removes file access). Emits the JSON form.
#
# Invoked by reference through the serialiser (see SKILL.md §3-4):
#     browser-serialiser instagram.com/parse-profile <handle>
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set handle ""
    foreach a $skillArgs {
        if {[string match "--*" $a]} continue
        set handle [string trimleft $a @]
        break
    }
    if {$handle eq ""} {
        emit {{"error": "Usage: instagram.com/parse-profile <handle>"}}
        return
    }
    nav "https://www.instagram.com/$handle/" --wait 6
    if {[dict get [state] terminal] ne ""} {
        emit {{"error": "login_redirect"}}
        return
    }
    set html [dump]
    set head50 [string range $html 0 49999]
    if {[string first "/accounts/login" [string range $html 0 29999]] >= 0 && \
        [string first "og:url" $head50] < 0} {
        emit {{"error": "login_redirect"}}
        return
    }
    emit [build_profile_json $html]
}

# Direct-tclsh entry: an optional --json flag plus one path, in any order. Skipped
# when this file is sourced as a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    set as_json 0
    set rest {}
    foreach a $argv {
        if {$a eq "--json"} {
            set as_json 1
        } else {
            lappend rest $a
        }
    }
    if {[llength $rest] != 1} {
        puts "Usage: parse-profile.tcl \[--json\] <profile.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    main [lindex $rest 0] $as_json
}
