---
name: slush.org
description: "Slush (Helsinki) attendee account: notifications, meeting requests and their status, my agenda, side events by day or topic, my registrations, signing me up, who attends."
argument-hint: <whoami | notifications | schedule | meetings | side-events | attendees | register>
allowed-tools: Bash, Read
---

# Slush platform (platform.slush.org)

The signed-in attendee's Slush account over the platform's own JSON API, no browser. Every action reads, except `auth-register`, which signs the account up for a side event. The platform rate-limits sign-ins, so a run reuses the session token the last sign-in stored in `~/.cache/magazines/slush.org.json` (readable only by the user) and signs in again only when the platform refuses it; deleting that file forces a fresh sign-in.

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
python3 $D/auth-notifications.py [--since "2026-11-18 08:00"] [--unseen] [--category meeting]
python3 $D/auth-schedule.py                           # agenda: confirmed meetings and added items, in order
python3 $D/auth-meetings.py [--status pending|accepted|declined|all]
python3 $D/auth-side-events.py [--day 2026-11-18] [--query AI] [--category networking] [--open] [--registered] [--limit N]
python3 $D/auth-attendees.py <side_event_id> [--company-type vc-investor] [--limit N]
python3 $D/auth-register.py <side_event_id> [--answer QUESTION_ID=VALUE ...] [--hide-from-attendees]
```

**auth-notifications**: the platform's bell, newest first: `created`, `category` (`meeting`, `side_event`, `message`, `application` and others), `title`, `content`, `seen`, and a `link` into the platform. `--since` takes a venue time and stops fetching at the first older notification, so a caller that remembers when it last looked downloads only what is new. `--unseen` keeps those not yet opened in the platform; reading never marks one as seen. The platform's emails carry more than the bell: a side-event application is confirmed by an "Application received" email with no bell notification (observed 2026-11-18).

**auth-meetings**: every meeting request, sent and received. `direction` is who asked: the platform swaps sender and receiver when a request is declined, so the skill reads the original sender. A pending request carries `recipient_seen`, whether the other side has opened it; a declined one carries `declined_by` and any reason or message. Reading never marks a meeting as seen.

**auth-side-events**: the whole catalogue as this account sees it (signed out, the platform shows fewer events), filtered here. `registration` is `open`, `full` or `closed`; `my_registration` is this account's own registration on the event, `accepted`, `pending`, `waitlisted` or `declined`, null when it holds none, and `--registered` keeps only the events where it holds one. `attendee_list_visible` says whether `auth-attendees` can read its attendees. `description` is the organiser's text, cut at 400 characters; `luma_links` lists the Luma pages the whole text links to.

**auth-attendees**: the visible attendee list of one side event (id from `auth-side-events`): name, title, company, company type, country. `total_registrations` counts every registration; `--limit` bounds how many are read, before `--company-type` filters them, and `hasMore` is true when fewer were read than the total.

**auth-register**: signs the account up for one side event and reports the status the platform answers (`accepted`, `pending` or `waitlisted`) with `sent` true. Registering shares the account's profile with the organiser, as the platform's own button does. Nothing is sent, and `sent` is false with a `note`, when the account already holds a registration on the event, registration has closed, or the event registers company profiles. An event's custom questions take one `--answer <id>=<value>` each; while a required one is unanswered or a value is not among a question's options, the result lists the event's `questions` (id, text, type, options, required) and nothing is sent.

**Registration on Luma.** Some organisers decide admission on their own Luma page and say so in the description (Operators Night and the Valpas hospitality evening at Slush 2026). The Slush application is then not the registration that counts, and `my_registration` says nothing about the Luma one. Both `auth-side-events` and `auth-register` report an event's `luma_links`, so an event carrying one is not reported as registered on the strength of its Slush status alone.

Unbuilt, undecided: withdrawing a side-event registration; sending, accepting or declining meeting requests; browsing the platform's investor and company profiles to find people to request meetings with.
