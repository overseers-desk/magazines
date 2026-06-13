#!/usr/bin/env tclsh
# Parse comments from a Facebook reel HTML capture into Markdown.
#
# Reads the rendered HTML produced by reel-comments-cdp.tcl and emits a
# human-readable markdown file. Each top-level comment is a numbered list
# item; replies are nested.
#
# Per-comment fields:
#   - Author display name (from aria-label)
#   - Age string (e.g. "5 weeks ago", from aria-label)
#   - Body text (visible text inside the comment article)
#   - Profile URL (from the comment header link)
#   - comment_id (decoded from the base64 query parameter when present)
#
# Usage:
#     tclsh parse-reel-comments.tcl HTML_FILE [--md OUT.md] [--source-url URL]
#                                   [--bodies-json SIDECAR.json]

package require json
package require base64

source [file dirname [info script]]/fb-common.tcl

# This file's directory, captured at load time ([info script] is only valid
# here, not at proc-runtime), so the lazy sibling source in serialiser_run
# resolves correctly under plain tclsh and inside the safe interp's access path.
namespace eval fbparse { variable dir [file dirname [info script]] }

# aria-label shapes:
#   "Comment by NAME AGE"
#   "Reply by NAME to OTHER's (comment|reply) AGE"
set ::AGE_PATTERN {(?:\d+|a|an)\s+(?:second|minute|hour|day|week|month|year)s?\s+ago|just now|yesterday(?:\s+at\s+[^"]+?)?|[A-Z][a-z]+\s+\d+(?:,\s*\d{4})?(?:\s+at\s+[^"]+?)?}
# The author group is [^"]+? not Python's .+?: the name lives inside an
# aria-label="..." attribute and never contains a ", so [^"] cannot bridge into
# the next aria-label. This matters because Tcl's ARE is POSIX longest-match,
# where a bare .+? would over-extend across attribute boundaries; [^"] makes the
# split structural and byte-identical to Python's leftmost-first .+? here.
set ::COMMENT_LABEL_RE "aria-label=\"(Comment|Reply) by (\[^\"\]+?)(?:\\s+to\\s+(\[^\"\]+?))?\\s+($::AGE_PATTERN)\""
set ::PROFILE_HREF_RE {href="(https://www\.facebook\.com/(?:profile\.php\?id=\d+|[a-zA-Z0-9._]+)[^"]*comment_id=([^"&]+)[^"]*)"}
# Tempered-greedy body capture (stop at the first </div>) instead of Python's
# .*?: under Tcl's POSIX longest-match a .*? would run to the last </div> and
# swallow sibling comments. (?:(?!</div>).)* stops at the first close, matching
# Python's leftmost-first .*? — including bodies that embed an <a> link.
set ::BODY_DIV_RE {(?s)<div dir="auto" style="text-align:\s*start;">((?:(?!</div>).)*)</div>}

# Decode a Facebook comment_id URL parameter: a URL-encoded base64 of
# `comment:STORY_COMMENT_ID`. Returns the STORY_COMMENT_ID, or the raw param.
proc decode_comment_id {b64_param} {
    # Note: a bare `return` inside the catch body would surface as a TCL_RETURN
    # code that catch reports like an error, so compute into $out and fall
    # through. On any failure (bad base64 / utf-8) keep the raw param, matching
    # the Python except branch.
    if {[catch {
        set raw [url_unquote $b64_param]
        set pad [string repeat "=" [expr {(-[string length $raw]) % 4}]]
        set decoded [encoding convertfrom utf-8 [base64::decode "$raw$pad"]]
        set ci [string first ":" $decoded]
        if {$ci >= 0} {
            # Python split(":", 1)[1]: everything after the FIRST colon.
            set out [string range $decoded [expr {$ci+1}] end]
        } else {
            set out $decoded
        }
    }]} {
        return $b64_param
    }
    return $out
}

# Minimal urllib.parse.unquote: turn %XX into bytes, then decode as UTF-8.
proc url_unquote {s} {
    set out ""
    set n [string length $s]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $s $i]
        if {$ch eq "%" && $i + 2 < $n} {
            set hex [string range $s [expr {$i+1}] [expr {$i+2}]]
            if {[regexp {^[0-9A-Fa-f]{2}$} $hex]} {
                append out [format %c [scan $hex %x]]
                incr i 2
                continue
            }
        }
        append out $ch
    }
    # The %XX bytes are UTF-8; reinterpret.
    return [encoding convertfrom utf-8 $out]
}

# Strip inline tags, unescape entities, collapse whitespace.
proc clean_text {s} {
    set s [regsub -all {<[^>]+>} $s " "]
    set s [fb::unescape $s]
    set s [string trim [regsub -all {\s+} $s " "]]
    return $s
}

# Parse HTML into a structured result dict. $bodies maps legacy_fbid -> full
# body text (from the GraphQL sidecar), used to override truncated DOM bodies.
proc parse_html {html bodies} {
    set title [fb::title $html "Facebook reel"]

    set owner_id ""
    set owner_name ""
    if {[regexp -- {"owner":\{"__typename":"(?:User|Page)","__isActor"(?:(?!"id":")[^\}])*"id":"(\d+)"(?:(?!"name":")[^\}])*"name":"([^"]+)"} $html -> oid oname]} {
        set owner_id $oid
        set owner_name [fb::unescape $oname]
    }

    set total ""
    if {[regexp -- {"total_comment_count":(\d+)} $html -> t]} { set total $t }

    set og_url ""
    if {[regexp -- {<meta property="og:url" content="([^"]+)"} $html -> u]} { set og_url $u }

    # Locate every comment / reply article by its aria-label anchor. With
    # -all -inline -indices the stream is, per match, five index pairs:
    # the whole match then groups 1-4 (kind, author, in_reply_to, age).
    set anchors {}
    foreach {whole kind author inreply age} \
        [regexp -all -inline -indices -- $::COMMENT_LABEL_RE $html] {
        lappend anchors [list \
            [string range $html {*}$kind] \
            [fb::unescape [string trim [string range $html {*}$author]]] \
            [expr {[lindex $inreply 0] >= 0 ? [fb::unescape [string trim [string range $html {*}$inreply]]] : ""}] \
            [string trim [string range $html {*}$age]] \
            [lindex $whole 0]]
    }

    set items {}
    set nanchors [llength $anchors]
    for {set i 0} {$i < $nanchors} {incr i} {
        lassign [lindex $anchors $i] kind author in_reply_to age start
        if {$i + 1 < $nanchors} {
            set end [lindex [lindex $anchors [expr {$i+1}]] 4]
        } else {
            set end [expr {min([string length $html], $start + 30000)}]
        }
        set region [string range $html $start [expr {$end-1}]]

        # Profile URL + comment_id from the header anchor (first 6000 chars).
        set profile_url ""
        set comment_id ""
        set head [string range $region 0 5999]
        if {[regexp -- $::PROFILE_HREF_RE $head -> purl cid]} {
            set profile_url [fb::unescape $purl]
            set comment_id [decode_comment_id $cid]
            regsub -all {[?&]comment_id=[^&]+} $profile_url "" profile_url
            regsub -all {[?&]__cft__[^&]+} $profile_url "" profile_url
            regsub -all {[?&]__tn__=[^&]+} $profile_url "" profile_url
            set profile_url [string map {?& ?} $profile_url]
            set profile_url [string trimright $profile_url "?&"]
        }

        # Body: every <div dir="auto" style="text-align: start;"> block.
        set body_parts {}
        foreach {bwhole bcap} [regexp -all -inline -- $::BODY_DIV_RE $region] {
            set piece [clean_text $bcap]
            if {$piece ne ""} { lappend body_parts $piece }
        }
        set body [join $body_parts "\n"]

        # Backfill with canonical body from the GraphQL sidecar.
        set legacy_fbid ""
        if {$comment_id ne "" && [string first "_" $comment_id] >= 0} {
            set legacy_fbid [lindex [split $comment_id "_"] end]
        }
        set full_text ""
        if {$legacy_fbid ne "" && [dict exists $bodies $legacy_fbid]} {
            set full_text [dict get $bodies $legacy_fbid]
        }
        if {$full_text ne ""} {
            set looks_truncated [expr {
                [string match "*See more" $body] || [string first "… See more" $body] >= 0
            }]
            if {$looks_truncated || [string length $full_text] > [string length $body] + 8} {
                set body $full_text
            }
        }

        lappend items [dict create \
            kind $kind author $author in_reply_to $in_reply_to age $age \
            body $body profile_url $profile_url comment_id $comment_id]
    }

    return [dict create \
        title $title owner_id $owner_id owner_name $owner_name \
        total_comment_count $total og_url $og_url items $items]
}

# Emit raw comments — author, age, body. Replies indented under their parent.
proc to_markdown {data source_url} {
    set out {}
    set items [dict get $data items]
    set rendered [llength $items]
    set reported [dict get $data total_comment_count]
    if {$reported ne "" && $reported > $rendered} {
        set url_part [expr {$source_url ne "" ? " ($source_url)" : ""}]
        lappend out "\[$rendered of $reported comments Facebook reports on this reel$url_part. Facebook's GraphQL endpoint only serves $rendered to a logged-in viewer; the larger header count is an aggregate that includes spam-filtered, community-standards-removed, or cross-universe items the API does not return.\]"
        lappend out ""
    }
    foreach item $items {
        if {[dict get $item kind] eq "Comment"} {
            if {[llength $out]} { lappend out "" }
            lappend out "[dict get $item author] · [dict get $item age]"
            set body [dict get $item body]
            if {$body ne ""} {
                foreach line [split $body "\n"] { lappend out $line }
            } else {
                lappend out "(no text)"
            }
        } else {
            lappend out ""
            set label "  ↳ [dict get $item author] · [dict get $item age]"
            if {[dict get $item in_reply_to] ne ""} {
                append label " (to [dict get $item in_reply_to])"
            }
            lappend out $label
            set body [dict get $item body]
            if {$body ne ""} {
                foreach line [split $body "\n"] { lappend out "  $line" }
            } else {
                lappend out "  (no text)"
            }
        }
    }
    lappend out ""
    return [join $out "\n"]
}

# ---------------------------------------------------------------------------
# Serialiser entry: the user-facing "read a reel's comments" step. A reel's
# comments live behind the authenticated SPA's lazy GraphQL loading, so there is
# no single-dump path: the sibling reel-comments-cdp drives the viewer (clicks
# Comment, expands replies) and harvests the page's GraphQL responses. This entry
# sources that driver (lazily, so the two files never source each other at load)
# and runs the same parse_html + to_markdown here, the single home for rendering.
#
# Invoked by reference through the serialiser (see SKILL.md §9):
#     browser-serialiser facebook.com/parse-reel-comments URL [--max-rounds N]
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set url ""
    set max_rounds 80
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --max-rounds { incr i; set max_rounds [lindex $skillArgs $i] }
            default      { if {$url eq ""} { set url $a } }
        }
    }
    if {$url eq ""} {
        emit "Usage: facebook.com/parse-reel-comments URL \[--max-rounds N\]"
        return
    }
    lassign [fbcdp::sv_fetch $url $max_rounds] html bodies wall
    if {$wall ne ""} {
        emit "ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."
        return
    }
    emit [to_markdown [parse_html $html $bodies] $url]
}

# The reel-comments driver (fbcdp::sv_fetch and its in-page JS) lives in the
# sibling reel-comments-cdp. Source it at load time (the Safe Base's `source`
# works during a file's own load, even with the `eval` verb aliased; a runtime
# source does not). The guard skips the source when the driver is already
# present, so the two files' mutual load-time sources resolve without recursion.
if {![llength [info commands fbcdp::sv_fetch]]} {
    source [file join $::fbparse::dir reel-comments-cdp.tcl]
}

# --- Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a library/skill. ---
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    set html_file ""
    set md_out ""
    set source_url ""
    set bodies_json ""
    set positional {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        switch -- $a {
            --md         { incr i; set md_out [lindex $argv $i] }
            --source-url { incr i; set source_url [lindex $argv $i] }
            --bodies-json { incr i; set bodies_json [lindex $argv $i] }
            default      { lappend positional $a }
        }
    }
    if {[llength $positional] != 1} {
        puts stderr "Usage: parse-reel-comments.tcl HTML_FILE \[--md OUT.md\] \[--source-url URL\] \[--bodies-json SIDECAR.json\]"
        exit 1
    }
    set html_file [lindex $positional 0]

    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8

    set html [fb::read_file $html_file]

    set bodies [dict create]
    if {$bodies_json ne ""} {
        set bj [fb::read_file $bodies_json]
        set bodies [json::json2dict $bj]
    }

    set data [parse_html $html $bodies]
    set md [to_markdown $data $source_url]

    if {$md_out ne ""} {
        set f [open $md_out w]
        fconfigure $f -encoding utf-8
        puts -nonewline $f $md
        close $f
        set comments 0
        set replies 0
        foreach x [dict get $data items] {
            if {[dict get $x kind] eq "Comment"} { incr comments } else { incr replies }
        }
        puts stderr "Wrote [fb::commafy [string length $md]] bytes to $md_out ($comments comments + $replies replies)"
    } else {
        puts -nonewline $md
    }
}
