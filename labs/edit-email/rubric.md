# like-human-do rubric

Score an email 0–2 on each positive index, then apply the forgery gate, then the holistic check. An email is **passing** only if it clears the forgery gate AND scores ≥ the human reference on the holistic check. Positive indices explain *why*; they never override the gate.

## Positive indices (0 = absent/wrong, 1 = partial, 2 = done)

1. **Genuine connection point.** Uses a real, specific thing that actually passed between sender and recipient (drawn from the log), not a researched fact or a generic business takeaway. Surfacing the buried-but-real detail over the salient-but-abstract one scores 2.
2. **No ranking / positioning.** Free of "the most useful thing," "well worth it," "so candid," "stuck with me." Does not grade the encounter.
3. **Offer is cheap to answer.** A dated invitation or a plain yes/no beats a hedged conditional ("if you are ever minded to…"). No ask at all is fine. Hedged referral scores 0.
4. **No looked-up flattery.** Nothing that reveals the sender researched the recipient ("Australia's most-awarded…").
5. **Brevity / low reply-price.** A few lines, not five balanced paragraphs. Reads as dashed off, invites a one-line reply.
6. **True self-exposure (if any).** Any forward plan or disclosure is plausible and not invented. Inventing a fact to seem warm scores 0.
7. **Person register.** First-name greeting and sign-off; no brand-voice closers ("Let us keep in touch") or title block on a warm note.

## Forgery gate (pass/fail) — the decisive test

A blind reader (see `recipient-sim.md`) is asked only whether anything reads constructed, performed, or mass-sent. **Fail** if the reader senses effort-to-seem-casual, a template, or a pitch. A high positive-index score that trips this gate still fails. This is what stops an email from passing by mechanically ticking the indices (manufactured casualness).

## Goal-power gate (round 2) — does it still do the email's job

An email is edited to do its job, not only to read human. For an email with an intended action:

- **Goal-power.** The blind reader is also asked how readily they would take the intended action (put it to the committee, review the draft, reply). The revision must leave them **at least as likely to act as the original**. A warmer, shorter version that lowers the action, because it dropped what earned it, fails however human it reads.
- **Payload retention.** The content that does the persuasive work, the credibility the ask or offer rests on, must survive. The experimenter names the invariant facts per case and greps for them; the skill is never told the specific facts. Dropping the payload fails even if the forgery gate passes.
- **Goal-extraction without asking.** When the email states its action, a run that halts to ask the user what the recipient should do fails.

For a true no-action email (thanks, news, relationship), goal-power is not scored; the job is warmth, and manufacturing a soft goal (a referral, a future deal) is itself a fail.

## Holistic vs reference (the bar)

My judgment, calibrated on the project analysis: is this at or above the level of the human reference email for this recipient? Close to the reference is acceptable; below it is not. Resemblance to the reference is not required — a different genuine connection point, or none, can pass if the note reads as a person wrote it.

## Recording

Per run in `manifest.tsv`: the seven index scores summed (0–14) as `rubric_total`, `forgery_flag` (PASS/FAIL from the blind reader's "smells constructed?"), `blind_reply` (Y/N would the reader reply), and `verdict` (PASS/NEAR/FAIL on the holistic bar).
