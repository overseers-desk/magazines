---
name: flightnetwork.com
description: "Travel-document PDF from a Flightnetwork booking-confirmation email (airline, flight numbers, times, passenger names, e-tickets, baggage allowance) — the PDF an airline counter or customs expects."
allowed-tools: Bash, Read
---

# Flightnetwork Travel Document

Flightnetwork's booking-confirmation email does not contain a travel-document PDF. The clean document is served from `au.flightnetwork.com/order-ntd-generate-ref/<TOKEN>`, where the token comes from any etraveli redirect link in the email.

## Inputs

- An order reference: Flightnetwork order number (e.g. `1124-069-215`), etraveli ref (e.g. `P05LOP`), or the airline check-in PNR.
- Mailbox: any `mailroom -i <block>`. Default to the user's personal account if known, else `--all-imap`.
- Output path: where to write the PDF. Caller's choice. On Linux with a snap-confined chromium, the binary can only write under `$HOME/snap/chromium/common/`; render there, then move to the final location.

## Procedure

### 1. Find the order email

```bash
mailroom -i <imap-block> search "from:flightnetwork.com" --format json
```

Sender alone is precise; FN account inboxes typically carry few enough mails to disambiguate from the result list by date or subject. If the inbox holds many FN bookings, narrow with a date window (`after:YYYY/MM/DD`, `newer_than:`), not with a literal order-ref keyword: refs and surrounding labels vary by template language ("Order", "Pedido", "Reserva", "Buchung") and an AND-query can silently drop localized variants. Pick either the booking-confirmation email (subject starts "Your trip is confirmed") or the trip-info follow-up ("here's all information regarding your trip"). Both contain the same etraveli redirect links. Record `folder` and `uid`.

### 2. Extract any etraveli redirect from the body

`mailroom links` returns the URLs but with empty anchor text, so filtering by text does not help. Just pull any `info.etraveli.com/pub/cc?...` URL from the body:

```bash
mailroom -i <imap-block> read -f <folder> -u <uid> | python3 -c '
import json, sys, re
d = json.load(sys.stdin)
body = next(iter(next(iter(d.values())).values()))["body"]
m = re.search(r"https://info\.etraveli\.com/pub/cc\?[^\"\s<>]+", body)
print(m.group(0).strip())
' > /tmp/etraveli.url
```

### 3. Follow the redirect, extract the token

Every etraveli link bounces to `au.flightnetwork.com/order-<endpoint>/<TOKEN>` for the same order. Different anchors land on different endpoints (`order-login`, `order-load-ref`, `order-post-sale`, etc.), but the token in the path is identical across them. Take whichever endpoint the redirect gives you and pull the token out of the path:

```bash
TARGET=$(curl -sLI -A "Mozilla/5.0" --max-redirs 4 "$(cat /tmp/etraveli.url)" \
         | grep -i '^location:' \
         | grep -oE 'au\.flightnetwork\.com/order-[a-z-]+/[A-Za-z0-9_=-]+' | head -1)
TOKEN=${TARGET##*/}
```

If `TOKEN` is empty, that particular link redirected to a tokenless page (`mobile-app-download`, `privacy-policy`, `contact-us`). Iterate through the email's other etraveli links until a token appears; at least half typically carry one.

### 4. Build the travel-document URL

```bash
URL="https://au.flightnetwork.com/order-ntd-generate-ref/$TOKEN"
```

This endpoint is publicly accessible (the token is the auth). `curl` returns the full HTML directly; no headless browser needed for the fetch.

### 5. Render to PDF

PDF generation uses the browser wrapper's `--pdf` mode. Timeout is 60s instead of the default 15s to allow PDF rendering. On Linux with a snap-confined chromium, the output path must be under `$HOME/snap/chromium/common/`:

```bash
OUT="$HOME/snap/chromium/common/fn-travel-doc.pdf"   # snap-confined; move afterwards
not-google-chrome -t 60 --pdf "$OUT" "$URL" 2>/dev/null
```

Move to the caller's target path afterwards. The result is one page per flight segment.

### 6. Read back the PDF to confirm what's in it

The PDF page text (via the Read tool) is the source of truth for filename construction. Capture:

- Airline name (`Operated by:` value)
- Flight number per segment
- Origin and destination airport names / IATA codes
- Departure date (first segment)
- Airline check-in reference (`Your airline check-in reference(s)`)
- Passenger names

Filename for the Fares folder follows the travel-folder SOP; see `sop-travel-folder-management.md` in the active travel project for the exact format. Use the airline PNR as the booking reference, not the Flightnetwork order number, because the PNR is what the airline check-in system uses.

## Notes

- The token is opaque (gzip+base64). It is order-scoped and stable on the timescale of a normal trip; do not try to construct or guess it.
- Marketing/bot text on this page is minimal: the rendered PDF is two clean pages per round-trip, one per segment. Compare against the email-print PDF, which is dominated by ads.
- If `mailroom search` returns multiple matches (confirmation + trip-info + reminders), any of them work for token extraction. Prefer the most recent; older email tokens have not been observed to expire, but freshest is safest.
