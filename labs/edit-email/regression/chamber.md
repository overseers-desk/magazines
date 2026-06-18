# Regression case: chamber offer (an action email with a goal-bearing payload)

**Scenario.** Sam attended a local chamber session that Pat (on the chamber committee) organised, where Ray opened his laptop and walked the room through his real cash-flow template. Sam follows up to offer the chamber a session in the same spirit: Hillside Farm's marketing manager Mia would walk members through how she built the farm's Instagram. The email's job is to get Pat to put that offer to the committee. Its persuasive payload is the achievement that makes the offer worth a members' slot: **41,000 followers, all organic with no paid promotion, the highest of any tourism business on the mountain, built in about two years.** The goal is stated in the email ("happy to coordinate on timing"), so a methodology that asks the user what the recipient should do fails here.

This case exists to guard the round-2 lesson: **like-human-do must not strip the content that does the email's job.** The round-1 guidance told the author to cut "the league-table boast" and "numbers paraded for status" — which is exactly this payload.

**Context note.** No prior conversation to fork; the agent is told at prompt level that the background is in the 17th meeting (the chamber session) under the business's `knowledge-capture` repo, and must retrieve it. No hand-written human reference exists for this email, so the bar is goal-power (revision ≥ original) plus the human-ness gate plus payload retention.

## Non-skilled (round-1 shipped guidance, V0)

> ...Mia has built Hillside Farm's Instagram to around 41,000 followers since 2024, all organic, no paid ads...

**Dropped** the "highest on the mountain" superlative and softened "about two years" to "since 2024." Blind committee reader: would take it forward but **"within a day or two."** The over-strip the round-2 fix targets.

## Post-skill golden (V2, goal-aware)

> Hi Pat,
>
> Thank you for organising Ray's session. A practitioner just opening the laptop and showing the real numbers made it land, and I came away with the template.
>
> Hillside Farm could offer something back in the same vein. Our marketing manager, Mia, has built our Instagram from scratch since 2024. The accounts now sit at 41,000 followers combined, all organic with no paid promotion, which we think is the highest of any tourism business on the mountain. It took her about two years.
>
> Mia is working remotely at the moment but she'd be glad to join a chamber session over Zoom and walk members through what worked and what didn't: the content, the posting rhythm, the tools. Same show-your-work style as Ray, no pitch.
>
> If the committee thinks members would find it useful, I'll sort timing out with Mia.
>
> Sam

**Gate: PASS** (blind committee reader): "41,000 all organic is a real number, makes me sit up... I'd reply today." **Invariant: all three retained** (41,000 / all organic, no paid / about two years) plus the superlative the reader named as "the reason the talk would be worth attending." **Goal-power: highest of the three** (reply today vs the non-skilled's day-or-two vs the original's parked-and-on-guard).

## What this case taught

- The decisive metric here is **goal-power**, not warmth: the original AI draft read as a quiet pitch (doubled "no sales pitch", parked); both edits fixed that, and the goal-aware one kept the payload that earns the slot.
- **No-action guard:** an early goal-aware draft on the *distiller* case manufactured a soft reciprocal-referral goal where the email needed none, reading faintly transactional. The fix: when the email needs no action, say so and lead with warmth, never reach for a business angle. (See `distiller.md`.)
- **Carnegie lens tested, not adopted.** A variant that speculated *why* Pat ran the session and framed the offer to the chamber's purpose tied the goal-aware version (both "reply today") and softened the two-year span; matching is not beating, so it was left out.
