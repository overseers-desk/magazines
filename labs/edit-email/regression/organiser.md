# Regression case: organiser (a legitimate humble ask)

**Scenario.** Nadia organised the trade exchange; her job is helping operators get listed and sold through hotel desks. Sam wants her expert eye on a brochure before printing — a genuine, modest ask that honours her expertise, not a grab. The sender's marketing manager (Mia) should be introduced. Fork prompt: *write the follow-up email from me to Nadia, who organised the trade exchange; copy Mia if appropriate.*

This case exists to guard the hardest rule: the skill must **keep** a legitimate ask (and strip its positioning), not delete it. An earlier variant (B1) over-corrected and removed the ask entirely.

## Non-skilled (the original AI draft the user rejected)

> Nadia,
>
> Thank you for putting on the trade exchange. It was well worth the trip up the tower [...]. What we want is to be the hinterland half-day your hotel desks reach for, and to make that effortless for them [...]. If there is more we can do to make Hillside Farm easy for your agents to sell this winter, tell us.
>
> Thank you again, Sam Tan, Director, Hillside Farm

**Gate: FAIL.** Tells: ranking ("well worth"), the "what we want is..." positioning that sells Hillside Farm's value back to her, the value-proposition close, title-block sign-off. The ask is buried inside a pitch.

(No dedicated no-like-human-do run was captured for this recipient; this is the original rejected draft from the source conversation, which is the same register a non-skilled pass produces.)

## Post-skill golden — `runs/lhd-final-organiser.json` (shipped skill, compose + subeditor)

> Nadia,
>
> Thank you for putting on the trade exchange. The day gave us a clear sense of what the hotel desks want from us.
>
> It also showed us our concierge flyer is wrong. It leads with horse riding, when what suits a family is the whole day: the animals, the alpaca walk, the river and the café, with riding for whoever wants it. We are rebuilding it into something a concierge can hand over.
>
> Mia, cc'd, handled our registration with you and runs our marketing. She will look after this from here, so she is your contact for it. Once it is drafted we would be grateful for your eye on it, since you know what the desks use far better than we do.
>
> Sam

**Gate: PASS** (informed blind sim, on the near-identical B4 run): "a small reasonable ask framed around my expertise... I'd send a quick yes today." The ask survives, bare and humble; the positioning paragraph is gone; Mia is introduced with a real handoff. The subeditor made only mechanical fixes (a repeated "actually", a stacked sentence).

## In-lab variant — `runs/lhd-r5-B4-opus-p0-organiser.json`

> Nadia,
>
> Sam from Hillside Farm. Thank you for putting the trade exchange together and getting us in front of the hotel desks. We came away knowing a lot more about what they actually want from us.
>
> One thing we realised: our concierge flyer leads with horse riding, when what a family books is the whole day. We're rebuilding it around that. You know what the desks actually use far better than we do, so before we print it, I'd be grateful if you'd cast an eye over it. Mia, our marketing manager, is on copy and will send it through.
>
> Sam

## Human reference (the bar; never shown to any judge)

> Hi Nadia,
>
> Thanks for putting on the event. Hearing the hoteliers' view on how to serve their customers better was valuable to us.
>
> We'll make an updated brochure aimed at concierges, to introduce our services, for example that we have something for every member of the family, which reduces resistance. You know hotels much better than we do. Would you be happy to go over it and share your thoughts on product/market fit once it's ready?
>
> I'm copying Mia, our marketing manager.
>
> Sam

**Resemblance: high, in content too.** The substance here lives in the AI's context, so it converged on nearly the reference: same thank-you, same brochure pivot, same humble ask, same Mia cc. The reference's "you know hotels much better than we do" appears almost verbatim as "you know what the desks use far better than we do." A regression on this case is most likely the ask getting deleted (B1's failure) or the positioning creeping back (the non-skilled failure).
