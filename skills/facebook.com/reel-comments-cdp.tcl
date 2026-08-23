#!/usr/bin/env tclsh
# Facebook reel comments, driven through the viewer.
#
# Usage:
#   browser-serialiser facebook.com/reel-comments-cdp URL [--max-rounds N]
#   tclsh reel-comments-cdp.tcl URL [--out PATH] [--bodies-json PATH] [--debug]

source [file join [file dirname [info script]] lib reel-comments-cdp.tcl]
source [file join [file dirname [info script]] lib parse-reel-comments.tcl]


# Drives the viewer, then runs the same parse and Markdown render the file-fed
# action uses, so both emit the same bytes for one capture.
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
        emit "Usage: facebook.com/reel-comments-cdp URL \[--max-rounds N\]"
        return
    }
    ::log "serialiser_run: calling sv_fetch url=$url max_rounds=$max_rounds"
    lassign [fbcdp::sv_fetch $url $max_rounds] html bodies wall
    ::log "serialiser_run: sv_fetch done wall=$wall bodies=[dict size $bodies] html_len=[string length $html]"
    if {$wall ne ""} {
        emit "ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."
        return
    }
    set data [parse_html $html $bodies]
    ::log "serialiser_run: parse_html done comments=[llength [dict get $data comments]]"
    set md [to_markdown $data $url]
    ::log "serialiser_run: to_markdown len=[string length $md]"
    emit $md
}
# Direct-tclsh entry (legacy CDP). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    # --- Argument parsing ---
    set url ""
    set out_path ""
    set bodies_json ""
    set max_rounds 80
    set positional {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        switch -- $a {
            --out         { incr i; set out_path [lindex $argv $i] }
            --bodies-json { incr i; set bodies_json [lindex $argv $i] }
            --max-rounds  { incr i; set max_rounds [lindex $argv $i] }
            --debug       { set fbcdp::debug 1 }
            default       { lappend positional $a }
        }
    }
    if {[llength $positional] != 1} {
        puts stderr "Usage: reel-comments-cdp.tcl URL \[--out PATH\] \[--bodies-json PATH\] \[--max-rounds N\] \[--debug\]"
        exit 1
    }
    set url [lindex $positional 0]

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser facebook.com/reel-comments-cdp <reel-url> \[--out FILE\]"
        exit 1
    }

    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8

    set c [cdp::connect]
    set rc [catch {fbcdp::fetch $c $url $max_rounds $bodies_json} html]
    catch {$c close}
    if {$rc} {
        error $html
    }

    if {$out_path ne ""} {
        set f [open $out_path w]
        fconfigure $f -encoding utf-8
        puts -nonewline $f $html
        close $f
        puts stderr "wrote [fb::commafy [string length $html]] bytes to $out_path"
    } else {
        puts -nonewline $html
    }
}
