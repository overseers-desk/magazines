#!/usr/bin/env tclsh
# Parse Qantas Flight Reward Finder HTML — extract Classic Reward flight availability.
#
# Usage:
#     tclsh parse-rewards.tcl /tmp/qantas-frf.html
#
# The Flight Reward Finder is a server-rendered Next.js page; the flight data
# lives in `__next_f.push([...])` chunks in the HTML. This extracts those chunks,
# reassembles the streamed payload, finds the per-flight availability records,
# and prints a per-cabin point/tax/seat summary.

package require json

namespace eval qf {}

# Reassemble the __next_f.push streamed payload: each chunk is `[<n>,"<str>"]`;
# concatenate the second (string) element of every well-formed chunk.
proc qf::extract_payload {html} {
    set payload ""
    foreach {whole c} [regexp -all -inline {__next_f\.push\(\[(.*?)\]\)</script>} $html] {
        if {[catch {json::json2dict "\[$c\]"} parts]} { continue }
        if {[llength $parts] >= 2 && [lindex $parts 1] ne ""} {
            # parts[1] must be a string; json2dict yields the decoded string.
            append payload [lindex $parts 1]
        }
    }
    return $payload
}

# Availability records are typically <2KB; cap at 16KB so a malformed payload
# cannot drive an unbounded scan.
variable qf::MAX_RECORD_BYTES [expr {16 * 1024}]

# Walk forward from $start (which must point at `{`), tracking string state.
# Returns the index just after the matching `}`, or -1 if not found within
# MAX_RECORD_BYTES. Bounded — cannot scan more than the cap.
proc qf::find_record_end {text start} {
    variable MAX_RECORD_BYTES
    set n [string length $text]
    set end_limit [expr {min($n, $start + $MAX_RECORD_BYTES)}]
    set depth 0
    set in_string 0
    set escape 0
    for {set i $start} {$i < $end_limit} {incr i} {
        set ch [string index $text $i]
        if {$in_string} {
            if {$escape} {
                set escape 0
            } elseif {$ch eq "\\"} {
                set escape 1
            } elseif {$ch eq "\""} {
                set in_string 0
            }
        } elseif {$ch eq "\""} {
            set in_string 1
        } elseif {$ch eq "\{"} {
            incr depth
        } elseif {$ch eq "\}"} {
            incr depth -1
            if {$depth == 0} { return [expr {$i + 1}] }
        }
    }
    return -1
}

# Find all availability records: objects starting with `{"id":<digits>,` that
# also contain a `"cabins":` key. Bounded per-record; safe on malformed payloads.
# Returns a list of parsed dicts.
proc qf::extract_availability_records {text} {
    set results {}
    foreach {whole} [regexp -all -inline -indices {\{"id":\d+,} $text] {
        set start [lindex $whole 0]
        set end [qf::find_record_end $text $start]
        if {$end == -1} { continue }
        set chunk [string range $text $start [expr {$end - 1}]]
        if {[string first {"cabins":} $chunk] < 0} { continue }
        if {[catch {json::json2dict $chunk} obj]} { continue }
        if {[qf::is_dict $obj] && [dict exists $obj cabins] && \
            [qf::is_dict [dict get $obj cabins]]} {
            lappend results $obj
        }
    }
    return $results
}

# A value parsed from JSON is a dict when it is an even-length list whose first
# element parses as a key. json2dict yields {} for a JSON null/empty; treat that
# as not-a-dict here (mirrors the Python isinstance(x, dict) guard).
proc qf::is_dict {v} {
    if {$v eq ""} { return 0 }
    if {[catch {dict size $v} sz]} { return 0 }
    return 1
}

# Fetch a key from a dict, returning $default when absent.
proc qf::dget {d key {default ""}} {
    if {[qf::is_dict $d] && [dict exists $d $key]} { return [dict get $d $key] }
    return $default
}

# Format an integer with thousands separators (mirrors Python's f"{n:,}").
proc qf::comma {n} {
    set neg ""
    if {[string index $n 0] eq "-"} { set neg "-"; set n [string range $n 1 end] }
    set out ""
    set len [string length $n]
    for {set i 0} {$i < $len} {incr i} {
        if {$i > 0 && (($len - $i) % 3) == 0} { append out "," }
        append out [string index $n $i]
    }
    return "$neg$out"
}

# Parse an ISO-8601 datetime (e.g. 2026-06-13T18:30:00 or ...+10:00). Returns a
# dict {ok 1 hhmm HH:MM date "Www DD Mmm YYYY"} or {ok 0}.
#
# The displayed time is the literal wall-clock value as written, with no zone
# conversion (mirrors Python datetime.fromisoformat(...).strftime("%H:%M"),
# which renders the original local time and never shifts to the host's zone).
# So the HH:MM and the calendar date come straight from the literal Y-M-D and
# H:M fields; the date-of-week is derived from that calendar date at UTC, which
# is zone-independent for a fixed Y-M-D.
proc qf::parse_iso {s} {
    if {$s eq ""} { return [dict create ok 0] }
    if {![regexp {^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})} $s \
            -> y mo d h mi]} {
        return [dict create ok 0]
    }
    # Weekday/month name from the literal calendar date, computed at UTC so the
    # zone offset never shifts the day.
    if {[catch {clock scan "$y-$mo-${d}T00:00:00" \
            -format %Y-%m-%dT%H:%M:%S -gmt 1} t]} {
        # Unparseable calendar date: fall back to the raw leading date.
        return [dict create ok 1 hhmm "$h:$mi" date [string range $s 0 9]]
    }
    set date [clock format $t -format "%a %d %b %Y" -gmt 1]
    return [dict create ok 1 hhmm "$h:$mi" date $date]
}

# Parse the HTML at $path into a list of flight dicts.
proc qf::parse {html_path} {
    set f [open $html_path r]
    fconfigure $f -encoding utf-8
    set html [read $f]
    close $f

    set payload [qf::extract_payload $html]
    if {$payload eq ""} { return {} }

    set records [qf::extract_availability_records $payload]

    set flights {}
    foreach rec $records {
        set cabins [qf::dget $rec cabins {}]
        if {![qf::is_dict $cabins]} { continue }
        set legs [qf::dget $rec legs {}]
        if {![llength $legs]} { continue }

        set departs_raw [qf::dget $rec departsAt ""]
        set arrives_raw [qf::dget $rec arrivesAt ""]
        set day_offset [qf::dget $rec arrivalDayOffset 0]
        set duration [qf::dget $rec duration ""]
        set stopovers [qf::dget $rec stopovers 0]
        set origin [qf::dget [qf::dget $rec origin {}] code "?"]
        set dest [qf::dget [qf::dget $rec destination {}] code "?"]

        # Collect leg flight numbers and aircraft.
        set leg_flights {}
        foreach l $legs { lappend leg_flights [qf::dget $l flightNumber ""] }
        set aircraft ""
        if {[llength $legs] == 1} {
            set aircraft [qf::dget [lindex $legs 0] equipment ""]
        }

        set dep [qf::parse_iso $departs_raw]
        set arr [qf::parse_iso $arrives_raw]
        if {[dict get $dep ok]} {
            set dep_str [dict get $dep hhmm]
            set date_str [dict get $dep date]
        } else {
            set dep_str $departs_raw
            set date_str [string range $departs_raw 0 9]
        }
        if {[dict get $arr ok]} {
            set arr_str [dict get $arr hhmm]
        } else {
            set arr_str $arrives_raw
        }

        set arr_label $arr_str
        if {$day_offset ne "" && $day_offset ne "0"} {
            append arr_label " (+$day_offset)"
        }

        set cabin_lines {}
        foreach name {Economy PremiumEconomy Business First} {
            set cab [qf::dget $cabins $name ""]
            if {![qf::is_dict $cab]} { continue }
            if {$name eq "PremiumEconomy"} {
                set label "Prem Economy"
            } else {
                set label $name
            }
            set pts [qf::dget $cab points "?"]
            set tax [qf::dget $cab tax "?"]
            set currency [qf::dget $cab currency ""]
            set seats [qf::dget $cab seats "?"]
            if {[string is integer -strict $pts]} {
                set pts_fmt [qf::comma $pts]
            } else {
                set pts_fmt $pts
            }
            lappend cabin_lines \
                "  $label: $pts_fmt pts + $currency$tax tax  ($seats seats)"
        }

        lappend flights [dict create \
            date $date_str \
            flight [join $leg_flights "/"] \
            route "$origin→$dest" \
            departs $dep_str \
            arrives $arr_label \
            duration $duration \
            aircraft $aircraft \
            stopovers $stopovers \
            cabin_lines $cabin_lines]
    }
    return $flights
}

proc qf::main {} {
    global argv
    if {[llength $argv] < 1} {
        puts stderr "Usage: parse-rewards.tcl <html-file>"
        exit 1
    }
    set flights [qf::parse [lindex $argv 0]]
    if {![llength $flights]} {
        puts "No Classic Reward flights found in this page."
        return
    }

    puts "Classic Flight Reward availability (flightrewardfinder.qantas.com):"
    puts ""
    foreach f $flights {
        if {[dict get $f stopovers] == 0} {
            set stops "nonstop"
        } else {
            set stops "[dict get $f stopovers] stop(s)"
        }
        set aircraft ""
        if {[dict get $f aircraft] ne ""} {
            set aircraft "  [dict get $f aircraft]"
        }
        puts "[dict get $f flight]  [dict get $f date]  [dict get $f route]  [dict get $f departs] → [dict get $f arrives]  [dict get $f duration]  $stops$aircraft"
        foreach line [dict get $f cabin_lines] {
            puts $line
        }
        puts ""
    }
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    qf::main
}
