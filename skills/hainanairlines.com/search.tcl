#!/usr/bin/env tclsh
# Hainan Airlines (HU) one-way and return fare search on www.hainanairlines.com.
#
# Access pattern (verified live, see the sibling SKILL.md for the caller view):
# the Home page's REVENUE search form is filled by writing its hidden inputs
# (B_LOCATION_1 / E_LOCATION_1 / B_DATE_1 / B_DATE_2, TRIP_TYPE, NB_ADT /
# NB_CHD) and then calling the native HTMLFormElement submit. The site's own click-handler
# chain (flightSearchForm.js) validates, may show popups, and ends in a plain
# formRef.submit() with no field mutation, so a native submit with the fields
# pre-set posts byte-identically to a human search — including the dynamic
# per-render csrf hidden input. A composed GET deep link to the same endpoint
# fails with "4000 System Error" (it lacks the csrf/session package), and
# typing into the visible location widget fails because its container computes
# display:none with a zero bounding rect. So: field injection + native submit,
# nothing else.
#
# The form's whole trip-type vocabulary, read from the live Home page: the
# TRIP_TYPE radios are exactly R ("Round Trip", the default) and O ("One-way"),
# and the field set carries one location pair and two dates (B_DATE_1 /
# B_DATE_2) and nothing else — no second location pair, no third date, no
# multi-city wording anywhere on the page. Multi-city does not exist in this
# form, so this skill does not offer it.
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
#    seat status live in clientSideData.AVAI.LIST_BOUND[bi].LIST_FLIGHT (one
#    bound per journey direction); the page defers prices to flight selection,
#    so none are in the dump.
#
# A return search (TRIP_TYPE=R, B_DATE_2 set) on an international market comes
# back as the same Flex Pricer page with BOTH bounds in one payload
# (mapDataUI.LIST_BOUND has two entries) and a combinational price model:
# mapDataOut.LIST_PANEL[0].LIST_TAB[0].LIST_RECOMMENDATION is the whole-journey
# price list, one entry per (outbound flight+fare family, return flight+fare
# family) combination, each with LIST_TRIP_PRICE[0].TOTAL_AMOUNT covering the
# whole journey. Established from the payload itself, not from plausibility:
# each recommendation appears once under each bound's flight
# (RECOMMENDATIONS_BY_FF...RECOMMENDATIONS, keyed <otherBoundFF>-<otherBound
# FLIGHT_ID>, sharing one RECOMMENDATION_ID), and the two per-bound
# PRICE_TO_DISPLAY values summed to LIST_TRIP_PRICE[0].TOTAL_AMOUNT for all
# 114 of 114 recommendations on the first capture (CKG-MAD 2026-09-02 /
# 2026-09-09). So the per-bound prices are components of the journey total,
# not fares — the renderer prints only the recommendation totals and treats
# the bound prices as internal. LIST_PANEL[1] carries alternate-city upsell
# recommendations (other origins/destinations than the queried journey) and
# is deliberately ignored. The totals cover the whole party, not one adult:
# the same return queried with NB_ADT=2 priced every combination at exactly
# twice its 1-adult TOTAL_AMOUNT (the one-way page, by contrast, displays
# per-adult fares).
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
    return "Usage: hainanairlines.com/search <origin> <dest> <date YYYY-MM-DD> \[--return YYYY-MM-DD] \[--adults N] \[--children N] \[--json]"
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

# FLIGHT_ID -> segment list for bound $bi, from the proposed-bound side of
# the model (bound 0 the outbound, bound 1 the return of a return search).
proc hu::intl_segments {csd {bi 0}} {
    set map {}
    foreach f [hu::dgetp $csd [list mapDataOut LIST_PANEL 0 LIST_TAB 0 LIST_PROPOSED_BOUND $bi LIST_FLIGHT]] {
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
        trip [json::write string "one-way"] \
        origin [json::write string $origin] \
        destination [json::write string $dest] \
        date [json::write string $date] \
        passengers [json::write object adults $adults children $children] \
        currency [json::write string $currency] \
        itineraries [json::write array {*}$itins] \
        calendar [json::write array {*}$caljson]]
}

# ---------------------------------------------------------------------------
# Return (two-bound FlexPricer) shape. Prices come only from the whole-journey
# recommendation list; the per-bound PRICE_TO_DISPLAY values are components of
# those totals (they sum to TOTAL_AMOUNT, verified 114/114 on first capture)
# and are never rendered.

# FLIGHT_IDs of bound $bi in the page's display order (FLIGHT_INDEX).
proc hu::bound_flight_ids {csd bi} {
    set keyed {}
    foreach f [hu::dgetp $csd [list mapDataUI LIST_BOUND $bi LIST_FLIGHT]] {
        lappend keyed [list [hu::dget $f FLIGHT_INDEX 0] [hu::dget $f FLIGHT_ID]]
    }
    set out {}
    foreach kf [lsort -integer -index 0 $keyed] { lappend out [lindex $kf 1] }
    return $out
}

# Whole-journey recommendations of the queried journey (LIST_PANEL[0] only:
# LIST_PANEL[1] holds alternate-city upsells): list of dicts.
proc hu::ret_combos {csd} {
    set out {}
    foreach r [hu::dgetp $csd {mapDataOut LIST_PANEL 0 LIST_TAB 0 LIST_RECOMMENDATION}] {
        set total [hu::dgetp $r {LIST_TRIP_PRICE 0 TOTAL_AMOUNT}]
        if {![string is double -strict $total]} { continue }
        set seats [hu::dgetp $r {LIST_BOUND 0 LIST_FLIGHT 0 NUMBER_OF_LAST_SEATS} 9]
        set s1 [hu::dgetp $r {LIST_BOUND 1 LIST_FLIGHT 0 NUMBER_OF_LAST_SEATS} 9]
        if {[string is integer -strict $s1] \
                && (![string is integer -strict $seats] || $s1 < $seats)} {
            set seats $s1
        }
        lappend out [dict create \
            rid [hu::dget $r RECOMMENDATION_ID] \
            outId [hu::dgetp $r {LIST_BOUND 0 LIST_FLIGHT 0 FLIGHT_ID}] \
            outFF [hu::dgetp $r {LIST_BOUND 0 FARE_FAMILY SHORT_NAME}] \
            inId [hu::dgetp $r {LIST_BOUND 1 LIST_FLIGHT 0 FLIGHT_ID}] \
            inFF [hu::dgetp $r {LIST_BOUND 1 FARE_FAMILY SHORT_NAME}] \
            total $total \
            base [hu::dgetp $r {LIST_TRIP_PRICE 0 AMOUNT_WITHOUT_TAX} 0] \
            tax [hu::dgetp $r {LIST_TRIP_PRICE 0 TAX} 0] \
            currency [hu::dgetp $r {LIST_TRIP_PRICE 0 CURRENCY CODE}] \
            seats $seats]
    }
    return $out
}

# The cabin key of one combination; the two bounds' fare families have only
# been seen in the same cabin, but a mixed pair would render as "ECONOMY/
# BUSINESS" rather than mislabel either half.
proc hu::combo_cabin {c ffCabin} {
    set a [hu::dget $ffCabin [dict get $c outFF] [dict get $c outFF]]
    set b [hu::dget $ffCabin [dict get $c inFF] [dict get $c inFF]]
    if {$a eq $b} { return $a }
    return "$a/$b"
}

proc hu::combo_ff_label {c ffName} {
    set outFF [dict get $c outFF]
    set inFF [dict get $c inFF]
    set a [hu::dget $ffName $outFF $outFF]
    if {$outFF eq $inFF} { return $a }
    return "$a + [hu::dget $ffName $inFF $inFF]"
}

# "O1) CKG 02:25 → MAD 08:55   13h30m, nonstop" plus one line per segment.
proc hu::flight_block {label segs qdate} {
    set first [lindex $segs 0]
    set last [lindex $segs end]
    set dep [hu::timestr [hu::dget $first B_DATE 0] $qdate]
    set arr [hu::timestr [hu::dget $last E_DATE 0] $qdate]
    set dur [hu::duration [hu::itin_duration_ms $segs]]
    set stops [hu::stopstr [expr {[llength $segs] - 1}]]
    set out "$label) [hu::dgetp $first {B_LOCATION LOCATION_CODE}] $dep → [hu::dgetp $last {E_LOCATION LOCATION_CODE}] $arr   $dur, $stops"
    foreach seg $segs {
        append out "\n   [hu::seg_line $seg $qdate]"
    }
    return $out
}

# Combos grouped per (outbound, return) flight pair, pairs ordered by their
# cheapest total: list of {pairKey comboList}.
proc hu::ret_pairs {combos} {
    set pairs {}
    foreach c $combos {
        dict lappend pairs "[dict get $c outId],[dict get $c inId]" $c
    }
    set keyed {}
    foreach {pk lst} $pairs {
        set lo ""
        foreach c $lst {
            set t [dict get $c total]
            if {$lo eq "" || $t < $lo} { set lo $t }
        }
        lappend keyed [list $lo $pk $lst]
    }
    set out {}
    foreach k [lsort -real -index 0 $keyed] {
        lappend out [list [lindex $k 1] [lindex $k 2]]
    }
    return $out
}

# Cabin keys present in one pair's combos, CABIN_ORDER first.
proc hu::pair_cabins {lst ffCabin} {
    variable CABIN_ORDER
    set present {}
    foreach c $lst {
        set cab [hu::combo_cabin $c $ffCabin]
        if {$cab ni $present} { lappend present $cab }
    }
    set keys {}
    foreach cab $CABIN_ORDER {
        if {$cab in $present} { lappend keys $cab }
    }
    foreach cab $present {
        if {$cab ni $keys} { lappend keys $cab }
    }
    return $keys
}

proc hu::render_ret_text {csd origin dest date retDate adults children currency} {
    set head "Hainan Airlines $origin → $dest $date + $dest → $origin $retDate, return, adults $adults children $children (each fare is the whole journey's total for the whole party)"
    set combos [hu::ret_combos $csd]
    set outIds [hu::bound_flight_ids $csd 0]
    set inIds [hu::bound_flight_ids $csd 1]
    if {![llength $combos] || ![llength $outIds] || ![llength $inIds]} {
        return "$head\n\nNo itineraries for $origin → $dest $date + $dest → $origin $retDate."
    }
    set segOut [hu::intl_segments $csd 0]
    set segIn [hu::intl_segments $csd 1]
    set ffCabin [hu::ff_cabins $csd]
    set ffName [hu::ff_names $csd]

    set out $head
    set num {}
    append out "\n\nOutbound flights:"
    set n 0
    foreach id $outIds {
        incr n
        dict set num "O,$id" "O$n"
        append out "\n[hu::flight_block O$n [hu::dget $segOut $id] $date]"
    }
    append out "\n\nReturn flights:"
    set n 0
    foreach id $inIds {
        incr n
        dict set num "R,$id" "R$n"
        append out "\n[hu::flight_block R$n [hu::dget $segIn $id] $retDate]"
    }

    append out "\n\nWhole-journey fares per flight pair, cheapest pair first:"
    foreach pair [hu::ret_pairs $combos] {
        lassign $pair pk lst
        lassign [split $pk ,] oid iid
        append out "\n\n[hu::dget $num O,$oid ?] + [hu::dget $num R,$iid ?]"
        foreach cab [hu::pair_cabins $lst $ffCabin] {
            set keyed {}
            foreach c $lst {
                if {[hu::combo_cabin $c $ffCabin] ne $cab} { continue }
                lappend keyed [list [dict get $c total] $c]
            }
            set fares [lsort -real -index 0 $keyed]
            if {![llength $fares]} { continue }
            set line [format "   %-14s %s %s" [hu::cabin_label $cab] $currency [hu::amt [lindex $fares 0 0]]]
            set parts {}
            foreach tc $fares {
                set c [lindex $tc 1]
                set part "[hu::combo_ff_label $c $ffName] [hu::amt [dict get $c total]]"
                set seats [dict get $c seats]
                if {[string is integer -strict $seats] && $seats < 9} {
                    append part " (last $seats)"
                }
                lappend parts $part
            }
            append line "   \[[join $parts {, }]\]"
            append out "\n$line"
        }
    }
    return $out
}

# One bound flight as a JSON itinerary object (no fares: return fares are
# whole-journey, so they live in the combinations array).
proc hu::json_flight {segs} {
    set first [lindex $segs 0]
    set last [lindex $segs end]
    return [json::write object \
        origin [json::write string [hu::dgetp $first {B_LOCATION LOCATION_CODE}]] \
        destination [json::write string [hu::dgetp $last {E_LOCATION LOCATION_CODE}]] \
        departure [json::write string "[hu::ms_date [hu::dget $first B_DATE 0]] [hu::ms_time [hu::dget $first B_DATE 0]]"] \
        arrival [json::write string "[hu::ms_date [hu::dget $last E_DATE 0]] [hu::ms_time [hu::dget $last E_DATE 0]]"] \
        durationMinutes [expr {[hu::itin_duration_ms $segs] / 60000}] \
        stops [expr {[llength $segs] - 1}] \
        segments [json::write array {*}[hu::json_segments $segs]]]
}

proc hu::render_ret_json {csd origin dest date retDate adults children currency} {
    set segOut [hu::intl_segments $csd 0]
    set segIn [hu::intl_segments $csd 1]
    set ffCabin [hu::ff_cabins $csd]
    set ffName [hu::ff_names $csd]

    set outIds [hu::bound_flight_ids $csd 0]
    set inIds [hu::bound_flight_ids $csd 1]
    set outjson {}
    set idxOut {}
    set n 0
    foreach id $outIds {
        incr n
        dict set idxOut $id $n
        lappend outjson [hu::json_flight [hu::dget $segOut $id]]
    }
    set injson {}
    set idxIn {}
    set n 0
    foreach id $inIds {
        incr n
        dict set idxIn $id $n
        lappend injson [hu::json_flight [hu::dget $segIn $id]]
    }

    set combjson {}
    foreach pair [hu::ret_pairs [hu::ret_combos $csd]] {
        lassign $pair pk lst
        set keyed {}
        foreach c $lst { lappend keyed [list [dict get $c total] $c] }
        foreach tc [lsort -real -index 0 $keyed] {
            set c [lindex $tc 1]
            set cur [dict get $c currency]
            if {$cur eq ""} { set cur $currency }
            lappend combjson [json::write object \
                outboundFlight [hu::dget $idxOut [dict get $c outId] 0] \
                returnFlight [hu::dget $idxIn [dict get $c inId] 0] \
                cabin [json::write string [hu::cabin_label [hu::combo_cabin $c $ffCabin]]] \
                fareFamilies [json::write object \
                    outbound [json::write object \
                        code [json::write string [dict get $c outFF]] \
                        label [json::write string [hu::dget $ffName [dict get $c outFF] [dict get $c outFF]]]] \
                    return [json::write object \
                        code [json::write string [dict get $c inFF]] \
                        label [json::write string [hu::dget $ffName [dict get $c inFF] [dict get $c inFF]]]]] \
                total [dict get $c total] \
                base [dict get $c base] \
                tax [dict get $c tax] \
                currency [json::write string $cur] \
                lastSeats [dict get $c seats]]
        }
    }
    return [json::write object \
        type [json::write string "farePriced"] \
        trip [json::write string "return"] \
        origin [json::write string $origin] \
        destination [json::write string $dest] \
        date [json::write string $date] \
        returnDate [json::write string $retDate] \
        passengers [json::write object adults $adults children $children] \
        currency [json::write string $currency] \
        outboundFlights [json::write array {*}$outjson] \
        returnFlights [json::write array {*}$injson] \
        combinations [json::write array {*}$combjson]]
}

# ---------------------------------------------------------------------------
# Domestic (schedule-driven) shape

proc hu::dom_bounds {csd} {
    return [hu::dgetp $csd {AVAI LIST_BOUND}]
}

proc hu::dom_flights {csd {bi 0}} {
    return [hu::dgetp $csd [list AVAI LIST_BOUND $bi LIST_FLIGHT]]
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

# One domestic flight as its text block, numbered $n against query date $qdate.
proc hu::dom_flight_block {n f qdate} {
    set segs [hu::dget $f LIST_SEGMENT]
    set first [lindex $segs 0]
    set last [lindex $segs end]
    set dep [hu::timestr [hu::dget $first B_DATE 0] $qdate]
    set arr [hu::timestr [hu::dget $last E_DATE 0] $qdate]
    # Domestic flights share one time zone, so first-to-last is real time.
    set dur [hu::duration [expr {[hu::dget $last E_DATE 0] - [hu::dget $first B_DATE 0]}]]
    set stops [expr {[llength $segs] - 1}]
    set out "\n\n$n) [hu::dgetp $first {B_LOCATION LOCATION_CODE}] $dep → [hu::dgetp $last {E_LOCATION LOCATION_CODE}] $arr   $dur, [hu::stopstr $stops]"
    foreach seg $segs {
        set cabs {}
        foreach cs [hu::seg_cabins $seg] {
            lassign $cs label status
            lappend cabs "$label $status"
        }
        set line "   [hu::seg_line $seg $qdate]   [hu::dgetp $seg {EQUIPMENT NAME}]"
        if {[llength $cabs]} { append line "   seats: [join $cabs {, }]" }
        append out "\n$line"
    }
    return $out
}

proc hu::render_dom_text {csd origin dest date retDate adults children} {
    set note "Schedule-driven availability: this page lists flights and per-cabin seat counts; the site defers prices to flight selection, so no prices are in this result (seat count 9 means nine or more)."
    if {$retDate eq ""} {
        set flights [hu::dom_flights $csd]
        set head "Hainan Airlines $origin → $dest $date, one-way, adults $adults children $children"
        if {![llength $flights]} {
            return "$head\n\nNo flights for $origin → $dest on $date."
        }
        set out "$head\n$note"
        set n 0
        foreach f $flights {
            incr n
            append out [hu::dom_flight_block $n $f $date]
        }
        return $out
    }
    set head "Hainan Airlines $origin → $dest $date + $dest → $origin $retDate, return, adults $adults children $children"
    set out "$head\n$note"
    foreach {bi qdate label} [list 0 $date "Outbound $origin → $dest $date" 1 $retDate "Return $dest → $origin $retDate"] {
        set flights [hu::dom_flights $csd $bi]
        append out "\n\n$label:"
        if {![llength $flights]} {
            append out "\nNo flights."
            continue
        }
        set n 0
        foreach f $flights {
            incr n
            append out [hu::dom_flight_block $n $f $qdate]
        }
    }
    return $out
}

proc hu::dom_json_itins {flights} {
    set itins {}
    foreach f $flights {
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
    return $itins
}

proc hu::render_dom_json {csd origin dest date retDate adults children} {
    set note "domestic schedule-driven display: prices appear only after flight selection and are not in this result"
    if {$retDate eq ""} {
        return [json::write object \
            type [json::write string "scheduleOnly"] \
            trip [json::write string "one-way"] \
            note [json::write string $note] \
            origin [json::write string $origin] \
            destination [json::write string $dest] \
            date [json::write string $date] \
            passengers [json::write object adults $adults children $children] \
            itineraries [json::write array {*}[hu::dom_json_itins [hu::dom_flights $csd]]]]
    }
    return [json::write object \
        type [json::write string "scheduleOnly"] \
        trip [json::write string "return"] \
        note [json::write string $note] \
        origin [json::write string $origin] \
        destination [json::write string $dest] \
        date [json::write string $date] \
        returnDate [json::write string $retDate] \
        passengers [json::write object adults $adults children $children] \
        outboundItineraries [json::write array {*}[hu::dom_json_itins [hu::dom_flights $csd 0]]] \
        returnItineraries [json::write array {*}[hu::dom_json_itins [hu::dom_flights $csd 1]]]]
}

# ---------------------------------------------------------------------------
# Result-page rendering shared by both shapes

proc hu::render_result {html origin dest date retDate adults children asJson title url} {
    set obj [hu::extract_csd $html]
    set csd ""
    if {$obj ne "" && [catch {json::json2dict $obj} csd]} { set csd "" }

    set currency [hu::dgetp $csd {MapDataIn FARE_CURRENCY} "CNY"]

    if {[hu::dgetp $csd {mapDataUI LIST_BOUND}] ne ""} {
        set nb [llength [hu::dgetp $csd {mapDataUI LIST_BOUND}]]
        if {$retDate eq ""} {
            if {$asJson} {
                return [hu::render_intl_json $csd $origin $dest $date $adults $children $currency]
            }
            return [hu::render_intl_text $csd $origin $dest $date $adults $children $currency]
        }
        # A return render is only honest when the payload carries both legs;
        # anything else would print one leg under a whole-journey heading.
        if {$nb != 2} {
            return "return search answered with $nb bound(s) instead of 2: the payload does not cover the whole journey, so it is not rendered as one (title '$title' at $url)"
        }
        if {$asJson} {
            return [hu::render_ret_json $csd $origin $dest $date $retDate $adults $children $currency]
        }
        return [hu::render_ret_text $csd $origin $dest $date $retDate $adults $children $currency]
    }
    if {[hu::dget $csd AVAI] ne ""} {
        if {$retDate ne "" && [llength [hu::dom_bounds $csd]] != 2} {
            return "return search answered with [llength [hu::dom_bounds $csd]] bound(s) instead of 2: the payload does not cover the whole journey, so it is not rendered as one (title '$title' at $url)"
        }
        if {$asJson} {
            return [hu::render_dom_json $csd $origin $dest $date $retDate $adults $children]
        }
        return [hu::render_dom_text $csd $origin $dest $date $retDate $adults $children]
    }
    # Neither data model is present: report what the site said, if anything.
    set msgs {}
    foreach m [hu::dget $csd LIST_MSG] {
        lappend msgs $m
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
    set retDate ""
    set adults 1
    set children 0
    set asJson 0
    for {set i 3} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --return   { incr i; set retDate [lindex $skillArgs $i] }
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
    if {$retDate ne ""} {
        if {![regexp {^\d{4}-\d{2}-\d{2}$} $retDate] \
                || [catch {clock scan $retDate -format %Y-%m-%d -gmt 1}]} {
            emit "bad date: expected YYYY-MM-DD for --return, got $retDate"
            return
        }
        if {[string compare $retDate $date] < 0} {
            emit "bad date: return $retDate is before departure $date"
            return
        }
    }

    # capture rather than nav, for the one property that separates them: only
    # capture arms the Network domain, which the doEnc submit chain needs live.
    # The match glob is written to catch nothing, the arming being the point.
    capture $hu::HOME --seconds 12 --match "__none__"
    set st [state]
    if {[dict get $st terminal] ne ""} {
        emit "wall: terminal state '[dict get $st terminal]' at [dict get $st lastNav]"
        return
    }
    dwell 3

    # YYYYMMDD0000: the form's wire format for a date with no time preference.
    # TRIP_TYPE is the form's own vocabulary: O one-way, R return (its whole
    # radio set; there is no multi-city in this form).
    set wireDate "[string map {- {}} $date]0000"
    if {$retDate eq ""} {
        set tripType "O"
        set wireDate2 ""
    } else {
        set tripType "R"
        set wireDate2 "[string map {- {}} $retDate]0000"
    }

    set js [format {
        (function(){
            var jq = window.jQuery || window.$;
            if (!jq) return "no-jquery";
            var form = jq("form.flight-form-srch-REVENUE");
            if (!form.length) return "no-form";
            form.find("input[name=B_LOCATION_1]").val("%s");
            form.find("input[name=E_LOCATION_1]").val("%s");
            form.find("input[name=B_DATE_1]").val("%s");
            form.find("input[name=B_DATE_2]").val("%s");
            form.find("input[name=TRIP_TYPE][value=%s]").prop("checked", true).trigger("change");
            form.find("input[name=NB_ADT], select[name=NB_ADT]").val("%s");
            form.find("input[name=NB_CHD], select[name=NB_CHD]").val("%s");
            jq("#filght-search-from-REVENUE").val("%s");
            jq("#filght-search-to-REVENUE").val("%s");
            return "ok";
        })()
    } $origin $dest $wireDate $wireDate2 $tripType $adults $children $origin $dest]
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

    emit [hu::render_result $html $origin $dest $date $retDate $adults $children $asJson $title $url]
}
