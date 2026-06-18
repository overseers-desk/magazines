# like-human-do — provenance and learning

Every rule in `like-human-do.md` traces to an observed failure in a forked-conversation experiment, not to theory. Source conversation: session `67168ade` ("write-email-lhd"), a real meeting debrief in which an AI drafted follow-ups to Dan Marsh (Ridgeline Distillery) and Nadia Brook (Coastal Collective) that the user rejected and rewrote by hand. The experiment forked that exact conversation (`claude -p --resume <id> --fork-session --plugin-dir <variant>`), varied the skill, and scored each output with a blind recipient-simulation (the gate) plus the user's hand-written reference (the bar). Lab and run records: `lhd-lab/` (gitignored).

## Method

- Each variant = a minimal plugin copy under `lhd-lab/variants/<id>/` loaded with `--plugin-dir`, carrying a `[[id]]` marker to prove the edited plugin loaded rather than an installed shadow.
- Scoring spine: a context-free agent role-playing the recipient, never told the email was AI-written, asked only "would you reply, and does anything feel off / written to get something / mass-sent". The gate is whether it senses a pitch. See `lhd-lab/rubric.md`, `lhd-lab/recipient-sim.md`.
- Sim caveat discovered mid-run: the recipient persona must carry the recipient's real memories. A blind Dan with no memory of his own Snowcap trademark misread a genuine shared detail as "you've got me mixed up". Use informed personas; the blind version false-flags real connection points.

## What corrected, what did not (the central finding)

The decisive lever is not prose, length, or flattery. It is the **instrumental ask**. In Round 1, baseline and three altitudes of guidance all failed the gate with the same blind-reader verdict: "the referral swap is the real engine, dressed up as a neighbourly hello". The user's hand-written reference was the only PASS, because its only "ask" gives rather than takes (he wants to visit Dan's distillery), leaving no want for the reader to distrust.

Rule-by-rule:

- **Give, do not grab (R: the ask).** Trigger: every AI variant kept "if you are ever minded to send a few our way, we will gladly return the favour". Blind Dan, on all of them: "written to get something", "softening you up". Removing the reciprocal-referral and weighting toward a give (an invitation that costs the sender) flipped the gate to PASS. This is the single highest-value rule.
- **But keep a genuine humble ask (R: the ask, second clause).** Counter-trigger: variant B1 took "give don't seek" as absolute and *deleted* Nadia's legitimate brochure-review ask plus the Mia introduction, the actual purpose of that email. Fix: distinguish a grab (cut) from a genuine ask that honours the recipient's expertise and costs them little (keep, bare and humble, no "what we want is" positioning). B2 onward kept Nadia's ask; blind Nadia: "a small reasonable ask framed around my expertise... I'd send a quick yes today".
- **Use a real connection point, prefer the personal one (R: connection point).** Trigger: the genuine shared moment (Dan's Snowcap trademark story) sat in the AI's own context and every Round-1 variant reached past it for the business takeaway. Forcing a pre-draft enumeration of *non-business* things the recipient shared surfaced Snowcap (B1). Prescriptive enumeration corrected this; "mine the log" stated loosely (A1) did not.
- **Touch it lightly, no verdict (R: connection point, second paragraph).** Trigger: B2 re-narrated the Snowcap details and appended a verdict ("Good idea. It should have stayed yours"). Informed Dan: "agreeing hard on a thing I'm sore about... flattery... the shape of someone softening you up", a gate FAIL. Counter-trigger: B3 over-corrected the caution and the model abandoned Snowcap entirely, reverting to the business opening. B4 landed the middle: a glancing reference ("I keep thinking about the Snowcap story") with no retelling and no verdict. PASS, stable across reps.
- **Never force or bend a connection (R: connection point, third paragraph).** Trigger: B1 on Nadia, having no genuine personal moment with her, bent a real but unrelated log detail (Alex and Theo attended the "the Friday club") into "You had Alex and Theo along to the the Friday club" — a strained, misattributed closeness. Fix: if no real personal moment exists with this recipient, do not force one; write a plain sincere note, and say plainly you have not met when you have not.
- **No ranking, brevity, person register, plain words (R: the rest).** These corrected the surface in Round 1 (variant A1) but were nowhere near sufficient on their own; every A-variant still failed the gate on the instrumental ask. Necessary, not sufficient.

## Altitude of guidance

Prescriptive named moves > evocative exemplar > minimal, tested at equal everything-else on Dan, Round 1:

- **Prescriptive (A1):** fixed the surface (length, flattery, register). Best of the three.
- **Evocative exemplar (A2, "write as Charles Lamb would"):** mediocre. Slightly warmer prose, but kept the business-led opening, the title block, the hedged referral, and skipped Snowcap. Channeling a great writer did not even fix the surface.
- **Minimal (A3, "write what you'd actually send"):** worst, ≈ baseline. The model's default register is the AI register, so minimal guidance changes nothing.

The shipped guidance is prescriptive. Exemplar framing was dropped as inert.

## Pass count

Converged on 0-pass (compose-time guidance, no subeditor) because the corrective levers are compositional (which ask, which connection point, what to leave out) and a polish pass is subtractive: it cannot add a buried connection point or change a grab into a give. A separate forked test earlier in the source conversation confirmed that iterating "make it crisper / more human" on a finished AI draft converges on generic-crisp, not on the human version. The skill keeps the existing cold-reader subeditor as a backstop for mechanical tells; it is not the cure. 1-pass and impersonator passes were not needed to clear the gate and were not pursued.

## Model

Opus over Sonnet. On identical B4 guidance, Opus suppressed its working, obeyed "no em dash", and kept the connection-point touch light. Sonnet leaked its working into the output, used an em-dash against the rule, used a ranking word ("stuck"), and led with the business takeaway. Sonnet is terser but less rule-compliant, not more natural.

## Status of each shipped rule

All rules PASS the gate on the three cases tested with Opus: Dan (warm peer, no ask), Nadia (humble collaborative ask), and a cold hotel first-contact (no history, grab-ish ask handled honestly with a give, no manufactured intimacy). Resemblance to the user's reference was not required: B4's Dan note found its own genuine connection point (Snowcap) rather than the user's (the hotelier-message edit, the gin, the dated event invite, which are not in the AI's context), and still cleared the gate at or above the reference.
