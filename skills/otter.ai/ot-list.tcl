# ot-list.tcl - the ot-list B-job playbook, run inside the serialiser harness.
# Home: skills/otter.ai/ot-list.tcl
#
# One page of the Otter recording list per call: opens my-notes (the covering
# view), replays the page's own /forward/api/v1/speeches fetch through
# otter-cdp's cmd_list, and emits the CANONICAL envelope the BI server's
# persist consumes:
#   result  {speeches: [{otid, title, created_at, duration, summary,
#            start_time, process_finished, folder, link}]}
#   cursor  the response's last_load_ts (the next page's resume token)
#   hasMore true when the page came back full (count == pageSize), so the
#           overseer's paged loop asks for the next page
#
# Pagination is MODIFIED-order: passing a cursor makes cmd_list add
# modified_after=1, so the walk runs newest-modified first and a rename bumps
# its recording to the top - which is why the server stamps a WIDE stop-at
# frontier rather than trusting strict recency.
#
# Args JSON: {pageSize?, lastLoadTs?} - and `cursor`, spliced in by the
# overseer's paged loop (last key wins), carries the previous page's
# last_load_ts. lastLoadTs is the caller-supplied first-page resume point; the
# loop's cursor takes precedence once paging is underway.
#
# A login redirect emits envelope_fault "login_wall: ...".

source [file join [file dirname [info script]] ot-canonical.tcl]
source [file join [file dirname [info script]] otter-cdp.tcl]

set ::OT_LIST_PAGE_SIZE 50

proc pb_ot_list {a} {
    set pageSize [dict_get_or $a pageSize $::OT_LIST_PAGE_SIZE]
    if {![string is integer -strict $pageSize] || $pageSize < 1} { set pageSize $::OT_LIST_PAGE_SIZE }
    set cursor [dstr $a cursor]
    if {$cursor eq ""} { set cursor [dstr $a lastLoadTs] }

    ot_covering_view
    lassign [cmd_list serialiser [dict create page_size $pageSize last_load_ts $cursor]] kind doc
    if {$kind ne "json"} { ot_raise $doc }
    if {[catch {::json::json2dict $doc} d]} { error "speeches response is not JSON" }
    if {[dict exists $d error]} { ot_raise $doc }

    # Re-emit each speech with explicit shapes (numbers stay numbers, absent
    # stays null) rather than trusting a lossy dict round-trip of the raw body.
    set sj {}
    foreach s [dict_get_or $d speeches {}] {
        lappend sj [json::write object \
            otid             [j_str [dstr $s otid]] \
            title            [j_strornull [dstr $s title]] \
            created_at       [j_intornull [dstr $s created_at]] \
            duration         [j_intornull [dstr $s duration]] \
            summary          [j_strornull [dstr $s summary]] \
            start_time       [j_intornull [dstr $s start_time]] \
            process_finished [j_bool [dbool $s process_finished]] \
            folder           [j_strornull [ot_folder_name $s]] \
            link             [j_strornull [dstr $s link]]]
    }
    set result [json::write object speeches [json::write array {*}$sj]]

    set next [dstr $d last_load_ts]
    set hasMore [expr {[llength $sj] >= $pageSize && $next ne "" ? 1 : 0}]
    return [dict create result $result cursor $next hasMore $hasMore]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_ot_list $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
