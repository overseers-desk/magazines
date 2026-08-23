# Flight search: the query and result contract

A skill that prices flights (an airline's own site, an OTA, a metasearch) takes its query and reports its answer in this one shape, so a caller can swap sites without changing the request, and put two sites' answers side by side. `xiamenair.com`, `kiwi.com` and `beatthatflight.com.au` are written against it in full. `csair.com` and `hainanairlines.com` share its query shape and answer conventions but keep their own failure vocabulary and lack `--limit`; bringing them onto the exit codes and prefixes below is open work. A site's own oddities (a China-domestic schedule without prices, a fare-family ladder, a quota refusal) are reported inside this shape, not by a different shape.

## Query

```
<script> <origin> <dest> <date YYYY-MM-DD> [--return YYYY-MM-DD] [--adults N] [--children N] [--infants N] [--cabin CABIN] [--currency CCC] [--limit N] [--json]
<script> --leg DEP-ARR-YYYY-MM-DD --leg DEP-ARR-YYYY-MM-DD [--leg ...] [same options]
```

- `origin`, `dest`: 3-letter IATA airport or city codes, case-insensitive, different from each other. A skill resolves a city code (`LON`, `CAN`) to whatever its site wants (an airport list, a place id) itself; the caller does not deal in the site's ids.
- `date`: `YYYY-MM-DD`, today or later. `--return` is the date of the back leg `dest → origin`, on or after `date`; the journey is then priced as one return, not two one-ways.
- `--leg DEP-ARR-YYYY-MM-DD`, repeatable, 2 to 5, dates in travel order: a multi-city journey, replacing the positional route and excluding `--return`. A site that cannot price multi-city refuses it at validation (`bad arguments: multi-city not offered by <site>`), before any request.
- `--adults N` / `--children N` / `--infants N`: defaults 1/0/0; adults at least 1, infants at most the adult count. A site's tighter cap is enforced at validation with the site's number in the message.
- `--cabin ECONOMY|PREMIUM_ECONOMY|BUSINESS|FIRST`: default `ECONOMY`. A site that sells a cabin under another name maps it; a site without the cabin refuses at validation.
- `--currency CCC`: the display currency. No default: omitted, the skill sends no currency preference and reports whatever currency the site answers in, so a caller who cares asks, and one who does not is not made to search twice because a default was not the currency wanted. A site that quotes in one fixed currency ignores the flag and says so in its SKILL.md.
- `--limit N`: itineraries returned, cheapest first, default 20. The answer still states how many the site found.
- `--json`: the structured answer below instead of the text answer.

Unknown options, a past date, a bad code, a count outside the caps: refused before any request, exit 2, message on stderr.

## Answer

Cheapest first; the whole party's total rather than one passenger's; local times at each airport, `+1`/`+2` where the arrival's calendar day is later than the leg's departure day.

Text: a header line naming the query as understood (`BNE → TBS 2026-09-05, 1 adult, ECONOMY; 310 itineraries, showing 20, prices in AUD`), then one block per itinerary:

```
#1  AUD 866.49   1d 07h 55m   1 stop   China Eastern
    MU 736   BNE 11:05 → PVG 18:00+1   10h55m   A332
    MU 5019  PVG 22:35+1 → TBS 19:00+1 ...
```

One line per leg header for a return or multi-city (`out`, `back`, or `leg 1`..`leg 5` with that leg's date), its segments indented beneath. Where the site names the seller (an OTA lists several agencies per itinerary), the block ends with `via <seller>` and the booking URL where the site gives one. A site-specific line (fare family, seats left, booking class, self-transfer warning) goes after the segments of the itinerary it belongs to; the vocabulary above stays as it is.

`No itineraries` for a route and date the site serves but has nothing for is a normal answer, exit 0.

JSON (`--json`), one object:

```
source            the skill's site domain
tripType          one-way | return | multi-city
bounds[]          {origin, destination, date} as requested, in travel order
passengers        {adults, children, infants}
cabinClassRequested
currency          the currency every amount below is in, requested or the site's own
totalResults      how many the site found (null if the site does not say)
itineraries[]     cheapest first, at most --limit
  price           {amount, currency}      whole party
  durationMinutes total elapsed, first departure to last arrival
  legs[]          one per bound, in bound order
    origin, destination, departure, arrival   ISO local datetimes, no offset
    durationMinutes, stops
    segments[]    {flight, carrier, carrierName, operatedBy, origin, departure,
                   destination, arrival, durationMinutes, equipment}
  seller          who sells this itinerary, where the site names one (else null)
  bookingUrl      where the site gives one (else null)
  <site extras>   named keys the SKILL.md documents; additions only, the keys above keep their names
```

`flight` is the marketing flight (`MU736`); `carrier` its 2-letter code; `operatedBy` the operating carrier where it differs, else null. Amounts are numbers, not strings.

## Exit codes and message prefixes

Stderr carries one line, exit code says the class; the airline skills use the same set.

- `0` answer printed, including `No itineraries`
- `2` `bad route:` / `bad date:` / `bad leg:` / `bad passenger count:` / `bad cabin:` / `bad currency:` / `bad arguments:`: the query itself, nothing sent
- `3` `request rejected:`: the site answered the search with a refusal (quota, captcha, a parameter it will not price); the site's own code or message echoed
- `4` `transport failure:`: host unreachable, timeout, answer outside any format; usually transient
- `5` `unexpected payload:`: an answer arrived but not in the shape the skill knows; the site may have changed
- `66` `browser-serialiser: terminal <state>`: a browser-run skill hit a wall the harness recognises (COMMAND-SURFACE.md)
- `77` `session missing: <site>, profile "<path>"`: the wall was a login or checkpoint redirect (SESSION-CONTRACT.md)

## Where a skill's code lives

A plain-HTTPS site: one `search.py`, invoked as `${CLAUDE_PLUGIN_ROOT}/skills/<site>/search.py`. A site that needs the browser: one `search.tcl`, invoked as `browser-serialiser <site>/search`. Either way the SKILL.md's `argument-hint` is the Query line above with the options that site honours, and its body documents the site extras and the site's caps.
