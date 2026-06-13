# cdp-client.tcl - shared Chrome DevTools Protocol client for the aesop site-skills.
#
# A skill sources this and drives a browser over plain RFC6455 + flat CDP. The
# transport URL is either a real Chromium page target
# (ws://127.0.0.1:PORT/devtools/page/...), which the serialiser harness reads off
# /json after launching its own Chromium, or the overseer relay
# (ws://127.0.0.1:PORT/cdp/<leaseId>) when the overseer brokers the browser. Both
# are plain RFC6455 with no Authorization header and both preserve the client's
# top-level integer id, so one client serves both. A direct-mode legacy script
# (e.g. instagram.com/fetch-recent-posts.tcl run with bare tclsh) reads the URL
# from the CDP_WS_URL environment variable.
#
# Framing matches the overseer's proven masked-client path (desktop/lib/wsclient.tcl,
# desktop/lib/ws.tcl): FIN=1 opcode=1 masked text frames out, id-matched responses
# in with interleaved CDP events skipped. tcllib json handles encode/decode.
#
# API:
#   set cdp [cdp::connect]              ;# reads CDP_WS_URL; or cdp::connect $url
#   $cdp cdp <method> ?paramsDict?      ;# send a command, return matched response dict
#   $cdp navigate <url>                 ;# Page.enable + Page.navigate
#   $cdp evaluate <jsExpr>             ;# Runtime.evaluate value (returnByValue, awaitPromise)
#   $cdp close
#
# Network-interception API (for skills that read the page's own API traffic
# rather than replaying it — the persisted-query hash rotates, so intercept):
#   $cdp cdpBuffered <method> ?paramsDict?  ;# like cdp, but parks any CDP events
#                                            # seen while awaiting the response
#   $cdp drainEvents <seconds>          ;# park every event seen for <seconds>
#   $cdp events                          ;# the parked events (list of dicts)
#   $cdp clearEvents                     ;# empty the event buffer

package require json
package require json::write
package require base64

namespace eval cdp {}

# Build a CDP client connected to $url, or to $env(CDP_WS_URL) when $url is empty.
proc cdp::connect {{url ""}} {
    if {$url eq ""} {
        if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
            error "CDP_WS_URL is not set; the serialiser harness or overseer supplies it"
        }
        set url $::env(CDP_WS_URL)
    }
    return [cdp::Client new $url]
}

oo::class create cdp::Client {
    variable Sock NextId EventBuffer

    constructor {url} {
        set NextId 0
        set EventBuffer {}
        my Open $url
    }

    destructor {
        my close
    }

    # Plain RFC6455 handshake over a raw loopback socket. No Authorization header.
    method Open {url} {
        if {[string match "ws://*" $url]} {
            set rest [string range $url 5 end]
        } elseif {[string match "wss://*" $url]} {
            error "wss:// is not supported; CDP is plain ws:// on loopback"
        } else {
            error "CDP_WS_URL must be a ws:// URL, got: $url"
        }
        # host:port and the request path (may be empty).
        set slash [string first / $rest]
        if {$slash < 0} {
            set hostport $rest
            set path ""
        } else {
            set hostport [string range $rest 0 [expr {$slash-1}]]
            set path [string range $rest [expr {$slash+1}] end]
        }
        set colon [string last : $hostport]
        if {$colon < 0} {
            error "CDP_WS_URL host must include a port: $hostport"
        }
        set host [string range $hostport 0 [expr {$colon-1}]]
        set port [string range $hostport [expr {$colon+1}] end]

        set Sock [socket $host $port]
        fconfigure $Sock -blocking 1 -buffering none -translation binary

        set key [my ClientKey]
        set req "GET /$path HTTP/1.1\r\n"
        append req "Host: $hostport\r\n"
        append req "Upgrade: websocket\r\n"
        append req "Connection: Upgrade\r\n"
        append req "Sec-WebSocket-Key: $key\r\n"
        append req "Sec-WebSocket-Version: 13\r\n\r\n"
        puts -nonewline $Sock $req
        flush $Sock

        set resp ""
        while {[string first "\r\n\r\n" $resp] < 0} {
            set c [my ReadN 1]
            if {$c eq ""} { error "CDP handshake: no response from $host:$port" }
            append resp $c
        }
        if {![string match "HTTP/1.1 101*" $resp]} {
            error "CDP handshake failed: [lindex [split $resp \r\n] 0]"
        }
    }

    method ClientKey {} {
        set bytes {}
        for {set i 0} {$i < 16} {incr i} { lappend bytes [expr {int(rand()*256)}] }
        return [base64::encode [binary format c16 $bytes]]
    }

    # Mask + frame a UTF-8 text payload (client->server). FIN=1 opcode=1 mask=1.
    method FrameMasked {payload} {
        set data [encoding convertto utf-8 $payload]
        set n [string length $data]
        set out [binary format c 0x81]
        if {$n < 126} {
            append out [binary format c [expr {$n | 0x80}]]
        } elseif {$n < 65536} {
            append out [binary format cS [expr {126 | 0x80}] $n]
        } else {
            append out [binary format cW [expr {127 | 0x80}] $n]
        }
        set mask [binary format c4 [list \
            [expr {int(rand()*256)}] [expr {int(rand()*256)}] \
            [expr {int(rand()*256)}] [expr {int(rand()*256)}]]]
        append out $mask
        binary scan $mask cu4 mb
        binary scan $data cu* db
        set masked {}
        set i 0
        foreach byte $db { lappend masked [expr {$byte ^ [lindex $mb [expr {$i%4}]]}]; incr i }
        append out [binary format cu* $masked]
        return $out
    }

    # Read one full frame from the socket; return its decoded UTF-8 text payload.
    # Returns "" on a close frame or EOF. Continuation/control frames other than
    # close are not expected from CDP, so opcode is not surfaced.
    method ReadFrame {} {
        set hdr [my ReadN 2]
        if {[string length $hdr] < 2} { return "" }
        binary scan $hdr cucu b0 b1
        set opcode [expr {$b0 & 0x0f}]
        set len [expr {$b1 & 0x7f}]
        if {$len == 126} {
            binary scan [my ReadN 2] Su len
        } elseif {$len == 127} {
            binary scan [my ReadN 8] Wu len
        }
        # Server->client frames are unmasked per RFC6455.
        set payload ""
        if {$len > 0} { set payload [my ReadN $len] }
        if {$opcode == 0x8} { return "" }
        return [encoding convertfrom utf-8 $payload]
    }

    # Read exactly $n bytes from the CDP socket. The same primitive serves both
    # execution modes, branching on whether the caller runs inside a Tcl
    # coroutine:
    #   - In a coroutine (the overseer hosts the harness on its single event
    #     loop): set the socket non-blocking, read what is available, and when
    #     short of N, arm `fileevent` to resume this coroutine on readable and
    #     `yield` so the event loop keeps running while we wait. No `vwait` here.
    #   - Standalone (no coroutine): a plain blocking `read $Sock $n`, byte-for-
    #     byte the behaviour before coroutines existed.
    # EOF before N bytes is an error in both modes (a closed CDP socket).
    method ReadN {n} {
        set coro [info coroutine]
        if {$coro eq ""} {
            return [read $Sock $n]
        }
        # Coroutine mode: non-blocking accumulate, yielding on starvation.
        fconfigure $Sock -blocking 0
        set buf ""
        try {
            while {[string length $buf] < $n} {
                append buf [read $Sock [expr {$n - [string length $buf]}]]
                if {[string length $buf] >= $n} { break }
                if {[eof $Sock]} { error "CDP socket closed mid-frame" }
                fileevent $Sock readable [list $coro]
                yield
                fileevent $Sock readable {}
            }
        } finally {
            fileevent $Sock readable {}
            fconfigure $Sock -blocking 1
        }
        return $buf
    }

    # Send a CDP command (auto-incrementing id) and return the matched response
    # dict, skipping interleaved events and other responses.
    method cdp {method {params ""}} {
        incr NextId
        set id $NextId
        if {$params eq ""} {
            set msg [subst {{"id":$id,"method":[json::write string $method]}}]
        } else {
            set msg [subst {{"id":$id,"method":[json::write string $method],"params":[my ToJson $params]}}]
        }
        puts -nonewline $Sock [my FrameMasked $msg]
        flush $Sock
        while 1 {
            set r [my ReadFrame]
            if {$r eq ""} { error "CDP connection closed awaiting id $id" }
            set d [json::json2dict $r]
            if {[dict exists $d id] && [dict get $d id] == $id} {
                return $d
            }
            # else a CDP event or another command's response; keep reading.
        }
    }

    # Read one frame, but give up after $ms milliseconds. Returns the decoded
    # payload, or "" on timeout/close/EOF. Used by the event-draining methods so
    # a quiet socket does not block. Toggles non-blocking around a fileevent so
    # the rest of the client keeps its simple blocking reads.
    method ReadFrameTimed {ms} {
        fconfigure $Sock -blocking 0
        set hdr [my ReadNTimed 2 $ms]
        if {[string length $hdr] < 2} {
            fconfigure $Sock -blocking 1
            return ""
        }
        binary scan $hdr cucu b0 b1
        set opcode [expr {$b0 & 0x0f}]
        set len [expr {$b1 & 0x7f}]
        if {$len == 126} {
            binary scan [my ReadNTimed 2 $ms] Su len
        } elseif {$len == 127} {
            binary scan [my ReadNTimed 8 $ms] Wu len
        }
        set payload ""
        if {$len > 0} { set payload [my ReadNTimed $len $ms] }
        fconfigure $Sock -blocking 1
        if {$opcode == 0x8} { return "" }
        return [encoding convertfrom utf-8 $payload]
    }

    # Read exactly $n bytes from a non-blocking socket, waiting up to $ms total.
    # Returns the bytes, or "" if the deadline passes before $n arrive.
    method ReadNTimed {n ms} {
        set deadline [expr {[clock milliseconds] + $ms}]
        set buf ""
        while {[string length $buf] < $n} {
            set need [expr {$n - [string length $buf]}]
            set chunk [read $Sock $need]
            append buf $chunk
            if {[string length $buf] >= $n} { break }
            if {[eof $Sock]} { return "" }
            set remain [expr {$deadline - [clock milliseconds]}]
            if {$remain <= 0} { return "" }
            set ready 0
            set tok [after $remain [list set [namespace current]::ready 1]]
            fileevent $Sock readable [list set [namespace current]::ready 2]
            vwait [namespace current]::ready
            after cancel $tok
            fileevent $Sock readable {}
            if {$ready == 1} { return "" }
        }
        return $buf
    }

    # Like cdp, but events seen while awaiting the response are parked in the
    # event buffer instead of being dropped. Pair with drainEvents/events.
    method cdpBuffered {method {params ""}} {
        incr NextId
        set id $NextId
        if {$params eq ""} {
            set msg [subst {{"id":$id,"method":[json::write string $method]}}]
        } else {
            set msg [subst {{"id":$id,"method":[json::write string $method],"params":[my ToJson $params]}}]
        }
        puts -nonewline $Sock [my FrameMasked $msg]
        flush $Sock
        while 1 {
            set r [my ReadFrame]
            if {$r eq ""} { error "CDP connection closed awaiting id $id" }
            set d [json::json2dict $r]
            if {[dict exists $d id] && [dict get $d id] == $id} {
                return $d
            }
            if {[dict exists $d method]} { lappend EventBuffer $d }
        }
    }

    # Park every CDP event the server sends over the next $seconds.
    method drainEvents {seconds} {
        set deadline [expr {[clock milliseconds] + int($seconds * 1000)}]
        while {[clock milliseconds] < $deadline} {
            set remain [expr {$deadline - [clock milliseconds]}]
            if {$remain <= 0} break
            set r [my ReadFrameTimed [expr {$remain < 300 ? $remain : 300}]]
            if {$r eq ""} continue
            set d [json::json2dict $r]
            if {[dict exists $d method]} { lappend EventBuffer $d }
        }
    }

    # The parked CDP events, in arrival order (each a dict).
    method events {} { return $EventBuffer }

    # Discard parked events.
    method clearEvents {} { set EventBuffer {} }

    # Page.enable then Page.navigate. Returns the navigate response dict.
    method navigate {url} {
        my cdp Page.enable
        return [my cdp Page.navigate [dict create url $url]]
    }

    # Runtime.evaluate of a JS expression with returnByValue + awaitPromise.
    # Returns the JS value, or raises on a JS exception.
    method evaluate {expr} {
        set resp [my cdp Runtime.evaluate [dict create \
            expression $expr awaitPromise true returnByValue true]]
        set result [dict get $resp result]
        if {[dict exists $result exceptionDetails]} {
            set exc [dict get $result exceptionDetails]
            if {[dict exists $exc text]} {
                error "JS exception: [dict get $exc text]"
            }
            error "JS exception"
        }
        if {[dict exists $result result value]} {
            return [dict get $result result value]
        }
        return ""
    }

    method close {} {
        if {[info exists Sock] && $Sock ne ""} {
            catch { puts -nonewline $Sock [binary format cc 0x88 0]; flush $Sock }
            catch { ::close $Sock }
            set Sock ""
        }
    }

    # Encode a Tcl dict as a JSON object. Values that look like a pure integer or
    # the literals true/false/null pass through bare; everything else is a JSON
    # string. CDP params are shallow (string/number/bool), which this covers.
    method ToJson {d} {
        set pairs {}
        dict for {k v} $d {
            lappend pairs "[json::write string $k]:[my JsonScalar $v]"
        }
        return "{[join $pairs ,]}"
    }

    method JsonScalar {v} {
        if {$v in {true false null}} { return $v }
        if {[string is integer -strict $v]} { return $v }
        if {[string is double -strict $v]} { return $v }
        return [json::write string $v]
    }
}
