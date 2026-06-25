---
name: linkedin
description: "search people, read profiles, read a job posting, check keywords, verify connect eligibility, find role/company. Send connection invites or direct messages to connections. Edit your own profile headline and About."
argument-hint: <name, URL, or search terms>
---

## Execution model

This workflow produces large DOM outputs (1-20MB per page). Spawn a **Sonnet subagent** to execute it so the main conversation context is not consumed. Tell the subagent to use the scripts in `${CLAUDE_PLUGIN_ROOT}/skills/linkedin.com/` — do not paste scripts inline.

Each script runs through `browser-serialiser`, which owns the browser and exposes a policed command surface (the skill drives `nav`/`dump`/`type`/`click` verbs, never a raw socket). The skill is named by a reference relative to `skills/`, without the `.tcl` suffix: `linkedin.com/parse-profile`, `linkedin.com/send-invite`, and so on. See `serialised-browsing` for the surface contract.

## Prerequisites

A logged-in LinkedIn session in the user-data-dir that `browser-serialiser` targets. This skill constructs LinkedIn URLs, navigates to them, dumps the rendered DOM, and parses the result.

If the dumped DOM title contains "Sign In", "Log In", "Iniciar sesión", or "Registrarse", the session is not active. LinkedIn expires the session periodically while keeping a remember-me cookie. First run `linkedin.com/login` (see "Establish a session" below) to re-mint a session via the fastrack flow without a password. If that reports `logged_out` (no remember-me), or if the title persists after a successful login, then investigate the plumbing: the user-data-dir may be wrong, or another chromium instance may hold the same user-data-dir.

## Establish a session

LinkedIn expires the active session periodically while keeping a remember-me cookie. Re-mint a session without a password via the fastrack flow:

```bash
browser-serialiser linkedin.com/login          # log in via fastrack if logged out
browser-serialiser linkedin.com/login --check  # report state only, never click
```

`login`, `send-invite`, and `send-message` drive the browser through the serialiser, which owns the browser lifecycle: one browser at a time (flock), a deadman timeout, and a teardown that reaches the browser even after snap detaches it into its own systemd scope.

The JSON `status` is one of:
- `already_logged_in` / `logged_in` — session active
- `logged_out_remember_me` — remember-me cookie present; the default run clicks the fastrack "continue" control to log in
- `logged_out` — no remember-me; the user must log in once in the GUI browser
- `login_failed` — fastrack clicked but no session minted

Run this when a fetch returns a sign-in title, before assuming the plumbing is broken. The same `[browser]` user-data-dir and UA caveats as the send scripts apply (close the GUI browser so the headless instance can write the session cookie).

## 1. Search and parse people

Use **people search**, not "all" search. One reference navigates to the people-search URL, dumps the rendered DOM, and parses it in a single step:

```bash
browser-serialiser linkedin.com/parse-search "SEARCH TERMS"
```

Search terms are passed as one quoted argument; the skill URL-encodes them. The output lists each profile URL with nearby visible text (name, headline).

### Search variants for hard-to-find people (vary the quoted terms)

Try in order if no results:

1. `Name City` — `Sidney%20Lin%20Singapore`
2. `Name Company` — `Sidney%20Lin%20A%20Firm%20Foundation`
3. `Name Role City` — `Sidney%20Lin%20property%20Singapore`
4. Alternative romanisations — Lin (Mandarin), Lim (Hokkien), Lam (Cantonese) are the same surname
5. `"Company" City` — search by company to find employees, then match
6. `Role Organisation City` — `Chairman%20Distinction%20ASME%20Singapore`

A search returning zero results does not mean the person has no LinkedIn. Try all variants before declaring "not found".

## 2. Parse a profile

One reference navigates to `/in/USERNAME/`, dumps the rendered DOM, and parses it:

```bash
browser-serialiser linkedin.com/parse-profile USERNAME
```

`USERNAME` is the vanity slug or a full profile URL. Emits a structured YAML record: name, vanity slug, the profile URN (`urn:li:fsd_profile:ACoAA...`, the owner's, found as the dominant id in the page's data payload across LinkedIn's several serialisations of it), headline, location, current company, and a capped list of evidence text blocks. Redirect stdout to `<slug>.yaml` to save it. The legacy numeric form (`urn:li:member:NNN`) is not emitted: on a profile page its most-frequent value is the signed-in viewer's own id, not the owner. Deep career history, About, and skills are lazy-mounted and not reliably present in the dump (see BUGS.md), so they are not extracted as structured fields.

## 2a. Parse a job posting

```bash
browser-serialiser linkedin.com/parse-job <job-id-or-url>
```

`<job-id-or-url>` is a numeric job id, a `/jobs/view/<id>` URL, or any URL carrying `currentJobId=<id>`. The script navigates to the guest job-posting fragment (`jobs-guest/jobs/api/jobPosting/<id>`), whose class names are stable and whose description is the full text — so it does not depend on the logged-in SPA's randomised classes and is not truncated by the "… more" fold. Emits a YAML record: `job_id`, `url` (the human `/jobs/view/` link), `title`, `company`, `location`, `posted`, `seniority`, `employment_type`, `job_function`, `industries`, and the full `description` as a literal block scalar. Redirect stdout to `<id>.yaml` to save it. Falls back to JobPosting JSON-LD (present on a logged-out full job page) and then to the og:/<title> meta tags when the guest fragment is unavailable.

## 3. Keyword search (optional)

```bash
browser-serialiser linkedin.com/keyword-search USERNAME keyword1 keyword2 ...
```

Navigates to `/in/USERNAME/`, dumps the DOM, and reports whether the profile mentions specific terms with surrounding context.

## 3a. List a person's connections visible to you

See who you could reach through a given person — mutual connections, and (when they allow it) their wider network:

```bash
browser-serialiser linkedin.com/connections-of <profile-id-or-urn> [network]
```

`profile-id` is the `ACoAA...` token from parse-profile's `urn` field (the full URN works too; the prefix is stripped). This drives the faceted people-search `connectionOf` facet and parses the result with the same extractor as parse-search.

What LinkedIn exposes is gated, not arbitrary:

- `network` `F` (default) — people in **your** 1st-degree who are connected to the target, i.e. your **mutual** connections with them. Available for any target whose profile you can open.
- `network` `FS` — also requests the target's 2nd-degree connections visible to you. Populated only when the target is your 1st-degree **and** has not hidden their connection list; otherwise it degrades to the mutuals-only set.

Workflow: run parse-profile first to get the `urn`, then pass its id here. The facet name (`connectionOf`) and `origin=FACETED_SEARCH` follow the URL shape in BUGS.md; verify the result against a known person on first live run, as LinkedIn's facet params shift.

## 4. Verify connect eligibility

The connection invite page is at a constructable URL. Navigating there with the parser dumps the modal that renders:

```bash
browser-serialiser linkedin.com/parse-search "USERNAME"   # or read the modal text via a profile dump
```

The invite flow itself (step 6) navigates to `https://www.linkedin.com/preload/custom-invite/?vanityName=USERNAME` and inspects the modal before typing. The connectable states are:

- **Connectable** — modal header is "Add a note to your invitation?" with two buttons: "Add a note" and "Send without a note". Body text says "Personalize your invitation to [Name] by adding a note."
- **Email required** — same modal but with an extra `<input type="email">` and text asking to "enter their email to connect" (happens for some high-profile accounts).
- **Already connected** — different page state (no invite modal).
- **Not found / error** — no modal rendered.

If the modal shows "Add a note" and "Send without a note", the person is connectable. Proceed to step 7 to send.

## 5. Send connection invite with note

```bash
browser-serialiser linkedin.com/send-invite VANITY_NAME "Your note (≤300 chars)"
```

`VANITY_NAME` is the slug from the profile URL: `/in/john-smith-123/` → `john-smith-123`. The skill drives the policed verbs:
1. `nav` to `/preload/custom-invite/?vanityName=VANITY_NAME`
2. `click` "Add a note", waits for the textarea (`#custom-message`)
3. `type` the note (triggers Ember reactivity)
4. `click` the send button (label varies; matched by "send" excluding "without")
5. Reads the toast and modal-closed signals for confirmation

**Prerequisite:** the GUI Chromium must not be open (it shares the user-data-dir).

**Confirmation output** — a JSON result:
- `toast` — text of LinkedIn's toast notification if present (e.g. "Invitation sent")
- `modal_closed` — whether the modal disappeared after send (strong success signal)
- `api_responses` — present for shape compatibility; the post-send network call is not harvested on the policed surface, so this array is empty
- `status` — `"sent"` | `"uncertain"` | `"dry_run"`

`status: "sent"` requires a toast present or the modal closed. `--dry-run` types the note but stops before the send click:
```bash
browser-serialiser linkedin.com/send-invite VANITY_NAME "note" --dry-run
```

**Note character limit:** LinkedIn enforces 300 chars client-side (no `maxlength` HTML attribute). The skill enforces this before connecting.

## 6. Send a direct message to a connection

```bash
browser-serialiser linkedin.com/send-message VANITY_NAME "Message text"
```

The person must be a first-degree connection. The skill:
1. `nav` to the profile page `/in/VANITY_NAME/`, scrapes the compose URL, navigates to it
2. `type` the message into the compose area
3. `click` the Send button
4. Confirms via compose-area clearing and/or toast

`--dry-run` types the message but stops before the send click:
```bash
browser-serialiser linkedin.com/send-message VANITY_NAME "text" --dry-run
```

**Confirmation output:**
- `toast` — LinkedIn toast text if present
- `compose_cleared` — whether the compose area emptied after send (primary success signal)
- `api_responses` — empty on the policed surface (see step 5)
- `status` — `"sent"` | `"uncertain"` | `"dry_run"`

## 7. Edit your own profile (text fields)

Edit a single-value text field on the signed-in user's own profile. The profile
is reached through `/in/me/`, which LinkedIn redirects to whatever account is
signed in, so no profile slug is passed.

```bash
browser-serialiser linkedin.com/set-profile-field headline "New headline"   # ≤220 chars
browser-serialiser linkedin.com/set-profile-field about    "New About text"
browser-serialiser linkedin.com/set-profile-field <field> --dump            # read current value, no change
browser-serialiser linkedin.com/set-profile-field <field> "text" --dry-run  # type into the editor but do not Save
```

`<field>` is `headline` or `about`. The skill opens the field's edit form (the
headline form has a direct route; the About form opens via its pencil), replaces
the editor's content, clicks Save, then re-opens the form and re-reads to
confirm. It emits a JSON result: `{"status": "saved"|"uncertain", "field", "was",
"now"}`. `--dump` and `--dry-run` never Save and are safe to run freely; `--dump`
returns `{"status":"dump","current_len","current"}`.

**Save is the irreversible outward action.** LinkedIn may broadcast a profile
change to the user's network. Before a real (non-dry-run) edit, confirm Settings
→ Visibility → "Share profile updates with your network" is **off** if the change
should not notify connections.

The edit forms lazy-mount their rich-text editors only after the page is
scrolled, and the About form's pencil-open is racy, so the skill scroll-hydrates
and retries the open; a single run takes a couple of minutes. Runs serialise on
the same browser lock as every other LinkedIn call (one session at a time).

### What this skill can and cannot edit

`set-profile-field` covers the two single-value text fields below. The other
profile sections are not automated; edit them in the LinkedIn UI. How to confirm
each row still holds (and re-recon when LinkedIn changes its DOM) is in
`EDIT-VALIDATION.md`.

| Profile section | Automated? | Reason |
|---|---|---|
| Headline | Yes | Direct form route (`/in/me/edit/intro/`); one `role="textbox"`. Edit→Save→re-read proven. |
| About | Yes | Opens via its pencil (retried); one `role="textbox"`. Edit→Save→re-read proven. |
| Experience: set end date / edit description | No | Multi-field form with month/year **date-picker dropdowns** and a "currently here" toggle. The open/save mechanics carry over, but the date pickers are unbuilt. Buildable; not done. |
| Experience: add an entry | No | Same multi-field form as above. Buildable; not done. |
| Skills (reorder / pin) | No | Reordering is drag-and-drop; not reconnoitred. No edit path attempted. |
| Featured (add / remove) | No | Media/post picker flow; not reconnoitred. No edit path attempted. |
| Open to Work (visibility) | No | Separate settings route (`/opportunities/job-opportunities/edit/`); not reconnoitred. No edit path attempted. |

The "No" rows are not proven-impossible. Experience is buildable with the same
mechanics; Skills/Featured/Open-to-Work were never reconnoitred, so their
difficulty is unknown, not established.

## DOM parsing notes

LinkedIn (as of 2026) uses randomised CSS class names, no semantic IDs, lazy loading, and pages of 1-20MB. The scripts extract `<title>`, `<meta>` tags, and visible text via `>content<` pattern matching. Do not select by CSS class name — they change between sessions.
