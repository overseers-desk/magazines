---
name: instagram
description: "Search Instagram accounts, read profiles, and enumerate a profile's followers or following; find someone by name or handle. Also audits brand-account tag-reshare compliance."
argument-hint: <name, handle, or search terms>
---

## Execution model

Spawn a **Sonnet subagent** to run the workflow. Each script runs under the **serialised-browsing** harness: `browser-serialiser` loads the skill into a policed safe interpreter and drives the browser through the command surface (no raw CDP, anti-ban pacing enforced). Invoke by reference, `browser-serialiser instagram.com/<script> <args>`; the subagent need not paste scripts inline. See the serialised-browsing skill for the command surface.

## Prerequisites

A logged-in Instagram session in the user-data-dir the serialiser targets.

Note: `--lang` flags do not override Instagram's locale; it is a server-side account setting. The parsers are locale-agnostic, so this does not matter.

If a request redirects to `/accounts/login/` or returns empty JSON, the session has expired or been rate-limited. The harness classifies this as a terminal `logged-out`/`checkpoint` state and stops; let the user log in interactively before retrying.

## Pacing and walls

The harness owns pacing+jitter on every wire-touching verb and the 429/login backoff, so a script cannot burst. A profile view settles for a few seconds before the page-issued JSON is read; search reads the topsearch endpoint directly. On a 429 the harness backs off (capped) then goes terminal `rate-limited`; on a login/checkpoint redirect it goes terminal at once. A script never retries a wall.

## DM read-state policy

Before invoking any DM-content script (§9, and any future script whose filename carries `mark-seen`, `mutate-seen`, or `send`), name the specific thread(s) about to be touched and surface the read-state implication to the user, then wait for an explicit yes. For §9 the implication to surface is: this will only return content for threads already opened in the user's Instagram client; the script refuses unread threads and will not mark anything seen on the user's behalf.

§5 (`inbox-noninvasive.tcl`) is exempt — it reads inbox metadata only, never thread content, and blocks seen-mutation requests at the Fetch layer.

The internal refusal gate inside §9 is a backstop. A run without prior disclosure violates the policy even if the script would have refused anyway.

## 1-2. Search via the topsearch JSON endpoint

Instagram's rendered search page (`/explore/search/keyword/?q=...`) is GraphQL-hydrated and stays empty within a reasonable time budget. The internal endpoint `/web/search/topsearch/?query=...`, authenticated, returns clean JSON directly. The script navigates there, reads the JSON body, and prints the parsed report in one step:

```bash
browser-serialiser instagram.com/parse-search SEARCH TERMS
```

Pass terms as plain arguments (the script URL-encodes them). The topsearch response contains `users[]`, `hashtags[]`, and `places[]`. Each user includes `username`, `full_name`, `is_verified`, `is_private`, and (where applicable) `social_context` listing mutual followers — useful signal for disambiguation. The output is a ranked list of candidate handles with display name, verified/private flags, profile URL, and mutual-followers context.

## 3-4. Fetch and parse a profile

The script navigates to the profile, dumps the rendered DOM, and emits the canonical envelope in one step:

```bash
browser-serialiser instagram.com/ig-profile HANDLE
```

The output is the canonical envelope `{result, cursor, hasMore, fault}`. A profile is a single read, so `cursor` is null and `hasMore` is false. On success `fault` is null and `result` is the superset object — the server validates its required subset against `social/api/contracts/ig-profile.schema.json` and discards the rest, while a skill caller reads whichever fields it wants:

- `username`, `full_name`, `pk`
- `is_private` (boolean)
- `follower_count`, `following_count`, `media_count` — integers, or null when the page did not render them
- `category_name`, `biography`, `external_url`
- the extras `url`, `followers_raw`, `following_raw`, `posts_raw` (the rounded count strings as the header shows them, e.g. `27K`), `avatar`, `caption_snippet`, `og_description`, `meta_description`, `html_size`, `is_verified`, `business_category_name`

Instagram has no separate "about" page on the web; the counts, display name, avatar and recent-caption snippet come from the server-rendered `<meta>` tags (`og:title`, `og:image`, `og:description`, `meta name=description`), parsed positionally so they stay locale-agnostic. The exact follower count comes from the rendered header's `title=` attribute when present. `is_verified`, `business_category_name`, `biography` and `external_url` are pulled from inline-hydrated JSON when the page carries it — typically the viewer's own profile or one the viewer follows closely — and are null otherwise.

A removed or non-existent profile sets `result` to null and `fault` to `{shape:"removed", detail}`; a login wall (session expired or never logged in) sets `result` to null and `fault` to `{shape:"login_wall", detail}`.

## 5. DM inbox metadata (noninvasive)

This script reads inbox metadata only. It must not be modified to read individual thread content. If you need message content from a specific thread, that is a separate, invasive operation. Write a different script with a different name.

```bash
browser-serialiser instagram.com/inbox-noninvasive list
```

Emits JSON with one entry per thread: `username`, `full_name`, `thread_id`, `last_activity_iso`, `last_snippet` (up to 120 chars of the last message text or a type label), `unseen` (boolean), `is_group`.

Requires a logged-in session. Does not navigate to `/direct/inbox/` to avoid triggering a "user is viewing inbox" presence beacon. The script declares the seen-mutation URL patterns (`*/seen/*`, `*/mark_seen*`, `*item_seen*`, `*direct_thread*`) via the harness `veto` verb before the first navigation; the harness refuses any matching request so it cannot leave the browser. The read-state guarantee is structural — there is no runtime double-read needed.

## 6. Recent posts for a handle

```bash
browser-serialiser instagram.com/fetch-recent-posts posts HANDLE
browser-serialiser instagram.com/fetch-recent-posts posts HANDLE --limit 50
```

Default limit is 12. Pagination via the feed API's `next_max_id` cursor happens automatically when `--limit` exceeds 12. The script navigates to the profile page once to resolve the user_id (from inline JSON or the `web_profile_info` API, both covered by that nav), then reads `/api/v1/feed/user/<user_id>/` via the policed `api` verb in a loop until the limit is reached or `more_available` is false.

(`--raw-out PATH`, which writes the unparsed feed items to a file, is a direct-tclsh-only option; the serialiser path's safe interpreter has no file access, so the parsed JSON on stdout is the only output there.)

Each post entry includes:

- `post_id`, `shortcode`, `url`, `post_type` (image/video/carousel/reel), `taken_at_iso`
- `like_count`, `comment_count`, `play_count`, `ig_play_count`, `fb_play_count`, `view_count`, `media_repost_count`, `fb_like_count`, `fb_comment_count` (play/view/reshare null on stills; the `fb_*` are null unless the post was cross-posted to Facebook)
- `video_duration` (seconds, null on stills), `like_and_view_counts_disabled` (the creator hid metrics)
- `caption`, `hashtags` (regex-extracted from caption), `mentions` (regex-extracted from caption)
- `tagged_users` (the "tag people" feature on the post; aggregated across carousel slides)
- `coauthors` (the dual-author collab-post feature)
- `sponsors` (branded-content sponsor tags)
- `is_paid_partnership`, `location`

The five handle-bearing fields above (`mentions`, `tagged_users`, `coauthors`, `sponsors`, plus paid-partnership context) are what the collab-expansion script in §7 walks to find candidates.

## 7. Collab partner expansion (multi-handle spider)

```bash
browser-serialiser instagram.com/collab-expand expand handle1,handle2,handle3
browser-serialiser instagram.com/collab-expand expand handle1,handle2 --posts-per-handle 36
```

Walks a list of input handles, fetches recent posts for each (paginated via §6's helpers), and accumulates the union of `tagged_users`, `coauthors`, `sponsors`, and caption `mentions` across all posts. (The legacy `--from <file>` seed-list option is direct-tclsh-only; pass the CSV positional under the serialiser.) Outputs candidate handles NOT already in the input set, ranked by explicit-collab signal first (tagged + coauthor + sponsor counts) and then by caption-mention count and breadth of source handles.

Each candidate row carries the four per-signal counts, a `total`, and a sorted `sources` list of input handles whose posts surfaced the candidate. Multi-source candidates (handles surfaced by several different input accounts) rank higher than single-source ones at equal signal strength.

This is single-level expansion. For "spider" behaviour (recursively expanding), feed the top N candidates as input to a second run.

Default `--posts-per-handle` is 24 (about two pages). Pacing: roughly one feed page every 2 seconds, plus a 2-second gap between input handles. A run over 5 input handles at 24 posts each takes about a minute.

## 8. Post comments (for comment-circle discovery)

```bash
browser-serialiser instagram.com/fetch-post-comments comments SHORTCODE
browser-serialiser instagram.com/fetch-post-comments comments POST_ID
```

Accepts a shortcode (e.g. `DXsPrn5AvNH`), a full post_id from the feed API (`<media_id>_<user_id>`), or a bare numeric `media_id`. Shortcode-to-media-id conversion is a local base64 decode, so no extra fetch is needed to resolve. Navigates to the post permalink (the covering view), then reads `/api/v1/media/<media_id>/comments/` via the policed `api` verb.

Returns first-page comments only (typically 20-50, occasionally 1-2 if the post is lightly engaged or moderated). The first page is most-recent and has the highest signal for creator-on-creator engagement; older comments add noise. Pagination via `min_id` cursor can be added later if comment-circle yield proves insufficient.

Each comment row carries the four free significance signals:

- `is_verified` — Instagram's platinum-tier flag. Catches public-figure-tier accounts. Misses the meaty mid-tier creator case where neither party is verified.
- `has_default_avatar` — `true` when the user has not uploaded a profile picture (heuristic; checks for known default-avatar URL fragments and the API's `has_anonymous_profile_picture` flag). Throwaway accounts almost always have a default avatar.
- `text_length_words` — word count of the comment. A creator engaging another creator usually writes more than one word; a fan drops "❤️🔥".
- `comment_like_count` — likes on the comment itself. Weak but free signal.

Plus `username`, `full_name`, `text`, `created_at`, `comment_id`.

Workflow: comment-circle discovery promotes a commenter handle to a sweep candidate only if at least one of (`is_verified`, `text_length_words >= 3`, `has_default_avatar == false`) holds. This drops 80 to 95 percent of typical commenter sets before any profile fetch happens. Surviving handles enter the standard sweep pipeline (ig-profile then fetch-recent-posts), so the per-commenter profile fetch is just sweep doing its normal work, not a dedicated enumeration job. Instagram does not distinguish the request pattern.

The `comment_count_total` field in the response is the live count from this endpoint, which can differ from the cached count in the feed API. Treat the comments endpoint as authoritative.

## 9. DM thread history reader (seen threads only)

```bash
browser-serialiser instagram.com/read-seen-thread thread <thread_id> [--limit N]
browser-serialiser instagram.com/read-seen-thread by-handle <handle>   [--limit N]
browser-serialiser instagram.com/read-seen-thread all-seen             [--limit N]
```

Fetches message history from a DM thread for P-phase use. Companion to §5: §5 enumerates inbox metadata without ever touching thread content; §9 reads thread content but only for threads the operator has already marked seen. The hyphen-delimited word "seen" in the filename is load-bearing, parallel to "noninvasive" in §5.

The seen-only guarantee is enforced by reading the same `/api/v1/direct_v2/inbox/` endpoint §5 uses to check the thread's unread status BEFORE issuing any thread-content fetch. If `marked_as_unread` is true OR the viewer's `last_seen_at[viewer_id].timestamp` is older than `last_activity_at`, the script refuses with a structured error and never makes the thread-content call. The seen-mutation URL patterns are declared via the harness `veto` verb before any navigation, as a defensive backstop.

Per-message output includes `is_from_viewer` (whether the message is from the operator's side or the other party), `timestamp_iso`, normalised `text` (with bracketed type labels for `[shared post]`, `[reel-share]`, `[action]`, `[media]`, `[link]`, `[disappearing media]`, etc.), `item_type`, and `item_id`.

Verified 2026-05-12 against the live inbox: refusal path correctly skipped a thread carrying `marked_as_unread: true`; success path returned 9 messages across both directions from a seen thread. After both runs, the previously-unread thread was confirmed still unread by re-running §5, proving the gate did not leak a thread-content fetch onto the refused thread.

`all-seen` is the batch primitive for P: enumerate every thread in the current inbox, return parsed messages for the seen ones, and emit a separate `refused` list noting which threads were skipped and why. Useful when profiling many contacts in one pass.

## 10. Followers / following list extractor

```bash
browser-serialiser instagram.com/fetch-followers followers HANDLE [--limit N]
browser-serialiser instagram.com/fetch-followers following HANDLE [--limit N]
```

Enumerates `/api/v1/friendships/<user_id>/followers/` or `/.../following/` via the policed `api` verb. Resolves handle → user_id by reusing `sv_resolve_user_id` from §6 (the profile nav is the covering view), then paginates the cursor-based endpoint (25 users per page, `next_max_id`) until `--limit` is reached or the endpoint reports no more pages.

Default `--limit` is 500. The script prints JSON with a `users` array carrying `handle`, `user_id`, `kind`, `count_returned`, `limit_requested`, `stop_reason`, and `users`. (`--csv PATH`, which writes the rows to a file, is direct-tclsh-only; the serialiser path's safe interpreter has no file access.)

Per-entry fields:

- `user_id`, `username`, `full_name`
- `is_verified`, `is_private`
- `has_default_avatar` (same heuristic as §8 — known default-avatar URL fragments plus the API's `has_anonymous_profile_picture` flag)
- `profile_pic_url`

The five non-URL fields mirror the §8 comment-row shape, so the same sweep pre-filter (verified OR not-default-avatar OR ...) applies if the friendships output is fed into the standard sweep pipeline.

**Visibility and accuracy:**

- Private profiles return 0 users unless the logged-in viewer follows them. No workaround.
- The header counts shown by §4 (parsed from og:description) are server-cached and frequently drift a few percent from the enumerable list. Treat the friendships endpoint as authoritative for the list itself; treat the header count as authoritative only for "roughly how many."
- Order is reverse-chronological by relationship creation, not alphabetical or by engagement.

**Pacing and limits:** The friendships endpoint is one of the most aggressively throttled in IG's web API. The script paces ~2.5 seconds per page, which a small profile (a few hundred entries) absorbs cleanly. For larger profiles, expect soft-throttling (truncated pages, 429s, or "challenge_required") somewhere in the low thousands of entries per session. If `stop_reason` comes back as `error:HTTP 4xx` partway through, back off and re-run later — do not hammer.

`stop_reason` values: `limit` (hit the `--limit` cap), `exhausted` (endpoint returned no more pages), or `error:<detail>` (HTTP failure, often throttling).

Verified 2026-05-19 against `@_a.j.handyman_`: header counts 162 followers / 188 following; enumerated 162 followers (full match) and 182 following (6-entry gap, consistent with cached-header drift). Both lists written to CSV cleanly across 7-8 pages each.

## 11. Tag-reshare compliance audit

Built for SOP D40 (Social Media Reply) §6: the service team must reshare customer-tagged stories and posts to the brand's own story. This script audits which tags since `--since` were not reshared.

```bash
browser-serialiser instagram.com/audit-tag-reshares audit HANDLE --since 2026-05-01
```

The reshare-match heuristic (which inspects `reshared_reel.id`, `imported_taken_at`, and `reel_mentions[].user_id`) is best-effort and may need adjustment once real fields are inspected.

What the script pulls:

- **Tagged feed posts** — `/api/v1/usertags/<user_id>/feed/`, paginated until items predate `--since`. Permanent data, full coverage.
- **Activity-inbox story-mention notifications** — `/api/v1/news/inbox/`, filtered to story-mention rows. Instagram retains these for roughly 14-30 days only; older story tags are unrecoverable.
- **Currently-live story tray** — `/api/v1/feed/user/<user_id>/story/`, for stories posted in the last 24h.
- **Own story archive** — `/api/v1/archive/reel/day_shells/` + `seen_media`, walked back to `--since`. Only readable if the logged-in viewer IS the target account. If the viewer is a different account, the script reports `archive_not_accessible` in `coverage` and lists the implication in `notes`.

Reshare matching: for each tag (post or story), the script looks for a target-side story that either (a) carries a `reshared_media_id` equal to the tag's media id, or (b) has a `reel_mentions` entry pointing at the tag's actor within 24 hours of the tag timestamp.

Output is a JSON object with `summary` (counts), `missed_post_reshares`, `missed_story_tags`, `matched_*` lists, a `coverage` block (per source), and a `notes` array listing every applicable caveat. Always read `notes` and `coverage` before quoting a count — the same audit run can give very different numbers depending on whether the archive was reachable.

Operational notes:

- For a complete historical audit, the user must log in as the brand account in Chromium before running. A personal-account session can only see live (<24h) stories on the brand side.
- To build an ongoing audit trail, schedule the script daily and append the output to a log. Combined with the activity-inbox retention window, this captures every story tag before Instagram drops the notification.
- The script does not write or modify any Instagram state. All endpoints are read-only fetches.

## What this skill does NOT do (by design)

- It does not read an account's join date or age. Instagram's *About This Account* (date joined) is mobile-app-only; the web surface `browser-serialiser` drives does not expose it (a web fetch redirects to login), so it cannot be retrieved here. Estimate from the oldest visible post, or read it in the Instagram mobile app.
- It does not scrape individual post captions in bulk by opening each permalink. Recent post captions arrive via the feed API in §6; for older posts beyond pagination depth, a permalink fetch would be needed.
- It does not handle hashtag or place pages, only people search and profiles. The topsearch endpoint already returns hashtags and places for discovery; dedicated pages would be a separate addition.
- It does not attempt to defeat rate limits or checkpoints. Pace requests, a few per minute, not a burst.
