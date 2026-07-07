#!/usr/bin/env python3
"""Interline Travel cruise search.

Usage:
    python3 search.py search [options]
    python3 search.py details <id>
    python3 search.py options [--region REGION] [--operator OPERATOR]
    python3 search.py suggest <query>

Subcommands:
    search    Search cruises with filters
    details   Show full details and itinerary for a cruise by ID
    options   List available filter values (regions, cruise lines, ships, ports, durations)
    suggest   Autocomplete search (returns matching regions, cruise lines, ships)

Search options:
    --region REGION          Filter by region (e.g. "Mediterranean", "Caribbean")
    --operator OPERATOR      Filter by cruise line name (e.g. "MSC Cruises")
    --ship SHIP              Filter by ship name
    --start-port PORT        Filter by departure port
    --end-port PORT          Filter by arrival port
    --duration BAND          Duration band (e.g. "4-7", "8-14", "15-20")
    --from DATE              Earliest departure (YYYY-MM-DD)
    --to DATE                Latest departure (YYYY-MM-DD)
    --return-by DATE         Cruise must end by this date (client-side filter)
    --type TYPE              Cruise type: Ocean, River
    --max-price N            Maximum price
    --q TEXT                 Free-text search
    --page N                 Page number (default: 1)
    --per-page N             Results per page (default: 20)
    --json                   Output raw JSON
"""

import sys, json, os, argparse, urllib.request, urllib.parse, http.cookiejar, tempfile, time
import configparser
from pathlib import Path

BASE = "https://interlinetravel.com.au"
CRUISE_URL = "https://interlinetravel.com.au/cruise"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
_COOKIE_FILE = Path(tempfile.gettempdir()) / "interline-travel-cookies.json"
_COOKIE_MAX_AGE = 3600 * 2  # reuse session for 2 hours

def _load_creds():
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    cfg_file = base / "magazines" / "config.ini"
    if not cfg_file.exists():
        sys.exit(f"Error: {cfg_file} not found. See Prerequisites in the interlinetravel.com.au SKILL.md.")
    cp = configparser.ConfigParser(interpolation=None)
    cp.read([cfg_file, cfg_file.parent / "config.local.ini"])
    email = cp.get("interlinetravel.com.au", "email", fallback="").strip()
    password = cp.get("interlinetravel.com.au", "password", fallback="").strip()
    if not (email and password):
        sys.exit("Error: ~/.config/magazines/config.ini missing [interlinetravel.com.au] email / password.")
    return {"INTERLINE_EMAIL": email, "INTERLINE_PASSWORD": password}

def _make_opener():
    cj = http.cookiejar.CookieJar()
    return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj)), cj

def _request(opener, url, method="GET", data=None, headers=None):
    hdrs = {"User-Agent": UA}
    if headers:
        hdrs.update(headers)
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    with opener.open(req) as resp:
        return json.loads(resp.read())

def _save_cookies(cj):
    cookies = []
    for c in cj:
        cookies.append({"name": c.name, "value": c.value, "domain": c.domain,
                         "path": c.path, "expires": c.expires})
    _COOKIE_FILE.write_text(json.dumps({"time": time.time(), "cookies": cookies}))

def _load_cookies(cj):
    if not _COOKIE_FILE.exists():
        return False
    try:
        data = json.loads(_COOKIE_FILE.read_text())
        if time.time() - data["time"] > _COOKIE_MAX_AGE:
            return False
        for c in data["cookies"]:
            cookie = http.cookiejar.Cookie(
                version=0, name=c["name"], value=c["value"], port=None, port_specified=False,
                domain=c["domain"], domain_specified=True, domain_initial_dot=c["domain"].startswith("."),
                path=c["path"], path_specified=True, secure=True, expires=c["expires"],
                discard=False, comment=None, comment_url=None, rest={})
            cj.set_cookie(cookie)
        return True
    except Exception:
        return False

def authenticate(opener, cj):
    # Try cached session first
    if _load_cookies(cj):
        try:
            me = _request(opener, f"{BASE}/api/auth/me")
            if "user" in me or "id" in me:
                return me
        except Exception:
            pass
    # Fresh login
    env = _load_creds()
    csrf = _request(opener, f"{BASE}/api/auth/csrf")["csrfToken"]
    result = _request(opener, f"{BASE}/api/auth/login", method="POST",
                      data={"identifier": env["INTERLINE_EMAIL"], "password": env["INTERLINE_PASSWORD"]},
                      headers={"X-CSRF-Token": csrf, "Origin": BASE})
    if "user" not in result:
        print(f"Login failed: {json.dumps(result)}", file=sys.stderr)
        sys.exit(1)
    _save_cookies(cj)
    return result["user"]

def _price_str(price):
    if not price or price == "0.00":
        return "POA"
    return f"${float(price):,.0f}"

def _per_night(price, nights):
    if not price or price == "0.00" or not nights:
        return ""
    return f"${float(price) / int(nights):,.0f}/n"

def cmd_search(opener, args):
    params = {}
    if args.region:
        params["region"] = args.region
    if args.operator:
        params["operator_name"] = args.operator
    if args.ship:
        params["ship_name"] = args.ship
    if args.start_port:
        params["start_port"] = args.start_port
    if args.end_port:
        params["end_port"] = args.end_port
    if args.duration:
        params["duration"] = args.duration
    if args.date_from:
        params["start_date_from"] = args.date_from
    if args.date_to:
        params["start_date_to"] = args.date_to
    if args.cruise_type:
        params["cruise_type"] = args.cruise_type
    if args.max_price:
        params["max_price"] = str(args.max_price)
    if args.q:
        params["q"] = args.q
    params["page"] = str(args.page)
    params["per_page"] = str(args.per_page)

    url = f"{BASE}/api/cruises/search?{urllib.parse.urlencode(params)}"
    data = _request(opener, url)

    # Client-side filter: return-by date
    if args.return_by:
        data["results"] = [c for c in data.get("results", []) if c.get("end_date", "")[:10] <= args.return_by]
        data["meta"]["total"] = f'{data["meta"].get("total", "?")} (filtered to {len(data["results"])})'

    if args.json:
        print(json.dumps(data, indent=2))
        return

    meta = data.get("meta", {})
    total = meta.get("total", "?")
    page = meta.get("page", "?")
    per_page = meta.get("per_page", "?")
    if isinstance(total, int) and isinstance(per_page, int) and per_page > 0:
        pages = -(-total // per_page)
    else:
        pages = "?"
    print(f"Page {page} of {pages} ({total} cruises)\n")

    results = data.get("results", [])
    if not results:
        print("No cruises found.")
        return

    # Header
    print(f"{'ID':>5}  {'Price':>8}  {'/night':>7}  {'Nts':>3}  {'Departs':>10}  {'Returns':>10}  {'Operator':<20}  {'Ship':<22}  {'Route'}")
    print("-" * 145)
    for c in results:
        price = c.get("price_from", "0.00")
        nights = c.get("duration_nights", 0)
        start = c.get("start_date", "")[:10]
        end = c.get("end_date", "")[:10]
        op = (c.get("operator", {}).get("name") or "?")[:20]
        ship = (c.get("ship", {}).get("name") or "?")[:22]
        sport = c.get("start_port", "?")
        eport = c.get("end_port", "?")
        route = f"{sport} -> {eport}" if sport != eport else sport
        cid = c.get("id", "?")
        print(f"{cid:>5}  {_price_str(price):>8}  {_per_night(price, nights):>7}  {nights:>3}  {start:>10}  {end:>10}  {op:<20}  {ship:<22}  {route}")
    print()
    print("Links:")
    for c in results:
        cid = c.get("id", "?")
        title = c.get("title", "?")
        print(f"  {cid}: {CRUISE_URL}/{cid}  {title}")

def cmd_details(opener, args):
    url = f"{BASE}/api/cruises/{args.cruise_id}/details"
    data = _request(opener, url)

    if args.json:
        print(json.dumps(data, indent=2))
        return

    price = data.get("price_from", "0.00")
    nights = data.get("duration_nights", 0)

    print(f"Cruise #{data['id']}: {data['title']}")
    print(f"  Link:      {CRUISE_URL}/{data['id']}")
    print(f"  Operator:  {data.get('operator', {}).get('name', '?')}")
    print(f"  Ship:      {data.get('ship', {}).get('name', '?')}")
    print(f"  Rating:    {data.get('rating_label', '?')}")
    print(f"  Type:      {data.get('cruise_type', '?')}")
    print(f"  Region:    {data.get('region', '?')}")
    print(f"  Duration:  {nights} nights")
    print(f"  Departs:   {data.get('start_date', '')[:10]} from {data.get('start_port', '?')}")
    print(f"  Arrives:   {data.get('end_date', '')[:10]} at {data.get('end_port', '?')}")
    print(f"  Price:     {_price_str(price)} ({_per_night(price, nights)} per night)" if price and price != "0.00" else "  Price:     POA (Price on Application)")

    api = data.get("api_data", {})
    fare_sets = api.get("fare_sets", [])
    if fare_sets:
        print(f"\n  Fares:")
        for fs in fare_sets:
            name = fs.get("name", "?")
            fares = fs.get("fares", [])
            available = [f for f in fares if f.get("availability") == "available"]
            if not available:
                continue
            print(f"    {name}:")
            for f in available:
                grade = f.get("grade_name", "?")
                fprice = f.get("price", "?")
                flight = f.get("flight_price")
                flight_str = f" (+${flight} flights)" if flight and flight != "0.0" else ""
                print(f"      ${fprice} {grade}{flight_str}")

    # Itinerary
    try:
        itin_url = f"{BASE}/api/cruises/{args.cruise_id}/itinerary-ports"
        itin = _request(opener, itin_url)
        ports = itin.get("ports", [])
        if ports:
            print(f"\n  Itinerary ({len(ports)} ports):")
            for j, p in enumerate(ports):
                marker = "->" if j > 0 else "  "
                print(f"    {marker} {p}")
    except Exception:
        pass

def cmd_options(opener, args):
    params = {}
    if args.region:
        params["region"] = args.region
    if args.operator:
        params["operator_name"] = args.operator
    qs = f"?{urllib.parse.urlencode(params)}" if params else ""
    url = f"{BASE}/api/cruises/cascading-options{qs}"
    data = _request(opener, url)

    if args.json:
        print(json.dumps(data, indent=2))
        return

    for key in ["regions", "cruiseLines", "ships", "departurePorts", "destinationPorts", "durationBands"]:
        items = data.get(key, [])
        print(f"\n{key} ({len(items)}):")
        for item in items[:50]:
            if isinstance(item, dict):
                print(f"  - {item.get('title') or item.get('name', '?')} (id={item.get('id', '?')})")
            else:
                print(f"  - {item}")
        if len(items) > 50:
            print(f"  ... and {len(items) - 50} more")

def cmd_suggest(opener, args):
    url = f"{BASE}/api/cruises/suggestions?q={urllib.parse.quote(args.query)}"
    data = _request(opener, url)

    if args.json:
        print(json.dumps(data, indent=2))
        return

    if not data:
        print("No suggestions.")
        return
    for item in data:
        icon = item.get("icon", "")
        kind = item.get("type", "?")
        text = item.get("text", "?")
        count = item.get("count", "")
        print(f"  {icon} [{kind}] {text} ({count} cruises)")

def main():
    parser = argparse.ArgumentParser(description="Interline Travel cruise search")
    sub = parser.add_subparsers(dest="command")

    sp_search = sub.add_parser("search", help="Search cruises")
    sp_search.add_argument("--region", help="Region filter")
    sp_search.add_argument("--operator", help="Cruise line name")
    sp_search.add_argument("--ship", help="Ship name")
    sp_search.add_argument("--start-port", help="Departure port")
    sp_search.add_argument("--end-port", help="Arrival port")
    sp_search.add_argument("--duration", help="Duration band (e.g. 4-7, 8-14)")
    sp_search.add_argument("--from", dest="date_from", help="Earliest departure YYYY-MM-DD")
    sp_search.add_argument("--to", dest="date_to", help="Latest departure YYYY-MM-DD")
    sp_search.add_argument("--return-by", dest="return_by", help="Must end by YYYY-MM-DD (client-side filter)")
    sp_search.add_argument("--type", dest="cruise_type", help="Cruise type: Ocean, River")
    sp_search.add_argument("--max-price", type=int, help="Max price")
    sp_search.add_argument("--q", help="Free-text search")
    sp_search.add_argument("--page", type=int, default=1, help="Page number")
    sp_search.add_argument("--per-page", type=int, default=20, help="Results per page")
    sp_search.add_argument("--json", action="store_true", help="Output raw JSON")

    sp_details = sub.add_parser("details", help="Cruise details by ID")
    sp_details.add_argument("cruise_id", type=int, help="Cruise ID")
    sp_details.add_argument("--json", action="store_true", help="Output raw JSON")

    sp_options = sub.add_parser("options", help="List available filter values")
    sp_options.add_argument("--region", help="Narrow options to a region")
    sp_options.add_argument("--operator", help="Narrow options to an operator")
    sp_options.add_argument("--json", action="store_true", help="Output raw JSON")

    sp_suggest = sub.add_parser("suggest", help="Autocomplete search")
    sp_suggest.add_argument("query", help="Search text")
    sp_suggest.add_argument("--json", action="store_true", help="Output raw JSON")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        sys.exit(1)

    opener, cj = _make_opener()
    authenticate(opener, cj)

    if args.command == "search":
        cmd_search(opener, args)
    elif args.command == "details":
        cmd_details(opener, args)
    elif args.command == "options":
        cmd_options(opener, args)
    elif args.command == "suggest":
        cmd_suggest(opener, args)

if __name__ == "__main__":
    main()
