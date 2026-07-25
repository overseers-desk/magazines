---
name: whirlpool.net.au
description: "first-person Australian employment and consumer accounts on the Whirlpool forums — search threads and read a whole discussion as clean per-post text. For forums.whirlpool.net.au search results and /archive/ threads."
allowed-tools: Bash, Read
argument-hint: <search terms, or a forums.whirlpool.net.au/archive/<id> URL>
---

## Why this skill exists

Whirlpool (forums.whirlpool.net.au) is the densest Australian source of
first-person employment and consumer accounts — unfair dismissal, Fair Work,
probation, redundancy, warranty and telco disputes — written by the people who
lived them. The obstacle is never access; it is the markup. Both surfaces this
skill needs are **static HTML served to a plain fetch**, no browser and no login:

- the forum search page, `forums.whirlpool.net.au/search?q=...`, returns a fully
  rendered results list to `curl` (verified across several user agents and via
  WebFetch — it does **not** cloak on user agent and is **not** a JavaScript
  shell);
- an archive thread, `forums.whirlpool.net.au/archive/<id>`, serves the whole
  discussion, every post, on one page.

So this skill adds no browser. Its value is the **parser**: Whirlpool buries each
result and each post in deeply nested, whitespace-heavy markup, and `whirlpool.tcl`
turns that into per-thread and per-post records. This is why it is a plain
`Bash + Read` skill, unlike the serialiser skills next to it (reddit, economist),
which exist because their sites block a plain fetch. Whirlpool does not.

## Prerequisites

`curl` on `PATH` (the script fetches with it when handed a URL). No config keys,
no logged-in session. The pages are public.

## 1. Search for threads

Run the parser against a live search URL (it fetches) or a saved page:

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/whirlpool.net.au/whirlpool.tcl \
  search "https://forums.whirlpool.net.au/search?q=unfair+dismissal+employer" --limit 15
```

Prints, per hit: the thread title, its forum » subforum trail with the thread's
age, the `/archive/<id>` URL to read next, and a match snippet. Take a promising
archive URL into §2.

Query string (URL-encode spaces as `+` or `%20`):

- `q=` — the search terms.
- `w=` — where to match: empty or `t` (title only) or `b` (body only).
- `p=` — period: empty (recent-weighted) or `a` (all time), `w`, `m`, `mm`
  (three months), `y`, `yy` (three years).

Search returns a single relevance-ranked page of up to ~50 hits; there is **no
page cursor**, so narrow with `w`/`p` or sharper terms rather than paging. If you
prefer to fetch the page yourself (WebFetch, or a `curl` to a file), pass the
saved file's path in place of the URL — the parser reads either.

## 2. Read a whole thread

```bash
tclsh ${CLAUDE_PLUGIN_ROOT}/skills/whirlpool.net.au/whirlpool.tcl \
  thread "https://forums.whirlpool.net.au/archive/2471024" [--limit N]
```

Prints the thread title, the post count, then each post **in thread order**:
poster name and user id, an `[O.P.]` tag on the original poster, the post's date
(human plus ISO), and the body as clean text with paragraph breaks and quoted
`X writes...` references kept. `--limit N` caps the posts emitted; omit it for the
whole thread. Archive pages **do not paginate** — a 300-post thread is one fetch —
so no pagination handling is needed.

Archive ids come in two shapes and both work: older numeric (`2471024`) and newer
alphanumeric (`9qr1ppp2`). The parser handles the two archive markups these use
(the older `reply reply-archived` block and the newer `replyblock` wrapper),
including the "last updated" metadata block the newer layout opens with, which is
not a post and is dropped.

## Pacing

There is a rate limiter only in courtesy, not in code: these are plain public
GETs. Whirlpool's own pages carry a "spidering, indexing or crawling ... strictly
prohibited" notice, so read like a reader — a handful of fetches for a question,
not a crawl of a forum. Space requests; do not loop the search over a term list
at machine speed.

## What this skill does NOT do

- It does not log in, post, reply, vote, or send anything. Read-only.
- It does not need or use the browser serialiser. If Whirlpool ever JavaScript-walls
  search (it does not today), the fallback is a `browser-serialiser --dump` of the
  search URL piped to `whirlpool.tcl search <dump>` — the parser already accepts a
  saved page, so only the fetch would change.
- Search does not expose a per-thread reply count; that count lives on the thread
  page, not in the results markup. Search gives title, forum, age, snippet, URL.
- It does not page search results (there is no cursor; ~50 hits per query) and
  does not crawl a forum index. It answers a search and reads the threads it finds.
- It does not recover deleted posts: a removed post has no body and drops out of
  the thread render, which is the site's own state, not a parse gap.
