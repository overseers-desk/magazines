---
name: premierinn.com
description: "Premier Inn (Whitbread) hotel room availability, live nightly pricing, room-type inventory, rate plans (Flex/Standard/Non-Flex), occupancy rules. Premier Inn does not distribute prices through Google Hotels or OTAs; this is the only programmatic price source."
allowed-tools: Bash, Read
---

# Premier Inn

The booking SPA at premierinn.com calls an open GraphQL endpoint at `POST https://api.premierinn.com/graphql`. Named queries execute anonymously via curl; no API key, no cookies. Introspection is off (server returns `INTROSPECTION_DISABLED`; the Akamai WAF additionally 403s any body containing `__schema`), so the queries below were extracted from the site's webpack bundles and verified live.

## Required headers

```
-H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36'
-H 'Content-Type: application/json'
-H 'Origin: https://www.premierinn.com'
-H 'Referer: https://www.premierinn.com/'
--compressed
```

## Hotel ID resolution (slug → hotelId)

Hotel IDs are 6-letter codes (e.g. `LONBLA` = London Blackfriars (Fleet Street)). Resolve from the public hotel-page URL path: take everything from `/hotels/` to `.html` as the slug.

```bash
curl -s --compressed <HEADERS> 'https://api.premierinn.com/graphql' --data '{
 "query":"query h($slug:String!,$language:String!,$country:String!){hotelInformationBySlug(slug:$slug,language:$language,country:$country){hotelId name address{addressLine1 postalCode} coordinates{latitude longitude}}}",
 "variables":{"slug":"/hotels/england/greater-london/london/london-blackfriars-fleet-street.html","language":"en","country":"gb"}}'
```

Returns `data.hotelInformationBySlug.{hotelId,name,address,coordinates}`. The same data (plus parking, directions, facilities, city-tax flags) is embedded in the hotel page's `__NEXT_DATA__` under the `staticHotelInformation` dehydrated query, fetchable with plain curl, if more fields are wanted than the GraphQL selection above.

There is no working hotel-discovery-by-place query on this endpoint (the search results page renders server-side and returns 500 to non-browser clients). Find the hotel page URL first — premierinn.com hotel pages are indexed and fetchable by curl.

## Availability and prices (the core query)

```bash
curl -s --compressed <HEADERS> 'https://api.premierinn.com/graphql' --data @body.json
```

body.json:

```json
{
  "operationName": "hotelAvailability",
  "query": "query hotelAvailability($hotelId: String!, $arrival: String!, $departure: String!, $rooms: [RoomSearch!]!, $bookingChannel: BookingChannelCriteria!, $country: String!) { hotelAvailability(availabilitySearchCriteria: {arrival: $arrival, departure: $departure, rooms: $rooms, hotel: {identifier: $hotelId}, bookingChannel: $bookingChannel, country: $country}) { hotelId startDate endDate available limitedAvailability mlos roomRates { ratePlanCode promotionCode cellCode roomTypes { roomType roomNumber adults children cotRequested rooms { roomType pmsRoomType silentSubstitution cotAvailable roomClass specialRequests numberOfRoomsAvailable roomPriceBreakdown { totalNetAmount baseRateAmount currencyCode totalCityTaxAmount effectiveRateAmount dailyPrices { date netPrice effectiveRate } } } } } } }",
  "variables": {
    "hotelId": "LONBLA",
    "arrival": "2026-06-10",
    "departure": "2026-06-11",
    "rooms": [{"adultsNumber": 2, "childrenNumber": 2, "cotRequired": false, "roomType": "FAM"}],
    "country": "gb",
    "bookingChannel": {"channel": "PI", "language": "EN", "subchannel": "WEB"}
  }
}
```

Field notes, all verified by live calls:

- `rooms[]` is `RoomSearch`: `adultsNumber`, `childrenNumber`, `cotRequired`, `roomType`. Children are counted, not aged — under-16s are free and the site never asks ages. Multiple entries = multiple rooms.
- `roomType` codes: `DB` double, `SB` single, `TWIN` twin, `FAM` family, `DIS` accessible.
- `bookingChannel.channel` is the brand-channel enum: `PI` (Premier Inn), also `HUB`, `ZIP`, `PID` (Premier Inn Germany). `subchannel`: `WEB`, `MOBILE`, `CBT`, `WEB_DE`.
- Response: one `roomRates[]` entry per rate plan the hotel sells for those dates. Price is `rooms[].roomPriceBreakdown.totalNetAmount` (GBP, whole stay, per room); `dailyPrices[]` breaks it per night. `numberOfRoomsAvailable` is live inventory for that room/rate. `pmsRoomType` names the physical room (e.g. `FMQUAD` family quad, `FMTRPL` family triple).
- Do not add the site's companion sub-queries `ratesInformationV2`/`hotelInventory` to this operation: `ratesInformationV2` is non-nullable and its backing content service 404s for at least some hotels, nulling the whole response. Query availability alone (as above) and inventory separately if needed.

### Rate plans and cancellation terms

Rate plan codes returned in `ratePlanCode`, with the cancellation terms as published in the site's own booking copy:

| Code | Name | Cancellation |
|---|---|---|
| `FLEXRATE` | Flex | Amend or cancel up to 1pm on arrival day (Germany: 6pm) |
| `SEMIFLEX` | Semi-Flex | Amend or cancel up to three full days before arrival |
| `STANDARD` | Standard | Cannot be cancelled; arrival date amendable up to 1pm on arrival day |
| `ADVANCE` | Advance | Amend or cancel up to 28 days before arrival |
| `NONFLEX` | Non-Flex | Cannot be amended or cancelled |

A hotel typically returns a subset (e.g. Flex/Standard/Non-Flex) depending on dates and lead time.

## Room-type inventory (counts per physical room type)

```bash
curl -s --compressed <HEADERS> 'https://api.premierinn.com/graphql' --data '{
 "query":"query i($hotelId:String!,$dateRangeEnd:String!,$dateRangeStart:String!){hotelInventory(hotelId:$hotelId,dateRangeEnd:$dateRangeEnd,dateRangeStart:$dateRangeStart){roomTypeInventories{availableCount code}}}",
 "variables":{"hotelId":"LONBLA","dateRangeStart":"2026-06-10","dateRangeEnd":"2026-06-11"}}'
```

Returns per-PMS-room-type counts (`FMQUAD`, `FMTRPL`, `DOUBLE`, `WETTWN`, ...). Negative counts appear for oversold/overbookable types; treat `availableCount >= 1` as bookable.

## Occupancy rules

```bash
curl -s --compressed <HEADERS> 'https://api.premierinn.com/graphql' --data '{
 "query":"query s($channel:Channel!){roomOccupancyLimitations(channel:$channel){roomOccupancies{adultsNumber childrenNumber acceptedRoomTypes}}}",
 "variables":{"channel":"PI"}}'
```

Verified result: a room takes at most 2 adults + 2 children. Any party with children needs `FAM`; 2 adults without children fit `DB`/`TWIN`/`DIS`; 1 adult fits `SB`/`DB`/`DIS`. A family of 2+3 therefore needs two rooms (e.g. FAM + FAM or FAM + SB), split across `rooms[]` entries in one availability call.

## Errors

- `VALIDATION_INVALID_TYPE_VARIABLE` — a variable's object shape is wrong; the message names which one.
- `errCode 802` / "Unable to get booking information for hotel X" from `content-entity-service` — the hotel's static rate-description content is missing; availability for the same hotel still works (see the non-nullable note above).
- HTTP 403 "Access Denied" (Akamai) on a previously-working call — check the body for `__schema` or other introspection tokens first; the endpoint itself accepts plain curl.

## Fallback

If the GraphQL endpoint starts rejecting non-browser clients, fall back to `not-google-chrome` on the hotel page; prices render into the booking panel and `__NEXT_DATA__` still carries the static hotel record.
