#!/usr/bin/env tclsh
# Airbnb hosting dashboard skill, on the policed serialiser surface.
#
# The harness sources this file into a per-run safe interp and calls
# serialiser_run with the skill args; the flow drives the policed verbs
# (nav/capture/harvest/eval/api/state/emit) instead of opening a raw CDP socket.
# Two capabilities:
#   list          quick-replies settings page: the React app loads its own
#                 quick-replies API response on mount, harvested via capture.
#   reservations  the reservations page establishes the session (the covering
#                 view), then the page-context fetch loop replays
#                 /api/v2/reservations (a declared, view-before-fetch endpoint).
#
# The JSON shaping below (json_pretty / json_str) is byte-identical to the prior
# raw-CDP version, so output bytes match for the same intercepted data.
#
# Usage (by reference, through the serialiser):
#   browser-serialiser airbnb.com/airbnb-cdp list [--product STAYS|EXPERIENCES]
#   browser-serialiser airbnb.com/airbnb-cdp reservations [--filter past|upcoming|all]

package require json

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

# list [--product STAYS|EXPERIENCES]: navigate the quick-replies settings page
# via capture, so the React app issues its own quick-replies API call and the
# harness buffers the response; harvest the matching bodies and wrap them in the
# same per-entry JSON the prior version built.
#
# Returns a {kind doc} pair (kind is informational, like the prior eval_js
# wrappers); the caller pretty-prints doc.
proc cmd_list {product} {
    set url "https://www.airbnb.com/hosting/messages/settings/quick-replies?product=$product"

    # capture navigates (paced), lets the page load, and buffers the network
    # responses. The hosting app loads quick replies on mount via the persisted
    # query FetchQuickRepliesViaduct; match the operation on the response URL
    # rather than a fixed domain (the session may be on a localised host).
    set captured [capture $url --seconds 10 --match "*"]

    set st [state]
    if {[dict get $st terminal] ne ""} {
        return [list raw "\{[json_str error]:[json_str {Not logged in to Airbnb. Log in via your browser first, then close it before running this script.}]\}"]
    }

    # Filter to the quick-replies API responses and shape each entry: url,
    # status, and the parsed data verbatim (or raw-wrapped when not JSON).
    set entries {}
    foreach triple $captured {
        lassign $triple resp_url resp_status raw_body
        if {![string match "*quickreplies*" [string tolower $resp_url]]} continue
        if {![string match "*/api/*" $resp_url]} continue
        set entry [dict create \
            url [json_str $resp_url] \
            status $resp_status]
        if {$raw_body ne ""} {
            if {[catch {json::json2dict $raw_body}]} {
                dict set entry raw [json_str $raw_body]
            } else {
                dict set entry data $raw_body
            }
        }
        lappend entries $entry
    }

    if {[llength $entries] > 0} {
        # Build the JSON array verbatim from the per-entry documents.
        set items {}
        foreach entry $entries {
            set pairs {}
            dict for {k v} $entry { lappend pairs "[json_str $k]:$v" }
            lappend items "\{[join $pairs ,]\}"
        }
        return [list json "\[[join $items ,]\]"]
    }

    return [list raw "\{[json_str error]:[json_str {FetchQuickRepliesViaduct response not seen on the quick-replies page; the host app may have renamed the operation. Re-run, or capture the current request from the Network panel and update the match above.}]\}"]
}

# reservations [--filter past|upcoming|all]: navigate the reservations page (the
# covering view for the declared /api/v2/reservations endpoint), then replay the
# page-context fetch loop. The loop's per-page fetch is a declared private
# endpoint (view-before-fetch satisfied by the preceding nav); the page
# aggregates the pages and returns one document per filter, byte-identical to the
# prior version.
proc cmd_reservations {filter} {
    # Covering view for the view-before-fetch declaration of /api/v2/reservations.
    nav "https://www.airbnb.com/hosting/reservations" --wait 12

    set st [state]
    if {[dict get $st terminal] ne ""} {
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
        # The page-context loop replays the declared /api/v2/reservations
        # endpoint; eval runs it in the page, where it is policed on the wire.
        set doc [eval $js]
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

# ---------------------------------------------------------------------------
# Serialiser entry: the policed-surface path. The harness sources this file into
# a safe interp and calls serialiser_run with the skill args. The command
# shaping reuses cmd_list / cmd_reservations above, so the emitted bytes match
# the prior raw-CDP version for the same intercepted data.
# ---------------------------------------------------------------------------

proc serialiser_run {skillArgs} {
    if {[llength $skillArgs] == 0} {
        emit [json_pretty "\{[json_str error]:[json_str {Usage: airbnb.com/airbnb-cdp <list [--product STAYS|EXPERIENCES] | reservations [--filter past|upcoming|all]>}]\}"]
        return
    }
    set command [lindex $skillArgs 0]
    set rest [lrange $skillArgs 1 end]

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
                        emit [json_pretty "\{[json_str error]:[json_str {--product must be STAYS or EXPERIENCES}]\}"]
                        return
                    }
                } else {
                    emit [json_pretty "\{[json_str error]:[json_str "unknown argument: $a"]\}"]
                    return
                }
            }
            lassign [cmd_list $product] kind doc
        }
        reservations {
            for {set i 0} {$i < [llength $rest]} {incr i} {
                set a [lindex $rest $i]
                if {$a eq "--filter"} {
                    incr i
                    set filter [lindex $rest $i]
                    if {$filter ni {past upcoming all}} {
                        emit [json_pretty "\{[json_str error]:[json_str {--filter must be past, upcoming or all}]\}"]
                        return
                    }
                } else {
                    emit [json_pretty "\{[json_str error]:[json_str "unknown argument: $a"]\}"]
                    return
                }
            }
            lassign [cmd_reservations $filter] kind doc
        }
        default {
            emit [json_pretty "\{[json_str error]:[json_str "unknown command: $command"]\}"]
            return
        }
    }

    emit [json_pretty $doc]
}
