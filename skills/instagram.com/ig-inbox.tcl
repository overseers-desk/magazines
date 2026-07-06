# ig-inbox.tcl - the ig-inbox B-job playbook, run inside the serialiser harness.
# Home: skills/instagram.com/ig-inbox.tcl
#
# Pulls one raw IG inbox page (the api-fetch method: view instagram.com, then fetch
# the private direct_v2/inbox endpoint in-page over the page's own cookies), flattens
# it into the parser-input shape, and emits the CANONICAL inbox page envelope the BI
# server's persistInbox consumes. The harness's view-before-fetch table covers
# direct_v2/inbox, so the nav to instagram.com is what authorises the api call.
#
# One page per run: the cursor in/out lives in the envelope, and the B-harness's
# drainPaged loops this playbook over /run, carrying the cursor to the frontier.

source [file join [file dirname [info script]] ig-canonical.tcl]

# Returns one CANONICAL inbox page result (the parse lives on the overseer). Pulls
# one raw IG inbox page into the parser-input shape, then delegates to parse_inbox -
# the single canonical-emission path shared with the fixture self-test.
proc pb_ig_inbox {a} {
    set cursor [dict_get_or $a cursor ""]
    set q "visual_message_return_type=unseen&persistentBadging=true&limit=20"
    if {$cursor ne ""} { append q "&cursor=[serialiser_urlencode $cursor]" }
    set data [::json::json2dict [api "/api/v1/direct_v2/inbox/?$q" --headers [ig_api_headers]]]
    set inbox [expr {[dict exists $data inbox] ? [dict get $data inbox] : $data}]
    if {![dict exists $inbox threads]} {
        set why [ig_fail_reason $data]
        error "no inbox.threads in response[expr {$why ne "" ? " (IG: $why)" : ""}]"
    }
    set viewerId [user_pk [dict_get_or $data viewer {}]]
    # The identity condition against the fetched payload itself: the inbox names
    # its viewer, so a page fetched under some other session refuses here even if
    # the pre-fetch DOM read had nothing to say. Runs on every page (each page is
    # its own skill run), covering a mid-haul account switch.
    set expect [dict_get_or $a expectSelf ""]
    if {$expect ne "" && $viewerId ne "" && $viewerId ne $expect} {
        error "wrong_session: inbox viewer $viewerId is not the expected account $expect"
    }
    set tin {}
    foreach t [dict get $inbox threads] { lappend tin [inbox_thread_input $t $viewerId] }
    set result [parse_inbox [dict create viewer_id $viewerId threads $tin]]
    return [dict create result $result cursor [dstr $inbox oldest_cursor] hasMore [dbool $inbox has_older]]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    nav "https://www.instagram.com/"
    if {[catch {ig_assert_logged_in} r]} { emit [envelope_fault $r]; return }
    if {[catch {ig_assert_session [dict_get_or $a expectSelf ""]} r]} { emit [envelope_fault $r]; return }
    if {[catch {pb_ig_inbox $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
