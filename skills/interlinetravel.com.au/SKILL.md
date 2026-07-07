---
name: interlinetravel.com.au
description: "Interline Travel cruise deals at industry staff rates on interlinetravel.com.au: prices, availability, interline rates, search."
allowed-tools: Bash, Read
---

# Interline Travel Cruise Search

## Prerequisites

This skill requires staff travel credentials to access industry rates.

- **What:** Interline Travel account email and password
- **Where:** `$HOME/.config/magazines/config.ini`, under the `[interlinetravel.com.au]` section
- **Format:**
  ```ini
  [interlinetravel.com.au]
  email = you@example.com
  password = yourpassword
  ```

If the section is absent, pause and let the user know: "To search Interline Travel staff rates, add an `[interlinetravel.com.au]` section with your email and password to `$HOME/.config/magazines/config.ini`."

## Capabilities

1. **Cruise search with filters** — search 42,000+ cruises by region, cruise line, ship, port, date range, duration, type (Ocean/River), and price. Includes per-night price and return date in output. Pure curl via Python, no browser. Tested and working.
2. **Cruise details with fares and itinerary** — given a cruise ID, returns full details including cabin-grade pricing (inside, oceanview, balcony, suite), availability status, flight supplements, and port-by-port itinerary. Tested and working.
3. **Filter options** — lists all available regions, cruise lines, ships, departure/arrival ports, and duration bands. Supports cascading (e.g. narrowing to a specific region shows only operators sailing that region). Tested and working.
4. **Autocomplete suggestions** — free-text search returning matching regions, cruise lines, and ships with cruise counts. Tested and working.

Prices are interline staff rates — significantly below public pricing. The currency is not explicitly labelled in the API but is AUD based on the operator's Australian base.

## Quick start

Run `search.py` from the skill directory.

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/interlinetravel.com.au/search.py search --region Mediterranean --from 2026-06-01
```

### Subcommands

```bash
# Search with filters
python3 ${CLAUDE_PLUGIN_ROOT}/skills/interlinetravel.com.au/search.py search --region Caribbean --duration 8-14 --per-page 10

# Search within a travel window (must depart after X and return by Y)
python3 ${CLAUDE_PLUGIN_ROOT}/skills/interlinetravel.com.au/search.py search --from 2026-04-15 --to 2026-05-12 --return-by 2026-05-12

# Full cruise details (by ID from search results)
python3 ${CLAUDE_PLUGIN_ROOT}/skills/interlinetravel.com.au/search.py details 26649

# List available filter values
python3 ${CLAUDE_PLUGIN_ROOT}/skills/interlinetravel.com.au/search.py options

# Autocomplete
python3 ${CLAUDE_PLUGIN_ROOT}/skills/interlinetravel.com.au/search.py suggest "viking"
```

### Search options

| Option | Description |
|---|---|
| --region REGION | Region (e.g. Mediterranean, Caribbean, Alaska) |
| --operator OPERATOR | Cruise line name (e.g. "MSC Cruises", "Cunard") |
| --ship SHIP | Ship name |
| --start-port PORT | Departure port |
| --end-port PORT | Arrival port |
| --duration BAND | Duration band: 1-3, 4-7, 8-14, 15-20, 21-30, 31+ |
| --from DATE | Earliest departure (YYYY-MM-DD) |
| --to DATE | Latest departure (YYYY-MM-DD) |
| --return-by DATE | Cruise must end by this date (client-side filter on end_date) |
| --type TYPE | Cruise type: Ocean or River |
| --max-price N | Maximum price |
| --q TEXT | Free-text search |
| --page N | Page number (default: 1) |
| --per-page N | Results per page (default: 20) |
| --json | Output raw JSON (place after subcommand, e.g. `search --json`) |

## Cruise detail page URL

Each cruise has a web page at `https://interlinetravel.com.au/cruise/<id>`. The search output includes links. For a direct link, use the numeric ID from search results.

## Domestic vs international itineraries

The search API does not distinguish domestic from international cruises. Many Australian-departure cruises stay in Australian waters (e.g. Sydney → Hobart → Melbourne → Sydney). If the user needs to be outside Australia (e.g. for tax residency), check the itinerary ports via `details <id>` — the port list will show whether the cruise visits non-Australian ports.

## Authentication

The script authenticates automatically using credentials from `~/.config/magazines/config.ini` (`[interlinetravel.com.au]` email / password). Auth flow: CSRF token → login with email/password → session cookies with JWT. Sessions are cached for 2 hours in `/tmp/interline-travel-cookies.json` to avoid rate limiting on the auth endpoint.

## API details

All endpoints go through `https://interlinetravel.com.au/api/...` (same-origin proxy to `api.interlinetravel.com.au`). Authentication is required for all cruise endpoints.

### Endpoints used

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/api/auth/csrf` | Get CSRF token for login |
| POST | `/api/auth/login` | Authenticate (body: `{"identifier":"...","password":"..."}`, header: `X-CSRF-Token`) |
| GET | `/api/auth/me` | Validate existing session |
| GET | `/api/cruises/search` | Search cruises with query params |
| GET | `/api/cruises/count` | Total cruise count |
| GET | `/api/cruises/cascading-options` | Available filter values |
| GET | `/api/cruises/suggestions?q=...` | Autocomplete |
| GET | `/api/cruises/<id>/details` | Full cruise record |
| GET | `/api/cruises/<id>/itinerary-ports` | Port-by-port itinerary |

### Response structure (search)

Top-level: `results` (array), `resultsCount` (int), `meta` (`{page, per_page, total}`).

Each result: `id`, `title`, `duration_nights`, `start_date`, `end_date`, `price_from`, `region`, `rating_label`, `cruise_type`, `start_port`, `end_port`, `ship` (`{name}`), `operator` (`{id, name}`), `api_data` (contains `fare_sets` with per-cabin pricing).

### Response structure (details)

Same fields as search result plus full `api_data.fare_sets`. Each fare set has a `name` (e.g. "Late Saver", "Cunard Fare") and a `fares` array. Each fare: `price`, `grade_code`, `grade_name` (e.g. "Standard Inside", "Balcony", "Princess Suite"), `availability` ("available"/"closed"), `flight_price`.

## Data source

Cruise data is aggregated from Widgety (UK cruise data provider). The `widgety_cruise_id` field (e.g. `RCIST07E490`) is the upstream reference. Pricing overlays are applied by Interline Travel for staff rates.

## Typical workflow

1. User asks about cruise deals for a region/date/budget.
2. Run `search` with appropriate filters. Use `--return-by` if the user has a fixed travel window.
3. Present results table with per-night prices and links.
4. If user wants details on a specific cruise, run `details <id>`.
5. For exploring what's available, run `options` or `suggest`.
6. If user needs to be outside a country (e.g. tax residency), check itinerary ports in `details` to confirm international ports.

## Rate limiting

The auth endpoint returns 429 if hit too frequently. The script caches session cookies for 2 hours to avoid this. If you hit 429, wait a few minutes before retrying. Cruise search/detail endpoints have no observed rate limiting.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| Login failed | Wrong credentials or account locked | Check `~/.config/magazines/config.ini` credentials |
| HTTP 429 | Too many auth requests | Wait a few minutes; session caching should prevent this |
| HTTP 403 on all endpoints | Cloudflare blocking | Add a standard Chrome-compatible User-Agent (the script already does this) |
| 0 results | Filters too narrow or no cruises match | Broaden filters or check available options with `options` |
| POA pricing | Cruise has no interline rate set | Price on Application — contact Interline Travel directly |
