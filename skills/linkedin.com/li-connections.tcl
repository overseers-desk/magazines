# li-connections.tcl - the li-connections B-job playbook, run inside the serialiser
# harness. Home: skillbooks/skills/linkedin.com/li-connections.tcl
#
# Enumerates the LOGGED-IN member's OWN connection list - the people the My Network
# "Connections" page lists, NOT connections-of.tcl's faceted-search surface (that one
# is a mutuals-gated view of a THIRD party's network). It emits the CANONICAL
# connections envelope the BI server's persist consumes.
#
# Data source: LinkedIn migrated this page off the voyager `voyagerRelationshipsDash
# Connections` GraphQL query to a Server-Driven UI (SDUI) surface. The connection rows
# now arrive as React Server Components "flight" payloads on the rsc-action pagination
# endpoint (sduiid=com.linkedin.sdui.pagers.mynetwork.connectionsList), base64-wrapped
# by CDP. There is no voyager JSON endpoint for connections to re-issue, so this
# playbook does not fetch an API: it navigates the page, lets the page fire its own
# connectionsList pagination requests, harvests those response bodies, and parses the
# flight text. Each card carries the profile /in/<slug>/ link, the member's display
# name (a bold text node), the "Connected on <date>" line, and - inside the "message"
# action's compose link - the fsd_profile urn. All four canonical fields come off the
# flight by pattern, per card.
#
# Single-shot enumerator (SDUI scroll-pagination has no offset cursor the way the old
# start/count query did): one nav gathers page one, then the playbook scrolls to pull
# further pages until the list stops growing (bounded by maxScrolls), dedupes by urn,
# and emits every connection at once. cursor is always "", hasMore always false, so the
# overseer's drainPaged runs it once.
#
# Args JSON (all optional): {maxScrolls}. maxScrolls caps the scroll-to-load-more loop
# (default 50); a caller may lower it to bound a large list.

source [file join [file dirname [info script]] li-canonical.tcl]

set ::LI_CONN_URL "https://www.linkedin.com/mynetwork/invite-connect/connections/"
# The rsc-action responses that carry connection rows all have this in their URL.
set ::LI_CONN_MATCH "*connectionsList*"
set ::LI_CONN_MAX_SCROLLS 50

# A CDP-harvested body is base64 when the response was compressed/binary (the SDUI
# flight is), plain otherwise. Return the flight text either way: a body already
# holding the flight marker is plain; anything else is base64-decoded (best-effort).
proc rsc_text {body} {
    if {[string first "NavigateToUrl" $body] >= 0} { return $body }
    if {[catch {::base64::decode $body} dec]} { return $body }
    return $dec
}

# A "Connected on October 21, 2025" line -> "2025-10-21" (naive date, LinkedIn's
# connected-on granularity). "" when it does not parse.
proc conn_date {raw} {
    if {$raw eq ""} { return "" }
    if {[catch {clock scan $raw -format {%B %d, %Y} -gmt 1} t]} { return "" }
    return [clock format $t -gmt 1 -format {%Y-%m-%d}]
}

# One RSC flight (decoded) -> a list of per-connection dicts {urn slug name date}.
# The flight renders connection cards in order; each card's "message" action carries
# the member's fsd_profile id in a compose link (profileUrn=urn:li:fsd_profile:ACoAA...),
# exactly once per card, so that id segments the flight into cards. Within a card
# segment the profile link (/in/<slug>/), the bold display-name text node, and the
# "Connected on <date>" line resolve the other fields. The bold text node is also used
# for the "Remove connection" button label, so that value is skipped when picking the
# name.
proc parse_rsc_cards {flight} {
    set out {}
    set idxs [regexp -all -inline -indices \
        {profileUrn=urn%3Ali%3Afsd_profile%3A(ACoAA[A-Za-z0-9_-]+)} $flight]
    set segStart 0
    foreach {mIdx gIdx} $idxs {
        lassign $mIdx ms me
        lassign $gIdx gs ge
        set urnid [string range $flight $gs $ge]
        set seg [string range $flight $segStart $me]
        set segStart [expr {$me + 1}]

        set slug ""; regexp {/in/([A-Za-z0-9_%.-]+)/} $seg -> slug
        set name ""
        foreach {full val} [regexp -all -inline \
                {"fontWeight":"bold"[^\]]*?"children":\["([^"]*)"\]} $seg] {
            if {$val ne "" && $val ne "Remove connection"} { set name $val; break }
        }
        set rawdate ""; regexp {Connected on ([^"]+)"} $seg -> rawdate

        lappend out [dict create \
            urn "urn:li:fsd_profile:$urnid" slug $slug name $name date [conn_date $rawdate]]
    }
    return $out
}

# A member display name -> {first last}. LinkedIn renders one "First Last" string
# (the old voyager query gave the two fields split); first token is the given name,
# the remainder the family name. A single-token name leaves last "".
proc split_name {name} {
    set name [string trim $name]
    if {$name eq ""} { return [list "" ""] }
    set parts [split $name " "]
    set first [lindex $parts 0]
    set last [string trim [join [lrange $parts 1 end] " "]]
    return [list $first $last]
}

# A list of card dicts + the own-profile urn -> one CANONICAL connections result.
# Deduped by profile urn (a scroll may re-harvest a page), order preserved.
proc render_li_connections {cards ownProfileUrn} {
    set seen [dict create]
    set cj {}
    foreach c $cards {
        set purn [dict get $c urn]
        if {$purn eq "urn:li:fsd_profile:" || [dict exists $seen $purn]} { continue }
        dict set seen $purn 1
        lassign [split_name [dict get $c name]] first last
        set slug [dict get $c slug]
        set url [expr {$slug eq "" ? "" : "https://www.linkedin.com/in/$slug/"}]
        lappend cj [json::write object \
            profile_urn  [j_str $purn] \
            first_name   [j_strornull $first] \
            last_name    [j_strornull $last] \
            profile_url  [j_strornull $url] \
            connected_at [j_strornull [dict get $c date]]]
    }
    return [json::write object \
        ownProfileUrn [j_strornull $ownProfileUrn] \
        connections   [json::write array {*}$cj]]
}

# Navigate the connections page and harvest every connectionsList rsc-action flight,
# scrolling to load further pages until the connection count stops growing (or
# maxScrolls is hit). Returns the merged list of card dicts. Leaves the browser on the
# same-origin mynetwork page so a following own_profile_urn fetch authenticates.
proc gather_connection_cards {maxScrolls} {
    set triples [capture $::LI_CONN_URL --seconds 14 --match $::LI_CONN_MATCH]
    set cards {}
    foreach t $triples { lappend cards {*}[parse_rsc_cards [rsc_text [lindex $t 2]]] }

    set prev -1
    for {set i 0} {$i < $maxScrolls} {incr i} {
        # count distinct urns so far; stop when a scroll adds none.
        set n [llength [dict keys [urns_of $cards]]]
        if {$n <= $prev} break
        set prev $n
        # Drive the LAST connection card into view (robust to whether the list scrolls
        # on the window or a nested container). That intersection is what fires the
        # SDUI itemDistanceTrigger to fetch the next page. The awaits let the fetch
        # land and buffer before we harvest.
        catch {eval {
            (async () => {
              for (let k = 0; k < 6; k++) {
                const a = document.querySelectorAll('a[href*="/in/"]');
                if (a.length) a[a.length - 1].scrollIntoView({block:"end"});
                window.scrollBy(0, window.innerHeight);
                await new Promise(r => setTimeout(r, 600));
              }
              return document.querySelectorAll('a[href*="/in/"]').length;
            })()
        }}
        dwell 2
        foreach t [harvest --match $::LI_CONN_MATCH] {
            lappend cards {*}[parse_rsc_cards [rsc_text [lindex $t 2]]]
        }
    }
    return $cards
}

# Distinct-urn set of a card list (dedupe gauge for the scroll loop).
proc urns_of {cards} {
    set s [dict create]
    foreach c $cards { dict set s [dict get $c urn] 1 }
    return $s
}

proc pb_li_connections {a} {
    set maxScrolls [dict_get_or $a maxScrolls $::LI_CONN_MAX_SCROLLS]
    if {![string is integer -strict $maxScrolls] || $maxScrolls < 0} {
        set maxScrolls $::LI_CONN_MAX_SCROLLS
    }
    set cards [gather_connection_cards $maxScrolls]
    # Own identity: the nav left the browser on the same-origin mynetwork page, so
    # this in-page /me fetch authenticates on its cookies.
    set own [own_profile_urn]
    set result [render_li_connections $cards $own]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_li_connections $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}

# --- direct-tclsh entry (offline parser self-test against a saved flight) ----
# Feed a decoded RSC connectionsList flight (or its raw base64 body); prints the
# canonical result. Skipped when sourced as a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    if {[llength $argv] < 1} {
        puts stderr "Usage: li-connections.tcl <flight.txt> \[ownProfileUrn\]"
        exit 1
    }
    lassign $argv file own
    set f [open $file r]; fconfigure $f -encoding utf-8; set body [read $f]; close $f
    puts [render_li_connections [parse_rsc_cards [rsc_text $body]] $own]
}
