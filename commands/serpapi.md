---
description: "Google Maps places and review timelines; Google Flights or Hotels to cross-check an OTA price. Web search only when brave-search fails."
argument-hint: <search request, e.g. maps \"restaurants near New York\", or leave empty to be prompted>
allowed-tools: Bash, Read, Write
---

Search request (the command argument): **$ARGUMENTS**. Pick the matching subcommand below.

# SerpApi Search

## Usage priority

**Flights:** Use a consumer OTA (Kiwi MCP if available) first to discover prices, routing options, and the best departure airport. SerpAPI Google Flights has a smaller result set than consumer-facing OTAs, does not accept city codes (e.g. LON), and does not index all carriers (notably China Eastern is absent). Use SerpAPI to verify or supplement — for example, to retrieve airline names per leg when the OTA omits them — not to discover the cheapest fare or confirm routing possibilities. The 250 searches/month quota reinforces this: reserve calls for verification, not exploration.

**Hotels:** If a brand-specific skill or MCP exists (e.g. the ihg.com skill for IHG properties), use it in preference to SerpAPI Google Hotels. Brand skills query the hotel chain's own availability API and return accurate per-night pricing; SerpAPI aggregates and may miss IHG-member rates or loyalty discounts.

**Web search:** brave-search comes first. Use SerpAPI Google Search only when brave-search returns an error or nothing usable; each search spends the monthly quota that Maps and Flights also draw on.

**Maps:** SerpAPI is the primary tool for places and review timelines.

## Prerequisites

This skill requires a SerpApi key (free plan: 250 searches/month, sign up at serpapi.com).

- **What:** SerpApi API key
- **Where:** environment variable `SERPAPI_KEY`, or `$HOME/.config/magazines/config.ini` under `[serpapi] api_key`
- **Format:**
  ```ini
  [serpapi]
  api_key = your_key_here
  ```

Run the script without checking for the key first: when neither is set it exits with a message naming both places a key can go. Stop there and pass that message to the user, adding that serpapi.com gives a free key.

## Setup

API key is read from one of:
- Environment variable `SERPAPI_KEY`
- `$HOME/.config/magazines/config.ini` under `[serpapi] api_key`

Free plan allows 250 searches/month. Check usage (costs no search):

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py account
```

Every SerpApi call goes through `search.py`; a hand-built `curl` to serpapi.com is refused by the plugin's hook.

## Saved results

Every response is saved to `~/.cache/magazines/serpapi/`, and the script prints its path on stderr as `raw: <path>`. A field the formatted output leaves out (layovers, `price_insights`, amenities, a review's full record) is read from that file rather than by running the search again with `--json`.

An identical request is answered from the saved file while it is fresh enough, and says so: `cached: saved <time> (<age> ago)`. Pass `--fresh` when the answer must be current.

| Search | Reused for |
|---|---|
| Flights, Hotels | 6 hours |
| Maps reviews | 1 day |
| Google Search | 3 days |
| Maps places | 30 days |

Results past their window are deleted, and past 50 MB in all the oldest go first.

## Quick start

### Google Flights (one-way)

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py flights LHR BNE 2026-05-10 --currency EUR
```

### Google Flights (return)

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py flights LHR BNE 2026-05-10 --return-date 2026-05-20 --currency EUR
```

### Google Search

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py search "best noise cancelling headphones 2026"
```

### Google Maps

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py maps "restaurants near New York"
```

### Google Maps reviews (review timeline)

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py reviews "<venue name> <suburb>" --max 5
```

### Google Hotels (list, then one property's prices)

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py hotels "Gold Coast Australia hotels" 2026-04-10 2026-04-11 --brands 17 --sort 3 --currency AUD
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py hotels "Gold Coast Australia hotels" 2026-04-10 2026-04-11 --currency AUD --property-token <token>
```

## Flight search arguments

| Argument | Description |
|---|---|
| origin | Departure IATA code (e.g. LHR, SVQ, MAD) |
| destination | Arrival IATA code (e.g. BNE, SYD, MEL) |
| date | Outbound date YYYY-MM-DD |
| --return-date | Return date (omit for one-way) |
| --currency | EUR, USD, AUD, GBP etc. (default: EUR) |
| --adults N | Number of adults (default: 1) |
| --stops N | 0=any, 1=nonstop, 2=max 1 stop, 3=max 2 stops |
| --travel-class N | 1=Economy, 2=Premium economy, 3=Business, 4=First |
| --max-price N | Price cap in chosen currency |
| --json | Output raw JSON |
| --fresh | Buy a new search even when a saved one is fresh enough (every subcommand) |

## API learnings (from testing)

These notes save future agents from trial-and-error:

1. **One-way flights require `type=2`** — the script handles this automatically when `--return-date` is omitted. Without it, the API defaults to round trip and fails without a return date.

2. **IATA codes only** — the API does not resolve city names. Use IATA airport codes (LHR, BNE, SVQ). For multi-airport cities, pick the main hub or use comma-separated codes (e.g. `LHR,LGW,STN`).

3. **Response structure**: `best_flights` (Google's top picks, usually 2-4 itineraries) and `other_flights` (the rest, up to ~15). Each itinerary contains `flights[]` (legs), `layovers[]`, `total_duration` (minutes), and `price` (integer in chosen currency).

4. **Each leg** has: `departure_airport.{name, id, time}`, `arrival_airport.{name, id, time}`, `duration` (minutes), `airline`, `flight_number`, `airplane`, `legroom`, `travel_class`, `extensions[]`.

5. **Layovers** include `duration` (minutes), `name`, `id`, and `overnight` (boolean).

6. **Price field** is an integer (no decimals). Currency is whatever you passed. `price_insights` object (when present) shows `lowest_price`, `price_history`, `typical_price_range`.

7. **Rate**: each call = 1 search. Free plan = 250/month. No per-second rate limit observed, but be conservative — don't exhaust the quota on exploratory queries.

8. **Nearby airport hubs**: a small home airport often has few long-haul options, so the cheapest routing may start from a larger hub within driving or short-flight distance. Use the `maps` subcommand to list nearby airports, then compare fares from each; for example, a traveller near a small regional field might fly internationally from New York (JFK) instead, where competition on long-haul routes lowers fares.

## Search and Maps arguments

| Argument | Description |
|---|---|
| query | Search query string |
| --num N | Number of results (search only, default: 10) |
| --location | Location string (search) or lat,lng (maps) |
| --json | Raw JSON output |
| --fresh | Buy a new search even when a saved one is fresh enough |

## Google Maps reviews (review timeline)

A venue's review timeline — each review's date, star rating, and text — comes from the `google_maps_reviews` engine, which is keyed by a place `data_id` rather than a name. The `reviews` subcommand runs the full chain: `maps` → `data_id` → `google_maps_reviews`, paginating newest-first by default.

```bash
# By place name (resolves data_id via Maps first, then pages the reviews)
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py reviews "<venue name> <suburb>" --max 5

# By data_id directly (skips the lookup, saving 1 search)
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py reviews "0x...:0x..." --sort newestFirst
```

| Argument | Description |
|---|---|
| place | Place name (resolved via Maps) **or** a `data_id` (`0x...:0x...`) |
| --sort | `newestFirst` (default), `mostRelevant`, `highestRating`, `lowestRating` |
| --max N | Max review pages to fetch (default: 3; each page = 1 search) |
| --json | Raw JSON: `{data_id, place, reviews[]}` |

The raw responses behind the chain (the Maps lookup with its `data_id`, then each `google_maps_reviews` page with `iso_date`, `rating`, `snippet`, `user.name` and `serpapi_pagination.next_page_token`) are the saved files the script names on stderr.

A full timeline needs many pages; each page is 1 search against the monthly quota, so a deep walk-back is expensive. Raise `--max` deliberately; pages fetched in the last day come from the saved files.

## Google Hotels

For hotel searches (e.g. IHG availability) use the `hotels` subcommand. A search lists properties with nightly and total rate, rating, review count and `property_token`; passing a `property_token` back with `--property-token` returns that one hotel's prices by booking site. Its saved raw response also holds room types, amenities and nearby places.

| Argument | Description | Example |
|---|---|---|
| query | Search query (location + "hotels") | `"Gold Coast Australia hotels"` |
| check_in | Check-in date, YYYY-MM-DD | `2026-04-10` |
| check_out | Check-out date, YYYY-MM-DD | `2026-04-11` |
| --adults N | Number of adults (SerpApi default 2) | `1` |
| --children N | Number of children | `0` |
| --children-ages | Comma-separated ages 1-17 | `5,8` |
| --brands | Brand ID filter, comma-separated | `17` (IHG) |
| --sort | `3` lowest price, `8` highest rating, `13` most reviewed | `3` |
| --currency | Currency code | `AUD` |
| --property-token | One property's prices | from a search result |

Brand IDs: 17 IHG, 28 Hilton, 33 Accor, 46 Marriott, 53 Wyndham. Omit `--brands` to search all.

Format results as a table: hotel name, nightly price, rating, reviews.

## Typical workflows

### Flight price comparison across dates
```bash
for date in 2026-05-08 2026-05-09 2026-05-10; do
    python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py flights LHR BNE "$date" --currency EUR
done
```

### Raw JSON for programmatic processing
```bash
python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py flights LHR BNE 2026-05-10 --currency EUR --json | python3 -c "
import sys, json
d = json.load(sys.stdin)
all_flights = d.get('best_flights', []) + d.get('other_flights', [])
cheapest = min(all_flights, key=lambda f: f.get('price', 99999))
print(f'Cheapest: EUR {cheapest[\"price\"]} via {cheapest[\"flights\"][0][\"airline\"]}')
"
```
