---
name: beatthatflight.com.au
description: "Cheapest fares on any route worldwide, shopped across dozens of online agencies at once: one-way, return or multi-city, with the agency's booking link."
argument-hint: <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] [--children N] [--infants N] [--cabin CABIN] [--currency CCC] [--limit N] [--json] | --leg DEP-ARR-YYYY-MM-DD (2 to 5 times)
allowed-tools: Bash, Read
---

# beatthatflight.com.au

Flight search answering the shape in `FLIGHT-SEARCH.md`. This is a metasearch,
not an airline: each itinerary comes with the agency selling it and that
agency's booking link.

The site's own search is a Travelpayouts (Aviasales) white-label at
`book.beatthatflight.com.au`, so the calls go to the Travelpayouts flight API
carrying beatthatflight's public affiliate marker, which the script reads from
that page's `window.TPWL_EXTRA` on each run (marker `171356`, hardcoded as the
fallback, if the page cannot be read).

## Prerequisites

None. No credentials, no config keys, no browser: every call is an anonymous
HTTPS request.

## Search

```bash
${CLAUDE_PLUGIN_ROOT}/skills/beatthatflight.com.au/search.py SYD MEL 2026-10-14
${CLAUDE_PLUGIN_ROOT}/skills/beatthatflight.com.au/search.py BNE LHR 2026-11-05 --return 2026-11-19 --limit 5
${CLAUDE_PLUGIN_ROOT}/skills/beatthatflight.com.au/search.py BNE TBS 2026-09-05 --currency EUR --json
${CLAUDE_PLUGIN_ROOT}/skills/beatthatflight.com.au/search.py --leg SYD-MEL-2026-10-14 --leg MEL-BNE-2026-10-18 --leg BNE-SYD-2026-10-22
```

A search takes 20 to 70 seconds. The API collects agency responses in the
background and the script polls until the API says the responses are all in,
so a busy long-haul route is slower than a domestic one.

## Parameters

Departures from the contract, and the site's caps:

- `--currency` omitted does not mean no currency preference. The API rejects a
  search with no currency (`400 invalid-currency`, "currency should not be
  empty"), so the omitted case sends the white-label's own configured display
  currency, AUD, read live from the same page as the marker. That is the
  currency a visitor to the site is quoted in. `--currency CCC` is passed
  through and the prices come back converted, verified with EUR.
- `--adults` at most 9, `--children` at most 9, `--infants` at most the adult
  count. All three caps are the API's own, checked here so the caller does not
  pay for a round trip to be told.
- `--cabin`: `ECONOMY`, `PREMIUM_ECONOMY`, `BUSINESS` and `FIRST` map to the
  API's `Y`, `W`, `C`, `F`. Only ECONOMY was run end to end; the other three
  are accepted by the search endpoint but their results are unverified.
- `--leg` takes 2 to 5 legs, the contract's cap. The API itself accepts up to
  6 directions and refuses 7.
- An origin or destination is looked up before the search, so a code the site
  does not know is refused with `bad route:`. A code that names both an
  airport and a city (`MEL`) is searched as the airport; a city-only code
  (`LON`, `TBS`) is searched as the whole metro area.
- Booking links are fetched for the `--json` answer only, one request per
  itinerary shown; the text answer names the agency and leaves the link to
  `--json`. `--no-booking-urls` (an addition, not in the contract) skips those
  requests when only prices matter.

## Output

The contract's keys, plus these named extras per itinerary:

- `proposalId` the API's id for this agency's offer on this itinerary
- `pricePerPerson` the same total divided by the party
- `baggageIncluded` `{checked, handbags}` piece counts in the quoted fare
- `transferWarnings` connection cautions the API flags: an overnight layover,
  a connection in a third country, baggage rechecked, an airport change
- `sellerCount` how many agencies sell this same itinerary. `price`, `seller`
  and `bookingUrl` are the cheapest of them.

Each segment carries `fareCode`, the agency's fare basis for that flight.

`totalResults` is the whole pool the API found. The script reads one page of
at most 200 of them, so a `--limit` above 200 returns 200.

## Failure modes

- `bad route:` / `bad date:` / `bad leg:` / `bad passenger count:` /
  `bad cabin:` / `bad currency:` / `bad arguments:`, exit 2. Nothing sent,
  except the code lookup behind `bad route:`.
- `request rejected:`, exit 3. The API refused the search and its own
  `type` and `message` are echoed, for example `invalid-trip-class` or
  `invalid-currency`. A 401 or 403 here means the affiliate marker or the
  request signature was not accepted, which is what a change on the site's
  page would look like.
- `transport failure:`, exit 4. Host unreachable, a 5xx, or the search never
  finished within 40 polls.
- `unexpected payload:`, exit 5. An answer arrived in a shape the script does
  not know, such as a finished search carrying no results chunk. The API has
  changed.
- `No itineraries`, exit 0, is a normal answer for a route and date with
  nothing on it.
