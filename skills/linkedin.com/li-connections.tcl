# li-connections.tcl - the li-connections B-job playbook, run inside the serialiser
# harness. Home: skillbooks/skills/linkedin.com/li-connections.tcl
#
# Enumerates the LOGGED-IN member's OWN full connection list - the people the My
# Network "Connections" page lists, NOT connections-of.tcl's faceted-search surface
# (that one is a mutuals-gated view of a THIRD party's network). It opens the
# connections page, harvests the page's own voyager relationships-connections
# GraphQL request (for the live queryId, which LinkedIn rotates), re-issues that
# fetch in-page over the page's cookies, and emits the CANONICAL connections
# envelope the BI server's persist consumes. The analogue of li-inbox.
#
# Paged: LinkedIn's connections list is offset-paged (start/count). The cursor in
# and out lives in the envelope - {cursor} arrives in the args JSON, {cursor,
# hasMore} go out - and the overseer's drainPaged loops this playbook over /run,
# carrying the cursor to the frontier. The cursor is the next `start` offset.

source [file join [file dirname [info script]] li-canonical.tcl]

# The page size LinkedIn's own connections page requests. Also the frontier gauge:
# a page that returns a full COUNT implies another page; a short page is the tail.
set ::LI_CONN_COUNT 40

# A fallback queryId for when page-discovery misses it. LinkedIn ROTATES these
# hashes; discovery from the live page (discover_connections) is the primary path
# and self-heals, so this is only a fallback. Refresh by opening the My Network
# connections page in DevTools and reading the relationships-connections request's
# queryId. (Unverified against the live site - see the Step-6 live checklist.)
set ::LI_CONN_QUERY_DEFAULT voyagerRelationshipsDashConnections.00000000000000000000000000000000

# Open the connections page and read its OWN voyager request URLs from the network
# cache, the way discover_messaging does for the inbox. The URLs carry the live
# queryId hash (which LinkedIn rotates); the page fetches its own connections list,
# so its request is what we harvest and re-issue. Returns {connQueryId <id>} ("" if
# not seen). The nav also leaves the browser on a same-origin page, so a following
# fetch_voyager (own identity, the connections fetch) authenticates on its cookies.
proc discover_connections {} {
    set triples [capture "https://www.linkedin.com/mynetwork/invite-connect/connections/" --seconds 12 --match *voyager*]
    set connQ ""
    foreach t $triples {
        set url [lindex $t 0]
        if {$connQ eq "" && [regexp {queryId=(voyagerRelationshipsDashConnections\.[0-9a-f]+)} $url -> q]} { set connQ $q }
    }
    return [dict create connQueryId $connQ]
}

# The connections response (normalized {data, included}) -> one CANONICAL
# connections page result. The `included` list carries two entity types we read:
#   com.linkedin.voyager.dash.relationships.Connection - one connection, with the
#       connected-on fact (createdAt, epoch millis) and a ref to the member
#   com.linkedin.voyager.dash.identity.profile.Profile - the member's card
#       (firstName, lastName, publicIdentifier)
# ownProfileUrn is the logged-in member's own profile urn (own_profile_urn),
# captured from the session the way li-inbox captures its identity.
proc parse_li_connections {body ownProfileUrn} {
    set d [::json::json2dict $body]
    set included [dict_get_or $d included {}]
    set profByUrn [dict create]
    set conns {}
    foreach e $included {
        switch -- [dstr $e {$type}] {
            com.linkedin.voyager.dash.identity.profile.Profile {
                set u [dstr $e entityUrn]
                if {$u ne ""} { dict set profByUrn $u $e }
            }
            com.linkedin.voyager.dash.relationships.Connection { lappend conns $e }
        }
    }
    set cj {}
    foreach c $conns {
        # The connection urn embeds the member's profile urn; that is the key.
        set purn [profile_urn_of [dstr $c entityUrn]]
        # The member card resolves inline, via a *ref into `included`, or by the
        # embedded profile urn - try each so a shape shift still resolves the name.
        set prof ""
        set inline [dict_get_or $c connectedMemberResolutionResult ""]
        if {$inline ne "" && $inline ne "null" && [llength $inline] > 1} {
            set prof $inline
        } else {
            set ref [dict_get_or $c {*connectedMemberResolutionResult} ""]
            if {$ref ne "" && [dict exists $profByUrn $ref]} { set prof [dict get $profByUrn $ref] }
        }
        if {$prof eq "" && $purn ne "" && [dict exists $profByUrn $purn]} {
            set prof [dict get $profByUrn $purn]
        }
        if {$purn eq "" && $prof ne ""} { set purn [profile_urn_of [dstr $prof entityUrn]] }
        if {$purn eq ""} { continue }

        set first ""; set last ""; set slug ""
        if {$prof ne ""} {
            set first [dstr $prof firstName]
            set last  [dstr $prof lastName]
            set slug  [dstr $prof publicIdentifier]
        }
        set url [expr {$slug eq "" ? "" : "https://www.linkedin.com/in/$slug/"}]
        set connectedAt [ms_to_date [dstr $c createdAt]]
        lappend cj [json::write object \
            profile_urn  [j_str $purn] \
            first_name   [j_strornull $first] \
            last_name    [j_strornull $last] \
            profile_url  [j_strornull $url] \
            connected_at [j_strornull $connectedAt]]
    }
    return [json::write object \
        ownProfileUrn [j_strornull $ownProfileUrn] \
        connections   [json::write array {*}$cj]]
}

# How many Connection entities this page carried - the frontier gauge. Counted off
# the raw body (cheap, no second json2dict) since it only drives hasMore.
proc connections_page_count {body} {
    return [regexp -all {relationships\.Connection"} $body]
}

proc pb_li_connections {a} {
    set cursor [dict_get_or $a cursor ""]
    set start [expr {($cursor eq "" || $cursor eq "null") ? 0 : $cursor}]
    if {![string is integer -strict $start]} { set start 0 }
    set count $::LI_CONN_COUNT

    set disc [discover_connections]
    set connQ [dict get $disc connQueryId]
    if {$connQ eq ""} { set connQ $::LI_CONN_QUERY_DEFAULT }
    # Own identity: discover_connections left the browser on the same-origin
    # mynetwork page, so this in-page fetch authenticates on its cookies.
    set own [own_profile_urn]

    # The variables are literal (int offsets + an enum), so no value needs encoding,
    # the way li-inbox leaves its parens/colons literal and only encodes values.
    set url "https://www.linkedin.com/voyager/api/graphql?variables=(start:$start,count:$count,sortType:RECENTLY_ADDED)&queryId=$connQ"
    set body [fetch_voyager $url]
    set result [parse_li_connections $body $own]

    set n [connections_page_count $body]
    set hasMore [expr {$n >= $count ? 1 : 0}]
    set nextCursor [expr {$hasMore ? [expr {$start + $count}] : ""}]
    return [dict create result $result cursor $nextCursor hasMore $hasMore]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_li_connections $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}

# --- direct-tclsh entry (offline parser self-test against a saved body) ------
# Skipped when sourced as a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    if {[llength $argv] < 1} {
        puts stderr "Usage: li-connections.tcl <conns.json> \[ownProfileUrn\]"
        exit 1
    }
    lassign $argv file own
    set f [open $file r]; fconfigure $f -encoding utf-8; set body [read $f]; close $f
    puts [parse_li_connections $body $own]
}
