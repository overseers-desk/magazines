#!/usr/bin/env python3
"""SerpApi search wrapper — supports Google Flights, Google Search, Google Maps, and more.

Usage:
    # Google Flights (one-way)
    python3 search.py flights LHR BNE 2026-05-10 --currency EUR

    # Google Flights (return)
    python3 search.py flights LHR BNE 2026-05-10 --return-date 2026-05-20 --currency EUR

    # Google Search
    python3 search.py search "best noise cancelling headphones 2026"

    # Google Maps
    python3 search.py maps "restaurants near city centre"

    # Google Maps reviews (review timeline, newest first)
    python3 search.py reviews "Joe's Diner Brooklyn" --max 5

    # Google Hotels (list, then one property's prices)
    python3 search.py hotels "Gold Coast Australia hotels" 2026-05-10 2026-05-11 --brands 17 --sort 3
    python3 search.py hotels "Gold Coast Australia hotels" 2026-05-10 2026-05-11 --property-token <token>

    # Searches used and left this month
    python3 search.py account

API key is read from SERPAPI_KEY env var or [serpapi] api_key in ~/.config/magazines/config.ini.

Every response is saved under ~/.cache/magazines/serpapi/ and its path printed on
stderr as "raw: <path>"; an identical request inside its engine's REUSE_SECONDS
window is answered from that file instead of buying another search (--fresh buys one).
"""

import argparse
import configparser
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
import urllib.parse
from pathlib import Path

# A Google Maps data_id looks like 0x<hex>:0x<hex>; anything else is a place name.
DATA_ID_RE = re.compile(r"^0x[0-9a-f]+:0x[0-9a-f]+$", re.IGNORECASE)

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "magazines" / "serpapi"
CACHE_CAP_BYTES = 50 * 1024 * 1024
HOUR = 3600
# How long a saved response answers an identical request: prices go stale in
# hours, reviews arrive daily, web results drift over days, and a place
# listing barely changes in a month.
REUSE_SECONDS = {
    "google_flights": 6 * HOUR,
    "google_hotels": 6 * HOUR,
    "google_maps_reviews": 24 * HOUR,
    "google": 72 * HOUR,
    "google_maps": 30 * 24 * HOUR,
}


def get_api_key():
    key = os.environ.get("SERPAPI_KEY", "").strip()
    if key:
        return key
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    cfg_file = base / "magazines" / "config.ini"
    cp = configparser.ConfigParser(interpolation=None)
    cp.read([cfg_file, cfg_file.parent / "config.local.ini"])
    key = cp.get("serpapi", "api_key", fallback="").strip()
    if key:
        return key
    sys.exit("No API key found. Set SERPAPI_KEY or add api_key under [serpapi] in ~/.config/magazines/config.ini")


def cache_path(params):
    digest = hashlib.sha256(json.dumps(params, sort_keys=True).encode()).hexdigest()[:20]
    return CACHE_DIR / f"{params['engine']}-{digest}.json"


def describe_age(seconds):
    if seconds < HOUR:
        return f"{int(seconds // 60)} min"
    if seconds < 24 * HOUR:
        return f"{seconds / HOUR:.1f} h"
    return f"{seconds / (24 * HOUR):.1f} days"


def read_saved(path, window):
    try:
        with open(path) as f:
            saved = json.load(f)
    except (OSError, ValueError):
        return None
    if time.time() - saved.get("saved_at", 0) >= window:
        return None
    return saved


def prune_cache():
    """Drop entries past their engine's window, then the oldest until under the cap."""
    now = time.time()
    kept = []
    for path in CACHE_DIR.glob("*.json"):
        try:
            st = path.stat()
            engine = path.name.rsplit("-", 1)[0]
            if now - st.st_mtime >= REUSE_SECONDS.get(engine, 0):
                path.unlink()
            else:
                kept.append((st.st_mtime, st.st_size, path))
        except OSError:
            continue
    total = sum(size for _, size, _ in kept)
    for _, size, path in sorted(kept):
        if total <= CACHE_CAP_BYTES:
            break
        try:
            path.unlink()
            total -= size
        except OSError:
            pass


def save_response(path, params, data):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    with open(tmp, "w") as f:
        json.dump({"saved_at": time.time(), "params": params, "response": data}, f)
    os.replace(tmp, path)
    prune_cache()


def serpapi_request(params, fresh=False):
    """Return SerpApi's parsed JSON for params, answering from a saved identical
    response while it is inside its engine's REUSE_SECONDS window."""
    path = cache_path(params)
    window = REUSE_SECONDS[params["engine"]]
    saved = None if fresh else read_saved(path, window)
    if saved is not None:
        when = time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(saved["saved_at"]))
        age = describe_age(time.time() - saved["saved_at"])
        print(f"cached: saved {when} ({age} ago); --fresh buys a new search", file=sys.stderr)
        print(f"raw: {path}", file=sys.stderr)
        return saved["response"]
    url = "https://serpapi.com/search.json?" + urllib.parse.urlencode(dict(params, api_key=get_api_key()))
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read())
    if "error" not in data:
        save_response(path, params, data)
        print(f"raw: {path}", file=sys.stderr)
    return data


def cmd_flights(args):
    """Google Flights search.

    Key API parameters (learned from testing):
    - engine: google_flights
    - departure_id / arrival_id: IATA codes (e.g. LHR, BNE). For multi-airport
      cities use the city code or comma-separated IATAs.
    - outbound_date: YYYY-MM-DD
    - return_date: YYYY-MM-DD (omit for one-way; set type=2 for one-way)
    - type: 1 = round trip (default), 2 = one-way, 3 = multi-city
    - currency: EUR, USD, AUD, GBP etc.
    - hl: language (default en)
    - adults, children, infants_in_seat, infants_on_lap: passenger counts
    - travel_class: 1=Economy, 2=Premium economy, 3=Business, 4=First
    - stops: 0=any, 1=nonstop, 2=1 stop or fewer, 3=2 stops or fewer
    - max_price: integer price cap in the chosen currency

    Response structure:
    - best_flights: list of best itineraries (Google's ranking)
    - other_flights: list of remaining itineraries
    - price_insights: min/max price, price history, typical range

    Each itinerary has:
    - flights[]: list of legs, each with departure_airport, arrival_airport,
      duration, airline, flight_number, airplane, legroom, extensions
    - layovers[]: list with duration, name, id, overnight (bool)
    - total_duration: minutes
    - price: integer in chosen currency
    - type: "Round trip" or "One way"
    - airline_logo, carbon_emissions, extensions

    Gotchas:
    - For one-way searches you MUST set type=2, otherwise it defaults to
      round trip and requires return_date.
    - Multi-airport cities: use comma-separated codes (e.g. "LHR,LGW,STN")
      or known city codes. Google handles "LON" for London but the API may not;
      LHR alone works and returns the main hub results.
    - The API returns at most ~15-20 results per category (best/other).
    - Free plan: 250 searches/month. Each API call = 1 search.
    """
    params = {
        "engine": "google_flights",
        "departure_id": args.origin,
        "arrival_id": args.destination,
        "outbound_date": args.date,
        "currency": args.currency,
        "hl": "en",
    }
    if args.return_date:
        params["return_date"] = args.return_date
        params["type"] = "1"
    else:
        params["type"] = "2"  # one-way

    if args.adults != 1:
        params["adults"] = str(args.adults)
    if args.stops is not None:
        params["stops"] = str(args.stops)
    if args.travel_class != 1:
        params["travel_class"] = str(args.travel_class)
    if args.max_price:
        params["max_price"] = str(args.max_price)

    data = serpapi_request(params, args.fresh)

    if args.json:
        print(json.dumps(data, indent=2))
        return

    # Formatted output
    searches_left = data.get("search_metadata", {}).get("total_results", "?")
    print(f"Flights: {args.origin} -> {args.destination} on {args.date}")
    if args.return_date:
        print(f"Return: {args.return_date}")
    print(f"Currency: {args.currency}")
    print()

    for category in ["best_flights", "other_flights"]:
        flights = data.get(category, [])
        if not flights:
            continue
        label = "BEST FLIGHTS" if category == "best_flights" else "OTHER FLIGHTS"
        print(f"--- {label} ---")
        for i, itin in enumerate(flights, 1):
            price = itin.get("price", "?")
            dur = itin.get("total_duration", 0)
            hours, mins = divmod(dur, 60)
            legs = itin.get("flights", [])
            stops = len(legs) - 1
            airlines = ", ".join(sorted(set(l.get("airline", "") for l in legs)))
            dep = legs[0]["departure_airport"]["time"] if legs else "?"
            arr = legs[-1]["arrival_airport"]["time"] if legs else "?"

            print(f"  #{i:2d}  EUR {price:<8}  {hours}h{mins:02d}m  "
                  f"{stops} stop{'s' if stops != 1 else ''}  {airlines}")
            for leg in legs:
                da = leg["departure_airport"]
                aa = leg["arrival_airport"]
                ldur = leg.get("duration", 0)
                lh, lm = divmod(ldur, 60)
                fn = leg.get("flight_number", "")
                print(f"       {fn:8s}  {da['id']} {da['time']}  ->  "
                      f"{aa['id']} {aa['time']}   {lh}h{lm:02d}m")
            print()


def cmd_search(args):
    """Google Search."""
    params = {
        "engine": "google",
        "q": args.query,
        "num": str(args.num),
    }
    if args.location:
        params["location"] = args.location
    if args.gl:
        params["gl"] = args.gl
    if args.domain:
        params["google_domain"] = args.domain

    data = serpapi_request(params, args.fresh)

    if args.json:
        print(json.dumps(data, indent=2))
        return

    for r in data.get("organic_results", []):
        print(f"[{r.get('position', '?')}] {r.get('title', '')}")
        print(f"    {r.get('link', '')}")
        snippet = r.get("snippet", "")
        if snippet:
            print(f"    {snippet}")
        print()


def cmd_maps(args):
    """Google Maps search."""
    params = {
        "engine": "google_maps",
        "q": args.query,
    }
    if args.location:
        params["ll"] = args.location

    data = serpapi_request(params, args.fresh)

    if args.json:
        print(json.dumps(data, indent=2))
        return

    # A strong single match arrives as place_results (an object), a list as local_results.
    results = data.get("local_results") or ([data["place_results"]] if data.get("place_results") else [])
    for r in results:
        rating = r.get("rating", "?")
        reviews = r.get("reviews", "?")
        print(f"  {r.get('title', '')}  ({rating}* / {reviews} reviews)")
        print(f"    {r.get('address', '')}")
        kind = r.get("type", "")
        print(f"    {', '.join(kind) if isinstance(kind, list) else kind}")
        print()


def cmd_hotels(args):
    """Google Hotels: a destination's properties with rates, or one property's prices.

    With --property-token (a search result's property_token) the same engine
    returns that one property's rate options instead of a list.
    """
    params = {
        "engine": "google_hotels",
        "q": args.query,
        "check_in_date": args.check_in,
        "check_out_date": args.check_out,
        "hl": "en",
    }
    for key, value in (("adults", args.adults), ("children", args.children),
                       ("children_ages", args.children_ages), ("brands", args.brands),
                       ("sort_by", args.sort), ("currency", args.currency),
                       ("property_token", args.property_token)):
        if value is not None:
            params[key] = str(value)

    data = serpapi_request(params, args.fresh)

    if args.json:
        print(json.dumps(data, indent=2))
        return

    currency = (data.get("search_parameters") or {}).get("currency", "")
    if args.property_token:
        print(f"{data.get('name', '?')}  ({data.get('overall_rating', '?')}* / {data.get('reviews', '?')} reviews)")
        for p in data.get("prices", []):
            nightly = (p.get("rate_per_night") or {}).get("extracted_lowest", "?")
            total = (p.get("total_rate") or {}).get("extracted_lowest", "?")
            print(f"  {p.get('source', '?'):30s}  {currency} {nightly}/night  {currency} {total} total")
        return

    for p in data.get("properties", []):
        nightly = (p.get("rate_per_night") or {}).get("extracted_lowest", "?")
        total = (p.get("total_rate") or {}).get("extracted_lowest", "?")
        print(f"  {p.get('name', '')}  ({p.get('overall_rating', '?')}* / {p.get('reviews', '?')} reviews)")
        print(f"    {currency} {nightly}/night  {currency} {total} total")
        print(f"    property_token {p.get('property_token', '')}")
        print()


def cmd_account(args):
    """This month's searches used and left. The account endpoint is not a search."""
    url = "https://serpapi.com/account.json?" + urllib.parse.urlencode({"api_key": get_api_key()})
    with urllib.request.urlopen(urllib.request.Request(url), timeout=30) as resp:
        data = json.loads(resp.read())
    print(f"Used: {data.get('this_month_usage', '?')}/{data.get('searches_per_month', '?')}, "
          f"Left: {data.get('total_searches_left', '?')}")


def resolve_data_id(query, fresh=False):
    """Resolve a place name to a (data_id, title) via the google_maps engine.

    A strong single match comes back as place_results (an object); a list of
    candidates comes back as local_results. The top hit carries data_id.
    Costs 1 search.
    """
    data = serpapi_request({"engine": "google_maps", "q": query}, fresh)
    results = data.get("local_results") or []
    if not results and data.get("place_results"):
        results = [data["place_results"]]
    if not results:
        sys.exit(f"No place found for query: {query!r}")
    top = results[0]
    data_id = top.get("data_id")
    if not data_id:
        sys.exit(f"Top match {top.get('title', '?')!r} has no data_id; pass a data_id directly")
    return data_id, top.get("title", "")


def cmd_reviews(args):
    """Google Maps reviews — a place's review timeline (date + rating + text).

    Two-step chain:
    1. Resolve the place name to a data_id via the google_maps engine
       (skipped when a data_id is passed directly).
    2. Page through the google_maps_reviews engine, following
       serpapi_pagination.next_page_token to walk back through time.

    sort_by accepts newestFirst / mostRelevant / highestRating / lowestRating.
    Each review carries iso_date, rating, snippet, and user.name. Every request
    (the maps lookup and each review page) counts as 1 search, so --max caps the
    page walk — keep it small given the monthly quota.
    """
    place = args.place
    if DATA_ID_RE.match(place):
        data_id, title = place, place
    else:
        data_id, title = resolve_data_id(place, args.fresh)

    all_reviews = []
    next_token = None
    pages = 0
    while pages < args.max:
        params = {
            "engine": "google_maps_reviews",
            "data_id": data_id,
            "sort_by": args.sort,
        }
        if next_token:
            params["next_page_token"] = next_token
        data = serpapi_request(params, args.fresh)
        all_reviews.extend(data.get("reviews") or [])
        pages += 1
        next_token = (data.get("serpapi_pagination") or {}).get("next_page_token")
        if not next_token:
            break

    if args.json:
        print(json.dumps({"data_id": data_id, "place": title, "reviews": all_reviews}, indent=2))
        return

    plural = "s" if pages != 1 else ""
    print(f"Reviews for {title or data_id}  (data_id {data_id})")
    print(f"sorted: {args.sort}  —  {len(all_reviews)} reviews across {pages} page{plural}")
    print()
    for r in all_reviews:
        when = r.get("iso_date") or r.get("date", "?")
        rating = r.get("rating", "?")
        user = (r.get("user") or {}).get("name", "")
        print(f"  {when}  {rating}*  {user}")
        snippet = (r.get("snippet") or "").strip()
        for line in snippet.splitlines():
            print(f"    {line}")
        print()


def main():
    parser = argparse.ArgumentParser(description="SerpApi search wrapper")
    sub = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--json", action="store_true", help="Raw JSON output")
    common.add_argument("--fresh", action="store_true",
                        help="Buy a new search even when a recent identical response is saved")

    # flights
    fp = sub.add_parser("flights", parents=[common], help="Google Flights search")
    fp.add_argument("origin", help="Departure IATA code (e.g. LHR)")
    fp.add_argument("destination", help="Arrival IATA code (e.g. BNE)")
    fp.add_argument("date", help="Outbound date YYYY-MM-DD")
    fp.add_argument("--return-date", help="Return date YYYY-MM-DD (omit for one-way)")
    fp.add_argument("--currency", default="EUR")
    fp.add_argument("--adults", type=int, default=1)
    fp.add_argument("--stops", type=int, default=None, help="0=any, 1=nonstop, 2=≤1stop, 3=≤2stops")
    fp.add_argument("--travel-class", type=int, default=1, help="1=Economy 2=Premium 3=Business 4=First")
    fp.add_argument("--max-price", type=int, default=None)

    # search
    sp = sub.add_parser("search", parents=[common], help="Google Search")
    sp.add_argument("query", help="Search query")
    sp.add_argument("--num", type=int, default=10, help="Number of results")
    sp.add_argument("--location", help="Location for local results")
    sp.add_argument("--gl", help="Country code for the results (e.g. au); without it Google answers as google.com")
    sp.add_argument("--domain", help="Google domain to query (e.g. google.com.au)")

    # maps
    mp = sub.add_parser("maps", parents=[common], help="Google Maps search")
    mp.add_argument("query", help="Search query")
    mp.add_argument("--location", help="Lat,lng (e.g. @36.68,-6.14,14z)")

    # reviews
    rp = sub.add_parser("reviews", parents=[common], help="Google Maps reviews (review timeline)")
    rp.add_argument("place", help="Place name (resolved via Maps) or a data_id (0x...:0x...)")
    rp.add_argument("--sort", default="newestFirst",
                    choices=["newestFirst", "mostRelevant", "highestRating", "lowestRating"],
                    help="Review ordering (default: newestFirst)")
    rp.add_argument("--max", type=int, default=3,
                    help="Max review pages to fetch (default: 3; each page = 1 search)")

    # hotels
    hp = sub.add_parser("hotels", parents=[common], help="Google Hotels search or one property's prices")
    hp.add_argument("query", help="Destination search, e.g. \"Gold Coast Australia hotels\"")
    hp.add_argument("check_in", help="Check-in date YYYY-MM-DD")
    hp.add_argument("check_out", help="Check-out date YYYY-MM-DD")
    hp.add_argument("--adults", type=int)
    hp.add_argument("--children", type=int)
    hp.add_argument("--children-ages", help="Comma-separated ages 1-17, e.g. 5,8")
    hp.add_argument("--brands", help="Brand IDs, comma-separated (17 IHG, 28 Hilton, 33 Accor, 46 Marriott, 53 Wyndham)")
    hp.add_argument("--sort", type=int, choices=[3, 8, 13], help="3=lowest price 8=highest rating 13=most reviewed")
    hp.add_argument("--currency")
    hp.add_argument("--property-token", help="One property's prices, from a search result's property_token")

    # account
    sub.add_parser("account", help="Searches used and left this month (costs no search)")

    args = parser.parse_args()

    if args.command == "flights":
        cmd_flights(args)
    elif args.command == "search":
        cmd_search(args)
    elif args.command == "maps":
        cmd_maps(args)
    elif args.command == "reviews":
        cmd_reviews(args)
    elif args.command == "hotels":
        cmd_hotels(args)
    elif args.command == "account":
        cmd_account(args)


if __name__ == "__main__":
    main()
