# whoami.tcl - report who the logged-in session is, run inside the serialiser
# harness. Home: skillbooks/skills/linkedin.com/whoami.tcl
#
# The cheapest identity-plus-liveness probe: one voyager request against
# /voyager/api/me, the tiny self endpoint every LinkedIn page loads - the same
# endpoint the other verbs use to capture their own identity (own_profile in
# li-canonical.tcl). It navs to the feed (view-before-fetch, and the feed walls
# a logged-out session into a terminal state), fetches /me in-page, and emits
# the CANONICAL envelope. A body that names no member (a sign-in body) is a
# fault, not a result - the same dead-session signal the other verbs raise.

source [file join [file dirname [info script]] li-canonical.tcl]

# parse_me's dict -> the canonical whoami result JSON. Errors login_wall when the
# body names no member: the session is dead, and that is a fault, never a result.
proc whoami_result {me} {
    set urn [dict get $me urn]
    if {$urn eq ""} { error "login_wall: /voyager/api/me names no member (signed out)" }
    set first [dict get $me first_name]
    set last  [dict get $me last_name]
    return [json::write object \
        profile_urn       [j_str $urn] \
        first_name        [j_strornull $first] \
        last_name         [j_strornull $last] \
        name              [j_strornull [string trim "$first $last"]] \
        public_identifier [j_strornull [dict get $me public_identifier]]]
}

proc pb_whoami {a} {
    # View-before-fetch: the feed is a same-origin page so the in-page /me fetch
    # authenticates on the session cookies, and a logged-out feed nav is
    # classified into a terminal wall.
    nav "https://www.linkedin.com/feed/" --wait 4
    if {[dict get [state] terminal] ne ""} { error "login_wall: feed view hit a wall" }
    set body [fetch_voyager "https://www.linkedin.com/voyager/api/me"]
    return [dict create result [whoami_result [parse_me $body]] cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_whoami $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}

# --- direct-tclsh entry (offline parser self-test against a saved /me body) --
# Skipped when sourced as a serialiser skill (no argv0 match). Emits the full
# envelope, so the fault path (a logged-out body) is offline-testable too.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    if {[llength $argv] < 1} {
        puts stderr "Usage: whoami.tcl <me.json>"
        exit 1
    }
    lassign $argv file
    set f [open $file r]; fconfigure $f -encoding utf-8; set body [read $f]; close $f
    if {[catch {whoami_result [parse_me $body]} r]} {
        puts [envelope_fault $r]
    } else {
        puts [envelope_ok [dict create result $r cursor "" hasMore 0]]
    }
}
