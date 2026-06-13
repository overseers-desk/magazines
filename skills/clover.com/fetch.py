#!/usr/bin/env python3
"""Fetch Clover AP orders for a date range as JSONL.

One Clover Order object per line, with lineItems.modifications, payments,
and refunds expanded. Token comes from ~/.claude/skills/config.ini under
[clover.com] api_token. Merchant id is resolved at runtime via
/v3/merchants/current — never stored in config.
"""
import argparse
import configparser
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

CONFIG = os.path.expanduser("~/.claude/skills/config.ini")
BASE = "https://api.ap.clover.com"
PAGE = 100
EXPAND = "lineItems.modifications,payments,refunds"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("date_from", help="Inclusive YYYY-MM-DD in --tz")
    p.add_argument("date_to",   help="Inclusive YYYY-MM-DD in --tz")
    p.add_argument("-o", "--output", required=True, help="Output JSONL path")
    p.add_argument("--tz", default="Australia/Brisbane",
                   help="IANA tz for date bounds (default Australia/Brisbane)")
    return p.parse_args()


def load_token():
    cfg = configparser.ConfigParser()
    cfg.read([CONFIG, CONFIG.replace("config.ini", "config.local.ini")])
    if "clover.com" not in cfg or "api_token" not in cfg["clover.com"]:
        sys.exit(f"FAIL: {CONFIG} missing [clover.com] api_token")
    return cfg["clover.com"]["api_token"].strip()


def api_get(token, path):
    req = urllib.request.Request(
        BASE + path,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def date_to_ms(date_str, end_of_day, tz_name):
    d = dt.date.fromisoformat(date_str)
    t = dt.time(23, 59, 59, 999000) if end_of_day else dt.time(0, 0, 0)
    return int(dt.datetime.combine(d, t, tzinfo=ZoneInfo(tz_name)).timestamp() * 1000)


def main():
    args = parse_args()
    token = load_token()
    mid = api_get(token, "/v3/merchants/current")["id"]

    start_ms = date_to_ms(args.date_from, False, args.tz)
    end_ms   = date_to_ms(args.date_to,   True,  args.tz)

    total = 0
    offset = 0
    with open(args.output, "w") as out:
        while True:
            params = [
                ("limit",  PAGE),
                ("offset", offset),
                ("expand", EXPAND),
                ("filter", f"createdTime>={start_ms}"),
                ("filter", f"createdTime<={end_ms}"),
            ]
            path = f"/v3/merchants/{mid}/orders?{urllib.parse.urlencode(params)}"
            body = api_get(token, path)
            elems = body.get("elements", [])
            if not elems:
                break
            for o in elems:
                out.write(json.dumps(o, separators=(",", ":")) + "\n")
            total += len(elems)
            if len(elems) < PAGE:
                break
            offset += PAGE
            if offset >= 10000:
                print("WARNING: pagination offset hit 10000 — split the date range",
                      file=sys.stderr)
                break

    print(f"wrote {total} orders to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
