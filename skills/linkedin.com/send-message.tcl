#!/usr/bin/env tclsh
# Send a LinkedIn direct message to a connection.
#
# Serialiser path (see SKILL.md): browser-serialiser linkedin.com/send-message VANITY_NAME "Message" [--dry-run]
#   navigates to the profile, opens the compose URL over the policed verbs, types
#   the message, locates the Send control, and clicks it. The send click is the
#   IRREVERSIBLE outward action; --dry-run types but stops before it.
# Direct path (legacy, CDP client): CDP_WS_URL from the harness/overseer relay; browser-serialiser linkedin.com/send-message.
#
# Usage:
#     browser-serialiser linkedin.com/send-message VANITY_NAME "Message text"
#     browser-serialiser linkedin.com/send-message VANITY_NAME "Message text" --dry-run   # stop before clicking Send

# Legacy CDP engine, sourced only for the direct-tclsh path; under the serialiser
# harness the policed verbs replace raw CDP, so loading is a no-op there.
if {![namespace exists cdp]} {
    catch { source [file dirname [info script]]/../lib/cdp-client.tcl }
}
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
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser linkedin.com/send-message VANITY_NAME \"Message\" \[--dry-run\]"
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

# ---------------------------------------------------------------------------
# Serialiser path: the policed-surface flow. Mirrors run_flow over the verbs
# (nav/eval/type/click/state/dwell) instead of cdp::connect. The send click is
# the irreversible action; result_json renders the same status object the legacy
# path prints, so the per-status output stays byte-identical.
#
#     browser-serialiser linkedin.com/send-message VANITY_NAME "Message" [--dry-run]
# ---------------------------------------------------------------------------

proc sv_js_bool {expr} {
    return [expr {[eval $expr] eq "true" ? 1 : 0}]
}

proc sv_wait_for {selector ticks} {
    for {set i 0} {$i < $ticks} {incr i} {
        if {[sv_js_bool "!!document.querySelector([json::write string $selector])"]} {
            return 1
        }
        dwell 0.5
    }
    return 0
}

proc sv_emit_result {d} {
    emit [result_json $d]
}

proc serialiser_run {skillArgs} {
    set dry_run 0
    set positional {}
    foreach a $skillArgs {
        if {$a eq "--dry-run"} { set dry_run 1 } else { lappend positional $a }
    }
    if {[llength $positional] < 2} {
        sv_emit_result [dict create status error reason "usage: send-message VANITY_NAME \"Message text\" \[--dry-run\]"]
        return
    }
    set vanity_name [lindex $positional 0]
    set text [lindex $positional 1]

    set page_url "https://www.linkedin.com/in/$vanity_name/"
    log "Navigating to: $page_url"
    nav $page_url --wait 4
    if {[dict get [state] terminal] ne ""} {
        sv_emit_result [dict create status error reason "session is not active ([dict get [state] terminal])"]
        return
    }

    set title [eval {document.title}]
    set tl [string tolower $title]
    foreach bad {"sign in" "log in" "iniciar"} {
        if {[string first $bad $tl] >= 0} {
            sv_emit_result [dict create status error reason "got sign-in page - session is not active"]
            return
        }
    }

    # Language interstitial (first CDP load sometimes shows it).
    set body_check [eval {document.body.innerText}]
    if {[string first "選擇語言" $body_check] >= 0 || \
        [string first "Choose language" $body_check] >= 0} {
        log "Language interstitial detected. Clicking English..."
        set tagged [sv_js_bool {(function() {
                var all = Array.from(document.querySelectorAll("a, button"));
                var en = all.find(function(el) {
                    var t = el.textContent.trim();
                    return t === "English (English)" || t === "English";
                });
                if (en) { en.setAttribute("data-sv-lang","1"); return true; }
                return false;
            })()}]
        if {!$tagged} {
            sv_emit_result [dict create status error reason "language interstitial appeared but English option not found"]
            return
        }
        click {[data-sv-lang="1"]}
        dwell 6
    }

    # Scrape the "Send message" link's URN-bearing href, then navigate to it.
    set msg_href ""
    for {set i 0} {$i < 20} {incr i} {
        set msg_href [eval {(function() {
                var els = Array.from(document.querySelectorAll('main a'));
                var msg = els.find(function(el) {
                    var t = (el.textContent || '').trim().toLowerCase();
                    return t === 'enviar mensaje' || t === 'send message' || t === 'message';
                });
                return msg ? msg.getAttribute('href') : null;
            })()}]
        if {$msg_href ne "" && $msg_href ne "null"} break
        dwell 0.5
    }
    if {$msg_href eq "null"} { set msg_href "" }

    if {$msg_href eq ""} {
        sv_emit_result [dict create status error reason "'Send message' link not found on profile (not a 1st-degree connection?)"]
        return
    }

    if {[string match "http*" $msg_href]} {
        set compose_url $msg_href
    } else {
        set compose_url "https://www.linkedin.com$msg_href"
    }
    log "Navigating to compose URL..."
    nav $compose_url --wait 5

    # Wait for the compose area (a contenteditable div).
    set compose_selectors {
        {div[role="textbox"][contenteditable="true"]}
        {[contenteditable="true"][data-placeholder]}
        {[contenteditable="true"]}
    }
    set compose_sel ""
    foreach sel $compose_selectors {
        if {[sv_wait_for $sel 16]} { set compose_sel $sel; break }
    }
    if {$compose_sel eq ""} {
        sv_emit_result [dict create status error reason "compose area did not appear"]
        return
    }

    log "Compose area found ($compose_sel). Focusing..."
    eval "document.querySelector([json::write string $compose_sel]).focus()"
    dwell 0.3

    log "Typing message ([cp_length $text] chars)..."
    type $text
    dwell 0.5

    set typed [eval "document.querySelector([json::write string $compose_sel]).textContent"]
    if {$typed eq "null"} { set typed "" }
    log "Verified in compose area ([cp_length $typed] chars)"

    if {$dry_run} {
        log "DRY RUN: stopping before send."
        sv_emit_result [dict create status dry_run typed $typed]
        return
    }

    # Locate the Send control.
    set send_label [eval {(function() {
            var btns = Array.from(document.querySelectorAll("button"));
            // The messaging Send control is an icon button with a stable class and
            // often an empty aria-label/textContent, so match the class first.
            var b = btns.find(function(b) { return /msg-form__send/.test(b.className || ""); });
            if (!b) b = btns.find(function(b) {
                var label = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase().trim();
                return label === "send" || label === "enviar";
            });
            if (b) { b.setAttribute("data-sv-send","1"); }
            return b ? (b.getAttribute("aria-label") || b.textContent.trim() || "send-btn") : null;
        })()}]
    if {$send_label eq "null" || $send_label eq ""} {
        set _btns [eval {Array.from(document.querySelectorAll("button")).map(function(b){return (b.getAttribute("aria-label")||"")+"|"+(b.textContent||"").trim()+"|"+(b.className||"").substring(0,30)}).filter(function(s){return s.length>2}).slice(0,40).join(" ;; ")}]
        sv_emit_result [dict create status error reason "Send button not found" buttons $_btns]
        return
    }

    # THE IRREVERSIBLE SEND. In the wiring test, this click is a stub that records
    # but does nothing; live, it dispatches the message.
    log "Clicking send button: '$send_label'"
    eval {document.querySelector('[data-sv-send="1"]').click()}

    log "Waiting for server response..."
    dwell 4

    set toast [eval {document.querySelector(".artdeco-toast-item__message, [data-test-artdeco-toast-item]")?.textContent?.trim() || null}]
    if {$toast eq "null"} { set toast "" }

    set remaining [eval "document.querySelector([json::write string $compose_sel])?.textContent?.trim()"]
    set compose_cleared [expr {[string trim $remaining] eq "" || $remaining eq "null"}]

    # The post-send messaging network call is not harvestable on this surface (the
    # send is a click, not a capture); success reads from the DOM signals the
    # legacy path also accepts: a toast or the compose area clearing.
    set msg_events {}
    set api_ok 0
    set api_failed 0
    set success [expr {$api_ok || ($compose_cleared && !$api_failed) || ($toast ne "" && !$api_failed)}]

    sv_emit_result [dict create \
        status [expr {$success ? "sent" : "uncertain"}] \
        toast $toast compose_cleared $compose_cleared \
        api_responses [api_responses_list $msg_events]]
}

# Direct-tclsh entry: skipped when sourced as a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
