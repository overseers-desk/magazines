---
name: officeworks.com.au
description: "Officeworks printing prices: flyer and document-print quantity ladders, per size, paper stock, siding and colour. The price grid renders empty to curl."
allowed-tools: Bash, Read
---

# Officeworks Print + Create pricing

Officeworks sells print as many products, each with its own price schedule, at `/print-copy/p/<slug>`. This skill reads the ladder a product's price grid shows, for a chosen size, paper stock, siding and colour. It was built and verified against **Flyers** (`flyers-pcdhflcp`) and **Document Prints** (`document-prints-pcdhdpcp`); any other Print + Create slug can be passed through and works where its `pricingType` is one of the composition rules below.

No login, no browser, no cookie.

## Why a plain page read does not work

The grid is a React widget. The page server-renders its Redux slice at `priceTableFetchStatus: "FETCHING"` with `priceTableData: null`, so a DOM dump carries no price, and the rendered table arrives later from a fetch.

But the prices are not in the page's HTML at any point either. The widget composes a SKU per row from the product configuration the page already ships, and asks one endpoint for each. That endpoint is reachable directly:

```
GET https://www.officeworks.com.au/app/pcc-product/api/pricing?<params>
```

(In the page's client bundle this is `rootUrl()` = `/` + `RESOURCE_NAMESPACE` `app/pcc-product` + `/api`, then `/pricing`.)

Verified 2026-09-12: it answers with **no User-Agent, no cookie, no CSRF token and no Referer**. Response `{"totalPrice": <cents>, "items": {"<sku>": {"price": <cents>}}, "permutationPricingSku": <sku|null>}`. A SKU it cannot resolve is HTTP 404 `{"message": "Price not found"}`.

The option tree comes from `window.__INITIAL_STATE__` on the product page (`productReducer.productConfiguration`), which plain curl returns at HTTP 200. The ladder is composed from that tree, so the page's own dropdowns are never driven.

## The composition rules

`productConfiguration.pricingType` picks which. Each was read out of the page's own `client.<hash>.bundle.js`.

**`PERMUTATION`** — Flyers. One `genSku` prices the whole configuration. It is `productShortCode` followed by the `optionKey` of every **non-optional** component that carries an `optionKeyOrder`, concatenated in `optionKeyOrder` order with nothing between them. Flyers is `FY` + Pack Size (`03`) + Finished Size (`09`) + Siding (`12`) + Business Print Paper (`21`) + Template (`84`), so the default DL / 50-pack / single / 120gsm bond / upload is `FY3310S80U`, which prices at 1995 — the same figure the page server-renders into `priceReducer`. The ladder walks the Pack Size component, so **the price is per pack**, and the per-unit figure is the pack price divided by the pack quantity, as the widget does it.

**`ACCUMULATIVE`** — Document Prints. There is no `genSku`; each component option carries its own SKU and the SKUs add up. The Printing component already holds one option per (size, siding, colour, quantity band) — `A4CL1PRNT1` is A4 / colour / single / 1–1000 — so the ladder is those options priced in one call. **The price is per printed side, in quantity bands, not per pack.** The paper stock is a separate charge per sheet on top; the default stock carries no SKU, which is the page's way of saying it is included in the print price.

Passing `--sided double` on Document Prints selects the `2PRNT` band SKUs, whose price is per side as well.

## Calls

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/officeworks.com.au/pub-price-ladder.py \
  prices --product flyers --size A5 --paper "120gsm Bond" --sided single

python3 ${CLAUDE_PLUGIN_ROOT}/skills/officeworks.com.au/pub-price-ladder.py \
  prices --product document-prints --size A4 --colour colour --sided single

python3 ${CLAUDE_PLUGIN_ROOT}/skills/officeworks.com.au/pub-price-ladder.py \
  options --product flyers
```

`--product` takes `flyers`, `document-prints`, or any `/print-copy/p/<slug>` path. `--size` is a finished size as the product offers it (Flyers: A3 A4 A5 A6 DL; Document Prints: A3 A4 A5). `--paper` is any substring of a stock's name, and an ambiguous one is refused with the stocks it matched rather than guessed at. `--sided` is `single` or `double`. `--colour` is `colour` or `black & white`, and matters only where the product offers the choice — Flyers has no Print Colour component and prints colour only. An option left unset takes the product's own default.

`options` prints the whole component tree, which is how to find out what a product actually offers before asking for a price.

Python 3 standard library only; no config keys, so nothing under `Prerequisites`.

## Output

The canonical envelope, with the ladder inside `result`. There is no `identity` key: the pages read here are signed-out and the site declares no account to name.

`result.ladder.basis` says which shape came back — `per_pack` (rows carry `quantity`, `pack_price_cents`, `unit_price_cents`, `gen_sku`) or `per_side` (rows carry `quantity_band`, `min`, `max`, `price_per_side_cents`, `sku`). A `per_side` result also carries `result.paper`, the stock's per-sheet charge or the fact that it is included. Money is integer cents, AUD, GST inclusive — the figure the signed-out retail page displays, which its own summary panel labels Inc GST.

A failure — an unreachable page, a size the product does not offer, an ambiguous paper name, a SKU the endpoint 404s — comes back as a fault envelope and exit 65.

## Limits

A signed-in business account with a contract price sees different money; the endpoint takes an `includeContractPricing` parameter for that, and this skill never sends it, so every figure here is the ordinary retail price.

Delivery and same-day-print availability are not priced. `result.product` carries the lead times the page states (`delivery_to_door`, `click_and_collect`) and nothing more.

Products whose `pricingType` is neither `PERMUTATION` nor `ACCUMULATIVE`: unbuilt, undecided. `options` still prints their component tree.
