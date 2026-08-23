#!/usr/bin/env tclsh
# Facebook reel comments: read a reel's comment thread as Markdown.
#
# Usage:
#   browser-serialiser facebook.com/auth-parse-reel-comments URL [--max-rounds N]
#   tclsh auth-parse-reel-comments.tcl <capture.html> [--md PATH] [--source-url URL]

source [file join [file dirname [info script]] lib parse-reel-comments.tcl]
source [file join [file dirname [info script]] lib reel-comments-cdp.tcl]

# A reel's comments load lazily over GraphQL inside the authenticated viewer, so
# there is no single-dump path. The driver in lib/reel-comments-cdp.tcl clicks
# through the viewer and harvests the responses; the parse and the Markdown come
# from lib/parse-reel-comments.tcl.
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
        emit "Usage: facebook.com/auth-parse-reel-comments URL \[--max-rounds N\]"
        return
    }
    lassign [fbcdp::sv_fetch $url $max_rounds] html bodies wall
    if {$wall ne ""} {
        emit "ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."
        return
    }
    emit [to_markdown [parse_html $html $bodies] $url]
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
        puts stderr "Usage: auth-parse-reel-comments.tcl HTML_FILE \[--md OUT.md\] \[--source-url URL\] \[--bodies-json SIDECAR.json\]"
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
