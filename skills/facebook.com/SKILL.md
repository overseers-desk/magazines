---
name: facebook
description: "search people, read profiles, extract posts with hashtags and tagged people, check keywords, dump reel comments to markdown; find someone's posts/activity."
argument-hint: <name, URL, or search terms>
---

## Execution model

This workflow produces large DOM outputs (1-15MB per page). Spawn a **Sonnet subagent** to execute it so the main conversation context is not consumed. Tell the subagent to use the scripts in `${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/` — do not paste scripts inline.

## Prerequisites

A logged-in Facebook session in the user-data-dir that `not-google-chrome` targets.

### No-session detection

When no one is logged in, Facebook embeds `"USER_ID":"0"` and `"ACCOUNT_ID":"0"` in the page config and serves a login wall (`id="login_form"`, `input name="email"`, `input name="pass"`, action `login/device-based/regular/login/`). The `"USER_ID":"0"` marker is the reliable one: it fires even on a public profile whose `<title>` still reads like a real page (e.g. `Mark Zuckerberg | Facebook`) behind the wall, where a title-only check would be fooled. When logged in, `USER_ID`/`ACCOUNT_ID` carry the real numeric account id.

`parse-profile.tcl` checks these markers and exits with `ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry.` The reel CDP fetcher (`reel-comments-cdp.tcl`) runs the same check after navigation and exits with the same message rather than returning an empty harvest. If a read returns this, surface it to the user verbatim — do not retry blindly or report empty results.

Facebook may otherwise serve different DOM structures depending on the target profile's privacy settings and the session locale.

## Skill-specific Chrome-compatible flag

The wrapper handles standard flags (headless, window size, user agent, user-data-dir, flock, timeout). This skill appends `--virtual-time-budget=3000` to allow Facebook's JS to render. Increase to 45000 on slow connections.

## 1. Search for people

```bash
not-google-chrome \
  "https://www.facebook.com/search/people/?q=SEARCH_TERMS" \
  --virtual-time-budget=3000 \
  > /tmp/facebook-search-results.html 2>/dev/null
```

URL-encode search terms (spaces become `%20`).

### Search variants for hard-to-find people

Try in order if no results:

1. `Name City` — `Vikram%20Mazumder%20Mumbai`
2. `Name Company` — `Vikram%20Mazumder%20Google`
3. `"Name" Country` — `Vikram%20Mazumder%20India`
4. Alternative romanisations — for Indian names try Mazumdar/Mazumder/Majumder/Majumdar; for Chinese names try Lin/Lim/Lam etc.

## 2. Parse search results

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-search.tcl /tmp/facebook-search-results.html
```

Outputs profile URLs (both vanity `/username` and numeric `/profile.php?id=`) with nearby visible text.

## 3. Fetch a profile

For username-based profiles:

```bash
not-google-chrome \
  "https://www.facebook.com/USERNAME" \
  --virtual-time-budget=3000 \
  > /tmp/facebook-profile.html 2>/dev/null
```

For numeric-ID profiles:

```bash
not-google-chrome \
  "https://www.facebook.com/profile.php?id=NUMERIC_ID" \
  --virtual-time-budget=3000 \
  > /tmp/facebook-profile.html 2>/dev/null
```

### Optional: Fetch the About page for richer bio data

```bash
not-google-chrome \
  "https://www.facebook.com/USERNAME/about" \
  --virtual-time-budget=3000 \
  > /tmp/facebook-about.html 2>/dev/null
```

For numeric-ID profiles, the about URL is `https://www.facebook.com/profile.php?id=NUMERIC_ID&sk=about`.

## 4. Parse profile

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-profile.tcl /tmp/facebook-profile.html
```

Extracts name, meta descriptions, JSON-LD Person data (if present), bio/intro lines, role/work mentions, location mentions, and visible text blocks.

Optionally parse the about page too:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-profile.tcl /tmp/facebook-about.html
```

## 5. Parse recent posts (optional)

Uses the same profile HTML from step 3 (no additional fetch):

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-posts.tcl /tmp/facebook-profile.html
```

Extracts per post: text content, hashtags, tagged/mentioned people and pages (with profile URLs), and shared-from source. Produces a summary of all hashtags and tagged entities across posts.

The script auto-detects the profile owner's ID to exclude self-references. To override:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-posts.tcl /tmp/facebook-profile.html --owner-id 100006232604720
```

How it works: each Facebook post carries a unique `__cft__[0]` token in all its links. The script uses `data-ad-preview="message"` markers to locate post boundaries, then associates hashtag and profile links via these tokens. Comments are excluded by limiting tag search to the header + content region.

## 6. Fetch a single reel / page post with comments

Fetching `https://www.facebook.com/reel/{ID}` directly returns an empty shell with no rendered content. To get the rendered post with caption, counts, and visible comments, use the page-post permalink form:

```bash
not-google-chrome \
  "https://www.facebook.com/PAGE_ID/posts/POST_ID" \
  --virtual-time-budget=5000 \
  > /tmp/facebook-post.html 2>/dev/null
```

`POST_ID` for a recent reel can be found in the main profile dump (step 3). Look for `"post_id":"NNNNNNNNN"` adjacent to the reel's `/reel/{ID}` URL — there is one such pair per recent reel embedded in the profile JSON.

Parse with:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-reel.tcl /tmp/facebook-post.html
```

Outputs page name, caption (from `<title>`), counts from both embedded JSON (`reaction_count`, `share_count`, sometimes `total_comment_count`) and the rendered engagement bar (reactions / comments / shares visible to the viewer), and the commenters whose names render in the DOM along with the comment body text adjacent to each name.

Limit: Facebook lazy-loads comments. A single headless render yields the first ~5-10 comments out of the full thread. The total count in the engagement bar is the true number; do not invent further commenters beyond what the parser extracts.

## 7. Parse reels-tab view counts (optional)

For a profile's reels tab (`...?sk=reels_tab` or `/USERNAME/reels`), fetch the page as in step 3, then:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-reels-tab.tcl /tmp/facebook-reels-tab.html
```

Extracts per visible reel card: reel URL and view count (e.g. `191K`). Headless dumps render only the first few cards before lazy-load — typical yield is 3 reels.

How it works: each reel card has an eye-icon SVG with a fixed path string (`M7.5 10a2.5...`); the view count is the first `<span>` after it. The reel ID is the closest `/reel/NNNNN` link occurring before that SVG.

## 8. Keyword search (optional)

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/keyword-search.tcl /tmp/facebook-profile.html keyword1 keyword2 ...
```

Checks whether a profile mentions specific terms and shows surrounding context.

## 7. Dump reel comments to Markdown

The reel viewer (`https://www.facebook.com/reel/{id}`) is an authenticated SPA
that defers comment loading until the Comment button is clicked, and uses
"Most relevant" sort by default. A plain `--dump-dom` captures the player
chrome but no comments. Use the CDP fetcher, then the parser.

Prerequisite: the user's snap chromium must be fully closed (the GUI holds
the user-data-dir lock; the `not-google-chrome --cdp` wrapper needs exclusive
access to launch its headless instance against the logged-in session).

The fetcher is a pure CDP client: the `not-google-chrome --cdp` wrapper owns
the browser (launch, flock, deadman timeout, snap-robust teardown, Singleton
lock cleanup) and exports `CDP_WS_URL`; the script connects to it. Run without
the wrapper and it exits with `ERROR: CDP_WS_URL not set`.

If there is no session, the fetcher exits after navigation with `ERROR:
Facebook: not logged in - no session in this profile...` (see No-session
detection above) instead of returning an empty harvest.

```bash
# 1. Fetch — drives CDP: open Comment panel, switch sort to All comments,
#    scroll and expand "N replies" / "See more" until the harvested set
#    stops growing. Each comment article is captured into a JS-side dict
#    (resilient to virtualization) and the comment list is dumped in thread
#    order at the end. The fetcher also intercepts every GraphQL response
#    and writes a sidecar JSON of {legacy_fbid: canonical_body_text} — used
#    by the parser to restore full text for comments truncated by 'See more'
#    in the DOM render. For a 600-comment reel this takes 3-5 minutes, so
#    raise the wrapper's deadman with -t (e.g. -t 600).
not-google-chrome --cdp -t 600 -- \
  tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/reel-comments-cdp.tcl \
  "https://www.facebook.com/reel/REEL_ID" \
  --out /tmp/reel-comments.html \
  --bodies-json /tmp/reel-bodies.json \
  --max-rounds 200 \
  --debug

# 2. Parse to Markdown. Pass --bodies-json so truncated bodies get backfilled
#    with canonical text from the GraphQL sidecar.
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/facebook.com/parse-reel-comments.tcl \
  /tmp/reel-comments.html \
  --bodies-json /tmp/reel-bodies.json \
  --md /tmp/reel-comments.md \
  --source-url "https://www.facebook.com/reel/REEL_ID"
```

Output format is raw: `Author · age` followed by body lines for each top-level
comment, with replies indented under their parent (prefixed with `↳`). No
headers, no profile URLs, no comment IDs — designed for reading.

The number of comments returned matches what Facebook serves over its GraphQL
endpoint. The viewer's header count (e.g. "630 comments") is often higher
than what's actually returned because Facebook counts include
spam-filtered/deleted/cross-universe-aggregated items that the API does not
serve to a logged-in viewer.

## DOM parsing notes

Facebook (as of 2026) uses randomised CSS class names (e.g. `x1lliihq x6ikm8r`), no semantic IDs, deeply nested div hierarchies, lazy loading, and pages of 1-15MB. The scripts extract `<title>`, `<meta>` tags, JSON-LD, and visible text via `>content<` pattern matching. Do not select by CSS class name — they change between sessions.
