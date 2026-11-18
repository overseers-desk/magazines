#!/usr/bin/env python3
"""The signed-in account's Slush notifications (the platform's bell), newest first,
with venue times. Reading never marks a notification as seen."""

import argparse
import os
import sys
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

PAGE = 100  # the platform's own page size
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument("--since", help='venue time, "YYYY-MM-DD HH:MM" or YYYY-MM-DD; only newer ones are fetched')
ap.add_argument("--unseen", action="store_true", help="only those not yet seen in the platform")
ap.add_argument("--category", help="meeting, side_event, message, application, company, ticket or admin")
args = ap.parse_args()

since = None
if args.since:
    try:
        since = datetime.fromisoformat(args.since).replace(tzinfo=sc.VENUE_TZ)
    except ValueError:
        sc.fail(f"--since {args.since!r} is not YYYY-MM-DD or YYYY-MM-DD HH:MM", 65)

sc.login()
rows, offset, done = [], 0, False
while not done:
    page = sc.get(f"/notifications?mark_seen=false&limit={PAGE}&offset={offset}", sc.NOTIFICATIONS) or []
    for n in page:
        created = datetime.fromisoformat(n["created_at"].replace("Z", "+00:00"))
        if since and created < since:
            done = True  # newest first: everything after this is older still
            break
        if (args.unseen and n.get("seen")) or (args.category and n.get("notification_category") != args.category):
            continue
        link = n.get("link") or ""
        rows.append({"notification_id": n.get("notification_id"), "created": sc.local_time(n["created_at"]),
                     "category": n.get("notification_category"), "title": n.get("title"),
                     "content": n.get("content"), "seen": bool(n.get("seen")),
                     "link": "https://platform.slush.org" + link if link.startswith("/") else link or None})
    done = done or len(page) < PAGE
    offset += PAGE
sc.emit_ok(rows)
