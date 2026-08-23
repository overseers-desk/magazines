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
# can name its signed-in account defines site_identity; a site that cannot
# leaves it undefined and the key comes back null, which is the declared
# capability the contract describes.
#
# Read once per run and remembered: the signed-in account cannot change under
# one browser lease, and on a site whose only source is a request (LinkedIn's
# /voyager/api/me) a read per emit would be a request per emit.
proc run_identity {} {
    if {[info exists ::_run_identity]} { return $::_run_identity }
    set ::_run_identity null
    if {[llength [info commands site_identity]]} {
        if {![catch {site_identity} v] && $v ne ""} {
            set ::_run_identity [json::write string $v]
        }
    }
    return $::_run_identity
}

proc envelope_ok {r} {
    set cursor [dict_get_or $r cursor ""]
    set c [expr {$cursor eq "" ? "null" : [json::write string $cursor]}]
    set h [expr {[dict_get_or $r hasMore 0] ? "true" : "false"}]
    return [json::write object result [dict get $r result] \
                identity [run_identity] cursor $c hasMore $h fault null]
}
proc envelope_fault {detail} {
    set shape [fault_shape_of $detail]
    if {$shape ne "unrecognised"} { regsub "^${shape}:\\s+" $detail "" detail }
    set f [json::write object shape [json::write string $shape] \
                detail [json::write string [string range $detail 0 200]]]
    return [json::write object result null identity [run_identity] \
                cursor null hasMore false fault $f]
}
