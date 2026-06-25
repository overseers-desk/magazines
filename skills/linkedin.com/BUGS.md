# LinkedIn skill — open bugs

## 2026-06-25 Edit-form Save buttons ignore the policed `click` verb — use eval `el.click()`

**Finding (from building set-profile-field):** the Save button in LinkedIn's
2026 server-driven-UI profile edit forms does not fire its React `onClick` from
the harness's policed `click` verb. The verb reports a match and runs, but the
form stays open, no navigation occurs, and nothing persists (no error). Driving
the click in-page instead — `eval {document.querySelector('[data-sv-save="1"]').click()}`
— fires the handler: the form closes, navigates to the profile, and the change
saves. `set-profile-field` tags the Save button then clicks it this way.

**Why it matters beyond this skill:** `send-invite` and `send-message` perform
their irreversible Send through the policed `click` verb (`click {[data-sv-send="1"]}`).
If LinkedIn's invite/compose buttons behave like these edit-form buttons, those
sends may be silently no-ops while still reporting `status: sent` from the
toast/modal-close heuristics. Not retested here. Before trusting a "sent" result,
verify against a real recipient, or switch those clicks to in-page `el.click()`.

**Editor mechanics, for the next field added to set-profile-field:** the headline
and About editors are Lexical-style `contenteditable` `[role="textbox"]` nodes
that (a) hydrate only after the form is scrolled into view, and (b) ignore a
programmatic DOM `Range` — a CDP `Input.insertText` then *appends* instead of
replacing. Replace via `execCommand('selectAll')` then `execCommand('insertText', …)`,
which flow through the `beforeinput` pipeline Lexical reconciles its editorState
from, so the form registers as dirty and Save persists. The headline form has a
direct route (`/in/me/edit/intro/`); the About form redirects to the profile on
direct nav and opens only via its pencil (an SPA click that is racy, hence the
open-retry loop). **Status:** set-profile-field works for headline + About;
the broader click-verb question is open.

---

## 2026-06-01 login.tcl `--check` reports `unknown` for a logged-in session

**Symptom:** `login.tcl --check` against an active, logged-in session returns `{"status": "unknown"}` instead of `already_logged_in`. The page was the normal logged-in feed (title `Feed | LinkedIn`, ~7.8 MB DOM, no checkpoint redirect), yet `login_state` matched none of its branches and fell through to `unknown`.

**Repro:** with a logged-in session, `browser-serialiser linkedin.com/login --check`. Observed 2026-06-01.

**Cause:** `login_state` (login.tcl:101-115) detects the logged-in state with class-substring selectors: `[class*="global-nav__me"]`, `a[href*="/in/"][class*="global-nav"]`, `main [class*="feed"]`, `div[class*="feed-shared"]`. LinkedIn randomises class names per session (the skill's own DOM notes say never to select by class), so on the current feed render these match nothing; `has_nav` and `has_feed` are both false and the function returns `unknown`. The logged-out branches (fastrack CTA, login form) use more stable selectors, which is why logged-out detection still works.

**Impact:** a caller that gates on `already_logged_in` before fetching reads a healthy session as indeterminate, and either aborts or proceeds blind. Harmless in isolation, but it defeats the pre-fetch session check.

**Proposed fix direction:** detect logged-in by a stable signal rather than class substrings (the page title `Feed | LinkedIn` or locale equivalent, the `/feed` landing URL, or a structural/aria landmark), paired with the existing negative login-form test. Verify against both a live logged-in and a live logged-out session before shipping, since the failure mode is exactly a false state read.

**Status:** open.

## 2026-04-17 parse-search.tcl: role field contains adjacent profile's name

**Symptom:** parsed search results pair one profile's name with the *next* profile's headline. When a calling agent uses the output to populate a roster, some rows end up with another person's NAME written into the role field.

**Repro:** LinkedIn faceted people search, e.g.

```
https://www.linkedin.com/search/results/people/?network=%5B%22F%22%5D&geoUrn=%5B%22101452733%22%5D&titleFreeText=CEO&origin=FACETED_SEARCH
```

Saved HTML examples may still exist at `/tmp/linkedin-1a-*.html` for a short window after filing.

**Evidence (from chris-insurance-broking campaign, 2026-04-17, format `name | parsed role`):**

- `Lachlan Harcourt | Phil Hobson`  ← "Phil Hobson" is the next profile in the result list
- `Varun Sikand | Jason Simcocks`
- `Stella Petrou Concha | Garry Horsnell`
- `Adi Roy Chowdhury | Frank Lampert`
- `Tammy Gleeson | Melvelle Equipment Corp`  ← company name as role, another alignment failure
- `Sahreena Mohammed | Trust, integrity, accountability, empathy, humility, resilience, vision, influence, positivity`  ← soft-skill list from elsewhere on the card

**Additional evidence (spar-campaigns sweep, 2026-04-20, `sculpture festival director Queensland` on Weiwu's session):**

- `Andrew Antonopoulos | Executive Director at SWELL Sculpture Festival`  ← the SWELL headline actually belongs to Dee Steinfort (genuine SWELL Executive Director, adjacent card). Andrew Antonopoulos (`/in/andrew-antonopoulos/`) is an R&D-tax platform founder at Synnch in Melbourne, no SWELL connection. A direct profile fetch confirmed the mis-pairing. The bled pairing was propagated as a cross-lead from corporate-team-experience to event-producer and produced a roster row with no valid outreach channels — flagged later by `spar-progress.tcl`. Downstream cleanup: negative-cache Andrew Antonopoulos row in `event-producer/roster.tsv`.
- `Lincoln Williams | Creative Director at Ravel + Chairperson at Swell Sculpture`  ← surfaced in the same sweep and rostered without direct-profile verification. Could be a genuine SWELL board member or another bled pairing; not confirmed either way.

**Likely cause:** `parse-search.tcl` walks visible text linearly (`>content<` regex) and pairs each name with whatever headline text appears next. LinkedIn's lazy-loaded result cards don't always place the name and headline in stable order once the DOM has been rendered, so cross-card pairing happens.

**Proposed fix direction:** parse per result card boundary rather than linearly across the document. Card boundaries can be detected by the recurring profile-URL anchor (`/in/<slug>/`); everything between two such anchors belongs to one person.

**Defensive pattern for callers until the parser is fixed:** never roster a parse-search-derived candidate without a confirming direct profile fetch whose `<title>` name AND current-org line match the parsed headline. If the URL turns out to belong to a different person, negative-cache the row (star=0, date_excluded) — do NOT keep it as an active row with `verified=no`, because `spar-progress.tcl` cannot tell the difference between "pending verification" and "verification already failed, do not outreach".

**Impact:** downstream filters on role fail to catch wrong people; roster rows carry nonsense role strings that require human cleanup.

**Status:** open.

---

## 2026-04-20 Commercial Use Limit (CUL) — soft monthly cap on people search

**Symptom:** after sustained people-search activity within a calendar month, LinkedIn shows a Spanish-language warning banner "Has llegado al límite mensual de búsquedas de perfiles" ("You have reached the monthly profile search limit") and degrades search-result count to ~6 profiles per query (down from ~18-25 typical for the same query).

**Repro:** ran ~12-13 people searches across one session on one logged-in LinkedIn account (corporate-team-experience S₅: 6 queries, event-producer S₃: 3 queries, wedding-planner S₄: ~3 queries before the banner), then the banner appeared mid-batch. Note: precise pre-CUL fetch count cannot be re-derived from the session log because tally was kept in prose; "13" is a working estimate, not an audited count. Same machine, switching to a second LinkedIn account on a separate user-data-dir was unaffected — confirming the cap is per-account, not per-IP.

**Behaviour observed:**

- Search still works — does NOT block the request entirely.
- Result count is reduced (~6 vs typical ~18-25 for the same query).
- Banner text contains the substring "límite mensual" and "Has llegado" (also the upgrade-prompt button "Actualizar").
- `<title>` remains the normal "Buscar | LinkedIn" / "Search | LinkedIn" — does NOT change to a Sign-In or error page.
- Walled state persists across sessions, browser restarts, and different fetch URLs. Resets at calendar-month boundary (LinkedIn's Commercial Use Limit policy).

**Cached failure DOM example:** `example-cul-quota-wall.html` in this directory — captured from a chromium fetch of `https://www.linkedin.com/search/results/people/?keywords=PCO%20Brisbane&origin=GLOBAL_SEARCH_HEADER` while Chris's account was walled. Search the file for "límite mensual" or "Actualizar" to find the banner DOM placement.

**Open question — degradation regime:** unknown whether the ~6 results returned in degraded mode are the *top 6* of what would have been the normal ~25 (ranking-preserving), or are randomised / sampled differently. This matters for downstream analysis: if ranking is preserved, a degraded query that returns 0 on-segment results is a weaker form of the same negative signal a non-degraded zero would give; if the degradation is randomised/noisy, a degraded zero is not a signal at all. To characterise: when CUL is active, run the same query in two consecutive fetches a few minutes apart. If the 6 results are identical, the regime is ranking-preserving; if they differ, it's not. Not done in tonight's session.

**Implications for callers:**

- A simple `<title>`-Sign-In check is insufficient. Add a check for `límite mensual` / `límite` / monthly-limit substring in DOM body to detect the walled state.
- Walled state is not a hard stop — degraded results may still contain useful candidates, but yield is much lower. Cost-per-fetch effectively halves once walled.
- Best mitigation: maintain a second logged-in LinkedIn account on a separate user-data-dir, switch to it when the wall hits.
- Triggers per-account, not per-IP — the second account on the same machine is unaffected.
- Trigger threshold is approximately 12-15 people searches in a session (roughly — needs more measurement). The cap is part of LinkedIn's Commercial Use Limit policy and the official threshold is documented as fuzzy.

**Status:** documented; no fix possible at the LinkedIn level (it's a deliberate platform constraint). Skill callers should plan for it.

---

## 2026-04-20 Profile detail-page lazy-load — `--dump-dom` doesn't capture body sections

**Symptom:** fetching `/in/USERNAME/` via `chromium --dump-dom` captures only the profile header (name, headline, current org, education line, location, mutual count). Experience timeline, About text, Skills, recent posts, recommendations, and "People also viewed" are all absent from the DOM dump.

**Repro:** fetched `https://www.linkedin.com/in/brittniven/` and `/in/brittniven/details/experience/` — both via Chris's session and Weiwu's session — same result on both sessions.

**Capture surface (what survives `--dump-dom`):**

- Title + headline
- Current organisation (from "{Org} · {Education}" footer line)
- Education institution (single line)
- Location (city/state/country)
- Mutual connection count and one mutual name

**Capture failures:**

- Experience timeline (career history)
- About / Summary text
- Skills
- Recent activity / posts / comments
- Recommendations
- "People also viewed" / "More profiles for you"
- Endorsements

**Cause:** LinkedIn 2026 lazy-mounts all body sections client-side via React after `load` event. `--dump-dom` captures the DOM at the `load` event, before lazy-mount runs. The detail subpages (`/details/experience/`, `/details/education/`) have the same lazy-load behaviour.

**Implications for callers:**

- Profile fetches add little marginal information beyond what search-result snippets already provide. Skip per-candidate profile fetches when the search snippet is clear; reserve fetches for ambiguous snippets.
- Full SPAR-P profile structure (career history table, public statements, "who they know") is unpopulable from `--dump-dom` alone. Profiles should be marked low yield honestly with sections noted "(not captured by --dump-dom)".
- Social-graph expansion (PAV-walking, commenter chains) is impossible without a scroll-aware browser automation layer. Falling back to keyword-only semantic expansion is the working alternative.

**Proposed fix direction:** add a CDP (Chrome DevTools Protocol) helper to the skill that scrolls the profile, waits for lazy-mount, then dumps. Out of scope for the present skill version; flagged for future work.

**Status:** documented; needs scroll-aware fetcher to fully resolve.

---

## 2026-04-17 titleFreeText URL parameter ignored by LinkedIn search

**Symptom:** adding `titleFreeText=<role>` to the people-search URL produces identical result sets regardless of the role value. Tested with `CEO`, `CFO`, `CIO`, `Managing Director`, `Founder`, `Owner` — all six returned the same 26 results for an AU geoUrn and the same 21 for an NZ geoUrn.

**Likely cause:** LinkedIn's faceted people-search endpoint does not honour `titleFreeText` as a query parameter (either the parameter name has changed or it was never accepted on the URL — it may only be settable via the in-page filter UI).

**Impact on skill:** if the skill doc (SKILL.md / skill.md) recommends `titleFreeText` as a way to narrow by role, that recommendation is stale. Calling agents building query matrices around `titleFreeText` will produce duplicate result sets and waste fetches.

**Proposed fix direction:** either find the current working parameter name (if any) via in-app network capture and update the skill doc, or document that role filtering must be done post-parse by the caller.

**Status:** open.
