---
name: hainanairlines.com
description: "Hainan Airlines (HU) fares and flight availability by route and date: international itineraries priced per cabin, China domestic schedules with seat counts."
argument-hint: <origin> <dest> <date YYYY-MM-DD> [--adults N] [--children N] [--json]
---

## Prerequisites

- `[browser] user_agent` in `$HOME/.config/magazines/config.ini` (serialised-browsing skill).
- No login, no credentials: the fare search is anonymous.

## Search fares (one-way)

Run through `browser-serialiser`. One call drives the site's own search form
and reads the rendered fare list:

```bash
browser-serialiser hainanairlines.com/search <origin> <dest> <date YYYY-MM-DD> [--adults N] [--children N] [--json]
browser-serialiser hainanairlines.com/search CKG MAD 2026-09-02
browser-serialiser hainanairlines.com/search PEK BRU 2026-09-15 --adults 2 --children 1
browser-serialiser hainanairlines.com/search HAK PEK 2026-09-10 --json
```

The run takes a while: the site routes every search through a "Please wait"
interstitial that reloads itself into the results.

Parameters:

- `origin`, `dest` — two different 3-letter IATA codes, case-insensitive
  (e.g. `CKG` Chongqing, `HAK` Haikou, `PEK` Beijing Capital).
- `date` — `YYYY-MM-DD`, today or later; the skill refuses a past date before
  touching the site.
- `--adults N` / `--children N` — defaults 1/0. Adults 1-9, children 0-8, at
  most 9 passengers in total.
- `--json` — structured output instead of the text table.

## Output

The site serves two result shapes, and the skill reports which it got:

- **International routes** come back priced. Per itinerary: origin/destination
  times with day offsets, total duration and stop count; each segment as
  flight number and times (partner-operated legs carry the partner's own
  flight number, e.g. `UX1040`); then one line per cabin (Economy / Business
  as sold on that itinerary) with the lowest fare and the per-fare-family
  prices (Economy Basic / Standard / Flexible, Business Saver / Choice ...),
  cheapest first, with a `(last N)` marker where fewer than nine seats remain
  at that price. A closing line gives the site's own price calendar: the
  lowest fare for each nearby date. Fares are per adult, as the site displays
  them.
- **China domestic routes** come back as a schedule-driven availability list:
  flights, times, aircraft and per-cabin seat counts (9 means nine or more),
  but no prices — the site defers pricing to flight selection, so prices are
  not in that page. The output says so explicitly.

Fares are quoted in `CNY`; that is the currency the site returns on this
storefront (AU/GB). `--json` adds aircraft types per segment, fare-family
codes, and the machine-readable calendar; its `type` field is `farePriced`
or `scheduleOnly`.

A recognised result page with no flights returns "No itineraries" / "No
flights", a normal answer.

## Failure modes

- `bad route: ...` / `bad passenger count: ...` / `bad date: ...` /
  `unknown option ...` — the arguments themselves don't satisfy Parameters
  above; no page is loaded.
- `wall: terminal state ...` — the harness classified the landing as a wall
  before the search was submitted.
- `wait page never resolved: ...` — the site's "Please wait" interstitial
  never reloaded into a result page within the allowed rounds; usually
  transient, retry later.
- `unrecognised result page: ...` — the run did not reach a page the skill
  can read: the search form never appeared, the result page dumped empty, or
  the page matched neither result shape. Only the last case carries the
  title, URL and any message the site displayed; the others carry what
  exists at that point.
- exit 66 with `browser-serialiser: terminal <state>` on stderr — the harness
  hit a wall (rate-limited, logged-out, checkpoint) and ended the run.
