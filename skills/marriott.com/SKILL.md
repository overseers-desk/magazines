---
name: marriott.com
description: "find hotel properties near a destination, lookup by property code; info (name, brand, address, coords, images, reviews). No pricing or live availability."
allowed-tools: Bash, Read
---

# marriott.com

Marriott's public site is served behind Akamai and calls an Apollo GraphQL backend at `POST https://www.marriott.com/mi/query/<operationName>`. The backend refuses any operation whose name + signature (sha256) pair is not pre-registered. Registered operations accessible without a session are listed below; each has a signature that must be sent in the `graphql-operation-signature` request header.

## Required headers

All GraphQL POSTs need this full set. Missing the `graphql-require-safelisting` or `apollographql-client-name` headers produces Akamai 403.

```
-H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36'
-H 'Accept: */*'
-H 'Origin: https://www.marriott.com'
-H 'Referer: https://www.marriott.com/'
-H 'Content-Type: application/json'
-H 'graphql-require-safelisting: true'
-H 'graphql-operation-name: <operationName>'
-H 'graphql-operation-signature: <sha256 hex>'
-H 'apollographql-client-name: phoenix_homepage'
-H 'apollographql-client-version: v1'
--compressed
```

URL path is `https://www.marriott.com/mi/query/<operationName>`. The operation name appears in the URL, in the `graphql-operation-name` header, and in the JSON body's `operationName` field.

Request body shape: `{"operationName":"<op>","variables":{...}}`. No query text is sent — the server looks up the registered query by operation-name + signature.

## Signature lifetime and re-extraction

Signatures rotate on Marriott front-end deploys (every few weeks). When a previously-working call starts returning 403 or `operation signature mismatch`, refresh the table below by fetching the homepage and parsing `__NEXT_DATA__`:

```bash
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
  -H 'Accept-Language: en-US,en;q=0.9' \
  -H 'Accept-Encoding: gzip, deflate, br' \
  'https://www.marriott.com/' \
  | python3 -c '
import sys, re, json
html = sys.stdin.read()
m = re.search(r"<script id=\"__NEXT_DATA__\" type=\"application/json\">(.+?)</script>", html)
sigs = json.loads(m.group(1))["props"]["pageProps"]["operationSignatures"]
for s in sigs: print(f"{s[\"operationName\"]}\t{s[\"signature\"]}")
'
```

The homepage exposes 8 signatures. A brand landing page (e.g. `https://www.marriott.com/brands/courtyard-by-marriott.mi`) exposes 21 including the richer property-search operations used below; use the same `__NEXT_DATA__` extraction on that URL to refresh those. Marriott registers multiple signatures per operation name (homepage and brand-page signatures can both be valid at the same time), so any match in either page's list will work.

## Signatures (current as of extraction)

Homepage (`https://www.marriott.com/default.mi`):

| Operation | Signature |
|---|---|
| `phoenixShopSuggestedPlacesQuery` | `70b3555c91797ca8945e4f4b1bdda42c3e37fa1f08fa99feafb73195702c1d34` |
| `phoenixShopSuggestedPlacesDetailsQuery` | `0b89c8ea7a6a6408eaee651983d6c7ee168670b727cc5beea980b2d2edfdbe2b` |
| `phoenixShopAdvSearchInventoryDate` | `7d7f735313b7f2dda708c1c9b6dc51233434f78319639a70a0d8b20f508ca02b` |

Brand pages (e.g. `https://www.marriott.com/brands/courtyard-by-marriott.mi`):

| Operation | Signature |
|---|---|
| `phoenixLuxurySearchByGeoQueryList` | `082d2f021ba4d85c80280e519f6052b7e5985a83cf97d6b6a7b410784cee4e57` |
| `phoenixLuxurySearchByGeoQueryMap` | `76c924cf9e864af810265c31bdad98a50161ec695b07029734e685c6e07ad8cd` |
| `phoenixLuxuryPropertyInfo` | `20c0e2cfa7a788ddefc68fe869feea481a3019fd57ddc628b36e094a4be682ed` |
| `PhoenixDestinationOffersSearchByGeolocation` | `2c4599862b62a6ca194111f18030d55811dc635e623be9c41e5d7953302def2b` |

## Capabilities

### 1. Destination autocomplete — name to placeId

Operation: `phoenixShopSuggestedPlacesQuery`. Variable: `query: String!`. Returns up to 5 Google-Places-style results ranked by match.

```bash
OP=phoenixShopSuggestedPlacesQuery
SIG=70b3555c91797ca8945e4f4b1bdda42c3e37fa1f08fa99feafb73195702c1d34
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: */*' -H 'Origin: https://www.marriott.com' -H 'Referer: https://www.marriott.com/' \
  -H 'Content-Type: application/json' \
  -H "graphql-operation-name: $OP" -H "graphql-operation-signature: $SIG" \
  -H 'graphql-require-safelisting: true' \
  -H 'apollographql-client-name: phoenix_homepage' -H 'apollographql-client-version: v1' \
  --data '{"operationName":"'"$OP"'","variables":{"query":"Paris"}}' \
  "https://www.marriott.com/mi/query/$OP"
```

Response shape: `data.suggestedPlaces.edges[].node = { placeId, primaryDescription, secondaryDescription, description }`.

### 2. Place details — placeId to coordinates

Operation: `phoenixShopSuggestedPlacesDetailsQuery`. Variable: `placeId: ID!`. Returns latitude, longitude, country, city, state, destinationType (City, Airport, Point Of Interest, etc.).

```bash
OP=phoenixShopSuggestedPlacesDetailsQuery
SIG=0b89c8ea7a6a6408eaee651983d6c7ee168670b727cc5beea980b2d2edfdbe2b
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: */*' -H 'Origin: https://www.marriott.com' -H 'Referer: https://www.marriott.com/' \
  -H 'Content-Type: application/json' \
  -H "graphql-operation-name: $OP" -H "graphql-operation-signature: $SIG" \
  -H 'graphql-require-safelisting: true' \
  -H 'apollographql-client-name: phoenix_homepage' -H 'apollographql-client-version: v1' \
  --data '{"operationName":"'"$OP"'","variables":{"placeId":"ChIJD7fiBh9u5kcRYJSMaMOCCwQ"}}' \
  "https://www.marriott.com/mi/query/$OP"
```

Response shape: `data.suggestedPlaceDetails = { placeId, description, destinationType, location: { latitude, longitude, address, city, country, countryName, state } }`.

### 3. Properties near a coordinate — list view

Operation: `phoenixLuxurySearchByGeoQueryList`. Required variables: `search.latitude: Float!`, `search.longitude: Float!`, `search.facets: SearchPropertiesFacetInput!` (can be `{}`). Returns up to 30 hotels near the point; `total` gives the full count.

```bash
OP=phoenixLuxurySearchByGeoQueryList
SIG=082d2f021ba4d85c80280e519f6052b7e5985a83cf97d6b6a7b410784cee4e57
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: */*' -H 'Origin: https://www.marriott.com' -H 'Referer: https://www.marriott.com/' \
  -H 'Content-Type: application/json' \
  -H "graphql-operation-name: $OP" -H "graphql-operation-signature: $SIG" \
  -H 'graphql-require-safelisting: true' \
  -H 'apollographql-client-name: phoenix_homepage' -H 'apollographql-client-version: v1' \
  --data '{"operationName":"'"$OP"'","variables":{"search":{"facets":{},"latitude":48.8575,"longitude":2.3513}}}' \
  "https://www.marriott.com/mi/query/$OP"
```

Response shape per hotel: `{ id, basicInformation: { name, brand: { id } }, contactInformation: { address: { city, country, stateProvince } }, media.primaryImage.edges[].node.imageUrls, reviews: { numberOfReviews.count, stars.count }, seoNickname }`.

`id` is the 5-char Marriott property code (e.g. `PAROB`). Combine with `seoNickname` for the public hotel URL path `https://www.marriott.com/en-us/hotels/<seoNickname>/overview/` (page itself returns 403 to non-browser clients, but the URL is the canonical reference).

Brand codes returned in `basicInformation.brand.id` are two-letter (e.g. `MC` Marriott, `CY` Courtyard, `OX` Moxy, `BR` Renaissance, `DS` Design Hotels, `CM` citizenM).

Known additional `SearchPropertiesOptionsInput` fields: `numberOfGuestRooms: Int`, `numberInParty: Int`, `customerId: String`. Dates and pricing are NOT part of the registered query — this endpoint cannot return prices.

### 4. Properties near a coordinate — map view (coords only)

Operation: `phoenixLuxurySearchByGeoQueryMap`. Same variables as list view. The registered query selects only `id`, `latitude`, `longitude` — intended for map pins.

```bash
OP=phoenixLuxurySearchByGeoQueryMap
SIG=76c924cf9e864af810265c31bdad98a50161ec695b07029734e685c6e07ad8cd
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: */*' -H 'Origin: https://www.marriott.com' -H 'Referer: https://www.marriott.com/' \
  -H 'Content-Type: application/json' \
  -H "graphql-operation-name: $OP" -H "graphql-operation-signature: $SIG" \
  -H 'graphql-require-safelisting: true' \
  -H 'apollographql-client-name: phoenix_homepage' -H 'apollographql-client-version: v1' \
  --data '{"operationName":"'"$OP"'","variables":{"search":{"facets":{},"latitude":48.8575,"longitude":2.3513}}}' \
  "https://www.marriott.com/mi/query/$OP"
```

### 5. Property info by ID (batch)

Operation: `phoenixLuxuryPropertyInfo`. Variable: `ids: [ID!]!`. Returns basic info, coordinates, primary image, reviews summary, seoNickname for each given property code. Batches of at least 8 work in a single request.

```bash
OP=phoenixLuxuryPropertyInfo
SIG=20c0e2cfa7a788ddefc68fe869feea481a3019fd57ddc628b36e094a4be682ed
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: */*' -H 'Origin: https://www.marriott.com' -H 'Referer: https://www.marriott.com/' \
  -H 'Content-Type: application/json' \
  -H "graphql-operation-name: $OP" -H "graphql-operation-signature: $SIG" \
  -H 'graphql-require-safelisting: true' \
  -H 'apollographql-client-name: phoenix_homepage' -H 'apollographql-client-version: v1' \
  --data '{"operationName":"'"$OP"'","variables":{"ids":["PAROB","PAROP","PARPR"]}}' \
  "https://www.marriott.com/mi/query/$OP"
```

Response: `data.propertiesByIds[]` with the same fields as capability 3.

### 6. Destination offers by geolocation

Operation: `PhoenixDestinationOffersSearchByGeolocation`. Required variables: `input: { latitude, longitude }`, `offset: Int!`. Returns marketing offers (bonus points, discounts) relevant to hotels near that point.

```bash
OP=PhoenixDestinationOffersSearchByGeolocation
SIG=2c4599862b62a6ca194111f18030d55811dc635e623be9c41e5d7953302def2b
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: */*' -H 'Origin: https://www.marriott.com' -H 'Referer: https://www.marriott.com/' \
  -H 'Content-Type: application/json' \
  -H "graphql-operation-name: $OP" -H "graphql-operation-signature: $SIG" \
  -H 'graphql-require-safelisting: true' \
  -H 'apollographql-client-name: phoenix_homepage' -H 'apollographql-client-version: v1' \
  --data '{"operationName":"'"$OP"'","variables":{"input":{"latitude":48.8575,"longitude":2.3513},"offset":0}}' \
  "https://www.marriott.com/mi/query/$OP"
```

Response: `data.offersSearchByGeolocation.edges[].node = { id, descriptionTeaser, offerCategory, offerType, media.primaryImage, participatingProperties.properties[], memberLevel, ... }`.

### 7. Maximum reservation date

Operation: `phoenixShopAdvSearchInventoryDate`. No variables. Returns the last bookable date — tells the caller what the inventory horizon is before querying a specific stay.

```bash
OP=phoenixShopAdvSearchInventoryDate
SIG=7d7f735313b7f2dda708c1c9b6dc51233434f78319639a70a0d8b20f508ca02b
curl -sL --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  -H 'Accept: */*' -H 'Origin: https://www.marriott.com' -H 'Referer: https://www.marriott.com/' \
  -H 'Content-Type: application/json' \
  -H "graphql-operation-name: $OP" -H "graphql-operation-signature: $SIG" \
  -H 'graphql-require-safelisting: true' \
  -H 'apollographql-client-name: phoenix_homepage' -H 'apollographql-client-version: v1' \
  --data '{"operationName":"'"$OP"'","variables":{}}' \
  "https://www.marriott.com/mi/query/$OP"
```

Response: `data.advancedReservationDateLimit.singleDateLimit.value` (transient), `.groupDateLimit.value` (group).

## Typical workflow

For "Marriott hotels in <place>":

1. Call `phoenixShopSuggestedPlacesQuery` with the place name. Pick the best edge's `placeId`.
2. Call `phoenixShopSuggestedPlacesDetailsQuery` with that `placeId`. Read `location.latitude` and `location.longitude`.
3. Call `phoenixLuxurySearchByGeoQueryList` with those coordinates. Iterate `data.search.properties.searchByGeolocation.edges` for the hotel list. `total` is the full count; only the first 30 come back in `edges`.
4. If more than 30 hotels are needed and the `edges` limit is insufficient, the registered query does not expose pagination — capability is capped at 30 per geolocation query.

The homepage GraphQL path handled ~20 back-to-back requests without throttling. A second or two between calls avoids tripping Akamai's adaptive rules. If the GraphQL endpoints start returning 403 consistently, fall back to `browser-serialiser --dump`.
