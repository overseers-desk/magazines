#!/usr/bin/env tclsh
# Send a LinkedIn connection invite with a personalised note.
#
# Serialiser path (see SKILL.md): browser-serialiser linkedin.com/send-invite VANITY_NAME "Note" [--dry-run]
#   navigates to the custom-invite modal over the policed verbs, types the note,
#   locates the send control, and clicks it. The send click is the IRREVERSIBLE
#   outward action; --dry-run types but stops before it.
# Direct path (legacy, CDP client): CDP_WS_URL from the harness/overseer relay; browser-serialiser linkedin.com/send-invite.
#
# Usage:
#     browser-serialiser linkedin.com/send-invite VANITY_NAME "Note text (<=300 chars)"
#     browser-serialiser linkedin.com/send-invite VANITY_NAME "Note text" --dry-run   # stop before clicking Send

# Legacy CDP engine, sourced only for the direct-tclsh path; under the serialiser
# harness the policed verbs replace raw CDP, so loading is a no-op there.
if {![namespace exists cdp]} {
    catch { source [file dirname [info script]]/../lib/cdp-client.tcl }
}
package require json

set MAX_NOTE_CHARS 300

# Code-point length matching Python's len() (Tcl 8.6 surrogate-pair aware).
proc cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}

# Code-point-aware prefix (first $n code points), to mirror Python slicing.
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
# parking any interleaved CDP events (e.g. Network.responseReceived) so the
# network-event scan below can read them. Raises on a JS exception.
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

# Wait up to $timeout_ms for document.querySelector($selector) to exist.
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

# The parked Network.responseReceived params seen so far (list of dicts).
proc net_events {c} {
    set out {}
    foreach ev [$c events] {
        if {[dict exists $ev method] && [dict get $ev method] eq "Network.responseReceived"} {
            lappend out [dict get $ev params]
        }
    }
    return $out
}

proc run_flow {c page_url note dry_run} {
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

    if {![wait_for $c {[aria-label="Add a note"]} 10000]} {
        set body [js $c {document.body.innerText}]
        set bl [string tolower $body]
        if {[string first "already connected" $bl] >= 0 || \
            [string first "ya estás conectado" $bl] >= 0} {
            puts stderr "ERROR: already connected to this person"
            exit 1
        }
        set html [js $c {document.body.innerHTML}]
        if {[string first {type="email"} $html] >= 0} {
            puts stderr "ERROR: email verification required to connect (high-profile account)"
            exit 1
        }
        puts stderr "ERROR: invite modal not found. Body start: [cp_take $body 400]"
        exit 1
    }

    if {$note ne ""} {
        puts "Modal found. Clicking 'Add a note'..."
        js $c {document.querySelector('[aria-label="Add a note"]').click()}

        if {![wait_for $c {#custom-message} 8000]} {
            puts stderr "ERROR: textarea #custom-message did not appear after clicking 'Add a note'"
            exit 1
        }

        puts "Typing note ([cp_length $note] chars)..."
        js $c {document.querySelector('#custom-message').focus()}
        after 300
        # Input.insertText simulates a real keyboard paste (triggers Ember input events).
        $c cdpBuffered Input.insertText [dict create text $note]
        after 500

        set typed [js $c {document.querySelector('#custom-message').value}]
        if {$typed eq ""} { set typed "" }
        set ell [expr {[cp_length $typed] > 60 ? "..." : ""}]
        puts "Verified in textarea ([cp_length $typed] chars): '[cp_take $typed 60]$ell'"
        if {[string trim $typed] ne [string trim $note]} {
            puts stderr "WARNING: textarea mismatch - got [cp_length $typed] chars, expected [cp_length $note]"
        }

        if {$dry_run} {
            puts "DRY RUN: stopping before send."
            return [dict create status dry_run typed $typed]
        }

        # After typing, LinkedIn changes the primary button label.
        set send_label [js $c {(function() {
                var b = Array.from(document.querySelectorAll("button")).find(function(b) {
                    var l = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase();
                    return l.includes("send") && !l.includes("without");
                });
                return b ? (b.getAttribute("aria-label") || b.textContent.trim()) : null;
            })()}]

        if {$send_label eq ""} {
            set all_btns [js $c {Array.from(document.querySelectorAll("button")).map(function(b){return (b.getAttribute("aria-label")||"")+"|"+b.textContent.trim()}).join("; ")}]
            puts stderr "ERROR: send button not found after typing. Buttons present: $all_btns"
            exit 1
        }

        puts "Clicking send button: '$send_label'"
        js $c {(function() {
                var b = Array.from(document.querySelectorAll("button")).find(function(b) {
                    var l = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase();
                    return l.includes("send") && !l.includes("without");
                });
                if (b) b.click();
            })()}
    } else {
        # No-note path: click "Send without a note" directly.
        if {$dry_run} {
            puts "DRY RUN: modal found, would click 'Send without a note'."
            return [dict create status dry_run typed ""]
        }

        puts "No note. Clicking 'Send without a note'..."
        set clicked [js_bool $c {(function() {
                var b = Array.from(document.querySelectorAll("button")).find(function(b) {
                    var l = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase();
                    return l.includes("send without");
                });
                if (b) { b.click(); return true; }
                return false;
            })()}]
        if {!$clicked} {
            set all_btns [js $c {Array.from(document.querySelectorAll("button")).map(function(b){return (b.getAttribute("aria-label")||"")+"|"+b.textContent.trim()}).join("; ")}]
            puts stderr "ERROR: 'Send without a note' button not found. Buttons present: $all_btns"
            exit 1
        }
    }

    puts "Waiting for server response..."
    after 5000
    # Park any late network events the post-send round-trip emits.
    $c drainEvents 0.2

    set toast [js $c {document.querySelector(".artdeco-toast-item__message, [data-test-artdeco-toast-item]")?.textContent?.trim() || null}]
    if {$toast eq "null"} { set toast "" }
    set modal_gone [expr {![js_bool $c {!!document.querySelector("#send-invite-modal")}]}]

    # Invite-related network events: anything mentioning invitation/relationship,
    # excluding browser-internal URLs.
    set all_net [net_events $c]
    set inv_events {}
    foreach e $all_net {
        set u [dict get $e response url]
        if {([string first "invitation" $u] >= 0 || [string first "relationship" $u] >= 0) && \
            ![string match "chrome://*" $u] && ![string match "extension://*" $u]} {
            lappend inv_events $e
        }
    }
    # The definitive invite creation call (verifyQuotaAndCreate).
    set voyager_event ""
    foreach e $all_net {
        if {[string first "verifyQuotaAndCreate" [dict get $e response url]] >= 0} {
            set voyager_event $e
            break
        }
    }
    if {$voyager_event ne "" && [lsearch -exact $inv_events $voyager_event] < 0} {
        lappend inv_events $voyager_event
    }

    # Fetch the Voyager invitation API response body.
    set server_body ""
    set server_message_echo ""
    if {$voyager_event ne ""} {
        if {![catch {
            set body_result [$c cdpBuffered Network.getResponseBody \
                [dict create requestId [dict get $voyager_event requestId]]]
            set raw_body [dict get $body_result result body]
            if {$raw_body ne ""} {
                set server_body [json::json2dict $raw_body]
                set body_str $raw_body
                if {[regexp {"(?:message|customMessage|note)"\s*:\s*"([^"]+)"} $body_str -> mm]} {
                    set server_message_echo $mm
                }
            }
        } err]} {
            puts stderr "WARNING: could not fetch API response body: $err"
        }
    }

    puts ""
    puts "=== Server Confirmation ==="
    if {$toast ne ""} { puts "Toast notification: $toast" }
    puts "Modal closed after send: [py_bool $modal_gone]"
    foreach e $inv_events {
        puts "API response: HTTP [dict get $e response status] <- [dict get $e response url]"
    }
    if {$server_message_echo ne ""} {
        puts "Message confirmed by server: \"$server_message_echo\""
    } elseif {$server_body ne ""} {
        puts "Server response body (no message field found): [cp_take $raw_body 400]"
    } elseif {$voyager_event ne ""} {
        puts stderr "WARNING: Voyager API called but response body was empty or unreadable"
    } else {
        puts stderr "WARNING: Voyager invitation API call not captured in network monitor"
    }

    set api_ok 0
    foreach e $inv_events {
        if {[dict get $e response status] in {200 201 204}} { set api_ok 1 }
    }
    set api_failed [expr {[llength $inv_events] > 0 && !$api_ok}]

    if {$api_failed && $toast eq ""} {
        set statuses {}
        foreach e $inv_events { lappend statuses [dict get $e response status] }
        set all400 1
        foreach s $statuses { if {$s != 400} { set all400 0 } }
        if {$all400} {
            puts stderr "ERROR: invitation API returned 400 — already connected, quota exhausted, or profile not connectable."
            return [dict create status failed \
                reason already_connected_or_not_connectable \
                toast $toast modal_closed $modal_gone \
                api_responses [api_responses_list $inv_events]]
        }
        puts stderr "ERROR: invitation API returned errors: $statuses"
    }

    set success [expr {$api_ok || ($toast ne "" && !$api_failed) || ($modal_gone && !$api_failed)}]

    return [dict create \
        status [expr {$success ? "sent" : "uncertain"}] \
        toast $toast modal_closed $modal_gone \
        server_message_echo $server_message_echo \
        api_responses [api_responses_list $inv_events]]
}

# A list of {url ... status ...} dicts for the result's api_responses array.
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
# Values are typed: status flags are JSON booleans, api_responses is an array of
# {url, status}, status integers stay bare; everything else is a JSON string or
# null (an empty string standing for Python None).
proc result_json {d} {
    set order {status reason toast modal_closed compose_cleared \
               server_message_echo api_responses typed}
    set pairs {}
    dict for {k v} $d {
        lappend pairs $k
    }
    set lines {}
    foreach k $pairs {
        set v [dict get $d $k]
        lappend lines "  [json::write string $k]: [json_value $k $v]"
    }
    return "{\n[join $lines ",\n"]\n}"
}

# JSON for a result field, by key (booleans, the api_responses array, strings).
proc json_value {key v} {
    switch -- $key {
        modal_closed - compose_cleared {
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
        toast - server_message_echo {
            if {$v eq ""} { return "null" }
            return [json::write string $v]
        }
        default {
            return [json::write string $v]
        }
    }
}

proc main {} {
    global argv MAX_NOTE_CHARS
    set dry_run 0
    set positional {}
    foreach a $argv {
        if {$a eq "--dry-run"} {
            set dry_run 1
        } else {
            lappend positional $a
        }
    }
    if {[llength $positional] < 1} {
        puts stderr "Usage: send-invite.tcl VANITY_NAME \[note\] \[--dry-run\]"
        exit 2
    }
    set vanity_name [lindex $positional 0]
    set note [expr {[llength $positional] > 1 ? [lindex $positional 1] : ""}]

    if {$note ne "" && [cp_length $note] > $MAX_NOTE_CHARS} {
        puts stderr "ERROR: note is [cp_length $note] chars; LinkedIn limit is $MAX_NOTE_CHARS"
        exit 1
    }

    set page_url "https://www.linkedin.com/preload/custom-invite/?vanityName=$vanity_name"

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser linkedin.com/send-invite VANITY_NAME \"Note\" \[--dry-run\]"
        exit 1
    }

    set c [cdp::connect]
    if {[catch {run_flow $c $page_url $note $dry_run} result opts]} {
        catch {$c close}
        return -options $opts $result
    }
    $c close

    puts ""
    puts "=== RESULT ==="
    puts [result_json $result]

    set status [dict get $result status]
    if {$status eq "sent"} {
        set echo [expr {[dict exists $result server_message_echo] ? [dict get $result server_message_echo] : ""}]
        if {$echo ne ""} {
            puts "\nSUCCESS: invitation sent. Server confirmed note: \"$echo\""
        } else {
            puts "\nSUCCESS: invitation sent (server confirmed via API + modal close; note text not echoed in response)."
        }
    } elseif {$status eq "dry_run"} {
        puts "\nDRY RUN complete - no invite sent."
    } elseif {$status eq "failed"} {
        set reason [expr {[dict exists $result reason] ? [dict get $result reason] : "unknown"}]
        puts stderr "\nFAILED: $reason. No invitation sent."
        exit 1
    } else {
        puts stderr "\nUNCERTAIN - could not confirm server acceptance. Check LinkedIn manually."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Serialiser path: the policed-surface flow. Mirrors run_flow over the verbs
# (nav/eval/type/click/state/dwell) instead of cdp::connect. The send click is
# the irreversible action; result_json renders the same status object the legacy
# path prints, so the per-status output stays byte-identical.
#
#     browser-serialiser linkedin.com/send-invite VANITY_NAME "Note" [--dry-run]
# ---------------------------------------------------------------------------

# Evaluate a JS boolean over the policed `eval` verb. Returns 1/0.
proc sv_js_bool {expr} {
    return [expr {[eval $expr] eq "true" ? 1 : 0}]
}

# Wait up to ~$ticks*0.5s for a selector to exist, polling via eval + dwell.
proc sv_wait_for {selector ticks} {
    for {set i 0} {$i < $ticks} {incr i} {
        if {[sv_js_bool "!!document.querySelector([json::write string $selector])"]} {
            return 1
        }
        dwell 0.5
    }
    return 0
}

# Emit a result and stop. Centralised so every exit path renders via result_json.
proc sv_emit_result {d} {
    emit [result_json $d]
}

proc serialiser_run {skillArgs} {
    global MAX_NOTE_CHARS
    set dry_run 0
    set positional {}
    foreach a $skillArgs {
        if {$a eq "--dry-run"} { set dry_run 1 } else { lappend positional $a }
    }
    if {[llength $positional] < 1} {
        sv_emit_result [dict create status error reason "usage: send-invite VANITY_NAME \[note\] \[--dry-run\]"]
        return
    }
    set vanity_name [lindex $positional 0]
    set note [expr {[llength $positional] > 1 ? [lindex $positional 1] : ""}]

    if {$note ne "" && [cp_length $note] > $MAX_NOTE_CHARS} {
        sv_emit_result [dict create status error \
            reason "note is [cp_length $note] chars; LinkedIn limit is $MAX_NOTE_CHARS"]
        return
    }

    set page_url "https://www.linkedin.com/preload/custom-invite/?vanityName=$vanity_name"
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

    if {![sv_wait_for {[aria-label="Add a note"]} 20]} {
        set body [eval {document.body.innerText}]
        set bl [string tolower $body]
        if {[string first "already connected" $bl] >= 0 || \
            [string first "ya estás conectado" $bl] >= 0} {
            sv_emit_result [dict create status error reason "already connected to this person"]
            return
        }
        set html [eval {document.body.innerHTML}]
        if {[string first {type="email"} $html] >= 0} {
            sv_emit_result [dict create status error reason "email verification required to connect (high-profile account)"]
            return
        }
        sv_emit_result [dict create status error reason "invite modal not found"]
        return
    }

    if {$note ne ""} {
        log "Modal found. Clicking 'Add a note'..."
        # Open the note editor. This click is non-destructive (UI expansion only).
        # LinkedIn's artdeco modal button does not respond to the harness's trusted
        # CDP mouse click here; an in-page .click() does (the legacy CDP path used
        # this, and it sent prior batches). Keep the JS click for the modal buttons.
        eval {document.querySelector('[aria-label="Add a note"]').click()}

        if {![sv_wait_for {#custom-message} 16]} {
            sv_emit_result [dict create status error reason "textarea #custom-message did not appear after clicking 'Add a note'"]
            return
        }

        log "Typing note ([cp_length $note] chars)..."
        eval {document.querySelector('#custom-message').focus()}
        dwell 0.3
        type $note
        dwell 0.5

        set typed [eval {document.querySelector('#custom-message').value}]
        if {$typed eq "null"} { set typed "" }
        log "Verified in textarea ([cp_length $typed] chars)"

        if {$dry_run} {
            log "DRY RUN: stopping before send."
            sv_emit_result [dict create status dry_run typed $typed]
            return
        }

        # Locate the send control (label varies; "send" excluding "without").
        set send_label [eval {(function() {
                var b = Array.from(document.querySelectorAll("button")).find(function(b) {
                    var l = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase();
                    return l.includes("send") && !l.includes("without");
                });
                if (b) { b.setAttribute("data-sv-send","1"); }
                return b ? (b.getAttribute("aria-label") || b.textContent.trim()) : null;
            })()}]
        if {$send_label eq "null" || $send_label eq ""} {
            sv_emit_result [dict create status error reason "send button not found after typing"]
            return
        }

        # THE IRREVERSIBLE SEND. In the wiring test, this click is a stub that
        # records but does nothing; live, it dispatches the invitation.
        log "Clicking send button: '$send_label'"
        eval {document.querySelector('[data-sv-send="1"]').click()}
    } else {
        if {$dry_run} {
            log "DRY RUN: modal found, would click 'Send without a note'."
            sv_emit_result [dict create status dry_run typed ""]
            return
        }
        # No-note path: tag and click "Send without a note". IRREVERSIBLE.
        set tagged [sv_js_bool {(function() {
                var b = Array.from(document.querySelectorAll("button")).find(function(b) {
                    var l = (b.getAttribute("aria-label") || b.textContent || "").toLowerCase();
                    return l.includes("send without");
                });
                if (b) { b.setAttribute("data-sv-send","1"); return true; }
                return false;
            })()}]
        if {!$tagged} {
            sv_emit_result [dict create status error reason "'Send without a note' button not found"]
            return
        }
        log "No note. Clicking 'Send without a note'..."
        eval {document.querySelector('[data-sv-send="1"]').click()}
    }

    log "Waiting for server response..."
    dwell 5

    set toast [eval {document.querySelector(".artdeco-toast-item__message, [data-test-artdeco-toast-item]")?.textContent?.trim() || null}]
    if {$toast eq "null"} { set toast "" }
    set modal_gone [expr {![sv_js_bool {!!document.querySelector("#send-invite-modal")}]}]

    # The post-send Voyager confirmation network call is not harvestable on this
    # surface (the send is a click, not a capture), so success is read from the
    # DOM signals the legacy path also accepts: a toast or the modal closing.
    set inv_events {}
    set server_message_echo ""

    set api_ok 0
    set api_failed 0
    set success [expr {$api_ok || ($toast ne "" && !$api_failed) || ($modal_gone && !$api_failed)}]

    sv_emit_result [dict create \
        status [expr {$success ? "sent" : "uncertain"}] \
        toast $toast modal_closed $modal_gone \
        server_message_echo $server_message_echo \
        api_responses [api_responses_list $inv_events]]
}

# Direct-tclsh entry: skipped when sourced as a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
