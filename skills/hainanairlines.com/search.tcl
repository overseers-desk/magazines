#!/usr/bin/env tclsh
# Hainan Airlines (HU) one-way fare search on www.hainanairlines.com.
#
# Access pattern (verified live, see the sibling SKILL.md for the caller view):
# the Home page's REVENUE search form is filled by writing its hidden inputs
# (B_LOCATION_1 / E_LOCATION_1 / B_DATE_1, TRIP_TYPE=O, NB_ADT / NB_CHD) and
# then calling the native HTMLFormElement submit. The site's own click-handler
# chain (flightSearchForm.js) validates, may show popups, and ends in a plain
# formRef.submit() with no field mutation, so a native submit with the fields
# pre-set posts byte-identically to a human search — including the dynamic
# per-render csrf hidden input. A composed GET deep link to the same endpoint
# fails with "4000 System Error" (it lacks the csrf/session package), and
# typing into the visible location widget fails because its container computes
# display:none with a zero bounding rect. So: field injection + native submit,
# nothing else.
#
# The result is taken from `dump`, not `harvest`: the availability document's
# body is evicted from the CDP network buffer across the doEnc redirect chain
# (harvest returns length 0), while the rendered DOM carries the complete fare
# list, the site's own data model and the price calendar.
#
# Two result shapes, both carrying a single-line `var clientSideData = {...}`
# JSON in the dump:
#  - International markets: "Flex Pricer Upsell Page". Segments live in
#    clientSideData.mapDataOut.LIST_PANEL[0].LIST_TAB[0].LIST_PROPOSED_BOUND[0]
#    .LIST_FLIGHT (keyed by FLIGHT_ID); per-fare-family prices in
#    clientSideData.mapDataUI.LIST_BOUND[0].LIST_FLIGHT[].RECOMMENDATION_BY_FF;
#    fare family -> cabin in mapDataOut.FARE_FAMILY_DICTIONARY; display names
#    in mapDataUI.FF_BENEFITS; the +/-3-day price calendar in
#    mapDataUI.LIST_BOUND[0].CALENDAR.
#  - Domestic markets: "Schedule driven Availability". Flights with per-cabin
#    seat status live in clientSideData.AVAI.LIST_BOUND[0].LIST_FLIGHT; the
#    page defers prices to flight selection, so none are in the dump.
# The fare currency sits at clientSideData.MapDataIn.FARE_CURRENCY, and that
# capital M is the site's own spelling beside its lowercase siblings, so a
# lookup written to match them silently finds nothing.
#
# Timestamps in the model are local times encoded as epoch ms in GMT, so they
# are formatted with -gmt 1 and never converted. Total duration of a
# connection is the sum of the segment flying times plus the layover gaps
# (each gap is a local difference at one airport, hence real time); the plain
# first-to-last difference would be wrong across time zones.

package require json
package require json::write

namespace eval hu {}

set hu::HOME "https://www.hainanairlines.com/AU/GB/Home"

# Cabin display order; any unlisted commercial fare family renders after
# these, in payload order. Only ECONOMY and BUSINESS have been seen on the
# routes captured so far; the two premium-economy spellings are carried
# because either could appear and both label the same cabin.
set hu::CABIN_ORDER {ECONOMY PREMIUM_ECONOMY PREMIUMECONOMY BUSINESS FIRST}

proc hu::usage {} {
    return "Usage: hainanairlines.com/search <origin> <dest> <date YYYY-MM-DD> \[--adults N] \[--children N] \[--json]"
}

proc hu::dget {d key {default ""}} {
    if {$d ne "" && ![catch {dict get $d $key} v]} { return $v }
    return $default
}

# Get along a key path, empty-safe at every step; an integer step indexes a
# list (json2dict renders arrays as Tcl lists), any other step a dict key.
proc hu::dgetp {d path {default ""}} {
    foreach key $path {
        if {[string is integer -strict $key]} {
            set d [lindex $d $key]
        } else {
            set d [hu::dget $d $key ""]
        }
        if {$d eq ""} { return $default }
    }
    return $d
}

proc hu::amt {v} {
    if {[string is double -strict $v]} { return [format %.2f $v] }
    return $v
}

proc hu::cabin_label {code} {
    switch -- $code {
        ECONOMY { return "Economy" }
        PREMIUM_ECONOMY - PREMIUMECONOMY { return "PremiumEconomy" }
        BUSINESS { return "Business" }
        FIRST { return "First" }
    }
    return $code
}

# Domestic cabin letters as the availability page uses them.
proc hu::cabin_letter_label {c} {
    switch -- $c {
        E { return "Economy" }
        B { return "Business" }
        F { return "First" }
    }
    return $c
}

proc hu::ms_time {ms} {
    return [clock format [expr {$ms / 1000}] -format %H:%M -gmt 1]
}

proc hu::ms_date {ms} {
    return [clock format [expr {$ms / 1000}] -format %Y-%m-%d -gmt 1]
}

# Whole days from $base to $date (both YYYY-MM-DD); 0 on unparseable input.
proc hu::days_from {base date} {
    if {[catch {clock scan $base -format %Y-%m-%d -gmt 1} b]} { return 0 }
    if {[catch {clock scan $date -format %Y-%m-%d -gmt 1} d]} { return 0 }
    return [expr {($d - $b) / 86400}]
}

# "02:25" or "08:55 (+1)" when the timestamp's date is past the queried date.
proc hu::timestr {ms qdate} {
    set t [hu::ms_time $ms]
    set off [hu::days_from $qdate [hu::ms_date $ms]]
    if {$off > 0} { return "$t (+$off)" }
    return $t
}

proc hu::duration {ms} {
    if {![string is integer -strict $ms] || $ms <= 0} { return "" }
    set mins [expr {$ms / 60000}]
    return "[expr {$mins / 60}]h[format %02d [expr {$mins % 60}]]m"
}

# Sum of segment flying times plus layover gaps, in ms.
proc hu::itin_duration_ms {segs} {
    set total 0
    set lastE ""
    foreach seg $segs {
        if {$lastE ne ""} {
            incr total [expr {[hu::dget $seg B_DATE 0] - $lastE}]
        }
        set ft [hu::dget $seg SEGMENT_FLIGHT_TIME 0]
        if {![string is integer -strict $ft]} { set ft 0 }
        incr total $ft
        set lastE [hu::dget $seg E_DATE 0]
    }
    return $total
}

proc hu::stopstr {stops} {
    switch -- $stops {
        0 { return "nonstop" }
        1 { return "1 stop" }
    }
    return "$stops stops"
}

# "HU727 CKG 02:25 → MAD 08:55"
proc hu::seg_line {seg qdate} {
    set flight "[hu::dgetp $seg {AIRLINE CODE}][hu::dget $seg FLIGHT_NUMBER]"
    set dep [hu::timestr [hu::dget $seg B_DATE 0] $qdate]
    set arr [hu::timestr [hu::dget $seg E_DATE 0] $qdate]
    return "$flight [hu::dgetp $seg {B_LOCATION LOCATION_CODE}] $dep → [hu::dgetp $seg {E_LOCATION LOCATION_CODE}] $arr"
}

# The single-line `var clientSideData = {...}` object out of the dumped DOM,
# by string-aware brace matching; "" when absent.
proc hu::extract_csd {html} {
    set marker {var clientSideData = }
    set i [string first $marker $html]
    if {$i < 0} { return "" }
    set start [expr {$i + [string length $marker]}]
    set depth 0
    set instr 0
    set esc 0
    set n [string length $html]
    for {set k $start} {$k < $n} {incr k} {
        set ch [string index $html $k]
        if {$instr} {
            if {$esc} { set esc 0 } elseif {$ch eq "\\"} { set esc 1 } elseif {$ch eq "\""} { set instr 0 }
        } else {
            if {$ch eq "\""} {
                set instr 1
            } elseif {$ch eq "\{"} {
                incr depth
            } elseif {$ch eq "\}"} {
                incr depth -1
                if {$depth == 0} { return [string range $html $start $k] }
            }
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# International (FlexPricer) shape

# fareFamily -> commercial fare family (ECONOMY/BUSINESS/...), from
# mapDataOut.FARE_FAMILY_DICTIONARY.
proc hu::ff_cabins {csd} {
    set map {}
    foreach e [hu::dgetp $csd {mapDataOut FARE_FAMILY_DICTIONARY LIST_FARE_FAMILY}] {
        set ff [hu::dget $e FARE_FAMILY]
        if {$ff ne ""} { dict set map $ff [hu::dget $e COMMERCIAL_FARE_FAMILY] }
    }
    return $map
}

# fareFamily -> display name ("Economy Basic"), from mapDataUI.FF_BENEFITS.
# The site pads one name with an ideographic space; trim it.
proc hu::ff_names {csd} {
    set map {}
    set ben [hu::dgetp $csd {mapDataUI FF_BENEFITS}]
    if {$ben eq ""} { return $map }
    foreach {ff v} $ben {
        set name [hu::dget $v BRAND_NAME]
        if {$name ne ""} {
            dict set map $ff [string trim $name " \t\r\n　"]
        }
    }
    return $map
}

# FLIGHT_ID -> segment list, from the proposed-bound side of the model.
proc hu::intl_segments {csd} {
    set map {}
    foreach f [hu::dgetp $csd {mapDataOut LIST_PANEL 0 LIST_TAB 0 LIST_PROPOSED_BOUND 0 LIST_FLIGHT}] {
        dict set map [hu::dget $f FLIGHT_ID] [hu::dget $f LIST_SEGMENT]
    }
    return $map
}

# Priced flights in page order: list of dicts {id segs ffPrices}.
proc hu::intl_flights {csd} {
    set keyed {}
    foreach f [hu::dgetp $csd {mapDataUI LIST_BOUND 0 LIST_FLIGHT}] {
        lappend keyed [list [hu::dget $f FLIGHT_INDEX 0] $f]
    }
    set segmap [hu::intl_segments $csd]
    set out {}
    foreach kf [lsort -integer -index 0 $keyed] {
        set f [lindex $kf 1]
        set id [hu::dget $f FLIGHT_ID]
        lappend out [dict create \
            id $id \
            segs [hu::dget $segmap $id] \
            ffPrices [hu::dget $f RECOMMENDATION_BY_FF]]
    }
    return $out
}

# Cabin keys present across the fare families of one flight, CABIN_ORDER
# first, leftovers in payload order.
proc hu::flight_cabins {ffPrices ffCabin} {
    variable CABIN_ORDER
    set present {}
    foreach {ff v} $ffPrices {
        set c [hu::dget $ffCabin $ff $ff]
        if {$c ni $present} { lappend present $c }
    }
    set keys {}
    foreach c $CABIN_ORDER {
        if {$c in $present} { lappend keys $c }
    }
    foreach c $present {
        if {$c ni $keys} { lappend keys $c }
    }
    return $keys
}

# Fare families of one cabin, cheapest first: list of {ff price seats}.
proc hu::cabin_fares {ffPrices ffCabin cabin} {
    set keyed {}
    foreach {ff v} $ffPrices {
        if {[hu::dget $ffCabin $ff $ff] ne $cabin} { continue }
        set p [hu::dget $v PRICE_TO_DISPLAY]
        if {![string is double -strict $p]} { continue }
        lappend keyed [list $p $ff [hu::dget $v NUMBER_OF_LAST_SEATS 9]]
    }
    set out {}
    foreach k [lsort -real -index 0 $keyed] {
        lassign $k p ff seats
        lappend out [list $ff $p $seats]
    }
    return $out
}

proc hu::calendar_entries {csd} {
    set out {}
    foreach e [hu::dgetp $csd {mapDataUI LIST_BOUND 0 CALENDAR LIST_DATE}] {
        set ms [hu::dget $e DATE]
        set p [hu::dget $e PRICE_TO_DISPLAY]
        if {[string is wideinteger -strict $ms] && [string is double -strict $p]} {
            lappend out [list [hu::ms_date $ms] $p]
        }
    }
    return $out
}

proc hu::render_intl_text {csd origin dest date adults children currency} {
    set flights [hu::intl_flights $csd]
    set head "Hainan Airlines $origin → $dest $date, one-way, adults $adults children $children (per-adult \"from\" fares as displayed)"
    if {![llength $flights]} {
        return "$head\n\nNo itineraries for $origin → $dest on $date."
    }
    set ffCabin [hu::ff_cabins $csd]
    set ffName [hu::ff_names $csd]
    set out $head
    set n 0
    foreach f $flights {
        incr n
        set segs [dict get $f segs]
        set first [lindex $segs 0]
        set last [lindex $segs end]
        set dep [hu::timestr [hu::dget $first B_DATE 0] $date]
        set arr [hu::timestr [hu::dget $last E_DATE 0] $date]
        set dur [hu::duration [hu::itin_duration_ms $segs]]
        set stops [expr {[llength $segs] - 1}]
        append out "\n\n$n) [hu::dgetp $first {B_LOCATION LOCATION_CODE}] $dep → [hu::dgetp $last {E_LOCATION LOCATION_CODE}] $arr   $dur, [hu::stopstr $stops]"
        foreach seg $segs {
            append out "\n   [hu::seg_line $seg $date]"
        }
        set ffPrices [dict get $f ffPrices]
        foreach cabin [hu::flight_cabins $ffPrices $ffCabin] {
            set fares [hu::cabin_fares $ffPrices $ffCabin $cabin]
            if {![llength $fares]} { continue }
            set lowest [lindex $fares 0 1]
            set line [format "   %-14s %s %s" [hu::cabin_label $cabin] $currency [hu::amt $lowest]]
            set parts {}
            foreach fps $fares {
                lassign $fps ff p seats
                set label [hu::dget $ffName $ff $ff]
                set part "$label [hu::amt $p]"
                if {[string is integer -strict $seats] && $seats < 9} {
                    append part " (last $seats)"
                }
                lappend parts $part
            }
            append line "   \[[join $parts {, }]\]"
            append out "\n$line"
        }
    }
    set cal {}
    foreach e [hu::calendar_entries $csd] {
        lassign $e d p
        lappend cal "$d [hu::amt $p]"
    }
    if {[llength $cal]} {
        append out "\n\nNearby dates, lowest per-adult fare ($currency): [join $cal {, }]"
    }
    return $out
}

proc hu::json_segments {segs} {
    set segjson {}
    foreach seg $segs {
        lappend segjson [json::write object \
            flight [json::write string "[hu::dgetp $seg {AIRLINE CODE}][hu::dget $seg FLIGHT_NUMBER]"] \
            airline [json::write string [hu::dgetp $seg {AIRLINE NAME}]] \
            origin [json::write string [hu::dgetp $seg {B_LOCATION LOCATION_CODE}]] \
            destination [json::write string [hu::dgetp $seg {E_LOCATION LOCATION_CODE}]] \
            departure [json::write string "[hu::ms_date [hu::dget $seg B_DATE 0]] [hu::ms_time [hu::dget $seg B_DATE 0]]"] \
            arrival [json::write string "[hu::ms_date [hu::dget $seg E_DATE 0]] [hu::ms_time [hu::dget $seg E_DATE 0]]"] \
            aircraft [json::write string [hu::dgetp $seg {EQUIPMENT NAME}]]]
    }
    return $segjson
}

proc hu::render_intl_json {csd origin dest date adults children currency} {
    set ffCabin [hu::ff_cabins $csd]
    set ffName [hu::ff_names $csd]
    set itins {}
    foreach f [hu::intl_flights $csd] {
        set segs [dict get $f segs]
        set first [lindex $segs 0]
        set last [lindex $segs end]
        set ffPrices [dict get $f ffPrices]
        set cabjson {}
        foreach cabin [hu::flight_cabins $ffPrices $ffCabin] {
            set fares [hu::cabin_fares $ffPrices $ffCabin $cabin]
            if {![llength $fares]} { continue }
            set brands {}
            foreach fps $fares {
                lassign $fps ff p seats
                lappend brands [json::write object \
                    code [json::write string $ff] \
                    label [json::write string [hu::dget $ffName $ff $ff]] \
                    price $p \
                    currency [json::write string $currency] \
                    lastSeats $seats]
            }
            lappend cabjson [hu::cabin_label $cabin] [json::write object \
                from [lindex $fares 0 1] \
                currency [json::write string $currency] \
                fareFamilies [json::write array {*}$brands]]
        }
        lappend itins [json::write object \
            origin [json::write string [hu::dgetp $first {B_LOCATION LOCATION_CODE}]] \
            destination [json::write string [hu::dgetp $last {E_LOCATION LOCATION_CODE}]] \
            departure [json::write string "[hu::ms_date [hu::dget $first B_DATE 0]] [hu::ms_time [hu::dget $first B_DATE 0]]"] \
            arrival [json::write string "[hu::ms_date [hu::dget $last E_DATE 0]] [hu::ms_time [hu::dget $last E_DATE 0]]"] \
            durationMinutes [expr {[hu::itin_duration_ms $segs] / 60000}] \
            stops [expr {[llength $segs] - 1}] \
            segments [json::write array {*}[hu::json_segments $segs]] \
            cabins [json::write object {*}$cabjson]]
    }
    set caljson {}
    foreach e [hu::calendar_entries $csd] {
        lassign $e d p
        lappend caljson [json::write object \
            date [json::write string $d] \
            lowestFare $p \
            currency [json::write string $currency]]
    }
    return [json::write object \
        type [json::write string "farePriced"] \
        origin [json::write string $origin] \
        destination [json::write string $dest] \
        date [json::write string $date] \
        passengers [json::write object adults $adults children $children] \
        currency [json::write string $currency] \
        itineraries [json::write array {*}$itins] \
        calendar [json::write array {*}$caljson]]
}

# ---------------------------------------------------------------------------
# Domestic (schedule-driven) shape

proc hu::dom_flights {csd} {
    return [hu::dgetp $csd {AVAI LIST_BOUND 0 LIST_FLIGHT}]
}

# Per-segment cabin availability: list of {label status}. Status "9" is the
# site's cap, nine or more seats.
proc hu::seg_cabins {seg} {
    set out {}
    foreach c [hu::dget $seg LIST_CABIN] {
        lappend out [list [hu::cabin_letter_label [hu::dget $c CABIN]] [hu::dget $c STATUS]]
    }
    return $out
}

proc hu::render_dom_text {csd origin dest date adults children} {
    set flights [hu::dom_flights $csd]
    set head "Hainan Airlines $origin → $dest $date, one-way, adults $adults children $children"
    if {![llength $flights]} {
        return "$head\n\nNo flights for $origin → $dest on $date."
    }
    set out "$head\nSchedule-driven availability: this page lists flights and per-cabin seat counts; the site defers prices to flight selection, so no prices are in this result (seat count 9 means nine or more)."
    set n 0
    foreach f $flights {
        incr n
        set segs [hu::dget $f LIST_SEGMENT]
        set first [lindex $segs 0]
        set last [lindex $segs end]
        set dep [hu::timestr [hu::dget $first B_DATE 0] $date]
        set arr [hu::timestr [hu::dget $last E_DATE 0] $date]
        # Domestic flights share one time zone, so first-to-last is real time.
        set dur [hu::duration [expr {[hu::dget $last E_DATE 0] - [hu::dget $first B_DATE 0]}]]
        set stops [expr {[llength $segs] - 1}]
        append out "\n\n$n) [hu::dgetp $first {B_LOCATION LOCATION_CODE}] $dep → [hu::dgetp $last {E_LOCATION LOCATION_CODE}] $arr   $dur, [hu::stopstr $stops]"
        foreach seg $segs {
            set cabs {}
            foreach cs [hu::seg_cabins $seg] {
                lassign $cs label status
                lappend cabs "$label $status"
            }
            set line "   [hu::seg_line $seg $date]   [hu::dgetp $seg {EQUIPMENT NAME}]"
            if {[llength $cabs]} { append line "   seats: [join $cabs {, }]" }
            append out "\n$line"
        }
    }
    return $out
}

proc hu::render_dom_json {csd origin dest date adults children} {
    set itins {}
    foreach f [hu::dom_flights $csd] {
        set segs [hu::dget $f LIST_SEGMENT]
        set first [lindex $segs 0]
        set last [lindex $segs end]
        set segjson {}
        foreach seg $segs {
            set cabjson {}
            foreach cs [hu::seg_cabins $seg] {
                lassign $cs label status
                lappend cabjson [json::write object \
                    cabin [json::write string $label] \
                    seats [json::write string $status]]
            }
            lappend segjson [json::write object \
                flight [json::write string "[hu::dgetp $seg {AIRLINE CODE}][hu::dget $seg FLIGHT_NUMBER]"] \
                airline [json::write string [hu::dgetp $seg {AIRLINE NAME}]] \
                origin [json::write string [hu::dgetp $seg {B_LOCATION LOCATION_CODE}]] \
                destination [json::write string [hu::dgetp $seg {E_LOCATION LOCATION_CODE}]] \
                departure [json::write string "[hu::ms_date [hu::dget $seg B_DATE 0]] [hu::ms_time [hu::dget $seg B_DATE 0]]"] \
                arrival [json::write string "[hu::ms_date [hu::dget $seg E_DATE 0]] [hu::ms_time [hu::dget $seg E_DATE 0]]"] \
                aircraft [json::write string [hu::dgetp $seg {EQUIPMENT NAME}]] \
                cabinAvailability [json::write array {*}$cabjson]]
        }
        lappend itins [json::write object \
            origin [json::write string [hu::dgetp $first {B_LOCATION LOCATION_CODE}]] \
            destination [json::write string [hu::dgetp $last {E_LOCATION LOCATION_CODE}]] \
            departure [json::write string "[hu::ms_date [hu::dget $first B_DATE 0]] [hu::ms_time [hu::dget $first B_DATE 0]]"] \
            arrival [json::write string "[hu::ms_date [hu::dget $last E_DATE 0]] [hu::ms_time [hu::dget $last E_DATE 0]]"] \
            durationMinutes [expr {([hu::dget $last E_DATE 0] - [hu::dget $first B_DATE 0]) / 60000}] \
            stops [expr {[llength $segs] - 1}] \
            segments [json::write array {*}$segjson]]
    }
    return [json::write object \
        type [json::write string "scheduleOnly"] \
        note [json::write string "domestic schedule-driven display: prices appear only after flight selection and are not in this result"] \
        origin [json::write string $origin] \
        destination [json::write string $dest] \
        date [json::write string $date] \
        passengers [json::write object adults $adults children $children] \
        itineraries [json::write array {*}$itins]]
}

# ---------------------------------------------------------------------------
# Result-page rendering shared by both shapes

proc hu::render_result {html origin dest date adults children asJson title url} {
    set obj [hu::extract_csd $html]
    set csd ""
    if {$obj ne "" && [catch {json::json2dict $obj} csd]} { set csd "" }

    set currency [hu::dgetp $csd {MapDataIn FARE_CURRENCY} "CNY"]

    if {[hu::dgetp $csd {mapDataUI LIST_BOUND}] ne ""} {
        if {$asJson} {
            return [hu::render_intl_json $csd $origin $dest $date $adults $children $currency]
        }
        return [hu::render_intl_text $csd $origin $dest $date $adults $children $currency]
    }
    if {[hu::dget $csd AVAI] ne ""} {
        if {$asJson} {
            return [hu::render_dom_json $csd $origin $dest $date $adults $children]
        }
        return [hu::render_dom_text $csd $origin $dest $date $adults $children]
    }
    # Neither data model is present: report what the site said, if anything.
    set msgs {}
    foreach m [hu::dget $csd LIST_MSG] {
        if {[string is list $m] && [llength $m] % 2 == 0} {
            foreach {k v} $m { lappend msgs $v }
        } else {
            lappend msgs $m
        }
    }
    set detail ""
    if {[llength $msgs]} { set detail "; site message: [join $msgs {; }]" }
    return "unrecognised result page: title '$title' at $url$detail"
}

# ---------------------------------------------------------------------------

proc serialiser_run {skillArgs} {
    if {[llength $skillArgs] < 3} {
        emit [hu::usage]
        return
    }
    set origin [string toupper [lindex $skillArgs 0]]
    set dest [string toupper [lindex $skillArgs 1]]
    set date [lindex $skillArgs 2]
    set adults 1
    set children 0
    set asJson 0
    for {set i 3} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --adults   { incr i; set adults [lindex $skillArgs $i] }
            --children { incr i; set children [lindex $skillArgs $i] }
            --json     { set asJson 1 }
            default    { emit "unknown option $a\n[hu::usage]"; return }
        }
    }

    if {![regexp {^[A-Z]{3}$} $origin] || ![regexp {^[A-Z]{3}$} $dest]} {
        emit "bad route: origin and destination must be 3-letter IATA codes\n[hu::usage]"
        return
    }
    if {$origin eq $dest} {
        emit "bad route: origin and destination are both $origin"
        return
    }
    if {![string is integer -strict $adults] || $adults < 1 || $adults > 9} {
        emit "bad passenger count: adults must be 1-9, got $adults"
        return
    }
    if {![string is integer -strict $children] || $children < 0 || $children > 8} {
        emit "bad passenger count: children must be 0-8, got $children"
        return
    }
    if {$adults + $children > 9} {
        emit "bad passenger count: at most 9 passengers in total"
        return
    }
    if {![regexp {^\d{4}-\d{2}-\d{2}$} $date] \
            || [catch {clock scan $date -format %Y-%m-%d -gmt 1}]} {
        emit "bad date: expected YYYY-MM-DD, got $date"
        return
    }
    set today [clock format [clock seconds] -format %Y-%m-%d]
    if {[string compare $date $today] < 0} {
        emit "bad date: $date is in the past (today is $today)"
        return
    }

    # Arm the Network domain on entry (capture, not nav): the doEnc submit
    # chain needs the domain live, and the real-browser navigation is what
    # passes Imperva.
    capture $hu::HOME --seconds 12 --match "__none__"
    set st [state]
    if {[dict get $st terminal] ne ""} {
        emit "wall: terminal state '[dict get $st terminal]' at [dict get $st lastNav]"
        return
    }
    dwell 3

    # YYYYMMDD0000: the form's wire format for a date with no time preference.
    set wireDate "[string map {- {}} $date]0000"

    set js [format {
        (function(){
            var jq = window.jQuery || window.$;
            if (!jq) return "no-jquery";
            var form = jq("form.flight-form-srch-REVENUE");
            if (!form.length) return "no-form";
            form.find("input[name=B_LOCATION_1]").val("%s");
            form.find("input[name=E_LOCATION_1]").val("%s");
            form.find("input[name=B_DATE_1]").val("%s");
            form.find("input[name=B_DATE_2]").val("");
            form.find("input[name=TRIP_TYPE][value=O]").prop("checked", true).trigger("change");
            form.find("input[name=NB_ADT], select[name=NB_ADT]").val("%s");
            form.find("input[name=NB_CHD], select[name=NB_CHD]").val("%s");
            jq("#filght-search-from-REVENUE").val("%s");
            jq("#filght-search-to-REVENUE").val("%s");
            return "ok";
        })()
    } $origin $dest $wireDate $adults $children $origin $dest]
    set filled ""
    catch { set filled [eval $js] }
    if {$filled ne "ok"} {
        emit "unrecognised result page: the Home page did not present the search form (probe returned '$filled')"
        return
    }

    # The eval may raise as the navigation tears the context down; the submit
    # itself still fires.
    catch { eval {HTMLFormElement.prototype.submit.call(document.querySelector("form.flight-form-srch-REVENUE"))} }
    dwell 25

    # The availability app parks on a "Please wait..." interstitial that
    # reloads itself into the results; give it extra rounds before giving up.
    set title ""
    catch { set title [eval {document.title}] }
    set rounds 0
    while {[string match -nocase "*wait*" $title] && $rounds < 3} {
        dwell 15
        incr rounds
        catch { set title [eval {document.title}] }
    }
    if {[string match -nocase "*wait*" $title]} {
        emit "wait page never resolved: still on '$title' after [expr {25 + $rounds * 15}]s"
        return
    }
    set url ""
    catch { set url [eval {document.location.href}] }

    set html ""
    catch { set html [dump] }
    if {$html eq ""} {
        emit "unrecognised result page: empty dump at $url (title '$title')"
        return
    }

    emit [hu::render_result $html $origin $dest $date $adults $children $asJson $title $url]
}
