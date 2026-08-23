#!/usr/bin/env tclsh
# session-contract-selftest.tcl - the conformance test for SESSION-CONTRACT.md.
#
# A site adopts the contract by carrying whoami.tcl. From then on every action
# in it carries the auth- or pub- action prefix, and this test fails the suite
# when one does not. Sites that name a signed-in session in their SKILL.md and
# carry no probe yet print as a backlog line, not a failure: adoption is per
# site, and the remaining work stays visible without a second list to drift.
#
# An action is a file defining serialiser_run, the entry proc the harness calls
# (COMMAND-SURFACE.md). A file without it is a library the harness never
# invokes, so no caller names it and a prefix would say nothing.
#
# Run: tclsh lib/session-contract-selftest.tcl
# Exit 0 when every adopted site conforms, 1 with one line per violation.

set root [file dirname [file dirname [file normalize [info script]]]]
set reserved {whoami login}
set failures {}
set backlog {}
set actions 0
set adopted 0

foreach siteDir [lsort [glob -nocomplain -directory [file join $root skills] -type d *]] {
    set site [file tail $siteDir]
    # skills/lib is the committed symlink to ../lib, the shared harness, not a
    # site (COMMAND-SURFACE.md names it as the libDir a caller passes).
    if {$site eq "lib"} continue

    set hasProbe [file exists [file join $siteDir whoami.tcl]]
    if {$hasProbe} { incr adopted }

    if {$hasProbe} {
        foreach f [lsort [glob -nocomplain -directory $siteDir *.tcl]] {
            set name [file rootname [file tail $f]]
            set ch [open $f r]
            set body [read $ch]
            close $ch
            if {![regexp {proc\s+serialiser_run\s} $body]} continue
            incr actions
            if {$name in $reserved} continue
            if {![regexp {^(auth|pub)-} $name]} {
                lappend failures "$site/$name: no action prefix (auth- or pub-)"
            }
        }
        continue
    }

    # Not adopted. A SKILL.md naming a logged-in session is the site's own
    # declaration that it needs one, and the only statement of it. The phrase
    # takes a qualifier on some sites ("a logged-in Economist subscriber
    # session"), so the match allows a few words before "session".
    set skillMd [file join $siteDir SKILL.md]
    if {![file exists $skillMd]} continue
    set ch [open $skillMd r]
    set md [read $ch]
    close $ch
    if {[regexp -nocase {logged-in( [A-Za-z.]+){1,4} session} $md]} {
        lappend backlog $site
    }
}

if {[llength $backlog]} {
    puts "session contract: [llength $backlog] site(s) await a whoami probe: [join [lsort $backlog] {, }]"
}
if {[llength $failures]} {
    puts "session contract: [llength $failures] violation(s) in $adopted adopted site(s)"
    foreach v $failures { puts "  $v" }
    exit 1
}
puts "session contract: $actions action(s) across $adopted adopted site(s) conform"
exit 0
