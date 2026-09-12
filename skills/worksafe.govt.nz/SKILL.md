---
name: worksafe.govt.nz
description: "New Zealand's Adventure Activities public register: which operators are registered for an activity (horse trekking, rafting, climbing), with their registration and audit details."
allowed-tools: Bash
argument-hint: <activity term, e.g. horse>
---

# WorkSafe NZ Adventure Activities register

Every commercial adventure activity operator in New Zealand must be registered here before it can trade, so the register is the authoritative list of who operates an activity, not a directory anyone can join. Public, no login.

```bash
browser-serialiser worksafe.govt.nz/pub-register-search horse
```

The term matches the register's "Activity Provided" filter, so it is the activity rather than the operator's name: `horse` returns horse trekking operators, `raft` the rafting ones.

`result.pages` is one entry per page of the result grid, each carrying the grid's own table markup, up to six pages. `result.term` echoes what was searched. The rows are returned as markup rather than parsed fields, because the register's columns differ by activity and a caller reading one activity wants its own columns.

## How the page works

The register is a Dynamics CRM portal. Its filter field carries `id="2"`, a numeric id that no CSS id selector can name, so the field is reached through `getElementById`; a `#2` selector is a parse error rather than a miss, and reports as an uncaught JS exception. Results are server-rendered into `.view-grid table tbody` and paged by the portal's own Next link.
