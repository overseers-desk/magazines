# Sessions: what a site skill declares, and how it fails

Most sites here are read while signed in. A skill that needs a session and finds none has to say so in a way a caller cannot mistake for an empty result. This document is the contract a skill author writes against; `COMMAND-SURFACE.md` carries the verbs, and this carries the session rules.

The failure it prevents: a caller reads a skill's output, finds nothing, and records "no Facebook presence" when what happened is that no Facebook page opened. Once that reaches prose, the distinction is gone.

## 1. A signed-in site ships a whoami probe

A site whose SKILL.md names a logged-in session as a prerequisite carries `skills/<site>/whoami.tcl`, a skill like any other, referenced as `<site>/whoami`.

It navigates once, names the account, and costs nothing else. It emits the canonical envelope with an `identity` key holding the site's own id for the signed-in account. `identity` is uniform across sites, so one caller reads one key whatever the site.

A signed-out page is a fault, never a result. The fault carries the `login_wall` shape.

`skills/linkedin.com/whoami.tcl` is the model to copy. Its siblings for `instagram.com` and `facebook.com` read a cookie rather than issuing a request, which is the cheaper shape where the site's cookie names the account.

## 2. An action declares its session need in its name

Every action file carries one of two action prefixes:

- `auth-` the action needs a signed-in session
- `pub-` the action runs signed out

The prefix is prepended to the existing name, which is otherwise left alone:

    send-invite.tcl    ->  auth-send-invite.tcl
    parse-search.tcl   ->  auth-parse-search.tcl
    keyword-search.tcl ->  auth-keyword-search.tcl
    parse-job.tcl      ->  pub-parse-job.tcl

Prepending keeps the rename mechanical and cannot collide, because the names it starts from are already distinct within a site. Shortening a name while prefixing it can collide: `parse-search` and `keyword-search` both reduce to `search`.

Both classes are marked. A file carrying neither prefix fails conformance rather than falling silently into the permissive class. The prefix travels on the reference a caller passes, so `browser-serialiser linkedin.com/auth-send-invite` states the dependency at the call site, in a dispatcher config, and in a log line.

An action that merely returns less when signed out is `auth-`. Partial data recorded as a finding is the failure this contract exists to prevent, and a caller cannot see the difference.

Two names are reserved and take no prefix. `whoami` is the probe this document defines. `login` mints a session and therefore runs signed out by definition.

Library files, which the harness never invokes because they define no `serialiser_run`, take no prefix.

`FLIGHT-SEARCH.md` uses "prefix" for the stderr message prefixes it defines. The two are unrelated; where this document says "prefix" bare, it means the action prefix defined above.

## 3. A missing session exits 77

An `auth-` action that finds no session exits **77**. One line on stderr names the site, the account expected, and the profile directory the browser opened:

    session missing: linkedin.com, expected ACoAAB1x, profile "Profile 2"

The caller reads the code, not the prose. A batch runner stops on 77 instead of writing a document that reads as complete.

The codes already in use here are 2, 3, 4, 5, 64, 65, 66, 75 and 78; `FLIGHT-SEARCH.md` documents the ones the flight skills share, and `bin/browser-serialiser` assigns 75 to a lock-wait timeout. 77 is reserved for this condition alone.

Where the harness has already classified the run terminal as `logged-out` or `checkpoint`, that classification is the session's absence and the action exits 77 on it.

## 4. Conformance is a test, and adoption is per site

`lib/session-contract-selftest.tcl` enforces the prefix rule on every site that has adopted the contract, and a site adopts it by carrying `whoami.tcl`. Presence of the probe is the opt-in, so no separate list of migrated sites exists to drift.

    tclsh lib/session-contract-selftest.tcl

Once a site has a `whoami.tcl`, every action in it carries a prefix or the suite fails. A new action added to an adopted site fails on the commit that adds it.

The test is red today. `facebook.com`, `instagram.com` and `linkedin.com` carry probes and none of their 35 actions carries a prefix yet. That rename is issue #38, and until it lands the failing run is the outstanding work rather than a regression.

Sites that name a signed-in session in their SKILL.md and have no probe yet are reported as a backlog line rather than a failure. That list is the remaining adoption work, and it is visible on every run rather than tracked elsewhere.
