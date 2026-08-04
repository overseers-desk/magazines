#!/usr/bin/env python3
# Xiamen Airlines (MF) fare search against the tRetail API the airline's own
# booking site calls. Two requests per search:
#
#   POST /flight/resultSets          submit the search; answer carries {"id"}
#   GET  /flight/resultSets/{id}     fetch the fares for that result set
#
# Both calls carry two headers or the API answers 400 with an apiErrors body:
#   Accept-Language:     a supported point-of-sale locale, exact case
#                        (en-AU works; en-au and en-US do not)
#   Market-Country-Code: that locale's country (AU). Left out, the API blames
#                        the locale ("Unsupported Locale") instead.
# The currencyCode in the request body has to match the same point of sale.
#
# The POST body's bounds array sets the trip shape: one element is a one-way,
# two a return or two-leg multi-city, up to the API's cap of five
# (OJ-01-0624 on a sixth). A search with no results answers totalResults 0 on
# the POST itself and the GET then 404s (OJ-04-0036, "Result set ID does not
# exist or has expired"), so the empty case is decided from the POST answer.
#
# The GET body cross-references flightSegments by id from two paths:
#   flightOptions[].flightBounds[].boundSegmentIds[].id -> flightSegments[].id
#   flightOptions[].prices[].fareInfos[].flightSegmentId -> flightSegments[].id
# flightBounds arrive in the order the bounds were submitted. Each price is
# one fare for the whole journey, all bounds together; its fareInfos carry the
# per-segment booking class, cabin and seat count across every bound.
# A flightOption can arrive without a prices array (seen live: an itinerary
# the point of sale does not price); it is listed without fare lines.

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import date as date_cls, datetime

BASE = "https://int-et.xiamenair.com/tRetailAPISolution"
CABINS = ("ECONOMY", "BUSINESS", "FIRST", "ANY")
MAX_BOUNDS = 5

# Error codes the API returns for a locale/market/currency combination it
# does not sell under (observed live: zh-CN/CN/CNY -> OJ-04-0090; a missing
# Market-Country-Code -> COMMON-04-0004).
POS_ERROR_CODES = {"OJ-04-0090", "COMMON-04-0004"}

EXIT_VALIDATION = 2
EXIT_REJECTED = 3
EXIT_TRANSPORT = 4
EXIT_PAYLOAD = 5


def die(code, msg):
    print(msg, file=sys.stderr)
    sys.exit(code)


def api_request(method, path, headers, payload=None):
    url = BASE + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        errs = None
        try:
            errs = json.loads(raw).get("apiErrors")
        except (ValueError, AttributeError):
            pass
        if errs:
            msgs = "; ".join(
                "%s: %s" % (x.get("errorCode"), x.get("userMessage") or x.get("devMessage"))
                for x in errs)
            if any(x.get("errorCode") in POS_ERROR_CODES for x in errs):
                die(EXIT_REJECTED, "unsupported point of sale: %s" % msgs)
            die(EXIT_REJECTED, "request rejected: HTTP %d, %s" % (e.code, msgs))
        die(EXIT_TRANSPORT, "transport failure: HTTP %d from %s: %s"
            % (e.code, url, raw[:200].decode("utf-8", "replace")))
    except (urllib.error.URLError, OSError) as e:
        die(EXIT_TRANSPORT, "transport failure: %s: %s" % (url, e))
    try:
        return json.loads(raw)
    except ValueError:
        die(EXIT_PAYLOAD, "unexpected payload: %s returned %d bytes that do not parse as JSON"
            % (url, len(raw)))


def parse_dt(dt_iso):
    try:
        return datetime.strptime(dt_iso, "%Y-%m-%dT%H:%M:%S")
    except (TypeError, ValueError):
        return None


def timestr(dt_iso, qdate):
    # "2026-08-25T18:55:00" -> "18:55", or "18:55 (+1)" past the leg's date.
    d = parse_dt(dt_iso)
    if d is None:
        return dt_iso or "?"
    off = (d.date() - qdate).days
    t = d.strftime("%H:%M")
    return "%s (+%d)" % (t, off) if off > 0 else t


def option_bound_segments(opt, segments_by_id):
    # One segment list per bound, in the order the bounds were submitted.
    per_bound = []
    for bound in opt.get("flightBounds") or []:
        segs = []
        for ref in bound.get("boundSegmentIds") or []:
            seg = segments_by_id.get(ref.get("id"))
            if seg:
                segs.append(seg)
        if segs:
            per_bound.append(segs)
    return per_bound


def seg_flight(seg):
    mk = seg.get("marketingAirlineInfo") or {}
    op = seg.get("operatingAirlineInfo") or {}
    flight = "%s%s" % (mk.get("airlineCode", ""), mk.get("flightNumber", ""))
    operated = "%s%s" % (op.get("airlineCode", ""), op.get("flightNumber", ""))
    return flight, (operated if operated and operated != flight else None)


def stops_of(segs):
    # Technical (same-flight) stops summed across every segment, plus one per
    # connection between segments: one number covering both kinds.
    return sum(s.get("numberOfStops") or 0 for s in segs) + max(len(segs) - 1, 0)


def duration_minutes(segs):
    """Total elapsed minutes: flying time plus the layovers between segments.

    The payload's dateTime values are local and carry no offset, so a plain
    first-to-last subtraction is wrong whenever an itinerary crosses zones.
    Each layover is a difference at one airport, hence real time, and each
    segment carries its own flying time, so the sum is right.
    """
    total = 0
    for seg in segs:
        d = seg.get("duration") or ""
        if ":" not in d:
            return None
        try:
            h, m = d.split(":", 1)
            total += int(h) * 60 + int(m)
        except ValueError:
            return None
    for prev, nxt in zip(segs, segs[1:]):
        arr = parse_dt((prev.get("arrival") or {}).get("dateTime"))
        dep = parse_dt((nxt.get("departure") or {}).get("dateTime"))
        if arr is None or dep is None:
            return None
        total += int((dep - arr).total_seconds() // 60)
    return total


def fmt_minutes(mins):
    if mins is None:
        return ""
    return "%dh%02dm" % (mins // 60, mins % 60)


def uniq(seq):
    out = []
    for x in seq:
        if x and x not in out:
            out.append(x)
    return out


def per_bound_join(values_by_bound):
    # ["R", "L"] -> "R | L"; identical bounds collapse to one; one bound
    # passes through, matching the one-way output.
    parts = [v for v in values_by_bound if v]
    if not parts:
        return ""
    return parts[0] if len(set(parts)) == 1 else " | ".join(parts)


def fare_infos_by_bound(price, seg_to_bound, nbounds):
    grouped = [[] for _ in range(nbounds)]
    for fi in price.get("fareInfos") or []:
        grouped[seg_to_bound.get(fi.get("flightSegmentId"), 0)].append(fi)
    return grouped


def fare_label(price, seg_to_bound, nbounds):
    if price.get("fareFamilyCode"):
        return price["fareFamilyCode"]
    grouped = fare_infos_by_bound(price, seg_to_bound, nbounds)
    per_bound = ["/".join(uniq(fi.get("fareFamilyCode") for fi in fis)) for fis in grouped]
    return per_bound_join(per_bound) or None


def fare_booking_summary(price, seg_to_bound, nbounds):
    grouped = fare_infos_by_bound(price, seg_to_bound, nbounds)
    cabins = per_bound_join(
        ["/".join(uniq(fi.get("cabinClass") for fi in fis)) for fis in grouped])
    rbds = per_bound_join(
        ["/".join(uniq(fi.get("rbd") for fi in fis)) for fis in grouped])
    seat_counts = []
    for fi in price.get("fareInfos") or []:
        try:
            seat_counts.append(int(fi.get("rbdQuantity")))
        except (TypeError, ValueError):
            pass
    seats = str(min(seat_counts)) if seat_counts else ""
    return cabins, rbds, seats


def sorted_prices(opt):
    return sorted(opt.get("prices") or [],
                  key=lambda p: (p.get("total") or {}).get("amount") or 0)


def seg_bound_map(per_bound_segs):
    return {seg.get("id"): bi
            for bi, segs in enumerate(per_bound_segs) for seg in segs}


def trip_desc(bounds, trip):
    if trip == "one-way":
        b = bounds[0]
        return "%s → %s %s, one-way" % (b["origin"], b["dest"], b["date"])
    if trip == "return":
        return "%s → %s, return out %s back %s" % (
            bounds[0]["origin"], bounds[0]["dest"], bounds[0]["date"], bounds[1]["date"])
    return "multi-city " + ", ".join(
        "%s→%s %s" % (b["origin"], b["dest"], b["date"]) for b in bounds)


def leg_labels(bounds, trip):
    if trip == "return":
        return ["out", "back"]
    return ["leg %d" % (i + 1) for i in range(len(bounds))]


def render_text(doc, args, bounds, trip):
    options = doc.get("flightOptions") or []
    head = ("Xiamen Airlines %s, adults %d children %d infants %d, "
            "cabin %s, POS %s/%s (totals in %s cover the whole party)"
            % (trip_desc(bounds, trip), args.adults, args.children,
               args.infants, args.cabin, args.pos_locale, args.pos_country,
               args.pos_currency))
    if not options:
        return "%s\n\nNo itineraries for %s." % (head, trip_desc(bounds, trip))

    segments_by_id = {s.get("id"): s for s in doc.get("flightSegments") or []}
    labels = leg_labels(bounds, trip)
    lw = max(len(x) for x in labels)
    multi = len(bounds) > 1
    out = [head]
    for n, opt in enumerate(options, 1):
        per_bound = option_bound_segments(opt, segments_by_id)
        if not per_bound:
            continue
        out.append("")
        for bi, segs in enumerate(per_bound):
            qdate = bounds[bi]["qdate"] if bi < len(bounds) else bounds[-1]["qdate"]
            dep = segs[0].get("departure") or {}
            arr = segs[-1].get("arrival") or {}
            stops = stops_of(segs)
            stopstr = "nonstop" if stops == 0 else ("1 stop" if stops == 1 else "%d stops" % stops)
            dur = fmt_minutes(duration_minutes(segs))
            route = "%s %s → %s %s" % (dep.get("iataCode", ""), timestr(dep.get("dateTime"), qdate),
                                       arr.get("iataCode", ""), timestr(arr.get("dateTime"), qdate))
            if multi:
                label = labels[bi] if bi < len(labels) else "leg %d" % (bi + 1)
                prefix = "%d) " % n if bi == 0 else "   "
                header = "%s%-*s %s  %s" % (prefix, lw, label, qdate.isoformat(), route)
            else:
                header = "%d) %s" % (n, route)
            header += "   %s%s" % (dur + ", " if dur else "", stopstr)
            out.append(header)
            for seg in segs:
                flight, operated = seg_flight(seg)
                sd = seg.get("departure") or {}
                sa = seg.get("arrival") or {}
                line = "   %s%s%s %s %s → %s %s" % (
                    "   " if multi else "",
                    flight, " (op %s)" % operated if operated else "",
                    sd.get("iataCode", ""), timestr(sd.get("dateTime"), qdate),
                    sa.get("iataCode", ""), timestr(sa.get("dateTime"), qdate))
                extras = []
                if seg.get("equipmentType"):
                    extras.append(seg["equipmentType"])
                sn = seg.get("numberOfStops") or 0
                if sn:
                    extras.append("%d stop%s en route" % (sn, "" if sn == 1 else "s"))
                if extras:
                    line += "   " + ", ".join(extras)
                out.append(line)
        prices = sorted_prices(opt)
        if not prices:
            out.append("   (no fares returned for this itinerary at this point of sale)")
            continue
        seg_to_bound = seg_bound_map(per_bound)
        for price in prices:
            total = price.get("total") or {}
            cash = (price.get("details") or {}).get("cash") or {}
            base = cash.get("base") or {}
            tax = cash.get("taxTotal") or {}
            cabins, rbds, seats = fare_booking_summary(price, seg_to_bound, len(per_bound))
            details = []
            if base.get("amount") is not None and tax.get("amount") is not None:
                details.append("base %.2f + tax %.2f" % (base["amount"], tax["amount"]))
            if cabins:
                details.append("cabin %s" % cabins)
            if rbds:
                details.append("rbd %s" % rbds)
            if seats:
                details.append("%s seats" % seats)
            out.append("   %-18s %s %.2f%s" % (
                fare_label(price, seg_to_bound, len(per_bound)) or "—",
                total.get("currencyCode", ""), total.get("amount") or 0,
                "   (%s)" % ", ".join(details) if details else ""))
    return "\n".join(out)


def money(m):
    m = m or {}
    return {"amount": m.get("amount"), "currency": m.get("currencyCode")}


def render_json(doc, args, bounds, trip):
    segments_by_id = {s.get("id"): s for s in doc.get("flightSegments") or []}
    itins = []
    for opt in doc.get("flightOptions") or []:
        per_bound = option_bound_segments(opt, segments_by_id)
        if not per_bound:
            continue
        legs = []
        for segs in per_bound:
            seg_out = []
            for seg in segs:
                flight, operated = seg_flight(seg)
                sd = seg.get("departure") or {}
                sa = seg.get("arrival") or {}
                seg_out.append({
                    "segmentId": seg.get("id"),
                    "flight": flight,
                    "operatedBy": operated,
                    "origin": sd.get("iataCode"),
                    "originTerminal": sd.get("terminal") or None,
                    "departure": sd.get("dateTime"),
                    "destination": sa.get("iataCode"),
                    "destinationTerminal": sa.get("terminal") or None,
                    "arrival": sa.get("dateTime"),
                    "duration": seg.get("duration") or None,
                    "equipment": seg.get("equipmentType"),
                    "stopsEnRoute": seg.get("numberOfStops") or 0,
                })
            legs.append({
                "origin": (segs[0].get("departure") or {}).get("iataCode"),
                "destination": (segs[-1].get("arrival") or {}).get("iataCode"),
                "departure": (segs[0].get("departure") or {}).get("dateTime"),
                "arrival": (segs[-1].get("arrival") or {}).get("dateTime"),
                "durationMinutes": duration_minutes(segs),
                "stops": stops_of(segs),
                "segments": seg_out,
            })
        seg_to_bound = seg_bound_map(per_bound)
        fares = []
        for price in sorted_prices(opt):
            cash = (price.get("details") or {}).get("cash") or {}
            fares.append({
                "fareFamily": fare_label(price, seg_to_bound, len(per_bound)),
                "total": money(price.get("total")),
                "base": money(cash.get("base")),
                "taxTotal": money(cash.get("taxTotal")),
                "bookingInfos": [{
                    "segmentId": fi.get("flightSegmentId"),
                    "cabinClass": fi.get("cabinClass"),
                    "rbd": fi.get("rbd"),
                    "seats": fi.get("rbdQuantity"),
                } for fi in price.get("fareInfos") or []],
                "perPassenger": [{
                    "type": fb.get("passengerType"),
                    "quantity": fb.get("quantity"),
                    "total": money(fb.get("total")),
                    "base": money(fb.get("base")),
                    "taxTotal": money(fb.get("taxTotal")),
                } for fb in price.get("fareBreakdowns") or []],
            })
        itins.append({
            "priced": bool(opt.get("prices")),
            "legs": legs,
            "fares": fares,
        })
    return json.dumps({
        "tripType": trip,
        "bounds": [{"origin": b["origin"], "destination": b["dest"], "date": b["date"]}
                   for b in bounds],
        "passengers": {"adults": args.adults, "children": args.children,
                       "infants": args.infants},
        "cabinClassRequested": args.cabin,
        "pointOfSale": {"locale": args.pos_locale, "marketCountry": args.pos_country,
                        "currency": args.pos_currency},
        "totalResults": doc.get("totalResults"),
        "itineraries": itins,
    }, indent=2, ensure_ascii=False)


def parse_args():
    ap = argparse.ArgumentParser(
        description="Xiamen Airlines fare search: one-way, return, or multi-city.",
        usage="%(prog)s <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] "
              "[--children N] [--infants N] [--cabin ECONOMY|BUSINESS|FIRST|ANY] "
              "[--pos en-AU:AU:AUD] [--json]\n"
              "       %(prog)s --leg DEP-ARR-YYYY-MM-DD --leg DEP-ARR-YYYY-MM-DD [--leg ... up to 5] "
              "[same options]")
    ap.add_argument("origin", nargs="?")
    ap.add_argument("dest", nargs="?")
    ap.add_argument("date", nargs="?")
    ap.add_argument("--return", dest="ret", metavar="YYYY-MM-DD",
                    help="date of the back leg; makes the search a return")
    ap.add_argument("--leg", dest="legs", action="append", metavar="DEP-ARR-YYYY-MM-DD",
                    help="one multi-city leg; repeat 2 to 5 times, replaces the positional route")
    ap.add_argument("--adults", type=int, default=1)
    ap.add_argument("--children", type=int, default=0)
    ap.add_argument("--infants", type=int, default=0)
    ap.add_argument("--cabin", default="ECONOMY", type=str.upper, choices=CABINS)
    ap.add_argument("--pos", default="en-AU:AU:AUD",
                    help="point of sale as locale:country:currency (default en-AU:AU:AUD)")
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
    # Each bound: origin, dest, date (string), qdate (date object).
    if args.legs:
        if args.origin or args.dest or args.date or args.ret:
            die(EXIT_VALIDATION,
                "bad arguments: --leg replaces the positional route and excludes --return")
        if not 2 <= len(args.legs) <= MAX_BOUNDS:
            die(EXIT_VALIDATION, "bad route: multi-city takes 2 to %d --leg segments, got %d"
                % (MAX_BOUNDS, len(args.legs)))
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
                die(EXIT_VALIDATION, "bad leg order: %s departs %s, before the prior leg's %s"
                    % (nxt["origin"], nxt["date"], prev["date"]))
        return bounds, "multi-city"

    if not (args.origin and args.dest and args.date):
        die(EXIT_VALIDATION,
            "bad route: give <origin> <dest> <date>, or 2 to %d --leg segments" % MAX_BOUNDS)
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


def main():
    args = parse_args()
    bounds, trip = parse_bounds(args)

    for name, v in (("adults", args.adults), ("children", args.children),
                    ("infants", args.infants)):
        if not 0 <= v <= 5:
            die(EXIT_VALIDATION, "bad passenger count: %s must be 0-5, got %d" % (name, v))
    if args.adults < 1:
        die(EXIT_VALIDATION, "bad passenger count: at least 1 adult")
    # The API caps a party at 5 (OJ-01-0629 on a larger one); catching it here
    # spares the caller a round trip.
    if args.adults + args.children + args.infants > 5:
        die(EXIT_VALIDATION, "bad passenger count: at most 5 passengers in total, got %d"
            % (args.adults + args.children + args.infants))
    if args.infants > args.adults:
        die(EXIT_VALIDATION, "bad passenger count: infants (%d) exceed adults (%d)"
            % (args.infants, args.adults))
    pos = args.pos.split(":")
    if (len(pos) != 3 or not re.fullmatch(r"[a-z]{2}-[A-Z]{2}", pos[0])
            or not re.fullmatch(r"[A-Z]{2}", pos[1])
            or not re.fullmatch(r"[A-Z]{3}", pos[2])):
        die(EXIT_VALIDATION, "bad point of sale: expected locale:country:currency "
            "with exact case (e.g. en-AU:AU:AUD), got %s" % args.pos)
    args.pos_locale, args.pos_country, args.pos_currency = pos

    headers = {
        "Accept-Language": args.pos_locale,
        "Market-Country-Code": args.pos_country,
        "Content-Type": "application/json",
    }
    pax = [{"count": args.adults, "passengerType": "ADT"}]
    if args.children:
        pax.append({"count": args.children, "passengerType": "CHD"})
    if args.infants:
        pax.append({"count": args.infants, "passengerType": "INF"})
    body = {
        "cabinClass": args.cabin,
        "currencyCode": args.pos_currency,
        "passengerCounts": pax,
        "bounds": [{
            "departureDate": b["date"],
            "origin": {"code": b["origin"], "context": "IATA"},
            "destination": {"code": b["dest"], "context": "IATA"},
        } for b in bounds],
    }

    created = api_request("POST", "/flight/resultSets", headers, body)
    rsid = created.get("id") if isinstance(created, dict) else None
    if not rsid:
        die(EXIT_PAYLOAD, "unexpected payload: POST /flight/resultSets answered without an id: %s"
            % json.dumps(created)[:200])
    if created.get("totalResults") == 0:
        # Fetching an empty result set 404s (OJ-04-0036); no flights is the
        # POST's own answer.
        doc = {"flightOptions": [], "totalResults": 0}
    else:
        doc = api_request("GET", "/flight/resultSets/%s" % rsid, headers)
        if not isinstance(doc, dict) or ("flightOptions" not in doc and doc.get("totalResults") not in (0, None)):
            die(EXIT_PAYLOAD, "unexpected payload: result set %s carries no flightOptions" % rsid)

    if args.json:
        print(render_json(doc, args, bounds, trip))
    else:
        print(render_text(doc, args, bounds, trip))


if __name__ == "__main__":
    main()
