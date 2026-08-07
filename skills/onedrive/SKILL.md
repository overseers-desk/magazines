---
name: onedrive
description: "Access your own OneDrive through rclone: list, browse, and download files and shared folders. Trigger on any OneDrive or rclone request, including shared-folder access."
allowed-tools: Bash, Read
---

## What this skill does

Drives `rclone` against **your own** OneDrive to list, browse, and download files —
including folders that were *shared with you*, once they have been added to your
drive. It is per-user: each person runs rclone with their **own** OneDrive token,
never a shared account.

## Prerequisites

- `rclone` installed — macOS: `brew install rclone`; Linux: `sudo apt install rclone`
  (or see https://rclone.org/install/).
- A OneDrive remote in **your own** rclone config, created with `rclone config`
  (storage type `onedrive`) and authenticated against your own Microsoft account.
  - Find your config file: `rclone config file`.
  - List the remotes already configured: `rclone listremotes`.
- The remote holds your personal OAuth token. It is yours — do not hand it to
  anyone else, and do not reuse someone else's. Sharing is done through OneDrive's
  own folder-sharing (below), not by sharing tokens.

If `rclone listremotes` shows no OneDrive remote, run `rclone config` once:
`n` (new) → name it → `onedrive` → accept defaults → complete the browser sign-in.

## The shared-folder rule (the important bit)

rclone only lists what lives in **your** drive. A folder someone shared with you
sits under **"Shared with me"** and will **not** appear in `rclone lsd remote:`
until you pull it into your own drive:

1. Open OneDrive in the browser → **Shared** → find the folder.
2. Select it → **Add shortcut to My files**.
3. It now appears at your drive root, so `rclone lsd remote:` lists it and you can
   browse and copy it.

(The same idea on Google Drive is "Add shortcut to Drive" — that is what was
verified with the *Colourful.land Pty Ltd* / Historic Rivermill folder.)

## Capabilities

Replace `remote` with your rclone remote name from `rclone listremotes`. Quote any
path containing spaces.

| Task | Command |
|---|---|
| List top-level folders | `rclone lsd remote:` |
| List a folder's contents | `rclone lsf "remote:Colourful.land Pty Ltd"` |
| Show a folder as a tree | `rclone tree "remote:path"` |
| List files recursively, with sizes | `rclone ls "remote:path"` |
| Download a file or folder | `rclone copy "remote:path/to/item" /local/dest` |
| Show account quota/usage | `rclone about remote:` |

## Notes

- If a shared folder is missing from `rclone lsd remote:`, you have not added it to
  "My files" yet — see the shared-folder rule above. This is the single most common
  reason a shared folder "can't be accessed" with rclone; it can.
- This skill installs nothing and stores no token of its own; it documents how to
  use your existing rclone OneDrive remote.
