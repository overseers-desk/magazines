# Serialised browsing: the policed command surface

A browser skill runs inside a per-run **safe interpreter** that exposes only the
verbs below. The skill never opens a socket, file, subprocess, or raw CDP
channel: each verb runs back in the harness (the master interpreter), which
drives the real browser through the `cdp` module (vendored at `lib/cdp-1.0.1.tm`) and enforces
anti-ban web behaviour. The harness is `bin/browser-serialiser` (standalone) and,
later, the overseer (delegated); both share `lib/serialiser-harness.tcl`,
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
`tclsh` use, as `instagram.com/fetch-recent-posts` does; the harness ignores
everything but `serialiser_run`.

A skill may `source` its sibling files in the same skill directory, the files in
its own `lib/`, and anything in the shared `lib` at the root, and nothing else:
the safe interp's access path is exactly those directories. This preserves
single-source-of-truth for shared components: helpers that several of a skill's
actions draw on live in that skill's `lib/`, as the Instagram feed-and-parse
helpers do.

## Credentials: config.ini reaches a skill as arguments

`$HOME/.config/magazines/config.ini` sits outside the safe interp's access
path, so a skill takes every credential as a `skillArgs` element and the
caller supplies it. This shell function is the reader:

    ini() { python3 -c 'import configparser,os,pathlib,sys;p=pathlib.Path(os.environ.get("XDG_CONFIG_HOME") or pathlib.Path.home()/".config")/"magazines/config.ini";c=configparser.ConfigParser(interpolation=None);c.read(p);print(c.get(sys.argv[1],sys.argv[2],fallback=""))' "$1" "$2"; }

Substitute its output straight into the command:

    browser-serialiser qantas.com/login "$(ini qantas.com member_id)" "$(ini qantas.com last_name)" "$(ini qantas.com pin)"

The substitution runs in the shell, so a secret travels from the file to the
process argument list without an agent reading it. An agent that opens
`config.ini` instead, or prints a value and retypes it, copies the credential
into the conversation and out to the model provider, where the file's own
permissions no longer protect it. Absent key or absent section yields the
empty string, which a skill reports as a missing prerequisite.

Two properties of the reader carry weight. `interpolation=None` keeps a literal
`%` in a password from raising `InterpolationSyntaxError` and silently yielding
an empty value. Python's `configparser` accepts the key syntax this file uses;
`git config -f` does not, since git rejects `_` in a key name and fails the
whole file on the first one it meets.

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
| `key` | `key <keyname>` | "" | Dispatch a trusted key press to the focused element (`Input.dispatchKeyEvent`). Needed where a rich-text editor ignores a synthetic event, e.g. a send-on-Enter message composer with no Send button. Known keys: `Enter`, `Backspace`. Paced. |
| `state` | `state` | dict | The harness's view of the run: `terminal` (""/`rate-limited`/`logged-out`/`checkpoint`/`off-site`), `lastNav`, `pages`. A skill reads `terminal` to stop gracefully. |
| `emit` | `emit <result>` | "" | The skill's single output. The harness returns it as the run result. |
| `dwell` | `dwell <seconds>` | "" | A deliberate human-ish pause the skill may request (reading time between views). The harness owns timing. |
| `log` | `log <message>` | "" | A diagnostic line to stderr (the only channel besides `emit`). |

`capture`/`harvest` are one verb pair and `dwell`/`log` are documented together,
so the surface reads as: `nav`, `dump`, `eval`, `api`, `capture`(+`harvest`),
`veto`, `type`, `click`, `key`, `state`, `emit`, `dwell`(+`log`).

`capture` is the only verb that turns the CDP Network domain on, and `harvest`
reads the buffer that `capture` filled. A skill that reaches a page with `nav`,
drives it with `click`/`type`/`eval`, and then calls `harvest` collects nothing,
however long it dwells: nothing was listening while the page fetched. To observe
traffic a page issues in response to in-page action, enter the page through
`capture` (`--match "__none__"` when the arming, not the bodies, is the point),
act, then `harvest` the matches.

## Wall handling

The harness, not the skill, classifies walls:

- **429** on an `api` fetch → exponential backoff (from 4s, doubling, capped at
  60s, up to 4 tries) → terminal `rate-limited`.
- **login / checkpoint** redirect (on `nav`/`capture`) or **401/403** on `api` →
  immediate terminal (`logged-out` / `checkpoint`).

On a terminal state the run ends; `browser-serialiser` exits 66 and the skill's
`state` shows the reason. A skill never chooses to retry a wall; the only retry
that exists is the harness's own 429 backoff.

## Diagnostics log (standalone)

The standalone host appends one tab-separated line per event to
`/var/local/log/browser-serialiser/skill.log` (override `BROWSER_SERIALISER_LOG_DIR`;
best-effort, so an unwritable directory disables it rather than failing the run):
`timestamp<TAB>pid<TAB>tag<TAB>data`, with tags `run` / `nav` / `capture` / `api`
/ `backoff` / `terminal` / `end`. Each wire-touching line carries its jittered pace
(`pace=Nms`); `nav`/`capture` carry the requested and landing URLs (query stripped);
`api` carries status and path; `terminal` carries the wall state and where it landed.
This is host-side, not a skill capability: the harness writes it from the trusted
interp, so the sandbox is untouched. It is the standalone counterpart of the
overseer's own `/log` sink, letting a ban post-mortem read the cadence and the wall
from the harness's record rather than reconstructing it from the browser History DB.
## Tray icon (standalone)

While a standalone run's process lives, it shows a system-tray icon (Tk 9's
`tk systray`; menu-bar item on macOS): an amber ring while queued for the
profile lock or pacing the inter-run gap, a teal disc while the browser is
driven, with the skill and its current query-stripped page in the tooltip.
Presence answers "is an agent on the shared profile right now"; absence means
idle, and each queued run shows its own icon, so the tray shows the queue. A
run that dies on a login wall fires a desktop notification naming the site to
log in to, since its icon vanishes with the process; the notification fires on
the overseer-delegated path too (a login wall needs the user's hand whichever
host hit it), while the icon itself stays standalone-only, the overseer being
the status surface when it runs the job. Host machinery like the diagnostics
log (`lib/serialiser-tray.tcl`), not a skill capability: nothing is added to
the verb surface. It needs Tcl/Tk 9 and a display; the harness's sh trampoline
header picks `tclsh9.0` where installed, and on a Tcl 8.6-only or headless
machine no icon or notification appears and nothing else changes.

## Cross-run spacing (standalone)

The `/tmp/chromium.lock` gives mutual exclusion (one browser on the profile at a
time; a second run queues up to 600 s for its turn) but no pacing, so back-to-back
runs would otherwise fire with no gap between them. The standalone host enforces a
minimum gap between successive runs: `lock_release` stamps the release time in
`/tmp/chromium.lastrun`, and the next `lock_acquire`, once it holds the lock, sleeps
just the remainder needed to reach `BROWSER_SERIALISER_MIN_GAP_SECS` (default 30, `0`
disables) before returning. The wait is held under the lock, so it paces the combined
rate of several concurrent sessions: they all serialise through the one lock, so a gap
held there throttles the lot. It is paid only when the previous run was recent, so an
interactive fetch after a long idle waits nothing. This is the standalone counterpart
of the overseer's cross-job rate budget, for the path outside the overseer's view;
under the overseer `browser-serialiser` delegates and takes neither this lock nor this gap.
It is a spacing floor, not a volume cap: it stretches a rapid campaign into a paced
crawl but does not bound the total a determined caller pulls.

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
