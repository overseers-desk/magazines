# ot-fetch.tcl - the ot-fetch B-job playbook, run inside the serialiser harness.
# Home: skills/otter.ai/ot-fetch.tcl
#
# One recording's transcript: opens my-notes (the covering view), replays the
# recording page's own /forward/api/v1/speech fetch through otter-cdp's
# cmd_fetch (which reconstructs a speaker-labelled transcript from the
# response's segment list), and emits the CANONICAL envelope:
#   result  {otid, title, created_at, duration, segments, transcript}
#   cursor  null, hasMore false (a transcript is one document, never paged)
# `segments` is cmd_fetch's segment COUNT (an integer), not the segment array;
# the raw segments never leave the page in this read.
#
# Args JSON: {otid}. A login redirect emits envelope_fault "login_wall: ...".

source [file join [file dirname [info script]] ot-canonical.tcl]
source [file join [file dirname [info script]] otter-cdp.tcl]

proc pb_ot_fetch {a} {
    set otid [dstr $a otid]
    if {$otid eq ""} { error "ot-fetch requires otid" }

    ot_covering_view
    lassign [cmd_fetch serialiser [dict create otid $otid]] kind doc
    if {$kind ne "json"} { ot_raise $doc }
    if {[catch {::json::json2dict $doc} d]} { error "speech response is not JSON" }
    if {[dict exists $d error]} { ot_raise $doc }
    if {[dstr $d otid] eq ""} { error "speech response carries no otid for $otid" }

    set result [json::write object \
        otid       [j_str [dstr $d otid]] \
        title      [j_strornull [dstr $d title]] \
        created_at [j_intornull [dstr $d created_at]] \
        duration   [j_intornull [dstr $d duration]] \
        segments   [j_intornull [dstr $d segments]] \
        transcript [j_str [dstr $d transcript]]]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_ot_fetch $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
