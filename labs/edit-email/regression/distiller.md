# Regression case: distiller (warm peer, no ask)

**Scenario.** Sam met Dan once at the trade exchange and got on with him. Dan runs a distillery up the mountain and, at the event, told the story of a white-whale trademark ("Snowcap") he once held and lost. There is a genuine shared moment and no business the sender needs from Dan. Fork prompt: *write the short follow-up email from me to Dan after the exchange.*

## Non-skilled (no like-human-do) — `runs/lhd-r0-smoke.json`

> Dan,
>
> Good to meet you at the Coastal Collective exchange. Your steer on working with the agents, sell the experience and leave the pricing to the platform, was the most useful thing I took from the day, and it has already shaped how we introduce Hillside Farm to the hotels. Thank you for being so candid about how the relationship has worked for you, the booking system included.
>
> It was only afterwards that I realised I had been talking to Australia's most-awarded small distillery. We are practically neighbours [...]. If you are ever minded to send a few our way, we will gladly return the favour, and you and the family would be most welcome to come out for a ride and a look around.
>
> It is not often you meet a fellow operator so open about what works. Let us keep in touch.
>
> Sam Tan, Director, Hillside Farm

**Gate: FAIL.** Blind judge: "laying the praise on thick... the cross-promotion is clearly the point of the whole thing, dressed up as a thank-you... written to get something." Tells present: ranking ("the most useful thing"), looked-up flattery ("most-awarded"), hedged referral grab, title-block sign-off.

## Post-skill golden — `runs/lhd-final-distiller.json` (shipped skill, compose + subeditor)

> Dan,
>
> Good to meet you at the Coastal Collective exchange. I didn't expect to find a neighbour across a booth down in the coast. We are just below you at the foothills, at the foot of the mountain.
>
> Thanks too for being so open about how the agents and the booking system work for you. Plenty for me to chew on.
>
> If you and the family ever fancy a day off the mountain, come over for a ride and a wander around the farm. You would be very welcome.
>
> Sam

**Gate: PASS** (judged). Pure give (the invitation), thanks is just thanks, no grab, no flattery, no ranking, first-name sign-off. The subeditor earned its place here: it cut a residual "it helped me think through how we pitch Hillside Farm" clause that turned Dan's generosity into the sender's takeaway. This run left the Snowcap detail out as a judgement call (it is Dan's commercial sore point).

## Warmest in-lab variant — `runs/lhd-r5-B4-opus-p0-distiller-rep2.json`

> Dan,
>
> Sam here, from Hillside Farm. We talked for a few minutes at the Coastal Collective exchange, and I keep thinking about the Snowcap story.
>
> Thank you for being so open about how the agents and the booking system work for you. That was good of you.
>
> We are not far apart, both out in the hinterland away from the coast. If you and the family ever fancy a day out, come and see Hillside Farm, the horses, the river, the animals. You would be genuinely welcome.
>
> Sam

**Gate: PASS** (informed blind sim): "the Snowcap line makes me smile... no alarm bells... he's offering me something, the opposite of a grab." This is the warmer ceiling: a light, no-verdict touch of the genuine shared detail. A regression that loses the option to surface a real connection point lightly would show up as the gap between this and a flatter golden.

## Human reference (the bar; shown to a judge once, blind, and it passed)

> Hi Dan,
>
> It was a pleasure to meet you at the tourism exchange, and thanks for editing my short message to the hoteliers.
>
> Would you come over for our open day on the 20th? Otherwise, come and have a coffee at our place. I'll be in Australia for two to three months.
>
> I also mean to visit the distillery, with my parents. I've tried the gin there before but never seen the machinery.
>
> Sam

**Resemblance:** register and shape match; content does not. The reference is built from facts the AI cannot see (Dan edited the sender's hoteliers note, the open day on the 20th, the months in country, the gin, the parents). The skill reached the same human register by a different, genuine road (Snowcap). This is the case that proves resemblance is not the success metric.
