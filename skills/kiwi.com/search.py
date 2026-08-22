#!/usr/bin/env python3
# kiwi.com flight search against the public GraphQL endpoint the site's own
# front end calls:
#
#   POST https://api.skypicker.com/umbrella/v2/graphql
#
# No auth, no cookie: content-type: application/json is the only header the
# endpoint needs. Three root fields carry the three trip shapes, all three
# taking the same (search, filter, options) argument triple and returning the
# same ItinerariesResult union (Itineraries | AppError):
#
#   onewayItineraries     search: SearchOnewayInput      itinerary.sector
#   returnItineraries     search: SearchReturnInput      itinerary.outbound/.inbound
#   multicityItineraries  search: SearchMulticityInput   itinerary.sectors[]
#
# Places are opaque ids, not IATA codes: "Station:airport:SYD" for an airport,
# "City:london_gb" for a metro area. A code the caller gives (SYD, LON) is
# resolved through the `places` root field first, both endpoints aliased into
# one request, so a search costs two round trips at most.
#
# Kiwi sells virtual interlining: it will combine two carriers that have no
# interline agreement onto one booking, leaving the traveller to collect bags
# and check in again at the connection. Such a connection carries
# guarantee: KIWI_COM on the following sector segment (a carrier-protected
# connection carries CARRIER or null), and the itinerary then holds several
# PNRs. Both are reported: selfTransfer and pnrCount.
#
# Money arrives as a string amount plus a currency object; durations arrive in
# seconds. Segments carry no aircraft type, so the contract's `equipment` is
# always null here.

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import date as date_cls, datetime, timedelta

ENDPOINT = "https://api.skypicker.com/umbrella/v2/graphql"
BOOKING_BASE = "https://www.kiwi.com"
SOURCE = "kiwi.com"

# The contract's cabin names, mapped to the CabinClassType enum. Only FIRST
# differs.
CABINS = {
    "ECONOMY": "ECONOMY",
    "PREMIUM_ECONOMY": "PREMIUM_ECONOMY",
    "BUSINESS": "BUSINESS",
    "FIRST": "FIRST_CLASS",
}
MAX_LIMIT = 50      # filter.limit above this is silently truncated by the API
MIN_LEGS = 2
MAX_LEGS = 5
MAX_PASSENGERS = 9  # adults + children; the booking flow refuses a larger party

EXIT_VALIDATION = 2
EXIT_REJECTED = 3
EXIT_TRANSPORT = 4
EXIT_PAYLOAD = 5

SEGMENT_FIELDS = """
  duration
  code
  cabinClass
  carrier { code name }
  operatingCarrier { code name }
  source { localTime station { code name } }
  destination { localTime station { code name } }
"""

SECTOR_FIELDS = """
  duration
  sectorSegments {
    guarantee
    layover { duration isStationChange isBaggageRecheck }
    segment { %s }
  }
""" % SEGMENT_FIELDS

ITINERARY_COMMON = """
  id
  duration
  pnrCount
  price { amount currency { code } }
  provider { name code }
  bagsInfo { includedHandBags includedCheckedBags }
  bookingOptions { edges { node {
    bookingUrl
    price { amount currency { code } }
    itineraryProvider { name code }
  } } }
"""

QUERIES = {
    "one-way": """
query($search: SearchOnewayInput, $filter: ItinerariesFilterInput, $options: ItinerariesOptionsInput) {
  onewayItineraries(search: $search, filter: $filter, options: $options) {
    __typename
    ... on AppError { code message }
    ... on Itineraries {
      metadata { itinerariesCount }
      itineraries { ... on ItineraryOneWay { %s sector { %s } } }
    }
  }
}""" % (ITINERARY_COMMON, SECTOR_FIELDS),
    "return": """
query($search: SearchReturnInput, $filter: ItinerariesFilterInput, $options: ItinerariesOptionsInput) {
  returnItineraries(search: $search, filter: $filter, options: $options) {
    __typename
    ... on AppError { code message }
    ... on Itineraries {
      metadata { itinerariesCount }
      itineraries { ... on ItineraryReturn { %s outbound { %s } inbound { %s } } }
    }
  }
}""" % (ITINERARY_COMMON, SECTOR_FIELDS, SECTOR_FIELDS),
    "multi-city": """
query($search: SearchMulticityInput, $filter: ItinerariesFilterInput, $options: ItinerariesOptionsInput) {
  multicityItineraries(search: $search, filter: $filter, options: $options) {
    __typename
    ... on AppError { code message }
    ... on Itineraries {
      metadata { itinerariesCount }
      itineraries { ... on ItineraryMulticity { %s sectors { %s } } }
    }
  }
}""" % (ITINERARY_COMMON, SECTOR_FIELDS),
}

ROOT_FIELD = {
    "one-way": "onewayItineraries",
    "return": "returnItineraries",
    "multi-city": "multicityItineraries",
}

PLACES_QUERY = """
query(%s) {
  %s
}"""
PLACES_ALIAS = """
  %s: places(search: {term: $%s}, filter: {onlyTypes: [AIRPORT, CITY]}, first: 10) {
    ... on PlaceConnection { edges { node {
      __typename id name
      ... on Station { code }
    } } }
  }"""


def die(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)


def graphql(query, variables):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(
        ENDPOINT, data=body, method="POST",
        headers={"content-type": "application/json", "accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        detail = raw[:300].decode("utf-8", "replace")
        try:
            errs = json.loads(raw).get("errors") or []
            if errs:
                detail = "; ".join(str(x.get("message")) for x in errs)[:300]
        except (ValueError, AttributeError):
            pass
        die(EXIT_REJECTED, "request rejected: HTTP %d from %s: %s" % (e.code, ENDPOINT, detail))
    except (urllib.error.URLError, OSError) as e:
        die(EXIT_TRANSPORT, "transport failure: %s: %s" % (ENDPOINT, e))
    try:
        doc = json.loads(raw)
    except ValueError:
        die(EXIT_TRANSPORT, "transport failure: %s answered %d bytes that do not parse as JSON"
            % (ENDPOINT, len(raw)))
    if doc.get("errors") and not doc.get("data"):
        # A 200 carrying only errors is a schema complaint: the query no longer
        # matches what the endpoint serves.
        msgs = "; ".join(str(x.get("message")) for x in doc["errors"])[:300]
        die(EXIT_PAYLOAD, "unexpected payload: the GraphQL endpoint rejected the query: %s" % msgs)
    if not isinstance(doc.get("data"), dict):
        die(EXIT_PAYLOAD, "unexpected payload: no data object in the answer")
    return doc["data"]


def resolve_places(codes):
    """IATA codes -> kiwi place ids, every code in one request.

    An exact Station code match wins (SYD -> Station:airport:SYD). Failing
    that, the first City the term matches is the metro area (LON ->
    City:london_gb), which is what a caller giving a city code means.
    """
    names = ["p%d" % i for i in range(len(codes))]
    query = PLACES_QUERY % (
        ", ".join("$%s: String!" % n for n in names),
        "".join(PLACES_ALIAS % (n, n) for n in names))
    data = graphql(query, {n: c for n, c in zip(names, codes)})
    out = []
    for name, code in zip(names, codes):
        conn = data.get(name) or {}
        edges = conn.get("edges") or []
        station = city = None
        for edge in edges:
            node = (edge or {}).get("node") or {}
            if node.get("__typename") == "Station" and (node.get("code") or "").upper() == code:
                station = node
                break
            if node.get("__typename") == "City" and city is None:
                city = node
        node = station or city
        if not node:
            die(EXIT_VALIDATION, "bad route: %s is not an airport or city kiwi.com knows" % code)
        out.append({"id": node["id"], "name": node.get("name") or code, "code": code})
    return out


def day_range(datestr):
    return {"start": "%sT00:00:00" % datestr, "end": "%sT23:59:59" % datestr}


def build_search(bounds, places, trip, args):
    passengers = {
        "adults": args.adults,
        "children": args.children,
        "infants": args.infants,
        "adultsHandBags": [0] * args.adults,
        "adultsHoldBags": [0] * args.adults,
    }
    if args.children:
        passengers["childrenHandBags"] = [0] * args.children
        passengers["childrenHoldBags"] = [0] * args.children
    cabin = {"cabinClass": CABINS[args.cabin], "applyMixedClasses": False}
    if trip == "one-way":
        itinerary = {
            "source": {"ids": [places[0]["id"]]},
            "destination": {"ids": [places[1]["id"]]},
            "outboundDepartureDate": day_range(bounds[0]["date"]),
        }
    elif trip == "return":
        itinerary = {
            "source": {"ids": [places[0]["id"]]},
            "destination": {"ids": [places[1]["id"]]},
            "outboundDepartureDate": day_range(bounds[0]["date"]),
            "inboundDepartureDate": day_range(bounds[1]["date"]),
        }
    else:
        itinerary = [{
            "source": {"ids": [b["place_from"]["id"]]},
            "destination": {"ids": [b["place_to"]["id"]]},
            "outboundDepartureDate": day_range(b["date"]),
        } for b in bounds]
    return {"itinerary": itinerary, "passengers": passengers, "cabinClass": cabin}


def build_options(args):
    options = {
        "sortBy": "PRICE",
        "locale": "en",
        "partner": "skypicker",
        "storeSearch": False,
        "searchStrategy": "REDUCED",
    }
    if args.currency:
        # The endpoint wants the ISO code in lower case.
        options["currency"] = args.currency.lower()
    return options


def run_search(bounds, places, trip, args):
    variables = {
        "search": build_search(bounds, places, trip, args),
        "filter": {
            "allowChangeInboundDestination": True,
            "allowChangeInboundSource": True,
            "allowDifferentStationConnection": True,
            "enableSelfTransfer": True,
            "transportTypes": ["FLIGHT"],
            "contentProviders": ["KIWI"],
            "limit": min(args.limit, MAX_LIMIT),
        },
        "options": build_options(args),
    }
    data = graphql(QUERIES[trip], variables)
    result = data.get(ROOT_FIELD[trip])
    if not isinstance(result, dict):
        die(EXIT_PAYLOAD, "unexpected payload: %s missing from the answer" % ROOT_FIELD[trip])
    if result.get("__typename") == "AppError":
        die(EXIT_REJECTED, "request rejected: %s: %s"
            % (result.get("code") or "AppError", result.get("message") or "no message"))
    if "itineraries" not in result:
        die(EXIT_PAYLOAD, "unexpected payload: %s answered without an itineraries list (%s)"
            % (ROOT_FIELD[trip], result.get("__typename")))
    return result


# ---------------------------------------------------------------- shaping ---

def parse_local(dt):
    try:
        return datetime.strptime(dt, "%Y-%m-%dT%H:%M:%S")
    except (TypeError, ValueError):
        return None


def minutes(seconds):
    return None if seconds is None else int(seconds) // 60


def money_amount(price):
    try:
        return float((price or {}).get("amount"))
    except (TypeError, ValueError):
        return None


def sector_segments(sector):
    return [s for s in ((sector or {}).get("sectorSegments") or []) if s.get("segment")]


def leg_from_sector(sector):
    segs = sector_segments(sector)
    if not segs:
        return None
    first = segs[0]["segment"]
    last = segs[-1]["segment"]
    out = []
    for s in segs:
        seg = s["segment"]
        carrier = seg.get("carrier") or {}
        oper = seg.get("operatingCarrier") or {}
        code = carrier.get("code") or ""
        operated = None
        if oper.get("code") and oper.get("code") != code:
            operated = "%s %s" % (oper["code"], oper.get("name") or "")
            operated = operated.strip()
        out.append({
            "flight": "%s%s" % (code, seg.get("code") or ""),
            "carrier": code or None,
            "carrierName": carrier.get("name"),
            "operatedBy": operated,
            "origin": ((seg.get("source") or {}).get("station") or {}).get("code"),
            "departure": (seg.get("source") or {}).get("localTime"),
            "destination": ((seg.get("destination") or {}).get("station") or {}).get("code"),
            "arrival": (seg.get("destination") or {}).get("localTime"),
            "durationMinutes": minutes(seg.get("duration")),
            "equipment": None,
            "cabinClass": seg.get("cabinClass"),
            "selfTransferBefore": s.get("guarantee") == "KIWI_COM",
        })
    return {
        "origin": ((first.get("source") or {}).get("station") or {}).get("code"),
        "destination": ((last.get("destination") or {}).get("station") or {}).get("code"),
        "departure": (first.get("source") or {}).get("localTime"),
        "arrival": (last.get("destination") or {}).get("localTime"),
        "durationMinutes": minutes(sector.get("duration")),
        "stops": max(len(segs) - 1, 0),
        "segments": out,
    }


def itinerary_legs(itin, trip):
    if trip == "one-way":
        sectors = [itin.get("sector")]
    elif trip == "return":
        sectors = [itin.get("outbound"), itin.get("inbound")]
    else:
        sectors = itin.get("sectors") or []
    legs = [leg_from_sector(s) for s in sectors]
    return [l for l in legs if l]


def booking_options(itin):
    out = []
    for edge in ((itin.get("bookingOptions") or {}).get("edges") or []):
        node = (edge or {}).get("node") or {}
        url = node.get("bookingUrl")
        if url and url.startswith("/"):
            url = BOOKING_BASE + url
        out.append({
            "seller": ((node.get("itineraryProvider") or {}).get("name")),
            "price": {"amount": money_amount(node.get("price")),
                      "currency": ((node.get("price") or {}).get("currency") or {}).get("code")},
            "bookingUrl": url,
        })
    return out


def shape(itin, trip):
    legs = itinerary_legs(itin, trip)
    options = booking_options(itin)
    price = itin.get("price") or {}
    bags = itin.get("bagsInfo") or {}
    self_transfer = any(seg["selfTransferBefore"] for leg in legs for seg in leg["segments"])
    return {
        "price": {"amount": money_amount(price),
                  "currency": (price.get("currency") or {}).get("code")},
        "durationMinutes": minutes(itin.get("duration")),
        "legs": legs,
        "seller": (options[0]["seller"] if options else (itin.get("provider") or {}).get("name")),
        "bookingUrl": (options[0]["bookingUrl"] if options else None),
        "selfTransfer": self_transfer,
        "pnrCount": itin.get("pnrCount"),
        "bagsIncluded": {"handBags": bags.get("includedHandBags"),
                         "checkedBags": bags.get("includedCheckedBags")},
        "bookingOptions": options,
    }


# ----------------------------------------------------------------- output ---

def fmt_duration(mins):
    if mins is None:
        return "?"
    d, rem = divmod(int(mins), 24 * 60)
    h, m = divmod(rem, 60)
    if d:
        return "%dd %02dh %02dm" % (d, h, m)
    return "%dh %02dm" % (h, m)


def clock(dt_iso, base_date):
    d = parse_local(dt_iso)
    if d is None:
        return "?"
    off = (d.date() - base_date).days
    return d.strftime("%H:%M") + ("+%d" % off if off > 0 else "")


def stops_word(n):
    return "nonstop" if n == 0 else ("1 stop" if n == 1 else "%d stops" % n)


def carriers_of(legs):
    names = []
    for leg in legs:
        for seg in leg["segments"]:
            n = seg.get("carrierName") or seg.get("carrier")
            if n and n not in names:
                names.append(n)
    return ", ".join(names)


def leg_labels(trip, count):
    if trip == "one-way":
        return [None]
    if trip == "return":
        return ["out", "back"]
    return ["leg %d" % (i + 1) for i in range(count)]


def render_text(itins, args, bounds, trip, total, currency):
    pax = ["%d adult%s" % (args.adults, "" if args.adults == 1 else "s")]
    if args.children:
        pax.append("%d child%s" % (args.children, "" if args.children == 1 else "ren"))
    if args.infants:
        pax.append("%d infant%s" % (args.infants, "" if args.infants == 1 else "s"))
    if trip == "multi-city":
        route = ", ".join("%s → %s %s" % (b["origin"], b["dest"], b["date"]) for b in bounds)
    elif trip == "return":
        route = "%s → %s %s, back %s" % (bounds[0]["origin"], bounds[0]["dest"],
                                         bounds[0]["date"], bounds[1]["date"])
    else:
        route = "%s → %s %s" % (bounds[0]["origin"], bounds[0]["dest"], bounds[0]["date"])
    head = "%s, %s, %s; %s itineraries, showing %d, prices in %s" % (
        route, ", ".join(pax), args.cabin,
        "unknown number of" if total is None else total, len(itins), currency or "?")
    if not itins:
        out = head + "\n\nNo itineraries"
        if trip == "multi-city":
            out += ("\n(multicityItineraries has answered 0 for every anonymous search tried, "
                    "including routes its one-way field prices; price the legs as one-ways instead)")
        return out

    labels = leg_labels(trip, len(bounds))
    out = [head]
    for n, it in enumerate(itins, 1):
        price = it["price"]
        out.append("")
        out.append("#%-3d %s %s   %s   %s   %s" % (
            n, price["currency"] or "", fmt_amount(price["amount"]),
            fmt_duration(it["durationMinutes"]),
            stops_word(sum(l["stops"] for l in it["legs"])),
            carriers_of(it["legs"])))
        for i, leg in enumerate(it["legs"]):
            base = bounds[i]["qdate"] if i < len(bounds) else bounds[-1]["qdate"]
            label = labels[i] if i < len(labels) else "leg %d" % (i + 1)
            if label:
                out.append("    %-6s %s   %s %s → %s %s   %s   %s" % (
                    label, bounds[i]["date"] if i < len(bounds) else "",
                    leg["origin"], clock(leg["departure"], base),
                    leg["destination"], clock(leg["arrival"], base),
                    fmt_duration(leg["durationMinutes"]), stops_word(leg["stops"])))
            for seg in leg["segments"]:
                line = "    %-8s %s %s → %s %s   %s" % (
                    seg["flight"], seg["origin"], clock(seg["departure"], base),
                    seg["destination"], clock(seg["arrival"], base),
                    fmt_duration(seg["durationMinutes"]))
                if seg["operatedBy"]:
                    line += "   op %s" % seg["operatedBy"]
                out.append(("    " + line.lstrip()) if label else line)
        extras = []
        if it["selfTransfer"]:
            extras.append("self-transfer: bags collected and re-checked at a connection, "
                          "%s separate tickets" % (it["pnrCount"] or "several"))
        bags = it["bagsIncluded"]
        extras.append("bags included: %s hand, %s checked"
                      % (bags["handBags"], bags["checkedBags"]))
        for e in extras:
            out.append("    %s" % e)
        if it["seller"]:
            # The booking URL is a kilobyte of token per itinerary; the text
            # answer names the seller and leaves the link to --json.
            tail = "    via %s" % it["seller"]
            if it["bookingUrl"]:
                tail += " (booking link in --json)"
            out.append(tail)
    return "\n".join(out)


def fmt_amount(a):
    return "?" if a is None else ("%.2f" % a)


def render_json(itins, args, bounds, trip, total, currency):
    return json.dumps({
        "source": SOURCE,
        "tripType": trip,
        "bounds": [{"origin": b["origin"], "destination": b["dest"], "date": b["date"]}
                   for b in bounds],
        "passengers": {"adults": args.adults, "children": args.children,
                       "infants": args.infants},
        "cabinClassRequested": args.cabin,
        "currency": currency,
        "totalResults": total,
        "itineraries": itins,
    }, indent=2, ensure_ascii=False)


# ------------------------------------------------------------- validation ---

def parse_args():
    ap = argparse.ArgumentParser(
        add_help=True,
        description="kiwi.com flight search: one-way, return, or multi-city.",
        usage="%(prog)s <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] "
              "[--children N] [--infants N] [--cabin ECONOMY|PREMIUM_ECONOMY|BUSINESS|FIRST] "
              "[--currency CCC] [--limit N] [--json]\n"
              "       %(prog)s --leg DEP-ARR-YYYY-MM-DD --leg DEP-ARR-YYYY-MM-DD [--leg ...] "
              "[same options]")
    ap.add_argument("origin", nargs="?")
    ap.add_argument("dest", nargs="?")
    ap.add_argument("date", nargs="?")
    ap.add_argument("--return", dest="ret", metavar="YYYY-MM-DD")
    ap.add_argument("--leg", dest="legs", action="append", metavar="DEP-ARR-YYYY-MM-DD")
    ap.add_argument("--adults", type=int, default=1)
    ap.add_argument("--children", type=int, default=0)
    ap.add_argument("--infants", type=int, default=0)
    ap.add_argument("--cabin", default="ECONOMY", type=str.upper)
    ap.add_argument("--currency", default=None)
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--json", action="store_true")
    return ap.parse_args()


def valid_iata(code, what):
    code = (code or "").upper()
    if not re.fullmatch(r"[A-Z]{3}", code):
        die(EXIT_VALIDATION, "bad route: %s must be a 3-letter IATA code, got %s" % (what, code))
    return code


def valid_date(s, what):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", s or ""):
        die(EXIT_VALIDATION, "bad date: %s expected YYYY-MM-DD, got %s" % (what, s))
    try:
        d = datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        die(EXIT_VALIDATION, "bad date: %s is not a calendar date" % s)
    if d < date_cls.today():
        die(EXIT_VALIDATION, "bad date: %s is in the past" % s)
    if d > date_cls.today() + timedelta(days=365):
        die(EXIT_VALIDATION, "bad date: %s is more than a year out, further than kiwi.com sells" % s)
    return d


def parse_bounds(args):
    if args.legs:
        if args.origin or args.dest or args.date or args.ret:
            die(EXIT_VALIDATION,
                "bad arguments: --leg replaces the positional route and excludes --return")
        if not MIN_LEGS <= len(args.legs) <= MAX_LEGS:
            die(EXIT_VALIDATION, "bad leg: multi-city takes %d to %d --leg segments, got %d"
                % (MIN_LEGS, MAX_LEGS, len(args.legs)))
        bounds = []
        for i, spec in enumerate(args.legs, 1):
            m = re.fullmatch(r"([A-Za-z]{3})-([A-Za-z]{3})-(\d{4}-\d{2}-\d{2})", spec or "")
            if not m:
                die(EXIT_VALIDATION, "bad leg: expected DEP-ARR-YYYY-MM-DD, got %s" % spec)
            o, d, dt = m.group(1).upper(), m.group(2).upper(), m.group(3)
            if o == d:
                die(EXIT_VALIDATION, "bad leg: origin and destination are both %s" % o)
            bounds.append({"origin": o, "dest": d, "date": dt,
                           "qdate": valid_date(dt, "leg %d" % i)})
        for prev, nxt in zip(bounds, bounds[1:]):
            if nxt["qdate"] < prev["qdate"]:
                die(EXIT_VALIDATION, "bad leg: %s departs %s, before the prior leg's %s"
                    % (nxt["origin"], nxt["date"], prev["date"]))
        return bounds, "multi-city"

    if not (args.origin and args.dest and args.date):
        die(EXIT_VALIDATION, "bad arguments: give <origin> <dest> <date>, or %d to %d --leg segments"
            % (MIN_LEGS, MAX_LEGS))
    o = valid_iata(args.origin, "origin")
    d = valid_iata(args.dest, "destination")
    if o == d:
        die(EXIT_VALIDATION, "bad route: origin and destination are both %s" % o)
    qdate = valid_date(args.date, "date")
    bounds = [{"origin": o, "dest": d, "date": args.date, "qdate": qdate}]
    if args.ret:
        rdate = valid_date(args.ret, "--return")
        if rdate < qdate:
            die(EXIT_VALIDATION, "bad date: return %s is before the outbound %s"
                % (args.ret, args.date))
        bounds.append({"origin": d, "dest": o, "date": args.ret, "qdate": rdate})
        return bounds, "return"
    return bounds, "one-way"


def validate(args):
    if args.cabin not in CABINS:
        die(EXIT_VALIDATION, "bad cabin: expected one of %s, got %s"
            % ("|".join(CABINS), args.cabin))
    if args.currency is not None and not re.fullmatch(r"[A-Za-z]{3}", args.currency):
        die(EXIT_VALIDATION, "bad currency: expected a 3-letter ISO code, got %s" % args.currency)
    for name, v in (("adults", args.adults), ("children", args.children),
                    ("infants", args.infants)):
        if v < 0:
            die(EXIT_VALIDATION, "bad passenger count: %s cannot be negative, got %d" % (name, v))
    if args.adults < 1:
        die(EXIT_VALIDATION, "bad passenger count: at least 1 adult")
    if args.infants > args.adults:
        die(EXIT_VALIDATION, "bad passenger count: infants (%d) exceed adults (%d)"
            % (args.infants, args.adults))
    if args.adults + args.children > MAX_PASSENGERS:
        die(EXIT_VALIDATION,
            "bad passenger count: at most %d adults and children in total, got %d"
            % (MAX_PASSENGERS, args.adults + args.children))
    if args.limit < 1:
        die(EXIT_VALIDATION, "bad arguments: --limit must be at least 1, got %d" % args.limit)


def main():
    args = parse_args()
    bounds, trip = parse_bounds(args)
    validate(args)

    codes = []
    for b in bounds:
        codes += [b["origin"], b["dest"]]
    places = resolve_places(codes)
    for i, b in enumerate(bounds):
        b["place_from"] = places[2 * i]
        b["place_to"] = places[2 * i + 1]

    result = run_search(bounds, [bounds[0]["place_from"], bounds[0]["place_to"]], trip, args)
    total = (result.get("metadata") or {}).get("itinerariesCount")
    raw = result.get("itineraries") or []
    itins = [shape(it, trip) for it in raw if it]
    itins = [it for it in itins if it["legs"]]
    itins.sort(key=lambda it: (it["price"]["amount"] is None, it["price"]["amount"] or 0))
    itins = itins[:args.limit]
    currency = next((it["price"]["currency"] for it in itins if it["price"]["currency"]), None)
    if currency is None and args.currency:
        currency = args.currency.upper()

    if args.json:
        print(render_json(itins, args, bounds, trip, total, currency))
    else:
        print(render_text(itins, args, bounds, trip, total, currency))


if __name__ == "__main__":
    main()
