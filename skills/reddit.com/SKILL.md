---
name: reddit
description: "search Reddit, read a post with its comment tree, return whole discussions for a search, or list the logged-in account's saved items"
argument-hint: <search terms, a reddit post URL, or a request for saved items>
---

## Why this skill exists

WebFetch hard-refuses reddit.com ("Claude Code is unable to fetch from www.reddit.com"), so the only path to Reddit content is the headless-browser wrapper. Reddit's rendered HTML is auto-translated into the logged-in account's UI locale, which corrupts verbatim quote capture; its `.json` endpoints carry original-language text and parse cleanly. This skill fetches the `.json` endpoint through the wrapper and parses it.

## Execution model

Spawn a **Sonnet subagent** to run the workflow. A search dump is tens of KB; a busy thread can be a few hundred KB. The two-step path (§1-2) fetches a `.json` dump with `not-google-chrome` (the wrapper from the headless-browser skill, called by bare name) and parses the file with `${CLAUDE_PLUGIN_ROOT}/skills/reddit.com/reddit.tcl`. The one-session paths (§3-4) run under the policed serialiser as `serialised-browsing` skills, invoked by reference (`browser-serialiser reddit.com/<script> …`); the serialiser owns the browser, so no `--cdp` wrapper and no `CDP_WS_URL`. Keep raw dumps out of the main session.

A Reddit search hit is always a **post** (submission, kind `t3`); there is no comment-level search. A post's `comments/<id>.json` endpoint returns the post body and the comment tree together, so "go to the post" and "go to the comments" are a single fetch. §1-2 are the two-step path (one fetch, then parse a file); §3 collapses search-then-read-each into one browser session and is what you usually want for gathering discussions.

## Prerequisites

`[browser] user_agent` set in `$HOME/.claude/skills/config.ini` (the wrapper exits 78 without it). Reddit's public `.json` does not require a logged-in session, but going through the user's Chromium profile keeps the fingerprint consistent and reduces throttling. If a dump comes back as a "blocked" or login interstitial, back off rather than hammer; Reddit throttles bursts.

## 1. Search

Subreddit search:

```bash
not-google-chrome -t 25 \
  "https://old.reddit.com/r/SUBREDDIT/search.json?q=SEARCH+TERMS&restrict_sr=on&sort=relevance&t=all&limit=25" \
  > /tmp/reddit-search.html 2> /tmp/reddit-search.err
```

Site-wide search (drop `restrict_sr`):

```bash
not-google-chrome -t 25 \
  "https://old.reddit.com/search.json?q=SEARCH+TERMS&sort=relevance&t=all&limit=25" \
  > /tmp/reddit-search.html 2> /tmp/reddit-search.err
```

URL-encode the query (spaces as `+` or `%20`). `sort` accepts `relevance`, `new`, `top`, `comments`; `t` (time) accepts `all`, `year`, `month`, `week`, `day`. Save stdout and stderr separately: `2>/dev/null > out` produces a zero-byte file on some shells.

Parse:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/reddit.com/reddit.tcl search /tmp/reddit-search.html --limit 25
```

Prints, per post: title, `r/subreddit`, `u/author`, score, comment count, date, the full `old.reddit.com` permalink, and a 200-char selftext snippet. Take the permalink of a promising post into step 2.

## 2. Read a post and its comments

Append `.json` to any post permalink. A `www.reddit.com/r/SUB/comments/ID/slug/` URL works the same way; swap the host to `old.reddit.com` for locale consistency or leave it, since the `.json` body is original-language regardless:

```bash
not-google-chrome -t 25 \
  "https://old.reddit.com/r/SUBREDDIT/comments/POST_ID.json?limit=100&sort=top" \
  > /tmp/reddit-thread.html 2> /tmp/reddit-thread.err
```

Parse:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/reddit.com/reddit.tcl thread /tmp/reddit-thread.html --limit 50
```

Prints the post header (title, subreddit, author, score, comment count, date, permalink), the full selftext, then the comment tree indented by depth, each comment carrying `u/author`, score, date, and body. `--limit` caps the number of comments emitted. Reddit collapses deep threads behind "load more" stubs; the first `.json` page covers the top of the tree, which is the highest-signal part for quote gathering.

## 3. Return whole discussions for a search (one browser pass)

Searches, then fetches each result's discussion (post body plus comment tree) over a single CDP session, so it does not pay a browser cold-start per result. This is the usual entry point for quote-gathering.

```bash
browser-serialiser reddit.com/reddit-discussions \
  --query "SEARCH TERMS" [--subreddit SUB] \
  [--sort relevance|new|top|comments] [--time all|year|month|week|day] \
  [--limit 5] [--comments 15]
```

Subreddit listing instead of a search (omit `--query`, give `--subreddit`; `--sort` then takes `hot|new|top|rising`):

```bash
browser-serialiser reddit.com/reddit-discussions \
  --subreddit SUB --sort hot --limit 5 --comments 15
```

`--limit` is the number of discussions returned; `--comments` caps comments printed per discussion. Each discussion prints the post header, full selftext, and the top comment tree, the same format as §2. The serialiser owns the browser session and paces the `.json` fetches; the script asks a one-second dwell between discussions.

## 4. List the logged-in account's saved items

The saved listing is private: Reddit returns it only to the account that owns it, so this needs the user's session cookie. It reads the authenticated `old.reddit.com` origin through the serialiser, the same path §3 uses, and **the user must close their GUI Chromium first** (the user-data-dir lock, see CLAUDE.md), otherwise the session reads no cookies and Reddit answers `404`.

```bash
browser-serialiser reddit.com/reddit-saved --user NAME [--limit 25]
```

`--user` is the account whose saved list to read and must be the logged-in account; another user's saved list is unreachable. `--limit` is the number of items returned, newest first. The script walks Reddit's `after` cursor across pages internally (100 per fetch, a one-second dwell between pages), so the caller asks for a count and never handles a cursor. A saved list interleaves posts (`t3`) and comments (`t1`); both print, comments tagged `[comment]` and carrying the title of the post they sit under. A `404` here means not logged in, the wrong account, or the GUI browser is still holding the profile lock.

## Notes

- The parser strips the wrapper's `<pre>`, unescapes the HTML-render layer and Reddit's own entity escaping, and parses the result as JSON. It also accepts a raw `.json` body if fetched some other way. The §3-4 serialiser path fetches JSON directly through the `api` verb (a same-origin replay from the page), so there is no `<pre>` layer there; the shared `clean` still handles Reddit's entity escaping.
- A post-only Listing parses with `search` mode, so a subreddit front page (`/r/SUB/.json`) or a user's posts (`/user/NAME.json`) work through the same command. A saved listing mixes posts and comments, so it has its own `saved` mode (`reddit.tcl saved <dump>`), which §4 calls.
- Author may read `[deleted]`; score may be hidden (shown as the number Reddit returns, often a low placeholder) on recent posts. These are Reddit states, not parse errors.

## What this skill does NOT do

- It does not post, vote, comment, or message. Read-only.
- It does not paginate a comment tree past the first page or expand "load more" stubs (§2, §3). Add a `more`-children walk if deep threads prove necessary. Saved-item listings (§4) do paginate, by following the Listing `after` cursor.
- It does not defeat rate limits. Pace requests; a few per minute, not a burst.
