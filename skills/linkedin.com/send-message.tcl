#!/usr/bin/env tclsh
# Send a LinkedIn direct message to a connection via CDP.
#
# The wrapper (not-google-chrome --cdp) owns the browser lifecycle and exports
# CDP_WS_URL; this script is a pure CDP client and exits if run without it.
#
# Usage:
#     not-google-chrome --cdp -- tclsh send-message.tcl VANITY_NAME "Message text"
#     not-google-chrome --cdp -- tclsh send-message.tcl VANITY_NAME "Message text" --dry-run   # stop before clicking Send

source [file dirname [info script]]/../lib/cdp-client.tcl
package require json

# Code-point length matching Python's len() (Tcl 8.6 surrogate-pair aware).
proc cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}

# Code-point-aware prefix (first $n code points), mirroring Python slicing.
proc cp_take {s n} {
    if {$n <= 0} { return "" }
    if {![regexp {[\uD800-\uDBFF]} $s]} {
        return [string range $s 0 [expr {$n-1}]]
    }
    set out ""; set cp 0; set len [string length $s]
    for {set i 0} {$i < $len} {incr i} {
        set ch [string index $s $i]
        scan $ch %c code
        if {$code >= 0xD800 && $code <= 0xDBFF && $i+1 < $len} {
            append ch [string index $s [expr {$i+1}]]; incr i
        }
        append out $ch; incr cp
        if {$cp >= $n} break
    }
    return $out
}

# Runtime.evaluate like the Python js(): awaitPromise=false, returnByValue=true,
# parking interleaved CDP events (Network.responseReceived) for the scan below.
proc js {c expr} {
    set r [$c cdpBuffered Runtime.evaluate [dict create \
        expression $expr awaitPromise false returnByValue true]]
    set result [dict get $r result]
    if {[dict exists $result exceptionDetails]} {
        set exc [dict get $result exceptionDetails]
        if {[dict exists $exc text]} { error [dict get $exc text] }
        error "JS error"
    }
    if {[dict exists $result result value]} {
        return [dict get $result result value]
    }
    return ""
}

proc js_bool {c expr} {
    return [expr {[js $c $expr] eq "true" ? 1 : 0}]
}

proc wait_for {c selector timeout_ms} {
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < $timeout_ms} {
        if {[js_bool $c "!!document.querySelector([json::write string $selector])"]} {
            return 1
        }
        after 500
    }
    return 0
}

proc net_events {c} {
    set out {}
    foreach ev [$c events] {
        if {[dict exists $ev method] && [dict get $ev method] eq "Network.responseReceived"} {
            lappend out [dict get $ev params]
        }
    }
    return $out
}

proc run_flow {c page_url text dry_run} {
    $c cdp Network.enable
    $c cdp Page.enable

    puts "Navigating to: $page_url"
    $c cdp Page.navigate [dict create url $page_url]
    after 4000

    set title [js $c {document.title}]
    if {$title eq ""} { set title "" }
    puts "Page title: $title"
    set tl [string tolower $title]
    foreach bad {"sign in" "log in" "iniciar"} {
        if {[string first $bad $tl] >= 0} {
            puts stderr "ERROR: got sign-in page - session is not active"
            exit 1
        }
    }

    # LinkedIn sometimes shows a language-selection interstitial on first CDP load.
    set body_check [js $c {document.body.innerText}]
    if {[string first "選擇語言" $body_check] >= 0 || \
        [string first "Choose language" $body_check] >= 0} {
        puts "Language interstitial detected. Clicking English..."
        set clicked [js_bool $c {(function() {
                var all = Array.from(document.querySelectorAll("a, button"));
                var en = all.find(function(el) {
                    var t = el.textContent.trim();
                    return t === "English (English)" || t === "English";
                });
                if (en) { en.click(); return true; }
                return false;
            })()}]
        if {!$clicked} {
            puts stderr "ERROR: language interstitial appeared but English option not found"
            exit 1
        }
        puts "Clicked English. Waiting for profile to load..."
        after 6000
        set title [js $c {document.title}]
        if {$title eq ""} { set title "" }
        puts "Page title after language selection: $title"
        set tl [string tolower $title]
        foreach bad {"sign in" "log in" "iniciar"} {
            if {[string first $bad $tl] >= 0} {
                puts stderr "ERROR: redirected to sign-in after language selection"
                exit 1
            }
        }
    }

    # Scrape the "Send message" link's href from <main> (its URN-bearing compose
    # URL), then navigate directly to it.
    set msg_href ""
    for {set i 0} {$i < 20} {incr i} {
        set msg_href [js $c {(function() {
                var els = Array.from(document.querySelectorAll('main a'));
                var msg = els.find(function(el) {
                    var t = (el.textContent || '').trim().toLowerCase();
                    return t === 'enviar mensaje' || t === 'send message' || t === 'message';
                });
                return msg ? msg.getAttribute('href') : null;
            })()}]
        if {$msg_href ne "" && $msg_href ne "null"} break
        after 500
    }
    if {$msg_href eq "null"} { set msg_href "" }

    if {$msg_href eq ""} {
        set body [js $c {document.body.innerText}]
        puts stderr "ERROR: 'Send message' link not found on profile (not a 1st-degree connection?). Body: [cp_take $body 300]"
        exit 1
    }

    if {[string match "http*" $msg_href]} {
        set compose_url $msg_href
    } else {
        set compose_url "https://www.linkedin.com$msg_href"
    }
    puts "Navigating to compose URL..."
    $c cdp Page.navigate [dict create url $compose_url]
    after 5000

    # Wait for the compose area (a contenteditable div).
    set compose_selectors {
        {div[role="textbox"][contenteditable="true"]}
        {[contenteditable="true"][data-placeholder]}
        {[contenteditable="true"]}
    }
    set compose_sel ""
    foreach sel $compose_selectors {
        if {[wait_for $c $sel 8000]} { set compose_sel $sel; break }
    }
    if {$compose_sel eq ""} {
        set body [js $c {document.body.innerText}]
        puts stderr "ERROR: compose area did not appear after clicking Message. Body: [cp_take $body 300]"
        exit 1
    }

    puts "Compose area found ($compose_sel). Focusing..."
    js $c "document.querySelector([json::write string $compose_sel]).focus()"
    after 300

    puts "Typing message ([cp_length $text] chars)..."
    $c cdpBuffered Input.insertText [dict create text $text]
    after 500

    set typed [js $c "document.querySelector([json::write string $compose_sel]).textContent"]
    if {$typed eq ""} { set typed "" }
    set ell [expr {[cp_length $typed] > 60 ? "..." : ""}]
    puts "Verified in compose area ([cp_length $typed] chars): '[cp_take $typed 60]$ell'"

    if {$dry_run} {
        puts "DRY RUN: stopping before send."
        return [dict create status dry_run typed $typed]
    }

    set send_label [js $c {(function() {
            var btns = Array.from(document.querySelectorAll("button"));
            var b = btns.find(function(b) {
                var label = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase().trim();
                return label === "send" || label === "enviar";
            });
            return b ? (b.getAttribute("aria-label") || b.textContent.trim()) : null;
        })()}]

    if {$send_label eq ""} {
        set all_btns [js $c {Array.from(document.querySelectorAll("button")).map(function(b){return (b.getAttribute("aria-label")||"")+"|"+b.textContent.trim()}).join("; ")}]
        puts stderr "ERROR: Send button not found. Buttons present: $all_btns"
        exit 1
    }

    puts "Clicking send button: '$send_label'"
    js $c {(function() {
            var btns = Array.from(document.querySelectorAll("button"));
            var b = btns.find(function(b) {
                var label = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase().trim();
                return label === "send" || label === "enviar";
            });
            if (b) b.click();
        })()}

    puts "Waiting for server response..."
    after 4000
    $c drainEvents 0.2

    set toast [js $c {document.querySelector(".artdeco-toast-item__message, [data-test-artdeco-toast-item]")?.textContent?.trim() || null}]
    if {$toast eq "null"} { set toast "" }

    set remaining [js $c "document.querySelector([json::write string $compose_sel])?.textContent?.trim()"]
    set compose_cleared [expr {[string trim $remaining] eq ""}]

    set msg_events {}
    foreach e [net_events $c] {
        set u [dict get $e response url]
        if {[string first "messaging" $u] >= 0 && \
            ![string match "chrome://*" $u] && ![string match "extension://*" $u]} {
            lappend msg_events $e
        }
    }

    puts ""
    puts "=== Server Confirmation ==="
    if {$toast ne ""} { puts "Toast notification: $toast" }
    puts "Compose area cleared after send: [py_bool $compose_cleared]"
    foreach e $msg_events {
        puts "API response: HTTP [dict get $e response status] <- [dict get $e response url]"
    }

    set api_ok 0
    foreach e $msg_events {
        if {[dict get $e response status] in {200 201 204}} { set api_ok 1 }
    }
    set api_failed [expr {[llength $msg_events] > 0 && !$api_ok}]

    if {$api_failed && $toast eq ""} {
        set statuses {}
        foreach e $msg_events { lappend statuses [dict get $e response status] }
        puts stderr "ERROR: messaging API returned errors: $statuses"
    }

    set success [expr {$api_ok || ($compose_cleared && !$api_failed) || ($toast ne "" && !$api_failed)}]

    return [dict create \
        status [expr {$success ? "sent" : "uncertain"}] \
        toast $toast compose_cleared $compose_cleared \
        api_responses [api_responses_list $msg_events]]
}

proc api_responses_list {events} {
    set out {}
    foreach e $events {
        lappend out [dict create url [dict get $e response url] \
                         status [dict get $e response status]]
    }
    return $out
}

proc py_bool {v} { return [expr {$v ? "True" : "False"}] }

# Render the result dict as Python's json.dumps(indent=2, ensure_ascii=False).
proc result_json {d} {
    set lines {}
    dict for {k v} $d {
        lappend lines "  [json::write string $k]: [json_value $k $v]"
    }
    return "{\n[join $lines ",\n"]\n}"
}

proc json_value {key v} {
    switch -- $key {
        compose_cleared {
            return [expr {$v ? "true" : "false"}]
        }
        api_responses {
            if {![llength $v]} { return "\[\]" }
            set items {}
            foreach r $v {
                lappend items "{\n      \"url\": [json::write string [dict get $r url]],\n      \"status\": [dict get $r status]\n    }"
            }
            return "\[\n    [join $items ",\n    "]\n  \]"
        }
        toast {
            if {$v eq ""} { return "null" }
            return [json::write string $v]
        }
        default {
            return [json::write string $v]
        }
    }
}

proc main {} {
    global argv
    set dry_run 0
    set positional {}
    foreach a $argv {
        if {$a eq "--dry-run"} {
            set dry_run 1
        } else {
            lappend positional $a
        }
    }
    if {[llength $positional] < 2} {
        puts stderr "Usage: send-message.tcl VANITY_NAME \"Message text\" \[--dry-run\]"
        exit 2
    }
    set vanity_name [lindex $positional 0]
    set text [lindex $positional 1]

    set page_url "https://www.linkedin.com/in/$vanity_name/"

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh send-message.tcl VANITY_NAME \"Message\" \[--dry-run\]"
        exit 1
    }

    set c [cdp::connect]
    if {[catch {run_flow $c $page_url $text $dry_run} result opts]} {
        catch {$c close}
        return -options $opts $result
    }
    $c close

    puts ""
    puts "=== RESULT ==="
    puts [result_json $result]

    set status [dict get $result status]
    if {$status eq "sent"} {
        puts "\nSUCCESS: message sent."
    } elseif {$status eq "dry_run"} {
        puts "\nDRY RUN complete - no message sent."
    } else {
        puts stderr "\nUNCERTAIN - could not confirm delivery. Check LinkedIn manually."
        exit 1
    }
}

fconfigure stdout -encoding utf-8
fconfigure stderr -encoding utf-8
main
