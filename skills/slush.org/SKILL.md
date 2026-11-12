---
name: slush.org
description: "Slush (Helsinki) attendee account: my meeting requests and their status, my agenda, the side-event catalogue by day or topic, and who is attending a side event."
argument-hint: <whoami | schedule | meetings | side-events | attendees>
allowed-tools: Bash, Read
---

# Slush platform (platform.slush.org)

Reads of the signed-in attendee's Slush account over the platform's own JSON API, no browser. Nothing is written to the account. The platform rate-limits sign-ins, so a run reuses the session token the last sign-in stored in `~/.cache/magazines/slush.org.json` (readable only by the user) and signs in again only when the platform refuses it; deleting that file forces a fresh sign-in.

## Prerequisites

- **What:** the Slush platform login (email and password)
- **Where:** `$HOME/.config/magazines/config.ini`, under the `[slush.org]` section
- **Format:**
  ```ini
  [slush.org]
  email = you@example.com
  password = yourpassword
  ```

Run an action without checking for the credentials first: when a key is unset it exits 78 naming the `[slush.org]` keys it lacks. Stop there and tell the user to add them.

## Output and exit codes

Every action prints the canonical envelope (`{"result", "identity", "cursor", "hasMore", "fault"}`); on a result, `identity` is the signed-in account's Slush `user_id`, and a fault carries none. Times are venue time (Europe/Helsinki) as `YYYY-MM-DD HH:MM`; the schedule also carries the UTC originals.

- 0: result
- 77: no session: the login was rejected or the platform answered 401 (`fault.shape` `login_wall`, one stderr line naming the account)
- 75: rate limited (HTTP 429); wait a few minutes before the next run
- 78: credentials missing from config.ini
- 65: any other site fault

Each edition is a target id (`slush26` for November 2026); every action takes `--target` for another edition.

## Actions

```bash
D=${CLAUDE_PLUGIN_ROOT}/skills/slush.org
python3 $D/whoami.py                                  # which account the login names
python3 $D/auth-schedule.py                           # agenda: confirmed meetings and added items, in order
python3 $D/auth-meetings.py [--status pending|accepted|declined|all]
python3 $D/auth-side-events.py [--day 2026-11-18] [--query AI] [--category networking] [--open] [--limit N]
python3 $D/auth-attendees.py <side_event_id> [--company-type vc-investor] [--limit N]
```

**auth-meetings**: every meeting request, sent and received. `direction` is who asked: the platform swaps sender and receiver when a request is declined, so the skill reads the original sender. A pending request carries `recipient_seen`, whether the other side has opened it; a declined one carries `declined_by` and any reason or message. Reading never marks a meeting as seen.

**auth-side-events**: the whole catalogue as this account sees it (signed out, the platform shows fewer events), filtered here. `registration` is `open`, `full` or `closed`; `attendee_list_visible` says whether `auth-attendees` can read its attendees.

**auth-attendees**: the visible attendee list of one side event (id from `auth-side-events`): name, title, company, company type, country. `total_registrations` counts every registration; `--limit` bounds how many are read, before `--company-type` filters them, and `hasMore` is true when fewer were read than the total.

Unbuilt, undecided: listing the side events the account has registered for; sending, accepting or declining meeting requests; registering for side events; browsing the platform's investor and company profiles to find people to request meetings with.
