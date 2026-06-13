# serialiser-harness.tcl - the policing harness behind browser-serialiser.
#
# A browser skill no longer opens its own CDP socket. Instead the harness loads
# the skill into a per-run SAFE interpreter (Tcl Safe Base) and exposes a fixed
# POLICED COMMAND SURFACE: a skill calls verbs like `nav`, `eval`, `api`, `emit`;
# each verb runs back in the MASTER interpreter, where the harness drives the
# real browser through cdp-client.tcl and enforces web-behaviour policy. The
# skill never reaches a socket, a file, exec, or raw CDP.
#
# Two enforcement planes (the plan's Shape C):
#   Plane 1 (capability): ::safe::interpCreate removes file/exec/socket/raw-CDP.
#       The skill's own directory and skills/lib are added to the safe interp's
#       access path so a skill may `source` its shared siblings (e.g. the other
#       Instagram scripts source fetch-recent-posts.tcl as a library) and the
#       harness verb definitions, but nothing else on the filesystem is reachable.
#   Plane 2 (web behaviour): the harness paces and jitters the wire-touching
#       verbs, enforces view-before-fetch for declared private endpoints, bounds
#       response/paging size, and classifies 429 / login-wall outcomes into
#       terminal states the skill reads through `state` but cannot retry past.
#
# This file is the SAME library both execution hosts use. `browser-serialiser`
# (standalone) sources it and calls serialiser::run; a later overseer host will
# embed it and call serialiser::run on its leased browser. Everything host-
# specific (who owns the browser) is behind serialiser::Session, so the policy
# and the command surface live in one place.
#
# Command surface and entry convention: skills/serialised-browsing/COMMAND-SURFACE.md.

package require json
package require json::write

namespace eval serialiser {
    # Toolbox root (the directory holding bin/ and skills/), set by the caller
    # via serialiser::setRoot before run. The skill-ref resolver and the access
    # path are both anchored here.
    variable Root ""

    # The CDP client object for the current run (a cdp::Client). The verbs drive
    # it; the safe interp never sees it.
    variable Cdp ""

    # Per-run policy + bookkeeping state, a dict. Reset by serialiser::run.
    variable Run {}
}

# ---------------------------------------------------------------------------
# Setup.
# ---------------------------------------------------------------------------

# Anchor the toolbox root. $root is the directory that contains bin/ and skills/.
proc serialiser::setRoot {root} {
    variable Root
    set Root [file normalize $root]
}

# Resolve a skill reference to an absolute .tcl path inside the trusted skill
# tree, refusing anything that escapes it.
#
# REF->PATH RULE: "<dir>/<name>" resolves to "<Root>/skills/<dir>/<name>.tcl".
# The ref is a path RELATIVE to the skills/ directory, without the .tcl suffix.
# Example: "instagram.com/fetch-recent-posts" ->
#          "<Root>/skills/instagram.com/fetch-recent-posts.tcl".
# The resolved path must stay under <Root>/skills/ (no "..", no absolute ref),
# so a ref cannot reach outside the curated tree.
proc serialiser::resolveSkill {ref} {
    variable Root
    if {$Root eq ""} { error "serialiser: root not set (call serialiser::setRoot)" }
    if {[string match "/*" $ref] || [string match "~*" $ref]} {
        error "serialiser: skill-ref must be relative to skills/, got '$ref'"
    }
    set skillsDir [file join $Root skills]
    set path [file normalize [file join $skillsDir $ref.tcl]]
    # Containment: the normalized path must live under skills/ (defeats "..").
    if {$path ne $skillsDir && ![string match "[file normalize $skillsDir]/*" $path]} {
        error "serialiser: skill-ref '$ref' escapes the skills tree"
    }
    if {![file exists $path]} {
        error "serialiser: no skill at '$ref' (looked for $path)"
    }
    return $path
}

# ---------------------------------------------------------------------------
# Plane 2 policy tables and defaults.
# ---------------------------------------------------------------------------

# Per-site view-before-fetch table. `api` (the declared private-data exception)
# may only fire when the page already navigated to a URL matching one of the
# site's covering glob patterns. The key is a host suffix matched against the
# api endpoint's site (derived from the most recent nav). This is the central
# replacement for the old per-host gate and the narrow seen-mutation veto.
#
# Shape: dict host-suffix -> list of {endpointGlob coveringNavGlob ...} pairs.
# An `api` call to a path matching endpointGlob is allowed only if the last nav
# landed on a URL matching the paired coveringNavGlob.
variable serialiser::ViewBeforeFetch {
    instagram.com {
        */api/v1/feed/user/*   *instagram.com/*
        */api/v1/users/web_profile_info/* *instagram.com/*
        */api/v1/friendships/*/followers/* *instagram.com/*
        */api/v1/friendships/*/following/* *instagram.com/*
        */api/v1/media/*/comments/* *instagram.com/*
        */api/v1/direct_v2/inbox/* *instagram.com/*
        */api/v1/direct_v2/threads/* *instagram.com/*
        */api/v1/usertags/*/feed/* *instagram.com/*
        */api/v1/news/inbox/* *instagram.com/*
        */api/v1/accounts/current_user/* *instagram.com/*
        */api/v1/archive/reel/* *instagram.com/*
    }
    reddit.com {
        *.json   *reddit.com/*
    }
    airbnb.com {
        */api/v2/reservations* *airbnb*/hosting/reservations*
    }
}

# Pacing bounds (milliseconds) for the wire-touching verbs, owned by the harness
# so a skill cannot pace itself faster. Each policed verb sleeps a base plus a
# uniform random jitter before acting. Tunable per run via policy overrides.
variable serialiser::PaceDefaults {
    nav   {base 1500 jitter 1500}
    api   {base 1200 jitter 1800}
    click {base  400 jitter  600}
    type  {base  150 jitter  250}
}

# Paging / size bounds: an api response larger than MaxBodyBytes is refused
# (a runaway endpoint), and a capture/api loop may not page beyond MaxPages.
variable serialiser::MaxBodyBytes 8000000
variable serialiser::MaxPages 50

# 429 backoff: exponential from BackoffBaseMs, doubling, capped at BackoffCapMs,
# up to BackoffMaxTries before the run goes terminal `rate-limited`.
variable serialiser::BackoffBaseMs 4000
variable serialiser::BackoffCapMs 60000
variable serialiser::BackoffMaxTries 4

# ---------------------------------------------------------------------------
# Run: build the safe interp, source the skill, call its entry proc.
# ---------------------------------------------------------------------------

# Run a resolved skill under the policed surface against an already-connected
# cdp::Client. $skillPath is absolute (from resolveSkill); $cdp is the client;
# $skillArgs is the list passed to the skill's entry proc. Returns the string
# the skill emitted, or raises with the terminal reason on a wall.
proc serialiser::run {skillPath cdp skillArgs} {
    variable Cdp
    variable Run
    variable Root
    set Cdp $cdp
    set Run [dict create \
        lastNavUrl "" \
        pages 0 \
        terminal "" \
        emitted "" \
        emittedSet 0 \
        log {}]

    set interp [::safe::interpCreate]
    try {
        # Plane 1: widen the access path to the skill's own dir and skills/lib so
        # `source` of shared siblings works, and nothing else does.
        ::safe::interpAddToAccessPath $interp [file dirname $skillPath]
        ::safe::interpAddToAccessPath $interp [file join $Root skills lib]

        # The Safe Base removes stdin/stdout/stderr from the child, but a skill's
        # diagnostics (the `log` verb, and bare `puts stderr` in skills carried
        # over from the unsandboxed CDP path) expect stderr to exist. Share only
        # stderr in (read-write), so diagnostic writes reach the real channel
        # while stdout stays the harness's alone (emit is the skill's one result
        # channel). File/exec/socket capability is still removed.
        interp share {} stderr $interp

        serialiser::InjectVerbs $interp

        # tcllib json is pure-Tcl and safe; let the skill's parsers use it.
        catch {$interp eval {package require json}}
        catch {$interp eval {package require json::write}}

        # Source the skill inside the sandbox. ::safe maps the absolute path
        # through the access path automatically.
        $interp invokehidden source $skillPath

        if {![llength [$interp eval {info procs serialiser_run}]] \
                && ![$interp eval {namespace exists ::skill}] } {
            # The skill must define the entry proc (see COMMAND-SURFACE.md).
        }
        if {![llength [$interp eval {info commands serialiser_run}]]} {
            error "serialiser: skill [file tail $skillPath] defines no serialiser_run entry proc"
        }

        # Hand the args to the skill's entry proc. The skill drives the verbs and
        # calls `emit`; its return value is ignored in favour of what it emitted.
        $interp eval [list serialiser_run $skillArgs]
    } finally {
        ::safe::interpDelete $interp
    }

    if {[dict get $Run terminal] ne ""} {
        # A wall was hit; surface it as the run outcome.
        return -code error -errorcode [list SERIALISER_TERMINAL [dict get $Run terminal]] \
            "serialiser: terminal [dict get $Run terminal]"
    }
    return [dict get $Run emitted]
}

# ---------------------------------------------------------------------------
# Alias injection: bind every surface verb to a master-side handler. The safe
# interp can call the verb by name; the body runs here with full capability.
# ---------------------------------------------------------------------------

proc serialiser::InjectVerbs {interp} {
    foreach verb {nav dump eval api capture harvest veto type click state emit dwell log} {
        $interp alias $verb [list serialiser::Verb_$verb]
    }
}

# ---------------------------------------------------------------------------
# The 11 surface verbs (signatures documented in COMMAND-SURFACE.md). Each is a
# master-interp proc reached only through its alias.
# ---------------------------------------------------------------------------

# nav <url> ?--wait seconds?  -- navigate the page and settle. Paced+jittered.
# Records the landing URL for the view-before-fetch check, and classifies a
# login/checkpoint redirect into a terminal state. Returns the landing URL.
proc serialiser::Verb_nav {url args} {
    variable Cdp
    variable Run
    set wait 4
    foreach {k v} $args { if {$k eq "--wait"} { set wait $v } }
    serialiser::Pace nav
    $Cdp cdp Page.enable
    $Cdp cdp Page.navigate [dict create url $url]
    after [expr {int($wait * 1000)}]
    set landing [serialiser::PageUrl]
    dict set Run lastNavUrl $landing
    serialiser::ClassifyWall $landing [serialiser::PageTitle]
    return $landing
}

# dump  -- the current page's rendered outerHTML (the DOM-dump path, in-page).
# No extra pacing beyond the nav that preceded it. Returns the HTML string.
proc serialiser::Verb_dump {} {
    variable Cdp
    return [$Cdp evaluate {document.documentElement.outerHTML}]
}

# eval <jsExpr>  -- Runtime.evaluate in the page (returnByValue, awaitPromise).
# General by design: it runs in the page, not the host; any fetch the JS itself
# triggers is policed on the wire. Returns the JS value (a string/number/bool),
# or raises "JS exception: ..." on a page-side error.
proc serialiser::Verb_eval {jsExpr} {
    variable Cdp
    return [$Cdp evaluate $jsExpr]
}

# api <path> ?--params str? ?--site host?  -- a DECLARED private fetch replayed
# from the page context (credentials included). The exception to capture-based
# private-data access: allowed only when the last nav covered a page matching
# the site's view-before-fetch entry. Paced, size-bounded, and 429/login-aware
# (a 429 backs off then goes terminal; a login redirect goes terminal at once).
# Returns the raw JSON body string. The endpoint is same-origin (a path), so the
# page's own cookies and CSRF token authenticate it.
proc serialiser::Verb_api {path args} {
    variable Cdp
    variable Run
    set params ""
    set site ""
    set headers {}
    foreach {k v} $args {
        switch -- $k {
            --params  { set params $v }
            --site    { set site $v }
            --headers { set headers $v }
        }
    }
    if {$site eq ""} { set site [serialiser::HostOf [dict get $Run lastNavUrl]] }
    serialiser::CheckViewBeforeFetch $site $path
    return [serialiser::FetchPaced $path $params $headers]
}

# capture <navUrl> ?--seconds N? ?--match glob?  -- the primary private-data
# path: navigate (paced), let the page issue its OWN API calls, and harvest the
# matching response bodies from the CDP network cache. View-before-fetch is
# intrinsic here (the data only exists because the page was viewed). Returns a
# list of {url status body} triples for responses whose URL matches --match
# (default *), bounded by MaxBodyBytes each.
proc serialiser::Verb_capture {navUrl args} {
    variable Cdp
    variable Run
    set seconds 10
    set match "*"
    foreach {k v} $args {
        switch -- $k {
            --seconds { set seconds $v }
            --match   { set match $v }
        }
    }
    serialiser::Pace nav
    $Cdp cdpBuffered Network.enable
    $Cdp cdpBuffered Page.navigate [dict create url $navUrl]
    set landing ""
    $Cdp drainEvents $seconds
    set landing [serialiser::PageUrl]
    dict set Run lastNavUrl $landing
    serialiser::ClassifyWall $landing [serialiser::PageTitle]
    return [serialiser::Harvest $match]
}

# harvest ?--match glob?  -- collect matching response bodies already buffered
# by a prior capture, without navigating again. Same return shape as capture.
proc serialiser::Verb_harvest {args} {
    set match "*"
    foreach {k v} $args { if {$k eq "--match"} { set match $v } }
    return [serialiser::Harvest $match]
}

# veto <pattern>  -- declare a URL glob the harness must abort if the page tries
# to fetch it (a mutation guard, e.g. mark-as-seen). Recorded for the run; the
# Fetch interceptor fails any matching request. Returns the live veto list.
proc serialiser::Verb_veto {pattern} {
    variable Run
    dict lappend Run vetoes $pattern
    return [dict get $Run vetoes]
}

# type <text>  -- insert text into the focused element via Input.insertText.
# Paced+jittered (human-ish). Returns "".
proc serialiser::Verb_type {text} {
    variable Cdp
    serialiser::Pace type
    $Cdp cdp Input.insertText [dict create text $text]
    return ""
}

# click <selector>  -- click the first element matching a CSS selector, in-page.
# Paced+jittered. Returns 1 if an element was found and clicked, 0 otherwise.
proc serialiser::Verb_click {selector} {
    variable Cdp
    serialiser::Pace click
    set js "(function(){var e=document.querySelector([\"[SEL]\"][0]);if(e){e.click();return true;}return false;})()"
    set js [string map [list {["[SEL]"][0]} [json::write string $selector]] $js]
    set r [$Cdp evaluate $js]
    return [expr {$r eq "true" || $r eq 1 ? 1 : 0}]
}

# state  -- the harness's view of the run for the skill: a dict with
#   terminal  (""|rate-limited|logged-out|checkpoint)  the wall classification
#   lastNav   the last navigated landing URL
#   pages     the count of api/capture pages fetched so far
# The skill reads `terminal` to stop gracefully; it never chooses to retry a
# wall (the harness already did the only retry that is allowed, for 429).
proc serialiser::Verb_state {} {
    variable Run
    return [dict create \
        terminal [dict get $Run terminal] \
        lastNav  [dict get $Run lastNavUrl] \
        pages    [dict get $Run pages]]
}

# emit <result>  -- the skill's single output. The harness captures it and
# returns it as the run result. Calling emit twice overwrites (last wins).
proc serialiser::Verb_emit {result} {
    variable Run
    dict set Run emitted $result
    dict set Run emittedSet 1
    return ""
}

# dwell <seconds>  -- a deliberate human-ish pause the skill may request (e.g.
# reading-time between page views). The harness owns timing, so a skill asks for
# a dwell rather than calling `after` itself. Returns "".
proc serialiser::Verb_dwell {seconds} {
    after [expr {int($seconds * 1000)}]
    return ""
}

# log <message>  -- a diagnostic line to the harness (goes to stderr, prefixed),
# the only output channel besides emit. Returns "".
proc serialiser::Verb_log {message} {
    variable Run
    dict lappend Run log $message
    puts stderr "  \[skill\] $message"
    return ""
}

# ---------------------------------------------------------------------------
# Plane 2 internals: pacing, view-before-fetch, paced fetch, wall classification.
# ---------------------------------------------------------------------------

# Sleep base+uniform-jitter ms for a verb class before it touches the wire.
proc serialiser::Pace {verb} {
    variable PaceDefaults
    if {![dict exists $PaceDefaults $verb]} return
    set spec [dict get $PaceDefaults $verb]
    set base [dict get $spec base]
    set jit [dict get $spec jitter]
    set ms [expr {$base + int(rand() * $jit)}]
    after $ms
}

# The site host suffix the view-before-fetch table is keyed on. Returns the
# registrable-ish host of a URL (the bare hostname); the table keys are matched
# as suffixes so "www.instagram.com" matches the "instagram.com" entry.
proc serialiser::HostOf {url} {
    if {[regexp {^[a-z]+://([^/]+)} $url -> hostport]} {
        return [lindex [split $hostport :] 0]
    }
    return ""
}

# Enforce view-before-fetch: an `api` to $path is allowed only if the site has a
# table entry whose endpointGlob matches $path AND the last nav landed on a URL
# matching the paired coveringNavGlob. No table entry for the site/path => the
# endpoint is undeclared and refused (the audit case from the plan).
proc serialiser::CheckViewBeforeFetch {site path} {
    variable ViewBeforeFetch
    variable Run
    set entry {}
    dict for {suffix pairs} $ViewBeforeFetch {
        if {$site eq $suffix || [string match "*.$suffix" $site] || [string match "*$suffix" $site]} {
            set entry $pairs
            break
        }
    }
    if {![llength $entry]} {
        error "serialiser: api endpoint '$path' on site '$site' is not declared in the view-before-fetch table; route private data through capture, or add the endpoint"
    }
    set lastNav [dict get $Run lastNavUrl]
    foreach {endpointGlob coveringNavGlob} $entry {
        if {[string match $endpointGlob $path]} {
            if {$lastNav ne "" && [string match $coveringNavGlob $lastNav]} {
                return 1
            }
            error "serialiser: api '$path' requires a covering nav matching '$coveringNavGlob'; last nav was '[expr {$lastNav eq "" ? "<none>" : $lastNav}]'"
        }
    }
    error "serialiser: api endpoint '$path' is not declared for site '$site'"
}

# Replay a same-origin fetch from the page context, with pacing, size bound, and
# 429/login classification + capped backoff. $path is a same-origin path (the
# page's cookies/CSRF authenticate it); $params is the query string after '?';
# $headers is a flat {name value ...} list folded into the request. Returns the
# raw response body string. Raises (terminal) on a wall.
proc serialiser::FetchPaced {path params headers} {
    variable Cdp
    variable Run
    variable MaxBodyBytes
    variable MaxPages
    variable BackoffBaseMs
    variable BackoffCapMs
    variable BackoffMaxTries

    if {[dict get $Run pages] >= $MaxPages} {
        error "serialiser: paging bound reached ($MaxPages pages); refusing further api fetches"
    }

    set try 0
    set delay $BackoffBaseMs
    while 1 {
        serialiser::Pace api
        set body [serialiser::DoFetch $path $params $headers status]
        if {$status == 429} {
            incr try
            if {$try > $BackoffMaxTries} {
                dict set Run terminal rate-limited
                error "serialiser: rate-limited (429) after $BackoffMaxTries backoffs"
            }
            after $delay
            set delay [expr {min($delay * 2, $BackoffCapMs)}]
            continue
        }
        if {$status == 401 || $status == 403} {
            # A private fetch rejected as unauthenticated -> treat as logged out.
            dict set Run terminal logged-out
            error "serialiser: logged-out (HTTP $status on $path)"
        }
        if {[string length $body] > $MaxBodyBytes} {
            error "serialiser: api response from '$path' exceeds size bound ($MaxBodyBytes bytes)"
        }
        dict incr Run pages
        return $body
    }
}

# Do one in-page fetch of a same-origin path, returning the body and writing the
# HTTP status into the named var. The page-context JS sends the standard IG-style
# auth headers (X-CSRFToken from the cookie, X-Requested-With) plus any caller
# headers; a non-2xx returns the status with an empty body. Same-origin only.
proc serialiser::DoFetch {path params headersList statusVar} {
    variable Cdp
    upvar 1 $statusVar status
    set url $path
    if {$params ne ""} { append url "?" $params }
    # Build the headers object for the fetch. The CSRF token is read in-page from
    # the cookie so it is always the live value.
    set hdrPairs {"'X-Requested-With':'XMLHttpRequest'" "'X-CSRFToken':csrf"}
    foreach {hk hv} $headersList {
        lappend hdrPairs "[json::write string $hk]:[json::write string $hv]"
    }
    set js {
    (async () => {
        const csrf = (document.cookie.match(/csrftoken=([^;]+)/)||[])[1] || '';
        const resp = await fetch(@URL@, {
            credentials: 'include',
            headers: { @HDRS@ }
        });
        const text = await resp.text();
        return JSON.stringify({status: resp.status, body: text});
    })()
    }
    set js [string map [list \
        @URL@ [json::write string $url] \
        @HDRS@ [join $hdrPairs ,]] $js]
    set raw [$Cdp evaluate $js]
    set d [json::json2dict $raw]
    set status [dict get $d status]
    return [dict get $d body]
}

# Harvest buffered Network responses whose URL matches $match: read each body
# from the CDP cache, bounded by MaxBodyBytes. Returns a list of {url status
# body} triples. Clears the event buffer after reading so a later capture starts
# clean.
proc serialiser::Harvest {match} {
    variable Cdp
    variable MaxBodyBytes
    set out {}
    foreach evt [$Cdp events] {
        if {![dict exists $evt method]} continue
        if {[dict get $evt method] ne "Network.responseReceived"} continue
        set resp [dict get $evt params response]
        set url [dict get $resp url]
        if {![string match $match $url]} continue
        set reqId [dict get $evt params requestId]
        set bodyResp [$Cdp cdp Network.getResponseBody [dict create requestId $reqId]]
        set body ""
        if {[dict exists $bodyResp result body]} {
            set body [dict get $bodyResp result body]
        }
        if {[string length $body] > $MaxBodyBytes} {
            set body [string range $body 0 [expr {$MaxBodyBytes - 1}]]
        }
        lappend out [list $url [dict get $resp status] $body]
    }
    $Cdp clearEvents
    return $out
}

# Classify a wall from the landing URL and page title into a terminal state.
# A login/checkpoint redirect terminates the run at once (the skill reads it via
# `state` and stops; it never retries a wall).
proc serialiser::ClassifyWall {url title} {
    variable Run
    set u [string tolower $url]
    set t [string tolower $title]
    if {[string match "*/accounts/login*" $u] || [string match "*/login*" $u] || [string match "*/signup*" $u]} {
        dict set Run terminal logged-out
        return
    }
    if {[string match "*/challenge/*" $u] || [string match "*/checkpoint*" $u]} {
        dict set Run terminal checkpoint
        return
    }
    if {[string first "log in" $t] >= 0 || [string first "login" $t] >= 0 \
            || [string first "sign in" $t] >= 0} {
        dict set Run terminal logged-out
        return
    }
}

# The current page's location.href, via a raw (un-policed) page eval. Used by the
# harness itself for wall classification, so it bypasses the verb pacing.
proc serialiser::PageUrl {} {
    variable Cdp
    if {[catch {$Cdp evaluate {window.location.href}} u]} { return "" }
    return $u
}

proc serialiser::PageTitle {} {
    variable Cdp
    if {[catch {$Cdp evaluate {document.title}} t]} { return "" }
    return $t
}
