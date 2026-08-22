---
name: kiwi.com
description: Cheapest flights across airlines that do not interline, including self-transfer combinations no airline or OTA sells, priced for the whole party.
argument-hint: <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] [--children N] [--infants N] [--cabin ECONOMY|PREMIUM_ECONOMY|BUSINESS|FIRST] [--currency CCC] [--limit N] [--json]
allowed-tools: Bash, Read
---

# kiwi.com

Kiwi's own front end reads a public GraphQL endpoint,
`https://api.skypicker.com/umbrella/v2/graphql`, which answers anonymously
over plain HTTPS. `content-type: application/json` is the only header it
needs. The script below resolves the route's codes to Kiwi place ids and runs
the search, two requests in all.

The query and the answer follow `FLIGHT-SEARCH.md`. What follows is only where
this site departs from it.

## Prerequisites

None. No credentials, no config keys, no browser.

## Search fares

```bash
${CLAUDE_PLUGIN_ROOT}/skills/kiwi.com/search.py SYD MEL 2026-10-14
${CLAUDE_PLUGIN_ROOT}/skills/kiwi.com/search.py BNE LHR 2026-11-05 --return 2026-11-19 --limit 5
${CLAUDE_PLUGIN_ROOT}/skills/kiwi.com/search.py BNE TBS 2026-09-05 --currency AUD --json
${CLAUDE_PLUGIN_ROOT}/skills/kiwi.com/search.py BNE LON 2026-11-05 --cabin BUSINESS --adults 2
```

## Parameters

- `origin`, `dest` — an airport code resolves to that airport; a code Kiwi
  knows only as a metro area resolves to the whole city, so `LON` searches
  every London airport at once. Resolution is a `places` lookup, and a code
  Kiwi does not know is refused with `bad route:`.
- `--currency CCC` — passed through, and the answer comes back in it (`AUD`
  and `EUR` exercised live). Omitted, the endpoint quotes **EUR**, whatever
  the route or market; the text header and the JSON `currency` say which
  currency the numbers are in either way.
- `--limit N` — the endpoint returns at most 50 itineraries per search, so a
  larger `--limit` still shows 50. `totalResults` is Kiwi's pool count for the
  search, and it saturates at 50 as well: a big route reports 50 rather than
  the true total.
- `--adults` / `--children` — at most 9 adults and children in total. A larger
  party comes back empty from the endpoint, so the cap is enforced at
  validation instead.
- `--cabin` — all four contract cabins are sold. `FIRST` maps to Kiwi's
  `FIRST_CLASS`. Kiwi may still return a mixed-cabin itinerary; each
  segment's own cabin is in the JSON as `segments[].cabinClass`.
- `--leg` multi-city — wired to the endpoint's `multicityItineraries` field,
  but that field answered 0 itineraries for every anonymous search tried,
  including city pairs its one-way field prices freely. The text answer says
  so under `No itineraries`. Treat multi-city as unusable here and price the
  legs as separate one-ways.

## Output

The contract's keys, plus these, per itinerary:

- `selfTransfer` — true where Kiwi has stitched carriers together itself
  (virtual interlining). The traveller collects bags, clears immigration and
  checks in again at that connection, and a missed connection is covered by
  the Kiwi Guarantee rather than by an airline. The text answer prints a
  `self-transfer:` line for such an itinerary.
- `pnrCount` — how many separate tickets the itinerary is. Above 1 means
  separate bookings under one Kiwi order.
- `bagsIncluded` — `{handBags, checkedBags}`, the pieces in the quoted price.
  Prices are quoted with no bags bought, so the cheapest rows are usually
  hand-baggage only or nothing at all. A bag is priced later in Kiwi's
  booking flow and is not in these totals.
- `bookingOptions[]` — every seller Kiwi lists for the itinerary, each with
  `seller`, `price` and `bookingUrl`. The contract's `seller` and
  `bookingUrl` are the first, which is the cheapest. The URL is a kiwi.com
  deep link roughly a kilobyte long, carrying the booking token; the text
  answer names the seller only and leaves the link to `--json`.
- `segments[].cabinClass` and `segments[].selfTransferBefore` — the cabin
  actually sold on that segment, and whether the connection before it is the
  self-transfer.

Two shapes to know when reading amounts and times. `equipment` is always
null: the endpoint carries no aircraft type. On a return or multi-city,
`durationMinutes` is the sum of the legs' elapsed times, which is Kiwi's own
figure, not the wall-clock span from the first departure to the last arrival.

## Failure modes

- `bad route:` / `bad date:` / `bad leg:` / `bad passenger count:` /
  `bad cabin:` / `bad currency:` / `bad arguments:` — exit 2, refused before
  any request. `bad route:` also covers a code the `places` lookup cannot
  match. Dates more than a year out are refused: Kiwi does not sell that far.
- `request rejected:` — exit 3, the endpoint refused the search: an HTTP 4xx
  or 5xx with the GraphQL error text echoed, or an `AppError` result with its
  code and message.
- `transport failure:` — exit 4, the host was unreachable, timed out, or
  answered something that is not JSON. Usually transient.
- `unexpected payload:` — exit 5, an answer arrived but the schema no longer
  matches the query (a GraphQL validation complaint, or a result without an
  itineraries list). The endpoint is versionless and changes without notice.
- No throttling was seen across the runs behind this file, some 30 searches
  in a few minutes, and there is no auth to lose. A `request rejected:` burst
  would be the first sign that changed.
