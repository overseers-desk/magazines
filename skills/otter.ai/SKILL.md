---
name: otter.ai
description: "Otter.ai recordings: list, rename, trash, fetch transcripts, and capture meetings into the matching business repo (knowledge-capture)."
argument-hint: <list | rename | trash | fetch | capture>
allowed-tools: Bash, Read, Write
---

## Execution model

The browser subcommands (`list`, `rename`, `trash`, `fetch`) run under the
serialised-browsing harness: `browser-serialiser` loads this skill into a policed
safe interpreter and drives the browser through the command surface (no raw CDP,
anti-ban pacing enforced). Invoke by reference:
`browser-serialiser otter.ai/otter-cdp <subcommand> <args>`. Each launch takes
~15s for the browser.

`capture` is different: it is an inline workflow (this skill holds Bash, Read,
Write) that *calls* the browser subcommands for the Otter steps and does the
classification, correction, file-writing, and committing itself. Run it directly,
not in a subagent.

## Prerequisites

- A logged-in Otter.ai session in the user-data-dir the serialiser targets (the
  user logs in via the browser UI). If a subcommand returns
  `{"error": "Not logged in..."}`, the harness saw a login/checkpoint redirect and
  stopped; the user needs to log in to otter.ai in their browser first.
- For `capture`: the business repos (each with a `knowledge-capture/` folder) must
  be present on disk; see the capture workflow below.

## Capabilities

### 1. List recordings

```bash
browser-serialiser otter.ai/otter-cdp list [--page-size N] [--last-load-ts TS]
```

Returns JSON with a `speeches` array. Each entry has `otid`, `title`, `created_at`
(epoch), `duration` (seconds), `summary`, `link`. Default page size 50; to
paginate, pass `--last-load-ts` from the previous response's `last_load_ts`.

### 2. Rename a recording

```bash
browser-serialiser otter.ai/otter-cdp rename <otid> "<new title>"
```

Returns `{"status": "OK", "verified": true, ...}` once the change is read back and
confirmed. The `otid` comes from `list` or an otter.ai URL
(`https://otter.ai/u/<otid>`). Otter allows `/` in titles, so a path-like
`<business>/<name>.txt` is a valid title (the capture done-signal).

### 3. Move a recording to Trash

```bash
browser-serialiser otter.ai/otter-cdp trash <otid>
```

Moves the recording to Otter Trash, recoverable from the web UI for ~30 days.
**There is deliberately no hard-delete subcommand.** Otter's permanent-delete
endpoints bypass Trash and are unrecoverable; on 2026-05-13 a real recording was
lost that way. Permanently delete only from the Otter web UI, where the
consequence is explicit.

### 4. Fetch a transcript

```bash
browser-serialiser otter.ai/otter-cdp fetch <otid>
```

Returns `{"otid", "title", "created_at", "duration", "segments", "transcript"}`.
The transcript comes straight from Otter's `/forward/api/v1/speech` endpoint (the
same call the recording page makes to render) and is reconstructed into
speaker-labelled turns: each segment's text grouped by speaker, named from the
recording's speaker list, falling back to a diarisation label
(`Speaker N`) when a segment has no assigned speaker.

## Capture: route recordings into business repos

`capture` lists recent recordings, fetches each transcript, decides which business
it belongs to, corrects it against that business's glossary, writes and commits the
result into that business's repo, and renames the recording in Otter to mark it
done. The browser steps go through the subcommands above; everything else is inline
work.

### Modes

- `capture` (no arg): recordings created in the last 3 days.
- `capture N`: last N days.
- `capture <otid>`: just that one recording (reprocessing an already-done one is
  allowed).

### Step 1 — discover the businesses

Each business is a sibling repo containing a `knowledge-capture/` folder. Glob
`"$HOME/code"/*/knowledge-capture/precis.md` (override the scan root with a path
argument if the repos live elsewhere). Read every `precis.md` — each is a short
identity file naming the business, its people, and recognition cues. The
business-folder basename is the routing key and the title prefix.

### Step 2 — list and filter

`list --page-size 100`. Keep recordings whose `created_at` is inside the window AND
whose title is not already a done-signal: skip titles matching
`<business-folder>/*.txt` (already captured) or a bare `*.txt` (legacy). For an
`<otid>` invocation, skip the window and `.txt` filters.

### Step 3 — per recording

1. **Fetch** the transcript: `fetch <otid>`.
2. **Classify** against the precis set — read the transcript and decide the single
   owning business:
   - Apply the "subject vs context" rule each precis carries: the business the
     meeting is *about* owns it, even when another business appears as a venue or
     the speaker's other venture.
   - **0 matches** (personal — school, medical, family — or no business): skip. Do
     not write, do not rename. Report "skipped: not business".
   - **exactly 1**: that business.
   - **>1 co-equal subjects** (genuinely shared): halt and ask the user which
     business owns it. Unattended: pick the most-central subject and record the
     secondary business in the staging frontmatter and the report.
3. **Correct** the transcript against that business's
   `knowledge-capture/capture-correction-index.md`:
   - Read the whole index and the whole transcript; correct holistically. **Never
     grep** for terms — mistranscriptions vary without limit, so a search for the
     wrong spelling cannot find them.
   - Fix names, places, and domain terms from the glossary. Remove stutter,
     fillers, and immediate self-corrections (write what the speaker settled on).
   - For an uncertain term not in the glossary, **web-search before** flagging it —
     most are place names, brands, or local businesses a single search resolves.
     Only mark a term uncertain after a search fails; list unresolved terms in the
     run report, not in the files.
   - Strip any `_otter_ai` suffix the recording carried.
4. **Frontmatter** — prepend a YAML problem-statement header to the corrected
   transcript:
   ```yaml
   ---
   date: YYYY-MM-DD
   participants: [names from the transcript]
   problems:
     - summary: one-line statement of a specific problem the meeting addressed
       detail: names, dates, concrete specifics — never frame a solution as the problem
       <taxonomy>: [codes]
   ---
   ```
   One entry per distinct problem discussed. The `<taxonomy>` key and its codes
   belong to the target repo: use whatever its correction-index defines, and omit
   the line for a repo that defines no taxonomy.
5. **Filename**: `YYYY-MM-DD-topic-key-people` — lowercase kebab-case, the
   `created_at` date unless the content clearly indicates another, 2–3 key people.
6. **Write** two files in the target repo:
   - `knowledge-capture/incoming/<name>.txt` — the corrected transcript with the
     frontmatter.
   - `knowledge-capture/staging/<name>.md` — a clean prose summary, topic sections
     with line ranges back to the incoming file, covering decisions, facts, names,
     numbers, methods, and reasoning, in British English, with no "uncertain words"
     section. If the repo's `knowledge-capture/README.md` documents a staging format
     or domain-specific things to capture, follow it.
7. **Commit** both into that repo: `git add` the two paths, then
   `git commit -m "Add <name>"`. If the commit fails, stop for this recording (do
   not rename).
8. **Rename** in Otter to mark done:
   `rename <otid> "<business-folder>/<name>.txt"`. The next run sees the prefix and
   skips it.

### Step 4 — report

Per recording: title → business, fetch / commit / rename status, and any uncertain
terms with the web searches you ran. List skipped recordings with the reason and a
checklist of the web searches performed.

## How it works

The serialised-browsing harness launches the browser with the user's logged-in
user-data-dir and loads this skill into a policed safe interpreter (file / exec /
socket / raw-CDP removed; the harness owns pacing and the 429/login backoff). The
skill reaches the browser only through the command surface:

1. `nav` to `otter.ai/my-notes` to establish session context — the covering view
   for the `/forward/api/v1/*` endpoints (view-before-fetch).
2. `eval` runs page-context JavaScript `fetch()` against Otter's internal API,
   carried by the page's own session cookie and CSRF token.
3. Each subcommand returns a JSON document, pretty-printed to stdout.

The skill does not use Google Chrome; it runs under whatever Chrome-compatible
browser the harness targets. The `otter.ai` view-before-fetch entries live in
`skills/lib/serialiser-harness.tcl`.

## API endpoints used

| Operation | Method | Path | Auth |
|---|---|---|---|
| List speeches | GET | `/forward/api/v1/speeches` | session cookie + x-csrftoken |
| Fetch transcript | GET | `/forward/api/v1/speech?otid=` | session cookie + x-csrftoken |
| Rename | POST | `/forward/api/v1/set_speech_title` | session cookie + x-csrftoken |
| Trash (recoverable) | POST | `/forward/api/v1/move_to_trash_bin` | session cookie + x-csrftoken |
| User info | GET | `/forward/api/v1/user` | session cookie + x-csrftoken |

The CSRF token is read from `document.cookie` (the `csrftoken` cookie is not
httponly). The session cookie (`sessionid`) is httponly and sent automatically.
