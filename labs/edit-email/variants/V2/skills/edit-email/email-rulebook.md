# email-rulebook

Rules for drafting and polishing email on the user's behalf. CLAUDE.md applies concurrently (newspaper, SDT, NSWP, LHD, Densify) and is not restated.

## R1. Identity and ask up front

The first paragraph names the sender and how the recipient has the sender's address. The second sentence or the start of the second paragraph states the ask in one sentence: what the recipient is being asked to do, and the headline fact that motivates it. Topic is not ask. "I am writing about my mortgage" is topic; "I have paid the stated arrears and need help getting the bank to confirm receipt" is ask. Supporting details, dates, references, and adjacent problems come after. A draft whose ask appears only after several paragraphs of background has buried its thesis under chronology; the subeditor queries the caller to move the ask up.

## R2. One ask, as prose

State the request as a sentence inside the prose. Numbered or bulleted lists of requests turn email into project; project-shaped mail is deferred behind email-shaped mail. If the requests cannot reduce to one inquiry, the email is the wrong tool.

## R3. Situation and ask, not recipe

State the situation and what is needed. Don't prescribe how a professional should do their work. Recipe text reads as patronising and signals "this will take effort".

## R4. Secondary and tertiary concerns

The primary ask is the trunk. Facts that directly support the ask are primary; facts that support those are secondary; facts that support those are tertiary. A secondary or tertiary fact sometimes can't earn the recipient's attention and tends to carry sender-only context that does not travel. The subeditor walks each fact back to the primary ask and queries (does not silently cut) any that sit at secondary or tertiary depth, unless the primary ask cannot be understood without them. The caller decides whether to ground the fact in one sentence or to remove it.

## R5. No session-anchored timestamps

"Today", "this morning", "yesterday" anchor to when the sender wrote the message. The reader cannot place that. Anchor to events the email itself names (a dated letter, a prior message), or drop the time reference. Do not invent a calendar date as a replacement; if no anchor exists in the draft, query the caller.

## R6. Faithful surface for borrowed facts

The user's words are data. Paraphrase that adds ownership, status, specificity, or detail is inference. The subeditor cannot verify this against a brief it does not have; where the draft contains a paraphrasable fact (an ownership claim, a residency status, a numerical value, a date, a relationship), the subeditor queries the caller and the caller checks the brief.

## R7. Volunteer only what advances the ask

Each fact in the draft should be there because the ask depends on it. Incidental facts widen the project surface and give the recipient something to misread.

## R8. The mail acts; it does not narrate the act

A sentence narrating what the email is doing, or hedging on the recipient's behalf, is doing the recipient's work out loud. Cut. (See CLAUDE.md SDT.)

## R9. Sender identity match

Send from the address the recipient most likely has indexed against the user's file. The right `From` makes the recipient's reflex search hit; a mismatched one forces a content search that may not surface the file. When the body claims an identity tied to prior correspondence and the `From` does not match that history, the subeditor queries the caller.

## R10. Reader's pace

Email is read fast, not literarily. Long sentences and convoluted clause structure can be optimised for sounding serious; the unintended effect is to slow the reader down and make the message hard to scan. A reader should be able to grasp each fact on first pass. The substance stays serious by being clear, not by being slow.

The underlying principle is **dependency distance**. Each grammatically-linked pair of words — subject and verb, modifier and head, verb and particle, noun and its qualifier — should sit as close together as possible. The reader holds a head word in working memory until its dependent arrives; the further apart they sit, the more effort the bridge costs. Compose in dependency grammar (head–dependent links), not phrase structure grammar (slotting clauses into NP/VP positions). Subjects beside verbs. Modifiers beside heads. Particles beside the verbs they belong to. Qualifiers beside the nouns they qualify.

Specific patterns this principle exposes:

- **Two-idea sentences joined by ", and" or extended by em-dash.** Each clause has its own subject and verb; separating them lets every dependency sit close. Split.
- **Nominalisation: verbs hidden inside abstract noun phrases.** "The site has surfaced flood-resilience considerations that need designing into the brief" hides the verbs (*design*, *be on a river*) inside the nouns *considerations* and *site*. Find the verb the sentence is actually about and lead with it: "The site is on the river, so we have to design for flood and weather before locking specifications." Same fact, half the reading time.
- **Setup-before-subject.** Clauses that delay the subject behind a positioning phrase widen the subject–verb dependency. Lead with the subject.
- **Subject and verb separated by an intervening clause.** "The supplier, despite having received multiple notifications, has not finalised their acceptance terms" suspends the reader between *supplier* and *has not finalised*. Move the intervening clause out of the middle.
- **Modifier far from head.** "Acceptance terms for the new equipment" — when an adjective phrase qualifies the wrong noun on first read (here the reader can parse "terms for the new equipment" as terms about the new equipment, not terms governing the return of the old equipment), the qualifier is too far from its true head. Recast so the qualifier sits next to what it modifies.
- **Adverbial weight without fact.** "Substantively", "essentially", "ultimately", "in effect", "broadly" — cut unless the adverb carries a fact the sentence loses without it.
- **Stacked compound noun phrases.** "Closing the supply agreement out on contract terms" stacks three noun phrases without verbs to anchor them. Pick the load-bearing one or recast as a verb.

R7 still applies: shorter does not mean dropping facts the ask depends on.

## Director register (D-rules)

Applies when the caller marks the draft as director-to-staff (the editor-prompt's `REGISTER` slot says so). The relationship is one direction: a decision arrives, the recipient implements. The R-rules above continue to apply concurrently.

### D1. Soft closes that invite back-and-forth the writer did not invite

A closing line offering further discussion, encouraging follow-up, or volunteering the writer's availability re-frames a directive as a proposal and leaves the recipient owing a reply. Cut unless the body itself contains a real open question. The rule cuts AI-trained openness; it does not cut genuine asks.

### D2. Decisions stated as decisions

A decision in the source draft stays a decision in the email. Hedging that softens "we are doing X" into "we are thinking about X" shifts authorship from sender to recipient and leaves the recipient unclear whether implementation is wanted. Soften only what the draft already softens.

### D3. Don't decide in the recipient's domain

A director's mail to a professional states constraints and outcomes, not the implementation. A sentence that picks the cloud, the brand of equipment, the booking form layout, or the accounting treatment trespasses on the recipient's craft and signals distrust. Strip such sentences unless a constraint the recipient cannot derive (a regulatory rule, a protocol quirk, a contractual term) requires the specific choice; then state the constraint, not the chosen response.

### D4. Explain the outcome, not defend the action

Where reasoning belongs, the email gives the outcome frame ("X fits because Y") rather than the deliberation narrative ("I considered alternatives, weighed them, and concluded X"). The narrative form reads as the director arguing for permission, which inverts the relationship. Where the source draft contains no reasoning, the email contains none.

### D5. Closing matches register

Internal director-to-staff mail closes with the writer's name. Ornamental sign-offs ("Best regards", "Warm regards") and anticipatory thanks ("thanks in advance") belong to peer or vendor register; here they read as the writer adopting the manners of the wrong relationship.

### D6. Approval phrases are rulings

Over the director's signature, an approval-flavoured sentence is read as a ruling by the recipient and by every staff member cc'd: "happy for you to carry on", "no problem at all", "that works for us" each auto-translate to "boss said yes" and get quoted later as policy. Where the brief intends a ruling, state it as one (D2). Where it intends only acknowledgement or normalisation, recast to a form that cannot be quoted as approval: a fact, or experience ("we have worked this way with other organisers for years"). Within director register the rule covers external mail with staff in cc as much as internal mail, since the cc'd staff read the approval as a ruling either way.
