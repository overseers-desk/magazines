---
name: xiamenair.com
description: "Xiamen Airlines (MF) fares and seat availability — one-way, return or multi-city — by route and date, international and China domestic, with per-fare-family totals, booking class and seat counts."
argument-hint: <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] [--cabin ...] [--json] | --leg DEP-ARR-YYYY-MM-DD (2 to 5 times)
allowed-tools: Bash, Read
---

# xiamenair.com

Xiamen Airlines' booking site prices flights through an open API at
`https://int-et.xiamenair.com/tRetailAPISolution`, which answers plain HTTPS:
`POST /flight/resultSets` submits the search and returns a result-set id,
`GET /flight/resultSets/{id}` returns the fares. The script below drives both
calls. The POST body's `bounds` array sets the trip shape: one bound is a
one-way, two a return or two-leg multi-city, up to the API's cap of five.

## Prerequisites

None. No credentials, no config keys: the fare search is two anonymous HTTPS
calls.

## Required headers

Both calls need this pair or the API answers 400:

```
Accept-Language: en-AU
Market-Country-Code: AU
```

`Accept-Language` names the point-of-sale locale and the API matches it
case-sensitively against its supported list: `en-AU` works, `en-au` and
`en-US` do not. `Market-Country-Code` is that locale's country; with it
missing the API reports "Unsupported Locale", blaming the other header. No
cookie, token, or user agent is required.

## Search fares

```bash
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] [--children N] [--infants N] [--cabin ECONOMY|BUSINESS|FIRST|ANY] [--pos locale:country:currency] [--json]
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py --leg DEP-ARR-YYYY-MM-DD --leg DEP-ARR-YYYY-MM-DD [--leg ... up to 5] [same options]
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py SYD XMN 2026-08-25
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py XMN LHW 2026-08-25 --children 1 --json
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py SYD XMN 2026-09-10 --return 2026-09-24
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py --leg BNE-LHW-2026-09-08 --leg LHW-MAD-2026-09-15
```

Parameters:

- `origin`, `dest` — two different 3-letter IATA codes, case-insensitive.
- `date` — `YYYY-MM-DD`, today or later; a past date is refused before any
  request.
- `--return YYYY-MM-DD` — date of the back leg (`dest` → `origin`), on or
  after `date`; makes the search a return, priced as one journey.
- `--leg DEP-ARR-YYYY-MM-DD` — one multi-city leg; give 2 to 5 (the API caps
  bounds at 5, `OJ-01-0624` on a sixth), dates in travel order. `--leg`
  replaces the positional route and excludes `--return`. Legs need not
  connect: the second leg may start anywhere.
- `--adults N` / `--children N` / `--infants N` — defaults 1/0/0. Adults at
  least 1, infants at most the adult count, at most 5 passengers in total
  (the API's own cap).
- `--cabin` — `ECONOMY` (default), `BUSINESS`, `FIRST`, or `ANY`. `ANY`
  returns every fare family the itinerary sells, economy through first, in
  one answer.
- `--pos locale:country:currency` — the point of sale, default
  `en-AU:AU:AUD`. The API sells each point of sale in its own currency, so the
  three parts travel together: the locale, its country, and that
  point of sale's currency (`en-PH:PH:PHP` is another working point of sale).
  `zh-CN:CN:CNY` is rejected by these hosts (`OJ-04-0090`), so China
  domestic legs price in the point of sale's foreign currency, not CNY.
- `--json` — structured output instead of the text table.

## Output

One block per itinerary. A one-way block opens with origin/destination times
(day offsets where the arrival crosses midnight), duration, stop count; a
return or multi-city block has one such line per leg, labelled `out`/`back`
or `leg 1`..`leg 5` with the leg's date, day offsets counted from that leg's
own date. Under each leg line, its segments: marketing flight with the
operating flight where they differ (`(op ...)`), times, aircraft type.

Then one line per fare, cheapest first. A fare prices the whole journey, all
legs together — a return is one fare, not two one-ways added up. Each line
carries the fare family (e.g. ECONOMY STANDARD/ELITE/FLEX), total, base + tax
split, cabin, booking class, and seats left at that fare (the tightest
segment's count across the journey). On a multi-leg journey the booking
classes are grouped per leg, separated by `|` (`rbd R | L`: R out, L back).
China domestic and some through-fares arrive without a fare-family name; the
line shows `—`. All amounts cover the whole party, not one passenger.

An itinerary the API lists but does not price at the point of sale is shown
without fare lines. A route/date combination with no flights answers
`totalResults: 0` on the POST itself (the follow-up GET would 404); the
script prints "No itineraries", a normal answer, exit 0. Two-leg journeys
whose combination has flights but no through-fare answer the same way (seen
live: BNE-XMN + XMN-LHW + LHW-XMN + XMN-BNE), so a "No itineraries" on a
multi-city does not mean the individual legs are unserved.

`--json` returns `tripType` (`one-way`/`return`/`multi-city`), the requested
`bounds`, and `itineraries[]` each carrying `legs[]` (per-leg endpoints,
times, duration, stops, segments with terminals and segment ids) and
`fares[]` (whole-journey totals, per-segment booking info, per-passenger-type
fare split), plus a `priced` flag.

## Failure modes

- `bad route: ...` / `bad date: ...` / `bad leg: ...` / `bad leg order: ...` /
  `bad arguments: ...` / `bad passenger count: ...` / `bad point of sale: ...`
  — exit 2, the arguments don't satisfy Parameters above; printed without any
  request.
- `unsupported point of sale: ...` — exit 3, the API rejected the
  locale/market/currency combination (its error code is echoed).
- `request rejected: ...` — exit 3, the API refused the search for another
  reason; the HTTP status and its error message are echoed.
- `transport failure: ...` — exit 4, the host was unreachable or answered
  outside its error format; usually transient, retry later (a stray
  "Connection reset by peer" was seen once on the GET and the retry
  succeeded).
- `unexpected payload: ...` — exit 5, an answer arrived but not in the known
  shape; the API's format may have changed.
