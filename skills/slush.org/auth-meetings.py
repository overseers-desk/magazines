#!/usr/bin/env python3
"""Every meeting request of the signed-in account for a Slush edition, sent and
received, with status, counterpart, times (venue time) and, for a pending request,
whether its recipient has opened it.

Read-only: this never calls the platform's meetings/view endpoint, which marks a
meeting as seen.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__)
sc.add_target_arg(ap)
ap.add_argument("--status", default="all",
                help="pending, accepted, declined, canceled, rescheduled, reassigned, or all (default)")
args = ap.parse_args()

sc.login()
me = sc.user["user_id"]
rows = []
for m in sc.get(f"/matchmaking/{args.target}/meetings") or []:
    if args.status != "all" and m.get("status") != args.status:
        continue
    # A decline swaps sender and receiver; original_sender_id keeps who asked.
    asked_by = m.get("original_sender_id") or m.get("sender_id")
    other = (m.get("receiver") if m.get("sender_id") == me else m.get("sender")) or {}
    loc = m.get("location") or {}
    table = loc.get("table_label") or loc.get("table_number") or m.get("table_number")
    place = loc.get("location_name") or ""
    if table and str(table) not in place:
        place = f"{place} table {table}".strip()
    suggested = [s.get("start_at") if isinstance(s, dict) else s for s in (m.get("time_suggestions") or [])]
    row = {
        "meeting_id": m.get("meeting_id"),
        "status": m.get("status"),
        "direction": "sent" if asked_by == me else "received",
        "with": {"name": f'{other.get("first_name", "")} {other.get("last_name", "")}'.strip(),
                 "title": other.get("title"), "company": other.get("company_name"),
                 "company_type": other.get("company_type"), "user_id": other.get("user_id")},
        "time": sc.local_time(m.get("confirmed_time")),
        "suggested_times": [sc.local_time(s) for s in suggested if s],
        "location": place or None,
        "subject": m.get("subject"),
        "message": m.get("message"),
        "sent_at": m.get("sent_at"),
    }
    if m.get("status") == "pending":
        row["recipient_seen"] = bool(m.get("seen"))
    if m.get("status") == "declined":
        row["declined_by"] = "me" if m.get("declined_by_id") == me else "them"
        row["decline_reason"] = m.get("decline_reason")
        row["decline_message"] = m.get("decline_message")
    rows.append(row)
rows.sort(key=lambda r: (r["status"] or "", r["time"] or (r["suggested_times"] or [""])[0]))
sc.emit_ok(rows)
