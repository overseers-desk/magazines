#!/usr/bin/env tclsh
# Find Facebook posts by keyword: inside one group, across Facebook, or by
# browsing a group's recent feed.
#
# Serialiser path (see SKILL.md): browser-serialiser facebook.com/auth-search-posts ...
# Direct path (file-fed): tclsh auth-search-posts.tcl <bodies-file> keyword ...
#
# Three scopes, one script. They differ only in the URL navigated to; the
# harvest, the extraction and the report are shared.
#
# Posts are read from the page's own GraphQL responses rather than the rendered
# DOM. The DOM carries the text of what is on screen but the identity of only a
# fraction of it: a settled in-group search page rendered 10 post bodies while
# embedding post ids for 5, so half the results could not be cited. The same
# page's GraphQL traffic carried 86 posts with id, author, timestamp and full
# text. `capture` is also the harness's intended path for private data, since
# view-before-fetch is intrinsic to it.

source [file join [file dirname [info script]] lib fb-common.tcl]

# ---------------------------------------------------------------------------
# Scope URLs
# ---------------------------------------------------------------------------

# Resolve a group reference to its root URL. A vanity name works anywhere a
# numeric id does, so both pass through the same form.
proc group_url {ref} {
    if {[string match "http*://*" $ref]} { return [string trimright $ref /] }
    return "https://www.facebook.com/groups/[string trim $ref /]"
}

# The group id as it appears in a URL, for building permalinks when a post's
# own record does not carry its group.
proc group_slug {ref} {
    set u [group_url $ref]
    if {[regexp {/groups/([^/?]+)} $u -> slug]} { return $slug }
    return $ref
}

proc url_encode {s} {
    set out ""
    foreach ch [split $s ""] {
        if {[regexp {[a-zA-Z0-9._~-]} $ch]} {
            append out $ch
        } else {
            foreach byte [split [encoding convertto utf-8 $ch] ""] {
                scan $byte %c code
                append out [format %%%02X $code]
            }
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# JSON string decoding
#
# The bodies are read with regexps rather than a JSON parse: they run to several
# megabytes each and the post records sit deep in a normalised GraphQL store, so
# a full parse costs far more than reaching for the handful of fields wanted.
# Only the extracted string bodies need decoding.
# ---------------------------------------------------------------------------

proc json_unescape {s} {
    # \uXXXX first, pairing surrogates so a non-BMP character (emoji are common
    # in these posts) comes out as one character rather than two halves.
    while {[regexp -indices {\\u([0-9a-fA-F]{4})} $s whole hex]} {
        set code [scan [string range $s [lindex $hex 0] [lindex $hex 1]] %x]
        set end [lindex $whole 1]
        if {$code >= 0xD800 && $code <= 0xDBFF} {
            set tail [string range $s [expr {$end+1}] [expr {$end+6}]]
            if {[regexp {^\\u([0-9a-fA-F]{4})$} $tail -> lowhex]} {
                set low [scan $lowhex %x]
                if {$low >= 0xDC00 && $low <= 0xDFFF} {
                    set code [expr {0x10000 + (($code - 0xD800) << 10) + ($low - 0xDC00)}]
                    incr end 6
                }
            }
        }
        set s [string replace $s [lindex $whole 0] $end [format %c $code]]
    }
    return [string map {\\n "\n" \\r "\r" \\t "\t" \\/ / \\\" \" \\\\ \\} $s]
}

# ---------------------------------------------------------------------------
# Extraction
#
# One record per post: the message text, and the id / author / timestamp / group
# that precede it in the same GraphQL node. The fields sit before the message in
# the serialised node, so each is taken as the last occurrence in the window
# ahead of the text.
# ---------------------------------------------------------------------------

proc last_match {window pat} {
    set hits [regexp -all -inline -- $pat $window]
    if {![llength $hits]} { return "" }
    return [lindex $hits end]
}

# How far either side of the message text a post's own fields are taken from.
# Wide enough to clear the reaction and module metadata Facebook serialises
# between them, narrow enough not to reach the neighbouring post.
set POST_FIELD_WINDOW 5000

proc extract_posts {bodies} {
    global POST_FIELD_WINDOW
    set posts {}
    set seen {}
    set pat {"message":\{"text":"((?:[^"\\]|\\.)*)"}
    foreach {whole textIdx} [regexp -all -inline -indices -- $pat $bodies] {
        set raw [string range $bodies [lindex $textIdx 0] [lindex $textIdx 1]]
        set start [lindex $whole 0]
        set ws [expr {$start - $POST_FIELD_WINDOW}]
        if {$ws < 0} { set ws 0 }
        set window [string range $bodies $ws $start]

        set pid [last_match $window {"post_id":"(\d+)"}]
        if {$pid eq "" || [dict exists $seen $pid]} { continue }
        dict set seen $pid 1

        dict set post id $pid
        dict set post text [json_unescape $raw]
        dict set post time [last_match $window {"creation_time":(\d+)}]
        dict set post author [json_unescape [last_match $window {"name":"([^"]{2,60})"}]]

        # The group is named either side of the message depending on the node's
        # shape, so look ahead when the preceding window does not carry it.
        set gid [last_match $window {"target_group":\{"id":"(\d+)"}]
        if {$gid eq ""} {
            set ahead [string range $bodies [lindex $whole 1] [expr {[lindex $whole 1] + $POST_FIELD_WINDOW}]]
            set gid [lindex [regexp -all -inline -- {"target_group":\{"id":"(\d+)"} $ahead] 1]
        }
        dict set post group $gid
        dict set post owner [last_match $window {"profile_id":"(\d+)"}]
        lappend posts $post
    }
    return $posts
}

# True when every term appears in the post text (case-insensitive). An empty
# term list matches everything, which is what browsing a feed unfiltered means.
proc post_matches {text terms} {
    foreach t $terms {
        if {[string first [string tolower $t] [string tolower $text]] < 0} { return 0 }
    }
    return 1
}

proc render_report {posts terms scope_label group_slug} {
    set matched {}
    foreach p $posts {
        if {[post_matches [dict get $p text] $terms]} { lappend matched $p }
    }

    # Newest first: a story lead is worth more while it is current.
    set matched [lsort -integer -decreasing -index 1 [lmap p $matched {
        list $p [expr {[dict get $p time] eq "" ? 0 : [dict get $p time]}]
    }]]
    set matched [lmap pair $matched { lindex $pair 0 }]

    set out "$scope_label\n"
    if {[llength $terms]} { append out "Terms: [join $terms { }]\n" }
    append out "Posts: [llength $matched] matching, [llength $posts] harvested\n\n"

    if {![llength $matched]} {
        append out "No post matching those terms was harvested.\n"
        return $out
    }

    foreach p $matched {
        set when "date unknown"
        if {[dict get $p time] ne ""} {
            set when [clock format [dict get $p time] -format "%Y-%m-%d"]
        }
        set author [dict get $p author]
        if {$author eq ""} { set author "unknown author" }
        # A group post is cited under its group; a Page or profile post, which
        # Facebook-wide search returns freely, is cited under its owner. Naming a
        # non-group post under /groups/ builds a URL that resolves to nothing.
        set gid [dict get $p group]
        if {$gid eq "" && $group_slug ne ""} { set gid $group_slug }
        if {$gid ne ""} {
            set link "https://www.facebook.com/groups/$gid/posts/[dict get $p id]/"
        } elseif {[dict get $p owner] ne ""} {
            set link "https://www.facebook.com/[dict get $p owner]/posts/[dict get $p id]/"
        } else {
            set link "https://www.facebook.com/[dict get $p id]"
        }
        append out "$when  $author\n"
        append out "  $link\n"
        foreach line [split [string trim [dict get $p text]] "\n"] {
            set line [string trim $line]
            if {$line eq ""} { continue }
            append out "  $line\n"
        }
        append out "\n"
    }
    return $out
}

# ---------------------------------------------------------------------------
# Page driving
# ---------------------------------------------------------------------------

# Scroll the window and the tallest scrollable container, so a results list that
# lazy-loads inside its own pane advances as well as one that grows the page.
proc scroll_page {} {
    set expr {(function(){window.scrollTo(0,document.body.scrollHeight);var best=null,bh=0;document.querySelectorAll('div').forEach(function(d){var s=getComputedStyle(d);if((s.overflowY=='auto'||s.overflowY=='scroll')&&d.scrollHeight>d.clientHeight+400&&d.scrollHeight>bh){bh=d.scrollHeight;best=d}});if(best){best.scrollTop=best.scrollHeight}return 1})()}
    catch {eval $expr}
}

# Rendered post bodies currently mounted. Facebook recycles these as the list
# scrolls, so this is a progress signal for the scroll loop, not a result count:
# the results themselves come from the harvested GraphQL bodies.
proc mounted_posts {} {
    set expr {(function(){return document.querySelectorAll('[data-ad-rendering-role="story_message"]').length})()}
    if {[catch {eval $expr} v]} { return 0 }
    if {![string is integer -strict $v]} { return 0 }
    return $v
}

proc serialiser_run {skillArgs} {
    set group ""
    set feed 0
    set max_rounds 25
    set terms {}
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --group { incr i; set group [lindex $skillArgs $i] }
            --feed { set feed 1 }
            --max-rounds { incr i; set max_rounds [lindex $skillArgs $i] }
            default { lappend terms $a }
        }
    }

    if {$group eq "" && ![llength $terms]} {
        emit [envelope_fault "Usage: facebook.com/auth-search-posts \[--group <id|name|url>\] \[--feed\] \[--max-rounds N\] <terms...>"]
        return
    }

    set q [url_encode [join $terms " "]]
    if {$group ne "" && $feed} {
        set url [group_url $group]
        set scope_label "Group feed: [group_slug $group]"
    } elseif {$group ne ""} {
        set url "[group_url $group]/search/?q=$q"
        set scope_label "Group search: [group_slug $group]"
    } else {
        set url "https://www.facebook.com/search/posts/?q=$q"
        set scope_label "Facebook post search"
    }

    capture $url --seconds 8 --match "*/api/graphql/*"
    if {[dict get [state] terminal] ne ""} {
        emit [envelope_fault "login_wall: Facebook: [dict get [state] terminal]. Log in via a Chrome-compatible browser first."]
        return
    }

    # Scroll until the mounted count stops growing. Each scroll makes the page
    # issue another GraphQL page, which the harness buffers for the harvest.
    set last -1
    set stable 0
    for {set r 0} {$r < $max_rounds} {incr r} {
        scroll_page
        dwell 1.5
        set n [mounted_posts]
        log "search-posts: round=$r mounted=$n stable=$stable"
        if {$n == $last} {
            incr stable
            if {$stable >= 3} { break }
        } else {
            set stable 0
            set last $n
        }
    }

    set bodies {}
    foreach b [harvest --match "*/api/graphql/*"] {
        lassign $b u st body
        lappend bodies $body
    }
    if {![llength $bodies]} {
        emit [envelope_ok [dict create result [json::write string "$scope_label\nNo GraphQL response was harvested. The page served no post data."]]]
        return
    }

    set posts [extract_posts [join $bodies "\n"]]
    emit [envelope_ok [dict create result [json::write string [render_report $posts $terms $scope_label [group_slug $group]]]]]
}

# Direct-tclsh entry (file-fed): run the extraction over saved GraphQL bodies,
# so the parser can be exercised without touching the wire.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 1} {
        puts "Usage: auth-search-posts.tcl <bodies-file> \[keyword ...\]"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    set bodies [fb::read_file [lindex $argv 0]]
    puts [render_report [extract_posts $bodies] [lrange $argv 1 end] "Saved bodies" ""]
}
