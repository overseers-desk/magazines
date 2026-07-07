---
name: linkedin
description: "search people, read profiles, read a job posting, check keywords, verify connect eligibility, find role/company. Read a member's shared contact info (email, phone, websites). Send connection invites or direct messages to connections. Edit your own profile headline and About. Enumerate the messaging inbox and a thread's messages. Report which account the session is signed in as."
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

```bash
browser-serialiser linkedin.com/parse-profile USERNAME            # complete (default)
browser-serialiser linkedin.com/parse-profile USERNAME --quick     # topcard only, one navigation
```

`USERNAME` is the vanity slug or a full profile URL. By default this fetches the
topcard plus the Experience and Skills details pages and the About, emitting a
structured YAML record: name, vanity slug, the profile URN
(`urn:li:fsd_profile:ACoAA...`, the owner's, found as the dominant id in the
page's data payload), headline, location, `current_company`, `experience` (a list
of entries with `title`/`company`/`start`/`end`/`current`), `skills`, `about`,
evidence blocks, and a **`coverage:`** block. Redirect stdout to `<slug>.yaml`.

`coverage` is the honesty contract: each section is `fetched`, `not_found`
(the page was read and the section was absent — e.g. a profile with no skills
emits `skills: []` with `skills: fetched`), or `not_fetched` (never read).
`current_company` comes from the ongoing position in Experience, not guessed from
the headline; it is `null` only when Experience was read and no role is ongoing,
and `not_fetched` under `--quick`. So a caller can always tell a real empty from
an unread one and never reads partial data as a complete profile.

Each details page is a separate navigation, so the default makes ~3 navigations
per profile. For rate-sensitive bulk runs use `--quick` (topcard only, one
navigation); it marks Experience/Skills/About `not_fetched`. About still
lazy-mounts unreliably and is the section most often `not_found`. The legacy
numeric URN (`urn:li:member:NNN`) is not emitted: on a profile page its most
frequent value is the signed-in viewer's own id, not the owner.

## 2a. Parse a job posting

```bash
browser-serialiser linkedin.com/parse-job <job-id-or-url>
```

`<job-id-or-url>` is a numeric job id, a `/jobs/view/<id>` URL, or any URL carrying `currentJobId=<id>`. The script navigates to the guest job-posting fragment (`jobs-guest/jobs/api/jobPosting/<id>`), whose class names are stable and whose description is the full text — so it does not depend on the logged-in SPA's randomised classes and is not truncated by the "… more" fold. Emits a YAML record: `job_id`, `url` (the human `/jobs/view/` link), `title`, `company`, `location`, `posted`, `seniority`, `employment_type`, `job_function`, `industries`, and the full `description` as a literal block scalar. Redirect stdout to `<id>.yaml` to save it. Falls back to JobPosting JSON-LD (present on a logged-out full job page) and then to the og:/<title> meta tags when the guest fragment is unavailable.

## 2b. Read a member's Contact info

```bash
browser-serialiser linkedin.com/contact-info VANITY
```

`VANITY` is the vanity slug, an `ACoAA...` profile id, or a full `/in/.../` URL. This reads the member's self-listed Contact info — the data behind LinkedIn's "Contact info" modal. That modal does not mount in a headless session, so the DOM is empty; the script instead fetches the voyager GraphQL query the modal itself issues (`profile-contact-info-finder`, keyed by `memberIdentity`) and parses the privileged fields. Same in-page-fetch pattern as the messaging playbooks; `li-canonical.tcl` carries the shared helpers.

It emits the canonical envelope `{result, cursor, hasMore, fault}`. `result` is:

```json
{"viewer_urn", "profile_url", "member", "name", "email_shared": true|false,
 "emails": [...], "phones": [{"number","type"}], "twitter": [...],
 "websites": [{"url","label","category"}], "birthday": "MM-DD"|null}
```

`viewer_urn` is the logged-in member's own profile urn, captured from the session (via `/voyager/api/me`) so the persist records which own account the share-state was read as — ownership from the haul, never from config; it is null on the rare read where the self endpoint is unreadable. Email and phone are shared only by members who chose to (usually 1st-degree). When a member has not shared an email, `email_shared` is `false` and `emails` is `[]`, while `profile_url` and any other shared fields are still returned — a fetched empty, distinguishable from a failed fetch (which sets `fault`). `birthday` carries month and day only (LinkedIn exposes no year). The `queryId` rotates; if a run returns `fault` with "no profile found", refresh `LI_CONTACT_QUERY` in `contact-info.tcl` from the modal's request in DevTools.

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
- `reason` — present only on a terminal non-send status (see below); a human-readable explanation
- `status` — `"sent"` | `"email_required"` | `"blocked_challenge"` | `"uncertain"` | `"dry_run"`

`status: "sent"` requires a toast present or the modal closed. When the send does **not** confirm (modal still open, no toast), the skill classifies the stuck modal rather than blanket-returning `uncertain`:

- **`email_required`** — LinkedIn does not treat you as knowing this member, so instead of the "Add a note" modal it renders a **"Connect"** modal that demands the recipient's email (`<input type="email">`, text "To verify this member knows you, please enter their email to connect") and keeps the Send button **disabled**. The click is a no-op; no invite is ever dispatched. This is **terminal** — do not retry on the invite channel; reach the person by email or Follow + DM. (Observed on high-profile/low-overlap accounts, e.g. Jason Lemkin / Nate Herk / Shane Parrish.) Note the same email-gate can also render before send; the pre-send guard reports it as an error there, this is the post-send counterpart when the gated modal still offers an "Add a note" button.
- **`blocked_challenge`** — a visible security/verification challenge intercepted the send. Terminal on this channel without human interaction.
- **`uncertain`** — no terminal signal; genuinely "sent but couldn't confirm". This one **is** retry-worthy.

`--dry-run` types the note but stops before the send click:
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

## 7. Enumerate the messaging inbox and a thread

Two B-job playbooks mirror LinkedIn messaging into a caller's store (an overseer drives them as type-B jobs). Unlike the read skills, these do not DOM-dump — they open `/messaging/`, harvest the page's own voyager request to learn the live `queryId` (LinkedIn rotates these) and the mailbox urn, then re-issue the fetch in-page over the session cookies. The response is LinkedIn's normalized GraphQL envelope; the parse lives in `li-canonical.tcl`.

```bash
browser-serialiser linkedin.com/li-inbox
browser-serialiser linkedin.com/li-thread "conversationUrn <urn:li:msg_conversation:(...)>"
```

`li-inbox` emits a canonical inbox envelope: `{result:{ownProfileUrn, threads:[{conversation_urn, backend_thread_urn, is_group, title, last_activity, created_at, unread_count, unread, category, participants:[{profile_urn, first_name, last_name, profile_url}]}]}, cursor, hasMore, fault}`. One run mirrors the current inbox (the most recent conversations); it carries no older-than cursor.

`li-thread` takes a `conversationUrn` (from `li-inbox`'s output) and emits `{result:{conversationUrn, complete, participants:[...], messages:[{message_urn, sender_profile_urn, sent_at, body}]}, ...}`. One run returns the thread's most recent page; `complete` is true when the page is short enough that no older page is implied.

`li-canonical.tcl` has a direct-tclsh entry for offline parser testing against a saved voyager body: `tclsh9.0 li-canonical.tcl inbox <conv.json> <ownProfileUrn>` (or `thread <msgs.json> <conversationUrn>`).

## 8. Enumerate your own connections

A B-job playbook that enumerates the **logged-in member's own** connection list — the people the My Network "Connections" page lists, not `connections-of`'s faceted view of a *third party's* network (that one is mutuals-gated). LinkedIn migrated this page off the voyager GraphQL query to a Server-Driven UI (SDUI) surface: the rows now arrive as React Server Components "flight" payloads on the rsc-action `connectionsList` pager, not a re-issuable JSON API. So the playbook navigates the page, lets it fire its own pagination requests, harvests those flight bodies (base64-wrapped by CDP), and parses each card by pattern — the profile `/in/<slug>/` link, the bold display-name node, the "Connected on <date>" line, and the fsd_profile urn inside the card's message-compose link.

```bash
browser-serialiser linkedin.com/li-connections
browser-serialiser linkedin.com/li-connections '{"maxScrolls":10}'
```

Emits the canonical envelope. `result` is `{ownProfileUrn, connections:[{profile_urn, first_name, last_name, profile_url, connected_at}]}`. `ownProfileUrn` is the logged-in member's own profile urn, captured from the session the way `li-inbox` captures its identity. `first_name`/`last_name` are split from the one display-name string LinkedIn renders (first token / remainder). `connected_at` is the connected-on date (`"YYYY-MM-DD"`), null when absent. This is a **single-shot enumerator**: SDUI scroll-pagination has no offset cursor, so one run scrolls the last card into view repeatedly to pull further pages until the list stops growing (bounded by the optional `maxScrolls` arg, default 50), dedupes by urn, and emits every connection at once — `cursor` is always null, `hasMore` always false.

`li-connections.tcl` has a direct-tclsh entry for offline parser testing against a saved flight (the decoded RSC body, or its raw base64): `tclsh9.0 li-connections.tcl <flight.txt> <ownProfileUrn>`.

## 9. Read a profile header (job envelope)

A B-job profile-header read. `parse-profile` (§2) stays the interactive YAML verb; this one emits the canonical envelope for the persist leg. Args JSON carries `{profileUrn, slug}` (slug is a vanity or an `ACoAA` id; it drives the navigation, `profileUrn` is a fallback identity). It reuses parse-profile's extraction (headline, about, location, current company from the ongoing Experience entry) and adds the connection/follower count pairs and `current_title`.

```bash
browser-serialiser linkedin.com/li-profile '{"slug":"ada-lovelace"}'
```

Emits the canonical envelope. `result` is `{profile_urn, headline, about, location, current_title, current_company, connection_count, connection_raw, follower_count, follower_raw}`. LinkedIn shows `"500+"` once a member passes 500 connections and delivers follower counts display-formed (`"1,234"`, `"10K"`), so each count keeps the verbatim token in its `_raw` field and a best-effort parsed integer beside it (null when absent or unparseable). `profile_urn` is read from the page (the dominant owner urn), falling back to the passed `profileUrn`.

`li-profile.tcl` has a direct-tclsh entry for offline extraction testing against a saved profile page: `tclsh9.0 li-profile.tcl <profile.html> [slug]`.

## 10. Report who the logged-in session is

One voyager request against the self endpoint (`/voyager/api/me`, the same one the other verbs use to capture their own identity) — the cheapest identity-plus-liveness probe:

```bash
browser-serialiser linkedin.com/whoami
```

Emits the canonical envelope. `result` is `{profile_urn, first_name, last_name, name, public_identifier}`. `profile_urn` is the signed-in member's own urn (`urn:li:fsd_profile:...`, the shape every other verb keys on) and is always present in a result; `name` is the first/last pair joined, null when neither is present; `public_identifier` is the vanity slug, null when the /me body omits it. A logged-out session (a walled nav, or a /me body naming no member) is a `fault`, never a result — the same dead-session signal the other verbs raise.

`whoami.tcl` has a direct-tclsh entry for offline parser testing against a saved /me body: `tclsh9.0 whoami.tcl <me.json>` (emits the full envelope, fault path included).

## DOM parsing notes

LinkedIn (as of 2026) uses randomised CSS class names, no semantic IDs, lazy loading, and pages of 1-20MB. The scripts extract `<title>`, `<meta>` tags, and visible text via `>content<` pattern matching. Do not select by CSS class name — they change between sessions.
