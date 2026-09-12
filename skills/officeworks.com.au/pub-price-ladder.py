#!/usr/bin/env python3
"""Officeworks Print + Create: the quantity-to-price ladder behind a product's price grid.

The grid on a /print-copy/p/ page is a React widget whose Redux slice starts at
priceTableFetchStatus "FETCHING" with priceTableData null, so a DOM dump carries
no price. The prices are not in the page at all: the widget composes SKUs from
the product configuration the page already ships, and asks one endpoint for each.

  https://www.officeworks.com.au/app/pcc-product/api/pricing

(rootUrl() in the page's client bundle = "/" + RESOURCE_NAMESPACE "app/pcc-product"
+ "/api".) It answers a bare GET with no cookie, no CSRF token, no Referer and no
User-Agent, and returns {"totalPrice": <cents>, "items": {<sku>: {"price": <cents>}},
"permutationPricingSku": ...}. A price it cannot resolve is 404 {"message": "Price
not found"}. So this script needs no browser: it reads window.__INITIAL_STATE__ off
the product page for the option tree, composes the SKUs itself, and prices them.

The composition rules, chosen by productConfiguration.pricingType:

  PERMUTATION (Flyers, PCDHFLCP)
      One genSku per whole configuration. It is productShortCode followed by the
      optionKey of every non-optional component that carries an optionKeyOrder,
      concatenated in optionKeyOrder order and nothing between them.
      Ladder axis: the Pack Size component. Price is per pack.

  ACCUMULATIVE (Document Prints, PCDHDPCP)
      No genSku. Each component option has its own SKU and they add up. The
      Printing component already holds one option per (size, siding, colour,
      quantity band), so the ladder is those options priced in one call.
      Price is per printed side, and the paper stock is charged per sheet on top.

Each rule is the page's own, read out of client.<hash>.bundle.js.

Usage:
    pub-price-ladder.py options --product flyers
    pub-price-ladder.py prices  --product flyers --size A5 --paper "120gsm Bond" --sided single
    pub-price-ladder.py prices  --product document-prints --size A4 --colour colour

Emits the canonical envelope on stdout and nothing else.
"""

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SITE = "https://www.officeworks.com.au"
PRICING = SITE + "/app/pcc-product/api/pricing"
UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36")

# The products this skill was built and verified against. Any other
# /print-copy/p/ slug may be passed through as --product and will work wherever
# its pricingType is one of the composition rules described in the module
# docstring above.
PRODUCTS = {
    "flyers": "/print-copy/p/flyers-pcdhflcp",
    "document-prints": "/print-copy/p/document-prints-pcdhdpcp",
}

# Component subTypes this script steers by. Everything else takes its default.
SIZE = "Finished Size"
SIDING = "Siding"
COLOUR = "Print Colour"
PRINTING = "Printing"
PACK_SIZE = "Pack Size"
PRICING_TIERS = "Pricing Tiers"
# Flyers calls its stock "Business Print Paper", Document Prints calls it "Paper".
PAPER_SUBTYPES = ("Paper", "Business Print Paper")


class Failed(Exception):
    pass


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=45) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")[:200]
        raise Failed("%s returned HTTP %s: %s" % (url.split("?")[0], e.code, body))
    except urllib.error.URLError as e:
        raise Failed("could not reach %s: %s" % (url.split("?")[0], e))


def product_url(product):
    p = PRODUCTS.get(product.lower(), product)
    if p.startswith("http"):
        return p
    return SITE + "/" + p.lstrip("/")


def fetch_configuration(product):
    """The productConfiguration the page server-renders: every component, every
    option, with the optionKeys and SKUs the pricing endpoint is keyed on."""
    html = get(product_url(product))
    m = re.search(r"window\.__INITIAL_STATE__\s*=\s*(\{.*?\});?\s*(?:window\.|</script>)",
                  html, re.S)
    if not m:
        raise Failed("no window.__INITIAL_STATE__ on %s (page shape changed)"
                     % product_url(product))
    state = json.loads(m.group(1))
    cfg = state.get("productReducer", {}).get("productConfiguration")
    if not cfg:
        raise Failed("page carried no productConfiguration; is %s a Print + Create product?"
                     % product)
    return cfg


def price_call(params):
    """One pricing call. Returns {"totalPrice": cents, "items": {sku: {"price": cents}}}."""
    url = PRICING + "?" + urllib.parse.urlencode(params)
    body = get(url)
    try:
        return json.loads(body)
    except ValueError:
        raise Failed("pricing endpoint returned non-JSON: %s" % body[:200])


def components_by_subtype(cfg, subtype):
    return [c for c in cfg["components"] if c["subType"] == subtype]


def one_component(cfg, subtype):
    got = components_by_subtype(cfg, subtype)
    return got[0] if got else None


def paper_component(cfg):
    for st in PAPER_SUBTYPES:
        c = one_component(cfg, st)
        if c:
            return c
    return None


def option_size(o):
    """The finished size of an option. The `size` field is the stable handle, but
    the DL flyer option leaves it null, so fall back to the leading token of the
    name ("DL (99 x 210mm)")."""
    return (o.get("size") or (o.get("name") or "").split(" ")[0] or "").upper()


def match_option(options, wanted, how, what):
    """Pick the one option the caller asked for, or explain the choices."""
    if wanted is None:
        for o in options:
            if o.get("isDefault"):
                return o
        return options[0]
    hits = [o for o in options if how(o, wanted)]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise Failed("no %s matching %r; the page offers: %s"
                     % (what, wanted, ", ".join(sorted({o["name"] for o in options}))))
    raise Failed("%r matches %d %s options (%s); be more specific"
                 % (wanted, len(hits), what, ", ".join(o["name"] for o in hits)))


def by_size(o, wanted):
    return option_size(o) == wanted.strip().upper()


def by_substring(o, wanted):
    return wanted.strip().lower() in (o.get("name") or "").lower()


def by_siding(o, wanted):
    w = wanted.strip().lower()
    w = {"1": "single", "2": "double", "single-sided": "single",
         "double-sided": "double"}.get(w, w)
    return (o.get("siding") or "").lower() == w


def by_colour(o, wanted):
    w = wanted.strip().lower().replace("color", "colour")
    c = (o.get("color") or "").lower()
    if w in ("bw", "b&w", "mono", "black and white", "black & white"):
        return c == "black & white"
    return c == w


def cents(n):
    return "%.2f" % (n / 100.0)


# --- PERMUTATION: one genSku per configuration, ladder over Pack Size ---------

def gensku_components(cfg):
    """Sorted by optionKeyOrder, the same string the page itself sorts by."""
    got = [c for c in cfg["components"]
           if not c.get("isOptional") and c.get("optionKeyOrder")]
    return sorted(got, key=lambda c: c["optionKeyOrder"])


def permutation_ladder(cfg, args):
    ordered = gensku_components(cfg)
    axis = one_component(cfg, PACK_SIZE) or one_component(cfg, PRICING_TIERS)
    if axis is None:
        raise Failed("product has no Pack Size or Pricing Tiers component to walk")

    chosen = {}
    for c in ordered:
        if c["id"] == axis["id"]:
            continue
        if c["subType"] == SIZE:
            chosen[c["id"]] = match_option(c["options"], args.size, by_size, "finished size")
        elif c["subType"] == SIDING:
            chosen[c["id"]] = match_option(c["options"], args.sided, by_siding, "siding")
        elif c["subType"] == COLOUR:
            chosen[c["id"]] = match_option(c["options"], args.colour, by_colour, "print colour")
        elif c["subType"] in PAPER_SUBTYPES:
            chosen[c["id"]] = match_option(c["options"], args.paper, by_substring, "paper")
        else:
            chosen[c["id"]] = match_option(c["options"], None, None, c["subType"])

    rows = []
    walking = dict(chosen)
    for opt in sorted(axis["options"], key=lambda o: int(o["quantity"]["min"])):
        walking[axis["id"]] = opt
        gen = cfg["productShortCode"] + "".join(
            walking[c["id"]]["optionKey"] for c in ordered)
        try:
            got = price_call({"pricingType": "PERMUTATION", "genSkus": gen})
        except Failed as e:
            rows.append({"quantity": int(opt["quantity"]["min"]), "gen_sku": gen,
                         "pack_price_cents": None, "unavailable": str(e)})
            continue
        total = got["totalPrice"]
        qty = int(opt["quantity"]["min"])
        rows.append({
            "quantity": qty,
            "pack_price_cents": total,
            "pack_price": cents(total),
            "unit_price_cents": round(total / qty),
            "gen_sku": gen,
        })
    return {"basis": "per_pack", "rows": rows}, chosen


# --- ACCUMULATIVE: per-option SKUs that add up, ladder over Printing bands ----

def accumulative_ladder(cfg, args):
    printing = one_component(cfg, PRINTING)
    if printing is None:
        raise Failed("product has no Printing component to read quantity bands from")
    size_c = one_component(cfg, SIZE)
    siding_c = one_component(cfg, SIDING)
    colour_c = one_component(cfg, COLOUR)

    chosen = {}
    size = match_option(size_c["options"], args.size, by_size, "finished size")
    chosen[size_c["id"]] = size
    siding = match_option(siding_c["options"], args.sided, by_siding, "siding") if siding_c else None
    if siding:
        chosen[siding_c["id"]] = siding
    colour = match_option(colour_c["options"], args.colour, by_colour, "print colour") if colour_c else None
    if colour:
        chosen[colour_c["id"]] = colour

    bands = [o for o in printing["options"]
             if option_size(o) == option_size(size)
             and (siding is None or o.get("siding") == siding.get("siding"))
             and (colour is None or o.get("color") == colour.get("color"))]
    if not bands:
        raise Failed("no Printing option for %s / %s / %s"
                     % (size["name"], siding and siding["name"], colour and colour["name"]))
    bands.sort(key=lambda o: int(o["quantity"]["min"]))

    got = price_call({"pricingType": "ACCUMULATIVE",
                      "skus": ",".join(o["sku"] for o in bands)})
    rows = []
    for i, o in enumerate(bands):
        lo, hi = int(o["quantity"]["min"]), int(o["quantity"]["max"])
        label = "%d +" % lo if i == len(bands) - 1 else "%d - %d" % (lo, hi)
        p = got["items"].get(o["sku"], {}).get("price")
        rows.append({
            "quantity_band": label, "min": lo, "max": None if i == len(bands) - 1 else hi,
            "price_per_side_cents": p,
            "price_per_side": cents(p) if p is not None else None,
            "sku": o["sku"],
        })
    return {"basis": "per_side", "rows": rows}, chosen


def paper_line(cfg, args, chosen):
    """On an ACCUMULATIVE product the stock is a separate per-sheet charge; the
    default stock carries no SKU, which is the page's way of saying it is included."""
    comp = paper_component(cfg)
    if comp is None:
        return None
    size = None
    size_c = one_component(cfg, SIZE)
    if size_c and size_c["id"] in chosen:
        size = option_size(chosen[size_c["id"]])
    pool = [o for o in comp["options"] if size is None or option_size(o) == size]
    if not pool:
        pool = comp["options"]
    opt = match_option(pool, args.paper, by_substring, "paper")
    if not opt.get("sku"):
        return {"name": opt["name"], "sku": None, "price_per_sheet_cents": 0,
                "included_in_print_price": True}
    got = price_call({"pricingType": "ACCUMULATIVE", "skus": opt["sku"]})
    p = got["items"].get(opt["sku"], {}).get("price")
    return {"name": opt["name"], "sku": opt["sku"], "price_per_sheet_cents": p,
            "price_per_sheet": cents(p) if p is not None else None,
            "included_in_print_price": False}


# --- reporting ---------------------------------------------------------------

def envelope_ok(result):
    # No identity key: officeworks.com.au declares no identity source for the
    # signed-out pages this skill reads (SESSION-CONTRACT.md §4).
    return json.dumps({"result": result, "cursor": None, "hasMore": False,
                       "fault": None}, indent=1)


def envelope_fault(detail):
    return json.dumps({"result": None, "cursor": None, "hasMore": False,
                       "fault": {"shape": "unrecognised", "detail": str(detail)[:200]}},
                      indent=1)


def do_options(cfg, args):
    out = []
    for c in cfg["components"]:
        names = []
        for o in c["options"]:
            names.append({"name": o["name"], "optionKey": o.get("optionKey"),
                          "sku": o.get("sku"), "size": o.get("size"),
                          "siding": o.get("siding"), "colour": o.get("color"),
                          "quantity": o.get("quantity"), "isDefault": o.get("isDefault")})
        out.append({"component": c["name"], "subType": c["subType"],
                    "optional": c.get("isOptional"),
                    "optionKeyOrder": c.get("optionKeyOrder"), "options": names})
    return {"product": product_head(cfg, args), "components": out}


def product_head(cfg, args):
    return {"sku": cfg["baseSku"], "name": cfg["displayName"],
            "url": product_url(args.product), "pricing_type": cfg["pricingType"],
            "from_price": cfg.get("fromPrice"),
            "delivery_to_door": cfg.get("deliveryToDoor"),
            "click_and_collect": cfg.get("clickAndCollect")}


def do_prices(cfg, args):
    if cfg["pricingType"] == "PERMUTATION":
        ladder, chosen = permutation_ladder(cfg, args)
        paper = None
    elif cfg["pricingType"] == "ACCUMULATIVE":
        ladder, chosen = accumulative_ladder(cfg, args)
        paper = paper_line(cfg, args, chosen)
    else:
        raise Failed("pricingType %r is not one this skill composes SKUs for; run "
                     "`options` and read the component tree" % cfg["pricingType"])

    selection = {}
    for c in cfg["components"]:
        if c["id"] in chosen:
            selection[c["name"]] = chosen[c["id"]]["name"]
    result = {"product": product_head(cfg, args), "selection": selection,
              "currency": "AUD", "gst": "inclusive", "ladder": ladder}
    if paper is not None:
        result["paper"] = paper
    return result


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=["options", "prices"])
    ap.add_argument("--product", required=True,
                    help="flyers, document-prints, or a /print-copy/p/<slug> path")
    ap.add_argument("--size", help="finished size: A3, A4, A5, A6, DL (as the product offers)")
    ap.add_argument("--paper", help="paper stock, a substring of its name, e.g. '120gsm Bond'")
    ap.add_argument("--sided", help="single or double")
    ap.add_argument("--colour", help="colour or black & white (where the product offers both)")
    args = ap.parse_args()
    try:
        cfg = fetch_configuration(args.product)
        result = do_options(cfg, args) if args.action == "options" else do_prices(cfg, args)
    except Failed as e:
        print(envelope_fault(e))
        return 65
    print(envelope_ok(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
