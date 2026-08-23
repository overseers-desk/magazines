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

## Return and multi-city: whole-journey fares (not yet fired end to end)

The leg-walking described below was written from the app's own code and has
never completed a live run: the site's search quota refused every attempt on
the night it was built. Treat its numbers as unconfirmed until someone
watches one journey through, and check a total against the same legs queried
separately before trusting it. The one-way path above is unaffected and is
verified.


`--return YYYY-MM-DD` adds the back leg; a repeatable `--leg DEP-ARR-YYYY-MM-DD`
(2 to 5 of them, replacing the positional route) makes a multi-city journey:

```bash
browser-serialiser csair.com/search LHW CAN 2026-08-26 --return 2026-09-02
browser-serialiser csair.com/search --leg BNE-CAN-2026-08-23 --leg CAN-LHW-2026-08-24 --json
```

The site prices a multi-leg journey the way its UI does, one leg at a time:
each search covers one leg, and selecting an option unlocks the next leg's
grid (`/api/shop/next`), whose amounts are cumulative running totals. The
skill walks that flow in one run: every leg before the last is fixed to its
cheapest bookable option, and the output is the final leg's options, each
amount the whole-journey total for the party. The fixed selections are echoed
(flights, cabin, brand) without amounts, since a non-final leg's numbers are
not a whole-journey fare. `--json` puts them in `selectedLegs` and the
whole-journey rows in `journeyOptions`.

A multi-leg query costs one site search plus one next-leg request per later
leg, so it draws the same quota as its legs queried separately; the quota
notes under Failure modes apply unchanged.

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
- `no fare payload: ...` — the fare page loaded but its search response (or,
  for a multi-leg query, the decryptArgs response the next-leg requests need)
  did not arrive within the capture window; usually transient, retry later.
- `next-leg request refused: ...` — a later leg's `/api/shop/next` call
  answered with an HTTP status instead of a fare grid; the refusal envelopes
  below can also arrive on these calls and are reported the same way.
- `rate-limited by csair.com (CZWEB000010 / CZWEB000003): ...` — the site
  answered the search with its IP-quota refusal instead of fares (HTTP 200
  with a tiny JSON envelope). `CZWEB000010` means the site is demanding a
  captcha for this IP; `CZWEB000003` is its escalation when queries continue,
  and then covers the fare-calendar endpoint too. Repeating the search
  prolongs the block: leave the site alone and retry much later. Roughly
  twenty searches inside one evening triggered it.
- `search refused by csair.com (CZWEBnnnnnn): ...` — a refusal envelope with
  a code this skill does not know; the desc is echoed ASCII-sanitised.
- `unexpected fare payload: ...` — a search response arrived but did not
  parse into the known `ita` shape; the site's payload format may have
  changed.
- exit 66 with `browser-serialiser: terminal <state>` on stderr, or 77 when that state is a login or checkpoint redirect — the harness
  hit a wall (rate-limited, logged-out, checkpoint) and ended the run.
