#!/usr/bin/env tclsh
# Establish a LinkedIn session via the fastrack (remember-me) flow using CDP.
#
# LinkedIn periodically expires the active session but keeps a remember-me cookie
# that allows re-login without a password. This script clicks the "Continue as
# <name>" button to mint a fresh session, which persists to the user-data-dir
# on disk for subsequent skill runs (send-invite.tcl, send-message.tcl).
#
# The wrapper (not-google-chrome --cdp) owns the browser lifecycle and exports
# CDP_WS_URL; this script is a pure CDP client and exits if run without it.
#
# Usage:
#     not-google-chrome --cdp -- tclsh login.tcl            # report state; if logged out, attempt fastrack login
#     not-google-chrome --cdp -- tclsh login.tcl --check    # report current login state only, never click

source [file dirname [info script]]/../lib/cdp-client.tcl
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
proc login_state {c} {
    set has_nav [js_bool $c {!!document.querySelector("[class*=\"global-nav__me\"], a[href*=\"/in/\"][class*=\"global-nav\"]")}]
    set has_feed [js_bool $c {!!document.querySelector("main [class*=\"feed\"], div[class*=\"feed-shared\"]")}]
    set has_fastrack [js_bool $c {!!document.querySelector(".fastrack-sign-in-cta")}]
    set has_login_form [js_bool $c {!!document.querySelector("form[action*=\"login\"], form[action*=\"authenticate\"]")}]
    if {$has_nav || $has_feed} { return "logged_in" }
    if {$has_fastrack} { return "logged_out_remember_me" }
    if {$has_login_form} { return "logged_out" }
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
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh login.tcl \[--check\]"
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

fconfigure stdout -encoding utf-8
fconfigure stderr -encoding utf-8
main
