#!/usr/bin/env tclsh
# Log into Qantas Frequent Flyer via CDP and print account state.
#
# Reads credentials from ~/.claude/skills/config.ini, drives the sign-in form on
# www.qantas.com, navigates to my-account, and extracts {first_name, tier,
# member_id, points, status_credits}.
#
# not-google-chrome owns the browser lifecycle and exports CDP_WS_URL; this
# script is a pure CDP client and exits if run without it. Login + balance
# happen in one CDP session.
#
# Usage:
#     not-google-chrome --cdp -- tclsh login.tcl            # human-readable
#     not-google-chrome --cdp -- tclsh login.tcl --json     # JSON
#     not-google-chrome --cdp -- tclsh login.tcl --check    # open login page, do not submit

package require json

source [file dirname [info script]]/../lib/cdp-client.tcl

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
        set name [qf::dget $data first_name "?"]
        set tier [qf::dget $data tier "?"]
        set mid [qf::dget $data member_id "?"]
        set pts [qf::dget $data points ""]
        set sc [qf::dget $data status_credits ""]
        set pts_str [expr {[string is integer -strict $pts] ? [qf::comma $pts] : "?"}]
        set sc_str [expr {[string is integer -strict $sc] ? [qf::comma $sc] : "?"}]
        puts "$name ($tier, $mid): $pts_str pts, $sc_str status credits"
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
