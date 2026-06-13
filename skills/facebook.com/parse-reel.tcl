#!/usr/bin/env tclsh
# Parse a Facebook reel / page-post permalink for caption, counts, commenters.
#
# Serialiser path (see SKILL.md §6): browser-serialiser facebook.com/parse-reel <post-permalink-url>
#   navigates to the permalink, dumps the rendered DOM, and runs the identical parse.
# Direct path (legacy, file-fed): tclsh parse-reel.tcl <html-file>
#
# The right URL to fetch is the page-post permalink form, not /reel/{id}:
#     https://www.facebook.com/{PAGE_ID}/posts/{POST_ID}
# The /reel/{id} URL returns an empty shell with no rendered content.
#
# Extracts: poster (page name), caption (from <title>), reaction_count /
# total_comment_count / share_count (embedded JSON), creation_time (unix->ISO),
# and visible commenters with the body text closest to each name.
#
# Limits: Facebook lazy-loads comments; a headless single-render yields the
# first ~5-10. The total_comment_count field is the true total.

source [file dirname [info script]]/fb-common.tcl

# Parse from in-memory HTML, the single home for the byte-identical extraction.
proc parse_reel_html {html} {
    set title [fb::title $html ""]
    if {[fb::title_is_login $title]} {
        puts "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        exit 1
    }

    # Bare-shell warning: title is "(16) Facebook"/"Facebook", or ends in
    # "Facebook" with no " - " and no " | " separator.
    if {$title in {"(16) Facebook" "Facebook"} || \
        ([string match "*Facebook" $title] && \
         [string first " - " $title] < 0 && [string first " | " $title] < 0)} {
        puts "WARNING: Title is '$title'. This dump looks like an empty Facebook shell,"
        puts "         not a rendered post. Did you fetch /reel/{id}? Use the"
        puts "         /{page_id}/posts/{post_id} permalink URL instead — see SKILL.md."
        puts ""
    }

    # --- Caption (from the title) ---
    # "(N) <CAPTION_START...> - <PAGE NAME> | Facebook"
    set caption $title
    set page_name ""
    regsub {^\(\d+\)\s*} $caption "" caption
    foreach sep {" | Facebook" " - Facebook"} {
        if {[string match "*$sep" $caption]} {
            set caption [string trim [string range $caption 0 end-[string length $sep]]]
        }
    }
    # rsplit(" - ", 1): split on the LAST " - ".
    set sidx [string last " - " $caption]
    if {$sidx >= 0} {
        set page_name [string trim [string range $caption [expr {$sidx+3}] end]]
        set caption [string trim [string range $caption 0 [expr {$sidx-1}]]]
    }
    set caption [decode_entities_reel $caption]
    if {$page_name ne ""} { set page_name [decode_entities_reel $page_name] }

    puts "Page: [expr {$page_name ne "" ? $page_name : "(unknown)"}]"
    puts "Caption (truncated): $caption"

    # --- Counts from embedded JSON ---
    # Preserve insertion order: total_comment_count, reaction_count,
    # share_count, then creation_time (Python dict order).
    set counts {}
    if {[regexp -- {"total_comment_count":(\d+)} $html -> v]} {
        lappend counts total_comment_count $v
    }
    set rm_start -1
    if {[regexp -indices -- {"reaction_count":\{"count":(\d+)} $html mi ci]} {
        set rm_start [lindex $mi 0]
        lappend counts reaction_count [string range $html [lindex $ci 0] [lindex $ci 1]]
    }
    if {[regexp -- {"share_count":\{"count":(\d+)} $html -> v]} {
        lappend counts share_count $v
    }
    # creation_time near the first reaction_count is the post's own time.
    if {$rm_start >= 0} {
        set ws [expr {$rm_start - 5000}]
        if {$ws < 0} { set ws 0 }
        set window [string range $html $ws [expr {$rm_start-1}]]
        set cts [capture_list $window {"creation_time":(\d{10})}]
        if {[llength $cts]} {
            lappend counts creation_time [lindex $cts end]
        }
    }

    puts ""
    puts "--- Counts (from embedded JSON; authoritative totals) ---"
    if {![llength $counts]} {
        puts "  (none found — this dump probably has no embedded post JSON)"
    } else {
        foreach {k v} $counts {
            if {$k eq "creation_time"} {
                set iso [clock format $v -format {%Y-%m-%dT%H:%M:%S+00:00} -gmt 1]
                puts "  $k: $v  ($iso)"
            } else {
                puts "  $k: [fb::commafy $v]"
            }
        }
    }

    # --- Rendered engagement counts (fallback / cross-check) ---
    set rendered_counts [extract_rendered_engagement $html]
    if {[llength $rendered_counts]} {
        puts ""
        puts "--- Counts (rendered visible text; from engagement bar) ---"
        set labels {reactions comments shares}
        set i 0
        foreach val [lrange $rendered_counts 0 2] {
            set label [expr {$i < [llength $labels] ? [lindex $labels $i] : "slot-$i"}]
            puts "  $label (visible): $val"
            incr i
        }
    }

    # --- Commenter sample from rendered DOM ---
    set span_text {}
    foreach {whole cap} [regexp -all -inline -indices -- {<span[^>]*dir="auto"[^>]*>([^<]+)</span>} $html] {
        set inner [string range $html [lindex $cap 0] [lindex $cap 1]]
        # Python bounded the inner at 1..500 chars; apply as a filter.
        set L [string length $inner]
        if {$L < 1 || $L > 500} { continue }
        lappend span_text [list [lindex $whole 0] [decode_entities_reel [string trim $inner]]]
    }

    # Post region begins at the "<PageName>'s post" header; anything before is
    # the chat sidebar.
    set post_region_start 0
    foreach pt $span_text {
        lassign $pt pos text
        if {[string match "*'s post" $text] || [string match "*’s post" $text]} {
            set post_region_start $pos
            break
        }
    }

    set page_name_norm [string map {& &amp;} $page_name]
    set commenter_names_seen {}
    set commenters {}
    foreach pt $span_text {
        lassign $pt pos text
        if {$pos < $post_region_start} { continue }
        if {$text eq "" || $text eq $page_name || $text eq $page_name_norm} { continue }
        # Page-name variant with entity differences.
        if {$page_name ne "" && \
            [string map {" " ""} $text] eq [string map {" " "" & ""} $page_name]} {
            continue
        }
        if {$text in {More All About Reels Photos Followers "Contact info" Featured Posts "Create group chat" Videos Mentions Reviews Likes}} {
            continue
        }
        # Skip pure engagement numbers.
        if {[regexp -- {^[\d.,]+[KMB]?$} $text]} { continue }
        # Skip page post-header sentences.
        if {[string first "'s post" $text] >= 0 || [string match "*'s post" $text]} { continue }
        # Commenter name: 1-5 capitalised words, no punctuation tail.
        if {![regexp -- {^[A-ZÀ-ſ][\w'\-À-ſ]*(?:\s+[A-ZÀ-ſ][\w'\-À-ſ]*){0,4}$} $text]} { continue }
        if {[dict exists $commenter_names_seen $text]} { continue }
        dict set commenter_names_seen $text 1

        # Body: scan 3500 chars after the name span.
        set after [string range $html $pos [expr {$pos + 3500}]]
        set body_parts {}
        foreach p [capture_list $after {>([^<]+)<}] {
            # Python bound 2..500; apply as filter.
            set Lp [string length $p]
            if {$Lp < 2 || $Lp > 500} { continue }
            set p [string trim $p]
            if {$p eq "" || $p eq $text} { continue }
            if {[is_ui_noise_reel $p]} { continue }
            if {[dict exists $commenter_names_seen $p]} { break }
            lappend body_parts [decode_entities_reel $p]
            if {[string length [join $body_parts " "]] > 600} { break }
        }
        if {[llength $body_parts]} {
            set body [join [lrange $body_parts 0 2] " / "]
        } else {
            set body "(no body extracted)"
        }
        lappend commenters [list $text $body]
    }

    puts ""
    puts "--- Visible commenters in DOM ([llength $commenters]; full total above) ---"
    foreach c $commenters {
        lassign $c cname cbody
        puts "  $cname:"
        puts "    [string range $cbody 0 399]"
    }

    puts ""
    puts "--- End of reel parse ---"
}

# Numeric engagement spans (1..30 chars inner) in DOM order, after the post
# region begins; first three.
proc extract_rendered_engagement {html} {
    set spans {}
    foreach {whole cap} [regexp -all -inline -indices -- {<span[^>]*dir="auto"[^>]*>([^<]+)</span>} $html] {
        set inner [string range $html [lindex $cap 0] [lindex $cap 1]]
        set L [string length $inner]
        if {$L < 1 || $L > 30} { continue }
        lappend spans [list [lindex $whole 0] $inner]
    }
    set post_start 0
    foreach s $spans {
        lassign $s pos inner
        set t [string trim $inner]
        if {[string match "*'s post" $t] || [string match "*’s post" $t]} {
            set post_start $pos
            break
        }
    }
    set rendered {}
    foreach s $spans {
        lassign $s pos inner
        if {$pos < $post_start} { continue }
        set t [string trim $inner]
        if {[regexp -- {^[\d.,]+[KMB]?$} $t]} { lappend rendered $t }
        if {[llength $rendered] >= 3} { break }
    }
    return $rendered
}

proc decode_entities_reel {s} {
    return [string map {
        &amp; & &lt; < &gt; > &#39; ' &quot; \" &#x2F; / &nbsp; " "
    } $s]
}

set ::UI_NOISE_SET {
    Reply Like Edited "Most relevant" "All comments"
    "Write a comment" "View more comments" "View previous comments"
    Send Comment Share Save
}
set ::UI_NOISE_RE {^\d+[dhmws]$|^x[0-9a-z]{7,}|padding|margin|display:|font-|cursor:|overflow|color:|webpack|require\(|exports\.|aria-|tabindex|^Reply\s*\d+$|^\d+\s+(?:Repl(?:y|ies)|Like|Likes)$}

proc is_ui_noise_reel {text} {
    if {$text in $::UI_NOISE_SET} { return 1 }
    if {[regexp -- $::UI_NOISE_RE $text]} { return 1 }
    if {[string index $text 0] eq "\{" || [string index $text 0] eq "."} { return 1 }
    if {[string length $text] < 2} { return 1 }
    return 0
}

proc capture_list {text pat} {
    set out {}
    foreach {whole cap} [regexp -all -inline -- $pat $text] {
        lappend out $cap
    }
    return $out
}

# Legacy file-fed entry: read the file, then run the shared parser.
proc parse_reel {html_path} {
    parse_reel_html [fb::read_file $html_path]
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the post permalink, dump the rendered DOM, run the
# identical parse under fb::capture, emit the report. Pass the page-post
# permalink (https://www.facebook.com/{PAGE_ID}/posts/{POST_ID}); a /reel/{id}
# URL renders an empty shell (the parser warns, as in the file path).
#
# Invoked by reference through the serialiser (see SKILL.md §6):
#     browser-serialiser facebook.com/parse-reel <post-permalink-url>
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set url ""
    foreach a $skillArgs {
        if {[string match "--*" $a]} continue
        set url $a
        break
    }
    if {$url eq ""} {
        emit "Usage: facebook.com/parse-reel <post-permalink-url>"
        return
    }
    nav $url --wait 6
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set html [dump]
    emit [fb::capture out { parse_reel_html $html }]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 1} {
        puts "Usage: parse-reel.tcl <reel-permalink.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_reel [lindex $argv 0]
}
