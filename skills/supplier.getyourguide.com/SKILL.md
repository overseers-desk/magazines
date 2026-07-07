---
name: supplier.getyourguide.com
description: "GetYourGuide (GYG) supplier dashboard: tour/activity listings, products, bookings, reviews, supplier account."
allowed-tools: Bash, Read, Write
---

# GetYourGuide Supplier Portal

## Prerequisites

This skill requires a GetYourGuide supplier account and fresh authentication tokens (expire after ~1 hour).

- **Supplier ID:** read from `~/.config/magazines/config.ini` under `[supplier.getyourguide.com] supplier_id`
- **Tokens:** Firebase Bearer token + Cloudflare cookies extracted from a live browser session (see "Authentication" section below)

If you do not have a GetYourGuide supplier account, this skill does not apply. If the supplier ID is absent from `~/.config/magazines/config.ini`, pause and let the user know: "Add your supplier ID to `~/.config/magazines/config.ini` under `[supplier.getyourguide.com] supplier_id`. This file is not part of the shared aesop repository - create it locally."

## Capabilities

1. **List all activities** -- returns all activities including unpublished/draft ones with status, title, and pictures. Tested and working.
2. **Search activities** -- search by keyword, status filter (bookable, expired, draft, etc). Tested query structure.
3. **Activity details** -- get detailed information about a specific activity by ID.
4. **Activity status counts** -- get counts of activities by status (all, expired, expiring soon, not bookable, temp, bookable).
5. **Bookings** -- list and manage bookings (query structure identified but not yet tested end-to-end).
6. **Reviews** -- access review stats by activity ID.

## Authentication

Cloudflare protects the GraphQL endpoint. Direct curl without browser cookies returns `{"reason":"bot"}`. The working method is a two-step process: extract a fresh Firebase Bearer token and Cloudflare cookies from a headless browser session (user must be logged into supplier.getyourguide.com in their browser), then use those with curl.

### Step 1: Extract token and cookies via headless browser net log

A net log of the browser session carries the Firebase Bearer token and the Cloudflare cookies, so the session is dumped with `--log-net-log` and `--net-log-capture-mode=Everything`:

```bash
NETLOG="$HOME/gyg-netlog.json"

browser-serialiser --dump -t 15 \
  "https://supplier.getyourguide.com/products/list" \
  --log-net-log="$NETLOG" --net-log-capture-mode=Everything \
  > /dev/null 2>&1
```

Note: `browser-serialiser --dump` does not yet pass Chrome launch flags after the URL through to Chromium (it drives an already-launched browser over CDP), so the net log above is captured only once that passthrough is added; until then this step needs the net-log flags supplied at launch.

### Step 2: Parse token and cookies from the net log

```python
import json

with open(NETLOG_PATH) as f:
    data = json.load(f)

for e in data["events"]:
    params = e.get("params", {})
    pstr = json.dumps(params)
    # Extract Bearer token from type-578 events (HTTP_TRANSACTION_SEND_REQUEST_HEADERS)
    if "supplier.getyourguide.com/graphql" in pstr:
        rh = params.get("request_headers", {})
        if isinstance(rh, dict):
            for h in rh.get("headers", []):
                if "Bearer " in h:
                    TOKEN = h.split("Bearer ")[1].strip()
    # Extract cookies from type-227 events
    if "supplier.getyourguide.com" in pstr and "visitor_id" in pstr:
        headers = params.get("headers", [])
        if isinstance(headers, list):
            for h in headers:
                if isinstance(h, str) and h.lower().startswith("cookie:"):
                    COOKIES = h.split(": ", 1)[1].strip()
```

Token expires after ~1 hour. If a query returns 401, re-run the headless browser step.

## API endpoints

### GraphQL (primary API)

**Endpoint:** `https://supplier.getyourguide.com/graphql`

**Required headers:**
```
Authorization: Bearer <firebase-id-token>
Content-Type: application/json
x-gyg-supplier-id: $SUPPLIER_ID
Accept: application/json
apollographql-client-name: supplier-portal
sec-ch-ua: "Not-A.Brand";v="24", "Chromium";v="146"
User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36
Origin: https://supplier.getyourguide.com
Cookie: <cookies from step 2>
```

## Key GraphQL queries

### List all supplier activities (including unpublished)

```graphql
query Activity_ProductWizardAllSupplierActivities($supplierId: ID!) {
  allSupplierActivities(supplierId: $supplierId) {
    id
    online
    status
    supplierStatus
    sourceText {
      title
    }
    pictures {
      url
    }
  }
}
```

### Search activities with pagination

```graphql
query Activity_ActivitySearch($input: SearchInput) {
  activitySearch(input: $input) {
    items {
      id
      online
      status
      supplierStatus
      sourceText {
        title
      }
      pictures {
        url
      }
    }
  }
}
```

### Activity status counts

```graphql
query Activity_ProductsListStatusCount($input: SearchInput) {
  activitySearchStats(input: $input) {
    all
    expired
    expiringSoon
    notBookable
    temp
    bookable
  }
}
```

### Activity details

```graphql
query Activity_ActivityCard($activityId: ID!) {
  activity(id: $activityId) {
    id
    pictures {
      url
    }
    sourceText {
      title
    }
    options {
      id
    }
  }
}
```

### Review stats

```graphql
query Activity_activityStats($activityIds: [ID!]!) {
  reviewStatsByActivityIds(activityIds: $activityIds) {
    stats {
      activityId
      reviewsAverageRating
      reviewCount
    }
  }
}
```

### Bookings list with deals

```graphql
query OneClickDealGetActivityList($input: SearchInput, $dateFrom: DateTime!, $dateTo: DateTime!) {
  activitySearch(input: $input) {
    items {
      id
      supplierBookingCount(dateFrom: $dateFrom, dateTo: $dateTo)
      deals {
        id
        status
        dateRange {
          end
        }
      }
      sourceText {
        title
      }
      pictures {
        id
        url
      }
      options {
        id
      }
    }
    pagination {
      totalItems
      offset
      limit
      hasNextPage
    }
  }
}
```

## Example curl command

```bash
# List all activities for a supplier
curl -s -X POST "https://supplier.getyourguide.com/graphql" \
  -H "Authorization: Bearer $ID_TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-gyg-supplier-id: $SUPPLIER_ID" \
  -H "Accept: application/json" \
  -H "apollographql-client-name: supplier-portal" \
  -H "sec-ch-ua: \"Not-A.Brand\";v=\"24\", \"Chromium\";v=\"146\"" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36" \
  -H "Origin: https://supplier.getyourguide.com" \
  -H "Cookie: $COOKIES" \
  -d '{
    "operationName": "Activity_ProductWizardAllSupplierActivities",
    "variables": {"supplierId": "$SUPPLIER_ID"},
    "query": "query Activity_ProductWizardAllSupplierActivities($supplierId: ID!) { allSupplierActivities(supplierId: $supplierId) { id online status supplierStatus sourceText { title } } }"
  }'
```

## Status values

Activities have two status fields:
- `status` -- system status (e.g. NEW, ACTIVE)
- `supplierStatus` -- supplier-facing status (e.g. TEMP, DEACTIVATED, DELETED)
- `online` -- boolean, whether currently bookable on the marketplace

## Limitations

- Consumer GYG login (www.getyourguide.com) and supplier portal login (supplier.getyourguide.com) are completely separate authentication systems. The user must be logged into the supplier portal in their browser.
- Cloudflare blocks direct curl to the GraphQL endpoint; browser cookies (especially `__cf_bm`) are required alongside the Bearer token.
- Firebase ID tokens expire after ~1 hour. Re-run the headless browser step to get a fresh token.
- The net log file is large (~50MB). Clean up `$HOME/gyg-netlog.json` after extracting tokens.
