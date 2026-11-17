#!/usr/bin/env python3
"""Register the signed-in account for one Slush side event, answering the event's
custom questions, and report the status the platform gives back."""

import argparse
import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__)
sc.add_target_arg(ap)
ap.add_argument("side_event_id", help="from auth-side-events.py")
ap.add_argument("--answer", action="append", default=[], metavar="QUESTION_ID=VALUE",
                help="answer to one custom question; repeat for each")
ap.add_argument("--hide-from-attendees", action="store_true",
                help="keep this account off the event's visible attendee list")
args = ap.parse_args()

sc.login()
path = f"/side-events/{args.target}/public/{args.side_event_id}"
e = sc.get(path) or {}
if not e.get("side_event_id"):
    sc.fail(f"{path} named no side event", 65)

questions = [{"id": q.get("id"), "question": q.get("question"), "type": q.get("type"),
              "options": [o.get("value") for o in q.get("options") or []], "required": bool(q.get("required"))}
             for q in e.get("custom_questions") or []]
out = {"side_event_id": e["side_event_id"], "title": e.get("title"),
       "start": sc.local_time(e.get("start_at")), "my_registration": e.get("is_registered"),
       "luma_links": sc.description(e.get("description"))[1], "sent": False}


def done(note, **extra):
    sc.emit_ok(dict(out, note=note, **extra))
    sys.exit(0)


# The register path withdraws when posted without a body, and the platform's answer to a
# second registration is unread, so an account that already holds one is left as it is.
if e.get("is_registered"):
    done("already registered; nothing sent")
if e.get("registration_target") == "company":
    done("this event registers a company profile, which this action does not do")
if e.get("status") and e.get("status") != "accepted":
    done(f"the event itself is {e['status']}, not open for registration")
closes = e.get("close_at")
if (not e.get("registration_active") or e.get("hard_closed")
        or (closes and datetime.fromisoformat(closes.replace("Z", "+00:00")) < datetime.now(timezone.utc))):
    done(f"registration closed (deadline {sc.local_time(closes)})")

answers, bad = {}, []
by_id = {q["id"]: q for q in questions}
for a in args.answer:
    qid, sep, value = a.partition("=")
    q = by_id.get(qid.strip())
    if not sep or not q:
        bad.append(f"{a!r} names no question of this event")
    elif q["options"] and value not in q["options"]:
        bad.append(f"{q['question']!r} takes one of {q['options']}, not {value!r}")
    else:
        answers[q["id"]] = value
missing = [q for q in questions if q["required"] and not answers.get(q["id"], "").strip()]
if bad or missing:
    done("; ".join(bad) or "required questions unanswered; nothing sent", questions=questions)

body = {"consent": True, "hidden_from_attendees": args.hide_from_attendees,
        "custom_answers": [{"id": k, "value": v} for k, v in answers.items()]}
reply = sc.post(f"/side-events/{args.target}/me/register/{e['side_event_id']}", body) or {}
out.update(my_registration=reply.get("newStatus"), sent=True)
sc.emit_ok(out)
