# whoami.tcl - report who the logged-in Facebook session is, run inside the
# serialiser harness.
#
# The cheapest identity-plus-liveness probe, built like Instagram's sibling and
# for the same reason: it navs to facebook.com and reads the c_user cookie,
# Facebook's own name for the logged-in account. No api call, no DOM dump, so it
# costs one navigation on a site whose pages run 1-15MB.
#
# c_user is readable from document.cookie (xs, the session secret, is httpOnly
# and is never touched here). A page with no c_user has no viewer to name: that
# is a login_wall fault, never a result, which is the dead-session signal every
# other facebook.com verb raises. The harness's own terminal classification is
# consulted first, so a login or checkpoint redirect is reported as what it is
# rather than as a missing cookie.

package require json::write

namespace eval fb {}

# The canonical whoami result JSON. identity is the c_user cookie, the account
# id Facebook itself carries; the SKILL.md's logged-out marker ("USER_ID":"0" in
# the page config) is the same number seen from the DOM side. name is null by
# design: the consumer names the account from its own records, never from a
# page scrape that could name a bystander. `identity` is the uniform cross-host
# key the identity-routed lease reads, so every host's whoami emits it.
proc whoami_result {} {
    if {[catch {eval {(document.cookie.match(/c_user=(\d+)/)||[])[1]||''}} id]} { set id "" }
    if {$id eq ""} { error "login_wall: facebook.com names no viewer (no c_user cookie)" }
    return [json::write object \
        identity [json::write string $id] \
        name     null]
}

proc fb::envelope_ok {result} {
    return [json::write object result $result cursor null hasMore false fault null]
}

# The fault shape the BI server's persist discriminates on. login_wall is the
# only tag this probe raises; anything else arrives unrecognised, and the tag is
# stripped from the detail so the text stays human.
proc fb::envelope_fault {detail} {
    set shape unrecognised
    if {[regexp {^(login_wall):\s} $detail -> tag]} {
        set shape $tag
        regsub "^${tag}:\\s+" $detail "" detail
    }
    set f [json::write object \
        shape  [json::write string $shape] \
        detail [json::write string [string range $detail 0 200]]]
    return [json::write object result null cursor null hasMore false fault $f]
}

proc serialiser_run {skillArgs} {
    nav "https://www.facebook.com/"
    set st [state]
    set terminal [expr {[dict exists $st terminal] ? [dict get $st terminal] : ""}]
    if {$terminal in {logged-out checkpoint}} {
        emit [fb::envelope_fault "login_wall: facebook.com walled the session ($terminal)"]
        return
    }
    if {[catch {whoami_result} r]} { emit [fb::envelope_fault $r]; return }
    emit [fb::envelope_ok $r]
}
