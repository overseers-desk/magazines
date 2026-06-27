---
name: economist.com
description: "Read The Economist behind its paywall: list a topic's articles (newest first, by year) and fetch an article's full text as markdown. For economist.com/topics/* and article URLs that return a subscribe wall to curl."
allowed-tools: Bash, Read
argument-hint: <topic-slug | article-path>
---

The Economist serves a subscribe wall to logged-out fetches; a logged-in
subscriber session renders the full article. Each page embeds its data in a
`__NEXT_DATA__` JSON blob, so these drivers parse that rather than the markup.
Run them through `browser-serialiser` (the serialised-browsing skill), which
drives the logged-in Chromium.

## Verbs

List a topic's articles, newest first, filtered to a year (default the topic
slug `artificial-intelligence`, year `2026`). Emits TSV `date<TAB>path<TAB>headline`:

```bash
browser-serialiser economist.com/topic-list artificial-intelligence --year 2026
```

The feed pages by cursor (`?after=<endCursor>`), not by `?page=N`; the driver
walks the cursors until a whole page holds no article of the target year.

Fetch one article's text as markdown (headline, rubric, date, body) by its feed
path or full URL:

```bash
browser-serialiser economist.com/fetch-article /leaders/2026/06/25/the-ai-backlash-is-only-getting-started
```

## Files

- `economist.tcl` — shared parser (`__NEXT_DATA__` → article list / markdown);
  also a CLI for testing against a saved dump (`economist.tcl list|article <dump.html>`).
- `topic-list.tcl`, `fetch-article.tcl` — the serialiser drivers.

## Prerequisites

- A logged-in Economist subscriber session in the shared Chromium profile. A
  fetch that comes back as a subscribe wall means the profile is logged out.
- `[browser] user_agent` in `$HOME/.claude/skills/config.ini` (serialised-browsing skill).
