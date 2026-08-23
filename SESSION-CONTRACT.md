# Sessions: what a site skill declares, and how it fails

Most sites here are read while signed in. A skill that needs a session and finds none has to say so in a way a caller cannot mistake for an empty result. This document is the contract a skill author writes against; `COMMAND-SURFACE.md` carries the verbs, and this carries the session rules.

The failure it prevents: a caller reads a skill's output, finds nothing, and records "no Facebook presence" when what happened is that no Facebook page opened. Once that reaches prose, the distinction is gone.

## 1. A signed-in site ships a whoami probe

A site whose SKILL.md names a logged-in session as a prerequisite carries `skills/<site>/whoami.tcl`, a skill like any other, referenced as `<site>/whoami`.

A lane opening runs the probe, always. Whether the operator opened the lane or a consumer opened it at startup, `<site>/whoami` runs before work does. No site is exempt because its probe costs a request: making the probe cheap is the skill's job, and what each site pays is §4.

Between opening and closing, ordinary work reports identity on every run (§4), so a running lane learns its session died from the next job rather than from a separate probe.

The probe navigates once and names the account. It emits the canonical envelope with an `identity` key holding the site's own id for the signed-in account. `identity` is uniform across sites, so one caller reads one key whatever the site.

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

The codes already in use here are 2, 3, 4, 5, 64, 65, 66, 75 and 78; `FLIGHT-SEARCH.md` documents the ones the flight skills share, and `bin/browser-serialiser` assigns 75 to a lock-wait timeout. 77 is this condition alone: `bin/browser-serialiser` exits it on a `logged-out` or `checkpoint` wall, and 66 keeps the walls that are not about a session.

Where the harness has already classified the run terminal as `logged-out` or `checkpoint`, the action exits 77 on it. The two share the code and differ in the line, because what a person does about them differs: a `logged-out` wall is one account's, and a sign-in clears it, so the line names the account and the profile; a `checkpoint` is the site challenging this browser, no sign-in clears it, and every account on that site is stopped, so the line says that instead.

    session missing: linkedin.com, expected ACoAAB1x, profile "Profile 2"
    checkpoint: linkedin.com is challenging this browser, profile "Profile 2"

A caller that has to act on the difference reads the line, or, where it runs the harness rather than the command, the terminal classification the harness raises.

## 4. An auth- action reports the identity it saw

Every run of an `auth-` action names the account the page was rendered for, in the same `identity` key `whoami.tcl` emits, as a sibling of `result` in the envelope:

    {"result": {...}, "identity": "1569557680", "cursor": null, "hasMore": false, "fault": null}

It sits beside `result` rather than inside it, so one caller reads one place whatever the site returns, and no site's result shape has to make room for it.

The key has three states and a caller acts differently on each:

- **absent** the site declares no identity source, and never had an account to name.
- **null** the site was asked and named nobody. A signed-out page reads this way, and so does a read that failed.
- **a string** the account the page was rendered for.

A fault carries no identity key at all. Its shape says what went wrong, and a run that failed before it navigated has no page whose viewer to name.

The point is that work becomes the liveness check. A caller that reads `identity` on every signed-in run learns the session died from the first run after it died, rather than from the first run that went looking. On 22 August the session died at 05:20 and the loss surfaced at 05:57; the documents written in between are the cost of that gap.

An action that lands on a signed-out page reports nobody and exits 77 (§3). It does not proceed and it does not return a partial result.

This section reaches sites with a login, which are the sites carrying `whoami.tcl` (§1). A site nobody signs in to has no `auth-` action and no probe, and is outside it. `csair.com` prices flights signed out and has no account to name; that is the site's shape, not a gap in it.

Within the sites that do have a login, one that cannot name the signed-in account says so in its SKILL.md, and its `auth-` actions are then held to §3 alone. Read that declaration as a defect awaiting a fix rather than a settled shape: a site serving pages to a signed-in person almost always says who they are somewhere, and a skill that cannot find it has usually not looked in the right place. The declaration exists because a few sites genuinely do not say, and a rule with no exception would be obeyed with a guess.

What this costs differs by site, and the cheap shape is not available everywhere:

- `instagram.com` reads `ds_user_id` from `document.cookie`. No request. `ig_viewer_id` in `ig-canonical.tcl` already does it.
- `facebook.com` reads `c_user` the same way, as `whoami.tcl` does.
- `linkedin.com` has no cookie naming the member. The reliable source is `own_profile` in `li-canonical.tcl`, one request against `/voyager/api/me`. Three actions already pay it. For the rest, read it once per browser lease and reuse it: the profile cannot change under a lease, so the cost is one request per lease rather than one per action. A session that dies mid-lease still walls the read, and §3 catches it there.

A profile page's legacy `urn:li:member:NNN` often carries the viewer's own id, but only often. It is not the source for this.

## 5. A null identity on an auth- run means the result is not trustworthy

The wall the harness raises is the site's own evidence, and a site that wants to serve a signed-out page without saying so gives none. `skills/facebook.com/SKILL.md` records that case: a public profile served at 200, on an ordinary URL, whose `<title>` reads like a real page while the page config carries `"USER_ID":"0"`. The URL test never fires and the title test is fooled, so a caller waiting for a wall waits for something that is not coming. The page is not walled at all; it is served, and it is empty of the viewer.

The rule that covers it is the caller's, not the harness's. A result from an `auth-` action whose `identity` key is present and null is not to be trusted, whether or not a wall was raised. That page carries no account cookie either, so identity is null exactly where the data is not to be trusted.

The key being present is half the rule. A site that declares no identity source omits the key, so its results are not caught by this; it never claimed to know who was signed in. A caller that treated an absent key as a null one would distrust every result from every site with no reader, which is most of the tree.

The rule is scoped to `auth-` actions. A `pub-` result never had an identity to lack, and a site with no login runs nothing else, so applying it wider would distrust every result from most of the tree.

Within `auth-`, a present null has two causes and both want the same answer. The page was signed out, which is the case the rule is for. Or the read failed, and an authenticated result that cannot be shown to be authenticated is one to hold. Those two are not distinguishable from the envelope.

How strong the evidence is depends on what the site's reader costs, which §4 lists. Where the account comes from a cookie, a failed read means the cookie was absent, which is being signed out, so a present null is close to proof. Where it comes from a request, a failed request is the commoner cause, so a present null is a reason to look rather than a verdict. A caller that stops work on it wants a way to start again without a human, since a stop taken on the weaker evidence is one it will sometimes take wrongly.

What a caller holds on is the account the job asked for, not one the page named. There is no name on the page; that is the fact the rule fires on.

## 6. Conformance is a test, and adoption is per site

`lib/session-contract-selftest.tcl` enforces the prefix rule on every site that has adopted the contract, and a site adopts it by carrying `whoami.tcl`. Presence of the probe is the opt-in, so no separate list of migrated sites exists to drift.

    tclsh lib/session-contract-selftest.tcl

Once a site has a `whoami.tcl`, every action in it carries a prefix or the suite fails. A new action added to an adopted site fails on the commit that adds it.

`facebook.com`, `instagram.com` and `linkedin.com` are adopted, and the test passes on 39 actions: 35 carrying a prefix, plus their three probes and one `login`, which are reserved.

Sites that name a signed-in session in their SKILL.md and have no probe yet are reported as a backlog line rather than a failure. That list is the remaining adoption work, and it is visible on every run rather than tracked elsewhere.
