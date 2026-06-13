---
name: otter.ai
description: "recordings: list, rename, trash, export; transcripts and content management. Runs under the serialised-browsing harness; does not use Google Chrome."
argument-hint: <list | rename | trash | export-dropbox | fetch-via-dropbox | dropbox-status>
allowed-tools: Bash, Read
---

## Execution model

Spawn a **subagent** to run the workflow. The skill runs under the **serialised-browsing** harness: `browser-serialiser` loads it into a policed safe interpreter and drives the browser through the command surface (no raw CDP, anti-ban pacing enforced). Invoke by reference, `browser-serialiser otter.ai/otter-cdp <subcommand> <args>`; the subagent need not paste scripts inline. See the serialised-browsing skill for the command surface.

## Prerequisites

- A logged-in Otter.ai session in the user-data-dir the serialiser targets (the user logs in via the browser UI).
- For Dropbox export: Dropbox must be connected in Otter.ai settings.
- Export path configured in `~/.claude/skills/config.ini` under `[otter.ai] dropbox_export_path`.

If a subcommand returns `{"error": "Not logged in..."}`, the user needs to log in to otter.ai in their browser first; the harness classifies a login/checkpoint redirect as a terminal state and stops. If `~/.claude/skills/config.ini` is absent, pause and let the user know: "Create `~/.claude/skills/config.ini` with an `[otter.ai]` section containing `dropbox_export_path = ...`. This file is not part of the shared aesop repository - create it locally."

## Capabilities

### 1. List recordings

```bash
browser-serialiser otter.ai/otter-cdp list [--page-size N] [--last-load-ts TS]
```

Returns JSON with `speeches` array. Each entry has: `otid`, `title`, `created_at` (epoch), `duration` (seconds), `summary`, `link` (full URL).

Default page size is 50. To paginate, pass `--last-load-ts` from the previous response's `last_load_ts`.

### 2. Rename a recording

```bash
browser-serialiser otter.ai/otter-cdp rename <otid> "<new title>"
```

Returns `{"status": "OK", "modified_time": ...}` on success.

The `otid` is the recording identifier from the list command or from an otter.ai URL (`https://otter.ai/u/<otid>`).

**Naming convention:** titles follow `YYYY-MM-DD-kebab-case-description.txt`. When the user provides a natural-language phrase, convert it to this format before issuing the rename command.

### 3. Move a recording to Trash

```bash
browser-serialiser otter.ai/otter-cdp trash <otid>
```

Moves the recording to Otter Trash, the same action as the web UI's "Move to Trash" button. The recording is recoverable from the Trash folder in the web UI for approximately 30 days, then permanently removed by Otter.

Use this as the end-of-pipeline action once the transcript has been captured, corrected, and committed elsewhere.

**There is deliberately no hard-delete subcommand.** Otter's permanent-delete endpoints (`delete_speech`, `permanently_delete_speech`, `bulk_delete_speech`) bypass Trash and are unrecoverable. Their names are easy to misread as soft-delete; on 2026-05-13 a real recording was lost this way. If you genuinely need permanent deletion, do it from the Otter web UI where the consequence is explicit. Do not add a `delete` subcommand back without a strong reason and a confirmation prompt.

### 4. Export to Dropbox

```bash
browser-serialiser otter.ai/otter-cdp export-dropbox <otid> [--format txt|pdf|docx|srt]
```

Exports the recording to the user's connected Dropbox. Default format is `txt`.

Returns `{"status": "OK", "failed_speeches": []}` on success.

### 5. Fetch a recording via Dropbox round-trip

The one-shot round-trip — trigger a txt export, poll `Dropbox:Apps/Otter` via `rclone` until the file appears, read it, delete it, return the text — uses `rclone`, a host tool. The serialised-browsing surface exposes only the browser; `rclone` is not reachable from the policed safe interpreter, so over `browser-serialiser` the `fetch-via-dropbox` subcommand returns an error pointing here. Run the round-trip in two host-side steps: `export-dropbox <otid>` (browser-side, over the serialiser), then read the resulting file from `Dropbox:Apps/Otter` with `rclone` from a shell. Format is `txt`; path `Dropbox:Apps/Otter` is the Otter app folder.

### 6. Check Dropbox connection

```bash
browser-serialiser otter.ai/otter-cdp dropbox-status
```

Returns connection status, `dropbox_account_id`, auto-export/import settings, and default export format.

## How it works

The serialised-browsing harness launches the browser with the user's logged-in user-data-dir and loads the skill into a policed safe interpreter. The skill drives the command surface:
1. `nav` to `otter.ai/my-notes` to establish session context — the covering view for the `/forward/api/v1/*` endpoints (view-before-fetch).
2. `eval` runs page-context JavaScript `fetch()` calls against Otter.ai's internal API (`/forward/api/v1/...`), reads and writes carried by the page's own cookies and CSRF token.
3. Each subcommand returns a JSON document, pretty-printed to stdout.

The harness owns pacing+jitter and the 429/login backoff, and the safe interpreter removes file/exec/socket/raw-CDP — the skill reaches the browser only through the verbs. The `otter.ai` view-before-fetch entries live in `skills/lib/serialiser-harness.tcl`.

## API endpoints used

| Operation | Method | Path | Auth |
|---|---|---|---|
| List speeches | GET | `/forward/api/v1/speeches` | session cookie + x-csrftoken |
| Rename | POST | `/forward/api/v1/set_speech_title` | session cookie + x-csrftoken |
| Trash (recoverable) | POST | `/forward/api/v1/move_to_trash_bin` (form body `otid=`) | session cookie + x-csrftoken |
| Export TXT to Dropbox | POST | `/forward/api/v1/dropbox_speech_txt` | session cookie + x-csrftoken |
| Export PDF to Dropbox | POST | `/forward/api/v1/dropbox_speech_pdf` | session cookie + x-csrftoken |
| Export DOCX to Dropbox | POST | `/forward/api/v1/dropbox_speech_word` | session cookie + x-csrftoken |
| Export SRT to Dropbox | POST | `/forward/api/v1/dropbox_speech_srt` | session cookie + x-csrftoken |
| User info | GET | `/forward/api/v1/user` | session cookie + x-csrftoken |

The CSRF token is read from `document.cookie` (the `csrftoken` cookie is not httponly). The session cookie (`sessionid`) is httponly and sent automatically by the browser.
