#!/usr/bin/env tclsh
# Parse a Facebook activity-log page (allactivity) for group-post entries, to
# audit cross-posting: the same content sent to many groups, or the same group
# posted to more than once.
#
# Serialiser path (see SKILL.md): browser-serialiser facebook.com/parse-activity <profile-id|activity-url> [--max-rounds N]
#   navigates to the activity log, scrolls to lazy-load entries, dumps the DOM, parses.
# Direct path (legacy, file-fed): tclsh parse-activity.tcl <html-file>
#
# Each group-post row ends in a permalink /groups/GID/(permalink|posts)/PID that
# is the row's "View" link; GID+PID uniquely identify the post, so two rows are
# the same post only if they share a permalink, and "same group twice" is a GID
# that recurs across two different PIDs. Each row's time (a HH:MM ~451 chars
# before its permalink) and privacy sit next to it in the DOM; the full date is a
# per-section header the row inherits. The group name is read separately from the
# activity-title JSON (a "posted in NAME." caption beside the group node), bound
# id-to-name within one object rather than by DOM proximity — the plain-post rows
# carry it; a link-share row has no name beside its id and is shown by group id.

source [file dirname [info script]]/fb-common.tcl

set ::ACTIVITY_MONTHS {January February March April May June July August September October November December}

# Parse from in-memory HTML (serialiser path) or a file (legacy path); one home
# for the extraction, printed line-by-line so fb::capture collects it into the
# single emitted string.
proc parse_activity_html {html} {
    set title [fb::title $html "NOT FOUND"]
    if {[fb::title_is_login $title]} {
        puts "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        exit 1
    }
    if {[regexp {"(?:USER_ID|ACCOUNT_ID)":"0"} $html]} {
        puts "ERROR: Facebook: not logged in (USER_ID:0 / login wall). Log in, then retry."
        exit 1
    }

    puts "HTML size: [fb::commafy [fb::cp_length $html]] bytes"

    set headers [find_date_headers $html]
    set names [group_name_map $html]
    set entries [find_group_entries $html $headers]

    if {![llength $entries]} {
        puts ""
        puts "No group-post entries found. The page may be a non-group activity"
        puts "category, empty, or a DOM structure this parser does not match."
        return
    }

    # Count distinct groups for the headline.
    set by_gid [ordered_counter]
    foreach e $entries { counter_incr by_gid [dict get $e gid] }
    set n_groups [counter_size $by_gid]
    puts "Group-post entries: [llength $entries]  (across $n_groups distinct groups)"
    puts ""

    # --- Per-entry listing, grouped under its date header (newest first). ---
    set cur ""
    foreach e $entries {
        set date [dict get $e date]
        if {$date ne $cur} {
            if {$cur ne ""} { puts "" }
            puts "[expr {$date eq "" ? "(no date header)" : $date}]"
            set cur $date
        }
        puts "  [dict get $e time]  ·  [entry_label $e $names]  ·  [dict get $e privacy]"
        puts "        https://www.facebook.com/groups/[dict get $e gid]/permalink/[dict get $e pid]/"
    }
    puts ""

    # --- Same-group audit: a GID that recurs (across two different PIDs) is the
    #     "posted twice to one group" case the log cannot show at a glance. This
    #     is the question the report exists to answer. ---
    puts "--- Same-group check ---"
    set repeated {}
    dict for {gid n} $by_gid {
        if {$n > 1} { lappend repeated $gid $n }
    }
    if {[llength $repeated]} {
        foreach {gid n} $repeated {
            puts "  [group_name $gid $names] received $n posts:"
            foreach e $entries {
                if {[dict get $e gid] eq $gid} {
                    puts "    - [string trim "[dict get $e date] [dict get $e time]"]  https://www.facebook.com/groups/$gid/permalink/[dict get $e pid]/"
                }
            }
        }
    } else {
        puts "  No group received more than one post: [llength $entries] posts to $n_groups distinct groups."
    }
    puts ""
    puts "--- End of activity parse ([llength $entries] entries) ---"
}

# gid -> group name, read from the activity-title JSON where the group node and
# its "posted in NAME." caption sit in one object (present for plain posts).
# Share-posts do not carry the name near their id, so the map is partial; a gid
# not in it is reported by number, and its permalink URL identifies the group.
proc group_name_map {html} {
    set map [dict create]
    set re {groups\\/(\d+)\\/","__isNode":"Group".{0,250}?"text":"[^"]*posted in ([^"]+?)\."}
    foreach {whole gid name} [regexp -all -inline -- $re $html] {
        set name [string map {\\/ /} $name]
        if {![dict exists $map $gid]} { dict set map $gid [fb::unescape $name] }
    }
    return $map
}

proc group_name {gid names} {
    if {[dict exists $names $gid]} { return [dict get $names $gid] }
    return "group $gid"
}

proc entry_label {e names} {
    return [group_name [dict get $e gid] $names]
}

# Date-section headers, as {pos label} in document order: absolute dates
# (>DD Month YYYY<) and the relative "Today"/"Yesterday" the log uses for recent
# days. A row's date is the label of the last header before it.
proc find_date_headers {html} {
    set months [join $::ACTIVITY_MONTHS |]
    set headers {}
    set pos 0
    set re ">(\\d{1,2} (?:$months) \\d{4}|Today|Yesterday)<"
    while {[regexp -indices -start $pos -- $re $html whole cap]} {
        lappend headers [list [lindex $whole 0] \
            [string range $html [lindex $cap 0] [lindex $cap 1]]]
        set pos [expr {[lindex $whole 1] + 1}]
    }
    return $headers
}

# Every group-post row: the permalink is the discriminator; its time and privacy
# sit in the ~3000 chars before it. Returns a list of dicts.
proc find_group_entries {html headers} {
    set entries {}
    set seen {}
    set pos 0
    while {[regexp -indices -start $pos -- {/groups/(\d+)/(?:permalink|posts)/(\d+)} $html whole g1 g2]} {
        set start [lindex $whole 0]
        set gid [string range $html [lindex $g1 0] [lindex $g1 1]]
        set pid [string range $html [lindex $g2 0] [lindex $g2 1]]
        set pos [expr {[lindex $whole 1] + 1}]

        # Dedup by (gid,pid): the same post's permalink can render more than once,
        # and double-counting would fabricate a same-group repeat.
        if {[dict exists $seen $gid,$pid]} { continue }
        dict set seen $gid,$pid 1

        set rstart [expr {$start - 3000}]
        if {$rstart < 0} { set rstart 0 }
        set region [string range $html $rstart [expr {$start - 1}]]

        lappend entries [dict create \
            gid $gid pid $pid \
            date [date_for_pos $headers $start] \
            time [row_time $region] \
            privacy [row_privacy $region]]
    }
    return $entries
}

# The label of the last header positioned before $p; "" if none precedes.
proc date_for_pos {headers p} {
    set label ""
    foreach h $headers {
        if {[lindex $h 0] < $p} {
            set label [lindex $h 1]
        } else {
            break
        }
    }
    return $label
}

# The HH:MM nearest the permalink is the last one in the region (the row's time
# sits just before its "View" link).
proc row_time {region} {
    set last ""
    foreach {whole cap} [regexp -all -inline -- {>(\d{1,2}:\d{2})<} $region] {
        set last $cap
    }
    return $last
}

proc row_privacy {region} {
    if {[regexp -- {>(Public group|Private group)<} $region -> p]} { return $p }
    return ""
}

# --- Counter (shared shape with parse-posts; kept local so this file stands
#     alone for the legacy tclsh path). ---
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

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the activity log, scroll to lazy-load entries, dump
# the rendered DOM, parse. A login wall is caught by `state` after nav.
#
#     browser-serialiser facebook.com/parse-activity <profile-id|activity-url> [--max-rounds N]
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set max_rounds 25
    set target ""
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        if {$a eq "--max-rounds"} {
            incr i; set max_rounds [lindex $skillArgs $i]
        } elseif {$target eq ""} {
            set target $a
        }
    }
    if {$target eq ""} {
        emit "Usage: facebook.com/parse-activity <profile-id|activity-url> \[--max-rounds N\]"
        return
    }

    nav [activity_url $target] --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: Facebook: [dict get [state] terminal]. Log in via a Chrome-compatible browser first."
        return
    }

    # Scroll until the group-permalink count stops growing (or the round cap).
    set last -1
    set stable 0
    for {set r 0} {$r < $max_rounds} {incr r} {
        act_scroll
        dwell 1.2
        set n [act_count]
        ::log "parse-activity: round=$r group_entries=$n stable=$stable"
        if {$n == $last} {
            incr stable
            if {$stable >= 4} { break }
        } else {
            set stable 0
            set last $n
        }
    }

    set html [dump]
    emit [fb::capture out { parse_activity_html $html }]
}

# Resolve a target to an activity-log URL: a full URL passes through; a bare
# numeric profile id builds the group-posts activity URL.
proc activity_url {ref} {
    if {[string match "http*://*" $ref]} { return $ref }
    if {[regexp {^\d+$} $ref]} {
        return "https://www.facebook.com/$ref/allactivity/?activity_history=false&category_key=GROUPPOSTS&manage_mode=false&should_load_landing_page=false"
    }
    return "https://www.facebook.com/$ref"
}

# Count group-post permalinks currently in the DOM (growth signal for the loop).
proc act_count {} {
    set expr {(function(){return [...document.querySelectorAll('a[href*="/groups/"]')].filter(function(a){return /\/groups\/\d+\/(permalink|posts)\/\d+/.test(a.href)}).length})()}
    if {[catch {eval $expr} v]} { return 0 }
    if {![string is integer -strict $v]} { return 0 }
    return $v
}

# Scroll the window and the tallest scrollable container to the bottom so the
# log's lazy-load fires.
proc act_scroll {} {
    set expr {(function(){window.scrollTo(0,document.body.scrollHeight);var best=null,bh=0;document.querySelectorAll('div').forEach(function(d){var s=getComputedStyle(d);if((s.overflowY=='auto'||s.overflowY=='scroll')&&d.scrollHeight>d.clientHeight+400&&d.scrollHeight>bh){bh=d.scrollHeight;best=d}});if(best){best.scrollTop=best.scrollHeight}return 1})()}
    catch {eval $expr}
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 1} {
        puts "Usage: parse-activity.tcl <activity.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_activity_html [fb::read_file [lindex $argv 0]]
}
