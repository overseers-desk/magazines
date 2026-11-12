#!/usr/bin/env python3
"""Who is registered for one Slush side event, where the event shows its attendee
list: name, title, company and company type."""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

PAGE = 100
ap = argparse.ArgumentParser(description=__doc__)
sc.add_target_arg(ap)
ap.add_argument("side_event_id", help="from auth-side-events.py")
ap.add_argument("--company-type", help="keep one company type, e.g. vc-investor, startup")
ap.add_argument("--limit", type=int, default=1000, help="stop after this many registrations (default 1000)")
args = ap.parse_args()

sc.login()
regs, total, page = [], None, 1
while len(regs) < args.limit:
    b = sc.get(f"/side-events/{args.target}/public/{args.side_event_id}/registrations/visible"
               f"?page={page}&sorter[results]={PAGE}") or {}
    total = b.get("total", total)
    batch = b.get("registrations") or []
    regs += batch
    if len(batch) < PAGE:
        break
    page += 1
rows = [{"name": f'{r.get("first_name", "")} {r.get("last_name", "")}'.strip(), "title": r.get("title"),
         "company": r.get("company_name"), "company_type": r.get("company_type"),
         "country": r.get("country"), "status": r.get("status"), "user_id": r.get("user_id")}
        for r in regs[:args.limit]
        if not args.company_type or r.get("company_type") == args.company_type]
sc.emit_ok({"total_registrations": total, "attendees": rows},
           has_more=total is not None and len(regs) < total)
