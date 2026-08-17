---
name: otter.ai
description: "Otter.ai recordings: list, rename, trash, fetch speaker-labelled transcripts, and download mp3 audio from a logged-in Otter account."
argument-hint: <list | rename | trash | fetch>
allowed-tools: Bash, Read
---

## Execution model

The subcommands run under the serialised-browsing harness: `browser-serialiser`
loads this skill into a policed safe interpreter and drives the browser through
the command surface (no raw CDP, anti-ban pacing enforced). Invoke by reference:
`browser-serialiser otter.ai/otter-cdp <subcommand> <args>`. Each launch takes
~15s for the browser.

Turning a recording into a corrected, searchable record in a business repo is the
`knowledge-capture` command's job; it calls the subcommands here for the Otter
steps.

## Prerequisites

- A logged-in Otter.ai session in the user-data-dir the serialiser targets (the
  user logs in via the browser UI). If a subcommand returns
  `{"error": "Not logged in..."}`, the harness saw a login/checkpoint redirect and
  stopped; the user needs to log in to otter.ai in their browser first.
- `[otter.ai] auto_push` in `config.ini` — optional, default off. Read by the
  `knowledge-capture` command to decide whether a capture is pushed to the
  business repo's remote as well as committed.

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
`<business>/<name>.txt` is a valid title. `knowledge-capture` uses that shape as
its done-signal, so a later run reads the prefix and skips the recording.

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

### 5. Fetch a recording's audio pointer

```bash
browser-serialiser otter.ai/otter-cdp audio <otid>
```

Returns `{"otid", "title", "created_at", "duration", "audio_format", "audio_url",
"download_url"}`. `audio_url` is a presigned S3 URL for the recording's mp3,
valid for about two days and needing no cookies, so the bytes are pulled with
plain curl rather than through the browser:

```bash
curl -o meeting.mp3 "<audio_url>"
```

`audio_url` is null on a recording with no audio (`audio_enabled` false or
retention-blocked); `download_url` (api.aisense.com) needs the Otter session and
is returned only as a fallback pointer. Same `/forward/api/v1/speech` endpoint
as `fetch`, so no new API surface.

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
`lib/serialiser-harness.tcl`.

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
