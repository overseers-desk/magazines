---
name: airbnb.com
description: "host dashboard: quick replies, saved message templates, hosting message settings; past/upcoming/all reservations."
argument-hint: <list [--product STAYS|EXPERIENCES] | reservations [--filter past|upcoming|all]>
allowed-tools: Bash, Read
---

## Execution model

Spawn a **subagent** to run the skill through `browser-serialiser`, as each invocation drives a browser session (~15s overhead). The serialiser resolves the skill by reference (`airbnb.com/airbnb-cdp`) in the trusted skill tree and runs it inside the policed safe interp; the skill drives the harness verbs (it does not open its own browser or CDP socket).

## Prerequisites

- A Chrome-compatible browser with an active Airbnb hosting session. The user must be logged in to `airbnb.com/hosting` via their browser. The serialiser drives Airbnb over CDP (not a DOM dump) because Airbnb is a React SPA and the URL does not change on in-page navigation.
- **Close the browser before running.** The serialiser's browser instance and the GUI browser share the same user-data-dir; if the GUI holds the user-data-dir lock, cookies will not be readable.

If the skill returns `{"error": "Not logged in..."}`, the user needs to log in to Airbnb in their browser first, then close it.

## Capabilities

### 1. List quick replies

```bash
browser-serialiser airbnb.com/airbnb-cdp list [--product STAYS|EXPERIENCES]
```

Navigates to the quick replies settings page, intercepts the API response the page makes, and returns the quick replies as JSON. Default product is `STAYS`.

Returns a list with the intercepted response(s); each entry has `url`, `status`, and the parsed `data`. The quick replies live at `data.data.usersTemplates.messagingInbox.quickReplies.edges[].node`, each node carrying `id`, `title`, `text`, `productType`, and scheduling fields. If the response is not seen on the page, returns an `error` object naming the operation to look for in the Network panel.

### 2. Reservations

```bash
browser-serialiser airbnb.com/airbnb-cdp reservations [--filter past|upcoming|all]
```

Returns `{"total_count": N, "returned": N, "reservations": [...]}` (for `--filter all`, an object keyed by `past` and `upcoming`). Each reservation includes `confirmation_code`, `listing_id`, `listing_name`, `start_date`, `end_date`, `nights`, `guest_user`, `earnings`, `user_facing_status_key` (`complete`, `current`, `canceled`, `denied`, `timedout`, etc.), and `is_check_in_today` / `is_check_out_today` flags.

`past` uses `collection_strategy=for_reservations_list_history` and includes every past reservation regardless of status (cancellations and denials included). `upcoming` uses `collection_strategy=for_reservations_list` with `date_min=today` and `status=accepted,request`. Results are paginated 40 per call from inside the authenticated page context and the script loops until `metadata.page_count` is exhausted.

## How it works

The serialiser drives the user's logged-in browser session over Chrome DevTools Protocol (CDP). The skill navigates to a hosting page to establish the authenticated session, then either harvests the React app's own API responses from the network buffer via the `capture` verb (quick replies) or replays the `/api/v2/...` paging loop from inside the page context via `eval` (reservations). CDP is necessary because the hosting dashboard is a React SPA whose URL does not change on in-page navigation, so a plain DOM dump would only capture the pre-hydration shell.

Session redirects to the host's locale domain (e.g. `airbnb.es`), so the quick-replies URL match keys on `airbnb`/`quickreplies` rather than the literal `airbnb.com`. The `/api/v2/reservations` endpoint is declared in the serialiser's view-before-fetch table (host `airbnb.com`), covered by the preceding navigation to `/hosting/reservations`.

## API endpoints

`GET /api/v2/reservations` (verified). Headers required: `X-Airbnb-API-Key: d306zoyjsyarp7ifhu67rjxn52tv0t20` (the public web key), `X-CSRF-Without-Token: 1`, `Content-Type: application/json`. Query parameters: `locale`, `currency`, `_format=for_remy`, `_limit`, `_offset`, `collection_strategy`, `sort_field=start_date`, `sort_order`, and the strategy-specific filters described above. Response shape: `{reservations: [...], metadata: {page_count, page_index, total_count}}`.

`GET /api/v3/FetchQuickRepliesViaduct/<sha256>?operationName=FetchQuickRepliesViaduct&variables={"limit":25,"offset":0,"productType":STAYS|EXPERIENCES}` (GraphQL persisted query, used by capability 1). The host app issues it on mount; the script intercepts the response rather than replaying the URL, because the persisted-query hash rotates on Airbnb redeploys.
