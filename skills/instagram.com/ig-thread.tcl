# ig-thread.tcl - the ig-thread B-job playbook, run inside the serialiser harness.
# Home: overseer-toolbox/skills/instagram.com/ig-thread.tcl
#
# Pages one DM thread from raw IG (the api-fetch method: view instagram.com, then
# fetch the private direct_v2/threads endpoint in-page) into the parser-input shape,
# then emits the CANONICAL thread envelope the BI server's persistThread consumes.
# The harness's view-before-fetch table covers direct_v2/threads, so the nav to
# instagram.com is what authorises the api calls; the playbook pages to the thread
# start (the thread envelope carries no cursor - one run drains the whole thread).

source [file join [file dirname [info script]] ig-canonical.tcl]

# Returns the CANONICAL thread result (the parse lives on the overseer). Pages the
# thread from raw IG into the parser-input shape, then delegates to parse_thread -
# the single canonical-emission path shared with the fixture self-test.
proc pb_ig_thread {a} {
    set igThreadId [dict_get_or $a igThreadId ""]
    if {$igThreadId eq ""} { error "no igThreadId given" }
    set limit [expr {[info exists ::env(IG_THREAD_PAGE_LIMIT)] && $::env(IG_THREAD_PAGE_LIMIT) ne ""
                     ? $::env(IG_THREAD_PAGE_LIMIT) : 100}]
    set msgs {}
    set rawItems {}
    set seen {}
    set cursor ""
    set complete 0
    set page 0
    while 1 {
        set q "visual_message_return_type=unseen&direction=older&limit=$limit"
        if {$cursor ne ""} { append q "&cursor=$cursor" }
        set data [::json::json2dict [api "/api/v1/direct_v2/threads/$igThreadId/?$q" --headers [ig_api_headers]]]
        if {![dict exists $data thread] || ![dict exists $data thread items]} {
            set why [ig_fail_reason $data]
            error "no thread.items in response[expr {$why ne "" ? " (IG: $why)" : ""}]"
        }
        set thread [dict get $data thread]
        set added 0
        foreach it [dict get $thread items] {
            set iid [dstr $it item_id]
            if {$iid ne "" && [dict exists $seen $iid]} { continue }
            if {$iid ne ""} { dict set seen $iid 1 }
            lappend rawItems $it
            set itemType [dstr $it item_type]
            set fromId [user_pk $it]; if {$fromId eq ""} { set fromId [dstr $it user_id] }
            # The parser-input message shape (jobs.js parseThread's per-message keys).
            lappend msgs [dict create \
                item_id $iid from_user_id $fromId \
                timestamp_iso [micros_to_iso [dstr $it timestamp]] \
                item_type $itemType text [thread_item_text $it $itemType]]
            incr added
        }
        incr page
        set hasOlder [dstr $thread has_older]
        set oldest [dstr $thread oldest_cursor]
        log "# page $page: +$added items (total [llength $msgs]); has_older=$hasOlder"
        if {$hasOlder eq "false"} { set complete 1; break }
        if {$hasOlder eq "" || $oldest eq ""} { set complete 0; break }
        if {$added == 0} { set complete 0; break }
        set cursor $oldest
    }
    # Raw page items are a debugging concern: log them to the overseer, never into
    # the result the engine maps to rows (parity with ig-thread.js session.log).
    log "ig-thread.raw igThreadId=$igThreadId count=[llength $rawItems]"
    set result [parse_thread $igThreadId [dict create messages $msgs complete $complete]]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    nav "https://www.instagram.com/"
    if {[catch {pb_ig_thread $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
