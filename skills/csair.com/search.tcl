#!/usr/bin/env tclsh
# China Southern fare search on oversea.csair.com, driven by the booking SPA's
# deep link (one navigation, no form driving):
#
#   https://oversea.csair.com/tk/au/en/book/flights?m=<M>&t=<SEGS>&p=<ADT><CNN><INF>[&cy=CCC]
#
#   m = trip mode: 0 one-way, 1 return, 2 multi-city (2..5 segments);
#   t = comma-separated segments, each <DEP>-<ARR>-<YYYYMMDD>, uppercase IATA
#   (city or airport codes), origin != dest per segment; a return is two
#   segments (out, back); p = three digits adults/children/infants,
#   adults >= 1, infants <= adults, total < 10; cy = optional display
#   currency.
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
    return "Usage: csair.com/search <origin> <dest> <date YYYY-MM-DD> \[--return YYYY-MM-DD] \[--adults N] \[--children N] \[--infants N] \[--currency CCC] \[--json]\n       csair.com/search --leg DEP-ARR-YYYY-MM-DD --leg DEP-ARR-YYYY-MM-DD \[--leg ... up to 5] \[--adults N] \[--children N] \[--infants N] \[--currency CCC] \[--json]"
}

# The /api/shop/* refusal envelope: {"desc":"...","ex":"CZWEBnnnnnn"}, arriving
# as HTTP 200 where the fare payload would be. Seen live 2026-08-04:
#   CZWEB000010  "need.captcha/defaultShowCaptch,<zh: IP over query limit>"
#                - the app would show a captcha; every search from this IP gets
#                  this instead of fares.
#   CZWEB000003  "search.invalid/ExecutionIpInterceptor <zh: illegal request IP>"
#                - the escalation when queries continue against the captcha gate;
#                  it then covers /api/shop/calendar too.
# Returns "" when the dict is not a refusal envelope. The message is kept
# ASCII-only: desc carries Chinese text, and a non-ASCII emit faults the
# overseer transport.
proc cz::refusal {data} {
    if {![dict exists $data ex]} { return "" }
    set ex [dict get $data ex]
    switch -- $ex {
        CZWEB000010 {
            return "rate-limited by csair.com ($ex): this IP is over the search quota and the site is demanding a captcha instead of returning fares; leave the site alone and retry much later"
        }
        CZWEB000003 {
            return "rate-limited by csair.com ($ex): the site now flags this IP's requests as illegal, its escalation after continued queries; leave the site alone and retry much later"
        }
    }
    set desc ""
    catch {set desc [dict get $data desc]}
    regsub -all {[^\x20-\x7e]} $desc ? desc
    return "search refused by csair.com ($ex): $desc"
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

# One itinerary row as its text block. $qdate is the day-offset baseline for
# "(+N)" markers; "" uses the slice's own departure date (multi-leg rows,
# where no single queried date covers every slice).
proc cz::row_text {n row column qdate} {
    set slice [cz::dget $row slice]
    set base $qdate
    if {$base eq ""} { set base [lindex [cz::dget $slice departure] 0] }
    set segs [cz::dget $slice segment]
    set dep [cz::timestr [cz::dget $slice departure] $base]
    set arr [cz::timestr [cz::dget $slice arrival] $base]
    set dur [cz::duration [cz::dget $slice duration]]
    set stops [expr {[llength $segs] - 1}]
    switch -- $stops {
        0 { set stopstr "nonstop" }
        1 { set stopstr "1 stop" }
        default { set stopstr "$stops stops" }
    }
    set out "\n\n$n) [cz::dget $slice origin] $dep → [cz::dget $slice destination] $arr   $dur, $stopstr"
    foreach seg $segs {
        append out "\n   [cz::seg_line $seg $base]"
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
    return $out
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
        append out [cz::row_text $n $row $column $date]
    }
    return $out
}

# Return / multi-city text render. $mode is "return" or "multi-city"; $legs is
# a list of {dep arr date} triples as queried. Rows render exactly as one-way
# rows do, day offsets against each slice's own departure date.
proc cz::render_multi_text {ita mode legs adults children infants} {
    set grid [cz::dget $ita sliceGrid]
    set rows [cz::dget $grid row]
    set column [cz::dget $grid column]

    set legstrs {}
    foreach leg $legs {
        lassign $leg d a dt
        lappend legstrs "$d → $a $dt"
    }
    set journey [join $legstrs ", "]
    set head "China Southern $journey, $mode, adults $adults children $children infants $infants (totals cover the whole party)"
    if {![llength $rows]} {
        return "$head\n\nNo itineraries for $journey."
    }

    set out $head
    set n 0
    foreach row $rows {
        incr n
        append out [cz::row_text $n $row $column ""]
    }
    return $out
}

proc cz::json_money {m} {
    return [json::write object \
        amount [cz::dget $m amount 0] \
        currency [json::write string [cz::dget $m currency]]]
}

# One itinerary row as its JSON object (shared by every trip mode).
proc cz::row_json {row column} {
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
    return [json::write object \
        origin [json::write string [cz::dget $slice origin]] \
        destination [json::write string [cz::dget $slice destination]] \
        departure [json::write string [join [cz::dget $slice departure] " "]] \
        arrival [json::write string [join [cz::dget $slice arrival] " "]] \
        durationMinutes [cz::dget $slice duration 0] \
        stops [expr {[llength [cz::dget $slice segment]] - 1}] \
        segments [json::write array {*}$segjson] \
        cabins [json::write object {*}$cabjson]]
}

proc cz::render_json {ita origin dest date adults children infants} {
    set grid [cz::dget $ita sliceGrid]
    set column [cz::dget $grid column]
    set itins {}
    foreach row [cz::dget $grid row] {
        lappend itins [cz::row_json $row $column]
    }
    return [json::write object \
        origin [json::write string $origin] \
        destination [json::write string $dest] \
        date [json::write string $date] \
        passengers [json::write object adults $adults children $children infants $infants] \
        itineraries [json::write array {*}$itins]]
}

# Return / multi-city JSON render: a legs array as queried instead of the
# one-way origin/destination/date echo.
proc cz::render_multi_json {ita mode legs adults children infants} {
    set grid [cz::dget $ita sliceGrid]
    set column [cz::dget $grid column]
    set itins {}
    foreach row [cz::dget $grid row] {
        lappend itins [cz::row_json $row $column]
    }
    set legjson {}
    foreach leg $legs {
        lassign $leg d a dt
        lappend legjson [json::write object \
            origin [json::write string $d] \
            destination [json::write string $a] \
            date [json::write string $dt]]
    }
    return [json::write object \
        mode [json::write string $mode] \
        legs [json::write array {*}$legjson] \
        passengers [json::write object adults $adults children $children infants $infants] \
        itineraries [json::write array {*}$itins]]
}

proc serialiser_run {skillArgs} {
    set positionals {}
    set legspecs {}
    set retdate ""
    set adults 1
    set children 0
    set infants 0
    set currency ""
    set asJson 0
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --adults   { incr i; set adults [lindex $skillArgs $i] }
            --children { incr i; set children [lindex $skillArgs $i] }
            --infants  { incr i; set infants [lindex $skillArgs $i] }
            --currency { incr i; set currency [string toupper [lindex $skillArgs $i]] }
            --return   { incr i; set retdate [lindex $skillArgs $i] }
            --leg      { incr i; lappend legspecs [lindex $skillArgs $i] }
            --json     { set asJson 1 }
            default    {
                if {[string match -* $a]} {
                    emit "unknown option $a\n[cz::usage]"
                    return
                }
                lappend positionals $a
            }
        }
    }

    # Trip shape: positional <origin> <dest> <date> is one-way (m=0), --return
    # adds the back leg (m=1); --leg DEP-ARR-YYYY-MM-DD triples (2..5) make a
    # multi-city journey (m=2) and replace the positional route.
    set legs {}
    if {[llength $legspecs]} {
        if {[llength $positionals] || $retdate ne ""} {
            emit "bad arguments: --leg replaces the positional route and excludes --return\n[cz::usage]"
            return
        }
        if {[llength $legspecs] < 2 || [llength $legspecs] > 5} {
            emit "bad route: multi-city takes 2 to 5 --leg segments, got [llength $legspecs]"
            return
        }
        foreach spec $legspecs {
            if {![regexp {^([A-Za-z]{3})-([A-Za-z]{3})-(\d{4}-\d{2}-\d{2})$} $spec -> d a dt]} {
                emit "bad leg: expected DEP-ARR-YYYY-MM-DD, got $spec\n[cz::usage]"
                return
            }
            lappend legs [list [string toupper $d] [string toupper $a] $dt]
        }
        set mode 2
    } else {
        if {[llength $positionals] != 3} {
            emit [cz::usage]
            return
        }
        lassign $positionals origin dest date
        set origin [string toupper $origin]
        set dest [string toupper $dest]
        if {![regexp {^[A-Z]{3}$} $origin] || ![regexp {^[A-Z]{3}$} $dest]} {
            emit "bad route: origin and destination must be 3-letter IATA codes\n[cz::usage]"
            return
        }
        set legs [list [list $origin $dest $date]]
        set mode 0
        if {$retdate ne ""} {
            set mode 1
            lappend legs [list $dest $origin $retdate]
        }
    }
    foreach leg $legs {
        lassign $leg d a dt
        if {$d eq $a} {
            emit "bad route: origin and destination are both $d"
            return
        }
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
    # The booking app's own window; a date outside it is rejected client-side,
    # so refuse it here without touching the site.
    set now [clock seconds]
    set minDate [clock format [clock add $now 2 days] -format %Y-%m-%d]
    set maxDate [clock format [clock add $now 1 year] -format %Y-%m-%d]
    foreach leg $legs {
        lassign $leg d a dt
        if {![regexp {^\d{4}-\d{2}-\d{2}$} $dt] \
                || [catch {clock scan $dt -format %Y-%m-%d -gmt 1}]} {
            emit "bad date: expected YYYY-MM-DD, got $dt"
            return
        }
        if {[string compare $dt $minDate] < 0 || [string compare $dt $maxDate] > 0} {
            emit "date out of window: $dt is outside the bookable range $minDate .. $maxDate (today+2 days to today+1 year)"
            return
        }
    }

    set tsegs {}
    foreach leg $legs {
        lassign $leg d a dt
        lappend tsegs "$d-$a-[string map {- ""} $dt]"
    }
    set url "$cz::BASE?m=$mode&t=[join $tsegs ","]&p=$adults$children$infants"
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

    if {[catch {json::json2dict $body} data]} {
        emit "unexpected fare payload: /api/shop/search returned [string length $body] bytes that do not parse as the known ita shape"
        return
    }
    set refusal [cz::refusal $data]
    if {$refusal ne ""} {
        emit $refusal
        return
    }
    if {[catch {dict get $data ita} ita]} {
        emit "unexpected fare payload: /api/shop/search returned [string length $body] bytes that do not parse as the known ita shape"
        return
    }

    if {$mode == 0} {
        if {$asJson} {
            emit [cz::render_json $ita $origin $dest $date $adults $children $infants]
        } else {
            emit [cz::render_text $ita $origin $dest $date $adults $children $infants]
        }
    } else {
        # The booking app prices a multi-leg journey one leg at a time: this
        # response covers the first leg alone, which its own requestId spells
        # out (base64 of "sliceGrid:B2C_SEARCH_<DEP>-<ARR>_<date>_..."). The
        # totals on those rows are therefore not a whole-journey fare, and
        # printing them beside the queried legs would read as one. Reaching
        # the rest means selecting a leg and capturing what the app asks next.
        set modestr [expr {$mode == 1 ? "return" : "multi-city"}]
        set legstrs {}
        foreach leg $legs {
            lassign $leg d a dt
            lappend legstrs "$d-$a $dt"
        }
        emit "$modestr search reaches only the first leg: csair.com prices a multi-leg journey by selecting one leg at a time, and a single search returns [join $legstrs {, }] as first-leg options with no whole-journey total. Price each leg as its own one-way search, remembering that separate one-ways are not what the airline charges for a through-fare."
    }
}
