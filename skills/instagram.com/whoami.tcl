# whoami.tcl - report who the logged-in Instagram session is, run inside the
# serialiser harness. Home: skills/instagram.com/whoami.tcl
#
# The cheapest identity-plus-liveness probe, and unlike LinkedIn's it needs NO
# api fetch: it navs to instagram.com and reads the viewer id straight out of the
# SPA's inline page config - the same "userId"/"viewerId" keys ig_assert_logged_in
# and ig_assert_session read. ig_assert_logged_in faults login_wall on a logged-out
# shell first; then the first non-zero inline id is the identity. A page that names
# no viewer is a dead session - a fault, never a result - the same dead-session
# signal the other verbs raise.

source [file join [file dirname [info script]] ig-canonical.tcl]

# The DOM dump -> the canonical whoami result JSON. Reuses the exact inline-id
# regexp ig_assert_logged_in / ig_assert_session use; the identity is the first
# non-zero id. No non-zero id means a page that names no viewer: a login_wall
# fault, never a result.
proc whoami_result {html} {
    set ids [regexp -inline -all -nocase {"(?:user_?id|viewer_?id)"\s*:\s*\"?([0-9]+)} $html]
    set identity ""
    foreach {whole id} $ids { if {$id ne "0"} { set identity $id; break } }
    if {$identity eq ""} { error "login_wall: instagram.com names no viewer (signed out)" }
    # Best-effort handle; null when the page carries no adjacent "username".
    set username ""
    if {[regexp {"username"\s*:\s*"([^"]*)"} $html -> u]} { set username $u }
    # `identity` is the uniform cross-host key the identity-routed lease reads.
    return [json::write object \
        identity [j_str $identity] \
        username [j_strornull $username]]
}

proc pb_whoami {a} {
    return [dict create result [whoami_result [dump]] cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    nav "https://www.instagram.com/"
    if {[catch {ig_assert_logged_in} r]} { emit [envelope_fault $r]; return }
    if {[catch {pb_whoami $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
