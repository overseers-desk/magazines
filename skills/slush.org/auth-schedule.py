#!/usr/bin/env python3
"""The signed-in account's Slush agenda: confirmed meetings and anything added to
the agenda, in start order, with times in venue time (Europe/Helsinki)."""

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__)
sc.add_target_arg(ap)
args = ap.parse_args()

sc.login()
items = sc.get(f"/agenda/{args.target}/me?includeFromAgenda=true") or []
out = [{"kind": i.get("event_type"), "title": i.get("title"), "detail": i.get("description"),
        "start": sc.local_time(i.get("start_at")), "end": sc.local_time(i.get("end_at")),
        "location": i.get("location"), "start_utc": i.get("start_at"), "end_utc": i.get("end_at")}
       for i in items]
out.sort(key=lambda r: r["start_utc"] or "")
sc.emit_ok(out)
