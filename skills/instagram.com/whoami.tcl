# whoami.tcl - report who the logged-in Instagram session is, run inside the
# serialiser harness. Home: skills/instagram.com/whoami.tcl
#
# The cheapest identity-plus-liveness probe, and unlike LinkedIn's it needs NO
# api fetch: it navs to instagram.com and reads the ds_user_id cookie, Instagram's
# authoritative name for the logged-in session (ig_viewer_id in ig-canonical).
# ig_assert_logged_in faults login_wall on a logged-out shell first; then the
# cookie is the identity. No cookie means no viewer to name: a login_wall fault,
# never a result - the same dead-session signal the other verbs raise.

source [file join [file dirname [info script]] ig-canonical.tcl]

# The canonical whoami result JSON. identity is the ds_user_id cookie (the viewer
# alone, not a scraped bystander); username is null by design - the consumer names
# the account from its own records (the server's identityLabel, the id's known
# handle), never from a feed-DOM scrape that could name someone else. `identity`
# is the uniform cross-host key the identity-routed lease reads.
proc whoami_result {} {
    set identity [ig_viewer_id]
    if {$identity eq ""} { error "login_wall: instagram.com names no viewer (no ds_user_id cookie)" }
    return [json::write object \
        identity [j_str $identity] \
        username null]
}

proc pb_whoami {a} {
    return [dict create result [whoami_result] cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    nav "https://www.instagram.com/"
    if {[catch {ig_assert_logged_in} r]} { emit [envelope_fault $r]; return }
    if {[catch {pb_whoami $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
