---
name: clover.com
description: "Clover POS (Asia Pacific) sales data: fetch orders with line items, modifications, payments, and refunds for a date range. Read-only."
argument-hint: <DATE_FROM DATE_TO --output PATH>
allowed-tools: Bash, Read
---

## Prerequisites

- `~/.claude/skills/config.ini` with:
  ```ini
  [clover.com]
  api_token = <merchant-specific API token from the AP dashboard>
  ```
- Token issued at https://www.ap.clover.com/dashboard → Setup → API Tokens. For current report-manager needs, enable Read on Merchant, Inventory, Orders, Payments. Customers and Employees are not required.
- `merchant_id` is intentionally NOT stored in config. Scripts resolve it via `/v3/merchants/current` so the token is the single source of truth for which merchant is being read.

If the config is missing the `[clover.com]` section the script exits with a clear message. If the token is wrong for the AP region the resolver call will return HTTP 401.

## Capabilities

### 1. Fetch orders for a date range

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/clover.com/fetch.py DATE_FROM DATE_TO --output PATH [--tz IANA_TZ]
```

- `DATE_FROM`, `DATE_TO` are `YYYY-MM-DD`, inclusive, interpreted in `--tz` (default `Australia/Brisbane`).
- Writes JSON Lines (one Clover Order per line) to `--output`, with `lineItems.modifications`, `payments`, and `refunds` expanded.
- Paginates 100 per page. If the run prints `WARNING: pagination offset hit 10000` to stderr, split the date range and re-run.
- `--output` is required: a year of orders is tens of MB of JSON; never let it flow into the conversation.

Per-project convention for the output path (e.g. a `data/clover-data/` directory alongside other POS-export folders) lives in the consuming project's own docs, not here. A typical filename pattern is `orders-{from}-to-{to}.jsonl`.

Example for a 28-day fetch:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/clover.com/fetch.py 2026-04-19 2026-05-16 \
  --output ./orders-2026-04-19-to-2026-05-16.jsonl
```

## Output shape

Each line is one Clover Order with these top-level fields commonly used by reports: `id`, `createdTime` (UTC epoch ms), `clientCreatedTime` (POS-local epoch ms — use this for hour-of-day and day-of-week analysis), `total` (cents), `state`, `paymentState`, `orderType`, `employee` (present only if Employees scope is enabled on the token).

Expanded children:
- `lineItems.elements[]` — `name`, `price` (cents), `itemCode`, `printed`, `refunded`, `item` (FK ref to inventory item), and `modifications.elements[]` for variant/topping detail.
- `payments.elements[]` — payment amount, tender, card transaction metadata; needed to decompose tender type and identify reversals.
- `refunds.elements[]` — refund records linked to the order.

Category dimension lives on inventory items, not on line items. To resolve a line-item's `item.id` → category, a catalog dump (planned, see below) is required.

## Planned capabilities

Add as needs surface; do not pre-build:

- `catalog.py` — dump items, categories, modifiers as JSONL for joining against line items so F&B / Experiences / Retail / Other splits can be computed.
- `fetch.py --since EPOCH_MS` — incremental pull using a `modifiedTime` filter and a sidecar last-sync file.
- `fetch.py --compare` — fetch the same range plus the 364-day-offset prior period in one call, matching the 28-day-report pattern in `report-manager/`.
- `order.py ORDER_ID` — pretty-print one order with all expansions for refund/dispute investigation.
- `status.py` — heartbeat: token validity, today's txn count and revenue total.
- `flatten.py` — JSONL → Square-shaped CSV for any legacy analysis still grepping the old column layout.

## API base, auth, region

Asia Pacific production base: `https://api.ap.clover.com`. The AP dashboard at `www.ap.clover.com` issues tokens that authenticate only against this base. EU/US/sandbox bases reject AP tokens with HTTP 401. The geographic location of the device that creates the token has no effect on which base accepts it — only the dashboard region matters.

Auth header: `Authorization: Bearer <api_token>`. No other variant works (verified 2026-05-16: bare token, `X-Clover-Auth`, and `apikey` headers all return 401).
