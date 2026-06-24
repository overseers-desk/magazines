---
name: ndis.gov.au
description: "Australia's official NDIS provider register: search registered disability providers by suburb/postcode and radius, or confirm whether a named provider (or ABN) is registered and under which support groups."
allowed-tools: Bash, Read
---

# NDIS provider register

Australia's official "Find a registered NDIS provider" register. Public, no login. The same register backs both ndis.gov.au's Provider Finder and the NDIS Quality and Safeguards Commission's "Find a registered provider" page.

## How access works

The Provider Finder is a static React app, not a server-side search. On load it downloads the **entire register as one JSON file** and filters it in the browser; there is no query API to call per search. So this skill fetches that same file and runs the finder's own filters locally.

- `https://www.ndis.gov.au/sites/default/files/react_extract/provider_finder/build/data/list-providers.json` — every provider on the register, one row per office/outlet (~37 MB, ~66k rows over ~20k providers). Plain `curl` with a normal `User-Agent`; no auth, no headers beyond `User-Agent`/`Referer`.
- `.../data/australian-postcodes.json` — suburb/postcode → lat/long, used to turn a typed location into a search centre.

The base URL comes from `data-react-app-base` on the page; the finder JS calls `fetch(\`${base}data/list-providers.json?nocache=...\`)`. Verified 2026-06-24: both files return HTTP 200 as `application/json`, the dataset self-dates ("date": "24 June 2026") matching the Commission page's stated register update date.

`provider-register.py` does the fetch, filter and registration-group decode. It needs only python3 stdlib.

## What "on the register" means

The register lists providers that are **currently registered** *and* providers whose registration has been **suspended or revoked** — both appear. Each row's `Active` field is the distinction:

- `Active = 1` → currently registered
- `Active = 0` → on the register but not currently active (suspended / revoked / lapsed)

The finder shows inactive rows too (tagging active ones "/ Active"); it does not hide them. The script reports this as `registration_status` and carries the raw `active` value. Pass `--active-only` to keep just currently-registered providers.

## Capabilities

### 1. Search the register by location

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/ndis.gov.au/provider-register.py \
  region --location "Tamborine" --state QLD --radius 25
```

`--location` is a suburb name or postcode; `--state` (e.g. `QLD`) disambiguates a suburb/postcode that recurs across states. `--radius` is km (the finder offers 5/10/50/100/250/500; default here 25). Optional `--group "<substring>"` (repeatable) filters by registration-group name; `--active-only` drops suspended/revoked; `--limit N` caps the list.

Matches are providers whose **head office** falls within the radius of the location's centre (Haversine, R=6371 km — the finder's own formula), one entry per provider at its nearest office. Each entry carries: name, ABN, registration_status, registration_groups (code + name), location, state, postcode, record_type, phone, email, website, profession. `match_count` is the full count; `returned` reflects `--limit`.

(The finder also adds providers who *service* a postcode from elsewhere via a per-row serviced-postcode list, but that field is empty for almost all rows, so the office-radius set is the substantive result.)

### 2. Look up a specific provider by name or ABN

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/ndis.gov.au/provider-register.py lookup --name "Pony Pals"
python3 ${CLAUDE_PLUGIN_ROOT}/skills/ndis.gov.au/provider-register.py lookup --abn "39 793 923 272"
```

Returns matching providers collapsed one-per-ABN, each with registration_status, registration_groups, contact details, and an `offices` list (head office + outlets). `--name` is a case-insensitive substring; `--abn` ignores spaces. A provider trading under a brand name may be registered under its legal entity name — if a brand name returns nothing, try the operator's registered entity (e.g. the trustee/Pty Ltd name).

### 3. Registration-group reference

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/ndis.gov.au/provider-register.py groups
```

Lists the 36 registration groups (code → name → category). Each provider row's `RegGroup` is an array of these codes; the script decodes them inline, so this is only needed to browse the table or pick a `--group` filter term. The code→name table is baked into the script (extracted from the finder's JS bundle); refresh it from the bundle if group names ever change.

## Data fields (raw register row)

`Prov_N` name, `ABN`, `Head_Office` (text), `Outletname`, `Flag` (`H` head office / `O` outlet), `Active` (see above), `Phone`, `Website`, `Email`, `Address`, `State_cd`, `Post_cd`, `Latitude`, `Longitude`, `RegGroup` (array of group codes), `prfsn` (profession). Some rows show `CONFIDENTIAL` for the address where the provider withheld it.
