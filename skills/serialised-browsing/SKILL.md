---
name: serialised-browsing
description: "Policed browser access through `browser-serialiser`: drives the user's logged-in Chromium for any skill that reads or acts on a logged-in site, and fetches a page when curl or WebFetch cannot. Site skills invoke it by reference; the wrapper, the command surface, and the browser rationale live here."
allowed-tools: Bash, Read
argument-hint: <skill-ref and args, or a URL>
---

Canonical home of `browser-serialiser`, the harness that runs a browser skill inside a policed safe interpreter and drives the user's logged-in Chromium for it. Site-specific skills invoke it by reference; when a site skill covers the target, use that skill. This is the reference for the wrapper, the command surface, and the browser rationale, and the fallback for an ad-hoc page fetch.

## Two ways it runs

A **skill by reference** (the normal path). The serialiser loads the skill into a per-run safe interpreter that exposes only the policed verbs (navigate, fetch, dump, type, click, and the rest in COMMAND-SURFACE.md), drives the browser through them, and returns the skill's result:

```bash
browser-serialiser <site>/<script> <args>
# e.g. browser-serialiser instagram.com/ig-profile HANDLE
```

The skill never opens a socket or touches the disk: capability confinement and anti-ban pacing are enforced by the harness, not by the skill. When an overseer is running on `localhost:11402`, `browser-serialiser` delegates to it (the overseer owns the one logged-in browser, so it serialises the run with its own work); when no overseer is running, the serialiser launches its own Chromium standalone.

An **ad-hoc fetch** (the curl/WebFetch fallback). For a page no site skill covers:

```bash
browser-serialiser --dump [-t SECONDS] URL > /tmp/dump.html   # rendered DOM
browser-serialiser --pdf  [-t SECONDS] OUT URL                # print to PDF
```

Redirect a dump to a file: dumps run several MB and flood context if returned inline. Parse the file selectively, or hand it to a Haiku/Sonnet subagent, and keep raw DOM out of the main session.

## Do not blame the user's browser

The serialiser holds a single-browser lock and the overseer runs a watchdog; both classify whatever process holds the shared profile. A holder whose cmdline carries `--headless` or `--remote-debugging-port` is an agent process (yours or another session's), never a window the user opened. The user's everyday Google Chrome lives at a different user-data-dir and is irrelevant to this lock. Do not tell the user to close their browser unless a holder PID resolves to the shared Chromium profile and carries neither flag.

## Prerequisites

- `[browser] user_agent` set in `$HOME/.claude/skills/config.ini` (see `${CLAUDE_PLUGIN_ROOT}/config.ini.example`); the serialiser sends it so the fetch fingerprint matches the logged-in session.
- A logged-in Chromium session for any site that needs one. A dump that comes back as a sign-in page means the profile is wrong or another Chromium holds the lock; investigate the plumbing rather than asking the user to log in again, since they are usually already logged in.

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/serialised-browsing/COMMAND-SURFACE.md` — the verbs a skill calls and the entry convention (`serialiser_run`, one `emit`).
- `${CLAUDE_PLUGIN_ROOT}/skills/serialised-browsing/BROWSER.md` — why Chromium and the live user-data-dir.
- `${CLAUDE_PLUGIN_ROOT}/skills/serialised-browsing/chromium-process-model.md` — the Chromium process and launch facts.
