---
name: otter.ai
description: "recordings: list, rename, trash, export; transcripts and content management."
argument-hint: <list | rename | trash | export-dropbox | fetch-via-dropbox | dropbox-status>
allowed-tools: Bash, Read
---

## Execution model

Spawn a **subagent** to run the CDP script, as each invocation launches a headless browser session (~15s overhead). Tell the subagent to use the script at `${CLAUDE_PLUGIN_ROOT}/skills/otter.ai/otter-cdp.tcl`.

## Prerequisites

- A Chrome-compatible browser with an active Otter.ai session (user must be logged in via the browser UI). Browser invocation via `not-google-chrome`.
- `tclsh` with the tcllib `json` package (the shared `lib/cdp-client.tcl` provides the WebSocket/CDP transport)
- For Dropbox export: Dropbox must be connected in Otter.ai settings
- Export path configured in `~/.claude/skills/config.ini` under `[otter.ai] dropbox_export_path`

If the script returns `{"error": "Not logged in..."}`, the user needs to log in to otter.ai in their browser first. If `~/.claude/skills/config.ini` is absent, pause and let the user know: "Create `~/.claude/skills/config.ini` with an `[otter.ai]` section containing `dropbox_export_path = ...`. This file is not part of the shared aesop repository - create it locally."

## Capabilities

### 1. List recordings

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/otter.ai/otter-cdp.tcl list [--page-size N] [--last-load-ts TS]
```

Returns JSON with `speeches` array. Each entry has: `otid`, `title`, `created_at` (epoch), `duration` (seconds), `summary`, `link` (full URL).

Default page size is 50. To paginate, pass `--last-load-ts` from the previous response's `last_load_ts`.

### 2. Rename a recording

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/otter.ai/otter-cdp.tcl rename <otid> "<new title>"
```

Returns `{"status": "OK", "modified_time": ...}` on success.

The `otid` is the recording identifier from the list command or from an otter.ai URL (`https://otter.ai/u/<otid>`).

**Naming convention:** titles follow `YYYY-MM-DD-kebab-case-description.txt`. When the user provides a natural-language phrase, convert it to this format before issuing the rename command.

### 3. Move a recording to Trash

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/otter.ai/otter-cdp.tcl trash <otid>
```

Moves the recording to Otter Trash, the same action as the web UI's "Move to Trash" button. The recording is recoverable from the Trash folder in the web UI for approximately 30 days, then permanently removed by Otter.

Use this as the end-of-pipeline action once the transcript has been captured, corrected, and committed elsewhere.

**There is deliberately no hard-delete subcommand.** Otter's permanent-delete endpoints (`delete_speech`, `permanently_delete_speech`, `bulk_delete_speech`) bypass Trash and are unrecoverable. Their names are easy to misread as soft-delete; on 2026-05-13 a real recording was lost this way. If you genuinely need permanent deletion, do it from the Otter web UI where the consequence is explicit. Do not add a `delete` subcommand back without a strong reason and a confirmation prompt.

### 4. Export to Dropbox

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/otter.ai/otter-cdp.tcl export-dropbox <otid> [--format txt|pdf|docx|srt]
```

Exports the recording to the user's connected Dropbox. Default format is `txt`.

Returns `{"status": "OK", "failed_speeches": []}` on success.

### 5. Fetch a recording via Dropbox round-trip

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/otter.ai/otter-cdp.tcl fetch-via-dropbox <otid> [--timeout 60] [--extended-timeout 120]
```

One-shot helper that triggers a txt export to Dropbox, polls `Dropbox:Apps/Otter` via `rclone` until a new file appears, reads its contents, deletes it from Dropbox, and returns the text. Format is hardcoded to `txt`. Path `Dropbox:Apps/Otter` is hardcoded.

Polling: `rclone lsf` every 5 seconds. `--timeout` (default 60s) is the initial deadline; on expiry a stderr notice is logged and polling continues until `--extended-timeout` (default 120s).

Returns `{"otid", "dropbox_filename", "content"}` on success. Errors include `Timeout waiting for Dropbox export`, `Multiple new files in Dropbox:Apps/Otter` (if a concurrent unrelated upload races), and any error propagated from `export-dropbox`.

Requires `rclone` configured with a `Dropbox:` remote.

### 6. Check Dropbox connection

```bash
not-google-chrome --cdp -- tclsh ${CLAUDE_PLUGIN_ROOT}/skills/otter.ai/otter-cdp.tcl dropbox-status
```

Returns connection status, `dropbox_account_id`, auto-export/import settings, and default export format.

## How it works

The `not-google-chrome --cdp` wrapper launches a headless browser with the user's logged-in user-data-dir and exports `CDP_WS_URL` to the client. The script is a pure CDP client that:
1. Connects to the page target given by `CDP_WS_URL`
2. Navigates to otter.ai to establish session context
3. Executes JavaScript `fetch()` calls against Otter.ai's internal API (`/forward/api/v1/...`)
4. Returns JSON results

No Selenium needed. The wrapper owns the browser lifecycle; the client holds no browser PID.

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
