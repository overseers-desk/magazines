# li-thread.tcl - the li-thread B-job playbook, run inside the serialiser harness.
# Home: overseer-toolbox/skills/linkedin.com/li-thread.tcl
#
# Backfills one messaging thread: takes a conversationUrn (from the connector's
# selectReady), harvests the live messengerMessages queryId from the messaging
# page, fetches that thread's messages in-page, and emits the CANONICAL thread
# envelope. The analogue of instagram.com/ig-thread.
#
# One page per run: messengerMessages returns the most recent messages of the
# thread (the page LinkedIn's own client first renders). LinkedIn's older-than
# walk is a deliveredAt-cursor follow-up left for a later mode; the playbook marks
# `complete` true only when the page is short enough that no older page is implied.

source [file join [file dirname [info script]] li-canonical.tcl]

# Fallback queryId; discovery from the live page is primary and self-heals against
# LinkedIn's rotation (see li-inbox.tcl).
set ::LI_MSG_QUERY_DEFAULT messengerMessages.5846eeb71c981f11e0134cb6626cc314

# When a page carries fewer than this many messages, treat the thread as fully
# drained (no older page implied). LinkedIn's first messages page is ~20.
set ::LI_THREAD_PAGE_FULL 20

proc pb_li_thread {a} {
    set convUrn [dict_get_or $a conversationUrn ""]
    if {$convUrn eq ""} { error "no conversationUrn given" }
    set disc [discover_messaging]
    set msgQ [dict get $disc msgQueryId]
    if {$msgQ eq ""} { set msgQ $::LI_MSG_QUERY_DEFAULT }
    set url "https://www.linkedin.com/voyager/api/voyagerMessagingGraphQL/graphql?queryId=$msgQ&variables=(conversationUrn:[url_qcomp $convUrn])"
    set body [fetch_voyager $url]
    # message count drives the complete flag; a short page is the whole thread.
    set idx [index_included $body]
    set complete [expr {[llength [dict get $idx messages]] < $::LI_THREAD_PAGE_FULL ? 1 : 0}]
    set result [parse_li_thread $body $convUrn $complete]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_li_thread $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
