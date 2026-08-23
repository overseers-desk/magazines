---
name: hainanairlines.com
description: "Hainan Airlines (HU) fares and flight availability by route and date: international itineraries priced per cabin, China domestic schedules with seat counts."
argument-hint: <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] [--children N] [--json]
---

## Prerequisites

- `[browser] user_agent` in `$HOME/.config/magazines/config.ini` (serialised-browsing skill).
- No login, no credentials: the fare search is anonymous.

## Search fares (one-way or return)

Run through `browser-serialiser`. One call drives the site's own search form
and reads the rendered fare list:

```bash
browser-serialiser hainanairlines.com/search <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] [--children N] [--json]
browser-serialiser hainanairlines.com/search CKG MAD 2026-09-02
browser-serialiser hainanairlines.com/search CKG MAD 2026-09-02 --return 2026-09-09
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
- `--return YYYY-MM-DD` — search the round trip `origin → dest → origin`; the
  return date may not precede the outbound date.
- `--adults N` / `--children N` — defaults 1/0. Adults 1-9, children 0-8, at
  most 9 passengers in total.
- `--json` — structured output instead of the text table.

## Output

The site serves two result shapes, and the skill reports which it got:

- **International routes** come back priced. One-way: per itinerary,
  origin/destination times with day offsets, total duration and stop count;
  each segment as flight number and times (partner-operated legs carry the
  partner's own flight number, e.g. `UX1040`); then one line per cabin
  (Economy / Business as sold on that itinerary) with the lowest fare and the
  per-fare-family prices (Economy Basic / Standard / Flexible, Business
  Saver / Choice ...), cheapest first, with a `(last N)` marker where fewer
  than nine seats remain at that price. A closing line gives the site's own
  price calendar: the lowest fare for each nearby date. One-way fares are per
  adult, as the site displays them.
- **International returns** come back as one whole-journey answer: the site
  prices a return as combinations of one outbound and one return flight, and
  every fare in this output is such a combination's total. The output lists
  the outbound flights (`O1`, `O2` ...), the return flights (`R1` ...), then
  per flight pair the whole-journey fares by cabin, cheapest pair first;
  where the two directions carry different fare families the fare is labelled
  with both (`Business Choice + Business Saver`). Return totals cover the
  whole party, not one adult (verified: a 2-adult search prices every
  combination at exactly twice its 1-adult total). No price calendar in
  return mode.
- **China domestic routes** come back as a schedule-driven availability list:
  flights, times, aircraft and per-cabin seat counts (9 means nine or more),
  but no prices — the site defers pricing to flight selection, so prices are
  not in that page. The output says so explicitly. A domestic return lists
  the two directions as separate Outbound / Return schedule sections.

Fares are quoted in `CNY`; that is the currency the site returns on this
storefront (AU/GB). `--json` adds aircraft types per segment, fare-family
codes, and (one-way) the machine-readable calendar; its `type` field is
`farePriced` or `scheduleOnly` and its `trip` field `one-way` or `return`.
A priced return's JSON carries `outboundFlights`, `returnFlights` and
`combinations` (each with both flight indices, cabin, fare families, total,
base/tax split, seats); a domestic return carries `outboundItineraries` /
`returnItineraries`.

A recognised result page with no flights returns "No itineraries" / "No
flights", a normal answer.

## Failure modes

- `bad route: ...` / `bad passenger count: ...` / `bad date: ...` /
  `unknown option ...` — the arguments themselves don't satisfy Parameters
  above; no page is loaded.
- `wait page never resolved: ...` — the site's "Please wait" interstitial
  never reloaded into a result page within the allowed rounds; usually
  transient, retry later.
- `return search answered with N bound(s) instead of 2: ...` — a `--return`
  search reached a result page whose payload does not carry both directions;
  rather than print one leg under a whole-journey heading, the skill reports
  the mismatch.
- `unrecognised result page: ...` — the run did not reach a page the skill
  can read: the search form never appeared, the result page dumped empty, or
  the page matched neither result shape. Only the last case carries the
  title, URL and any message the site displayed; the others carry what
  exists at that point.
- exit 66 with `browser-serialiser: terminal <state>` on stderr, or 77 when that state is a login or checkpoint redirect — the harness
  hit a wall (rate-limited, logged-out, checkpoint) and ended the run.
