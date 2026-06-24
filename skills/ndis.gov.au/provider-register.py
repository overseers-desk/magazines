#!/usr/bin/env python3
"""Query Australia's official NDIS provider register.

The register is the dataset behind the public "Find a registered NDIS provider"
finder. The finder is a static React app that downloads the whole register as one
JSON file and filters it in the browser; there is no server-side search endpoint.
This script fetches that same file and runs the same filters server-side.

Data sources (public, no auth):
  list-providers.json     every provider on the register, one row per office/outlet
  australian-postcodes.json   suburb/postcode -> lat/long, for region searches

A row is on the register whether its registration is currently active or has been
suspended/revoked: the register lists both. The row's `Active` field is the
distinction (1 = currently registered, 0 = on the register but not currently
active). `region` and `lookup` report it as registration_status.

Subcommands:
  region   --location "<suburb or postcode>" [--state QLD] [--radius KM]
           [--group "<name substring>" ...] [--active-only] [--limit N]
  lookup   --name "<substring>" | --abn <digits> [--active-only]
  groups   list the registration-group code -> name table

Output is JSON on stdout.
"""

import argparse
import json
import math
import sys
import urllib.request

BASE = "https://www.ndis.gov.au/sites/default/files/react_extract/provider_finder/build/"
PROVIDERS_URL = BASE + "data/list-providers.json"
POSTCODES_URL = BASE + "data/australian-postcodes.json"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36")

# Registration groups: Index -> (name, category). Index is the code stored in
# each provider row's RegGroup array. Source: the finder's JS bundle, which
# carries the canonical {Index, RegGroup, Group} table.
REG_GROUPS = {
    1: ("Accommodation / Tenancy Assistance", "Assistive Services"),
    2: ("Assistance Animals", "Assistive Services"),
    3: ("Assistance with daily life tasks in a group or shared living arrangement", "Assistive Services"),
    4: ("Assistance with travel/transport arrangements", "Assistive Services"),
    5: ("Daily Personal Activities", "Assistive Services"),
    6: ("Group and Centre Based Activities", "Assistive Services"),
    7: ("High Intensity Daily Personal Activities", "Assistive Services"),
    8: ("Household tasks", "Assistive Services"),
    9: ("Interpreting and translation", "Assistive Services"),
    10: ("Participation in community/social and civic activities", "Assistive Services"),
    11: ("Assistive equipment for recreation", "Assistive Technology"),
    12: ("Assistive products for household tasks", "Assistive Technology"),
    13: ("Assistance products for personal care and safety", "Assistive Technology"),
    14: ("Communication and information equipment", "Assistive Technology"),
    15: ("Customised Prosthetics", "Assistive Technology"),
    16: ("Hearing Equipment", "Assistive Technology"),
    17: ("Hearing Services", "Assistive Technology"),
    18: ("Personal Mobility Equipment", "Assistive Technology"),
    19: ("Specialised Hearing Services", "Assistive Technology"),
    20: ("Vision Equipment", "Assistive Technology"),
    21: ("Assistance in coordinating or managing life stages/transitions and supports", "Capacity Building Services"),
    22: ("Behaviour Support", "Capacity Building Services"),
    23: ("Community nursing care for high needs", "Capacity Building Services"),
    24: ("Development of daily living and life skills", "Capacity Building Services"),
    25: ("Early Intervention supports for early childhood", "Capacity Building Services"),
    26: ("Exercise Physiology and Physical Wellbeing activities", "Capacity Building Services"),
    27: ("Innovative Community Participation", "Capacity Building Services"),
    28: ("Specialised Driving Training", "Capacity Building Services"),
    29: ("Therapeutic Supports", "Capacity Building Services"),
    30: ("Home modification design and construction", "Capital Services"),
    31: ("Specialist Disability Accommodation", "Capital Services"),
    32: ("Vehicle Modifications", "Capital Services"),
    33: ("Plan Management", "Choice and Control Support Services"),
    34: ("Support Coordination", "Choice and Control Support Services"),
    35: ("Assistance to access and/or maintain employment and/or education", "Employment and Education Support Services"),
    36: ("Specialised Supported Employment", "Employment and Education Support Services"),
}


def fetch_json(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": UA,
        "Referer": "https://www.ndis.gov.au/",
        "Accept": "application/json",
    })
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def load_providers():
    doc = fetch_json(PROVIDERS_URL + "?nocache=" + str(int(__import__("time").time())))
    return doc.get("date", ""), doc.get("data", [])


def group_names(codes):
    out = []
    for c in codes or []:
        name = REG_GROUPS.get(c, (f"Unknown ({c})", ""))[0]
        out.append({"code": c, "name": name})
    return out


def reg_status(row):
    return "Currently registered" if row.get("Active") == 1 else "On register, not currently active (suspended/revoked/lapsed)"


def render(row, distance_km=None):
    out = {
        "name": row.get("Prov_N"),
        "abn": row.get("ABN"),
        "registration_status": reg_status(row),
        "active": row.get("Active"),
        "registration_groups": group_names(row.get("RegGroup")),
        "registration_group_codes": row.get("RegGroup"),
        "location": row.get("Address"),
        "state": row.get("State_cd"),
        "postcode": row.get("Post_cd"),
        "record_type": "Head Office" if row.get("Flag") == "H" else "Outlet",
        "outlet_name": row.get("Outletname") or None,
        "phone": row.get("Phone") or None,
        "email": row.get("Email") or None,
        "website": row.get("Website") or None,
        "profession": (row.get("prfsn") or "").strip() or None,
    }
    if distance_km is not None:
        out["distance_km"] = round(distance_km, 1)
    return out


def haversine(lat1, lon1, lat2, lon2):
    R = 6371.0
    p = math.pi / 180
    a = (math.sin((lat2 - lat1) * p / 2) ** 2
         + math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lon2 - lon1) * p / 2) ** 2)
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def resolve_location(location, state):
    postcodes = fetch_json(POSTCODES_URL)
    q = location.strip().lower()
    cands = []
    for p in postcodes:
        if state and p.get("state", "").upper() != state.upper():
            continue
        if q == p.get("postcode", "").lower() or q == p.get("locality", "").lower():
            cands.append(p)
    if not cands:  # loosen to substring on locality
        for p in postcodes:
            if state and p.get("state", "").upper() != state.upper():
                continue
            if q in p.get("locality", "").lower():
                cands.append(p)
    return cands


def cmd_region(args):
    centres = resolve_location(args.location, args.state)
    if not centres:
        print(json.dumps({"error": f"location not resolved: {args.location!r}"
                          + (f" in {args.state}" if args.state else "")}))
        sys.exit(2)
    c = centres[0]
    clat, clon = float(c["lat"]), float(c["long"])
    date, providers = load_providers()

    wanted = [g.lower() for g in (args.group or [])]
    best = {}  # abn -> (distance, row) keeping nearest office per provider
    for row in providers:
        if row.get("Flag") != "H":
            continue
        try:
            d = haversine(clat, clon, float(row["Latitude"]), float(row["Longitude"]))
        except (TypeError, ValueError):
            continue
        if d > args.radius:
            continue
        if args.active_only and row.get("Active") != 1:
            continue
        if wanted:
            names = [REG_GROUPS.get(g, ("", ""))[0].lower() for g in (row.get("RegGroup") or [])]
            if not any(w in n for n in names for w in wanted):
                continue
        abn = row.get("ABN")
        if abn not in best or d < best[abn][0]:
            best[abn] = (d, row)

    rows = sorted(best.values(), key=lambda t: t[0])
    if args.limit:
        rows = rows[:args.limit]
    print(json.dumps({
        "register_date": date,
        "centre": {"locality": c["locality"], "postcode": c["postcode"],
                   "state": c["state"], "lat": clat, "lon": clon},
        "radius_km": args.radius,
        "match_count": len(best),
        "returned": len(rows),
        "providers": [render(r, d) for d, r in rows],
    }, indent=2, ensure_ascii=False))


def cmd_lookup(args):
    date, providers = load_providers()
    if args.abn:
        digits = "".join(ch for ch in args.abn if ch.isdigit())
        hits = [r for r in providers if r.get("ABN") == digits]
    else:
        q = args.name.lower()
        hits = [r for r in providers if q in (r.get("Prov_N") or "").lower()]
    if args.active_only:
        hits = [r for r in hits if r.get("Active") == 1]

    # collapse to one entry per provider (per ABN), listing each office location
    by_abn = {}
    for r in hits:
        by_abn.setdefault(r.get("ABN"), []).append(r)
    results = []
    for abn, group in by_abn.items():
        head = next((r for r in group if r.get("Flag") == "H"), group[0])
        entry = render(head)
        entry["offices"] = [{"location": r.get("Address"),
                             "record_type": "Head Office" if r.get("Flag") == "H" else "Outlet",
                             "outlet_name": r.get("Outletname") or None}
                            for r in group]
        results.append(entry)
    print(json.dumps({
        "register_date": date,
        "query": {"name": args.name, "abn": args.abn},
        "match_count": len(results),
        "providers": results,
    }, indent=2, ensure_ascii=False))


def cmd_groups(_args):
    print(json.dumps({
        "registration_groups": [
            {"code": k, "name": v[0], "category": v[1]} for k, v in sorted(REG_GROUPS.items())
        ]
    }, indent=2, ensure_ascii=False))


def main():
    ap = argparse.ArgumentParser(description="Query the official NDIS provider register.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("region", help="search the register by location and radius")
    r.add_argument("--location", required=True, help="suburb name or postcode")
    r.add_argument("--state", default="", help="state code to disambiguate (e.g. QLD)")
    r.add_argument("--radius", type=float, default=25, help="radius in km (default 25)")
    r.add_argument("--group", action="append",
                   help="registration-group name substring filter (repeatable)")
    r.add_argument("--active-only", action="store_true",
                   help="only providers whose registration is currently active")
    r.add_argument("--limit", type=int, default=0, help="cap number returned (0 = all)")
    r.set_defaults(func=cmd_region)

    lk = sub.add_parser("lookup", help="look up a provider by name or ABN")
    lk.add_argument("--name", help="provider name substring")
    lk.add_argument("--abn", help="ABN (digits, spaces ignored)")
    lk.add_argument("--active-only", action="store_true")
    lk.set_defaults(func=cmd_lookup)

    g = sub.add_parser("groups", help="list registration-group codes and names")
    g.set_defaults(func=cmd_groups)

    args = ap.parse_args()
    if args.cmd == "lookup" and not (args.name or args.abn):
        ap.error("lookup needs --name or --abn")
    args.func(args)


if __name__ == "__main__":
    main()
