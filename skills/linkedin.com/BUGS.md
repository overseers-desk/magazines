# LinkedIn skill — bugs and platform findings

Each entry carries its own status. A closed entry stays for the measurement in it, and because the behaviour it describes is LinkedIn's and tends to return.

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

## 2026-04-17 auth-parse-search.tcl: role field contains adjacent profile's name

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

**Cause (confirmed 2026-08-14):** two faults, one of them larger than the symptom above suggested. The parser harvested every `/in/` link on the page and then took a ±2000/3000-character window of visible text around each. A result card contains more profile links than its own: the "shared connections" line names two other members and links them. So those third parties entered the result set as if they were search hits, and the text window then handed them the card owner's headline. The window also spans the card boundary, which is the adjacent-card bleed originally filed.

Measured on `example-cul-quota-wall.html`: the old parser reported **6 profiles** for a page holding **3 results**. Of the three extra, two were shared-connection mentions inside one card and one was the signed-in viewer's own profile, picked up from the page chrome. `Caitlin Barnes-Whitaker` was reported carrying `Madalena Lopes Lottering`'s name and headline.

**Fixed 2026-08-14** (commits `60167a7`, `9fce887`). Cards are separated by `<hr role="presentation">`, the one structural landmark on a page whose class names are randomised per session. The parser cuts there, takes the first text-bearing anchor as the person, and reads the following paragraph runs as headline and location; shared-connection names are reported inside the card they belong to, in a `shared_connections` field, and are no longer rows. Paragraph text is matched to the first closing tag and flattened, because the live page wraps it a span deep while the capture kept here does not.

**Consequence for counts recorded elsewhere in this file:** every result count taken from the old parser is inflated by the same fault. See the commercial-use-limit entry, whose "~6 results when degraded, ~18-25 typical" figures were measured with it. A real page carries **10 results**.

**Status:** closed.

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

**Correction (2026-08-14) — the size of the limit.** LinkedIn's help page states the rule: searching profiles counts, as does browsing them through "People Also Viewed" and viewing members on a Page's People tab; name searches from the top-of-page box, viewing direct connections from the Connections page, and job searches do not. It resets midnight PST on the 1st, the size is undisclosed, and LinkedIn will neither report what remains nor lift it. Third-party trackers put a free account between 250 and 350 searches a month. Note the exemption covers the **Connections page**, not a people search filtered to first-degree; secondary sources round that off to "first-degree searches are free", which is their inference and not LinkedIn's text.

The "~12-13 searches in a session" figure above is not a contradiction of a monthly meter of that size, and was never an audited count: that session's thirteenth search may have been the month's three-hundredth.

**Correction (2026-08-14) — the result counts.** The counts in this entry were measured with the pre-fix `parse-search`, which reported every profile link on the page as a result, including the shared-connection names inside other people's cards and the viewer's own profile. Re-parsed with the card-boundary parser, the cached walled page holds **3 results**, not 6. A normal page holds **10** results, not 18-25; a live two-page read returned exactly 20 distinct people.

**Detection (2026-08-14):** implemented. A walled page carries LinkedIn's own paywall marker in its upsell link, `upsellSlotId=SEARCH_RESULT_PAYWALL_PEOPLE_DROP` (and `premium_people_search_usage_upsell_drop`). These are tracking constants rather than prose, so matching them works whatever language the account renders in, which the banner-text check proposed above would not. `parse-search` reports it as `state: "metered"` beside the results.

**Status:** the limit is a platform constraint and stays. Detection is done; callers read `state`, and `cost` for what each call spent.

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

**Status (2026-06-25):** mostly resolved. `parse-profile` now scroll-hydrates and, by default, fetches the dedicated details pages (`/details/experience/`, `/details/skills/`), parsing Experience into structured entries (title/company/start/end/current) and Skills into a list. It emits a `coverage:` block and never reports an unfetched section as fact (`current_company` comes from the ongoing position, not the headline). **About** is the remaining holdout: it lazy-mounts on the main page and is often absent from the dump even after scrolling, so it is marked `about: not_found` rather than guessed. "People also viewed" / recommendations / endorsements are still not parsed (not needed by current callers).

---

## 2026-04-17 titleFreeText URL parameter ignored by LinkedIn search

**Symptom:** adding `titleFreeText=<role>` to the people-search URL produces identical result sets regardless of the role value. Tested with `CEO`, `CFO`, `CIO`, `Managing Director`, `Founder`, `Owner` — all six returned the same 26 results for an AU geoUrn and the same 21 for an NZ geoUrn.

**Likely cause:** LinkedIn's faceted people-search endpoint does not honour `titleFreeText` as a query parameter (either the parameter name has changed or it was never accepted on the URL — it may only be settable via the in-page filter UI).

**Impact on skill:** if the skill doc (SKILL.md / skill.md) recommends `titleFreeText` as a way to narrow by role, that recommendation is stale. Calling agents building query matrices around `titleFreeText` will produce duplicate result sets and waste fetches.

**Cause (confirmed 2026-08-14):** the key does not exist. LinkedIn's own people-search filter bar sends `title`; the request payload embedded in `example-cul-quota-wall.html` enumerates the whole vocabulary and `titleFreeText` is not in it. An unrecognised key is discarded in silence, which is why six job titles gave one result set.

**Fixed 2026-08-14** (commit `2dea136`). `parse-search` takes LinkedIn's own key list and refuses anything outside it by name, so a mistyped or invented filter fails loudly instead of returning a plausible result set for a filter that never applied. The accepted keys are listed in SKILL.md, `title` among them.

**Status:** closed.

---

## 2026-08-14 `connectionOf` reads only the first id — several people cost several searches

**Symptom:** naming several members in the people-search `connectionOf` filter returns the first one's connections alone, with no error and no sign that the others were dropped.

**Repro:** two first-degree members of the signed-in account, A and B, whose mutual-connection sets are disjoint. `connectionOf=["A"]` returned 4 people; `connectionOf=["B"]` returned 5, sharing none of A's. `connectionOf=["A","B"]` returned exactly A's 4.

That rules out both alternatives: a union would have returned 9, an intersection 0.

**Consequence:** covering several people's networks in one call costs one search per person against the monthly allowance, and the merge is done by the caller. `parse-search` does this walk and tags each result with the people it was found through (`via`). The option to put several ids in one query was removed rather than kept as a cheaper mode, because it answers for one person while reading as though it answered for all.

**Not tested:** whether the same first-id-only rule governs the other list-valued filters (`geoUrn`, `currentCompany`, `industry` and the rest). Do not assume several values in any of them widen the search.

**Status:** documented; the behaviour is LinkedIn's.

---

## 2026-08-14 People-search pagination is `page=N`, ceiling 100 pages

**Finding:** `&page=N` on `/search/results/people/` works and returns 10 results a page. A live two-page read returned 20 distinct people with no overlap. A free account stops at 100 pages or 1000 results; past the ceiling LinkedIn serves page one again rather than erroring, so a caller reading on would silently re-read the start.

The page states **no result total** at all, so there is no count to page against. `parse-search` reports `total: null`, and signals more results by whether paging stopped on the caller's limit or on a page that brought nothing new.

**Untested:** whether reading page 2 spends a second unit of the monthly search allowance. LinkedIn does not report what remains, so this is not cheaply measurable; `parse-search` counts queries and page reads separately so the answer can be read off accumulated use.

**Status:** documented.

---

## 2026-08-14 li-connections returns profile urns with every other field null

**Symptom:** `li-connections` reports success and enumerates the full connection list, but each record carries only `profile_urn`. `first_name`, `last_name`, `profile_url` and `connected_at` are all null.

**Repro:** `browser-serialiser linkedin.com/auth-li-connections '{"maxScrolls":2}'` returned 516 connections, 0 of them with a name.

**Impact:** a caller reading the documented shape gets an identity-only list. It is enough to feed `connectionOf`, which is how it was used here, and not enough for anything that needs to show or match a person. The failure is silent: the envelope reports no fault.

**Likely cause, unverified:** the card patterns the playbook matches (the bold display-name node, the "Connected on" line, the `/in/<slug>/` link) against the React server-component payloads. The urn comes from a different pattern, the compose link, which still holds. Not investigated; found while picking test targets for the search work.

**Status:** open.

---

## 2026-08-14 `browser-serialiser --dump` writes double-encoded UTF-8

**Symptom:** a page dumped with the ad-hoc `--dump` fetch has its non-ASCII characters doubly encoded. A right single quote (U+2019, bytes `e2 80 99`) arrives as `c3 a2` `80` `99`, rendering as `â` followed by two stray bytes. The file passes as valid UTF-8, so the corruption is not visible to `file`.

**Repro:** dump any LinkedIn search page and look at a headline containing a typographic apostrophe. Python and Tcl read the file identically, so the fault is in the bytes written, not in the reader.

**Scope:** the `--dump` path only. A skill running inside the harness reads the DOM through the `dump` verb, which returns a decoded string; the same text came back correct through `parse-search` on the same page. So this affects ad-hoc fetches and any parser tested against a dumped file, not the skills in production.

**Status:** open; in the harness, not this skill.
