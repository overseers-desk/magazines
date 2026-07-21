#!/usr/bin/env tclsh
# Establish a LinkedIn session via the fastrack (remember-me) flow.
#
# LinkedIn periodically expires the active session but keeps a remember-me cookie
# that allows re-login without a password. This script clicks the "Continue as
# <name>" button to mint a fresh session, which persists to the user-data-dir
# on disk for subsequent skill runs (send-invite.tcl, send-message.tcl).
#
# Serialiser path (see SKILL.md): browser-serialiser linkedin.com/login [--check]
#   navigates home over the policed verbs, detects the login form via eval/state,
#   and clicks the fastrack "continue" control. `--check` reports state only.
# Direct path (legacy, CDP client): CDP_WS_URL from the harness/overseer relay; browser-serialiser linkedin.com/login [--check].
#
# Clicking "continue" mints a session — an outward action. The serialiser path
# performs it through the policed `click` verb; `--check` stops before any click.

# Legacy CDP engine, sourced only for the direct-tclsh path; under the serialiser
# harness the policed verbs replace raw CDP, so loading is a no-op there.
if {![namespace exists cdp]} {
    catch { ::tcl::tm::path add [file normalize [file join [file dirname [info script]] .. .. lib]]; package require cdp }
}
package require json

# Run a Runtime.evaluate the way the Python js() helper did: awaitPromise=false,
# returnByValue=true. Returns the JS value (or "" / a Tcl value), raising on a
# JS exception. cdpBuffered parks any CDP events seen while awaiting the reply,
# matching the Python loop that discarded non-matching events.
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

# A JS boolean value comes back as the literal true/false; normalise to 1/0.
proc js_bool {c expr} {
    return [expr {[js $c $expr] eq "true" ? 1 : 0}]
}

# Markers that distinguish logged-in from logged-out on the LinkedIn homepage.
# Detection rests on signals that survive LinkedIn's class-name randomisation:
# the landing URL (a logged-in `/` redirects into `/feed/`), the semantic
# `#global-nav` id and a `/feed/` nav link (authed chrome only), and the page
# title. The definitive logged-out sub-states (fastrack remember-me CTA, login
# form) are checked first so a stray authed-looking link cannot mask them.
proc login_state {c} {
    if {[js_bool $c {!!document.querySelector(".fastrack-sign-in-cta")}]} {
        return "logged_out_remember_me"
    }
    if {[js_bool $c {!!document.querySelector("form[action*=\"login\"], form[action*=\"authenticate\"]")}]} {
        return "logged_out"
    }
    if {[string match "*/feed*" [js $c {document.location.href}]]} { return "logged_in" }
    if {[js_bool $c {!!document.querySelector("#global-nav, a[href^=\"/feed/\"]")}]} {
        return "logged_in"
    }
    set tl [string tolower [js $c {document.title}]]
    foreach m {"sign in" "log in" "iniciar" "sign up"} {
        if {[string first $m $tl] >= 0} { return "logged_out" }
    }
    return "unknown"
}

# A JSON string literal for embedding a Tcl value into a JS expression, the way
# Python's json.dumps(value) did inside the f-strings.
proc js_str {s} {
    return [json::write string $s]
}

# Find the continue control by visible text (classes are randomised). Returns
# the label, or "" when none is present yet.
proc find_continue {c} {
    return [js $c {(function() {
                var els = Array.from(document.querySelectorAll(
                    "button, a, [role=button]"));
                var m = els.find(function(el) {
                    var t = (el.getAttribute("aria-label") || el.textContent || "")
                        .trim().toLowerCase();
                    return t === "continuar" || t === "continue"
                        || t.indexOf("iniciar sesión") === 0
                        || t.indexOf("sign in as") === 0;
                });
                return m ? (m.getAttribute("aria-label") || m.textContent.trim()) : null;
            })()}]
}

proc run_flow {c check_only} {
    $c cdp Page.enable

    puts "Navigating to homepage..."
    $c cdp Page.navigate [dict create url "https://www.linkedin.com/"]
    after 4000
    set state [login_state $c]
    puts "Initial state: $state  (title: [py_repr [js $c {document.title}]])"

    if {$state eq "logged_in"} {
        return [dict create status already_logged_in]
    }
    if {$check_only} {
        return [dict create status $state]
    }
    if {$state ne "logged_out_remember_me"} {
        return [dict create status $state \
            note "no remember-me fastrack available; a password login is required"]
    }

    # Click the fastrack CTA on the homepage -> navigates to the JS-rendered
    # continue page.
    puts "Clicking fastrack CTA..."
    js $c {document.querySelector(".fastrack-sign-in-cta")?.click()}
    after 5000

    # Wait up to 12s for a clickable continue control (text-matched).
    set label ""
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < 12000} {
        set label [find_continue $c]
        if {$label ne ""} break
        after 500
    }

    if {$label eq ""} {
        set clickables [js $c {Array.from(document.querySelectorAll("button, a, [role=button]")).map(function(el){return (el.getAttribute("aria-label")||"")+"|"+(el.textContent||"").trim().slice(0,40)}).filter(function(s){return s.length>1}).slice(0,40).join("; ")}]
        return [dict create status continue_button_not_found \
            url [js $c {document.location.href}] \
            clickables $clickables]
    }

    puts "Clicking continue control: '[string range $label 0 59]'"
    js $c {(function() {
            var els = Array.from(document.querySelectorAll("button, a, [role=button]"));
            var m = els.find(function(el) {
                var t = (el.getAttribute("aria-label") || el.textContent || "")
                    .trim().toLowerCase();
                return t === "continuar" || t === "continue"
                    || t.indexOf("iniciar sesión") === 0
                    || t.indexOf("sign in as") === 0;
            });
            if (m) m.click();
        })()}

    puts "Waiting for login to complete..."
    after 6000

    # Re-check on the homepage to confirm a session was minted.
    $c cdp Page.navigate [dict create url "https://www.linkedin.com/"]
    after 4000
    set final [login_state $c]
    puts "Final state: $final  (title: [py_repr [js $c {document.title}]])"

    return [dict create \
        status [expr {$final eq "logged_in" ? "logged_in" : "login_failed"}] \
        final_state $final]
}

# Mirror Python's !r on a string (repr): wrap in single quotes, escaping as
# Python would for the simple title strings this prints.
proc py_repr {s} {
    if {[string first "'" $s] >= 0 && [string first "\"" $s] < 0} {
        return "\"$s\""
    }
    set esc [string map {\\ \\\\ ' \\'} $s]
    return "'$esc'"
}

# Emit the result dict as the pretty JSON object Python printed (indent=2,
# ensure_ascii=False), preserving the field insertion order.
proc result_json {d} {
    set lines {}
    dict for {k v} $d {
        lappend lines "  [json::write string $k]: [json::write string $v]"
    }
    if {![llength $lines]} { return "{}" }
    return "{\n[join $lines ",\n"]\n}"
}

proc main {} {
    global argv
    set check_only 0
    foreach a $argv {
        if {$a eq "--check"} {
            set check_only 1
        } else {
            puts stderr "login.tcl: unrecognised argument: $a"
            exit 2
        }
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser linkedin.com/login \[--check\]"
        exit 1
    }

    set c [cdp::connect]
    if {[catch {run_flow $c $check_only} result opts]} {
        catch {$c close}
        return -options $opts $result
    }
    $c close

    puts ""
    puts "=== RESULT ==="
    puts [result_json $result]

    set status [dict get $result status]
    if {$status in {already_logged_in logged_in}} {
        puts "\nSUCCESS: session active."
    } elseif {$status eq "logged_in" && $check_only} {
        puts "\nLogged in."
    } elseif {$check_only} {
        puts "\nState: $status (no action taken; --check)."
        exit 1
    } else {
        puts stderr "\nFAILED: $status. No active session."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Serialiser path: the policed-surface flow. Mirrors run_flow over the verbs
# (nav/eval/click/state/dwell) instead of cdp::connect; result_json renders the
# same status object the legacy path prints, so output stays byte-identical.
#
#     browser-serialiser linkedin.com/login [--check]
# ---------------------------------------------------------------------------

# Evaluate a JS boolean over the policed `eval` verb: the value comes back as the
# literal true/false string. Returns 1/0.
proc sv_js_bool {expr} {
    return [expr {[eval $expr] eq "true" ? 1 : 0}]
}

# The login-state markers, read over the policed surface (same selectors as the
# legacy login_state). Returns logged_in / logged_out_remember_me / logged_out /
# unknown.
proc sv_login_state {} {
    if {[sv_js_bool {!!document.querySelector(".fastrack-sign-in-cta")}]} {
        return "logged_out_remember_me"
    }
    if {[sv_js_bool {!!document.querySelector("form[action*=\"login\"], form[action*=\"authenticate\"]")}]} {
        return "logged_out"
    }
    if {[string match "*/feed*" [eval {document.location.href}]]} { return "logged_in" }
    if {[sv_js_bool {!!document.querySelector("#global-nav, a[href^=\"/feed/\"]")}]} {
        return "logged_in"
    }
    set tl [string tolower [eval {document.title}]]
    foreach m {"sign in" "log in" "iniciar" "sign up"} {
        if {[string first $m $tl] >= 0} { return "logged_out" }
    }
    return "unknown"
}

# Find the continue control by visible text over the policed surface. Returns the
# label or "" when none is present yet.
proc sv_find_continue {} {
    set r [eval {(function() {
                var els = Array.from(document.querySelectorAll(
                    "button, a, [role=button]"));
                var m = els.find(function(el) {
                    var t = (el.getAttribute("aria-label") || el.textContent || "")
                        .trim().toLowerCase();
                    return t === "continuar" || t === "continue"
                        || t.indexOf("iniciar sesión") === 0
                        || t.indexOf("sign in as") === 0;
                });
                return m ? (m.getAttribute("aria-label") || m.textContent.trim()) : null;
            })()}]
    if {$r eq "null"} { return "" }
    return $r
}

# A CSS selector matching the continue control by its (variable) text. The click
# verb selects by CSS only, so we tag the matching element with a data attribute
# in-page first, then click that tag. Returns 1 if tagged, 0 otherwise.
proc sv_tag_continue {} {
    return [sv_js_bool {(function() {
            var els = Array.from(document.querySelectorAll("button, a, [role=button]"));
            var m = els.find(function(el) {
                var t = (el.getAttribute("aria-label") || el.textContent || "")
                    .trim().toLowerCase();
                return t === "continuar" || t === "continue"
                    || t.indexOf("iniciar sesión") === 0
                    || t.indexOf("sign in as") === 0;
            });
            if (m) { m.setAttribute("data-sv-continue", "1"); return true; }
            return false;
        })()}]
}

proc serialiser_run {skillArgs} {
    set check_only 0
    foreach a $skillArgs {
        if {$a eq "--check"} { set check_only 1 }
    }

    log "Navigating to homepage..."
    nav "https://www.linkedin.com/" --wait 4
    if {[dict get [state] terminal] ne ""} {
        emit [result_json [dict create status logged_out \
            note "navigation hit a wall ([dict get [state] terminal])"]]
        return
    }
    set st [sv_login_state]

    if {$st eq "logged_in"} {
        emit [result_json [dict create status already_logged_in]]
        return
    }
    if {$check_only} {
        emit [result_json [dict create status $st \
            url [eval {document.location.href}] \
            title [eval {document.title}]]]
        return
    }
    if {$st ne "logged_out_remember_me"} {
        emit [result_json [dict create status $st \
            note "no remember-me fastrack available; a password login is required"]]
        return
    }

    # Click the fastrack CTA -> navigates to the JS-rendered continue page.
    log "Clicking fastrack CTA..."
    click ".fastrack-sign-in-cta"
    dwell 5

    # Wait for a clickable continue control (text-matched).
    set label ""
    for {set i 0} {$i < 24} {incr i} {
        set label [sv_find_continue]
        if {$label ne ""} break
        dwell 0.5
    }

    if {$label eq ""} {
        set clickables [eval {Array.from(document.querySelectorAll("button, a, [role=button]")).map(function(el){return (el.getAttribute("aria-label")||"")+"|"+(el.textContent||"").trim().slice(0,40)}).filter(function(s){return s.length>1}).slice(0,40).join("; ")}]
        emit [result_json [dict create status continue_button_not_found \
            url [eval {document.location.href}] \
            clickables $clickables]]
        return
    }

    # Tag the continue control in-page, then click it through the policed verb.
    # This click mints a session (the outward action of this skill).
    log "Clicking continue control: '[string range $label 0 59]'"
    sv_tag_continue
    click {[data-sv-continue="1"]}

    log "Waiting for login to complete..."
    dwell 6

    # Re-check on the homepage to confirm a session was minted.
    nav "https://www.linkedin.com/" --wait 4
    set final [sv_login_state]
    log "Final state: $final"

    emit [result_json [dict create \
        status [expr {$final eq "logged_in" ? "logged_in" : "login_failed"}] \
        final_state $final]]
}

# Direct-tclsh entry: skipped when sourced as a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    main
}
