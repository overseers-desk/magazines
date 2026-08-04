#!/usr/bin/env tclsh
# China Southern fare search on oversea.csair.com, driven by the booking SPA's
# deep link (one navigation, no form driving):
#
#   https://oversea.csair.com/tk/au/en/book/flights?m=0&t=<DEP>-<ARR>-<YYYYMMDD>&p=<ADT><CNN><INF>[&cy=CCC]
#
#   m=0 one-way; t = origin-dest-date, uppercase IATA (city or airport codes),
#   origin != dest; p = three digits adults/children/infants, adults >= 1,
#   infants <= adults, total < 10; cy = optional display currency.
#
# On load the app resolves the params, obtains an opaque token, and
# router-pushes to /book/shop?enc=<token>, where it fires GET /api/shop/search;
# that response body is the fare list. One capture over *api/shop/* collects it.
# The enc token is short-lived and never part of this skill's interface:
# parameters in, fares out.
#
# The app accepts dates in the window today+2 .. today+1 year only. Outside the
# window, or on any parameter set it rejects, it falls back to the empty search
# form instead of erroring: the landing URL never reaches /book/shop?enc=.
# That missing landing is the rejected signal; the date window is checked here
# before navigating so the common case never burns a page load.
#
# Search-body shape (ita.sliceGrid): row[] per itinerary; row.slice.segment[]
# carries marketCarrier/marketFlight, operationCarrier/operationFlight (empty
# when CZ operates its own metal), origin, destination, departure/arrival as
# [date time utcOffset], leg[].aircraft; row.cell.<cabinKey> carries
# saleTotal/saleFareTotal/saleTaxTotal {amount currency} plus brand[] per fare
# brand; ita.sliceGrid.column maps cabin keys to labels (YYY Economy,
# WWW PremiumEconomy, CCC Business, FFF First). All amounts cover the whole
# party, not one passenger.

package require json
package require json::write

namespace eval cz {}

set cz::BASE "https://oversea.csair.com/tk/au/en/book/flights"

# Cabin display order; any unlisted key renders after these, in payload order.
set cz::CABIN_ORDER {YYY WWW CCC FFF}

proc cz::usage {} {
    return "Usage: csair.com/search <origin> <dest> <date YYYY-MM-DD> \[--adults N] \[--children N] \[--infants N] \[--currency CCC] \[--json]"
}

proc cz::dget {d key {default ""}} {
    if {$d ne "" && ![catch {dict get $d $key} v]} { return $v }
    return $default
}

proc cz::amt {v} {
    if {[string is double -strict $v]} { return [format %.2f $v] }
    return $v
}

# Whole days from $base to $date (both YYYY-MM-DD); 0 on an unparseable input.
proc cz::days_from {base date} {
    if {[catch {clock scan $base -format %Y-%m-%d -gmt 1} b]} { return 0 }
    if {[catch {clock scan $date -format %Y-%m-%d -gmt 1} d]} { return 0 }
    return [expr {($d - $b) / 86400}]
}

# "18:35" or "18:35 (+1)" when the segment's date is past the queried date
# ($qdate, the same value at every call site).
proc cz::timestr {when qdate} {
    lassign $when d t
    set off [cz::days_from $qdate $d]
    if {$off > 0} { return "$t (+$off)" }
    return $t
}

proc cz::duration {minutes} {
    if {![string is integer -strict $minutes]} { return "" }
    return "[expr {$minutes / 60}]h[format %02d [expr {$minutes % 60}]]m"
}

# "CZ2130 (op OQ2130) LHW 12:30 → CAN 15:55"
proc cz::seg_line {seg qdate} {
    set flight "[cz::dget $seg marketCarrier][cz::dget $seg marketFlight]"
    set op ""
    if {[cz::dget $seg operationCarrier] ne ""} {
        set op " (op [cz::dget $seg operationCarrier][cz::dget $seg operationFlight])"
    }
    set dep [cz::timestr [cz::dget $seg departure] $qdate]
    set arr [cz::timestr [cz::dget $seg arrival] $qdate]
    return "$flight$op [cz::dget $seg origin] $dep → [cz::dget $seg destination] $arr"
}

# Brands sorted cheapest first by saleTotal amount.
proc cz::sorted_brands {cab} {
    set keyed {}
    foreach b [cz::dget $cab brand] {
        lappend keyed [list [cz::dget [cz::dget $b saleTotal] amount 0] $b]
    }
    set out {}
    foreach kb [lsort -real -index 0 $keyed] {
        lappend out [lindex $kb 1]
    }
    return $out
}

# Cabin keys of a row's cell, CABIN_ORDER first, leftovers in payload order.
proc cz::cabin_keys {cell} {
    variable CABIN_ORDER
    set keys {}
    foreach k $CABIN_ORDER {
        if {[dict exists $cell $k]} { lappend keys $k }
    }
    foreach k [dict keys $cell] {
        if {$k ni $keys} { lappend keys $k }
    }
    return $keys
}

proc cz::render_text {ita origin dest date adults children infants} {
    set grid [cz::dget $ita sliceGrid]
    set rows [cz::dget $grid row]
    set column [cz::dget $grid column]

    set head "China Southern $origin → $dest $date, one-way, adults $adults children $children infants $infants (totals cover the whole party)"
    if {![llength $rows]} {
        return "$head\n\nNo itineraries for $origin → $dest on $date."
    }

    set out $head
    set n 0
    foreach row $rows {
        incr n
        set slice [cz::dget $row slice]
        set segs [cz::dget $slice segment]
        set dep [cz::timestr [cz::dget $slice departure] $date]
        set arr [cz::timestr [cz::dget $slice arrival] $date]
        set dur [cz::duration [cz::dget $slice duration]]
        set stops [expr {[llength $segs] - 1}]
        switch -- $stops {
            0 { set stopstr "nonstop" }
            1 { set stopstr "1 stop" }
            default { set stopstr "$stops stops" }
        }
        append out "\n\n$n) [cz::dget $slice origin] $dep → [cz::dget $slice destination] $arr   $dur, $stopstr"
        foreach seg $segs {
            append out "\n   [cz::seg_line $seg $date]"
        }
        set cell [cz::dget $row cell]
        foreach ck [cz::cabin_keys $cell] {
            set cab [dict get $cell $ck]
            set label [cz::dget $column $ck $ck]
            set total [cz::dget $cab saleTotal]
            set line [format "   %-14s %s %s" $label \
                [cz::dget $total currency] [cz::amt [cz::dget $total amount]]]
            set brands {}
            foreach b [cz::sorted_brands $cab] {
                set bt [cz::dget $b saleTotal]
                lappend brands "[cz::dget $b brandCodeLabel] [cz::amt [cz::dget $bt amount]]"
            }
            if {[llength $brands]} {
                append line "   \[[join $brands {, }]\]"
            }
            append out "\n$line"
        }
    }
    return $out
}

proc cz::json_money {m} {
    return [json::write object \
        amount [cz::dget $m amount 0] \
        currency [json::write string [cz::dget $m currency]]]
}

proc cz::render_json {ita origin dest date adults children infants} {
    set grid [cz::dget $ita sliceGrid]
    set column [cz::dget $grid column]
    set itins {}
    foreach row [cz::dget $grid row] {
        set slice [cz::dget $row slice]
        set segjson {}
        foreach seg [cz::dget $slice segment] {
            set aircraft {}
            foreach leg [cz::dget $seg leg] {
                lappend aircraft [cz::dget $leg aircraft]
            }
            set pairs [list \
                flight [json::write string "[cz::dget $seg marketCarrier][cz::dget $seg marketFlight]"]]
            if {[cz::dget $seg operationCarrier] ne ""} {
                lappend pairs operatedBy [json::write string \
                    "[cz::dget $seg operationCarrier][cz::dget $seg operationFlight]"]
            }
            lappend pairs \
                origin [json::write string [cz::dget $seg origin]] \
                destination [json::write string [cz::dget $seg destination]] \
                departure [json::write string [join [cz::dget $seg departure] " "]] \
                arrival [json::write string [join [cz::dget $seg arrival] " "]] \
                aircraft [json::write string [join $aircraft "/"]]
            lappend segjson [json::write object {*}$pairs]
        }
        set cabjson {}
        set cell [cz::dget $row cell]
        foreach ck [cz::cabin_keys $cell] {
            set cab [dict get $cell $ck]
            set brands {}
            foreach b [cz::sorted_brands $cab] {
                lappend brands [json::write object \
                    code [json::write string [cz::dget $b brandCode]] \
                    label [json::write string [cz::dget $b brandCodeLabel]] \
                    saleTotal [cz::json_money [cz::dget $b saleTotal]] \
                    saleFareTotal [cz::json_money [cz::dget $b saleFareTotal]] \
                    saleTaxTotal [cz::json_money [cz::dget $b saleTaxTotal]]]
            }
            lappend cabjson [cz::dget $column $ck $ck] [json::write object \
                saleTotal [cz::json_money [cz::dget $cab saleTotal]] \
                saleFareTotal [cz::json_money [cz::dget $cab saleFareTotal]] \
                saleTaxTotal [cz::json_money [cz::dget $cab saleTaxTotal]] \
                brands [json::write array {*}$brands]]
        }
        lappend itins [json::write object \
            origin [json::write string [cz::dget $slice origin]] \
            destination [json::write string [cz::dget $slice destination]] \
            departure [json::write string [join [cz::dget $slice departure] " "]] \
            arrival [json::write string [join [cz::dget $slice arrival] " "]] \
            durationMinutes [cz::dget $slice duration 0] \
            stops [expr {[llength [cz::dget $slice segment]] - 1}] \
            segments [json::write array {*}$segjson] \
            cabins [json::write object {*}$cabjson]]
    }
    return [json::write object \
        origin [json::write string $origin] \
        destination [json::write string $dest] \
        date [json::write string $date] \
        passengers [json::write object adults $adults children $children infants $infants] \
        itineraries [json::write array {*}$itins]]
}

proc serialiser_run {skillArgs} {
    if {[llength $skillArgs] < 3} {
        emit [cz::usage]
        return
    }
    set origin [string toupper [lindex $skillArgs 0]]
    set dest [string toupper [lindex $skillArgs 1]]
    set date [lindex $skillArgs 2]
    set adults 1
    set children 0
    set infants 0
    set currency ""
    set asJson 0
    for {set i 3} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --adults   { incr i; set adults [lindex $skillArgs $i] }
            --children { incr i; set children [lindex $skillArgs $i] }
            --infants  { incr i; set infants [lindex $skillArgs $i] }
            --currency { incr i; set currency [string toupper [lindex $skillArgs $i]] }
            --json     { set asJson 1 }
            default    { emit "unknown option $a\n[cz::usage]"; return }
        }
    }

    if {![regexp {^[A-Z]{3}$} $origin] || ![regexp {^[A-Z]{3}$} $dest]} {
        emit "bad route: origin and destination must be 3-letter IATA codes\n[cz::usage]"
        return
    }
    if {$origin eq $dest} {
        emit "bad route: origin and destination are both $origin"
        return
    }
    foreach {name v} [list adults $adults children $children infants $infants] {
        if {![string is integer -strict $v] || $v < 0 || $v > 9} {
            emit "bad passenger count: $name must be 0-9, got $v"
            return
        }
    }
    if {$adults < 1} {
        emit "bad passenger count: at least 1 adult"
        return
    }
    if {$infants > $adults} {
        emit "bad passenger count: infants ($infants) exceed adults ($adults)"
        return
    }
    if {$adults + $children + $infants > 9} {
        emit "bad passenger count: at most 9 passengers in total"
        return
    }
    if {$currency ne "" && ![regexp {^[A-Z]{3}$} $currency]} {
        emit "bad currency: expected a 3-letter code, got $currency"
        return
    }
    if {![regexp {^\d{4}-\d{2}-\d{2}$} $date] \
            || [catch {clock scan $date -format %Y-%m-%d -gmt 1}]} {
        emit "bad date: expected YYYY-MM-DD, got $date"
        return
    }
    # The booking app's own window; a date outside it is rejected client-side,
    # so refuse it here without touching the site.
    set now [clock seconds]
    set minDate [clock format [clock add $now 2 days] -format %Y-%m-%d]
    set maxDate [clock format [clock add $now 1 year] -format %Y-%m-%d]
    if {[string compare $date $minDate] < 0 || [string compare $date $maxDate] > 0} {
        emit "date out of window: $date is outside the bookable range $minDate .. $maxDate (today+2 days to today+1 year)"
        return
    }

    set ymd [string map {- ""} $date]
    set url "$cz::BASE?m=0&t=$origin-$dest-$ymd&p=$adults$children$infants"
    if {$currency ne ""} { append url "&cy=$currency" }

    # 30s window: the app fetches its token, router-pushes to the fare page,
    # then loads the search; the verb's 10s default closes before that ends.
    set triples [capture $url --seconds 30 --match "*api/shop/*"]
    set st [state]
    if {[dict get $st terminal] ne ""} {
        emit "wall: terminal state '[dict get $st terminal]' at [dict get $st lastNav]"
        return
    }
    # Rejected-parameter signal: the app fell back to the empty search form
    # instead of pushing to the fare page, so no search ever fired.
    set landing [dict get $st lastNav]
    if {![string match "*/book/shop?enc=*" $landing]} {
        emit "parameters rejected: the booking app fell back to the search form instead of the fare page (landed at $landing)"
        return
    }

    set body ""
    foreach t $triples {
        lassign $t u status b
        if {[string match "*/api/shop/search*" $u] && $status == 200} { set body $b }
    }
    if {$body eq ""} {
        emit "no fare payload: landed on the fare page but no /api/shop/search response arrived within the capture window"
        return
    }

    if {[catch {json::json2dict $body} data] || [catch {dict get $data ita} ita]} {
        emit "unexpected fare payload: /api/shop/search returned [string length $body] bytes that do not parse as the known ita shape"
        return
    }

    if {$asJson} {
        emit [cz::render_json $ita $origin $dest $date $adults $children $infants]
    } else {
        emit [cz::render_text $ita $origin $dest $date $adults $children $infants]
    }
}
