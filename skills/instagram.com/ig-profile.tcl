#!/usr/bin/env tclsh
# Instagram profile read: a handle in, the profile the page shows out.
#
# Usage:
#     browser-serialiser instagram.com/ig-profile <handle>

source [file join [file dirname [info script]] lib ig-profile.tcl]

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
