#!/bin/sh
# the next line restarts under the newest tclsh available (the sh trampoline from
# the tclsh man page: sh runs the exec, Tcl reads it as part of this comment) \
exec "$(command -v tclsh9.0 || command -v tclsh)" "$0" "$@"
# Vistaprint AU flyer prices: the whole quantity-to-price ladder for one size and
# stock, read from the price service the product page's own configurator calls.
#
#   pub-flyer-prices.tcl --size A4 --sides double --thickness Premium
#
# Browserless by construction: two anonymous HTTP reads, no cookie, no token, no
# Chromium, so this action does not go through browser-serialiser and defines no
# serialiser_run. It emits the canonical envelope on stdout (COMMAND-SURFACE.md)
# and sources lib/envelope.tcl for it, guarded, as a direct-tclsh skill does.

package require json
package require json::write

set ::SkillDir [file dirname [file normalize [info script]]]
set ::Root [file dirname [file dirname $::SkillDir]]
if {![llength [info commands envelope_ok]]} {
    source [file join $::Root lib envelope.tcl]
}

# The product page, whose server-rendered HTML carries the product key, the
# version, the whole attribute surface and the merchandised quantity ladder. It
# is read rather than hardcoded so a repriced or re-versioned product does not
# turn into a stale constant here.
set ::PDP "https://www.vistaprint.com.au/marketing-materials/flyers"
set ::PRICES "https://website-pricing-service-cdn.prices.cimpress.io/v4/prices/startingAt/estimated"
set ::UA "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"

proc fetch {url} {
    # -g turns curl's URL globbing off: the price query carries selections[Key]
    # and curl would otherwise read the brackets as a range to expand.
    if {[catch {exec curl -sS -g --compressed --max-time 30 \
            -H "User-Agent: $::UA" \
            -H "Accept-Language: en-AU,en;q=0.9" $url} body]} {
        error "fetch failed for $url: $body"
    }
    return $body
}

# Percent-encode one query value. Everything outside the unreserved set goes,
# space included: the attribute values carry spaces and a "/" ("4/0 - CMYK").
proc urlenc {s} {
    set out ""
    foreach ch [split $s ""] {
        if {[string match {[-A-Za-z0-9._~]} $ch]} {
            append out $ch
        } else {
            foreach b [split [encoding convertto utf-8 $ch] ""] {
                append out [format %%%02X [scan $b %c]]
            }
        }
    }
    return $out
}

# The page mounts each React fragment with a JSON blob in its own
# <script type="application/x-ubik-event"> tag. The pricing fragment's blob is
# the product record; find it by fragmentId rather than by position. -xdev
proc pdp_product_data {html} {
    # Every quantifier here is non-greedy on purpose: a Tcl ARE takes its
    # greediness from the FIRST quantifier, so a greedy [^>]* would turn the
    # trailing (.*?) greedy and match one span across the whole page.
    foreach {full body} [regexp -all -inline \
            {(?is)<script[^>]*?type="application/x-ubik-event"[^>]*?>(.*?)</script>} $html] {
        if {[string first "fragment-pdp-pricing-shipping" $body] < 0} continue
        if {[catch {json::json2dict $body} ev]} continue
        if {![dict exists $ev fragmentId]} continue
        if {[dict get $ev fragmentId] ne "@vp/fragment-pdp-pricing-shipping"} continue
        return [dict get $ev data]
    }
    error "product record not found on the flyers page (the page's fragment layout changed)"
}

# One attribute's options as a key->display dict, in the page's own order.
proc attr_options {data name} {
    set out [dict create]
    foreach a [dict get $data attributesInfo attributes] {
        if {[dict get $a key] ne $name} continue
        foreach o [dict get $a options] {
            dict set out [dict get $o key] [dict get $o value]
        }
    }
    return $out
}

# Accept what a person would type. "A4" is already the site's key; "DL" is the
# display name for the key "DIN Large", and "Square" for "Square (148 x 148mm)".
# Match the key first, then any option whose display name starts with the word.
proc resolve_option {opts wanted what} {
    foreach {k v} $opts {
        if {[string equal -nocase $k $wanted]} { return $k }
    }
    foreach {k v} $opts {
        if {[string equal -nocase $v $wanted]} { return $k }
        if {[string match -nocase "${wanted} (*" $v]} { return $k }
        if {[string match -nocase "${wanted}(*" $v]} { return $k }
    }
    error "$what '$wanted' is not offered. The site offers: [join [dict keys $opts] {, }]"
}

# The quantity tiles, expanded from the page's merchandised ranges: each range
# runs minimum..maximum by its own increment, and merchandisibleQuantities adds
# the standalone rungs (20000) that no range reaches.
proc quantity_ladder {data} {
    set mq [dict get $data merchandisingQuantities]
    set qs {}
    if {[dict exists $mq range]} {
        foreach r [dict get $mq range] {
            set inc [dict get $r increment]
            if {$inc <= 0} continue
            for {set q [dict get $r minimum]} {$q <= [dict get $r maximum]} {incr q $inc} {
                lappend qs $q
            }
        }
    }
    if {[dict exists $mq merchandisibleQuantities]} {
        foreach q [dict get $mq merchandisibleQuantities] { lappend qs $q }
    }
    return [lsort -integer -unique $qs]
}

# Sidedness is the PrintColor attribute. The product page's own option list does
# not carry it (it is settled in the design step), but the price service prices
# it and the two values below are the ones the page's product record uses.
proc print_colour {sides} {
    switch -- [string tolower $sides] {
        single - 1 - "4/0" { return "4/0 - CMYK" }
        double - 2 - "4/4" { return "4/4 - CMYK/CMYK" }
        default { error "sides '$sides' is not single or double" }
    }
}

proc price_url {data selections quantities} {
    set q "requestor=magazines-vistaprint-flyer-prices"
    append q "&productKey=[urlenc [dict get $data productKey]]"
    append q "&productVersion=[urlenc [dict get $data productVersion]]"
    foreach {k v} $selections {
        append q "&[urlenc selections\[$k\]]=[urlenc $v]"
    }
    foreach n $quantities { append q "&quantities=$n" }
    append q "&merchantId=[urlenc [string tolower [dict get $data merchant]]]"
    append q "&market=[urlenc [dict get $data country]]"
    append q "&pricingContext="
    return "$::PRICES?$q"
}

proc json_num {v} { return [expr {double($v)}] }

# result.ladder, one row per quantity, cheapest rung first. taxed is GST
# inclusive, which is the number the site shows an Australian shopper.
proc render_ladder {priced} {
    set rows {}
    foreach q [lsort -integer [dict keys [dict get $priced estimatedPrices]]] {
        set e [dict get $priced estimatedPrices $q]
        set list_t [dict get $e totalListPrice taxed]
        set disc_t [dict get $e totalDiscountedPrice taxed]
        lappend rows [json::write object \
            quantity $q \
            total_inc_gst [json_num $disc_t] \
            total_ex_gst [json_num [dict get $e totalDiscountedPrice untaxed]] \
            list_total_inc_gst [json_num $list_t] \
            unit_inc_gst [format %.4f [expr {$disc_t / double($q)}]]]
    }
    return [json::write array {*}$rows]
}

proc render_options {data} {
    set pairs {}
    foreach a [dict get $data attributesInfo attributes] {
        set vals {}
        foreach o [dict get $a options] {
            lappend vals [json::write object \
                key [json::write string [dict get $o key]] \
                label [json::write string [dict get $o value]]]
        }
        lappend pairs [dict get $a key] [json::write array {*}$vals]
    }
    lappend pairs sides [json::write array \
        [json::write object key [json::write string "4/0 - CMYK"] label [json::write string "single sided"]] \
        [json::write object key [json::write string "4/4 - CMYK/CMYK"] label [json::write string "double sided"]]]
    return [json::write object {*}$pairs]
}

proc usage {} {
    return "Usage: pub-flyer-prices.tcl --size <A7|A6|A5|DL|A4|A3|Square>\
\[--sides single|double\] \[--stock <paper stock>\] \[--thickness <paper thickness>\]\
\[--fold <fold>\] \[--quantities 100,250,500\]"
}

proc run {argv} {
    set size ""; set sides single; set stock ""; set thickness ""; set fold ""
    set wantQty ""
    foreach {flag val} $argv {
        switch -- $flag {
            --size       { set size $val }
            --sides      { set sides $val }
            --stock      { set stock $val }
            --thickness  { set thickness $val }
            --fold       { set fold $val }
            --quantities { set wantQty [split $val ", "] }
            default      { error "unknown argument '$flag'. [usage]" }
        }
    }
    if {$size eq ""} { error "--size is required. [usage]" }

    set data [pdp_product_data [fetch $::PDP]]

    # Start from the page's own default combination, so an option the caller
    # does not name is the one the page loads with rather than one chosen here.
    set selections [dict create]
    dict for {k v} [dict get $data attributesInfo defaultCombination] { dict set selections $k $v }

    dict set selections Format [resolve_option [attr_options $data Format] $size "size"]
    if {$stock ne ""} {
        dict set selections Material [resolve_option [attr_options $data Material] $stock "paper stock"]
    }
    if {$thickness ne ""} {
        dict set selections Weight [resolve_option [attr_options $data Weight] $thickness "paper thickness"]
    }
    if {$fold ne ""} {
        dict set selections Folding [resolve_option [attr_options $data Folding] $fold "fold"]
    }
    dict set selections PrintColor [print_colour $sides]

    set quantities [expr {$wantQty eq "" ? [quantity_ladder $data] : $wantQty}]
    foreach n $quantities {
        if {![string is integer -strict $n] || $n <= 0} { error "quantity '$n' is not a number" }
    }

    set body [fetch [price_url $data $selections $quantities]]
    if {[catch {json::json2dict $body} priced]} {
        error "price service returned something that is not JSON: [string range $body 0 200]"
    }
    if {![dict exists $priced estimatedPrices]} {
        error "price service declined this combination: [string range $body 0 300]"
    }

    # The service echoes the combination it actually priced, attribute by
    # attribute. Report that rather than what was asked, since it fills in the
    # attributes the page leaves implicit (Grammage follows paper thickness).
    set firstQ [lindex [lsort -integer [dict keys [dict get $priced estimatedPrices]]] 0]
    set priced_as {}
    foreach b [dict get $priced estimatedPrices $firstQ breakdown] {
        lappend priced_as [dict get $b name] [json::write string [dict get $b value]]
    }

    set result [json::write object \
        product [json::write string [dict get $data productName]] \
        product_key [json::write string [dict get $data productKey]] \
        product_version [dict get $data productVersion] \
        page [json::write string $::PDP] \
        currency [json::write string [dict get $priced currency]] \
        priced_as [json::write object {*}$priced_as] \
        ladder [render_ladder $priced] \
        options [render_options $data]]
    return $result
}

fconfigure stdout -encoding utf-8
if {[catch {run $argv} out]} {
    puts [envelope_fault $out]
    exit 65
}
puts [envelope_ok [dict create result $out]]
