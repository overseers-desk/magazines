# The canonical envelope every skill emits (COMMAND-SURFACE.md). Pure string
# building: no capability, nothing outside the interpreter it runs in.
#
# The harness reads this file and defines these in each skill's sandbox, so a
# skill under `browser-serialiser` calls them without loading anything. A skill
# with a direct-tclsh path sources this file itself, guarded, so the same four
# procedures back both paths from one text.

proc dict_get_or {d key default} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}
# A skill signals a non-default fault shape by leading its error with "<tag>: ".
# The shape is what a caller acts on: "removed" is a page that will not come back
# (skip the handle, stop the thread), "login_wall" is a session to restore,
# "wrong_session" is the wrong account signed in, and "unrecognised" is a fault
# worth retrying. The tag is stripped from the detail so the prose stays human.
proc fault_shape_of {detail} {
    if {[regexp {^([a-z_]+):\s} $detail -> tag] && $tag in {removed login_wall wrong_session}} {
        return $tag
    }
    return unrecognised
}
# The account the page was rendered for (SESSION-CONTRACT.md §4). A site that
# can name its signed-in account defines site_identity; the harness reads it
# from skills/<site>/lib/identity.tcl.
#
# Three states, and a caller acts differently on each, so they are kept apart:
# the key absent means the site declares no source and never had an account to
# name; the key null means the site was asked and named nobody; a string is the
# account. Returns "" for the first, which envelope_ok reads as "omit the key".
#
# Read once per run and remembered: the signed-in account cannot change under
# one browser lease, and on a site whose only source is a request (LinkedIn's
# /voyager/api/me) a read per emit would be a request per emit.
proc run_identity {} {
    if {![llength [info commands site_identity]]} { return "" }
    if {[info exists ::_run_identity]} { return $::_run_identity }
    set ::_run_identity null
    if {![catch {site_identity} v] && $v ne ""} {
        set ::_run_identity [json::write string $v]
    }
    return $::_run_identity
}

proc envelope_ok {r} {
    set cursor [dict_get_or $r cursor ""]
    set c [expr {$cursor eq "" ? "null" : [json::write string $cursor]}]
    set h [expr {[dict_get_or $r hasMore 0] ? "true" : "false"}]
    set pairs [list result [dict get $r result]]
    set who [run_identity]
    if {$who ne ""} { lappend pairs identity $who }
    lappend pairs cursor $c hasMore $h fault null
    return [json::write object {*}$pairs]
}
proc envelope_fault {detail} {
    set shape [fault_shape_of $detail]
    if {$shape ne "unrecognised"} { regsub "^${shape}:\\s+" $detail "" detail }
    set f [json::write object shape [json::write string $shape] \
                detail [json::write string [string range $detail 0 200]]]
    # A fault carries no identity. Its shape says what went wrong, and a run
    # that failed before it navigated has no page whose viewer to name.
    return [json::write object result null cursor null hasMore false fault $f]
}
