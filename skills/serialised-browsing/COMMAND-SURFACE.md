# Serialised browsing: the policed command surface

A browser skill runs inside a per-run **safe interpreter** that exposes only the
verbs below. The skill never opens a socket, file, subprocess, or raw CDP
channel: each verb runs back in the harness (the master interpreter), which
drives the real browser through `skills/lib/cdp-client.tcl` and enforces
anti-ban web behaviour. The harness is `bin/browser-serialiser` (standalone) and,
later, the overseer (delegated); both share `skills/lib/serialiser-harness.tcl`,
so this contract is identical in both hosts.

This document is the contract a skill author writes against, and the contract the
remaining skills are reworked onto (Phase 2).

## Skill reference and resolution

A skill is named by a **reference** relative to the `skills/` directory, without
the `.tcl` suffix:

    instagram.com/fetch-recent-posts   ->   skills/instagram.com/fetch-recent-posts.tcl

The reference must stay inside `skills/` (a `..` or absolute reference is
refused). Invoke standalone with:

    browser-serialiser <skill-ref> [skill args...]
    browser-serialiser instagram.com/fetch-recent-posts posts <handle> --limit 3

## Entry convention

The harness sources the skill file into the safe interp and then calls one proc:

    proc serialiser_run {skillArgs} { ... }

`skillArgs` is the list of arguments after the skill reference. The proc drives
the verbs and calls `emit` exactly once with the result string; the harness
prints what was emitted. A skill file may also keep its legacy `main` for direct
`tclsh` use (the IG keystone does, so its siblings can still source it as a
library); the harness ignores everything but `serialiser_run`.

A skill may `source` its sibling files in the same skill directory and anything
in `skills/lib`, and nothing else: the safe interp's access path is exactly those
two directories. This preserves single-source-of-truth for shared components
(e.g. the other Instagram scripts source `fetch-recent-posts.tcl` as their
library).

## The two enforcement planes

- **Plane 1, capability.** `::safe::interpCreate` (Tcl Safe Base) hides
  `open`, `exec`, `socket`, `file` mutation, and raw CDP. A skill that tries them
  gets `invalid command name` / `permission denied`. The only host reach is the
  verbs.
- **Plane 2, web behaviour.** The harness owns pacing and jitter on the
  wire-touching verbs, enforces view-before-fetch for declared private
  endpoints, bounds response and paging size, and classifies 429 / login-wall
  outcomes into terminal states the skill reads via `state` but cannot retry past.

## Why the sandbox holds with no overseer present

Both planes are enforced by `bin/browser-serialiser` standalone, on a developer's own machine, where nothing external requires them. They are kept on anyway because the same harness runs in a second host: the **overseer**, a desktop application in a separate project (its `docs/overseer.md`) that owns the one shared logged-in Chromium profile and runs these skills in-process against it. There a skill is untrusted code the overseer must police: it sources the same `serialiser-harness.tcl` into a per-run safe interp and relays CDP through the same policed verbs. A skill that only worked by reaching outside the planes (its own socket, file, raw CDP) would run standalone but break under the overseer. Enforcing the sandbox in the standalone path is what keeps every skill runnable in both hosts.

The overseer is a **compatibility target, not a runtime requirement**. The standalone path is self-contained: OT skills run with `browser-serialiser` alone and need no overseer installed. When an overseer is present `browser-serialiser` delegates to it (so the run serialises with the overseer's own work, §SKILL.md); when it is absent the standalone path launches its own Chromium. Stay within the verb surface and a skill satisfies both without knowing which host it is in.

## The verbs

Signatures (one line each). Verbs that touch the wire are paced+jittered by the
harness; a skill does not (and cannot) pace itself with `after`. Request a pause
with `dwell` instead.

| Verb | Signature | Returns | Notes |
|------|-----------|---------|-------|
| `nav` | `nav <url> ?--wait seconds? ?--expect-login?` | landing URL | Navigate and settle. Paced. Records the landing for view-before-fetch; classifies a login/checkpoint redirect into a terminal state. `--expect-login` suppresses that classification for this one navigation, for a login skill that deliberately lands on the sign-in page (its title/URL would otherwise read as a logged-out wall); later navigations are still classified, so a failed login bouncing back to sign-in still walls. |
| `dump` | `dump` | outerHTML string | The current page's rendered DOM. |
| `eval` | `eval <jsExpr>` | JS value | `Runtime.evaluate` in the page (returnByValue, awaitPromise). General by design: it runs in the page, not the host; any fetch the JS triggers is policed on the wire. Raises `JS exception: ...` on a page-side error. |
| `api` | `api <path> ?--params str? ?--site host? ?--headers {k v ...}?` | raw body string | A **declared** private fetch replayed from the page context (cookies + CSRF included). Allowed only when the last `nav` covered a page matching the site's view-before-fetch entry. Paced, size-bounded; a 429 backs off (capped) then goes terminal `rate-limited`; a 401/403 goes terminal `logged-out`. |
| `capture` | `capture <navUrl> ?--seconds N? ?--match glob?` | list of `{url status body}` | The **primary** private-data path: navigate (paced), let the page issue its own API calls, harvest matching response bodies from the CDP network cache. View-before-fetch is intrinsic. |
| `harvest` | `harvest ?--match glob?` | list of `{url status body}` | Collect matching bodies already buffered by a prior `capture`, without navigating again. |
| `veto` | `veto <urlGlob>` | live veto list | Declare a URL the harness must refuse if the page tries to fetch it (a mutation guard, e.g. mark-as-seen). |
| `type` | `type <text>` | "" | Insert text into the focused element (`Input.insertText`). Paced. |
| `click` | `click <cssSelector>` | 1 or 0 | Click the first matching element in-page. Paced. |
| `state` | `state` | dict | The harness's view of the run: `terminal` (""/`rate-limited`/`logged-out`/`checkpoint`), `lastNav`, `pages`. A skill reads `terminal` to stop gracefully. |
| `emit` | `emit <result>` | "" | The skill's single output. The harness returns it as the run result. |
| `dwell` | `dwell <seconds>` | "" | A deliberate human-ish pause the skill may request (reading time between views). The harness owns timing. |
| `log` | `log <message>` | "" | A diagnostic line to stderr (the only channel besides `emit`). |

`capture`/`harvest` are one verb pair and `dwell`/`log` are documented together,
making the surface the **11 verbs** of the plan: `nav`, `dump`, `eval`, `api`,
`capture`(+`harvest`), `veto`, `type`, `click`, `state`, `emit`, `dwell`(+`log`).

## Wall handling

The harness, not the skill, classifies walls:

- **429** on an `api` fetch → exponential backoff (from 4s, doubling, capped at
  60s, up to 4 tries) → terminal `rate-limited`.
- **login / checkpoint** redirect (on `nav`/`capture`) or **401/403** on `api` →
  immediate terminal (`logged-out` / `checkpoint`).

On a terminal state the run ends; `browser-serialiser` exits 66 and the skill's
`state` shows the reason. A skill never chooses to retry a wall; the only retry
that exists is the harness's own 429 backoff.

## View-before-fetch

`api` is the **declared exception** to capture-based private-data access: a
private endpoint may be replayed only after a covering page was viewed. The
harness consults a per-site table (in `serialiser-harness.tcl`,
`serialiser::ViewBeforeFetch`) keyed by host suffix: each entry pairs an endpoint
glob with the navigation glob that must have preceded it. An undeclared endpoint,
or one without its covering `nav`, is refused. New private endpoints are added to
that table as skills are reworked (Phase 2); the default path for private data is
`capture`+scroll, where view-before-fetch is intrinsic.

## Writing a skill: shape

```tcl
proc serialiser_run {skillArgs} {
    # parse skillArgs ...
    nav "https://example.com/" --wait 3
    if {[dict get [state] terminal] ne ""} {
        emit "{\"error\": \"wall\"}"; return
    }
    nav "https://example.com/profile/$handle/" --wait 4   ;# covering view
    set body [api "/api/v1/feed/" --params "count=12" --headers {X-App-Id 123}]
    # ... parse $body with pure-Tcl helpers sourced from the skill's own dir ...
    emit $rendered
}
```

## Headers the verb does not add for you

The `--headers` in that example is not decoration. `api` sends only
`X-Requested-With` and `X-CSRFToken`; a site that authenticates its `/api/v1`
calls by an app id (Instagram's `X-IG-App-ID`, for one) rejects a request that
omits it, and the rejection names something else, a 400 reading `useragent
mismatch` rather than "missing header", so the omission surfaces far from its
cause. Carry every header the site's own page sends on that endpoint. Unlike the
view-before-fetch table, which is central, this is per call, so it is the line a
port silently drops.

A type-B primitive (one the overseer runs and persists) carries a second
contract the harness does not enforce: its single `emit` must be the canonical
envelope the BI server's `persistB` validates. That envelope's shape is owned by
the consuming repo, not here; a primitive that emits a free-form result is
rejected at persist, not at run.
