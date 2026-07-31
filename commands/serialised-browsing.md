---
description: "use a headless Chromium to fetch a page when curl or WebFetch cannot, in-built burst access prevention. Also accepts CDP. Activated when a website blocks fetching or gives 403, or any situation that actual browser is needed for access."
allowed-tools: Bash, Read
argument-hint: <skill-ref and args, or a URL>
---

Request (the command argument): **$ARGUMENTS**. A `<site>/<script>` skill-ref with its args, or a URL to fetch; if empty, treat this as a reference read.

Canonical home of `browser-serialiser`, the harness that runs a browser skill inside a policed safe interpreter and drives the user's logged-in Chromium for it. Site-specific skills invoke it by reference; when a site skill covers the target, use that skill. This is the reference for the wrapper, the command surface, and the browser rationale, and the fallback for an ad-hoc page fetch.

## Two ways it runs

A **skill by reference** (the normal path). The serialiser loads the skill into a per-run safe interpreter that exposes only the policed verbs (`nav`, `api`, `capture`, `dump`, `type`, `click`, and the rest in COMMAND-SURFACE.md), drives the browser through them, and returns the skill's result:

```bash
browser-serialiser <site>/<script> <args>
# e.g. browser-serialiser instagram.com/ig-profile HANDLE
```

The skill never opens a socket or touches the disk: capability confinement and anti-ban pacing are enforced by the harness, not by the skill. Who drives the browser is decided per run, by the handshake below.

An **ad-hoc fetch** (the curl/WebFetch fallback). For a page no site skill covers:

```bash
browser-serialiser --dump [-t SECONDS] URL > /tmp/dump.html   # rendered DOM
browser-serialiser --pdf  [-t SECONDS] OUT URL                # print to PDF
```

Redirect a dump to a file: dumps run several MB and flood context if returned inline. Parse the file selectively, or hand it to a Haiku/Sonnet subagent, and keep raw DOM out of the main session.

## Working beside an overseer

One logged-in Chromium profile serves every agent on the machine, so `browser-serialiser` and an overseer (a resident broker that owns the profile while it runs, answering on `127.0.0.1:11402`, or the port in `BI_OVERSEER_PORT`) must never launch on it at once. The serialiser needs nothing from the caller for this; the handshake is built in:

- **Overseer up at entry**: the run delegates. A skill-ref goes to the overseer's `POST /run`, a `--dump` to its `POST /browser/dump`; the overseer serialises the run with its own work and paces it per host. The overseer then owns the outcome: a fault comes back as this run's failure, and the serialiser does not launch its own Chromium to retry.
- **No overseer**: the run is standalone. It queues on the profile lock (`/tmp/chromium.lock`, a PID-stamped exclusive-create file; a waiter sweeps a holder whose PID is dead), launches its own headless Chromium on the logged-in profile, and tears it down on every exit path.
- **Overseer arrives mid-wait**: the who-launches decision is remade when the lock is won, the moment before a launch would happen. The run releases the lock and delegates as above, so a backlog parked on the lockfile drains into an overseer that started while it waited. Release comes first because the overseer parks its own launches while the lockfile is held; delegating while holding it would deadlock both sides.
- **Overseer arrives mid-run**: nothing changes for this run. The overseer starts parked beside a live standalone browser, holds its browser jobs, and takes over when the run's teardown frees the profile.
- **`--pdf`**: the overseer has no PDF door, so this mode always runs standalone under the lock, which the overseer honours for the run's whole span.

So it is safe to start a run while no overseer is up, and safe for an overseer to start at any point after; neither side needs the other stopped first. The overseer's half of the contract is enforced where the overseer is built, not here.

## Do not blame the user's browser

The serialiser holds a single-browser lock and the overseer runs a watchdog; both classify whatever process holds the shared profile. A holder whose cmdline carries `--headless` or `--remote-debugging-port` is an agent process (yours or another session's), never a window the user opened. The user's everyday Google Chrome lives at a different user-data-dir and is irrelevant to this lock. Do not tell the user to close their browser unless a holder PID resolves to the shared Chromium profile and carries neither flag.

## Prerequisites

- `[browser] user_agent` set in `$HOME/.config/magazines/config.ini` (see `${CLAUDE_PLUGIN_ROOT}/config.ini.example`); the serialiser sends it so the fetch fingerprint matches the logged-in session.
- A logged-in Chromium session for any site that needs one. A dump that comes back as a sign-in page means the profile is wrong or another Chromium holds the lock; investigate the plumbing rather than asking the user to log in again, since they are usually already logged in.

## References

- `${CLAUDE_PLUGIN_ROOT}/COMMAND-SURFACE.md` — the verbs a skill calls and the entry convention (`serialiser_run`, one `emit`).
- `${CLAUDE_PLUGIN_ROOT}/docs/BROWSER.md` — why Chromium and the live user-data-dir.
- `${CLAUDE_PLUGIN_ROOT}/docs/chromium-process-model.md` — the Chromium process and launch facts.
