#!/usr/bin/env python3
"""Slush side events as the signed-in account sees them, with the account's own
registration on each, filtered by day, text, category and registration state, in
start order with venue times."""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

# One request holds the whole catalogue; this bound sits well above an edition's count.
CATALOGUE_MAX = 2000

ap = argparse.ArgumentParser(description=__doc__)
sc.add_target_arg(ap)
ap.add_argument("--day", help="venue-time date, YYYY-MM-DD")
ap.add_argument("--query", help="case-insensitive text in title, organiser, description or keywords")
ap.add_argument("--category", help="e.g. networking, roundtables, party, stage-session")
ap.add_argument("--open", action="store_true", help="only events taking registrations and not full")
ap.add_argument("--registered", action="store_true",
                help="only events this account holds a registration on, whatever its status")
ap.add_argument("--limit", type=int, default=0, help="at most this many events (default all)")
args = ap.parse_args()


def raw(v):
    # Search results wrap each field as {"raw": value}.
    return v.get("raw") if isinstance(v, dict) and "raw" in v else v


sc.login()
body = sc.search(args.target, f"/search/{args.target}/side-events",
                 {"query": "", "filters": {}, "sort": [{"start_at": {"order": "asc"}}]}, CATALOGUE_MAX) or {}
rows = []
for e in body.get("results") or []:
    e = {k: raw(v) for k, v in e.items()}
    cats = e.get("event_category") or []
    cats = cats if isinstance(cats, list) else [cats]
    start = sc.local_time(e.get("start_at"))
    if args.day and not (start or "").startswith(args.day):
        continue
    if args.category and args.category.lower() not in [str(c).lower() for c in cats]:
        continue
    if args.open and (e.get("full") or not e.get("registration_active")):
        continue
    if args.registered and not e.get("is_registered"):
        continue
    if args.query:
        hay = " ".join(str(e.get(k) or "") for k in ("title", "company_name", "description", "keywords")).lower()
        if args.query.lower() not in hay:
            continue
    desc, luma = sc.description(e.get("description"))
    rows.append({
        "side_event_id": e.get("side_event_id"),
        "title": e.get("title"),
        "organiser": e.get("company_name"),
        "start": start, "end": sc.local_time(e.get("end_at")),
        "location": e.get("location"),
        "categories": cats,
        "type": e.get("type"),
        "registration": "full" if e.get("full") else ("open" if e.get("registration_active") else "closed"),
        "registration_closes": sc.local_time(e.get("close_at")),
        "my_registration": e.get("is_registered"),
        "attendee_list_visible": not e.get("attending_list_hidden"),
        "description": desc[:400] + ("…" if len(desc) > 400 else ""),
        "luma_links": luma,
    })
rows.sort(key=lambda r: r["start"] or "")
more = bool(args.limit) and len(rows) > args.limit
sc.emit_ok(rows[:args.limit] if args.limit else rows, has_more=more)
