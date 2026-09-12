---
name: vistaprint.com.au
description: "Vistaprint Australia flyer prices in AUD: the full quantity ladder for a size, paper stock, thickness and sidedness; plus delivery cost and business days."
allowed-tools: Bash
---

# Vistaprint Australia

Flyer prices on vistaprint.com.au are quoted by a React configurator whose quantity tiles stay `po-tile--loading` in a plain DOM dump. They do not have to be read off the page: the configurator's own price service answers an anonymous GET. No browser, no cookie, no token, no `pricingContext`, and no `browser-serialiser`.

## Prices

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/vistaprint.com.au/pub-flyer-prices.tcl" --size A5
"${CLAUDE_PLUGIN_ROOT}/skills/vistaprint.com.au/pub-flyer-prices.tcl" --size A4 --sides double --thickness Premium --stock Glossy
"${CLAUDE_PLUGIN_ROOT}/skills/vistaprint.com.au/pub-flyer-prices.tcl" --size DL --quantities 500,1000,2500
```

`--size` is required and takes either the site's key or the name a person would type (`A5`, `A4`, `DL`, `A3`, `A7`, `A6`, `Square`). `--sides` is `single` (the default, and what the site prices when sidedness is left unsaid) or `double`. `--stock`, `--thickness` and `--fold` take any value the site offers; every option the caller does not name keeps the value the product page loads with. `--quantities` is a comma-separated list; without it the whole merchandised ladder is priced, 25 through 20000.

`result.ladder` is one row per quantity with the total and the unit price, GST-inclusive and exclusive. `result.priced_as` is the combination the service says it actually priced, attribute by attribute, including the ones the page leaves implicit (`Grammage` follows paper thickness). `result.options` is the attribute surface read off the page that run, so a size or stock that has come or gone shows up there rather than in a stale list here.

Every price is for the flyer alone. Delivery is separate and is the second action.

## Delivery

```bash
"${CLAUDE_PLUGIN_ROOT}/skills/vistaprint.com.au/pub-shipping-options.tcl"
```

Returns each delivery method with its cost and its estimated business days per area. The areas are state plus metro/regional/remote, which is as fine as the site publishes; a delivery date for one postcode and one cart is computed at checkout.

## How the prices are reached

Two GETs, verified 2026-09-12. The first is the product page, `https://www.vistaprint.com.au/marketing-materials/flyers`, whose server-rendered HTML carries the product record in a `<script type="application/x-ubik-event">` mount blob for `@vp/fragment-pdp-pricing-shipping`: product key, product version, the attribute surface with each option's key and display name, the default combination, and the merchandised quantity ranges. That is read every run rather than pinned here, so a repriced or re-versioned product does not become a stale constant.

The second is the price service the configurator calls:

```
GET https://website-pricing-service-cdn.prices.cimpress.io/v4/prices/startingAt/estimated
    ?requestor=<any string>
    &productKey=PRD-N2LQNKLY&productVersion=39
    &selections[Format]=A5&selections[Material]=...&selections[PrintColor]=4%2F0%20-%20CMYK
    &quantities=25&quantities=50&...
    &merchantId=vistaprint&market=AU&pricingContext=
```

Notes that cost time to rediscover:

- `requestor` is required and unvalidated; omitting it returns a 400 that names it.
- `selections` goes one bracketed parameter per attribute. Passing the whole combination as a single JSON blob returns the same 400 about `requestor`, which points away from the real fault.
- `quantities` repeats, once per rung, and every rung is priced in the one response.
- `pricingContext` may be empty. The page mints one and it changes nothing for an anonymous Australian read.
- Sidedness is the `PrintColor` attribute, `4/0 - CMYK` single sided and `4/4 - CMYK/CMYK` double sided. The product page's own option list does not carry it; the price service prices it, and omitting it yields single sided.
- `curl` needs `-g`, or it reads the brackets in `selections[Format]` as a glob range.
- Prices are `taxed` (GST inclusive, the number an Australian shopper is shown) and `untaxed`.

## Unbuilt

A delivery date for a given postcode and cart. The page gets it from `POST https://carts.checkout.cimpress.io/v0/accounts/{accountId}/shoppers/{shopperId}/cartTypes/{cartTypeId}/preview`, which answers 401 without the anonymous shopper token the site mints in the browser. Unbuilt, undecided.
