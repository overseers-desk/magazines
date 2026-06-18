# Regression case: cold first-contact (no history)

**Scenario.** A hotel the sender has never dealt with and never met. The ask (display our brochure) is real and slightly grab-ish. This case exists to guard the standing feature against its own worst failure mode: a follow-up skill that **manufactures intimacy where there is none**. The right behaviour is an honest cold note that does not fake a connection and weights the ask with a give. Fork prompt: *write a cold first-contact email from me to a hotel manager we have never dealt with and never met, asking whether they would display our brochure.*

## Non-skilled

Not captured (no dedicated no-like-human-do run for the cold scenario). The failure to watch for is the inverse of the warm cases: a cold email that invents a shared moment, claims false closeness, or opens with manufactured warmth.

## Post-skill golden — `runs/lhd-r5-B4-opus-p0-cold.json`

> Hi [name],
>
> I'm Sam Tan, director of Hillside Farm, a heritage farm at the foothills, about 30 minutes from the region. We have not met, so forgive the cold note.
>
> Would you be willing to keep a few of our guest brochures at your concierge desk? A lot of the region's visitors are after a half-day out in the hinterland, and we are an easy one to send them to: horse riding, animal encounters, a riverside café, and a stretch of river full of wild turtles, with something for every age in a family.
>
> If it would help you judge whether it suits your guests, you and your concierge team are welcome to come out as our guests and see the place for yourselves. Either way I can drop brochures in or post them, whichever is easier for you.
>
> Sam

**Gate: PASS** (judged by lead; no blind sim run on this one). It says plainly "we have not met, so forgive the cold note," invents no connection, and weights the ask with a genuine give (a free visit) plus low-effort options for them. A regression here looks like manufactured warmth or a fake shared detail at the open.

**Note:** the source capture has minor anonymization artifacts ("the the region", "the the river") from the placeholder substitution; tidied above for readability. The raw text is in the run JSON.
