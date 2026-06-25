# li-inbox.tcl - the li-inbox B-job playbook, run inside the serialiser harness.
# Home: overseer-toolbox/skills/linkedin.com/li-inbox.tcl
#
# Enumerates the LinkedIn messaging inbox: opens /messaging/, harvests the page's
# own voyager messengerConversations request (for the live queryId and the mailbox
# urn), re-issues that fetch in-page over the page's cookies, and emits the
# CANONICAL inbox envelope the BI server's persist consumes. The analogue of
# instagram.com/ig-inbox.
#
# One page per run: the messengerConversations call returns the most recent
# conversations (the active inbox). LinkedIn's older-than pagination is a separate
# sync-token walk; this MVP carries no cursor (hasMore=false), so a run mirrors the
# current inbox - which is the set a relationship pipeline cares about. The newSync
# token is left for a future incremental mode.

source [file join [file dirname [info script]] li-canonical.tcl]

# A default queryId for the case the page-discovery misses it. LinkedIn ROTATES
# these hashes; discovery from the live page (discover_messaging) is the primary
# path and self-heals, so this is only a fallback. Refresh by opening /messaging/
# in DevTools and reading the messengerConversations request's queryId.
set ::LI_CONV_QUERY_DEFAULT messengerConversations.0d5e6781bbee71c3e51c8843c6519f48

proc pb_li_inbox {a} {
    set disc [discover_messaging]
    set convQ [dict get $disc convQueryId]
    if {$convQ eq ""} { set convQ $::LI_CONV_QUERY_DEFAULT }
    set mailbox [dict get $disc mailbox]
    if {$mailbox eq ""} { error "could not determine own mailbox urn from the messaging page" }
    set url "https://www.linkedin.com/voyager/api/voyagerMessagingGraphQL/graphql?queryId=$convQ&variables=(mailboxUrn:[url_qcomp $mailbox])"
    set body [fetch_voyager $url]
    set result [parse_li_inbox $body $mailbox]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_li_inbox $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
