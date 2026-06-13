---
name: qantas.com
description: "Classic Reward flight availability (point cost, taxes, seats, aircraft, times for route+date range) and Frequent Flyer points balance. Triggers: points redemptions, award seat availability on Qantas-operated routes."
argument-hint: <origin> <destination> <date> [stops]   |   points
---

## Prerequisites

Feature 1 (Classic Reward search) requires no login. Feature 2 (points balance) requires credentials.

- **What:** Qantas Frequent Flyer member number, last name, and PIN
- **Where:** `$HOME/.claude/skills/config.ini`, under the `[qantas.com]` section
- **Format:**
  ```ini
  [qantas.com]
  member_id = YOUR_FF_NUMBER
  last_name = YOURLASTNAME
  pin = YOUR_PIN
  ```

If Feature 2 is requested and the section is absent, pause and let the user know: "To read your Qantas points balance, add a `[qantas.com]` section with member_id, last_name, and pin to `$HOME/.claude/skills/config.ini`."

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

Server-rendered Next.js - flight data lives in `__next_f.push(...)` chunks in the HTML. No authentication, no API key, no headed browser needed.

Steps:

1. Fetch the URL with `not-google-chrome URL > /tmp/qantas-frf.html`.
2. Run the parser:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/qantas.com/parse-rewards.tcl /tmp/qantas-frf.html
```

Date handling: the Flight Reward Finder only holds live and future availability - past dates return zero records, not an error. If the user asks about a date in the past, state today's date and confirm before fetching. Even when `dr` specifies a single day, the endpoint returns the full forward availability list (observed spanning ~12 months), not a filtered window, so filter to the requested date in the consumer.

## Feature 2: Read Frequent Flyer points balance (login required)

Returns first name, tier, member ID, points, and status credits. Login + read happen in one CDP session because cookies do not persist across invocations while the snap chromium browser is open (it locks the user-data-dir).

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/qantas.com/login.tcl            # human-readable
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/qantas.com/login.tcl --json     # JSON
```

Credentials are read from `$HOME/.claude/skills/config.ini` (`[qantas.com]` member_id, last_name, pin). See Prerequisites above.

This feature is independent of Feature 1. Run it only when the user asks about points balance, status credits, or tier. Do not run it as a side effect of a flight search.

## Booking engine vs. reward finder

The Classic Reward search above goes through `flightrewardfinder.qantas.com`. The main `book.qantas.com` booking engine blocks direct curl/headless access (HTTP/2 stream errors). To complete a booking after finding a redemption, the user opens it in their browser; this skill is search-only.
