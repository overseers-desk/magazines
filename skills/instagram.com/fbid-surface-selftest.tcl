#!/usr/bin/env tclsh
# fbid-surface-selftest.tcl - the account-level fbid_v2 (the long "17841…" Graph id)
# the connector re-keys onto must reach the canonical envelope from every IG surface
# that carries a user object, not the inbox alone. This exercises the pure parsers
# (no harness verbs) with a crafted user object and asserts the long id surfaces,
# the parity of the inbox's memberFbids contract.
#
#   tclsh fbid-surface-selftest.tcl
#
# Exits non-zero on the first mismatch; prints PASS per case otherwise.

package require json

set here [file dirname [info script]]

proc fail {msg} { puts "FAIL: $msg"; exit 1 }

# --- ig-thread: senderFbids aligned with senderPks, from thread.users[] ---------
namespace eval thread {
    source [file join $::here ig-canonical.tcl]
    set msgs {}
    lappend msgs [dict create item_id 1 from_user_id 50496013 \
        timestamp_iso 2024-01-01T00:00:00Z item_type text text hi]
    lappend msgs [dict create item_id 2 from_user_id 14912064 \
        timestamp_iso 2024-01-01T00:01:00Z item_type text text yo]
    # fbid known for the first sender only (the second proves the empty slot).
    set pk2fbid [dict create 50496013 17841400000390789]
    set d [::json::json2dict [parse_thread T123 [dict create messages $msgs complete true] $pk2fbid]]
    if {[dict get $d senderPks] ne {50496013 14912064}} { ::fail "thread senderPks" }
    if {[lindex [dict get $d senderFbids] 0] ne "17841400000390789"} { ::fail "thread senderFbids\[0]" }
    if {[lindex [dict get $d senderFbids] 1] ne ""} { ::fail "thread senderFbids\[1] should be empty" }
    puts "PASS ig-thread: senderFbids aligned with senderPks"
}

# --- ig-posts: ownerPk/ownerFbid from the feed's top-level user -----------------
namespace eval posts {
    source [file join $::here ig-canonical.tcl]
    set owner [dict create pk 50496013 username tabs_tribe fbid_v2 17841400000390789]
    set result [::json::write object \
        posts     [::json::write array] \
        ownerPk   [j_strornull [user_pk $owner]] \
        ownerFbid [j_strornull [user_fbid $owner]]]
    set d [::json::json2dict $result]
    if {[dict get $d ownerPk] ne "50496013"} { ::fail "posts ownerPk" }
    if {[dict get $d ownerFbid] ne "17841400000390789"} { ::fail "posts ownerFbid" }
    puts "PASS ig-posts: ownerFbid (long) and ownerPk (short) surfaced"
}

# --- ig-profile: fbid_v2 from the hydrated JSON near the handle -----------------
namespace eval profile {
    source [file join $::here ig-profile.tcl]
    set html {<html><head>
<meta property="og:title" content="Tabs Tribe (@tabs_tribe) &#8226; Instagram photos">
<meta property="og:description" content="1,234 Followers, 56 Following, 78 Posts">
</head><body>
<span><span>1,234</span></span> followers
<script>{"user":{"username":"tabs_tribe","profile_id":"50496013","fbid_v2":"17841400000390789","follower_count":1234,"following_count":56,"media_count":78,"is_private":false}}</script>
</body></html>}
    set d [::json::json2dict [parse_profile_superset tabs_tribe $html]]
    if {[dict get $d pk] ne "50496013"} { ::fail "profile pk (short)" }
    if {[dict get $d fbid_v2] ne "17841400000390789"} { ::fail "profile fbid_v2 (long)" }
    puts "PASS ig-profile: fbid_v2 (long) surfaced alongside pk (short)"
}

puts "all fbid-surface cases passed"
