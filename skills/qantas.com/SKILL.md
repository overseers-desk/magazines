---
name: qantas.com
description: "Classic Reward flight availability (point cost, taxes, seats, aircraft, times for route+date range) and Frequent Flyer points balance. Triggers: points redemptions, award seat availability on Qantas-operated routes."
argument-hint: <origin> <destination> <date> [stops]   |   points
---

## Prerequisites

Feature 1 (Classic Reward search) requires no login. Feature 2 (points balance) requires credentials.

- **What:** Qantas Frequent Flyer member number, last name, and PIN
- **Where:** `$HOME/.config/magazines/config.ini`, under the `[qantas.com]` section
- **Format:**
  ```ini
  [qantas.com]
  member_id = YOUR_FF_NUMBER
  last_name = YOURLASTNAME
  pin = YOUR_PIN
  ```

If Feature 2 is requested and the section is absent, pause and let the user know: "To read your Qantas points balance, add a `[qantas.com]` section with member_id, last_name, and pin to `$HOME/.config/magazines/config.ini`."

The skill has two independent features. Run whichever the user asked for; do not chain them.

## Feature 1: Search Classic Reward flight availability (no login)

Per-flight Classic Flight Reward availability: flight number, aircraft, departure and arrival times (with day offset), point cost and tax per cabin (Economy / Premium Economy / Business / First), and seats remaining at that price. Every result on the Flight Reward Finder is a Classic Reward by definition.

The Flight Reward Finder serves international itineraries only. A domestic Australian route (e.g. `SYD`-`MEL`) returns `routeError: {blocked: true, code: "DOMESTIC_AU_ONLY"}` instead of results; Qantas directs domestic Classic Reward search to `book.qantas.com`, which this skill cannot reach (see Booking engine vs. reward finder below). For a domestic request, tell the user it is not available through this path.

Endpoint: `https://flightrewardfinder.qantas.com/?o=ORIGIN&d=DEST&dr=YYYY-MM-DD_YYYY-MM-DD&st=STOPS&p=PASSENGERS`

Parameters:
- `o` - origin IATA code (e.g. `SIN`)
- `d` - destination IATA code (e.g. `BNE`)
- `dr` - date range, two dates joined with `_`. Single date uses the same value twice (`2026-06-13_2026-06-13`).
- `st` - stops filter: `direct`, `1`, `2`, `3+`. Use `direct` for nonstop only.
- `p` - passenger count.

Server-rendered Next.js - flight data lives in `__next_f.push(...)` chunks in the HTML. No authentication, no API key needed.

Run the skill through `browser-serialiser`: it loads the skill into a policed safe interpreter and drives the browser through the command surface (no raw CDP, anti-ban pacing enforced). The skill navigates to the Flight Reward Finder, dumps the rendered HTML, and parses it in one call. See the serialised-browsing skill for the command surface.

```bash
browser-serialiser qantas.com/parse-rewards <origin> <dest> <date YYYY-MM-DD> [stops]
browser-serialiser qantas.com/parse-rewards SIN BNE 2026-08-01 direct
```

The first three arguments are required; `stops` defaults to `direct`. The arguments map to the endpoint parameters above (`o`/`d`/`dr`/`st`); the single date repeats to form the `dr` range, and passenger count is 1.

Date handling: the Flight Reward Finder only holds live and future availability - past dates return zero records, not an error. If the user asks about a date in the past, state today's date and confirm before fetching. Even when `dr` specifies a single day, the endpoint returns the full forward availability list (observed spanning ~12 months), not a filtered window, so filter to the requested date in the consumer.

## Feature 2: Read Frequent Flyer points balance (login required)

Returns first name, tier, member ID, points, and status credits. Login + read happen in one session because cookies do not persist across invocations while the snap chromium browser is open (it locks the user-data-dir).

The skill runs under the policed surface: `serialiser_run` navigates the sign-in page, detects the form, types the credentials, clicks submit, then reads and parses the account page. The safe interpreter cannot read `config.ini`, so read the credentials from `$HOME/.config/magazines/config.ini` (`[qantas.com]` member_id, last_name, pin — see Prerequisites) and pass them as arguments:

```bash
browser-serialiser qantas.com/login <member_id> <last_name> <pin>            # human-readable
browser-serialiser qantas.com/login <member_id> <last_name> <pin> --json     # JSON
browser-serialiser qantas.com/login --check                                  # open the form, do not submit
```

`--check` opens the sign-in form and reports it ready without submitting; it needs no credentials. The submit is supervised — this skill types and clicks once, and a live run sends the real credentials.

This feature is independent of Feature 1. Run it only when the user asks about points balance, status credits, or tier. Do not run it as a side effect of a flight search.

## Booking engine vs. reward finder

The Classic Reward search above goes through `flightrewardfinder.qantas.com`. The main `book.qantas.com` booking engine blocks direct curl/headless access (HTTP/2 stream errors). To complete a booking after finding a redemption, the user opens it in their browser; this skill is search-only.
