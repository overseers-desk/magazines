# auth-ig-posts.tcl - the ig-posts B-job playbook, run inside the serialiser harness.
#
# Reads a public profile's recent posts from the profile grid's own GraphQL
# timeline, whose items carry the REST item shape post_json maps, and emits the
# CANONICAL posts envelope the BI server consumes. The grid is reached by the
# profile URL, which takes a username, so the args dict needs `username`
# beside `userId`. (The REST feed /api/v1/feed/user/<id>/ answers Instagram's
# HTML 404 page, observed 2026-10-29 and again 2026-11-05.)

source [file join [file dirname [info script]] ig-canonical.tcl]
source [file join [file dirname [info script]] lib fetch-recent-posts.tcl]

proc pb_ig_posts {a} {
    set username [string trimleft [dict_get_or $a username ""] @]
    set limit [dict_get_or $a limit 12]
    if {$username eq ""} {
        error "ig-posts needs `username` in its args: the profile grid is reached by username, and the feed/user endpoint for a bare userId is gone"
    }
    set items [ig::sv_fetch_feed $username $limit more]
    set pj {}
    foreach item $items { lappend pj [post_json $item] }
    # The owner's ids, from the first item's user object, surfaced as
    # ownerPk/ownerFbid so the caller has the long id without re-walking the
    # profile; "" when the item omits it.
    set owner [expr {[llength $items] ? [dict_get_or [lindex $items 0] user {}] : {}}]
    set result [json::write object \
        posts     [json::write array {*}$pj] \
        ownerPk   [j_strornull [user_pk $owner]] \
        ownerFbid [j_strornull [user_fbid $owner]]]
    return [dict create result $result cursor "" hasMore $more]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    nav "https://www.instagram.com/"
    if {[catch {pb_ig_posts $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
