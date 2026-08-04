#!/usr/bin/env python3
# Xiamen Airlines (MF) one-way fare search against the tRetail API the
# airline's own booking site calls. Two requests per search:
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
# The GET body cross-references flightSegments by id from two paths:
#   flightOptions[].flightBounds[].boundSegmentIds[].id -> flightSegments[].id
#   flightOptions[].prices[].fareInfos[].flightSegmentId -> flightSegments[].id
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
        with urllib.request.urlopen(req, timeout=60) as r:
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


def timestr(dt_iso, qdate):
    # "2026-08-25T18:55:00" -> "18:55", or "18:55 (+1)" past the queried date.
    try:
        d = datetime.strptime(dt_iso, "%Y-%m-%dT%H:%M:%S")
    except (TypeError, ValueError):
        return dt_iso or "?"
    off = (d.date() - qdate).days
    t = d.strftime("%H:%M")
    return "%s (+%d)" % (t, off) if off > 0 else t


def fmt_duration(d):
    # "9:30" or "05:05" -> "9h30m" / "5h05m"
    if not d or ":" not in d:
        return ""
    h, m = d.split(":", 1)
    try:
        return "%dh%02dm" % (int(h), int(m))
    except ValueError:
        return d


def option_segments(opt, segments_by_id):
    segs = []
    for bound in opt.get("flightBounds") or []:
        for ref in bound.get("boundSegmentIds") or []:
            seg = segments_by_id.get(ref.get("id"))
            if seg:
                segs.append(seg)
    return segs


def seg_flight(seg):
    mk = seg.get("marketingAirlineInfo") or {}
    op = seg.get("operatingAirlineInfo") or {}
    flight = "%s%s" % (mk.get("airlineCode", ""), mk.get("flightNumber", ""))
    operated = "%s%s" % (op.get("airlineCode", ""), op.get("flightNumber", ""))
    return flight, (operated if operated and operated != flight else None)


def stops_of(segs):
    return sum(s.get("numberOfStops") or 0 for s in segs) + max(len(segs) - 1, 0)


def fare_label(price):
    if price.get("fareFamilyCode"):
        return price["fareFamilyCode"]
    for fi in price.get("fareInfos") or []:
        if fi.get("fareFamilyCode"):
            return fi["fareFamilyCode"]
    return None


def uniq(seq):
    out = []
    for x in seq:
        if x and x not in out:
            out.append(x)
    return out


def fare_booking_summary(price):
    fis = price.get("fareInfos") or []
    cabins = "/".join(uniq(fi.get("cabinClass") for fi in fis))
    rbds = "/".join(uniq(fi.get("rbd") for fi in fis))
    seat_counts = []
    for fi in fis:
        try:
            seat_counts.append(int(fi.get("rbdQuantity")))
        except (TypeError, ValueError):
            pass
    seats = str(min(seat_counts)) if seat_counts else ""
    return cabins, rbds, seats


def sorted_prices(opt):
    return sorted(opt.get("prices") or [],
                  key=lambda p: (p.get("total") or {}).get("amount") or 0)


def render_text(doc, args, qdate):
    options = doc.get("flightOptions") or []
    head = ("Xiamen Airlines %s → %s %s, one-way, adults %d children %d infants %d, "
            "cabin %s, POS %s/%s (totals in %s cover the whole party)"
            % (args.origin, args.dest, args.date, args.adults, args.children,
               args.infants, args.cabin, args.pos_locale, args.pos_country,
               args.pos_currency))
    if not options:
        return "%s\n\nNo itineraries for %s → %s on %s." % (head, args.origin, args.dest, args.date)

    segments_by_id = {s.get("id"): s for s in doc.get("flightSegments") or []}
    out = [head]
    for n, opt in enumerate(options, 1):
        segs = option_segments(opt, segments_by_id)
        if not segs:
            continue
        dep = segs[0].get("departure") or {}
        arr = segs[-1].get("arrival") or {}
        stops = stops_of(segs)
        stopstr = "nonstop" if stops == 0 else ("1 stop" if stops == 1 else "%d stops" % stops)
        dur = fmt_duration(segs[0].get("duration")) if len(segs) == 1 else ""
        header = "%d) %s %s → %s %s" % (n, dep.get("iataCode", ""), timestr(dep.get("dateTime"), qdate),
                                        arr.get("iataCode", ""), timestr(arr.get("dateTime"), qdate))
        header += "   %s%s" % (dur + ", " if dur else "", stopstr)
        out.append("")
        out.append(header)
        for seg in segs:
            flight, operated = seg_flight(seg)
            sd = seg.get("departure") or {}
            sa = seg.get("arrival") or {}
            line = "   %s%s %s %s → %s %s" % (
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
        for price in prices:
            total = price.get("total") or {}
            cash = (price.get("details") or {}).get("cash") or {}
            base = cash.get("base") or {}
            tax = cash.get("taxTotal") or {}
            cabins, rbds, seats = fare_booking_summary(price)
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
                fare_label(price) or "—",
                total.get("currencyCode", ""), total.get("amount") or 0,
                "   (%s)" % ", ".join(details) if details else ""))
    return "\n".join(out)


def money(m):
    m = m or {}
    return {"amount": m.get("amount"), "currency": m.get("currencyCode")}


def render_json(doc, args):
    segments_by_id = {s.get("id"): s for s in doc.get("flightSegments") or []}
    itins = []
    for opt in doc.get("flightOptions") or []:
        segs = option_segments(opt, segments_by_id)
        if not segs:
            continue
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
        fares = []
        for price in sorted_prices(opt):
            cash = (price.get("details") or {}).get("cash") or {}
            fares.append({
                "fareFamily": fare_label(price),
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
            "departure": (segs[0].get("departure") or {}).get("dateTime"),
            "arrival": (segs[-1].get("arrival") or {}).get("dateTime"),
            "stops": stops_of(segs),
            "priced": bool(opt.get("prices")),
            "segments": seg_out,
            "fares": fares,
        })
    return json.dumps({
        "origin": args.origin,
        "destination": args.dest,
        "date": args.date,
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
        description="Xiamen Airlines one-way fare search.",
        usage="%(prog)s <origin> <dest> <date YYYY-MM-DD> [--adults N] [--children N] "
              "[--infants N] [--cabin ECONOMY|BUSINESS|FIRST|ANY] [--pos en-AU:AU:AUD] [--json]")
    ap.add_argument("origin")
    ap.add_argument("dest")
    ap.add_argument("date")
    ap.add_argument("--adults", type=int, default=1)
    ap.add_argument("--children", type=int, default=0)
    ap.add_argument("--infants", type=int, default=0)
    ap.add_argument("--cabin", default="ECONOMY", type=str.upper, choices=CABINS)
    ap.add_argument("--pos", default="en-AU:AU:AUD",
                    help="point of sale as locale:country:currency (default en-AU:AU:AUD)")
    ap.add_argument("--json", action="store_true")
    return ap.parse_args()


def main():
    args = parse_args()
    args.origin = args.origin.upper()
    args.dest = args.dest.upper()

    if not re.fullmatch(r"[A-Z]{3}", args.origin) or not re.fullmatch(r"[A-Z]{3}", args.dest):
        die(EXIT_VALIDATION, "bad route: origin and destination must be 3-letter IATA codes")
    if args.origin == args.dest:
        die(EXIT_VALIDATION, "bad route: origin and destination are both %s" % args.origin)
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
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        die(EXIT_VALIDATION, "bad date: expected YYYY-MM-DD, got %s" % args.date)
    try:
        qdate = datetime.strptime(args.date, "%Y-%m-%d").date()
    except ValueError:
        die(EXIT_VALIDATION, "bad date: %s is not a calendar date" % args.date)
    if qdate < date_cls.today():
        die(EXIT_VALIDATION, "bad date: %s is in the past" % args.date)
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
            "departureDate": args.date,
            "origin": {"code": args.origin, "context": "IATA"},
            "destination": {"code": args.dest, "context": "IATA"},
        }],
    }

    created = api_request("POST", "/flight/resultSets", headers, body)
    rsid = created.get("id") if isinstance(created, dict) else None
    if not rsid:
        die(EXIT_PAYLOAD, "unexpected payload: POST /flight/resultSets answered without an id: %s"
            % json.dumps(created)[:200])
    doc = api_request("GET", "/flight/resultSets/%s" % rsid, headers)
    if not isinstance(doc, dict) or ("flightOptions" not in doc and doc.get("totalResults") not in (0, None)):
        die(EXIT_PAYLOAD, "unexpected payload: result set %s carries no flightOptions" % rsid)

    if args.json:
        print(render_json(doc, args))
    else:
        print(render_text(doc, args, qdate))


if __name__ == "__main__":
    main()
