---
name: facebook
description: "search people, read profiles, extract posts with hashtags and tagged people, check keywords, dump reel comments to markdown; find someone's posts/activity. Runs under the serialised-browsing harness; does not use Google Chrome."
argument-hint: <name, URL, or search terms>
---

## Execution model

This workflow produces large DOM outputs (1-15MB per page). Spawn a **Sonnet subagent** to run it so the main conversation context is not consumed. Each script runs under the **serialised-browsing** harness: `browser-serialiser` loads the skill into a policed safe interpreter and drives the browser through the command surface (no raw CDP, anti-ban pacing enforced). Invoke by reference, `browser-serialiser facebook.com/<script> <args>`; the subagent need not paste scripts inline. See the serialised-browsing skill for the command surface.

Each script navigates to the relevant page, dumps the rendered DOM (or, for reel comments, harvests the page's own GraphQL responses), and emits its report in one step. A profile reference is a bare handle, a numeric id, or a full URL.

## Prerequisites

A logged-in Facebook session in the user-data-dir the serialiser targets.

### No-session detection

When no one is logged in, Facebook embeds `"USER_ID":"0"` and `"ACCOUNT_ID":"0"` in the page config and serves a login wall (`id="login_form"`, `input name="email"`, `input name="pass"`, action `login/device-based/regular/login/`). The `"USER_ID":"0"` marker is the reliable one: it fires even on a public profile whose `<title>` still reads like a real page (e.g. `Mark Zuckerberg | Facebook`) behind the wall, where a title-only check would be fooled. When logged in, `USER_ID`/`ACCOUNT_ID` carry the real numeric account id.

The harness classifies a login/checkpoint redirect into a terminal `logged-out`/`checkpoint` state; the scripts also check the no-session markers in the dumped DOM and emit `ERROR: Facebook: not logged in ...`. If a read returns this, surface it to the user verbatim — do not retry blindly or report empty results.

Facebook may otherwise serve different DOM structures depending on the target profile's privacy settings and the session locale.

## Pacing and walls

The harness owns pacing+jitter on every wire-touching verb and the 429/login backoff, so a script cannot burst. A page settles for a few seconds before its rendered DOM is read. On a login/checkpoint redirect the run goes terminal at once; a script never retries a wall.

## 1-2. Search for people

```bash
browser-serialiser facebook.com/parse-search SEARCH TERMS
```

Pass terms as plain arguments (the script URL-encodes them and navigates to `/search/people/?q=...`). Outputs profile URLs (both vanity `/username` and numeric `/profile.php?id=`) with nearby visible text.

### Search variants for hard-to-find people

Try in order if no results:

1. `Name City` — `Vikram Mazumder Mumbai`
2. `Name Company` — `Vikram Mazumder Google`
3. `Name Country` — `Vikram Mazumder India`
4. Alternative romanisations — for Indian names try Mazumdar/Mazumder/Majumder/Majumdar; for Chinese names try Lin/Lim/Lam etc.

## 3-4. Fetch and parse a profile

```bash
browser-serialiser facebook.com/parse-profile HANDLE_OR_URL
```

Navigates to the profile (a bare handle resolves to `https://www.facebook.com/HANDLE`; a numeric id to `/profile.php?id=ID`) and extracts name, meta descriptions, JSON-LD Person data (if present), bio/intro lines, role/work mentions, location mentions, and visible text blocks.

For richer bio data, point the same script at the about page URL: `https://www.facebook.com/HANDLE/about` (numeric: `/profile.php?id=ID&sk=about`).

## 5. Parse recent posts

```bash
browser-serialiser facebook.com/parse-posts HANDLE_OR_URL
```

Navigates to the profile and extracts per post: text content, hashtags, tagged/mentioned people and pages (with profile URLs), and shared-from source. Produces a summary of all hashtags and tagged entities across posts.

The script auto-detects the profile owner's ID to exclude self-references. To override:

```bash
browser-serialiser facebook.com/parse-posts HANDLE_OR_URL --owner-id 100006232604720
```

How it works: each Facebook post carries a unique `__cft__[0]` token in all its links. The script uses `data-ad-preview="message"` markers to locate post boundaries, then associates hashtag and profile links via these tokens. Comments are excluded by limiting tag search to the header + content region.

## 6. Fetch a single reel / page post with rendered counts and commenters

A `https://www.facebook.com/reel/{ID}` URL renders an empty shell with no content. Use the page-post permalink form:

```bash
browser-serialiser facebook.com/parse-reel https://www.facebook.com/PAGE_ID/posts/POST_ID
```

`POST_ID` for a recent reel can be found in the main profile dump (§3). Look for `"post_id":"NNNNNNNNN"` adjacent to the reel's `/reel/{ID}` URL — there is one such pair per recent reel embedded in the profile JSON.

Outputs page name, caption (from `<title>`), counts from both embedded JSON (`reaction_count`, `share_count`, sometimes `total_comment_count`) and the rendered engagement bar (reactions / comments / shares visible to the viewer), and the commenters whose names render in the DOM along with the comment body text adjacent to each name.

Limit: Facebook lazy-loads comments. A single render yields the first ~5-10 comments out of the full thread. The total count in the engagement bar is the true number; do not invent further commenters beyond what the parser extracts. For the full comment thread use §9.

## 7. Parse reels-tab view counts

```bash
browser-serialiser facebook.com/parse-reels-tab HANDLE_OR_URL
```

Navigates to the profile's reels tab (`/HANDLE/reels`, or `/profile.php?id=ID&sk=reels_tab` for a numeric id) and extracts per visible reel card: reel URL and view count (e.g. `191K`). The render yields the first few cards before lazy-load — typical yield is 3 reels.

How it works: each reel card has an eye-icon SVG with a fixed path string (`M7.5 10a2.5...`); the view count is the first `<span>` after it. The reel ID is the closest `/reel/NNNNN` link occurring before that SVG.

## 8. Keyword search

```bash
browser-serialiser facebook.com/keyword-search HANDLE_OR_URL keyword1 keyword2 ...
```

Navigates to the profile, then for each keyword shows the count and surrounding context — useful for checking whether a profile mentions specific companies, roles, locations, or topics without reading the entire DOM. The first argument is the profile reference; the rest are keywords.

## 9. Dump reel comments to Markdown

The reel viewer (`https://www.facebook.com/reel/{id}`) is an authenticated SPA that defers comment loading until the Comment button is clicked, and uses "Most relevant" sort by default. The reel-comments script drives the viewer: it navigates via `capture` (so the page's own GraphQL comment responses are buffered — the primary private-data path), clicks Comment, switches sort to an unfiltered view, scrolls and expands "N replies" / "See more" until the harvested set stops growing, harvests the GraphQL bodies for canonical comment text, and emits the parsed Markdown directly.

```bash
browser-serialiser facebook.com/reel-comments-cdp https://www.facebook.com/reel/REEL_ID --max-rounds 200
```

`facebook.com/parse-reel-comments URL` is the same end-to-end (it reuses the same driver and renderer); either reference produces the Markdown.

Output format is raw: `Author · age` followed by body lines for each top-level comment, with replies indented under their parent (prefixed with `↳`). No headers, no profile URLs, no comment IDs — designed for reading.

The number of comments returned matches what Facebook serves over its GraphQL endpoint. The viewer's header count (e.g. "630 comments") is often higher than what's actually returned because Facebook counts include spam-filtered/deleted/cross-universe-aggregated items that the API does not serve to a logged-in viewer.

## DOM parsing notes

Facebook (as of 2026) uses randomised CSS class names (e.g. `x1lliihq x6ikm8r`), no semantic IDs, deeply nested div hierarchies, lazy loading, and pages of 1-15MB. The scripts extract `<title>`, `<meta>` tags, JSON-LD, and visible text via `>content<` pattern matching. Do not select by CSS class name — they change between sessions.
