#!/usr/bin/env tclsh
# Log into Qantas Frequent Flyer and print account state.
#
# Drives the sign-in form on www.qantas.com, navigates to my-account, and
# extracts {first_name, tier, member_id, points, status_credits}. Login + balance
# happen in one session (cookies do not persist between invocations).
#
# Two entry paths share the same form-fill, parse and render logic:
#   - Serialiser surface (the policed path the harness drives):
#         browser-serialiser qantas.com/login <member_id> <last_name> <pin> [--json]
#         browser-serialiser qantas.com/login --check        # open the form, do not submit
#     serialiser_run navigates the sign-in page, detects the form, types the
#     credentials, clicks submit, then reads and parses the account page.
#   - Direct tclsh (legacy), credentials from ~/.claude/skills/config.ini:
#         not-google-chrome --cdp -- tclsh login.tcl [--json|--check]

package require json

# Legacy CDP engine, kept for the direct-tclsh path (qf::run / qf::main, which
# call cdp::connect when run as `tclsh login.tcl ...` outside the serialiser).
# Sourced only when not already present, so loading this file under the
# serialiser harness (where the policed verbs replace raw CDP) is a no-op rather
# than a re-definition. The harness path uses serialiser_run.
if {![namespace exists cdp]} {
    catch { source [file dirname [info script]]/../lib/cdp-client.tcl }
}

namespace eval qf {}

set qf::LOGIN_URL "https://www.qantas.com/au/en/frequent-flyer/my-account/sign-in.html"
set qf::ACCOUNT_URL "https://www.qantas.com/au/en/frequent-flyer/my-account.html"

# ---------------------------------------------------------------------------
# CDP eval helpers over the shared cdp::Client.
# ---------------------------------------------------------------------------

# Runtime.evaluate of $expr (returnByValue, awaitPromise=false to match the
# Python helper). Returns the JS value, or $default on a JS exception / error.
proc qf::js {c expr {default ""}} {
    if {[catch {
        $c cdp Runtime.evaluate [dict create \
            expression $expr awaitPromise false returnByValue true]
    } resp]} {
        return $default
    }
    set result [dict get $resp result]
    if {[dict exists $result exceptionDetails]} { return $default }
    if {[dict exists $result result value]} {
        return [dict get $result result value]
    }
    return $default
}

# Poll for a CSS selector to exist, up to $timeout seconds.
proc qf::wait_for {c selector {timeout 10}} {
    set deadline [expr {[clock milliseconds] + int($timeout * 1000)}]
    set expr "!!document.querySelector([qf::jsonstr $selector])"
    while {[clock milliseconds] < $deadline} {
        set v [qf::js $c $expr]
        if {$v eq "true" || $v == 1} { return 1 }
        after 400
    }
    return 0
}

# Encode a string as a JSON string literal (for embedding in a JS expression),
# mirroring Python's json.dumps(s).
proc qf::jsonstr {s} {
    return [json::write string $s]
}

# Format an integer with thousands separators (mirrors Python f"{n:,}").
proc qf::comma {n} {
    set neg ""
    if {[string index $n 0] eq "-"} { set neg "-"; set n [string range $n 1 end] }
    set out ""
    set len [string length $n]
    for {set i 0} {$i < $len} {incr i} {
        if {$i > 0 && (($len - $i) % 3) == 0} { append out "," }
        append out [string index $n $i]
    }
    return "$neg$out"
}

# ---------------------------------------------------------------------------
# Config.
# ---------------------------------------------------------------------------

# Read a `key = value` from the [section] of one or more INI files. Later files
# override earlier ones (config.local.ini wins). Returns "" if unset.
proc qf::ini_get {files section key} {
    set val ""
    foreach path $files {
        if {![file exists $path]} { continue }
        set f [open $path r]
        fconfigure $f -encoding utf-8
        set in_section 0
        while {[gets $f line] >= 0} {
            set t [string trim $line]
            if {$t eq "" || [string index $t 0] in {# ;}} { continue }
            if {[regexp {^\[(.+)\]$} $t -> sec]} {
                set in_section [expr {[string trim $sec] eq $section}]
                continue
            }
            if {!$in_section} { continue }
            set eq [string first "=" $t]
            if {$eq < 0} { continue }
            set k [string trim [string range $t 0 [expr {$eq - 1}]]]
            if {$k eq $key} {
                set val [string trim [string range $t [expr {$eq + 1}] end]]
            }
        }
        close $f
    }
    return $val
}

# ---------------------------------------------------------------------------
# Account-page parsing (pure logic — straight port of _parse_account_body).
# ---------------------------------------------------------------------------

# Extract {first_name, tier, member_id, points, status_credits} from the visible
# text of the rendered my-account page. Returns a dict with only the keys found.
proc qf::parse_account_body {body} {
    set out [dict create]

    # First name: the greeting line "Good <time>, <Name>".
    if {[regexp -line {^Good \w+,\s*([A-Z][a-z]+(?:\s+[A-Z][a-z]+)?)\s*$} \
            $body -> name]} {
        dict set out first_name $name
    }

    # Tier: a tier name on its own line, optionally with a trailing ":".
    if {[regexp -line {^(Bronze|Silver|Gold|Platinum One|Platinum|Chairman's Lounge):?\s*$} \
            $body -> tier]} {
        dict set out tier $tier
    }

    # Member ID: 10 digits on its own line.
    if {[regexp -line {^(\d{10})\s*$} $body -> mid]} {
        dict set out member_id $mid
    }

    # Points: number on the line after "Qantas Points". The rendered DOM uses
    # either "," or "." as the thousands separator.
    if {[regexp {(?n)^Qantas Points\s*\n+\s*([0-9.,]+)\s*$} $body -> pts]} {
        dict set out points [qf::strip_thousands $pts]
    }

    # Status Credits: same pattern.
    if {[regexp {(?n)^Status Credits\s*\n+\s*([0-9.,]+)\s*$} $body -> sc]} {
        dict set out status_credits [qf::strip_thousands $sc]
    }

    return $out
}

# Drop "." and "," and parse as a decimal integer (mirrors int(re.sub([.,],...)).
proc qf::strip_thousands {s} {
    set s [string map {. "" , ""} $s]
    # Force base-10 so a leading zero never triggers octal parsing.
    return [scan $s %d]
}

# ---------------------------------------------------------------------------
# Driver.
# ---------------------------------------------------------------------------

# Returns a 2-list {code dataDict}. code 0 on success (data carries the parsed
# fields, or {} for --check); code 1 on failure (data carries {error ...}).
proc qf::run {check_only debug} {
    set cfg_file [file join $::env(HOME) .claude skills config.ini]
    if {![file exists $cfg_file]} {
        puts stderr "ERROR: $cfg_file not found. See Prerequisites in the aesop qantas.com SKILL.md."
        exit 1
    }
    set cfg_files [list $cfg_file [file join [file dirname $cfg_file] config.local.ini]]
    set member_id [qf::ini_get $cfg_files qantas.com member_id]
    set last_name [qf::ini_get $cfg_files qantas.com last_name]
    set pin [qf::ini_get $cfg_files qantas.com pin]
    foreach {k v} [list member_id $member_id last_name $last_name pin $pin] {
        if {$v eq ""} {
            puts stderr "ERROR: ~/.claude/skills/config.ini missing \[qantas.com\] $k"
            exit 1
        }
    }

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: not-google-chrome --cdp -- tclsh login.tcl \[--json|--check\]"
        exit 1
    }

    set c [cdp::connect]
    try {
        $c cdp Network.enable
        $c cdp Page.enable

        if {$debug} { puts stderr "\[navigate\] $qf::LOGIN_URL" }
        $c cdp Page.navigate [dict create url $qf::LOGIN_URL]
        after 5000

        if {![qf::wait_for $c "#pin" 12]} {
            set body [string range [qf::js $c "document.body.innerText" ""] 0 399]
            puts stderr "ERROR: PIN field did not appear. Body: $body"
            exit 1
        }

        if {$check_only} {
            puts "Check only - login form ready, not submitting."
            return [list 0 {}]
        }

        foreach {fid val} [list memberId $member_id lastName $last_name pin $pin] {
            qf::js $c "document.querySelector(\"#$fid\").focus();document.querySelector(\"#$fid\").value = \"\";document.querySelector(\"#$fid\").dispatchEvent(new Event(\"input\",{bubbles:true}));"
            after 200
            $c cdp Input.insertText [dict create text $val]
            after 200
            if {$debug} {
                set got [qf::js $c "document.querySelector(\"#$fid\").value" ""]
                if {$fid eq "pin"} {
                    set shown [string repeat "*" [string length $got]]
                } else {
                    set shown $got
                }
                puts stderr "\[fill\] $fid=$shown ([string length $got] chars)"
            }
        }

        set clicked [qf::js $c {(function(){
            var btns = Array.from(document.querySelectorAll("button"));
            var b = btns.find(function(x){
                var t = (x.textContent || "").trim().toLowerCase();
                return x.type === "submit" || t === "log in" || t === "login";
            });
            if (b) { b.click(); return true; }
            return false;
        })()}]
        if {$clicked ne "true" && $clicked != 1} {
            puts stderr "ERROR: LOG IN button not found"
            exit 1
        }

        # Wait until the URL is no longer sign-in (login redirect completes).
        set deadline [expr {[clock milliseconds] + 25000}]
        while {[clock milliseconds] < $deadline} {
            after 1000
            set u [qf::js $c "window.location.href" ""]
            if {[string first "/my-account" $u] >= 0 && [string first "sign-in" $u] < 0} {
                break
            }
        }

        set ma_url [qf::js $c "window.location.href" ""]
        set ma_title [qf::js $c "document.title" ""]
        if {[string first "sign-in" $ma_url] >= 0 || [string first "Login" $ma_title] >= 0} {
            set err [qf::js $c {(function(){var e=document.querySelector("[role=\"alert\"], .error, [data-testid*=\"error\"]");return e ? e.textContent.trim() : null;})()}]
            set msg "login did not complete (URL=$ma_url, title=$ma_title)"
            if {$err ne "" && $err ne "null"} {
                append msg "; page error: $err"
            }
            return [list 1 [dict create error $msg]]
        }

        if {[string first "/my-account" $ma_url] < 0} {
            $c cdp Page.navigate [dict create url $qf::ACCOUNT_URL]
            after 6000
        }

        # Wait for points to render (SPA may hydrate after navigation).
        set deadline [expr {[clock milliseconds] + 15000}]
        set body ""
        while {[clock milliseconds] < $deadline} {
            after 1000
            set body [qf::js $c "document.body.innerText" ""]
            if {[string first "Qantas Points" $body] >= 0 && \
                [regexp {\d{1,3}(?:,\d{3})} $body]} {
                break
            }
        }

        set data [qf::parse_account_body $body]
        return [list 0 $data]
    } finally {
        $c close
    }
}

# ---------------------------------------------------------------------------
# JSON emission for --json (mirrors json.dumps(data, indent=2)). The five fields
# are: first_name/tier/member_id strings, points/status_credits integers.
# ---------------------------------------------------------------------------

proc qf::render_json {data} {
    if {![dict size $data]} { return "{}" }
    set strfields {first_name tier member_id}
    set parts {}
    dict for {k v} $data {
        if {$k in $strfields} {
            set rendered [json::write string $v]
        } elseif {[string is integer -strict $v]} {
            set rendered $v
        } else {
            set rendered [json::write string $v]
        }
        lappend parts "  [json::write string $k]: $rendered"
    }
    return "{\n[join $parts ",\n"]\n}"
}

# Render the parsed account dict as the one-line human summary (the exact text
# the legacy stdout path prints). Shared by qf::main and serialiser_run so the
# rendered bytes are identical on both paths.
proc qf::render_human {data} {
    set name [qf::dget $data first_name "?"]
    set tier [qf::dget $data tier "?"]
    set mid [qf::dget $data member_id "?"]
    set pts [qf::dget $data points ""]
    set sc [qf::dget $data status_credits ""]
    set pts_str [expr {[string is integer -strict $pts] ? [qf::comma $pts] : "?"}]
    set sc_str [expr {[string is integer -strict $sc] ? [qf::comma $sc] : "?"}]
    return "$name ($tier, $mid): $pts_str pts, $sc_str status credits"
}

# ---------------------------------------------------------------------------
# Serialiser entry: the policed-surface path. The harness sources this file into
# a safe interp and calls serialiser_run with the skill args; the flow drives the
# policed verbs (nav/eval/state/type/click/dump) instead of cdp::connect. The
# form-fill, account parse (qf::parse_account_body) and rendering (render_json /
# render_human) are the identical procs the legacy path uses, so the emitted
# bytes match.
#
# The safe interp cannot read config.ini, so the credentials arrive as skill
# args; the SKILL.md instructs the caller to read ~/.claude/skills/config.ini and
# pass them. --check needs no credentials (it stops before the submit click).
#
#   browser-serialiser qantas.com/login <member_id> <last_name> <pin> [--json]
#   browser-serialiser qantas.com/login --check
# ---------------------------------------------------------------------------

# Poll in-page (via the eval verb) for a CSS selector to exist, up to $timeout
# seconds, using dwell for the harness-owned pause between polls.
proc qf::sv_wait_for {selector {timeout 12}} {
    set expr "!!document.querySelector([qf::jsonstr $selector])"
    for {set waited 0} {$waited < $timeout} {incr waited} {
        set v [eval $expr]
        if {$v eq "true" || $v == 1} { return 1 }
        dwell 1
    }
    return 0
}

# Fill one form field over the policed surface: focus+clear it in-page (eval),
# then type the value (the type verb is Input.insertText, paced by the harness).
proc qf::sv_fill_field {fid val} {
    eval "document.querySelector(\"#$fid\").focus();document.querySelector(\"#$fid\").value = \"\";document.querySelector(\"#$fid\").dispatchEvent(new Event(\"input\",{bubbles:true}));"
    type $val
}

# Click the sign-in submit. Prefer the policed click verb on the submit button;
# fall back to the text-matched button the legacy path found (some Qantas form
# revisions render the submit without type=submit). Returns 1 if a click landed.
proc qf::sv_click_submit {} {
    if {[click "button\[type=submit\]"] == 1} { return 1 }
    set clicked [eval {(function(){
        var btns = Array.from(document.querySelectorAll("button"));
        var b = btns.find(function(x){
            var t = (x.textContent || "").trim().toLowerCase();
            return x.type === "submit" || t === "log in" || t === "login";
        });
        if (b) { b.click(); return true; }
        return false;
    })()}]
    return [expr {$clicked eq "true" || $clicked == 1 ? 1 : 0}]
}

proc serialiser_run {skillArgs} {
    set check 0
    set json_out 0
    set positional {}
    foreach a $skillArgs {
        switch -- $a {
            --check { set check 1 }
            --json  { set json_out 1 }
            default { lappend positional $a }
        }
    }

    nav $qf::LOGIN_URL --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit [qf::sv_error $json_out "sign-in page redirected to a wall ([dict get [state] terminal])"]
        return
    }

    if {![qf::sv_wait_for "#pin" 12]} {
        emit [qf::sv_error $json_out "PIN field did not appear on the sign-in page"]
        return
    }

    if {$check} {
        emit "Check only - login form ready, not submitting."
        return
    }

    if {[llength $positional] < 3} {
        emit [qf::sv_error $json_out "Usage: qantas.com/login <member_id> <last_name> <pin> \[--json] | --check"]
        return
    }
    lassign $positional member_id last_name pin

    foreach {fid val} [list memberId $member_id lastName $last_name pin $pin] {
        qf::sv_fill_field $fid $val
    }

    if {[qf::sv_click_submit] != 1} {
        emit [qf::sv_error $json_out "LOG IN button not found"]
        return
    }

    # Settle the login redirect, then ensure we are on my-account.
    dwell 3
    set u [eval "window.location.href"]
    set title [eval "document.title"]
    if {[string first "sign-in" $u] >= 0 || [string first "Login" $title] >= 0} {
        set err [eval {(function(){var e=document.querySelector("[role=\"alert\"], .error, [data-testid*=\"error\"]");return e ? e.textContent.trim() : null;})()}]
        set msg "login did not complete (URL=$u, title=$title)"
        if {$err ne "" && $err ne "null"} { append msg "; page error: $err" }
        emit [qf::sv_error $json_out $msg]
        return
    }
    if {[string first "/my-account" $u] < 0} {
        nav $qf::ACCOUNT_URL --wait 6
    }

    # Wait for points to hydrate (SPA renders after navigation).
    set body ""
    for {set waited 0} {$waited < 15} {incr waited} {
        dwell 1
        set body [eval "document.body.innerText"]
        if {[string first "Qantas Points" $body] >= 0 && [regexp {\d{1,3}(?:,\d{3})} $body]} {
            break
        }
    }

    set data [qf::parse_account_body $body]
    if {$json_out} {
        emit [qf::render_json $data]
    } elseif {[dict size $data]} {
        emit [qf::render_human $data]
    } else {
        emit [qf::sv_error 0 "account page parsed no fields (URL=$u)"]
    }
}

# Shape an error the same way each output mode expects: a JSON object for --json,
# a plain ERROR line otherwise.
proc qf::sv_error {json_out msg} {
    if {$json_out} {
        return "\{\n  [json::write string error]: [json::write string $msg]\n\}"
    }
    return "ERROR: $msg"
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------

proc qf::main {} {
    global argv
    set check 0
    set json_out 0
    set debug 0
    foreach a $argv {
        switch -- $a {
            --check { set check 1 }
            --json  { set json_out 1 }
            --debug { set debug 1 }
            default {
                puts stderr "Unknown argument: $a"
                exit 2
            }
        }
    }

    lassign [qf::run $check $debug] code data

    if {$json_out} {
        puts [qf::render_json $data]
    } elseif {$code == 0 && [dict size $data]} {
        puts [qf::render_human $data]
    } elseif {$code != 0 && [qf::dget $data error ""] ne ""} {
        puts stderr "ERROR: [dict get $data error]"
    }

    exit $code
}

proc qf::dget {d key {default ""}} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8
    qf::main
}
