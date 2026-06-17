# ig-posts.tcl - the ig-posts B-job playbook, run inside the serialiser harness.
# Home: overseer-toolbox/skills/instagram.com/ig-posts.tcl
#
# Fetches a public profile's recent posts (the api-fetch method: view instagram.com,
# then fetch the private feed/user endpoint in-page over the page's own cookies) and
# emits the CANONICAL posts envelope the BI server consumes. The harness's
# view-before-fetch table covers feed/user, so the nav to instagram.com authorises
# the api call. The B-harness's walkMembers calls this per public member after the
# member's ig-profile resolves their numeric user id.

source [file join [file dirname [info script]] ig-canonical.tcl]

proc pb_ig_posts {a} {
    set userId [dict_get_or $a userId ""]
    set limit [dict_get_or $a limit 12]
    set data [::json::json2dict [api "/api/v1/feed/user/$userId/?count=$limit" --headers [ig_api_headers]]]
    if {![dict exists $data items]} { error "no items array in feed response" }
    set pj {}
    foreach item [dict get $data items] { lappend pj [post_json $item] }
    set result [json::write object posts [json::write array {*}$pj]]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    nav "https://www.instagram.com/"
    if {[catch {pb_ig_posts $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
