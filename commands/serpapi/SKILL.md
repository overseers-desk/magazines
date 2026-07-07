---
name: serpapi
description: "SerpApi (Google Flights/Search/Maps/Hotels): web search, local business lookup; secondary/verification source for flights and hotels — not primary for flight prices or hotel brand searches."
allowed-tools: Bash, Read, Write
---

# SerpApi Search

## Usage priority

**Flights:** Use a consumer OTA (Kiwi MCP if available) first to discover prices, routing options, and the best departure airport. SerpAPI Google Flights has a smaller result set than consumer-facing OTAs, does not accept city codes (e.g. LON), and does not index all carriers (notably China Eastern is absent). Use SerpAPI to verify or supplement — for example, to retrieve airline names per leg when the OTA omits them — not to discover the cheapest fare or confirm routing possibilities. The 250 searches/month quota reinforces this: reserve calls for verification, not exploration.

**Hotels:** If a brand-specific skill or MCP exists (e.g. the ihg.com skill for IHG properties), use it in preference to SerpAPI Google Hotels. Brand skills query the hotel chain's own availability API and return accurate per-night pricing; SerpAPI aggregates and may miss IHG-member rates or loyalty discounts.

**Web search and maps:** SerpAPI is the primary tool — no alternative skill covers these.

## Prerequisites

This skill requires a SerpApi key (free plan: 250 searches/month, sign up at serpapi.com).

- **What:** SerpApi API key
- **Where:** environment variable `SERPAPI_KEY`, or `$HOME/.claude/skills/config.ini` under `[serpapi] api_key`
- **Format:**
  ```ini
  [serpapi]
  api_key = your_key_here
  ```

If neither is present, pause and let the user know: "To use SerpApi, set the SERPAPI_KEY environment variable or add `api_key` under `[serpapi]` in `$HOME/.claude/skills/config.ini`. Sign up at serpapi.com for a free key."

## Setup

API key is read from one of:
- Environment variable `SERPAPI_KEY`
- `$HOME/.claude/skills/config.ini` under `[serpapi] api_key`

Free plan allows 250 searches/month. Check usage at: `curl -s "https://serpapi.com/account.json?api_key=$(python3 -c "import configparser,pathlib; cp=configparser.ConfigParser(); cp.read(pathlib.Path.home()/'.claude/skills/config.ini'); print(cp['serpapi']['api_key'])")" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Used: {d[\"this_month_usage\"]}/250, Left: {d[\"total_searches_left\"]}')"`

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

### The chain, by hand

The subcommand wraps these two steps; run them manually only when you need the raw response.

1. **Find the place and its `data_id`.** The `maps` subcommand with `--json` returns the raw API response, where `local_results[0]` carries `data_id` (plus `place_id`, `rating`, and the `reviews` count). A strong single match instead arrives as `place_results`.

   ```bash
   python3 ${CLAUDE_PLUGIN_ROOT}/commands/serpapi/search.py maps "<venue name> <suburb>" --json
   # local_results[0].data_id  ->  0x...:0x...
   ```

2. **Pull reviews via the reviews engine**, paginating for older reviews:

   ```bash
   SERPAPI_KEY=$(python3 -c "import configparser,pathlib; cp=configparser.ConfigParser(); cp.read(pathlib.Path.home()/'.claude/skills/config.ini'); print(cp['serpapi']['api_key'])")
   curl -s "https://serpapi.com/search.json?engine=google_maps_reviews&data_id=<data_id>&sort_by=newestFirst&api_key=$SERPAPI_KEY"
   # reviews[] each with iso_date + rating + snippet + user.name
   # serpapi_pagination.next_page_token  ->  pass as next_page_token= for the next (older) page
   ```

A full timeline needs many pages; each page is 1 search against the monthly quota, so a deep walk-back is expensive. Raise `--max` deliberately.

## Google Hotels (curl-based)

For hotel searches (e.g. IHG availability), use the SerpApi Google Hotels engine directly via curl. The API key is read from `~/.claude/skills/config.ini` (`[serpapi] api_key`).

### Search for hotels

```bash
SERPAPI_KEY=$(python3 -c "import configparser,pathlib; cp=configparser.ConfigParser(); cp.read(pathlib.Path.home()/'.claude/skills/config.ini'); print(cp['serpapi']['api_key'])")
curl -s "https://serpapi.com/search.json?engine=google_hotels&q=${DESTINATION}+hotels&check_in_date=${CHECKIN}&check_out_date=${CHECKOUT}&adults=${ADULTS}&brands=17&sort_by=3&api_key=$SERPAPI_KEY"
```

#### Hotel search parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `q` | Search query (location + "hotels") | `Gold Coast Australia hotels` |
| `check_in_date` | Check-in date, YYYY-MM-DD | `2026-04-10` |
| `check_out_date` | Check-out date, YYYY-MM-DD | `2026-04-11` |
| `adults` | Number of adults | `1` |
| `children` | Number of children | `0` |
| `children_ages` | Comma-separated ages 1-17 | `5,8` |
| `brands` | Brand ID filter, comma-separated | `17` (IHG) |
| `sort_by` | `3` lowest price, `8` highest rating, `13` most reviewed | `3` |
| `currency` | Currency code | `AUD` |

Brand IDs: 17 IHG, 28 Hilton, 33 Accor, 46 Marriott, 53 Wyndham. Omit `brands` to search all.

#### Hotel response structure

The `properties` array contains hotels. Each property has:
- `name` — hotel name
- `total_rate.extracted_lowest` — lowest nightly price (number)
- `total_rate.currency` — currency
- `overall_rating` — guest rating
- `reviews` — number of reviews
- `property_token` — token for property details lookup
- `gps_coordinates` — lat/lng
- `check_in_time`, `check_out_time`

### Property details

Use `property_token` from the search results to get detailed pricing for a specific hotel:

```bash
SERPAPI_KEY=$(python3 -c "import configparser,pathlib; cp=configparser.ConfigParser(); cp.read(pathlib.Path.home()/'.claude/skills/config.ini'); print(cp['serpapi']['api_key'])")
curl -s "https://serpapi.com/search.json?engine=google_hotels&property_token=${TOKEN}&check_in_date=${CHECKIN}&check_out_date=${CHECKOUT}&adults=${ADULTS}&api_key=$SERPAPI_KEY"
```

This returns room types, rate options, amenities, and nearby places for a single hotel. Format results as a table: hotel name, nightly price, rating, reviews.

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
