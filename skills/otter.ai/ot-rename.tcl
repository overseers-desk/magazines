# ot-rename.tcl - the ot-rename B-job playbook, run inside the serialiser
# harness. Home: skills/otter.ai/ot-rename.tcl
#
# Retitles one recording: opens my-notes (the covering view), drives otter-cdp's
# cmd_rename (POST set_speech_title, then a read-back of the list until the new
# title is observed - Otter reports OK even when a rename does not stick), and
# emits the CANONICAL envelope:
#   result  {otid, title, verified}
#   cursor  null, hasMore false
# `verified` is true only when the read-back saw the new title; a rename the
# read-back never confirmed surfaces as a fault, not a false success.
#
# Args JSON: {otid, title}. Title conventions (the `<business>/<name>.txt`
# done-signal, any triage prefix) belong to the caller; this playbook writes
# whatever title it is handed. cmd_rename's non-.txt stderr warning fires for
# non-done-signal titles by design and is diagnostic only.
#
# A login redirect emits envelope_fault "login_wall: ...".

source [file join [file dirname [info script]] ot-canonical.tcl]
source [file join [file dirname [info script]] otter-cdp.tcl]

proc pb_ot_rename {a} {
    set otid [dstr $a otid]
    set title [dstr $a title]
    if {$otid eq "" || $title eq ""} { error "ot-rename requires otid and title" }

    ot_covering_view
    lassign [cmd_rename serialiser [dict create otid $otid new_title $title]] kind doc
    if {$kind ne "json"} { ot_raise $doc }
    if {[catch {::json::json2dict $doc} d]} { error "rename response is not JSON" }
    if {[dict exists $d error]} { ot_raise $doc }

    set result [json::write object \
        otid     [j_str $otid] \
        title    [j_str [dstr $d title]] \
        verified [j_bool [dbool $d verified]]]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_ot_rename $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
