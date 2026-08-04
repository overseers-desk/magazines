---
name: csair.com
description: "China Southern (CZ) fares and itinerary availability by route and date, including China domestic + international through-fares OTAs do not price."
argument-hint: <origin> <dest> <date YYYY-MM-DD> [--adults N] [--children N] [--infants N] [--currency CCC] [--json]
---

## Prerequisites

- `[browser] user_agent` in `$HOME/.config/magazines/config.ini` (serialised-browsing skill).
- No login, no credentials: the fare search is anonymous.

## Search fares (one-way)

Run through `browser-serialiser`. One call navigates the booking deep link and
harvests the fare payload the page fetches for itself:

```bash
browser-serialiser csair.com/search <origin> <dest> <date YYYY-MM-DD> [--adults N] [--children N] [--infants N] [--currency CCC] [--json]
browser-serialiser csair.com/search BNE MAD 2026-08-26
browser-serialiser csair.com/search LHW MAD 2026-08-26 --children 1
browser-serialiser csair.com/search BNE MAD 2026-08-26 --currency EUR --json
```

Parameters:

- `origin`, `dest` — two different 3-letter IATA city or airport codes,
  case-insensitive. City codes work (e.g. `LHW` Lanzhou, `CAN` Guangzhou).
- `date` — `YYYY-MM-DD`. The booking app accepts today+2 days through
  today+1 year; the skill refuses a date outside that window before touching
  the site.
- `--adults N` / `--children N` / `--infants N` — defaults 1/0/0. Adults at
  least 1, infants at most the adult count, each count a single digit, at
  most 9 passengers in total.
- `--currency CCC` — 3-letter display currency (e.g. `EUR`); omitted, the site
  picks its default for the route.
- `--json` — structured output instead of the text table.

## Output

Per itinerary: origin/destination times with day offsets, total duration and
stop count; each segment as marketing flight, operating carrier where
codeshared (`CZ2130 (op OQ2130) LHW 12:30 → CAN 15:55`), and times; then one
line per offered cabin (Economy / PremiumEconomy / Business / First as sold on
that itinerary) with the lowest total and the per-brand totals
(STANDARD / FLEX / FULLFLEX), cheapest first. All amounts cover the whole
party, not one passenger. `--json` adds the fare/tax split per cabin and
brand, and aircraft types per segment.

A route/date combination the booking app serves but has no seats for, returns
"No itineraries", a normal answer.

## Failure modes

- `bad route: ...` / `bad passenger count: ...` / `bad currency: ...` /
  `bad date: ...` / `unknown option ...` — the arguments themselves don't
  satisfy Parameters above; usage is echoed and no page is loaded.
- `date out of window: ...` — the date is outside today+2 .. today+1 year;
  emitted without any page load.
- `parameters rejected: ...` — the booking app dropped back to its empty
  search form instead of the fare page, its behaviour for a deep link it will
  not price; the landing URL is included.
- `no fare payload: ...` — the fare page loaded but its search response did
  not arrive within the capture window; usually transient, retry later.
- `unexpected fare payload: ...` — a search response arrived but did not
  parse into the known `ita` shape; the site's payload format may have
  changed.
- exit 66 with `browser-serialiser: terminal <state>` on stderr — the harness
  hit a wall (rate-limited, logged-out, checkpoint) and ended the run.
