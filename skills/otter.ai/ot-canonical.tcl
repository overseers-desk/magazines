# ot-canonical.tcl - the canonical envelope helpers the Otter B-job playbooks
# (ot-list, ot-fetch, ot-rename) share, plus the small dict/JSON utilities they
# parse Otter's API documents with. Home: skills/otter.ai/ot-canonical.tcl
#
# A playbook runs inside the serialiser harness's safe interp, drives Otter's
# /forward/api/v1/* endpoints through the working procs in otter-cdp.tcl
# (cmd_list / cmd_fetch / cmd_rename, each an in-page fetch over the session's
# own cookies + CSRF token), and `emit`s the CANONICAL envelope
# {result, cursor, hasMore, fault} the BI server's persist consumes - the same
# split the linkedin.com playbooks use (li-canonical is the model for this file).
#
# Pure Tcl over tcllib json - no socket, exec, or file - so it runs unchanged in
# the safe interp. The one browser-touching proc (ot_covering_view) calls the
# policed `nav`/`state` verbs and therefore runs only from a playbook.

package require json
package require json::write
::json::write indented 0
::json::write aligned 0

# --- small utilities --------------------------------------------------------
proc dict_get_or {d key default} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}
# value or "" ; a present JSON null (json2dict -> "null") is treated as absent.
proc dstr {d key} {
    if {[dict exists $d $key]} { set v [dict get $d $key]; if {$v eq "null"} { return "" }; return $v }
    return ""
}
proc dbool {d key} { set v [dstr $d $key]; return [expr {($v eq "true" || $v eq "1") ? 1 : 0}] }

# Otter's `folder` field is an object (its folder_name names the folder) or
# null. Return the folder's display name, "" when absent or unreadable. A
# dict-shaped value without a recognised name key degrades to "" rather than
# leaking a Tcl dict literal into the canonical result.
proc ot_folder_name {s} {
    if {![dict exists $s folder]} { return "" }
    set v [dict get $s folder]
    if {$v eq "null" || $v eq ""} { return "" }
    if {![catch {dict size $v} n] && $n > 0} {
        foreach k {folder_name name} {
            if {[dict exists $v $k] && [dstr $v $k] ne ""} { return [dstr $v $k] }
        }
        return ""
    }
    return $v
}

# --- JSON value emitters (explicit shapes, control chars escaped) -----------
proc jq {s} {
    set out "\""
    foreach ch [split $s ""] {
        switch -- $ch {
            "\"" { append out {\"} } "\\" { append out {\\} } "\n" { append out {\n} }
            "\r" { append out {\r} } "\t" { append out {\t} } "\b" { append out {\b} }
            "\f" { append out {\f} }
            default {
                scan $ch %c code
                if {$code < 0x20} { append out [format {\u%04x} $code]
                } elseif {$code < 0x7f} { append out $ch
                } elseif {$code > 0xffff} {
                    set c [expr {$code - 0x10000}]
                    append out [format {\u%04x\u%04x} [expr {0xd800 + ($c >> 10)}] [expr {0xdc00 + ($c & 0x3ff)}]]
                } else { append out [format {\u%04x} $code] }
            }
        }
    }
    return "$out\""
}
proc j_str {s}       { return [jq $s] }
proc j_strornull {s} { return [expr {$s eq "" || $s eq "null" ? "null" : [jq $s]}] }
proc j_bool {b}      { return [expr {$b ? "true" : "false"}] }
proc j_intornull {v} { return [expr {$v eq "" || $v eq "null" ? "null" : $v}] }

# --- envelope ---------------------------------------------------------------
proc envelope_ok {r} {
    set cursor [dict_get_or $r cursor ""]
    set c [expr {$cursor eq "" ? "null" : [json::write string $cursor]}]
    set h [expr {[dict_get_or $r hasMore 0] ? "true" : "false"}]
    return [json::write object result [dict get $r result] cursor $c hasMore $h fault null]
}
proc fault_shape_of {detail} {
    if {[regexp {^([a-z_]+):\s} $detail -> tag] && [lsearch -exact {removed login_wall} $tag] >= 0} { return $tag }
    return unrecognised
}
proc envelope_fault {detail} {
    set shape [fault_shape_of $detail]
    if {$shape ne "unrecognised"} { regsub "^${shape}:\\s+" $detail "" detail }
    set f [json::write object shape [json::write string $shape] \
                                detail [json::write string [string range $detail 0 200]]]
    return [json::write object result null cursor null hasMore false fault $f]
}

# An error document from otter-cdp's eval_js / cmd_* path ({"error": "..."} or a
# bare string) -> raise it as a fault, classifying a signed-out message into the
# login_wall shape so the persist side reads the wall, not a generic error.
proc ot_raise {doc} {
    set text $doc
    catch {
        set d [::json::json2dict $doc]
        if {[dict exists $d error]} { set text [dict get $d error] }
    }
    if {[string match -nocase "*not logged in*" $text] || [string match -nocase "*sign in*" $text]} {
        error "login_wall: $text"
    }
    error $text
}

# --- runtime browser helper (only called inside the serialiser safe interp) --
# The covering view for Otter's /forward/api/v1/* endpoints: navigate to
# my-notes (the page that itself issues those calls) and read the harness's wall
# classification. A logged-out or checkpoint landing raises the login_wall fault
# the caller's envelope_fault renders; any other terminal state (rate-limited)
# raises with its own name.
proc ot_covering_view {} {
    nav "https://otter.ai/my-notes" --wait 6
    set term [dict get [state] terminal]
    if {$term eq "logged-out" || $term eq "checkpoint"} {
        error "login_wall: otter.ai walled the session ($term); log in via a Chrome-compatible browser first"
    }
    if {$term ne ""} { error "otter.ai terminal state: $term" }
}
