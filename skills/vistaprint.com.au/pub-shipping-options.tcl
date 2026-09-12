#!/bin/sh
# the next line restarts under the newest tclsh available (the sh trampoline from
# the tclsh man page: sh runs the exec, Tcl reads it as part of this comment) \
exec "$(command -v tclsh9.0 || command -v tclsh)" "$0" "$@"
# Vistaprint AU delivery methods: what each costs and how many business days it
# takes to each area band, from the site's own published shipping page.
#
#   pub-shipping-options.tcl
#
# The bands are by state and metro/regional/remote, which is as fine as the site
# publishes. A date for one postcode and one cart is computed at checkout, not
# here. Browserless: one anonymous GET. Emits the canonical envelope on stdout.

package require json::write

set ::SkillDir [file dirname [file normalize [info script]]]
set ::Root [file dirname [file dirname $::SkillDir]]
if {![llength [info commands envelope_ok]]} {
    source [file join $::Root lib envelope.tcl]
}

set ::SHIPPING "https://www.vistaprint.com.au/shipping"
set ::UA "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

proc fetch {url} {
    if {[catch {exec curl -sS -g --compressed --max-time 30 \
            -H "User-Agent: $::UA" \
            -H "Accept-Language: en-AU,en;q=0.9" $url} body]} {
        error "fetch failed for $url: $body"
    }
    return $body
}

proc clean {frag} {
    regsub -all {<[^>]+>} $frag "" frag
    set frag [string map [list "&amp;" "&" "&lt;" "<" "&gt;" ">" "&quot;" "\"" \
                               "&#x26;" "&" "&#39;" "'" "&nbsp;" " "] $frag]
    regsub -all {\s+} $frag " " frag
    return [string trim $frag]
}

# Cells of one row, in order. Non-greedy throughout: a Tcl ARE takes its
# greediness from the first quantifier, so one greedy quantifier would make the
# whole pattern greedy and swallow the table.
proc cells {row tag} {
    set out {}
    foreach {full c} [regexp -all -inline "(?is)<$tag\[^>\]*?>(.*?)</$tag>" $row] {
        lappend out [clean $c]
    }
    return $out
}

# One delivery table: the header's columns after the first are the estimates,
# and each body row contributes one area per column under its estimate.
proc timeframes {table} {
    set heads [cells [lindex [regexp -inline {(?is)<thead.*?</thead>} $table] 0] th]
    if {[llength $heads] < 2} { return "" }
    set estimates [lrange $heads 1 end]
    set areas [lrepeat [llength $estimates] {}]
    foreach {full row} [regexp -all -inline {(?is)<tr[^>]*?>(.*?)</tr>} $table] {
        set c [lrange [cells $row td] 1 end]
        for {set i 0} {$i < [llength $estimates]} {incr i} {
            set v [lindex $c $i]
            if {$v ne ""} { lset areas $i [concat [lindex $areas $i] [list $v]] }
        }
    }
    set out {}
    foreach e $estimates a $areas {
        if {[llength $a] == 0} continue
        lappend out [json::write object \
            estimate [json::write string $e] \
            areas [json::write array {*}[lmap x $a {json::write string $x}]]]
    }
    return [json::write array {*}$out]
}

# Each delivery method is an <h2 id="..."> section; the ones that are methods
# carry a cost line, which is what separates them from the page's prose
# sections (split orders, product exclusions).
proc methods {html} {
    set out {}
    regsub -all {(?i)<h2 id="} $html "\x00<h2 id=\"" marked
    foreach chunk [lrange [split $marked \x00] 1 end] {
        if {![regexp {(?i)^<h2 id="([^"]+)"} $chunk -> id]} continue
        if {![regexp {(?is)<h2[^>]*?>(.*?)</h2>} $chunk -> heading]} continue
        if {![regexp {(?is)<strong>Cost:</strong>(.*?)</p>} $chunk -> cost]} continue
        set pairs [list id [json::write string $id] \
                        name [json::write string [clean $heading]] \
                        cost [json::write string [clean $cost]]]
        if {[regexp {(?is)<table.*?</table>} $chunk table]} {
            set tf [timeframes $table]
            if {$tf ne ""} { lappend pairs timeframes $tf }
        }
        lappend out [json::write object {*}$pairs]
    }
    return $out
}

proc run {} {
    set html [fetch $::SHIPPING]
    set ms [methods $html]
    if {[llength $ms] == 0} {
        error "no delivery methods found on $::SHIPPING (the page's layout changed)"
    }
    set free ""
    if {[regexp {(?is)<h2 id="delivery-offer".*?<ul>(.*?)</ul>} $html -> offer]} {
        set free [clean $offer]
    }
    set pairs [list page [json::write string $::SHIPPING] \
                    currency [json::write string AUD] \
                    banding [json::write string "by state and metro/regional/remote; a date for one postcode and cart is computed at checkout"] \
                    methods [json::write array {*}$ms]]
    if {$free ne ""} { lappend pairs delivery_offer [json::write string $free] }
    return [json::write object {*}$pairs]
}

fconfigure stdout -encoding utf-8
if {[catch {run} out]} {
    puts [envelope_fault $out]
    exit 65
}
puts [envelope_ok [dict create result $out]]
