#!/usr/bin/env python3
# beatthatflight.com.au flight search.
#
# The site's own search runs on a Travelpayouts (Aviasales) white-label hosted
# at book.beatthatflight.com.au, and that widget talks to the Travelpayouts
# flight API in plain JSON over HTTPS. No browser, no cookie, no credential:
# every call below is an anonymous POST or GET carrying beatthatflight's own
# public affiliate marker, the one its public page hands to any visitor.
#
# One search is three calls, plus one cheap GET for the marker:
#
#   GET  https://book.beatthatflight.com.au/            window.TPWL_EXTRA holds
#        the site's marker, white-label host and display currency. Read live so
#        a marker change on the site does not strand the skill; on any failure
#        the constants below (read from that same page on 2026-08-22) stand in.
#
#   POST https://api.apistp.com/whitelabels/web/flights/v1/search/sign
#        header Affiliate-Marker: <marker> (401 without it), body = the search
#        request; answers {"signature": "<32 hex>"}.
#
#   POST https://tickets-api.apistp.com/search/wl/start
#        the same body plus that signature (403 "access denied" without it);
#        answers search_id, results_url and polling_interval_ms.
#
#   POST https://<results_url>/search/wl/results
#        polled at polling_interval_ms until the response carries an
#        X-Stop-Marker header, which means the agent responses are all in.
#
# Then one GET per itinerary shown, for the booking deep link:
#
#   GET  https://<results_url>/searches/<search_id>/clicks/<proposal_id>
#        answers {"url": "<the agency's booking page>"}.
#
# Payload notes, all verified live:
#  - currency_code is mandatory. Sent empty or left out, start answers 400
#    {"type":"invalid-currency"}. So --currency omitted does not mean "no
#    currency preference sent"; it means the white-label's own configured
#    display currency (AUD, from TPWL_EXTRA), which is what the site answers a
#    visitor in.
#  - trip_class: Y, W, C, F. Anything else is 400 invalid-trip-class.
#  - directions: the API takes 1 to 6 (400 invalid-number-of-directions on 7);
#    the contract caps multi-city at 5, which is what this script enforces.
#  - is_origin_airport / is_destination_airport must match the code's kind. A
#    city code (LON, TBS) sent with the flag true returns an empty ticket list
#    over a non-zero total. The autocomplete endpoint classifies each code.
#  - adults 1-9, children 0-9, infants not more than adults.
#
# Result shape: the poll answers a JSON array; the object with
# chunk_id == "results" carries everything. tickets[].segments[] is one entry
# per direction, its flights[] are indices into the sibling flight_legs array;
# tickets[].proposals[] are the agencies selling that itinerary, each with its
# own price and its own marketing flight numbers in flight_terms, keyed by the
# same leg index. airlines, agents and equipments are sibling lookup maps, and
# meta.total_tickets_count is the size of the whole pool.

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date as date_cls, datetime

SOURCE = "beatthatflight.com.au"
CONFIG_URL = "https://book.beatthatflight.com.au/"
SIGN_URL = "https://api.apistp.com/whitelabels/web/flights/v1/search/sign"
START_URL = "https://tickets-api.apistp.com/search/wl/start"
AUTOCOMPLETE_URL = "https://autocomplete.apistp.com/places2"

# Fallbacks if the live page cannot be read; read from window.TPWL_EXTRA on
# https://book.beatthatflight.com.au/ on 2026-08-22.
FALLBACK_MARKER = "171356"
FALLBACK_HOST = "book.beatthatflight.com.au"
FALLBACK_CURRENCY = "AUD"

CABINS = {"ECONOMY": "Y", "PREMIUM_ECONOMY": "W", "BUSINESS": "C", "FIRST": "F"}
MIN_LEGS = 2
MAX_LEGS = 5
MAX_ADULTS = 9
MAX_CHILDREN = 9
POOL_LIMIT = 200        # the poll's own page cap
MAX_POLLS = 40

EXIT_VALIDATION = 2
EXIT_REJECTED = 3
EXIT_TRANSPORT = 4
EXIT_PAYLOAD = 5


def die(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)


# ------------------------------------------------------------------ http ---

def http(url, payload=None, headers=None, timeout=90):
    """Returns (status, headers dict, body bytes). Transport errors exit 4."""
    hdrs = {"Accept": "application/json",
            "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) magazines/beatthatflight"}
    if payload is not None:
        hdrs["Content-Type"] = "application/json"
    hdrs.update(headers or {})
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=hdrs,
                                 method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()
    except (urllib.error.URLError, OSError) as e:
        die(EXIT_TRANSPORT, "transport failure: %s: %s" % (url, e))


def as_json(url, status, raw):
    try:
        return json.loads(raw)
    except ValueError:
        die(EXIT_PAYLOAD, "unexpected payload: %s answered HTTP %d with %d bytes that are not JSON"
            % (url, status, len(raw)))


def reject(url, status, raw):
    """The API's own refusal: {"type": ..., "message": ...}."""
    try:
        doc = json.loads(raw)
        detail = "%s: %s" % (doc.get("type"), doc.get("message"))
    except (ValueError, AttributeError):
        detail = raw[:200].decode("utf-8", "replace")
    if status in (401, 403):
        die(EXIT_REJECTED, "request rejected: HTTP %d from %s, %s" % (status, url, detail))
    if status >= 500:
        die(EXIT_TRANSPORT, "transport failure: HTTP %d from %s, %s" % (status, url, detail))
    die(EXIT_REJECTED, "request rejected: HTTP %d, %s" % (status, detail))


# --------------------------------------------------------------- site cfg ---

def site_config():
    """marker, white-label host and display currency from the live page."""
    cfg = {"marker": FALLBACK_MARKER, "host": FALLBACK_HOST,
           "currency": FALLBACK_CURRENCY, "live": False}
    try:
        req = urllib.request.Request(
            CONFIG_URL, headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64)"})
        with urllib.request.urlopen(req, timeout=30) as r:
            html = r.read().decode("utf-8", "replace")
    except Exception:
        return cfg
    m = re.search(r"TPWL_EXTRA\s*=\s*\{(.*?)\}", html, re.S)
    if not m:
        return cfg
    block = m.group(1)
    found = {}
    for key, pat in (("marker", r'marker:\s*"([0-9]+)"'),
                     ("host", r'domain:\s*"([A-Za-z0-9.\-]+)"'),
                     ("currency", r'currency:\s*"([A-Za-z]{3})"')):
        hit = re.search(pat, block)
        if hit:
            found[key] = hit.group(1)
    if "marker" in found and "host" in found:
        cfg.update(found)
        cfg["currency"] = cfg["currency"].upper()
        cfg["live"] = True
    return cfg


# ------------------------------------------------------------ place kinds ---

def classify(code):
    """True if the code is an airport, False if a city, None if unknown."""
    url = "%s?%s" % (AUTOCOMPLETE_URL, urllib.parse.urlencode(
        [("types[]", "airport"), ("types[]", "city"), ("term", code), ("locale", "en")]))
    status, _, raw = http(url, timeout=30)
    if status != 200:
        reject(url, status, raw)
    doc = as_json(url, status, raw)
    if not isinstance(doc, list):
        die(EXIT_PAYLOAD, "unexpected payload: %s did not answer a list" % AUTOCOMPLETE_URL)
    kinds = {p.get("type") for p in doc
             if isinstance(p, dict) and (p.get("code") or "").upper() == code}
    if "airport" in kinds:
        return True
    if "city" in kinds:
        return False
    return None


def resolve_kinds(codes):
    uniq = sorted(set(codes))
    with ThreadPoolExecutor(max_workers=4) as pool:
        kinds = dict(zip(uniq, pool.map(classify, uniq)))
    for code, kind in kinds.items():
        if kind is None:
            die(EXIT_VALIDATION,
                "bad route: %s is not an airport or city code %s knows" % (code, SOURCE))
    return kinds


# ---------------------------------------------------------------- search ---

def run_search(bounds, kinds, args, cfg, currency):
    body = {
        "citizenship": "RU",
        "client_features": {"badges": True},
        "currency_code": currency,
        "host": cfg["host"],
        "languages": {"en": 1},
        "marker": cfg["marker"],
        "market_code": "AU",
        "search_params": {
            "directions": [{
                "origin": b["origin"],
                "destination": b["dest"],
                "date": b["date"],
                "is_origin_airport": kinds[b["origin"]],
                "is_destination_airport": kinds[b["dest"]],
            } for b in bounds],
            "passengers": {"adults": args.adults, "children": args.children,
                           "infants": args.infants},
            "trip_class": CABINS[args.cabin],
        },
    }

    status, _, raw = http(SIGN_URL, body, {"Affiliate-Marker": cfg["marker"]})
    if status != 200:
        reject(SIGN_URL, status, raw)
    signed = as_json(SIGN_URL, status, raw)
    signature = signed.get("signature") if isinstance(signed, dict) else None
    if not signature:
        die(EXIT_PAYLOAD, "unexpected payload: the sign call answered without a signature: %s"
            % json.dumps(signed)[:200])

    started_body = dict(body, signature=signature)
    status, _, raw = http(START_URL, started_body)
    if status != 200:
        reject(START_URL, status, raw)
    start = as_json(START_URL, status, raw)
    sid = start.get("search_id") if isinstance(start, dict) else None
    results_host = (start or {}).get("results_url")
    if not sid or not isinstance(results_host, str):
        die(EXIT_PAYLOAD, "unexpected payload: the start call answered without a search id "
                          "and results host: %s" % json.dumps(start)[:200])
    results_host = results_host.replace("https://", "").replace("http://", "").strip("/")

    interval = start.get("polling_interval_ms")
    interval = (interval / 1000.0) if isinstance(interval, (int, float)) and interval > 0 else 1.0
    poll_url = "https://%s/search/wl/results" % results_host
    poll_body = {"search_id": sid, "limit": POOL_LIMIT, "order": "cheapest",
                 "filters": {}, "search_by_airport": True, "required_tickets": []}

    chunk = None
    for attempt in range(MAX_POLLS):
        status, headers, raw = http(poll_url, poll_body)
        if status != 200:
            reject(poll_url, status, raw)
        doc = as_json(poll_url, status, raw)
        if not isinstance(doc, list):
            die(EXIT_PAYLOAD, "unexpected payload: the results poll answered %s, not a list"
                % type(doc).__name__)
        for part in doc:
            if isinstance(part, dict) and part.get("chunk_id") == "results":
                chunk = part
        if "x-stop-marker" in headers:
            break
        time.sleep(interval)
    else:
        die(EXIT_TRANSPORT, "transport failure: %s never finished the search (%d polls at %.1fs)"
            % (poll_url, MAX_POLLS, interval))
    if chunk is None:
        die(EXIT_PAYLOAD, "unexpected payload: the finished search carries no results chunk")
    return chunk, sid, results_host


def booking_urls(results_host, sid, proposal_ids):
    """One GET per itinerary shown. A failure leaves that link null."""
    def one(pid):
        url = "https://%s/searches/%s/clicks/%s" % (
            results_host, sid, urllib.parse.quote(pid, safe=""))
        try:
            req = urllib.request.Request(url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.loads(r.read()).get("url")
        except Exception:
            return None
    with ThreadPoolExecutor(max_workers=6) as pool:
        return list(pool.map(one, proposal_ids))


# ----------------------------------------------------------------- shape ---

def parse_local(s):
    try:
        return datetime.strptime(s, "%Y-%m-%d %H:%M")
    except (TypeError, ValueError):
        return None


def iso(s):
    d = parse_local(s)
    return d.isoformat() if d else None


def elapsed_minutes(first, last):
    a = first.get("departure_unix_timestamp")
    b = last.get("arrival_unix_timestamp")
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return int((b - a) // 60)
    return None


def carrier_name(airlines, code):
    entry = airlines.get(code) or {}
    return (((entry.get("name") or {}).get("en") or {}).get("default")) or code


def shape_ticket(ticket, chunk):
    legs_pool = chunk.get("flight_legs") or []
    airlines = chunk.get("airlines") or {}
    agents = chunk.get("agents") or {}

    proposals = [p for p in (ticket.get("proposals") or [])
                 if isinstance((p.get("price") or {}).get("value"), (int, float))]
    if not proposals:
        return None
    best = min(proposals, key=lambda p: p["price"]["value"])
    terms = best.get("flight_terms") or {}

    legs = []
    warnings = []
    for seg in ticket.get("segments") or []:
        idxs = [i for i in (seg.get("flights") or []) if 0 <= i < len(legs_pool)]
        if not idxs:
            continue
        segments = []
        for i in idxs:
            leg = legs_pool[i]
            term = terms.get(str(i)) or {}
            mk = term.get("marketing_carrier_designator") or {}
            op = leg.get("operating_carrier_designator") or {}
            code = mk.get("carrier") or op.get("carrier")
            number = mk.get("number") or op.get("number")
            operated = op.get("carrier")
            segments.append({
                "flight": "%s%s" % (code or "", number or ""),
                "carrier": code,
                "carrierName": carrier_name(airlines, code),
                "operatedBy": (carrier_name(airlines, operated)
                               if operated and operated != code else None),
                "origin": leg.get("origin"),
                "departure": iso(leg.get("local_departure_date_time")),
                "destination": leg.get("destination"),
                "arrival": iso(leg.get("local_arrival_date_time")),
                "durationMinutes": elapsed_minutes(leg, leg),
                "equipment": (leg.get("equipment") or {}).get("code"),
                "fareCode": term.get("fare_code"),
            })
        technical = sum(len(legs_pool[i].get("technical_stops") or []) for i in idxs)
        for t in seg.get("transfers") or []:
            if t.get("recheck_baggage"):
                warnings.append("baggage rechecked at a connection")
            for tag in t.get("tags") or []:
                if tag in ("night_transfer", "overnight_layover"):
                    warnings.append("overnight layover")
                elif tag == "third_country_transfer":
                    warnings.append("connection in a third country, check transit visa rules")
                elif tag == "airport_change":
                    warnings.append("airport change at a connection")
        legs.append({
            "origin": legs_pool[idxs[0]].get("origin"),
            "destination": legs_pool[idxs[-1]].get("destination"),
            "departure": iso(legs_pool[idxs[0]].get("local_departure_date_time")),
            "arrival": iso(legs_pool[idxs[-1]].get("local_arrival_date_time")),
            "durationMinutes": elapsed_minutes(legs_pool[idxs[0]], legs_pool[idxs[-1]]),
            "stops": len(idxs) - 1 + technical,
            "segments": segments,
        })
    if not legs:
        return None

    minimum = best.get("minimum_fare") or {}
    bag = minimum.get("baggage") or {}
    hand = minimum.get("handbags") or {}
    agent = agents.get(str(best.get("agent_id"))) or {}
    seller = (((agent.get("label") or {}).get("en") or {}).get("default")
              or agent.get("gate_name"))
    total = elapsed_minutes(legs_pool[(ticket["segments"][0]["flights"])[0]],
                            legs_pool[(ticket["segments"][-1]["flights"])[-1]])
    return {
        "price": {"amount": round(best["price"]["value"], 2),
                  "currency": (best["price"] or {}).get("currency_code")},
        "durationMinutes": total,
        "legs": legs,
        "seller": seller,
        "bookingUrl": None,          # filled in from the clicks endpoint
        "proposalId": best.get("id"),
        "pricePerPerson": round((best.get("price_per_person") or {}).get("value", 0), 2),
        "baggageIncluded": {"checked": bag.get("count"), "handbags": hand.get("count")},
        "transferWarnings": sorted(set(warnings)),
        "sellerCount": len(proposals),
    }


# ---------------------------------------------------------------- output ---

def fmt_duration(mins):
    if mins is None:
        return "?"
    d, rem = divmod(int(mins), 24 * 60)
    h, m = divmod(rem, 60)
    return ("%dd %02dh %02dm" % (d, h, m)) if d else ("%dh %02dm" % (h, m))


def clock(dt_iso, base_date):
    try:
        d = datetime.fromisoformat(dt_iso)
    except (TypeError, ValueError):
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


def route_words(bounds, trip):
    if trip == "multi-city":
        return ", ".join("%s → %s %s" % (b["origin"], b["dest"], b["date"]) for b in bounds)
    if trip == "return":
        return "%s → %s %s, back %s" % (bounds[0]["origin"], bounds[0]["dest"],
                                        bounds[0]["date"], bounds[1]["date"])
    return "%s → %s %s" % (bounds[0]["origin"], bounds[0]["dest"], bounds[0]["date"])


def render_text(itins, args, bounds, trip, total, currency):
    pax = ["%d adult%s" % (args.adults, "" if args.adults == 1 else "s")]
    if args.children:
        pax.append("%d child%s" % (args.children, "" if args.children == 1 else "ren"))
    if args.infants:
        pax.append("%d infant%s" % (args.infants, "" if args.infants == 1 else "s"))
    head = "%s, %s, %s; %s itineraries, showing %d, prices in %s" % (
        route_words(bounds, trip), ", ".join(pax), args.cabin,
        "unknown number of" if total is None else total, len(itins), currency)
    if not itins:
        return head + "\n\nNo itineraries"

    labels = leg_labels(trip, len(bounds))
    out = [head]
    for n, it in enumerate(itins, 1):
        out.append("")
        out.append("#%-3d %s %.2f   %s   %s   %s" % (
            n, it["price"]["currency"] or "", it["price"]["amount"],
            fmt_duration(it["durationMinutes"]),
            stops_word(sum(l["stops"] for l in it["legs"])),
            carriers_of(it["legs"])))
        for i, leg in enumerate(it["legs"]):
            base = bounds[i]["qdate"] if i < len(bounds) else bounds[-1]["qdate"]
            label = labels[i] if i < len(labels) else "leg %d" % (i + 1)
            indent = "    "
            if label:
                out.append("    %-6s %s   %s %s → %s %s   %s   %s" % (
                    label, bounds[i]["date"] if i < len(bounds) else "",
                    leg["origin"], clock(leg["departure"], base),
                    leg["destination"], clock(leg["arrival"], base),
                    fmt_duration(leg["durationMinutes"]), stops_word(leg["stops"])))
                indent = "        "
            for seg in leg["segments"]:
                line = "%s%-8s %s %s → %s %s   %s" % (
                    indent, seg["flight"], seg["origin"], clock(seg["departure"], base),
                    seg["destination"], clock(seg["arrival"], base),
                    fmt_duration(seg["durationMinutes"]))
                if seg["equipment"]:
                    line += "   %s" % seg["equipment"]
                if seg["operatedBy"]:
                    line += "   op %s" % seg["operatedBy"]
                out.append(line)
        bags = it["baggageIncluded"]
        out.append("    bags included: %s checked, %s hand" % (
            "0" if bags["checked"] is None else bags["checked"],
            "0" if bags["handbags"] is None else bags["handbags"]))
        for w in it["transferWarnings"]:
            out.append("    %s" % w)
        if it["seller"]:
            tail = "    via %s" % it["seller"]
            if it["sellerCount"] > 1:
                tail += " (cheapest of %d agencies)" % it["sellerCount"]
            out.append(tail)
        if it["bookingUrl"]:
            out.append("    (booking link in --json)")
    return "\n".join(out)


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
        description="beatthatflight.com.au flight search: one-way, return, or multi-city.",
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
    ap.add_argument("--no-booking-urls", dest="booking_urls", action="store_false",
                    help="skip the one deep-link lookup per itinerary shown (--json only)")
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
    if args.adults > MAX_ADULTS:
        die(EXIT_VALIDATION, "bad passenger count: at most %d adults, got %d"
            % (MAX_ADULTS, args.adults))
    if args.children > MAX_CHILDREN:
        die(EXIT_VALIDATION, "bad passenger count: at most %d children, got %d"
            % (MAX_CHILDREN, args.children))
    if args.infants > args.adults:
        die(EXIT_VALIDATION, "bad passenger count: infants (%d) exceed adults (%d)"
            % (args.infants, args.adults))
    if args.limit < 1:
        die(EXIT_VALIDATION, "bad arguments: --limit must be at least 1, got %d" % args.limit)


def main():
    args = parse_args()
    bounds, trip = parse_bounds(args)
    validate(args)

    cfg = site_config()
    currency = args.currency.upper() if args.currency else cfg["currency"]

    codes = []
    for b in bounds:
        codes += [b["origin"], b["dest"]]
    kinds = resolve_kinds(codes)

    chunk, sid, results_host = run_search(bounds, kinds, args, cfg, currency)

    total = (chunk.get("meta") or {}).get("total_tickets_count")
    itins = [shape_ticket(t, chunk) for t in (chunk.get("tickets") or []) if isinstance(t, dict)]
    itins = [it for it in itins if it]
    itins.sort(key=lambda it: it["price"]["amount"])
    itins = itins[:args.limit]

    # One clicks request per itinerary shown, and only the JSON answer
    # carries the link (1.5 KB of affiliate URL each), so text mode skips them.
    if itins and args.booking_urls and args.json:
        for it, url in zip(itins, booking_urls(results_host, sid,
                                               [it["proposalId"] for it in itins])):
            it["bookingUrl"] = url

    answered = next((it["price"]["currency"] for it in itins if it["price"]["currency"]), currency)

    if args.json:
        print(render_json(itins, args, bounds, trip, total, answered))
    else:
        print(render_text(itins, args, bounds, trip, total, answered))


if __name__ == "__main__":
    main()
