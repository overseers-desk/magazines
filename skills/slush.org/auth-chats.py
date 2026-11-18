#!/usr/bin/env python3
"""The signed-in account's Slush chat. With no conversation id: every conversation,
latest first, with its unread count and last message; listing marks nothing read.
With a conversation id: its messages, newest first; this marks it read, as opening
it in the platform does."""

import argparse
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import slush_client as sc  # noqa: E402

BATCH = 20  # the platform's own batch size
ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument("group_id", nargs="?", help="a conversation id from the listing")
ap.add_argument("--unread", action="store_true", help="listing: only conversations with unread messages")
ap.add_argument("--limit", type=int, default=BATCH, help=f"reading: at most this many messages (default {BATCH})")
args = ap.parse_args()


def text(m, names):
    """One message as (kind, plain text)."""
    if m.get("deleted"):
        return "deleted", None
    body = m.get("message")
    if isinstance(body, dict) and body.get("type") == "meeting_event":
        return "meeting_event", f"meeting {body.get('event')} by {body.get('actor_name')}"
    if isinstance(body, dict) and body.get("type") not in (None, "doc"):
        return body["type"], json.dumps(body, ensure_ascii=False)
    return "text", sc.description(body)[0] if body else None


def row(m, names):
    kind, said = text(m, names)
    out = {"sent": sc.local_time(m.get("sent_at")), "from": names.get(m.get("user_id"), m.get("user_id")),
           "kind": kind, "text": said}
    reply = m.get("respondingTo")
    if reply:
        out["reply_to"] = text(reply, names)[1]
    files = [a.get("name") or a.get("filename") or a.get("url") for a in m.get("attachments") or []]
    if files:
        out["attachments"] = files
    return out


sc.login()
groups = sc.get("/groups", sc.CHAT) or []


def names_of(g):
    return {u.get("user_id"): f"{u.get('first_name') or ''} {u.get('last_name') or ''}".strip()
            for u in g.get("users") or []}


if not args.group_id:
    rows = []
    for g in groups:
        if args.unread and not g.get("unread_messages"):
            continue
        names = names_of(g)
        others = [n for uid, n in names.items() if uid != sc.user.get("user_id")]
        last = g.get("last_message") or {}
        rows.append({"group_id": g.get("group_id"), "with": ", ".join(others) or g.get("group_name"),
                     "unread": g.get("unread_messages") or 0, "pinned": bool(g.get("pinned")),
                     "last_message": row(last, names) if last else None,
                     "link": f"https://platform.slush.org/chat/{g.get('group_id')}"})
    rows.sort(key=lambda r: (r["last_message"] or {}).get("sent") or "", reverse=True)
    sc.emit_ok(rows)
    sys.exit(0)

group = next((g for g in groups if g.get("group_id") == args.group_id), None)
if not group:
    sc.fail(f"no conversation {args.group_id} in this account's chat", 65)
names = names_of(group)
msgs, path = [], f"/messages/{args.group_id}"
while len(msgs) < args.limit:
    batch = sc.get(path, sc.CHAT) or []
    msgs += batch
    if len(batch) < BATCH:
        break
    path = f"/messages/{args.group_id}?sent_at={urllib.parse.quote(batch[-1]['sent_at'])}"
sc.emit_ok({"group_id": args.group_id, "with": ", ".join(n for uid, n in names.items() if uid != sc.user.get("user_id")),
            "messages": [row(m, names) for m in msgs[:args.limit]]},
           has_more=len(msgs) > args.limit or (len(msgs) == args.limit and len(batch) == BATCH))
