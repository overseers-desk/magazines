#!/usr/bin/env tclsh
# Log into IHG One Rewards and read the member's own stays, bookings and points.
#
# IHG drops the session when the browser closes, so login and any read happen in
# one serialiser run (no cookie persists between invocations). The sign-in page
# is a SAP CDC (Gigya) widget inside an Angular app; the member APIs on
# apis.ihg.com are gated by an in-memory bearer (x-ihg-sso-token) that the app
# sends, so a read run logs in, captures those headers from the app's own first
# authenticated request, then replays the member endpoints.
#
#   browser-serialiser ihg.com/login <username> <password>            ;# account summary
#   browser-serialiser ihg.com/login <username> <password> --stays    ;# + stays & points JSON
#   browser-serialiser ihg.com/login --check                          ;# probe the form, do not submit
#
# The safe interp cannot read config.ini, so credentials arrive as skill args;
# the caller reads ~/.claude/skills/config.ini [ihg.com] and passes them.
# Note: usernames may be a member number, an email, or a username.

package require json

namespace eval ihg {}

set ihg::SIGNIN_URL  "https://www.ihg.com/rewardsclub/gb/en/sign-in"
set ihg::ACCOUNT_URL "https://www.ihg.com/rewardsclub/gb/en/account-mgmt/home"
set ihg::STAYS_URL   "https://www.ihg.com/rewardsclub/gb/en/account-mgmt/staysevents"

# Encode a Tcl string as a JSON string literal for embedding in a JS expression.
proc ihg::jsonstr {s} { return [json::write string $s] }

# eval that never propagates a JS exception: returns the value, or "ERR: <msg>".
proc ihg::try_eval {expr} {
    if {[catch {eval $expr} r]} { return "ERR: $r" }
    return $r
}

# Poll for a *visible* password input. The page ships a hidden template form
# immediately; the interactive Gigya widget hydrates a few seconds later and only
# its inputs are visible (offsetParent set). Waiting on mere existence would race
# ahead of Gigya.
proc ihg::wait_visible_pw {{timeout 25}} {
    set expr {(function(){return Array.from(document.querySelectorAll("input[type=password]")).some(function(e){return e.offsetParent!==null;});})()}
    for {set w 0} {$w < $timeout} {incr w} {
        if {[ihg::try_eval $expr] eq "true"} { return 1 }
        dwell 1
    }
    return 0
}

# Live sign-in form structure as a JSON string (for --check / failure diagnosis).
proc ihg::probe_js {} {
    return {(function(){
        function d(el){return {tag:el.tagName.toLowerCase(),id:el.id||"",name:(el.getAttribute&&el.getAttribute("name"))||"",type:(el.getAttribute&&el.getAttribute("type"))||"",ph:(el.getAttribute&&el.getAttribute("placeholder"))||""};}
        var inputs=Array.from(document.querySelectorAll("input")).map(d);
        var captcha=!!document.querySelector("[class*=captcha],[id*=captcha],iframe[src*=recaptcha],iframe[src*=arkose],iframe[src*=hcaptcha]");
        return JSON.stringify({captcha:captcha,inputs:inputs});
    })()}
}

# Fill a field via the React controlled-input protocol: set the value through the
# native HTMLInputElement setter and dispatch input/change so the Gigya screenset
# records it exactly once. Trusted CDP Input.insertText instead made the visible
# password widget double its value (Gigya's onInput re-emits), which it submitted.
proc ihg::sv_fill {selector val} {
    eval "(function(){var e=document.querySelector([ihg::jsonstr $selector]);if(!e)return;e.focus();var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,\"value\");d.set.call(e,[ihg::jsonstr $val]);e.dispatchEvent(new Event(\"input\",{bubbles:true}));e.dispatchEvent(new Event(\"change\",{bubbles:true}));})()"
}

proc ihg::body_text {} { return [eval {document.body.innerText}] }

# Log in over the policed surface. Returns "" on success (page on the account
# area), or an "ERROR: ..." string describing the wall / Gigya error.
proc ihg::do_login {username password} {
    # --expect-login: the sign-in page title ("...Account Login") would otherwise
    # classify as a logged-out wall; this nav lands there on purpose. Later navs
    # are still wall-checked, so a failed login bouncing back to sign-in walls.
    nav $ihg::SIGNIN_URL --wait 6 --expect-login
    if {[dict get [state] terminal] ne ""} {
        return "ERROR: sign-in navigation hit a wall ([dict get [state] terminal])"
    }
    if {![ihg::wait_visible_pw 25]} {
        return "ERROR: password field never rendered. Probe: [ihg::try_eval [ihg::probe_js]]"
    }

    # Capture the Gigya accounts.login response so a failure reports its reason
    # (a credential mismatch, a temporary lockout and a risk block read alike in
    # the page text but differ here).
    ihg::try_eval {(function(){window.__gigya="";var ox=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){this.__gu=u+"";return ox.apply(this,arguments);};var os=XMLHttpRequest.prototype.send;XMLHttpRequest.prototype.send=function(){var x=this;x.addEventListener("load",function(){try{if(/accounts\.login|identity\.ihg\.com/.test(x.__gu||""))window.__gigya=(x.responseText||"").slice(0,700);}catch(e){}});return os.apply(this,arguments);};return "ok";})()}

    # Let the widget finish hydrating before tagging, so the tagged elements are
    # the live ones (an early tag can be detached by a later re-render).
    dwell 3

    # Gigya renders duplicate username/password inputs (a hidden template plus the
    # visible widget); tag the *visible* ones and the Gigya form's own submit (not
    # the header "Sign in" link, an <a> earlier in the DOM that only toggles a
    # panel and never submits).
    set tagged [eval {(function(){
        function vis(e){return !!(e && e.offsetParent !== null);}
        var ins=Array.from(document.querySelectorAll("input"));
        var u=ins.find(function(i){return i.name==="username"&&vis(i);})
            || ins.find(function(i){var t=(i.type||"text").toLowerCase();return (t==="text"||t==="email")&&vis(i);});
        var p=ins.find(function(i){return (i.name==="password"||i.type==="password")&&vis(i);});
        var s=Array.from(document.querySelectorAll("input.gigya-input-submit[type=submit]")).find(function(b){
            var t=((b.value||"")+"").trim().toLowerCase();return vis(b)&&(t==="sign in"||t==="log in"||t==="login");})
            || Array.from(document.querySelectorAll("form.gigya-login-form input[type=submit]")).find(function(b){return vis(b);});
        if(u)u.setAttribute("data-sv","u");
        if(p)p.setAttribute("data-sv","p");
        if(s)s.setAttribute("data-sv","s");
        return JSON.stringify({u:!!u,p:!!p,s:!!s});
    })()}]
    if {[string first {"u":true} $tagged] < 0 || [string first {"p":true} $tagged] < 0} {
        return "ERROR: login fields not found ($tagged). Probe: [ihg::try_eval [ihg::probe_js]]"
    }
    ihg::sv_fill {input[data-sv="u"]} $username
    ihg::sv_fill {input[data-sv="p"]} $password

    # The submit needs a *trusted* click (the policed click verb dispatches a real
    # CDP mouse event); a synthetic in-page click does not fire Gigya's login.
    if {[string first {"s":true} $tagged] < 0 || [click {[data-sv="s"]}] != 1} {
        return "ERROR: sign-in submit not found ($tagged)."
    }

    # Settle the AJAX login + redirect away from /sign-in.
    set u ""
    for {set w 0} {$w < 20} {incr w} {
        dwell 1
        set u [eval {window.location.href}]
        if {[string first "sign-in" $u] < 0} { break }
    }
    set title [eval {document.title}]
    if {[string first "sign-in" $u] >= 0 || [string match -nocase "*login*" $title]} {
        set gig [eval {window.__gigya||""}]
        return "ERROR: login did not complete (url=$u title=$title) gigya=[string range $gig 0 300]"
    }
    return ""
}

# Fetch a member API endpoint from the page context using captured app headers
# (window.__hdrs, set by ihg::capture_member_headers). Returns "status\nbody".
proc ihg::member_get {url} {
    set js "(function(){var H=Object.assign({},window.__hdrs||{});if(!H\[\"x-ihg-sso-token\"\])return \"NOHDRS\";return fetch([ihg::jsonstr $url],{headers:H,credentials:\"include\"}).then(function(r){return r.text().then(function(t){return r.status+\"\\n\"+t;});}).catch(function(e){return \"FETCHERR:\"+e;});})()"
    return [ihg::try_eval $js]
}

# The member APIs (apis.ihg.com) need the app's in-memory bearer (x-ihg-sso-token)
# plus its x-cdc-api-key. Capture them from a live authenticated XHR: hook
# setRequestHeader, then click a stay's "View Hotel Bill" (which fires one).
proc ihg::capture_member_headers {} {
    ihg::try_eval {(function(){
        window.__hdrs={};
        var oo=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){this.__u=u+"";return oo.apply(this,arguments);};
        var osh=XMLHttpRequest.prototype.setRequestHeader;XMLHttpRequest.prototype.setRequestHeader=function(n,v){try{if(/apis\.ihg\.com/.test(this.__u||""))window.__hdrs[n.toLowerCase()]=v+"";}catch(e){}return osh.apply(this,arguments);};
        return "ok";
    })()}
    ihg::try_eval {(function(){var el=Array.from(document.querySelectorAll("a,button,[role=button]")).find(function(x){return /view hotel bill|earning details/i.test((x.textContent||"").trim());});if(el){el.setAttribute("data-sv","trig");return true;}return false;})()}
    click {[data-sv="trig"]}
    for {set w 0} {$w < 12} {incr w} {
        dwell 1
        if {[eval {(window.__hdrs&&window.__hdrs["x-ihg-sso-token"])?"1":""}] ne ""} { return 1 }
    }
    return 0
}

proc serialiser_run {skillArgs} {
    set check 0
    set stays 0
    set positional {}
    foreach a $skillArgs {
        switch -- $a {
            --check { set check 1 }
            --stays { set stays 1 }
            --json  {}
            default { lappend positional $a }
        }
    }

    if {$check} {
        nav $ihg::SIGNIN_URL --wait 6 --expect-login
        ihg::wait_visible_pw 25
        emit "url=[ihg::try_eval {window.location.href}]\ntitle=[ihg::try_eval {document.title}]\nprobe=[ihg::try_eval [ihg::probe_js]]"
        return
    }

    if {[llength $positional] < 2} {
        emit "ERROR: usage: ihg.com/login <username> <password> \[--stays\] | --check"
        return
    }
    lassign $positional username password

    set err [ihg::do_login $username $password]
    if {$err ne ""} { emit $err; return }

    if {!$stays} {
        nav $ihg::ACCOUNT_URL --wait 5
        set body ""
        for {set w 0} {$w < 12} {incr w} {
            dwell 1
            set body [ihg::body_text]
            if {[string first "Points" $body] >= 0} { break }
        }
        emit "LOGGED IN (url=[eval {window.location.href}])\n---\n[string range $body 0 1200]"
        return
    }

    # --stays: read the member's bookings (stays) and points ledger (activities).
    # The cash value of a Points & Cash booking is NOT in these endpoints — it is
    # only in the booking-confirmation email (charged in USD). The stays list
    # carries each booking's confirmationNumber/dates/hotel/rateCode; the
    # activities ledger flags Points & Cash via a "Points and Cash Activity"
    # entry ("Points and Cash Points Purchased") alongside the points redemption.
    nav $ihg::STAYS_URL --wait 6
    for {set w 0} {$w < 15} {incr w} {
        dwell 1
        if {[string first "PAST STAYS" [ihg::body_text]] >= 0} { break }
    }
    if {![ihg::capture_member_headers]} {
        emit "ERROR: could not capture member API headers (no past-stay action to trigger an authenticated call?)."
        return
    }
    set stays_json [ihg::member_get "https://apis.ihg.com/members/v2/profiles/me/stays?limit=40"]
    set acts_json  [ihg::member_get "https://apis.ihg.com/members/v1/profiles/me/activities?activityType=all&duration=360&limit=500&offset=0"]
    emit "=== stays (members/v2/profiles/me/stays) ===\n[string range $stays_json 0 16000]\n\n=== activities (members/v1/profiles/me/activities) ===\n[string range $acts_json 0 16000]"
}

# Direct-tclsh entry intentionally omitted: this skill runs only over the policed
# serialiser surface (serialiser_run).
