---
name: renfe.com
description: "RENFE (Spanish national rail): station codes/coordinates, direct trains between two stations on a date, train type (AVE/Avlo/ALVIA/AVANT/Intercity/MD/Regional/Cercanías), live delays, live vehicle positions, service alerts."
allowed-tools: Bash, Read
---

# renfe.com

The RENFE consumer sites `www.renfe.com` and `horarios.renfe.com` are fenced by Akamai and reject plain curl (403 on every path). The booking site `venta.renfe.com` is reachable but gates every itinerary search behind an invisible reCAPTCHA v2/v3 token generated in-browser, so `buscarTren.do` and `searchTickets.do` cannot be driven programmatically.

Everything below uses RENFE's two open data hosts, which are outside Akamai and answer plain `curl` with a normal User-Agent:

- `data.renfe.com` — CKAN dataset catalogue (`https://data.renfe.com/api/3/action/...`).
- `ssl.renfe.com` — static file host for the GTFS zips, station CSV, and the 99-entry JS station list used by the booking UI.
- `gtfsrt.renfe.com` — GTFS-Realtime feeds (JSON mirror of the .pb feeds).

## Required headers

A plain Chrome-compatible User-Agent is enough for every endpoint below; nothing rotates per deploy. `--compressed` matters for `data.renfe.com` and `venta.renfe.com` (both gzip); the `gtfsrt.renfe.com` feeds are uncompressed JSON.

```
-H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36'
--compressed
```

No cookies, sessions, or tokens are required.

## Capabilities

### 1. Station list — short list used by the booking site (99 entries)

The booking site's autocomplete ships from this file. It contains the 99 most-used long-distance stations plus 8 city-level aggregator codes (`MADRI`, `BARCE`, `VALEN`, `ZARAG`, `GIJON`, `GUADA`, `IRUN-`, `LISBO`). Stations outside this list (e.g. small Cercanías stops) are NOT here — use capability 2 for the full list.

The file is plain JavaScript (ISO-8859-1), not JSON. One JS array `estaciones` of `[code, name, country]` triples.

```bash
curl -s --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://venta.renfe.com/vol/js2/estaciones.js'
```

Shape:

```
var estaciones=[["31412","A CORUNA","ES"],["60000","MADRID-PUERTA DE ATOCHA","ES"],["17000","MADRID-CHAMARTIN","ES"],["71801","BARCELONA-SANTS","ES"],...];
```

The numeric codes (e.g. `60000`, `71801`) are the CIF station codes used as `stop_id` in GTFS and in every other RENFE feed. The 5-letter aggregator codes (`MADRI` etc.) are city-level and are only recognised by the booking UI — GTFS and GTFS-RT never emit them.

### 2. Station list — full RENFE network (~1680 entries, CKAN dataset)

`data.renfe.com` mirrors the station master file. The CSV is ISO-8859-1, semicolon-delimited, fields: `CODIGO;DESCRIPCION;LATITUD;LONGITUD;DIRECION;CP;POBLACION;PROVINCIA;PAIS;CERCANIAS;FEVE;COMUN`.

```bash
curl -s --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://ssl.renfe.com/ftransit/Fichero_estaciones/estaciones.csv' \
  -o /tmp/renfe-stations.csv
iconv -f ISO-8859-1 -t UTF-8 /tmp/renfe-stations.csv | head -5
```

Same data is queryable as paged JSON via the CKAN datastore when a smaller slice is enough:

```bash
curl -s --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://data.renfe.com/api/3/action/datastore_search?resource_id=783e0626-6fa8-4ac7-a880-fa53144654ff&q=MADRID&limit=5'
```

Response: `result.records[]` with typed fields; `result.total` gives the total match count.

### 3. Static schedule — AV / LD / MD (GTFS)

A full GTFS zip (`agency`, `calendar`, `calendar_dates`, `routes`, `stops`, `stop_times`, `trips`) covering roughly the next six months of long-distance, high-speed, and medium-distance services.

```bash
curl -s \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://ssl.renfe.com/gtransit/Fichero_AV_LD/google_transit.zip' \
  -o /tmp/renfe-gtfs-ld.zip
unzip -l /tmp/renfe-gtfs-ld.zip
```

Key shape details observed on 2026-04-17:

- `stop_id` matches the 5-digit CIF codes from capability 1/2.
- `route_short_name` is the commercial product name: `AVE`, `AVE INT`, `AVLO`, `ALVIA`, `AVANT`, `AVANT EXP`, `EUROMED`, `Intercity`, `MD`, `REGIONAL`, `REG.EXP.`, `PROXIMDAD`, `TRENCELTA`, `CHARTER`.
- `trip_id` ends with `YYYY-MM-DD` — the start date of that trip's service. Do NOT filter trips by matching the date suffix of `trip_id`; that gives only services whose service_id starts that day. Use `service_id` against `calendar.txt` (day-of-week + date range) plus `calendar_dates.txt` exceptions to find every trip running on a target date.
- `trips.txt` has `trip_short_name` (the 5-digit train number, e.g. `03311`) which is what passengers see on signage.
- Each line in `stop_times.txt` is padded with trailing spaces; strip when parsing.

Example: direct trains Madrid-Puerta de Atocha (`60000`) to Barcelona-Sants (`71801`) on a Friday:

```bash
python3 << 'PY'
import csv, zipfile
from datetime import datetime
from collections import defaultdict

d = datetime(2026, 5, 1)
dow = d.strftime('%A').lower()
dstr = d.strftime('%Y%m%d')

def rows(z, name):
    with z.open(name) as f:
        r = csv.reader(l.decode('utf-8').rstrip('\r\n') for l in f)
        hdr = [h.strip() for h in next(r)]
        for row in r:
            yield {hdr[i]: (row[i].strip() if i < len(row) else '') for i in range(len(hdr))}

with zipfile.ZipFile('/tmp/renfe-gtfs-ld.zip') as z:
    svc = set()
    for r in rows(z, 'calendar.txt'):
        if r['start_date'] <= dstr <= r['end_date'] and r[dow] == '1':
            svc.add(r['service_id'])
    for r in rows(z, 'calendar_dates.txt'):
        if r['date'] == dstr:
            (svc.add if r['exception_type'] == '1' else svc.discard)(r['service_id'])
    trips = {r['trip_id']: r for r in rows(z, 'trips.txt') if r['service_id'] in svc}
    routes = {r['route_id']: r['route_short_name'] for r in rows(z, 'routes.txt')}
    by_trip = defaultdict(list)
    for r in rows(z, 'stop_times.txt'):
        if r['trip_id'] in trips:
            by_trip[r['trip_id']].append(r)

out = []
for tid, sts in by_trip.items():
    sts.sort(key=lambda s: int(s['stop_sequence']))
    ids = [s['stop_id'] for s in sts]
    if '60000' in ids and '71801' in ids and ids.index('60000') < ids.index('71801'):
        o = next(s for s in sts if s['stop_id'] == '60000')
        e = next(s for s in sts if s['stop_id'] == '71801')
        out.append((o['departure_time'], e['arrival_time'], routes[trips[tid]['route_id']], trips[tid]['trip_short_name'], tid))
for dep, arr, ty, num, tid in sorted(out):
    print(f'{dep} -> {arr}  {ty:10} {num:6} {tid}')
PY
```

A single GTFS `trip_id` is one physical train running end-to-end — it has no concept of "change trains". Journeys that would need a transfer appear as two separate `trip_id`s sharing a connecting station; stitching them into an itinerary requires a separate router.

### 4. Static schedule — Cercanías (GTFS, commuter networks)

Separate GTFS archive for the 11 Cercanías networks (Madrid, Barcelona/Rodalies, Valencia, Sevilla, etc.). Same GTFS structure, plus a populated `transfers.txt` giving station-to-station transfer times within each network. Note the file is ~300 MB uncompressed — stream it rather than loading in memory.

```bash
curl -s \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://ssl.renfe.com/ftransit/Fichero_CER_FOMENTO/fomento_transit.zip' \
  -o /tmp/renfe-gtfs-cer.zip
unzip -l /tmp/renfe-gtfs-cer.zip
```

### 5. Live delays — AV / LD (GTFS-Realtime, trip updates)

```bash
curl -s \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://gtfsrt.renfe.com/trip_updates_LD.json'
```

Response (GTFS-RT 2.0, JSON-encoded protobuf): `{ header: {timestamp}, entity: [{id, tripUpdate: {trip: {tripId}, delay}}, ...] }`. `delay` is in seconds and can be negative (early) or missing (on time / unknown). `tripId` matches `trips.txt.trip_id` in the AV/LD GTFS, so you can cross-reference the current delay of any scheduled train you found in capability 3.

Observed: ~200 live AV/LD entities during operating hours.

### 6. Live delays — Cercanías

Same schema as capability 5, different network:

```bash
curl -s \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://gtfsrt.renfe.com/trip_updates.json'
```

### 7. Live vehicle positions — AV / LD

```bash
curl -s \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://gtfsrt.renfe.com/vehicle_positions_LD.json'
```

Per-entity shape: `vehicle: { trip: {tripId}, position: {latitude, longitude}, currentStatus: IN_TRANSIT_TO | STOPPED_AT, stopId, vehicle: {id, label} }`. `vehicle.id` is the physical train set number (e.g. `04073`). The whole-network feed including Cercanías is at `https://gtfsrt.renfe.com/vehicle_positions.json`.

### 8. Service alerts / disruptions

```bash
curl -s \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://gtfsrt.renfe.com/alerts.json'
```

Per entity: `alert: { activePeriod: [{start, end?}], informedEntity: [{routeId | stopId | trip}], descriptionText: {translation: [{text, language}]} }`. `descriptionText` is Spanish-only. `routeId` cross-references `routes.txt` in the GTFS.

### 9. Train fleet factsheets

Catalogue of train types and their technical specs (AVE S-103, Avlo S-106, etc.):

```bash
curl -s \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://data.renfe.com/dataset/d5524151-d959-40a0-a3ba-4546e7533b11/resource/4877096a-160f-4fb2-925d-d261b51a065f/download/informacion-trenes.csv'
```

### 10. Dataset discovery (CKAN)

```bash
curl -s --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://data.renfe.com/api/3/action/package_list'
curl -s --compressed \
  -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36' \
  'https://data.renfe.com/api/3/action/package_show?id=<package-id>'
```

Lists all open datasets RENFE publishes (timetables, vehicle positions, passenger volumes, sustainability indicators, etc.) and resolves a named package to its download URLs.

## Typical workflow

For "next AVE from Madrid to Barcelona this Friday, with live delays":

1. Resolve "Madrid" and "Barcelona" to CIF codes via capability 1 (short list is enough for the big cities: Madrid-Puerta de Atocha `60000`, Madrid-Chamartin `17000`, Barcelona-Sants `71801`). For smaller towns, fall to capability 2.
2. Download the AV/LD GTFS (capability 3) once per session and keep it in `/tmp`. Query `calendar.txt` + `calendar_dates.txt` + `stop_times.txt` for trips containing both station codes in order on the target date; read `route_short_name` to filter `AVE`/`AVLO`/etc.
3. For each matching `trip_id`, look it up in the latest `trip_updates_LD.json` (capability 5) to report the current delay in seconds.

The GTFS zips and station CSV change at most a few times a day; cache them for the session. The `gtfsrt.renfe.com` feeds refresh every ~30 seconds — re-fetch on each live-status question.
