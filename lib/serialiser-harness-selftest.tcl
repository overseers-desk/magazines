#!/usr/bin/env tclsh
# serialiser-harness-selftest.tcl - offline check of the harness's site
# confinement (the optional 4th serialiser::run argument) and the SiteOf fold.
#
# No browser: a fake cdp::Client stands in, with a redirect map so a nav can
# land somewhere other than where it was pointed, the silent-rebase drift the
# confinement exists to catch. Pacing is zeroed for the runs because the fold
# and the confinement decisions are under test here, not the cadence. The tiny
# probe skills are written to a scratch directory at runtime and removed on
# success (left in place on a failure, for inspection).
#
#   tclsh serialiser-harness-selftest.tcl
#
# Exits non-zero on the first mismatch; prints PASS per case otherwise.

package require json

set here [file dirname [file normalize [info script]]]
::tcl::tm::path add $here
package require cdp                                ;# the harness's Sleep reads ::cdp::PumpMode
source [file join $here serialiser-harness.tcl]

proc fail {msg} { puts "FAIL: $msg"; exit 1 }

# Root anchors the safe interp's skills/lib access path; the probe skills
# themselves live outside it (run takes an absolute path, and the safe interp
# is granted the skill's own directory wherever it is).
serialiser::setRoot [file normalize [file join $here .. ..]]
set serialiser::PaceDefaults {
    nav   {base 0 jitter 0}
    api   {base 0 jitter 0}
    click {base 0 jitter 0}
    type  {base 0 jitter 0}
}

# --- SiteOf: the registrable-site fold, the shared half of the cross-repo
# --- confinement contract (the runner folds with the same rule on its side).
foreach {input want} {
    https://WWW.LinkedIn.com:443/feed          linkedin.com
    https://instagram.com/a?next=b             instagram.com
    http://user:pw@deep.shop.example.com.au:8443/x  example.com.au
    https://news.bbc.co.uk/politics            bbc.co.uk
    www.example.org                            example.org
    example.com.                               example.com
    127.0.0.1:9222                             127.0.0.1
    linkedin.com                               linkedin.com
} {
    set got [serialiser::SiteOf $input]
    if {$got ne $want} { fail "SiteOf $input -> $got (want $want)" }
}
puts "PASS SiteOf folds host spellings to the registrable site"

# --- The stand-in client: one proc dispatching on the method word, since that
# --- is all the harness does with $Cdp (no instances needed, the cases run one
# --- at a time). $redirects maps a requested URL to its landing; anything
# --- unmapped lands where it was pointed. The title is benign so ClassifyWall
# --- stays quiet.
namespace eval fakecdp {
    variable Url ""
    variable Redirects {}
}
proc fakecdp::reset {redirects} {
    variable Url
    variable Redirects
    set Url ""
    set Redirects $redirects
}
proc fakecdp {method args} {
    upvar #0 fakecdp::Url Url fakecdp::Redirects Redirects
    switch -- $method {
        cdp - cdpBuffered {
            lassign $args cdpMethod params
            if {$cdpMethod eq "Page.navigate"} {
                set u [dict get $params url]
                set Url [expr {[dict exists $Redirects $u] ? [dict get $Redirects $u] : $u}]
            }
            return {}
        }
        evaluate {
            set js [lindex $args 0]
            if {$js eq {window.location.href}} { return $Url }
            if {$js eq {document.title}} { return "A quiet page" }
            return ""
        }
        drainEvents - events - clearEvents - close { return {} }
    }
    error "fakecdp: unexpected method '$method'"
}

# --- Probe skills. Each catches the verb's raise so the run reaches its end
# --- and surfaces the terminal through the SERIALISER_TERMINAL errorcode, the
# --- graceful path a contract-following skill takes; what it emitted survives
# --- in serialiser::Run for the assertions even when run raises.
set tmpRoot [expr {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne "" ? $::env(TMPDIR) : "/tmp"}]
set skillDir [file join $tmpRoot serialiser-harness-selftest-[pid]]
file mkdir $skillDir
foreach {name body} {
    nav-each {
        # Nav every arg URL in turn; emit the last landing.
        proc serialiser_run {skillArgs} {
            set last ""
            foreach u $skillArgs { set last [nav $u --wait 0] }
            emit "ok $last"
        }
    }
    nav-catch {
        # Nav the one arg, expecting the verb to raise; emit what state shows.
        proc serialiser_run {skillArgs} {
            if {[catch {nav [lindex $skillArgs 0] --wait 0}]} {
                emit "caught [dict get [state] terminal]"
                return
            }
            emit "no-error"
        }
    }
    cap-catch {
        # As nav-catch, through the capture verb.
        proc serialiser_run {skillArgs} {
            if {[catch {capture [lindex $skillArgs 0] --seconds 0}]} {
                emit "caught [dict get [state] terminal]"
                return
            }
            emit "no-error"
        }
    }
    api-drift {
        # A covering nav on the granted site, then an api naming another site.
        proc serialiser_run {skillArgs} {
            lassign $skillArgs cover site
            nav $cover --wait 0
            if {[catch {api "/api/v1/feed/user/1/" --site $site}]} {
                emit "caught [dict get [state] terminal]"
                return
            }
            emit "no-error"
        }
    }
} {
    set ch [open [file join $skillDir $name.tcl] w]
    puts $ch $body
    close $ch
}

# Run $skill (a probe name) with $navArgs; $site "" runs the 3-arg call, the
# arity older runners use, anything else the confined 4-arg call. Returns a
# dict: ok (1 emitted result returned, 0 raised), out (result or error
# message), code (the -errorcode), emitted (what the skill emitted, read from
# the harness state even when run raised past the return).
proc runprobe {skill redirects navArgs {site ""}} {
    fakecdp::reset $redirects
    set path [file join $::skillDir $skill.tcl]
    if {$site eq ""} {
        set ok [expr {![catch {serialiser::run $path fakecdp $navArgs} out opts]}]
    } else {
        set ok [expr {![catch {serialiser::run $path fakecdp $navArgs $site} out opts]}]
    }
    return [dict create ok $ok out $out \
        code [expr {$ok ? "" : [dict get $opts -errorcode]}] \
        emitted [dict get $serialiser::Run emitted]]
}

# --- 3-arg call unchanged: unconfined, so roaming across sites still passes.
set r [runprobe nav-each {} {https://www.instagram.com/a/ https://other.example/away}]
if {![dict get $r ok] || [dict get $r out] ne "ok https://other.example/away"} {
    fail "3-arg call: want unconfined roam, got $r"
}
puts "PASS 3-arg call unchanged (empty site confines nothing)"

# --- 4-arg, landings on the granted site: exact host and www. sibling both
# --- fold to the grant, and a caller-spelled www. grant folds too.
set r [runprobe nav-each {} {https://instagram.com/a/} instagram.com]
if {![dict get $r ok]} { fail "matching site: $r" }
puts "PASS 4-arg with matching site passes"

set r [runprobe nav-each {} {https://www.instagram.com/b/} instagram.com]
if {![dict get $r ok]} { fail "sibling hostname: $r" }
set r [runprobe nav-each {} {https://instagram.com/c/} www.instagram.com]
if {![dict get $r ok]} { fail "caller-spelled www. grant: $r" }
puts "PASS sibling hostnames of the granted site pass"

# --- Off-site landings terminate off-site: a direct nav to another registrable
# --- site, and a redirect that rebases the landing off the granted site.
set r [runprobe nav-catch {} {https://evil.example/steal} instagram.com]
if {[dict get $r code] ne {SERIALISER_TERMINAL off-site} \
        || [dict get $r emitted] ne "caught off-site"} {
    fail "nav off-site: $r"
}
puts "PASS nav landing on another registrable site terminates off-site"

set r [runprobe nav-catch \
    {https://www.instagram.com/x/ https://evil.example/landing} \
    {https://www.instagram.com/x/} instagram.com]
if {[dict get $r code] ne {SERIALISER_TERMINAL off-site} \
        || [dict get $r emitted] ne "caught off-site"} {
    fail "nav redirected off-site: $r"
}
puts "PASS redirect off the granted site terminates off-site"

set r [runprobe cap-catch {} {https://evil.example/c/} instagram.com]
if {[dict get $r code] ne {SERIALISER_TERMINAL off-site} \
        || [dict get $r emitted] ne "caught off-site"} {
    fail "capture off-site: $r"
}
puts "PASS capture landing off the granted site terminates off-site"

# --- api drift: the covering nav is on the granted site, the api's --site
# --- names another one, so the fetch is refused before it fires.
set r [runprobe api-drift {} {https://www.instagram.com/self/ evil.example} instagram.com]
if {[dict get $r code] ne {SERIALISER_TERMINAL off-site} \
        || [dict get $r emitted] ne "caught off-site"} {
    fail "api drifted site: $r"
}
puts "PASS api with a drifted site terminates off-site"

file delete -force $skillDir
puts "all serialiser-harness confinement cases passed"
