#!/usr/bin/env tclsh
# CDP helper for the Airbnb hosting dashboard.
#
# not-google-chrome --cdp owns the browser lifecycle and exports CDP_WS_URL;
# this script is a pure CDP client and exits if run without it. It navigates to
# a hosting page, intercepts the React app's internal API responses (or replays
# the reservations API from inside the page context), and prints them as JSON.
#
# Usage:
#   not-google-chrome --cdp -- tclsh airbnb-cdp.tcl list [--product STAYS|EXPERIENCES]
#   not-google-chrome --cdp -- tclsh airbnb-cdp.tcl reservations [--filter past|upcoming|all]

package require json

source [file dirname [info script]]/../lib/cdp-client.tcl

# Pretty-print a compact JSON document with 2-space indentation, the shape
# Python's json.dumps(indent=2, ensure_ascii=False) emits. Values pass through
# verbatim (no re-typing), so numbers, booleans and unicode survive unchanged.
proc json_pretty {text {indent 0}} {
    set out ""
    set n [string length $text]
    set i 0
    set pad [string repeat "  " $indent]
    set instr 0
    set depth $indent
    while {$i < $n} {
        set c [string index $text $i]
        if {$instr} {
            append out $c
            if {$c eq "\\"} {
                append out [string index $text [expr {$i+1}]]
                incr i 2
                continue
            }
            if {$c eq "\""} { set instr 0 }
            incr i
            continue
        }
        switch -- $c {
            "\"" { set instr 1; append out $c; incr i }
            "\{" - "\[" {
                # Look ahead: an empty container stays on one line.
                set j [expr {$i+1}]
                while {$j < $n && [string is space [string index $text $j]]} { incr j }
                set close [expr {$c eq "\{" ? "\}" : "\]"}]
                if {[string index $text $j] eq $close} {
                    append out $c$close
                    set i [expr {$j+1}]
                } else {
                    incr depth
                    append out $c "\n" [string repeat "  " $depth]
                    incr i
                }
            }
            "\}" - "\]" {
                incr depth -1
                append out "\n" [string repeat "  " $depth] $c
                incr i
            }
            "," {
                append out ",\n" [string repeat "  " $depth]
                incr i
            }
            ":" { append out ": "; incr i }
            " " - "\t" - "\n" - "\r" { incr i }
            default { append out $c; incr i }
        }
    }
    return $out
}

# Quote a Tcl string as a JSON string literal (for error/raw wrappers built here
# rather than received from the page).
proc json_str {s} {
    set out "\""
    foreach ch [split $s ""] {
        scan $ch %c code
        switch -- $ch {
            "\"" { append out {\"} }
            "\\" { append out {\\} }
            "\n" { append out {\n} }
            "\r" { append out {\r} }
            "\t" { append out {\t} }
            default {
                if {$code < 0x20} {
                    append out [format {\u%04x} $code]
                } else {
                    append out $ch
                }
            }
        }
    }
    append out "\""
    return $out
}

# Runtime.evaluate of $expr, returning the JS value as a JSON document string.
# Mirrors the Python eval_js: the JS is expected to return a JSON string, so the
# value is taken verbatim when it parses as JSON, else wrapped as {"raw":...};
# a JS exception becomes {"error":...}, a missing value {"error":"No value..."}.
proc eval_js {cdp expr} {
    set resp [$cdp cdp Runtime.evaluate [dict create \
        expression $expr awaitPromise true returnByValue true]]
    set result [dict get $resp result]
    if {[dict exists $result exceptionDetails]} {
        set exc [dict get $result exceptionDetails]
        set text [expr {[dict exists $exc text] ? [dict get $exc text] : "JS exception"}]
        return [list error "\{[json_str error]:[json_str $text]\}"]
    }
    if {![dict exists $result result value]} {
        return [list error "\{[json_str error]:[json_str {No value returned from JS}]\}"]
    }
    set val [dict get $result result value]
    if {[catch {json::json2dict $val}]} {
        # Not JSON: wrap the raw string, matching Python's {"raw": val}.
        return [list raw "\{[json_str raw]:[json_str $val]\}"]
    }
    return [list json $val]
}

# True if the current page is an authenticated Airbnb hosting page.
proc check_logged_in {cdp} {
    lassign [eval_js $cdp {window.location.href}] kind doc
    set url [extract_scalar $kind $doc]
    if {[string match "*/login*" $url] || [string match "*/signup*" $url]} {
        return 0
    }
    lassign [eval_js $cdp {document.title}] tkind tdoc
    set title [extract_scalar $tkind $tdoc]
    if {[string match "*Log in*" $title] || [string match "*Sign up*" $title]} {
        return 0
    }
    return 1
}

# Pull a scalar string out of an eval_js return. For window.location.href and
# document.title the JS returns a bare string, so eval_js parses it as a JSON
# string value (kind=json) or wraps it raw; either way recover the text.
proc extract_scalar {kind doc} {
    if {$kind eq "json"} {
        if {![catch {json::json2dict $doc} v]} { return $v }
        return $doc
    }
    # raw/error wrapper: pull the inner value back out.
    if {![catch {json::json2dict $doc} d]} {
        if {[dict exists $d raw]} { return [dict get $d raw] }
        if {[dict exists $d error]} { return [dict get $d error] }
    }
    return $doc
}

# list [--product STAYS|EXPERIENCES]: navigate the quick-replies settings page,
# intercept the page's own quick-replies API response, return it.
proc cmd_list {cdp product} {
    set url "https://www.airbnb.com/hosting/messages/settings/quick-replies?product=$product"

    $cdp cdpBuffered Network.enable
    $cdp cdpBuffered Page.navigate [dict create url $url]

    # Collect network events while the page loads.
    $cdp drainEvents 10

    if {![check_logged_in $cdp]} {
        return [list raw "\{[json_str error]:[json_str {Not logged in to Airbnb. Log in via your browser first, then close it before running this script.}]\}"]
    }

    # The hosting app loads quick replies on mount via the persisted query
    # FetchQuickRepliesViaduct. Match the operation rather than a fixed domain
    # (the session may be on a localised host). Capture each matching response.
    set pending {}
    foreach evt [$cdp events] {
        if {[dict exists $evt method] && [dict get $evt method] eq "Network.responseReceived"} {
            set resp [dict get $evt params response]
            set resp_url [dict get $resp url]
            if {[string match "*quickreplies*" [string tolower $resp_url]] \
                    && [string match "*/api/*" $resp_url]} {
                set req_id [dict get $evt params requestId]
                dict set pending $req_id [list url $resp_url status [dict get $resp status]]
            }
        }
    }

    # Fetch response bodies while they are still in the CDP network cache.
    set captured {}
    dict for {req_id meta} $pending {
        set body_resp [$cdp cdp Network.getResponseBody [dict create requestId $req_id]]
        set entry [dict create \
            url [json_str [dict get $meta url]] \
            status [dict get $meta status]]
        if {[dict exists $body_resp result body]} {
            set raw_body [dict get $body_resp result body]
            if {[catch {json::json2dict $raw_body}]} {
                dict set entry raw [json_str $raw_body]
            } else {
                dict set entry data $raw_body
            }
        }
        lappend captured $entry
    }

    if {[llength $captured] > 0} {
        # Build the JSON array verbatim from the per-entry documents.
        set items {}
        foreach entry $captured {
            set pairs {}
            dict for {k v} $entry { lappend pairs "[json_str $k]:$v" }
            lappend items "\{[join $pairs ,]\}"
        }
        return [list json "\[[join $items ,]\]"]
    }

    return [list raw "\{[json_str error]:[json_str {FetchQuickRepliesViaduct response not seen on the quick-replies page; the host app may have renamed the operation. Re-run, or capture the current request from the Network panel and update the match above.}]\}"]
}

# reservations [--filter past|upcoming|all]: navigate the reservations page to
# establish the session, then replay /api/v2/reservations from the page context.
proc cmd_reservations {cdp filter} {
    $cdp cdpBuffered Network.enable
    $cdp cdpBuffered Page.navigate [dict create url "https://www.airbnb.com/hosting/reservations"]
    $cdp drainEvents 12

    if {![check_logged_in $cdp]} {
        return [list raw "\{[json_str error]:[json_str {Not logged in to Airbnb. Log in via your browser first, then close it before running this script.}]\}"]
    }

    set today [clock format [clock seconds] -format %Y-%m-%d]
    # collection_strategy controls past vs upcoming.
    set strategies [dict create \
        past     [list strategy for_reservations_list_history extra "" order desc] \
        upcoming [list strategy for_reservations_list extra "&date_min=$today&status=accepted%2Crequest" order asc]]

    if {$filter eq "all"} {
        set filters {past upcoming}
    } else {
        set filters [list $filter]
    }

    set out {}
    foreach f $filters {
        set cfg [dict get $strategies $f]
        set strategy [dict get $cfg strategy]
        set extra [dict get $cfg extra]
        set order [dict get $cfg order]
        set js [reservations_js $strategy $extra $order]
        lassign [eval_js $cdp $js] kind doc
        dict set out $f $doc
    }

    if {$filter eq "all"} {
        # Object keyed by past and upcoming, each its own JSON document.
        set pairs {}
        foreach f {past upcoming} {
            if {[dict exists $out $f]} {
                lappend pairs "[json_str $f]:[dict get $out $f]"
            }
        }
        return [list json "\{[join $pairs ,]\}"]
    }
    return [list json [dict get $out $filter]]
}

# The in-page fetch loop, identical in shape to the Python predecessor.
proc reservations_js {strategy extra order} {
    return [string cat \
        "(async () => {" \
        "  const headers = {" \
        "    'Accept':'application/json'," \
        "    'Content-Type':'application/json'," \
        "    'X-Airbnb-API-Key':'d306zoyjsyarp7ifhu67rjxn52tv0t20'," \
        "    'X-CSRF-Without-Token':'1'," \
        "    'X-Airbnb-Supports-Airlock-V2':'true'," \
        "  };" \
        "  const strategy = '$strategy';" \
        "  const extra = '$extra';" \
        "  const order = '$order';" \
        "  const all = \[\];" \
        "  let total = null;" \
        "  for (let offset = 0; offset < 5000; offset += 40) {" \
        "    const url = `/api/v2/reservations?locale=en&currency=USD&_format=for_remy" \
        "&_limit=40&_offset=\${offset}&collection_strategy=\${strategy}" \
        "&sort_field=start_date&sort_order=\${order}\${extra}`;" \
        "    const r = await fetch(url, {credentials:'include', headers});" \
        "    if (r.status !== 200) {" \
        "      return JSON.stringify({error:'fetch failed', status:r.status, offset, body:(await r.text()).slice(0,400)});" \
        "    }" \
        "    const d = await r.json();" \
        "    const recs = d.reservations || \[\];" \
        "    all.push(...recs);" \
        "    const m = d.metadata || {};" \
        "    total = m.total_count;" \
        "    if (recs.length < 40) break;" \
        "    if (m.page_index !== undefined && m.page_count !== undefined && m.page_index + 1 >= m.page_count) break;" \
        "  }" \
        "  return JSON.stringify({total_count: total, returned: all.length, reservations: all});" \
        "})()"]
}

proc usage {} {
    puts stderr "Airbnb hosting dashboard CDP helper"
    puts stderr "Usage:"
    puts stderr "  ... -- tclsh airbnb-cdp.tcl list \[--product STAYS|EXPERIENCES\]"
    puts stderr "  ... -- tclsh airbnb-cdp.tcl reservations \[--filter past|upcoming|all\]"
}

proc main {argv} {
    if {[llength $argv] == 0} {
        usage
        exit 1
    }
    set command [lindex $argv 0]
    set rest [lrange $argv 1 end]

    set product STAYS
    set filter past
    switch -- $command {
        list {
            for {set i 0} {$i < [llength $rest]} {incr i} {
                set a [lindex $rest $i]
                if {$a eq "--product"} {
                    incr i
                    set product [lindex $rest $i]
                    if {$product ni {STAYS EXPERIENCES}} {
                        puts stderr "--product must be STAYS or EXPERIENCES"
                        exit 2
                    }
                } else {
                    puts stderr "unknown argument: $a"
                    exit 2
                }
            }
        }
        reservations {
            for {set i 0} {$i < [llength $rest]} {incr i} {
                set a [lindex $rest $i]
                if {$a eq "--filter"} {
                    incr i
                    set filter [lindex $rest $i]
                    if {$filter ni {past upcoming all}} {
                        puts stderr "--filter must be past, upcoming or all"
                        exit 2
                    }
                } else {
                    puts stderr "unknown argument: $a"
                    exit 2
                }
            }
        }
        default {
            usage
            exit 1
        }
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh airbnb-cdp.tcl ..."
        exit 1
    }

    fconfigure stdout -encoding utf-8
    set cdp [cdp::connect]
    try {
        switch -- $command {
            list         { set res [cmd_list $cdp $product] }
            reservations { set res [cmd_reservations $cdp $filter] }
        }
        lassign $res kind doc
        puts [json_pretty $doc]
    } finally {
        $cdp close
    }
}

main $argv
