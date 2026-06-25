# li-canonical.tcl - the canonical LinkedIn messaging parsers and envelope builders
# the B-job playbooks (li-inbox, li-thread) share.
# Home: overseer-toolbox/skills/linkedin.com/li-canonical.tcl
#
# A playbook runs inside the serialiser harness's safe interp: it `nav`s to the
# messaging page a human views, fetches the voyager messaging GraphQL body with an
# in-page `eval` fetch (the generic `api` verb hardcodes Instagram's CSRF scheme,
# and LinkedIn voyager wants csrf-token=JSESSIONID + x-restli-protocol-version, so
# the playbook fetches in-page where the page's own cookies authenticate it), feeds
# that body through the parsers here, and `emit`s the CANONICAL envelope
# {result, cursor, hasMore, fault} the BI server's persist consumes. The parse lives
# on the overseer (not the server), the same split the Instagram skills use.
#
# Pure Tcl over tcllib json - no socket, exec, or file - so it runs unchanged in the
# safe interp. The data is LinkedIn's normalized GraphQL envelope: {data, included}
# where `included` is a flat list of entities, each tagged with a $type and an
# entityUrn. Messaging carries three entity types:
#   com.linkedin.messenger.Conversation         - a thread
#   com.linkedin.messenger.MessagingParticipant - a person in a thread
#   com.linkedin.messenger.Message              - one message
#
# The canonical `result` per pageType:
#   li-inbox  {ownProfileUrn, threads:[{conversation_urn, backend_thread_urn,
#              is_group, title, last_activity, created_at, unread_count, unread,
#              category, participants:[{profile_urn, first_name, last_name,
#              profile_url}]}]}
#   li-thread {conversationUrn, complete, participants:[{...}],
#              messages:[{message_urn, sender_profile_urn, sent_at, body}]}

package require json
package require json::write
::json::write indented 0
::json::write aligned 0

# --- small utilities --------------------------------------------------------
proc dict_get_or {d key default} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}
# value or "" ; a present JSON null (json2dict -> "null") is treated as absent.
proc dstr {d key} {
    if {[dict exists $d $key]} { set v [dict get $d $key]; if {$v eq "null"} { return "" }; return $v }
    return ""
}
proc dbool {d key} { set v [dstr $d $key]; return [expr {($v eq "true" || $v eq "1") ? 1 : 0}] }

# AttributedText -> its plain .text (the shape LinkedIn wraps names/bodies in).
proc attr_text {d key} {
    if {![dict exists $d $key]} { return "" }
    set v [dict get $d $key]
    if {$v eq "null" || $v eq ""} { return "" }
    return [dstr $v text]
}

# The bare profile id urn (urn:li:fsd_profile:ACoAA...) carried inside any of the
# longer messaging refs (msg_messagingParticipant:urn:li:fsd_profile:..., or a
# msg_conversation:(urn:li:fsd_profile:...,2-...)). The profile id is the account key.
proc profile_urn_of {ref} {
    if {[regexp {urn:li:fsd_profile:[A-Za-z0-9_-]+} $ref m]} { return $m }
    return ""
}

# LinkedIn ms-since-epoch -> naive UTC MySQL DATETIME "YYYY-MM-DD HH:MM:SS".
# "" for an absent/unparseable input (the caller emits JSON null).
proc ms_to_mysql {ms} {
    if {$ms eq "" || $ms eq "null"} { return "" }
    if {![regexp {^-?\d+$} $ms]} { return "" }
    return [clock format [expr {$ms / 1000}] -gmt 1 -format {%Y-%m-%d %H:%M:%S}]
}

# --- JSON value emitters (explicit shapes, control chars escaped) -----------
proc jq {s} {
    set out "\""
    foreach ch [split $s ""] {
        switch -- $ch {
            "\"" { append out {\"} } "\\" { append out {\\} } "\n" { append out {\n} }
            "\r" { append out {\r} } "\t" { append out {\t} } "\b" { append out {\b} }
            "\f" { append out {\f} }
            default {
                scan $ch %c code
                if {$code < 0x20} { append out [format {\u%04x} $code]
                } elseif {$code < 0x7f} { append out $ch
                } elseif {$code > 0xffff} {
                    set c [expr {$code - 0x10000}]
                    append out [format {\u%04x\u%04x} [expr {0xd800 + ($c >> 10)}] [expr {0xdc00 + ($c & 0x3ff)}]]
                } else { append out [format {\u%04x} $code] }
            }
        }
    }
    return "$out\""
}
proc j_str {s}       { return [jq $s] }
proc j_strornull {s} { return [expr {$s eq "" || $s eq "null" ? "null" : [jq $s]}] }
proc j_bool {b}      { return [expr {$b ? "true" : "false"}] }
proc j_intornull {v} { return [expr {$v eq "" || $v eq "null" ? "null" : $v}] }

# --- normalized-entity indexing ---------------------------------------------
# Index the `included` list by entityUrn, and bucket by $type. Returns a dict
# {byUrn {<urn> <entity> ...} conversations {<entity> ...} messages {...}
#  participants {...}}.
proc index_included {body} {
    set d [::json::json2dict $body]
    set included [dict_get_or $d included {}]
    set byUrn [dict create]
    set convs {}; set msgs {}; set parts {}
    foreach e $included {
        set urn [dstr $e entityUrn]
        if {$urn ne ""} { dict set byUrn $urn $e }
        switch -- [dstr $e {$type}] {
            com.linkedin.messenger.Conversation         { lappend convs $e }
            com.linkedin.messenger.Message              { lappend msgs $e }
            com.linkedin.messenger.MessagingParticipant { lappend parts $e }
        }
    }
    return [dict create byUrn $byUrn conversations $convs messages $msgs participants $parts]
}

# One MessagingParticipant -> the canonical account shape, or "" if not a member
# (LinkedIn also models org/non-member participants; we mirror people).
proc participant_record {p} {
    set host [dstr $p hostIdentityUrn]
    set profileUrn [profile_urn_of $host]
    if {$profileUrn eq ""} { set profileUrn [profile_urn_of [dstr $p entityUrn]] }
    if {$profileUrn eq ""} { return "" }
    set member [dict_get_or [dict_get_or $p participantType {}] member {}]
    set first [attr_text $member firstName]
    set last  [attr_text $member lastName]
    set url   [dstr $member profileUrl]
    return [json::write object \
        profile_urn [j_str $profileUrn] \
        first_name  [j_strornull $first] \
        last_name   [j_strornull $last] \
        profile_url [j_strornull $url]]
}

# Map profile_urn -> participant_record JSON, for the participants referenced by a
# thread. Built once per parse from the participants bucket.
proc participants_by_profile {idx} {
    set m [dict create]
    foreach p [dict get $idx participants] {
        set rec [participant_record $p]
        if {$rec eq ""} { continue }
        set host [dstr $p hostIdentityUrn]
        set profileUrn [profile_urn_of $host]
        if {$profileUrn eq ""} { set profileUrn [profile_urn_of [dstr $p entityUrn]] }
        if {$profileUrn ne "" && ![dict exists $m $profileUrn]} { dict set m $profileUrn $rec }
    }
    return $m
}

# --- li-inbox parser --------------------------------------------------------
# The conversations response (messengerConversationsBySyncToken) -> one CANONICAL
# inbox page result. ownProfileUrn is the mailbox the page enumerated.
proc parse_li_inbox {body ownProfileUrn} {
    set idx [index_included $body]
    set pmap [participants_by_profile $idx]
    set tj {}
    foreach c [dict get $idx conversations] {
        set convUrn [dstr $c entityUrn]
        if {$convUrn eq ""} { continue }
        # participants: resolve each *conversationParticipants ref to its record.
        set seen [dict create]; set precs {}
        foreach ref [dict_get_or $c {*conversationParticipants} {}] {
            set pu [profile_urn_of $ref]
            if {$pu eq "" || [dict exists $seen $pu]} { continue }
            dict set seen $pu 1
            if {[dict exists $pmap $pu]} { lappend precs [dict get $pmap $pu] }
        }
        set isGroup [expr {[llength [dict_get_or $c {*conversationParticipants} {}]] > 2 ? 1 : 0}]
        set cats [dict_get_or $c categories {}]
        lappend tj [json::write object \
            conversation_urn   [j_str $convUrn] \
            backend_thread_urn [j_strornull [dstr $c backendUrn]] \
            is_group           [expr {$isGroup ? 1 : 0}] \
            title              [j_strornull [dstr $c title]] \
            last_activity      [j_strornull [ms_to_mysql [dstr $c lastActivityAt]]] \
            created_at         [j_strornull [ms_to_mysql [dstr $c createdAt]]] \
            unread_count       [j_intornull [dstr $c unreadCount]] \
            unread             [j_bool [expr {[dstr $c unreadCount] ne "" && [dstr $c unreadCount] > 0}]] \
            category           [j_strornull [lindex $cats 0]] \
            participants       [json::write array {*}$precs]]
    }
    return [json::write object \
        ownProfileUrn [j_strornull $ownProfileUrn] \
        threads       [json::write array {*}$tj]]
}

# --- li-thread parser -------------------------------------------------------
# The messages response (messengerMessages) -> one CANONICAL thread result. The
# page carries the most recent messages; `complete` is true when the page is short
# enough that no older page is implied (the playbook sets it).
proc parse_li_thread {body conversationUrn complete} {
    set idx [index_included $body]
    set pmap [participants_by_profile $idx]
    set precs {}
    foreach pu [dict keys $pmap] { lappend precs [dict get $pmap $pu] }
    # messages oldest-first (the response is newest-first; reverse for storage parity).
    set ordered {}
    foreach m [dict get $idx messages] { set ordered [linsert $ordered 0 $m] }
    set mj {}
    foreach m $ordered {
        set murn [dstr $m entityUrn]
        if {$murn eq ""} { continue }
        set sender [profile_urn_of [dstr $m {*sender}]]
        lappend mj [json::write object \
            message_urn        [j_str $murn] \
            sender_profile_urn [j_strornull $sender] \
            sent_at            [j_strornull [ms_to_mysql [dstr $m deliveredAt]]] \
            body               [j_strornull [attr_text $m body]]]
    }
    return [json::write object \
        conversationUrn [j_str $conversationUrn] \
        complete        [j_bool $complete] \
        participants    [json::write array {*}$precs] \
        messages        [json::write array {*}$mj]]
}

# --- envelope ---------------------------------------------------------------
proc envelope_ok {r} {
    set cursor [dict_get_or $r cursor ""]
    set c [expr {$cursor eq "" ? "null" : [json::write string $cursor]}]
    set h [expr {[dict_get_or $r hasMore 0] ? "true" : "false"}]
    return [json::write object result [dict get $r result] cursor $c hasMore $h fault null]
}
proc fault_shape_of {detail} {
    if {[regexp {^([a-z_]+):\s} $detail -> tag] && [lsearch -exact {removed login_wall} $tag] >= 0} { return $tag }
    return unrecognised
}
proc envelope_fault {detail} {
    set shape [fault_shape_of $detail]
    if {$shape ne "unrecognised"} { regsub "^${shape}:\\s+" $detail "" detail }
    set f [json::write object shape [json::write string $shape] \
                                detail [json::write string [string range $detail 0 200]]]
    return [json::write object result null cursor null hasMore false fault $f]
}

# --- runtime browser helpers (only called inside the serialiser safe interp) -
# These reference the `capture`/`eval` verbs, so they run only from a playbook;
# the offline self-test below never calls them.

# Percent-encode a query value the LinkedIn way: unreserved passes, everything
# else (notably : ( ) ,) becomes %XX. urn:li:fsd_profile:X -> urn%3Ali%3A...
proc url_qcomp {s} {
    set out ""
    foreach ch [split $s ""] {
        if {[regexp {[A-Za-z0-9._~-]} $ch]} { append out $ch
        } else {
            foreach byte [split [encoding convertto utf-8 $ch] ""] {
                scan $byte %c code; append out [format %%%02X [expr {$code & 0xff}]]
            }
        }
    }
    return $out
}
# Decode a percent-encoded value harvested from a captured URL.
proc percent_decode {s} {
    set s [string map {+ " "} $s]
    set out ""; set n [string length $s]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $s $i]
        if {$ch eq "%" && $i + 2 < $n} {
            scan [string range $s [expr {$i+1}] [expr {$i+2}]] %x code
            append out [format %c $code]; incr i 2
        } else { append out $ch }
    }
    return [encoding convertfrom utf-8 $out]
}

# Open the messaging page and read its OWN voyager request URLs from the network
# cache. The bodies are not retained for LinkedIn's many small responses, but the
# URLs carry the live queryId hashes (which LinkedIn rotates) and the mailbox urn,
# so the playbook harvests the live shape and re-issues the fetch in-page. Returns
# {convQueryId <id> msgQueryId <id> mailbox <urn>} (any field "" if not seen).
proc discover_messaging {} {
    set triples [capture "https://www.linkedin.com/messaging/" --seconds 12 --match *voyager*]
    set convQ ""; set msgQ ""; set mailbox ""
    foreach t $triples {
        set url [lindex $t 0]
        if {$convQ eq "" && [regexp {queryId=(messengerConversations\.[0-9a-f]+)} $url -> q]} { set convQ $q }
        if {$msgQ eq "" && [regexp {queryId=(messengerMessages\.[0-9a-f]+)} $url -> q]} { set msgQ $q }
        if {$mailbox eq "" && [regexp {mailboxUrn:([^)&]+)} $url -> mb]} { set mailbox [percent_decode $mb] }
    }
    return [dict create convQueryId $convQ msgQueryId $msgQ mailbox $mailbox]
}

# In-page fetch of a voyager URL with LinkedIn's auth headers (csrf-token is the
# JSESSIONID cookie value; the page's cookies carry the session). The body is
# stashed on window and read back in chunks because CDP's eval cannot return a
# 150KB+ value in one message. Raises "login_wall: ..." on 401/403.
proc fetch_voyager {url} {
    set js [string map [list @URL@ [jq $url]] {
      (async () => {
        const j=(document.cookie.match(/JSESSIONID="?([^";]+)"?/)||[])[1]||'';
        const r=await fetch(@URL@,{credentials:'include',headers:{'accept':'application/vnd.linkedin.normalized+json+2.1','csrf-token':j,'x-restli-protocol-version':'2.0.0'}});
        window.__liBody=await r.text();
        return JSON.stringify({status:r.status,len:window.__liBody.length});
      })()
    }]
    set meta [::json::json2dict [eval $js]]
    set status [dict get $meta status]
    if {$status == 401 || $status == 403} { error "login_wall: voyager returned HTTP $status" }
    if {$status < 200 || $status >= 300} { error "voyager fetch failed (HTTP $status)" }
    set total [dict get $meta len]
    set chunk 30000; set body ""
    for {set i 0} {$i < $total} {incr i $chunk} {
        set body $body[eval "(window.__liBody||'').slice($i,[expr {$i+$chunk}])"]
    }
    return $body
}

# --- direct-tclsh entry (offline parser self-test against a saved body) ------
# Skipped when sourced as a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    if {[llength $argv] < 2} {
        puts stderr "Usage: li-canonical.tcl inbox <conv.json> <ownProfileUrn>"
        puts stderr "       li-canonical.tcl thread <msgs.json> <conversationUrn>"
        exit 1
    }
    lassign $argv mode file arg
    set f [open $file r]; fconfigure $f -encoding utf-8; set body [read $f]; close $f
    switch -- $mode {
        inbox  { puts [parse_li_inbox $body $arg] }
        thread { puts [parse_li_thread $body $arg 1] }
        default { puts stderr "unknown mode $mode"; exit 1 }
    }
}
