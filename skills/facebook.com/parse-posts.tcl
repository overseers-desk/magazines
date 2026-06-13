#!/usr/bin/env tclsh
# Parse a Facebook profile page for recent posts with hashtags and tagged people.
#
# Serialiser path (see SKILL.md §5): browser-serialiser facebook.com/parse-posts <handle|profile-url> [--owner-id ID]
#   navigates to the profile, dumps the rendered DOM, and runs the identical parse.
# Direct path (legacy, file-fed): tclsh parse-posts.tcl <html-file> [--owner-id ID]
#
# Extracts per post: text content, hashtags, tagged/mentioned people and pages
# (with profile URLs), and the shared-from source.
#
# Facebook's DOM uses randomised class names; we rely on structural markers:
#   - data-ad-preview="message" marks the start of each post's text content
#   - __cft__[0] tokens link a post's elements (hashtags, tags, photos)
#   - /hashtag/TAGNAME links for hashtags
#   - profile/page links with __cft__ tokens for tagged people

source [file dirname [info script]]/fb-common.tcl

# Parse from in-memory HTML (the serialiser path) instead of a file, so the
# byte-identical extraction below has one home. The legacy file path reads the
# file then calls this; the serialiser path dumps the DOM then calls this.
proc parse_posts_html {html owner_id} {
    set title [fb::title $html "NOT FOUND"]
    if {[fb::title_is_login $title]} {
        puts "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        exit 1
    }

    set name [fb::name_from_title $title]

    puts "Profile: $name"
    puts "HTML size: [fb::commafy [fb::cp_length $html]] bytes"

    if {$owner_id eq ""} {
        set owner_id [detect_owner_id $html]
    }
    if {$owner_id ne ""} {
        puts "Owner ID: $owner_id"
    }

    set preview_positions {}
    foreach m [regexp -all -inline -indices -- {data-ad-preview="message"} $html] {
        lappend preview_positions [lindex $m 0]
    }
    if {![llength $preview_positions]} {
        puts ""
        puts "No posts found (no data-ad-preview markers)."
        puts "The profile may have no visible posts, or the DOM structure has changed."
        return
    }

    puts "Posts found: [llength $preview_positions]"
    puts ""

    set htmllen [string length $html]
    set npos [llength $preview_positions]
    set posts {}
    for {set i 0} {$i < $npos} {incr i} {
        set pos [lindex $preview_positions $i]
        if {$i == 0} {
            set region_start [expr {$pos - 25000}]
            if {$region_start < 0} { set region_start 0 }
        } else {
            set region_start [expr {([lindex $preview_positions [expr {$i-1}]] + $pos) / 2}]
        }
        if {$i == $npos - 1} {
            set region_end [expr {$pos + 15000}]
            if {$region_end > $htmllen} { set region_end $htmllen }
        } else {
            set region_end [expr {($pos + [lindex $preview_positions [expr {$i+1}]]) / 2}]
        }

        # Python slices html[region_start:region_end] (end-exclusive); Tcl
        # string range is inclusive, so subtract 1 from the end.
        set region [string range $html $region_start [expr {$region_end-1}]]
        set content_offset [expr {$pos - $region_start}]

        lappend posts [extract_post $region $content_offset $owner_id]
    }

    set i 0
    foreach post $posts {
        incr i
        puts "=== POST $i ==="
        set content [dict get $post content]
        if {$content ne ""} {
            puts "  Content: $content"
        } else {
            puts "  Content: (empty or not extracted)"
        }
        set hashtags [dict get $post hashtags]
        if {[llength $hashtags]} {
            set tags {}
            foreach h $hashtags { lappend tags "#$h" }
            puts "  Hashtags: [join $tags ", "]"
        }
        set tagged [dict get $post tagged]
        if {[llength $tagged]} {
            puts "  Tagged/mentioned:"
            foreach tag $tagged {
                set url [dict get $tag url]
                set label [expr {[dict exists $tag name] ? [dict get $tag name] : $url}]
                puts "    - $label  ($url)"
            }
        }
        set shared_from [dict get $post shared_from]
        if {$shared_from ne ""} {
            puts "  Shared from: $shared_from"
        }
        puts ""
    }

    # --- Summary (Counter.most_common: by count desc, insertion order on ties) ---
    set hashtag_counts [ordered_counter]
    set tagged_counts [ordered_counter]
    foreach post $posts {
        foreach h [dict get $post hashtags] { counter_incr hashtag_counts $h }
        foreach t [dict get $post tagged] {
            set key [expr {[dict exists $t name] ? [dict get $t name] : [dict get $t url]}]
            counter_incr tagged_counts $key
        }
    }

    if {[counter_size $hashtag_counts]} {
        puts "--- Hashtag summary ---"
        foreach {tag count} [counter_most_common $hashtag_counts] {
            puts "  #$tag: $count"
        }
        puts ""
    }
    if {[counter_size $tagged_counts]} {
        puts "--- Tagged/mentioned summary ---"
        foreach {nm count} [counter_most_common $tagged_counts] {
            puts "  $nm: $count"
        }
        puts ""
    }

    puts "--- End of posts parse ([llength $posts] posts) ---"
}

set ::POSTS_NON_PROFILE_PATHS {
    search groups pages marketplace watch events
    photo photo.php hashtag stories reels reel
    ads business share sharer dialog plugins
    l.php permalink.php story.php profile.php
}

proc detect_owner_id {html} {
    set ids [capture_list $html {facebook\.com/profile\.php\?id=(\d+)}]
    if {[llength $ids]} {
        set c [ordered_counter]
        foreach id $ids { counter_incr c $id }
        return [lindex [counter_most_common $c] 0]
    }
    set og_url [capture_list $html {<meta[^>]*property="og:url"[^>]*content="([^"]*)"}]
    if {[llength $og_url]} {
        set first [lindex $og_url 0]
        if {[regexp -- {id=(\d+)} $first -> m]} { return $m }
        if {[regexp -- {facebook\.com/([a-zA-Z0-9.]+)} $first -> m]} { return $m }
    }
    return ""
}

proc extract_post {region content_offset owner_id} {
    set post [dict create content "" hashtags {} tagged {} shared_from ""]

    # --- Post text content ---
    set content_region [string range $region $content_offset [expr {$content_offset + 5000 - 1}]]
    set texts [fb::extract_visible_texts $content_region 3 2000 3]

    set stop_words {Like Comment Share Send Haha Love Wow Sad Angry Care comments shares "All comments" "Most relevant" "Write a comment" "Like this post"}
    set content_parts {}
    foreach t $texts {
        if {$t in $stop_words || [string match "* comments" $t] || [string match "* shares" $t]} {
            break
        }
        if {[string length $t] < 3} { continue }
        lappend content_parts $t
    }
    dict set post content [join $content_parts " "]

    # --- Hashtags (dedup, preserve order) ---
    set hashtags {}
    set hseen {}
    foreach h [capture_list $region {href="https://www\.facebook\.com/hashtag/([a-zA-Z0-9_]+)}] {
        if {![dict exists $hseen $h]} {
            dict set hseen $h 1
            lappend hashtags $h
        }
    }
    dict set post hashtags $hashtags

    # --- Tagged/mentioned people and pages ---
    set tag_region [string range $region 0 [expr {$content_offset + 5000 - 1}]]
    set vanity_links [capture_list $tag_region {href="https://www\.facebook\.com/([a-zA-Z0-9._]+)\?(?!comment_id)[^"]*__cft__[^"]*"}]
    set numeric_links [capture_list $tag_region {href="https://www\.facebook\.com/profile\.php\?id=(\d+)[^"]*__cft__[^"]*"}]

    set tagged {}
    set seen_tagged {}
    set owner_lower [string tolower $owner_id]
    foreach username $vanity_links {
        set username_lower [string trimright [string tolower $username] "."]
        if {$username_lower in $::POSTS_NON_PROFILE_PATHS} { continue }
        if {$owner_id ne "" && $username_lower eq $owner_lower} { continue }
        if {[dict exists $seen_tagged $username_lower]} { continue }
        dict set seen_tagged $username_lower 1
        set url "https://www.facebook.com/$username"
        set link_name [extract_link_name $region "/$username?"]
        set tag_info [dict create url $url]
        if {$link_name ne ""} { dict set tag_info name $link_name }
        lappend tagged $tag_info
    }
    foreach nid $numeric_links {
        if {$nid eq $owner_id} { continue }
        if {[dict exists $seen_tagged $nid]} { continue }
        dict set seen_tagged $nid 1
        set url "https://www.facebook.com/profile.php?id=$nid"
        set link_name [extract_link_name $region "id=$nid"]
        set tag_info [dict create url $url]
        if {$link_name ne ""} { dict set tag_info name $link_name }
        lappend tagged $tag_info
    }
    dict set post tagged $tagged

    # --- Shared from ---
    set header_region [string range $region 0 [expr {$content_offset - 1}]]
    set header_texts [fb::extract_visible_texts $header_region 3 2000 3]
    set nht [llength $header_texts]
    for {set j 0} {$j < $nht} {incr j} {
        set t [lindex $header_texts $j]
        if {[string first "shared" [string tolower $t]] >= 0} {
            set kmax [expr {min($j + 4, $nht)}]
            for {set k [expr {$j+1}]} {$k < $kmax} {incr k} {
                set candidate [lindex $header_texts $k]
                if {[string length $candidate] < 3} { continue }
                if {[regexp -- {^[A-Za-z0-9]+\.(com|org|net|io)} $candidate]} { continue }
                if {$candidate in {&nbsp; "Shared with Public" Public}} { continue }
                dict set post shared_from $candidate
                break
            }
            break
        }
    }

    return $post
}

# Visible text associated with a link: the first acceptable >text< after the
# link path appears in the region.
proc extract_link_name {html_region link_path} {
    set idx [string first $link_path $html_region]
    if {$idx < 0} { return "" }
    set after [string range $html_region $idx [expr {$idx + 500 - 1}]]
    set noise_re {x[0-9a-z]{7,}|padding|margin:|display:|font-|overflow|opacity|cursor:|visibility|border|position:|background|transform|transition|animation|componentkey|tabindex|aria-}
    foreach t [capture_list $after {>([^<]+)<}] {
        # Python bound 2..100; apply as filter.
        set L [string length $t]
        if {$L < 2 || $L > 100} { continue }
        set t [string trim $t]
        if {$t eq "" || [string length $t] < 2} { continue }
        if {[regexp -- $noise_re $t]} { continue }
        if {[string index $t 0] eq "\{" || [string index $t 0] eq "."} { continue }
        return [string map {&amp; & &#39; ' &quot; \" &#x2F; /} $t]
    }
    return ""
}

proc capture_list {text pat} {
    set out {}
    foreach {whole cap} [regexp -all -inline -- $pat $text] {
        lappend out $cap
    }
    return $out
}

# --- Counter mirroring collections.Counter + most_common() ---
# Stored as a dict {key count}; insertion order is dict order. most_common
# sorts by count desc, stable on insertion order (Python's behaviour).
proc ordered_counter {} { return [dict create] }
proc counter_incr {var key} {
    upvar 1 $var c
    if {[dict exists $c $key]} {
        dict set c $key [expr {[dict get $c $key] + 1}]
    } else {
        dict set c $key 1
    }
}
proc counter_size {c} { return [dict size $c] }
proc counter_most_common {c} {
    # Decorate with insertion index for a stable sort by (-count, index).
    set items {}
    set idx 0
    dict for {k v} $c {
        lappend items [list $k $v $idx]
        incr idx
    }
    set sorted [lsort -command compare_counter $items]
    set out {}
    foreach it $sorted {
        lappend out [lindex $it 0] [lindex $it 1]
    }
    return $out
}
proc compare_counter {a b} {
    set ca [lindex $a 1]; set cb [lindex $b 1]
    if {$ca != $cb} { return [expr {$cb - $ca}] }
    return [expr {[lindex $a 2] - [lindex $b 2]}]
}

# Legacy file-fed entry: read the file, then run the shared parser.
proc parse_posts {html_path owner_id} {
    parse_posts_html [fb::read_file $html_path] $owner_id
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the profile (the covering view), dump the rendered
# DOM, and run the identical parse over the in-memory HTML under fb::capture so
# the byte-identical printers populate the single emitted string. A login wall
# is caught by `state` after nav (the parser's own no-session exit is the
# fallback, captured before it fires).
#
# Invoked by reference through the serialiser (see SKILL.md §5):
#     browser-serialiser facebook.com/parse-posts <handle|profile-url> [--owner-id ID]
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set owner_id ""
    set target ""
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        if {$a eq "--owner-id"} {
            incr i
            set owner_id [lindex $skillArgs $i]
        } elseif {$target eq ""} {
            set target $a
        }
    }
    if {$target eq ""} {
        emit "Usage: facebook.com/parse-posts <handle|profile-url> \[--owner-id ID\]"
        return
    }
    nav [fb_profile_url $target] --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        return
    }
    set html [dump]
    emit [fb::capture out { parse_posts_html $html $owner_id }]
}

# Resolve a profile reference (a bare handle, a numeric id, or a full URL) to a
# facebook.com profile URL to navigate to.
proc fb_profile_url {ref} {
    if {[string match "http*://*" $ref]} { return $ref }
    if {[regexp {^\d+$} $ref]} {
        return "https://www.facebook.com/profile.php?id=$ref"
    }
    return "https://www.facebook.com/[string trimleft $ref @/]"
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    # Argument handling: a path plus optional --owner-id ID.
    set html_path ""
    set owner_id ""
    set rest {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        if {$a eq "--owner-id"} {
            incr i
            set owner_id [lindex $argv $i]
        } else {
            lappend rest $a
        }
    }
    if {[llength $rest] < 1} {
        puts "Usage: parse-posts.tcl <profile.html> \[--owner-id ID\]"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_posts [lindex $rest 0] $owner_id
}
