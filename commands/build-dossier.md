---
description: "Deep source-cited dossier on a subject (person, business, family/principals, panel, entity warranting multi-section briefing). Briefing depth: multi-page, quotation-heavy, every claim sourced. Triggers: dossier, deep brief, in-depth profile, briefing-depth research, research file on a named subject."
argument-hint: <subject: a person, a business, a family + their business(es), a panel, etc; with whatever seed information is available, plus an output folder if known>
---

Subject to research (the command argument): **$ARGUMENTS**. If empty, ask the user for a subject before proceeding.

## What this command does

Produce a dossier deep enough that the next reader can chair a meeting, draft substantive correspondence, run a roleplay simulation, or make a contracting decision from it. The output is multi-page, source-cited, and quotation-heavy. Summaries do not pass.

The skill is subject-agnostic. The same depth discipline applies whether the subject is a panel chair, a small family business, a community elder, an institution, or a person-and-business unit. The output *structure* adapts to subject type; the depth rules do not.

Identification gates dossier production. If the subject cannot be confidently identified, halt and surface the search trace.

## Subject types

Pick the closest match before drafting; the dossier sections reorganise around it.

- **Person.** A named individual. Sections: biography, education, career, worldview, style, social media, networks, current focus, likely position on the question that prompted the dossier, simulation prompt.
- **Business.** A trading entity. Sections: legal identity, ownership and control, related entities, history, services today, public footprint, reputation and red flags, financial signals, networks, outlook, project relationship, implications.
- **Family or principals + business.** Two or more linked persons operating one or several shared trading entities. Sections: a principal-block per person (compressed but preserving voice), a business-block per business, family-business dynamics (relationships, succession signals, division of roles), project relationship across all of them. This is one dossier, not several stapled together.
- **Group, panel, committee.** A named multi-person body. Sections: institutional context, membership with a person-block per member, decision history, internal dynamics, project relationship.
- **Other named entities.** Unions, clubs, associations, trusts, government programmes - adapt the closest of the above. Lead with what the entity does and who controls it.

If two subject types apply at once (a person who also runs a business that is itself relevant), use the **family / principals + business** shape rather than two stapled dossiers.

## Underlying skills

Lookups dispatch through underlying skills, one haiku subagent per outlet, in parallel. Sonnet collects the bundle and writes the dossier.

- `linkedin.com` - LinkedIn person and company pages
- `facebook.com` - Facebook profiles, pages, posts
- `instagram.com` - public-facing feeds
- `email-check` - local IMAP via mu, for prior correspondence
- `otter.ai` - meeting transcripts the user has captured. When the project tree references a recording but the local cleaned-up transcript is missing or thin, run `otter.ai` first - voice and family dynamics live in dialogue, and a clean transcript is research infrastructure rather than a nice-to-have.
- WebSearch - general web, news, regulator gazettes, court records
- Local project search - rg across the named project tree for prior mentions in correspondence, contracts, leases, meeting notes

For business or group subjects, also:

- ABN / ACN registry (Australia: abr.business.gov.au)
- ASIC company search (Australia)
- OpenCorporates, Companies House, Secretary of State (jurisdiction-appropriate)

If a required underlying skill is genuinely unavailable, halt and report a setup issue. Do not improvise with raw browser commands.

## Inputs the skill accepts

- A name (person, business, group)
- A name + role + organisation
- A name + a relationship that constrains identity ("Janet's daughter, the one who runs the crystal shop")
- An email address
- A domain
- An ABN or ACN
- A meeting reference where the subject was named
- A pointer to a project folder where the subject already appears

The seed often combines several. A person-plus-business seed ("the X family and their motor shop") is common and triggers §1.2.

## §1. Identification

### 1.1 Local first, then registry, then external fan-out

**Step A - local project search (always first when a project context is named).** Run `rg -i` across the named tree for every variant of the seed names. Read every hit in full. Project files (correspondence, meeting transcripts, leases, contracts) carry signature blocks, ABNs on quote letterheads, family relationships stated in conversation, and the trading-vs-registered distinction already resolved by someone who actually met them.

For meeting transcripts referenced but not cleanly captured locally, invoke `otter.ai` before going external. Dialogue carries more about a family than press releases ever will.

If `email-check` is available, run it on every named principal in parallel with the project grep.

If the user's `contact_graph` Postgres DB is reachable (see `find-person` for connection details), query it for each named person.

**Step B - registry lookup (when subject is a business, or a person + business pair).**

- Australia: ABN registry. Free; gives ABN, ACN, registered name, trading names, GST status, principal place of business state.
- Australia: ASIC. Name search free; full director and document extract paid - flag cost before pulling.
- Other jurisdictions: OpenCorporates aggregator first; then Companies House (UK), Secretary of State (US, state by state), or local equivalent.

For person-only subjects, registry is rarely useful in the abstract - but if any external signal during fan-out indicates the person trades commercially (a Facebook business page bearing their phone, a LinkedIn "self-employed" entry, a trading domain in whois), the seed is effectively person-plus-business and registry corroboration becomes a hard requirement, not a side check. The trap: a sole-trader's social handle is often not their legal name; ABR / whois are the cheapest path to the registered name keyed to the same phone, email, or domain the seed already gave you.

**Step C - parallel external fan-out.** Dispatch one haiku subagent per applicable outlet in a single message. Each runs only its outlet, returns candidates or "no match", and Sonnet performs §1.3 verification across the bundle.

| Outlet | Person seed | Business seed |
|---|---|---|
| linkedin.com | Profile read at canonical URL; if URL unknown, search by name + organisation | Company page; named-employee search |
| facebook.com | Profile search by name + city; verify with name + employer + photo | Business-page search by name + suburb. Photos-tab read includes image content (vision-OCR), not only alt-text - business cards, decals, signage, name tags routinely sit at random positions in the gallery and carry the legal name, ABN, or address. |
| instagram.com | Only if the subject has a public-facing feed | Hospitality, retail, creative, automotive customisers |
| WebSearch | `"Full Name" {role-or-employer}`; news, talks, papers | `"Trading Name" suburb`; reviews, news, court records |
| Domain or website | If known | About, services, team, history, news pages |

Local project grep happened in Step A and is not re-run here.

### 1.2 Person-to-business resolution

When the seed names persons but the business is unknown ("the X family motor shop"), the path is: local project hit -> self-disclosed business name in transcript or correspondence -> registry confirmation -> external corroboration. Family relationships signal a join: two persons converging on one ABN or one Facebook page is strong evidence both belong to the same business unit.

### 1.3 Verify a candidate

A subject is confirmed when at least two independent signals corroborate. Signals include name match (allowing common variants and the registered-vs-trading distinction), location match, role or employer or director match, ABN or ACN match, a distinguishing detail from the seed, and direct self-disclosure in a project-internal source.

Independent means independent chain of evidence, not just two fields. A phone seed that lands on a Facebook business page whose linked LinkedIn handle encodes a name is one signal: phone, page, handle, and assumed name all trace back to one self-published chain. The name in a LinkedIn URL slug, a Facebook page handle, or an Instagram username is whatever the person registered, which may be legal, alias, former, or marketing - not a verified legal name. For sole-trader and small-business subjects this is acute, since the trading face is one person's social account; pull the registry corroboration before treating the social-profile name as the legal name (ABR ABN Lookup keyed to the seed phone or trading name; whois of any associated `.com.au` domain returns the registrant; equivalents apply in other jurisdictions). A name that conflicts between social handle and registry blocks the dossier rather than appearing as a footnote.

Same-industry collisions are a trap. Two handyman sole traders called John in nearby Brisbane suburbs is precisely the configuration where the social-handle-to-name leap fails: trade overlap reads as corroboration but is just a coincidence of two common names in one industry. When the seed's industry is densely populated with similar names, raise the corroboration bar; an unverified name carried into the dossier propagates through every section and forces a rebuild.

A single signal is not confirmation. Two near-matches in nearby suburbs are two candidates - surface both, do not pick.

### 1.4 Outcomes

- **Identified** - one candidate, two-signal confirmed. Record canonical particulars (name, role, organisation, ABN/ACN where applicable, primary URLs, project-internal references). Confirm the subject and the strength of evidence to the user, then proceed to §2. If identification was weak, pause briefly so the user can adjust the seed before further fetches are spent.
- **Multiple candidates** - present each with the strongest distinguishing detail and ask the user which one. Do not guess.
- **Unidentifiable** - report the search trace and the constraint that would unblock identification. Do not produce a dossier on an unconfirmed identity.

## §2. The dossier

Briefing-depth output: multi-page, source-cited, quotation-heavy.

### 2.1 Dispatch

In a single message, dispatch one haiku subagent per applicable outlet. Each subagent reads every relevant page in full (not just metadata), extracts direct quotes wherever the subject's voice is on the record, and returns raw material with URLs rather than a synthesised summary. Sonnet collects all replies and writes the dossier from the merged material. If a return is thin and the gap is closable (a session expired, a search returned none on the first variant), mount a second-round dispatch before drafting.

Image content is part of the read, not metadata around it. For subjects with a small-business Facebook, Instagram, or Google Maps presence, the Photos-tab subagent opens each image and reads it visually: a printed business card, a trade-vehicle decal, signage, a name tag on a uniform, an awards plaque, a captioned school photo, a uniformed group shot. These are primary-source identification artefacts and frequently carry the legal name, registered address, ABN, or named associate the dossier turns on. A Photos-tab pass that only ingests alt-text or filenames will miss the business card sitting at position 17 of 63; the cost of skipping is identifying the wrong person.

### 2.2 Output structure (adapt by subject type)

Frontmatter is mandatory: subject identifiers (name, role, ABN, etc.), `status: dossier`, `seeded_from`, `compiled` date.

A title image follows the frontmatter, embedded with markdown image syntax referencing a file in the same folder as the dossier. Priority: a face photograph confirmed as the subject; a business card, signage, or trade-vehicle decal bearing the subject's name; another identifying image (uniform name tag, awards plaque, school photo with caption, news photo with caption). For business and family-business subjects the business-card or signage image is often the strongest available, since sole traders rarely post their own face. The image file lives alongside the dossier (downloaded into the same folder), and the dossier inlines it with a relative path so the document is self-contained when read or copied. When no verifiable image of any of those kinds exists, record the absence inline with the search trace and the date - a stock image, generic page banner, or unrelated thumbnail is negative evidence dressed as positive and does not belong at the top of the dossier.

**Person dossier sections (single individual):**

```
## 0. Handle
Key-value table of identity facts (legal name, DOB, phone, email(s), trading as, ABN/ACN, postcode or address where on record, known key relationships). Then one paragraph of context: the briefing-equivalent of "if a journalist had 60 seconds, what is this person".
End with a Sources line listing the URLs used in the handle.

## 1. Biography
Residence, family where stated, faith and personal values where evidenced, hobbies, notable life events. Each non-trivial detail cited inline. Where unknown, mark `Finding: gap` and note what would close it.

## 2. Education
Every institution, degree, year, specialisation. Honours and scholarships. Mentors if discoverable. Where unknown, mark `Finding: not established` with the reasoning.

## 3. Career - chronological
Every role with dates and a paragraph on what the role meant in its field at the time. Annotate transitions: who recruited them, why they left, what the pattern reveals.

## 4. Worldview and political leaning
Every public stance on record. Quote directly, at length. Note what they champion, what they criticise, what they avoid commenting on. Flag partisan signals.

## 5. Personality and style
Voice register(s) with sample quotes. Sentence rhythm. Meeting behaviour as evidenced by colleagues. Conflict style. How they treat juniors, peers, adversaries. Humour, ego, patience, risk appetite.

## 6. Social media - full content review
Per platform: cadence, themes, representative quotes. What they author, what they amplify, what they ignore. Cross-platform corroboration: where one platform added detail another missed, where they conflicted, where verification failed.

## 7. Networks and relationships
Named individuals only. Each with a stated relationship mechanism. Connection counts are not evidence.

## 8. Current focus
Priorities and visible action, tied to named projects, funding rounds, strategy documents, recent posts.

## 9. Likely position
On the question that prompted this dossier, given §1-§8. What will land well; what will draw resistance.

## 10. Simulation prompt
A "you are <name>" paragraph in second person packing six to ten of their most telling habits. Useable verbatim by a roleplay agent.

## 11. Sources
Every URL grouped by source type (official bio, interview, social post, press, adversarial coverage, third-party). Flag dead, paywalled, or authenticated links.
```

**Business dossier sections (single trading entity):**

```
## 0. One-paragraph handle
## 1. Legal identity and registry footprint (ABN, ACN, registered name, trading names, GST status, addresses, history of name changes and ABN cancellations)
## 2. Ownership and control (directors, officers, shareholders, partners, beneficial owner, holding-trust layers)
## 3. Related entities (other businesses each principal is associated with, current and prior; pattern interpretation)
## 4. History (founding, location moves, expansions, ownership transitions, rebrands, each transition cited)
## 5. What they do today (services, target customers, scale, specialisations; tone and positioning quoted from their own marketing copy)
## 6. Public footprint (website, Facebook, Instagram, LinkedIn, Google Maps, news; per-platform cadence, voice, customer interaction quality)
## 7. Reputation signals and red flags (court records, regulator action, insolvency notices, customer-protection complaints; each marked [verified] with source or [rumour, unsourced])
## 8. Financial signals where visible (scale from employee count, fleet, premises, advertising, property history, ATO disclosures, tender awards)
## 9. Networks and connections (industry associations, chambers, sponsorships, named associates)
## 10. Outlook and positioning
## 11. Project relationship (every meeting, contract, invoice, message in the named project where the business or its principals appear; with date and outcome)
## 12. Implications for the user's decision
## 13. Sources
```

**Family or principals + business sections (two or more linked persons + one or several shared businesses):**

```
## 0. One-paragraph handle
Covers all principals and their business(es) as one unit; opens with the family relationship and the commercial relationship to the project.

## 1. The principals
One block per person, in order of seniority or relevance to the project. Each block contains a compressed person-dossier (handle, biography, career-relevant detail, worldview if surfaced in the project tree, personality and voice with direct quotes from any project-internal transcripts or correspondence, social-media review, current focus). Voice-capture matters: if the project has a meeting transcript with the principal speaking, quote multi-sentence excerpts that show their hedge words, register switches, and rhythm.

## 2. The business(es)
One block per business. Each block contains the Business sections (legal identity, ownership, related entities, history, services today, public footprint, reputation signals, financial signals).

## 3. Family-business dynamics
Relationships among the principals. Division of roles across the businesses. Succession signals (who is being groomed for what). Decision-making patterns where the project has observed them. Internal tensions if surfaced.

## 4. Project relationship
Every meeting, contract, invoice, message in the named project where the business or its principals appear. Across all principals and all businesses, woven into a single timeline. Each entry: date, who was present, topic, outcome, outstanding items.

## 5. Outlook
What is each principal currently focused on; what is each business positioned for; how is the family unit changing.

## 6. Implications for the user's decision
Risk and reward in plain language. Where evidence is thin, say so.

## 7. Sources
Every URL and project-internal reference, grouped by source type. Flag dead, paywalled, or authenticated links.
```

**Group, panel, committee sections:**

```
## 0. One-paragraph handle
## 1. Institutional context (charter, founding, current authority)
## 2. Membership (one person-block per member, compressed)
## 3. Decision history (concrete decisions with dates, votes if known, dissents)
## 4. Internal dynamics (alliances, factions, named tensions, succession patterns)
## 5. Project relationship
## 6. Implications
## 7. Sources
```

### 2.3 Output target

If the request named a folder, write `<folder>/<slug>.dossier.md`. Slug: subject's last name, family surname, or business slug, lower-case-hyphenated. Where the surrounding folder has a sibling `.seed.md` shape established, follow it.

If no folder was named, return the dossier in the conversation. Default to `/tmp/<slug>-dossier.md` only if length makes inline return awkward, and ask before writing.

## §3. Depth discipline

These rules drive a dossier to briefing depth without naming a word count. The dossier is finished when the source material is exhausted, not when a section count is reached. A thin source set produces a shorter dossier honestly; a rich set produces a longer one.

- **Read every public source in full.** Summarising before quoting loses voice. If a public quote, post, interview, or article exists, read the whole text and pull the lines that reveal voice or position.
- **Image content is source material.** For subjects with a small-business Facebook, Instagram, or Google Maps presence, every image on the Photos tab gets a vision read, not just an alt-text or filename pass. Business cards, decals, signage, name tags, awards plaques, and uniformed group shots carry primary-source identifiers (legal name, ABN, address, named associates) that text-only scanning misses. A photo of a printed business card is often the cheapest path to confirmed identity for a sole-trader subject and to a usable title image for the dossier.
- **Cite every claim.** A claim without a URL or project-internal reference is a guess. Lines that cannot be sourced are dropped or marked `[unsourced]` and listed as a gap to close.
- **Quote directly and at length.** Direct quotes are evidence; paraphrases are claims. When the subject is on the record at length, quote multi-sentence excerpts that include their hedge words, register switches, and rhythm. A one-line snippet of a paragraph-long statement is rarely enough.
- **Capture voice.** Identify recurring phrases, rhetorical tics, register switches. Five examples per public-facing subject is a reasonable floor.
- **Enumerate, do not summarise.** Every role, every public statement in the last 24 months, every related entity, every meeting in the project tree, every named connection. Lists earn their place when the items are not interchangeable.
- **Structured facts use tables.** When a section holds a set of key-value items (identity fields, alias roster, platform accounts, court-record runs, scale signals), render it as a table rather than prose enumeration. The test: can a reader extract a phone number, email, or URL in three seconds?
- **Pattern interpretation belongs in the dossier.** "Stays involved through a looser tether" is more useful than "has held many roles". Inference is welcome where it is named as inference and grounded in cited evidence.
- **Show the search trace, not just the hits.** Each platform a comparable subject plausibly uses (LinkedIn, Facebook, Instagram, X, TikTok, YouTube, plus industry-specific: Etsy for makers, AutoGuru for trades, Google Maps for any premises) gets its own line per subject. URL plus per-platform metrics when found (followers, following, posts, reviews, page rating); `Checked: not found` with the queries used and the date when absent. Topics the subject has not spoken on, platforms they do not use, and searches that returned nothing belong on a visible line, not in white space.
- **Scale signals.** For business and family-business subjects, on each business block: employees on record, premises (size, room or bay or table count), fleet or vehicle count, customer-count proxies (rating count, review count, follower count, member count), year founded, current trading status. Each on its own line, value when found, `Checked: not on record` when searched and absent.
- **Cross-platform corroboration.** Where one platform added a detail another missed, where they conflicted, where verification failed - each is recorded in the relevant section with both sources cited.
- **Findings markers.** Use `Finding: established`, `Finding: gap`, or `Finding: not established` to make the resolution status of each section legible to the next reader. A gap is informative; a fabrication is not.
- **Project-internal evidence is a first-class source.** Meeting transcripts, contracts, and signed correspondence carry primary-source weight, often higher than public marketing material. Cite them by file path, with the dialogue quoted directly when voice or family dynamics are at stake.
- **Trust posture: validate, do not echo.** When the dossier's purpose is to assess a counterparty, lessee, supplier, or other commercial partner, the dossier validates rather than relays. Every claim that originates from the subject's own statements (meetings, emails, marketing copy, pitches) is tagged with its evidence state, inline in brackets. `[verified]` when an independent source corroborates. `[unverified]` when independent corroboration would be possible but has not been done. `[unverifiable]` when no public source could plausibly corroborate (private financials, internal staffing claims, claims about prior employer relationships not on public record, self-claims of character or skill). Citing a meeting transcript is not the same as verifying the content of what was said in it; the dossier shows which is which. For briefing-and-simulation dossiers (panel members, public figures, interview subjects whose words *are* the data), the goal is voice and prediction rather than fact-adjudication, so the tagging is optional, but the source citation remains.
- **Read the meeting staging file with caution.** Cleaned meeting summaries written by an LLM from a raw transcript can drift, especially in framing of who someone *is* (collapsing one observed skill into an identity label). Treat staging-file framings as a first read of the meeting, not as ground truth about the subject. Where the dossier disagrees with the staging file's framing, surface the divergence in the project relationship section.
- **Active verification, not just absence-noting.** When a self-claim is load-bearing for the dossier's purpose (top franchisee, shaped policy, integral to a sector reform, managed N staff, ran $X turnover), attempt verification by triangulation rather than tagging `[unverified]` and moving on. Triangulation steps: list the comparable population (top-performing franchises at the time, named policy authors, comparable industry peers); locate the subject through their public traces (Facebook check-ins and tagged friends, school affiliation, professional-body register, family network); cross-reference whether the subject appears where the claim would put them. The result of the attempt - hit, miss, partial - is the line that goes in the dossier. "Searched the comparable population and the subject's name does not appear" is more useful than `[unverified]` alone because it shows what was tried and what would close the gap.
- **Compilation is the author's work, not the subject's.** Information-finding can come from the subject's own statement (what they did, where they lived, what they earned). Compilation - estimating age from signals, ranking a franchise's claimed performance against external lists, mapping a stated fact against a registry, estimating staff size from observable evidence - is the dossier author's job. Filter signal from noise rather than echoing the subject's framing. When estimating, show the reasoning chain (e.g. *age 55-65 based on oldest child's ABN registration 13 years ago, plus typical motherhood-age range, plus a pre-2010 secondary-school director role that required years of credentials*) so the reader can pressure-test the inference.
- **The dossier reads standalone.** Readers are not given the build-dossier command source. Cross-references inside the dossier use the dossier's own section names ("see Career chronology") rather than the command's `§N` numbers, which to a fresh reader read as pointers to a different dossier. Where evidence given inline can answer a question, repeat it lightly rather than cross-pointer.

## §4. Constraints

- **No invention.** A claim without a source does not appear in the dossier.
- **No fabricated quotes.** A paraphrase represented as a quote is invention.
- **Adversarial framing demands a source.** Negative material is recorded only when verifiable. Suspected-but-unsourced items go in a gap list.
- **Family-relationship claims need a source.** "Mother and daughter" is a registry, social, or correspondence claim, not an inference from shared surname.
- **Status drift.** A trading name found in old correspondence may now be cancelled, sold, or rebranded. Confirm current status from registry before treating the entity as live.
- **Identification gates everything.** If §1 ends in "unidentifiable", do not run §2. Surface the trace.
- **Connection counts are not evidence.** Specific named relationships only.
- **Masked emails are not emails.** A data-broker `b***@example.com` is a hint, not an address.
- **Person vs role.** If the named person no longer holds the role the user is asking about, surface the mismatch before producing a dossier on a no-longer-relevant party.
