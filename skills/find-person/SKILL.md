---
name: find-person
description: "Identify a person from partial info (name, organisation, industry, location, known experience, email, approximate/heard spelling), then on instruction produce a lightweight profile or full dossier. Triggers: find/identify/look up/research a person, build a dossier."
argument-hint: <seed: full name, name + organisation, email, name + industry + location, etc.>
---

## What this skill does

Identification first. Profile and dossier are optional follow-on steps that depend on identification succeeding. If the person cannot be identified, halt - there is no profile or dossier to build on an unconfirmed identity.

## Underlying skills

This skill orchestrates lookups; it does not perform browser fetches itself. Each outlet is invoked through a haiku subagent and the outlets are dispatched in parallel - the calling sonnet model collects their replies and performs the identification synthesis. Outlets:

- `linkedin.com` - LinkedIn search and profile reads
- `facebook.com` - Facebook search and profile reads
- `instagram.com` - for people whose Instagram is a public-facing channel
- built-in WebSearch - general web search and email reverse lookup

- email-check: - local IMAP search via [mailroom](https://github.com/SmartLayer/mailroom/) or mu, when the user has prior correspondence to consult

Parallel dispatch: launch one haiku subagent per applicable outlet for the same target in a single message (multiple Agent tool uses in one block). Each subagent runs only its assigned outlet's lookup and returns its candidate(s) or a "no match" reply. Sonnet receives the bundle and performs identification (§1.3-§1.4). Cross-outlet rate-limit concerns belong inside each underlying skill, not at this orchestration layer.

If a required underlying skill is genuinely unavailable in the environment, halt and report a setup issue. Do not improvise with raw browser commands.

## Inputs the skill accepts

The seed can be any of:

- Full name (often ambiguous; expect to ask for a constraint before searching)
- Name + organisation
- Name + industry + location
- Name + a piece of experience the user remembers ("the person who used to lead engineering at Stripe")
- Name with possibly-misspelt or heard-not-read spelling
- Email address (reverse lookup to find the owner)

Strong identifying constraints in rough order of usefulness: organisation > unique role + city > industry + city > industry alone. A name-only seed is treated as ambiguous unless the name is genuinely rare.

## 1. Identification

### 1.0 False-positive guard for common names

A first name without a surname nor organisation name is likely to lead to false positive - search anyway but only consider the result a hit if the person is already connected or have significant fact alignment. Failure example: search "Michael" in a single town - guaranteed to hit mostly false positive - and report to user any unconnected candidate without significant other-fact alignments.

When the target can only be found through a known associate (e.g. "Michael, husband of Jane Doe"), find the associate first and extract the target from their profile. Do not run parallel searches for both as if they are equivalent seeds: the associate is the strong seed, the target is derived from it.

If the only seed is a first name with no surname, no employer, and no unique role, the seed is insufficient. Ask the user for a stronger constraint before searching.

### 1.1 Local contact graph first, then parallel fan-out

If a local contact graph is available (~/code/contact-graph), query it first by email or name; a hit there is free and often decisive, and your global instructions say how to reach it. When it is absent or does not resolve the seed, fan out: dispatch one haiku subagent per applicable outlet in a single message. Each subagent receives the seed and the per-outlet query pattern below, runs only its outlet, and returns the candidate(s) or a "no match" reply. Sonnet collects the bundle and performs §1.3 verification across all replies together - a name match in one outlet may be confirmed by a corroborating signal in another.

| Outlet | Query pattern |
|---|---|
| linkedin.com | Search by name plus the strongest constraint in the seed. When a candidate URL is already in hand, fetch the profile directly - direct URL views are not subject to LinkedIn's search-rate protection. |
| facebook.com | Search by name plus employer or full name. City alone is not a useful filter for common names. For small-business pages surfaced by phone or trading-name seeds, the Photos-tab read includes image content (vision-OCR), not only alt-text or filenames. Business cards, trade-vehicle decals, signage, name tags, and awards plaques routinely sit at random positions in a 60+ image gallery and carry the legal name, ABN, or address that resolves identity. |
| instagram.com | Search by name or known handle. Most useful for people whose Instagram is a public-facing channel (creators, founders, public figures). |
| WebSearch | `"Full Name"` plus the strongest constraint. For an email seed, search the address in quotes; data-broker results often surface the owner. If the literal address returns nothing, search the local-part (the bit before `@`) as a username, and check the domain for an organisation. |
| Registry / whois | For a phone, email, or domain seed that lands on a sole-trader or small-business candidate, pull the registry record before treating the social-profile name as the legal name. Australia: ABR ABN Lookup (free) accepts trading-name searches and returns the registered legal name; whois on a `.com.au` trading domain returns the registrant. Other jurisdictions: OpenCorporates aggregator, then the local register. |
| `email-check` | Search local IMAP for the seed name or email - surfaces prior correspondence and signature blocks. Run it for non-email seeds too. |
| Organisation website | If the seed names a small or medium organisation, fetch its about, team, and contact pages. |

Spelling-variant generation (§1.2) happens inside each haiku subagent - pass the variant set with the seed so each outlet searches them all.

### 1.2 Spelling variants for misspelt or heard names

The `linkedin.com` skill's "Search variants for hard-to-find people" section lists romanisation families (Lin/Lim/Lam, Mazumdar/Majumder, etc.) - consult it before composing your own. For seeds that came from speech rather than writing, also try:

- Vowel ambiguity: Sara/Sarah, Catherine/Katherine, Steven/Stephen, Jon/John
- Consonant pairs: Phil/Fil, Chris/Kris, Schmidt/Smith, Sean/Shawn
- Diacritic and transliteration forms: Müller/Mueller, Renée/Renee, Joao/João

### 1.3 Verify a candidate

A candidate is confirmed when at least two independent signals corroborate:

- Name match (allowing for the variants in §1.2)
- City or region match
- Employer match
- A distinguishing detail from the seed (specific role, project, school, year of a known event)

Independent means independent chain of evidence, not just two fields. A phone seed that lands on a Facebook business page whose linked LinkedIn handle encodes a name is one signal: phone, page, handle, and assumed name all trace back to one self-published chain. A LinkedIn URL slug, a Facebook page handle, or an Instagram username is whatever the person registered, which may be a legal name, an alias, a former name, or a marketing label - not a verified legal name. When the seed admits a registry corroboration (a sole trader's phone, a small-business email, a trading domain), pull the corroboration before treating the name as confirmed; ABR / whois / OpenCorporates returns the registered legal name keyed to the same identifier the seed already gave you. A name that conflicts between social handle and registry blocks the dossier rather than appearing as a footnote.

Same-industry collisions are a trap. Two handyman sole traders called John in nearby Brisbane suburbs is precisely the configuration where the social-handle-to-name leap fails: trade overlap reads as corroboration but is just a coincidence of two common names in one industry. When the seed's industry is densely populated with similar names, raise the corroboration bar rather than lower it; an unverified name carried forward propagates through every section and forces a rebuild.

A single signal is not confirmation. Two profiles with the same name and city but different employers are two candidates, not one - present both, do not guess.

### 1.4 Outcomes

- **Identified** - one candidate confirmed by at least two signals. Record full name, current role, organisation, location, and the canonical URL (LinkedIn vanity URL preferred). Proceed to §2.
- **Multiple candidates** - present each with the strongest distinguishing detail and ask the user which one. Do not pick.
- **Unidentifiable** - the §1.1 parallel fan-out (with §1.2 spelling variants where the seed warranted them) returned no candidate that clears §1.3's two-signal verification. Stop. Do not proceed to profile or dossier. Tell the user which outlets were queried, which returned name-only matches that failed verification, and what additional constraint would unblock the search (organisation, city, industry, year of a known role).

### 1.5 Person vs. role

If the seed names a role rather than a person ("the head of X at Y"), identify whoever currently holds the role. Sources the user is remembering may be stale; the answer is the current holder. If the named person no longer holds the role, surface the mismatch before proceeding - the user may want to redirect to the current holder.

## 2. Confirm and choose the goal

After identification:

1. Tell the user who was identified and the strength of evidence.
2. If the original request did not name a goal, ask the user: identify only, lightweight profile, or full dossier?
3. If the original request named a goal (e.g. "build a dossier on X"), proceed to that goal without re-asking - but pause if identification was weak so the user can adjust the seed before more fetches are spent.

If the user chose identify-only, stop. The output is the record from §1.4.

## 3. Lightweight profile

Adequate to write a thoughtful first email or decide whether to spend further time on the person.

Dispatch in parallel (one haiku subagent per outlet, in a single message):

- LinkedIn profile via direct URL (use the `linkedin.com` skill)
- WebSearch for the person's name plus any topic the user named (talks, articles, GitHub if technical)

Sonnet merges the replies. If the LinkedIn parse surfaces an additional topic worth a search, run a second-round WebSearch then.

Record:

- Confirmed identity (name, current role, organisation, location)
- Last 2-3 roles with dates
- Education and certifications
- One or two recent public statements with quote and source, if any exist
- Contact channels visible to the public (LinkedIn URL, organisational email if listed, organisational phone if appropriate)
- One line on what the person currently focuses on, drawn only from the material in front of you

Output: markdown in the conversation. Do not write a file unless the user asks.

## 4. Full dossier

Adequate to brief someone before a meeting, decide whether to involve the person in a strategic project, or write substantive correspondence that engages with their stated work.

Dispatch in parallel (one haiku subagent per outlet, in a single message):

- LinkedIn profile via direct URL.
- Facebook profile, with two-signal verification (name plus at least one of city, employer, profile photo). If the match cannot be verified, record "Facebook: no verified match" and do not use unverified data.
- Instagram, only if it is a public-facing channel for this person (creators, founders, public figures). For people whose Instagram is personal-only, the parsed fields are usually noise.
- Employer's website (about, team, programmes pages) for institutional context.
- WebSearch for `"Full Name" topic-keywords` and `"Full Name" organisation` - catches conference talks, blog posts, papers, media quotes, GitHub activity that LinkedIn does not show.
- `email-check` for any prior correspondence in the user's IMAP mail.

Sonnet collects all replies and writes the dossier from the merged material.

Record everything in §3, plus:

- Title image, embedded at the top of the dossier with markdown image syntax referencing a file in the same folder. Priority: a face photograph confirmed as the subject; a business card, signage, or trade-vehicle decal bearing the subject's name; another identifying image (uniform name tag, awards plaque, school photo with caption). For sole-trader and small-business subjects a business-card or signage image is often the strongest available, since the person rarely posts their own face. When no verifiable image of any of those kinds exists, record the absence inline with the search trace and the date; a stock image or generic page banner is negative evidence dressed as positive and does not belong in the dossier.
- Full career history with dates and a one-line note on each role
- Volunteer and mentorship roles
- Public statements: quote or close-paraphrase, with source. When the person has written articles or given talks, extract the specific recommendations or proposals they made - do not collapse them into a summary of the framing.
- Named connections: each is a person with a stated relationship mechanism (tagged in a post, co-organiser of an event, named co-author, predecessor in their current role). Connection counts ("500+ connections") are not evidence and do not belong in the dossier.
- Institutional context: the employer's mission and the programmes the person is personally involved in versus those run by their team or organisation more broadly.
- Recent activity: posts, conference appearances, publications within the past 12 months.
- Absent themes: topics the user named or the obvious campaign-adjacent topics on which the person has not spoken. Recording an absence is informative; inventing a position is not. If the person has said nothing on a topic, say so.
- Cross-platform corroboration notes: where Facebook or Instagram added detail, where they conflicted with LinkedIn, where verification failed.

Output: a markdown document, returned in the conversation by default. If the dossier is long enough that the user would prefer it on disk, ask where to write it; absent a path, default to `/tmp/{slug}-dossier.md`. Do not write into a project tree without an explicit path.

## 5. Constraints

- **No invention.** If you cannot find evidence for a claim, do not write the claim. "No public statements on X" is a valid line; a fabricated quote is not.
- **No connection counts as evidence.** Specific named relationships only.
- **Email format gate.** If you find what looks like an email, it must contain `@` and a plausible domain. Contact-form URLs, phone numbers, and placeholders are not email addresses; record them under a contact section, not as the email.
- **Masked emails are not emails.** A data-broker result like `b***@example.com` is a hint about a pattern, not a usable address. If the unmasked form cannot be verified, leave it unrecorded.
- **Person vs. role.** If profiling shows the named person no longer holds the role the user is asking about, surface the mismatch rather than producing a dossier on a no-longer-relevant party.
- **Identification gates everything.** If §1 ends in "unidentifiable", do not run §3 or §4. The user gets the search trace and a request for a stronger constraint.
