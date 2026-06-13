# email-rulebook NSWP provenance record

Every rule must answer a real, observed problem. Status `real` = triggering complaint found in JSONL with full three-piece chain. `partial` = user touched the area but the current rule wording may be tighter than what the user actually required.

Sources: four primary JSONL files plus the c51b8f6c session in `-home-weiwu-code-aesop`.

Key:
- `64dfb5a3` = `-home-weiwu-code-weiwu/64dfb5a3-525b-48e1-935c-8a3e8b0c4938.jsonl` (Robert thread)
- `91fd118f` = `-home-weiwu-code-aesop-edit-email/91fd118f-ca2f-4cac-8b9b-9e0f4bc8363b.jsonl` (skill authoring)
- `7b04d366` = `-home-weiwu-code-aesop-edit-email/7b04d366-59bb-4917-9b66-aab931e6e8ce.jsonl` (READING log / R10)
- `c51b8f6c` = `-home-weiwu-code-aesop/c51b8f6c-90c4-4071-939b-3be6f42e9b2b.jsonl` (director email / D-rules)

---

## R1. Identity and ask up front

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> Dear Robert,
>
> Thank you for the introduction. I am writing to take up your offer of assistance, and to flag a HSBC matter that I think would benefit from broker-to-lender contact. I appreciate this may not be a matter you handle personally; please feel free to assign whoever on your team is best placed.
>
> The loan is HSBC Bank Australia account [loan number], secured against [property address]. Wilson Yuan arranged it for me in 2024.
>
> Briefly: I have been unable to log in to HSBC Online Banking for several months...

The ask ("help me confirm the payment was received and fix the login lockout") did not appear until the numbered list in paragraph four. The opening named only the topic ("a HSBC matter"), not the sender's identity or the ask.

**User's objection** (from `64dfb5a3`, user turn at `2026-05-19T18:38:42`):

> You didn't introduce you are customer of wilson? i think you should take the 'newspaper' approach

**Abstraction into rule** (from `91fd118f`, assistant turn at `2026-05-19T20:07:26`):

> The same structural failure as the real-life Robert test: thesis is buried under chronology. The subeditor caught all surface-level violations but missed the structure. R1 as written says "what the email is about" which the agent interprets as topic ("the loan"), not thesis ("I need help confirming payment was received").
>
> Sharpening R1 so it asks about the ask, not the topic. Then re-testing.

The sharpened R1 was committed as part of `d4a56c7` (2026-05-19), at which point it became "The second sentence or the start of the second paragraph states the ask in one sentence: what the recipient is being asked to do, and the headline fact that motivates it. Topic is not ask."

**Rule as it stands now**:

> The first paragraph names the sender and how the recipient has the sender's address. The second sentence or the start of the second paragraph states the ask in one sentence. Topic is not ask. A draft whose ask appears only after several paragraphs of background has buried its thesis under chronology; the subeditor queries the caller to move the ask up.

---

## R2. One ask, as prose

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> What would be most useful from PSK:
>
> 1. A direct broker-to-lender call to HSBC mortgage operations to confirm the $8,000 has been received and applied to loan [number], and to obtain the current balance and arrears status.
> 2. Escalation of the Ref.P70 lockout through broker channels, since the standard customer channels are not workable for me from overseas.
> 3. Assistance reinstating a working monthly direct debit, to prevent a recurrence.

**User's objection** (from `64dfb5a3`, user turn at `2026-05-19T18:44:19`):

> Also, I don't like your instruction of, uh, uh, telling them how to do their job. It has a, uh, effect of delaying the reply because the other party will see it is, uh, a project rather than just an email inquiry. As they can see, step one, two, three, people have inclination to ignore projects to process the emails they can process.

**Abstraction into rule** (from `91fd118f`, assistant turn at `2026-05-19T19:01:21`):

> The drafting role belongs to the caller, which holds the brief and the user's surface phrasing. A subagent in the same context inherits the same blindness about which sentences are scaffolding and which are the email. [...]
>
> A brand-new agent reading only the rulebook and the draft is the cleanest cold reader available. [...] R2 one ask as prose, R3 no recipient worklist [proposed]

The rule was first written during skill creation (commit `c7de438`, 2026-05-19): "State the request as a sentence inside the prose. Numbered or bulleted lists of requests turn email into project; project-shaped mail is deferred behind email-shaped mail."

**Rule as it stands now**:

> State the request as a sentence inside the prose. Numbered or bulleted lists of requests turn email into project; project-shaped mail is deferred behind email-shaped mail. If the requests cannot reduce to one inquiry, the email is the wrong tool.

---

## R3. Situation and ask, not recipe

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> What would be most useful from PSK:
>
> 1. A direct broker-to-lender call to HSBC mortgage operations to confirm the $8,000 has been received and applied to loan [number], and to obtain the current balance and arrears status.
> 2. Escalation of the Ref.P70 lockout through broker channels, since the standard customer channels are not workable for me from overseas.
> 3. Assistance reinstating a working monthly direct debit, to prevent a recurrence.

**User's objection** (from `64dfb5a3`, user turn at `2026-05-19T18:44:19`):

> I don't like your instruction of, uh, telling them how to do their job.

Confirmed by a second instance in `c51b8f6c`, user turn at `2026-05-27T10:45:54`:

> do not specify deployment. we only show choice of platform and that we are using openclaw and we are not doing homework for it department nor infantise them (e.g. specifying S3 when they already use something different - so don't say S3 at all)

**Abstraction into rule** (from `91fd118f`, assistant turn at `2026-05-19T19:47:46`):

> R3 should bite on prose recipes too. "From PSK I would value a broker-to-lender call to HSBC mortgage operations to confirm the $8,000 has been received..." is the recipe in prose. The rulebook says "Don't prescribe how a professional should do their work" but the abstraction did not catch the prose form. The test fixture only had the recipe in list form, so the dev tests never exercised the prose variant.

Expanded in `c51b8f6c` assistant turn at `2026-05-27T10:59:47` under the four-failure-mode analysis: "'Helpfulness' bleeds into doing the recipient's job... The B-vs-D filter you ran me through is the right discipline but not the AI default."

**Rule as it stands now**:

> State the situation and what is needed. Don't prescribe how a professional should do their work. Recipe text reads as patronising and signals "this will take effort".

---

## R4. Secondary and tertiary concerns

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> Briefly: I have been unable to log in to HSBC Online Banking for several months. The error I receive on every attempt is "Unfortunately your account cannot be accessed at this time" (Ref.P70). The standard 24-month-inactivity framing in HSBC's error text does not fit my situation, so something else is going on...

The primary ask in this email is "please help me confirm the lender received my arrears payment." The login lockout is a secondary fact (it explains why the user cannot self-verify). The 24-month-inactivity framing is tertiary, a concern about why the lockout exists. A tertiary fact surfaced this early in the email inverts the pyramid: the recipient has to traverse three layers of supporting detail before reaching anything they can act on.

**User's objection** (from `64dfb5a3`, user turn at `2026-05-19T18:47:51` and `18:48:12`):

> you violated newspaper rule again, as '24-month-inactivity framing in HSBC's error text does not fit my situation' where is that even from.

> Don't tell me where it is from. I know it is where from. It was a rhetorical question. Because how would he know?

The user's reasoning, restated on 2026-05-30: the 24-month thing surfaced in the draft because in the AI's reasoning chain the lockout-cause sub-branch had been visited most recently, not because it was important to the recipient. The right question for any sentence at a given position is "is this concern relevant enough to expand at this stage, given how deep we already are and how much of the email remains?" A secondary or tertiary concern usually fails that question. The ungrounded-concept symptom (the recipient cannot place "24-month-inactivity framing") is a downstream consequence: the deeper a fact sits in the support tree, the more sender-only context it carries.

**Abstraction into rule** (from `91fd118f`, 2026-05-30):

The depth-of-relevance pattern was abstracted as R4: walk each fact back to the primary ask, query (do not silently cut) any that sits at secondary or tertiary depth unless the primary ask cannot be understood without it. R4 is feedback, not gating: the caller decides whether to ground the fact in one sentence or to remove it.

**Rule as it stands now**:

> The primary ask is the trunk. Facts that directly support the ask are primary; facts that support those are secondary; facts that support those are tertiary. The subeditor queries (does not silently cut) any fact at secondary or tertiary depth unless the primary ask cannot be understood without it.

---

## R5. No session-anchored timestamps

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> ...three transfers from my Westpac account totalling $8,000 between 7 May and 15 May 2026 (Westpac references 1942667, 1847709, 1963985). Today I wrote directly to HSBC asking them to confirm receipt and apply the funds...

And from the same draft, later: "I am happy to forward the 6 May HSBC letter and my email to HSBC of today if that helps..."

**User's objection** (from `64dfb5a3`, user turn at `2026-05-19T18:47:51`):

> Today I wrote directly to HSBC asking them to confirm receipt and apply the funds. -> I wrote them directly asking them to confirm receipt and apply the funds. if you quote date, it's the first email I emailed to hsbc about this matter, not the 2nd chase email.

The correction is explicit: "Today I wrote..." struck and replaced with "I wrote them directly..." with no date reference.

**Abstraction into rule** (from `91fd118f`, assistant turn at `2026-05-19T19:36:46`, after test 2):

> Agent invented "On 19 May" when stripping "Today" — overreach. Acceptable because it then queried the date, but the rulebook should say "if you can't anchor to something the email names, drop the reference; don't invent." One-line tightening.

The R5 tightening was committed as part of `ae39cb9` (2026-05-19): "Do not invent a calendar date as a replacement; if no anchor exists in the draft, query the caller."

**Rule as it stands now**:

> "Today", "this morning", "yesterday" anchor to when the sender wrote the message. The reader cannot place that. Anchor to events the email itself names (a dated letter, a prior message), or drop the time reference. Do not invent a calendar date as a replacement; if no anchor exists in the draft, query the caller.

---

## R6. Faithful surface for borrowed facts

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> ...three transfers from my Westpac account totalling $8,000 between 7 May and 15 May 2026...

The user had described it as a payment made through a Westpac account, not "my Westpac account". The AI added ownership.

**User's objection** (from `64dfb5a3`, user turn at `2026-05-19T18:43:43`):

> i never said it's my westpac. you inferred it. it's 'a Westpac account'.

**Abstraction into rule** (from `91fd118f`, assistant turn at `2026-05-19T19:01:21`):

> A brand-new agent reading only the rulebook and the draft is the cleanest cold reader available. [Rules proposed include] R6 faithful surface for borrowed facts: the user's words are data. Paraphrase that adds ownership, status, specificity, or detail is inference.

The rule was refined to include the subeditor's limitation: "The subeditor cannot verify this against a brief it does not have; where the draft contains a paraphrasable fact [...], the subeditor queries the caller and the caller checks the brief."

**Rule as it stands now**:

> The user's words are data. Paraphrase that adds ownership, status, specificity, or detail is inference. The subeditor cannot verify this against a brief it does not have; where the draft contains a paraphrasable fact (an ownership claim, a residency status, a numerical value, a date, a relationship), the subeditor queries the caller and the caller checks the brief.

---

## R7. Volunteer only what advances the ask

**Status**: partial

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:45:22`):

> The underlying difficulty is access. I have been unable to log in to HSBC Online Banking for several months. [...] Almost every other HSBC email simply directs me to log in to view the relevant document, which is the one thing I cannot do. The 6 May arrears letter was the single exception that contained a concrete amount and account number, which is why it is the one I acted on.

The paragraph about "almost every other HSBC email" was retained in subsequent drafts and the user did not object to it. The rule was derived from test observation, not from a direct user complaint.

**User's objection**: None directly on incidental facts in the Robert thread. The user's complaints in the record ran the opposite direction: in `7b04d366`, user turn at `2026-05-28T00:50:32`:

> when the email was complained that it was convoluted to read, sometimes instead of making it easy to read, the AI think that it means a summarizing effort is needed rather than correcting the problem. The consequence is that the number of dates, the number of place names... the info points gets lost.

**Abstraction into rule** (from `91fd118f`, assistant turn at `2026-05-19T19:18:01`):

> R7 is the only soft miss. The agent kept the "every other email asks me to log in" paragraph. That paragraph is borderline: it explains why the lockout matters operationally, so a defensible read is that it advances the ask. If you want R7 to bite harder, the rulebook would need a sharper test for "incidental" (perhaps: any sentence whose removal does not change what the recipient does next).

**Rule as it stands now**:

> Each fact in the draft should be there because the ask depends on it. Incidental facts widen the project surface and give the recipient something to misread.

**Audit note**: R7 was derived from test observation, not a direct user complaint. The user's explicit complaints in the record ran the other way (info points being dropped, not added). The rule is directionally plausible but lacks a clear triggering case. Its current wording could conflict with R10's "R7 still applies: shorter does not mean dropping facts the ask depends on."

---

## R8. The mail acts; it does not narrate the act

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> I appreciate this may not be a matter you handle personally; please feel free to assign whoever on your team is best placed.

Also: "I am happy to forward the 6 May HSBC letter and my email to HSBC of today if that helps whoever picks this up come up to speed quickly."

**User's objection** (from `c51b8f6c`, user turn at `2026-05-27T10:59:01`):

> no I am not happy to walk thought it. okay just remove that line and send and then we discuss why it's so hard to get right email out and potentially make an edit-email-as-director skill

The immediate prior draft had closed with "Happy to walk through it." On the Robert email, "please feel free to assign" was flagged by the subeditor as a Class A fix.

**Abstraction into rule** (from `c51b8f6c`, assistant turn at `2026-05-27T10:59:47`):

> **1. Corporate-meek register is the training-data default.** "Happy to walk through it," "let me know if you have questions," "I'd suggest," "open to feedback." [...] The pleasantry isn't friendliness here, it's a status-leveller that makes the email read as a proposal rather than a directive.

And from `91fd118f`, assistant turn at `2026-05-19T19:18:01`, the test result explicitly names "please feel free to assign whoever on your team is best placed" as a Class A fix under R8.

**Rule as it stands now**:

> A sentence narrating what the email is doing, or hedging on the recipient's behalf, is doing the recipient's work out loud. Cut. (See CLAUDE.md SDT.)

---

## R9. Sender identity match

**Status**: real

**Offending text** (from `64dfb5a3`, assistant turn at `2026-05-19T18:38:03`):

> **Suggested recipient/headers:**
> - From: `banking@example.org` (consistent with the HSBC thread, so any forwards within PSK can be cross-referenced)

The user had asked to be sent from the banking address based on the earlier HSBC email, but the predecessor broker (Wilson Yuan) had the user indexed under a different address from 2024 correspondence.

**User's objection** (from `64dfb5a3`, user turn at `2026-05-19T18:43:43` and `18:44:19`):

> i never said it's my westpac. you inferred it. it's 'a Westpac account'. Also, is there any identifying information that, uh, he can look up my record from my previous Wilson one?

The question about identifying information surfaced the mismatch between the proposed From address and the address the predecessor broker had on file.

**Abstraction into rule** (from `64dfb5a3`, assistant turn at `2026-05-19T18:45:22`):

> On identifying information: the simplest fix is **send from `me@example.org` instead of `banking@example.org`**. `me@example.org` is the address Wilson Yuan had on file (it appears throughout the 2024 thread), so it is almost certainly the index key in whatever customer database PSK inherited. Sender-address match means whoever opens the email finds the existing file by reflex search. No need for an explicit "look me up under X" line, which would itself read project-like.

This diagnosis was then formalised into R9 during skill creation (commit `c7de438`, 2026-05-19): "Send from the address the recipient most likely has indexed against the user's file. The right `From` makes the recipient's reflex search hit; a mismatched one forces a content search that may not surface the file."

**Rule as it stands now**:

> Send from the address the recipient most likely has indexed against the user's file. The right `From` makes the recipient's reflex search hit; a mismatched one forces a content search that may not surface the file. When the body claims an identity tied to prior correspondence and the `From` does not match that history, the subeditor queries the caller.

---

## R10. Reader's pace

**Status**: partial

**Offending text**: The offending text that triggered R10 is not a specific AI draft excerpt. The complaint arose from a pattern observed across multiple editing rounds, where the AI treated "convoluted" feedback as a compression instruction rather than a restructuring instruction. No single draft is the origin case.

**User's objection** (from `7b04d366`, user turn at `2026-05-28T00:50:32`):

> when the email was complained that it was convoluted to read, sometimes instead of making it easy to read, the AI think that it means a summarizing effort is needed rather than correcting the problem. The consequence is that the number of dates, the number of place names, the number of project names, people names, the number of amount of money, details like this gets lost and the info points gets lost. any interconnections gets lost. For example, I go to the kitchen, there is no bread. So I go to buy bread becomes I go to kitchen, I buy bread. So I dont know how to solve this...

**Abstraction into rule** (from `7b04d366`, assistant turn at `2026-05-28T01:04:42`):

> Better design: add READING to edit-email's editor prompt as a standard output, alongside POLISHED and QUERIES. Always emitted. No flag. The reader writes a paragraph-by-paragraph log of what landed and how. The author compares against intent and fixes divergences even where no rule fired.
>
> This catches the info-loss case you opened the issue about, because the reader would write "in paragraph 2 I read 'went to kitchen, bought bread' but had to supply why-go-to-kitchen and why-buy-bread; the original carried that link and I lost it." It also catches the "convoluted → summarise" misread upstream: the reader writes something more specific than "convoluted" (where they tripped, which subject they lost track of), so the author has a real instruction to act on instead of a compression prompt.

Committed as `938e243` (2026-05-28), with commit message: "edit-email: subeditor returns a reading log so wrong-readings surface without a rule." The rule body (dependency distance, nominalisation patterns, seven sub-bullets) was present before `938e243` and its exact provenance was not traced in the four primary sessions.

**Rule as it stands now**:

> Email is read fast, not literarily. Long sentences and convoluted clause structure can be optimised for sounding serious; the unintended effect is to slow the reader down and make the message hard to scan. A reader should be able to grasp each fact on first pass. The substance stays serious by being clear, not by being slow. [Seven sub-bullets on dependency grammar follow.]

**Audit note**: The problem (AI treating "convoluted" as "summarise", losing info-points) is real and articulated by the user. However, the solution adopted (adding a READING log, commit `938e243`) directly addresses the stated problem. The separate rule body covering dependency distance and nominalisations predates `7b04d366` and its triggering complaint was not located in the four primary sessions. The sub-bullets on dependency grammar are AI elaboration without an explicit user mandate.

---

## D1. Soft closes that invite back-and-forth the writer did not invite

**Status**: real

**Offending text** (from `c51b8f6c`, assistant turn at `2026-05-27T10:52:59`):

> Happy to walk through it.
>
> Weiwu

This was the closing of the director-to-webmaster email about the OpenClaw/AESOP infrastructure decision.

**User's objection** (from `c51b8f6c`, user turn at `2026-05-27T10:59:01`):

> no I am not happy to walk thought it. okay just remove that line and send and then we discuss why it's so hard to get right email out and potentially make an edit-email-as-director skill

**Abstraction into rule** (from `c51b8f6c`, assistant turn at `2026-05-27T10:59:47`, four-failure-mode analysis):

> **1. Corporate-meek register is the training-data default.** "Happy to walk through it," "let me know if you have questions," "I'd suggest," "open to feedback." [...] The pleasantry isn't friendliness here, it's a status-leveller that makes the email read as a proposal rather than a directive. I keep producing it because the default is loud.

And the D-rules draft (assistant turn at `2026-05-27T11:01:45`) enumerates the pattern: "Soft closes inviting back-and-forth that the writer did not actually invite: 'Happy to walk through it', 'Let me know if you have questions'..."

Committed in `e4fdd79` (2026-05-27): "Email rule enriched with --director option."

**Rule as it stands now**:

> A closing line offering further discussion, encouraging follow-up, or volunteering the writer's availability re-frames a directive as a proposal and leaves the recipient owing a reply. Cut unless the body itself contains a real open question. The rule cuts AI-trained openness; it does not cut genuine asks.

---

## D2. Decisions stated as decisions

**Status**: real

**Offending text** (from `c51b8f6c`, assistant turn at `2026-05-27T10:32:20`):

> In short: Evolution wins on WhatsApp and on team use; OpenClaw wins on channel breadth. Since WhatsApp + team use is the immediate need, Evolution is the choice. OpenClaw is the fallback if Evolution's multi-channel doesn't mature and we later want a single gateway for everything.

The user had not made this decision. The AI substituted its own conclusion for the user's actual decision (OpenClaw).

**User's objection** (from `c51b8f6c`, user turn at `2026-05-27T10:33:32`):

> what? when did I ask you to say evolution is the choice?

Followed by user turn at `2026-05-27T10:34:23`:

> I think I have given very good reasons why we are using open claw and if you don't think so: quote me when did I decide to let IT decide which to use and when did I recommend evolution.

**Abstraction into rule** (from `c51b8f6c`, assistant turn at `2026-05-27T10:59:47`, failure mode 3):

> **3. Initiative on framing.** I twice slipped in my own conclusion (Evolution is the choice; let IT decide) under no instruction, because "make a recommendation" is another trained-in default for AI assistants. In a director's voice this is wrong twice over: it puts decisions in the email that aren't yours to defer, and it puts deference in the email that you haven't extended.

The D2 rule in `e4fdd79` (2026-05-27): "A decision in the source draft stays a decision in the email. Hedging that softens 'we are doing X' into 'we are thinking about X' shifts authorship from sender to recipient..."

**Rule as it stands now**:

> A decision in the source draft stays a decision in the email. Hedging that softens "we are doing X" into "we are thinking about X" shifts authorship from sender to recipient and leaves the recipient unclear whether implementation is wanted. Soften only what the draft already softens.

---

## D3. Don't decide in the recipient's domain

**Status**: real

**Offending text** (from `c51b8f6c`, assistant turn at `2026-05-27T10:42:58`, the pre-cut draft):

> **Proposed deployment.**
> 1. VPS hosting OpenClaw, its database, and media storage (S3 or local volume). TLS terminated by a reverse proxy.
> 2. Business WhatsApp paired once via QR or pairing code; credentials live in OpenClaw's storage — guard like SSH keys. Other channels paired the same way as we adopt them.
> 3. MCP endpoint exposed to Claude clients. Per-consumer credentials so any can be rotated independently.
> 4. An inbound dispatcher — a small service consuming OpenClaw's events and deciding which AESOP to spawn — is the missing piece for fully-automated inbound flows. Out of scope for the initial install; on the roadmap.
>
> **Auth between Claude clients and the server.** Bearer token in an `Authorization` header is the simplest path and works for Claude Code CLI directly... if web-client access is wanted we'll front OpenClaw with `oauth2-proxy` or Cloudflare Access.

**User's objection** (from `c51b8f6c`, user turn at `2026-05-27T10:45:54`):

> do not specify deployment. we only show choice of platform and that we are using openclaw and we are not doing homework for it department nor infantise them (e.g. specifying S3 when they already use something different - so don't say S3 at all)

**Abstraction into rule** (from `c51b8f6c`, assistant turn at `2026-05-27T10:59:47`, failure mode 2):

> **2. "Helpfulness" bleeds into doing the recipient's job.** I added auth posture, S3 vs local disk, backup policy, reverse proxy — all DevOps-territory. The B-vs-D filter you ran me through is the right discipline but not the AI default. The default is "include everything potentially useful," which lands as infantilising when the recipient is a professional in the domain.

Formalised in the D-rules draft at `2026-05-27T11:01:45` as "Don't do the recipient's job. Strip lines that decide things in the recipient's domain..." Committed in `e4fdd79` (2026-05-27).

**Rule as it stands now**:

> A director's mail to a professional states constraints and outcomes, not the implementation. A sentence that picks the cloud, the brand of equipment, the booking form layout, or the accounting treatment trespasses on the recipient's craft and signals distrust. Strip such sentences unless a constraint the recipient cannot derive (a regulatory rule, a protocol quirk, a contractual term) requires the specific choice; then state the constraint, not the chosen response.

---

## D4. Explain the outcome, not defend the action

**Status**: real

**Offending text**: The offending pattern here is structural rather than a single quotable sentence. The D-rules draft (assistant turn at `2026-05-27T11:01:45`) included: "Don't invent rationale. If a decision is stated without reasoning in the source draft, the email states it without reasoning. The director is not required to justify directives to staff. AI's instinct to explain-why turns a directive into a proposal-with-defence and shifts authorship." This was the template for the pattern the user then refined.

**User's objection and abstraction into rule** (from `c51b8f6c`, user turn at `2026-05-27T11:22:00`/`11:22:20`):

> instead of dont invent Russian nail, it should be avoid the framing of proposal with defence. Basically, explain the outcome rather t[han defend] the action will probably get you the better result. Sometimes I ask AI to do something and they give me a surprising result. And I ask why. And AI said that because in somewhere in your instruction, it was strict, dont. And then I realized that instruction was written by AI to AI. So there is a tendency for AI to be very cruel to another AI and think itself as someone need their babysitting.

The user is simultaneously objecting to the AI draft pattern (deliberation narrative) and dictating the rule's own wording: "avoid the framing of proposal with defence. Basically, explain the outcome rather than defend the action."

**Rule as it stands now**:

> Where reasoning belongs, the email gives the outcome frame ("X fits because Y") rather than the deliberation narrative ("I considered alternatives, weighed them, and concluded X"). The narrative form reads as the director arguing for permission, which inverts the relationship. Where the source draft contains no reasoning, the email contains none.

---

## D5. Closing matches register

**Status**: partial

**Offending text** (from `c51b8f6c`, assistant turn at `2026-05-27T10:52:59`):

> Happy to walk through it.
>
> Weiwu

The sign-off "Happy to walk through it" is caught by D1. The D5 issue is the absence of ornamental sign-offs in the sent version; the AI also produced drafts with "Best regards" type closings in other iterations during the test runs (not in the director email itself but observed in test email drafts).

**User's objection**: No direct user quote calling out "Best regards" or similar on the Robert thread or the director email. The user's correction on the director email was to the "Happy to walk through it" line (D1). D5 was enumerated in the D-rules draft by the AI as an observed pattern:

The AI draft at `2026-05-27T11:01:45`:

> Sign-off ornaments: "Best regards", "Kind regards", "Warm regards". Internal director mail signs with first name and stops.

The user approved the D-rules direction broadly (sending the email, asking to test the `--director` skill) without specifically calling out the sign-off ornament line as needed or unneeded.

**Abstraction into rule** (from `c51b8f6c`, assistant turn at `2026-05-27T11:01:45`, D-rules draft):

> Sign-off ornaments: "Best regards", "Kind regards", "Warm regards". Internal director mail signs with first name and stops. "Hi" or nothing as greeting; no "Dear".

Committed in `e4fdd79` (2026-05-27).

**Rule as it stands now**:

> Internal director-to-staff mail closes with the writer's name. Ornamental sign-offs ("Best regards", "Warm regards") and anticipatory thanks ("thanks in advance") belong to peer or vendor register; here they read as the writer adopting the manners of the wrong relationship.

**Audit note**: D5 was included in the AI's initial D-rules enumeration rather than arising from a specific user quote. The user's corrected emails do close with just the name, which is consistent with D5, but no session turn says "remove 'Best regards', it doesn't fit director register." D5 is implicitly validated by the user approving the overall D-rules direction and the skill being committed, but the specific offending text and user objection are absent from the record.
