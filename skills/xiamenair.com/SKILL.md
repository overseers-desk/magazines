---
name: xiamenair.com
description: "Xiamen Airlines (MF) fares and seat availability by route and date, international and China domestic, with per-fare-family totals, booking class and seat counts."
argument-hint: <origin> <dest> <date YYYY-MM-DD> [--adults N] [--children N] [--infants N] [--cabin ECONOMY|BUSINESS|FIRST|ANY] [--pos en-AU:AU:AUD] [--json]
allowed-tools: Bash, Read
---

# xiamenair.com

Xiamen Airlines' booking site prices flights through an open API at
`https://int-et.xiamenair.com/tRetailAPISolution`, which answers plain HTTPS:
`POST /flight/resultSets` submits the search and returns a result-set id,
`GET /flight/resultSets/{id}` returns the fares. The script below drives both
calls.

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

## Search fares (one-way)

```bash
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py <origin> <dest> <date YYYY-MM-DD> [--adults N] [--children N] [--infants N] [--cabin ECONOMY|BUSINESS|FIRST|ANY] [--pos locale:country:currency] [--json]
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py SYD XMN 2026-08-25
${CLAUDE_PLUGIN_ROOT}/skills/xiamenair.com/search.py XMN LHW 2026-08-25 --children 1 --json
```

Parameters:

- `origin`, `dest` — two different 3-letter IATA codes, case-insensitive.
- `date` — `YYYY-MM-DD`, today or later; a past date is refused before any
  request.
- `--adults N` / `--children N` / `--infants N` — defaults 1/0/0. Adults at
  least 1, each count 0–9, infants at most the adult count.
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

One block per itinerary: origin/destination times with day offsets where the
arrival crosses midnight, duration, stop count; each segment as marketing
flight with the operating flight where they differ (`(op ...)`), times,
aircraft type; then one line per fare family (e.g. ECONOMY
STANDARD/ELITE/FLEX), cheapest first, with the total, base + tax split,
cabin, booking class, and seats left at that fare (the tightest segment's
count, on a multi-segment itinerary). China domestic fares can
arrive without a fare-family name; the line shows `—`. All amounts cover the
whole party, not one passenger.

An itinerary the API lists but does not price at the point of sale is shown
without fare lines. A route/date with no flights at all returns
"No itineraries", a normal answer, exit 0.

`--json` adds terminals, segment ids, the per-passenger-type fare split, and
a `priced` flag per itinerary.

## Failure modes

- `bad route: ...` / `bad date: ...` / `bad passenger count: ...` /
  `bad point of sale: ...` — exit 2, the arguments don't satisfy Parameters
  above; printed without any request.
- `unsupported point of sale: ...` — exit 3, the API rejected the
  locale/market/currency combination (its error code is echoed).
- `request rejected: ...` — exit 3, the API refused the search for another
  reason; the HTTP status and its error message are echoed.
- `transport failure: ...` — exit 4, the host was unreachable or answered
  outside its error format; usually transient, retry later.
- `unexpected payload: ...` — exit 5, an answer arrived but not in the known
  shape; the API's format may have changed.
