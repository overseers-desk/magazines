---
name: linkedin
description: "search people, read profiles, check keywords, verify connect eligibility, find role/company. Send connection invites or direct messages to connections."
argument-hint: <name, URL, or search terms>
---

## Execution model

This workflow produces large DOM outputs (1-20MB per page). Spawn a **Sonnet subagent** to execute it so the main conversation context is not consumed. Tell the subagent to use the scripts in `${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/` — do not paste scripts inline.

## Prerequisites

A logged-in LinkedIn session in the user-data-dir that `not-google-chrome` targets. This skill constructs LinkedIn URLs, calls the wrapper to fetch them, and parses the result.

If the dumped DOM title contains "Sign In", "Log In", "Iniciar sesión", or "Registrarse", the session is not active. LinkedIn expires the session periodically while keeping a remember-me cookie. First try `login.tcl` (see "Establish a session" below) to re-mint a session via the fastrack flow without a password. If that reports `logged_out` (no remember-me), or if the title persists after a successful login, then investigate the plumbing: the user-data-dir may be wrong, or another chromium instance may hold the same user-data-dir.

## Establish a session

LinkedIn expires the active session periodically while keeping a remember-me cookie. Re-mint a session without a password via the fastrack flow:

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/login.tcl          # log in via fastrack if logged out
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/login.tcl --check  # report state only, never click
```

`login.tcl`, `send-invite.tcl`, and `send-message.tcl` are CDP clients run through `not-google-chrome --cdp`, which owns the browser lifecycle: one browser at a time (flock), a deadman timeout, and a teardown that reaches the browser even after snap detaches it into its own systemd scope. Run directly, the scripts exit with `CDP_WS_URL not set`.

The JSON `status` is one of:
- `already_logged_in` / `logged_in` — session active
- `logged_out_remember_me` — remember-me cookie present; the default run clicks the fastrack "continue" control to log in
- `logged_out` — no remember-me; the user must log in once in the GUI browser
- `login_failed` — fastrack clicked but no session minted

Run this when a fetch returns a sign-in title, before assuming the plumbing is broken. The same `[browser]` user-data-dir and UA caveats as the send scripts apply (close the GUI browser so the headless instance can write the session cookie).

## 1. Search for people

Use **people search**, not "all" search. Fetch this URL with the wrapper, save to `/tmp/linkedin-search-results.html`:

```bash
not-google-chrome "https://www.linkedin.com/search/results/people/?keywords=SEARCH_TERMS&origin=GLOBAL_SEARCH_HEADER" > /tmp/linkedin-search-results.html
```

URL-encode search terms (spaces become `%20`).

### Search variants for hard-to-find people

Try in order if no results:

1. `Name City` — `Sidney%20Lin%20Singapore`
2. `Name Company` — `Sidney%20Lin%20A%20Firm%20Foundation`
3. `Name Role City` — `Sidney%20Lin%20property%20Singapore`
4. Alternative romanisations — Lin (Mandarin), Lim (Hokkien), Lam (Cantonese) are the same surname
5. `"Company" City` — search by company to find employees, then match
6. `Role Organisation City` — `Chairman%20Distinction%20ASME%20Singapore`

A search returning zero results does not mean the person has no LinkedIn. Try all variants before declaring "not found".

## 2. Parse search results

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/parse-search.tcl /tmp/linkedin-search-results.html
```

Outputs each profile URL with nearby visible text (name, headline).

## 3. Fetch a profile

Fetch this URL with the wrapper, save to `/tmp/linkedin-profile.html`:

```bash
not-google-chrome "https://www.linkedin.com/in/USERNAME/" > /tmp/linkedin-profile.html
```

## 4. Parse profile

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/parse-profile.tcl /tmp/linkedin-profile.html "https://www.linkedin.com/in/USERNAME/"
```

Emits a structured YAML record to stdout: name, vanity slug, the profile URN (`urn:li:fsd_profile:ACoAA...`, the owner's, found as the dominant id in the page's data payload across LinkedIn's several serialisations of it), headline, location, current company, and a capped list of evidence text blocks. Pass the profile URL as the optional second argument so the record carries the slug and canonical URL; redirect stdout to `<slug>.yaml` to save it. The legacy numeric form (`urn:li:member:NNN`) is not emitted: on a profile page its most-frequent value is the signed-in viewer's own id, not the owner. Deep career history, About, and skills are lazy-mounted and not reliably present in the dump (see BUGS.md), so they are not extracted as structured fields.

## 5. Keyword search (optional)

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/keyword-search.tcl /tmp/linkedin-profile.html keyword1 keyword2 ...
```

Checks whether a profile mentions specific terms and shows surrounding context.

## 6. Verify connect eligibility

The connection invite page is at a constructable URL:

```
https://www.linkedin.com/preload/custom-invite/?vanityName=USERNAME
```

Fetch this URL with the wrapper, save to `/tmp/linkedin-connect.html`, then check the modal that renders:

```bash
not-google-chrome "https://www.linkedin.com/preload/custom-invite/?vanityName=USERNAME" > /tmp/linkedin-connect.html
```

Parse the result:

- **Connectable** — modal header is "Add a note to your invitation?" with two buttons: "Add a note" and "Send without a note". Body text says "Personalize your invitation to [Name] by adding a note."
- **Email required** — same modal but with an extra `<input type="email">` and text asking to "enter their email to connect" (happens for some high-profile accounts).
- **Already connected** — different page state (no invite modal).
- **Not found / error** — no modal rendered.

If the modal shows "Add a note" and "Send without a note", the person is connectable. Proceed to step 7 to send.

## 7. Send connection invite with note

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/send-invite.tcl VANITY_NAME "Your note (≤300 chars)"
```

`VANITY_NAME` is the slug from the profile URL: `/in/john-smith-123/` → `john-smith-123`.

The wrapper launches the browser and hands the script a page-target websocket; the script then, over CDP:
1. Navigates to `/preload/custom-invite/?vanityName=VANITY_NAME`
2. Clicks "Add a note", waits for the textarea (`#custom-message`)
3. Types the note via `Input.insertText` (triggers Ember reactivity)
4. Clicks the send button (label varies; matched by "send" excluding "without")
5. Waits for server round-trip and captures confirmation

**Prerequisite:** the GUI Chromium must not be open (it shares the user-data-dir). The wrapper warns to stderr if it detects one running; close the browser and retry.

**Confirmation output** — the script prints and returns a JSON result:
- `toast` — text of LinkedIn's toast notification if present (e.g. "Invitation sent")
- `modal_closed` — whether the modal disappeared after send (strong success signal)
- `api_responses` — HTTP status codes from LinkedIn's invitation API calls
- `status` — `"sent"` | `"uncertain"` | `"dry_run"`

`status: "sent"` requires at least one of: toast present, modal closed, or API 200/201/204. If none triggered, the script exits with code 1 and prints `UNCERTAIN`.

**Dry-run mode** (types but does not click Send):
```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/send-invite.tcl VANITY_NAME "note" --dry-run
```

**Note character limit:** LinkedIn enforces 300 chars client-side (no `maxlength` HTML attribute). The script enforces this before connecting.

## 8. Send a direct message to a connection

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/send-message.tcl VANITY_NAME "Message text"
```

The person must be a first-degree connection. The script:
1. Navigates to the profile page `/in/VANITY_NAME/`
2. Clicks the "Message" button
3. Types the message via `Input.insertText` into the compose area
4. Clicks the Send button
5. Confirms via compose-area clearing and/or API response

**Dry-run mode:**
```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/send-message.tcl VANITY_NAME "text" --dry-run
```

**Confirmation output:**
- `toast` — LinkedIn toast text if present
- `compose_cleared` — whether the compose area emptied after send (primary success signal)
- `api_responses` — HTTP status codes from LinkedIn's messaging API
- `status` — `"sent"` | `"uncertain"` | `"dry_run"`

## DOM parsing notes

LinkedIn (as of 2026) uses randomised CSS class names, no semantic IDs, lazy loading, and pages of 1-20MB. The scripts extract `<title>`, `<meta>` tags, and visible text via `>content<` pattern matching. Do not select by CSS class name — they change between sessions.
