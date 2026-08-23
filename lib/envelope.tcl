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
# A detail line may open with a shape tag the caller reads instead of
# the prose. Anything else is unrecognised.
proc fault_shape_of {detail} {
    if {[regexp {^([a-z_]+):\s} $detail -> tag] && $tag in {removed login_wall}} { return $tag }
    return unrecognised
}
proc envelope_ok {r} {
    set cursor [dict_get_or $r cursor ""]
    set c [expr {$cursor eq "" ? "null" : [json::write string $cursor]}]
    set h [expr {[dict_get_or $r hasMore 0] ? "true" : "false"}]
    return [json::write object result [dict get $r result] \
                cursor $c hasMore $h fault null]
}
proc envelope_fault {detail} {
    set shape [fault_shape_of $detail]
    if {$shape ne "unrecognised"} { regsub "^${shape}:\\s+" $detail "" detail }
    set f [json::write object shape [json::write string $shape] \
                detail [json::write string [string range $detail 0 200]]]
    return [json::write object result null cursor null hasMore false fault $f]
}
    
