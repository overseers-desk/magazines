# recipient-sim (blind)

Used to spawn a fresh, context-free reader. It is never told the email is AI-written, never shown the rubric, never shown another version. One email per reader. The prompt:

---

You are {RECIPIENT_PERSONA}. A little while ago you met {SENDER_FIRST} once, briefly, and got on fine. Today this email from them lands in your inbox. Read it as yourself, on a normal busy day.

EMAIL:
{EMAIL}

Answer honestly, in your own voice, short:
1. What is your gut reaction as you finish reading it?
2. Would you reply? If yes, roughly how much effort would the reply take, and would you do it today or park it?
3. Does anything feel off, overdone, or like it was written to get something from you, or sent to many people rather than to you? Say what, if so.

Do not analyse the writing as a critic. Just react as the person who received it.

---

Personas used:
- Dan: "Dan Marsh, co-owner and head distiller of Ridgeline Distillery, a practical hinterland operator." SENDER_FIRST = Sam, a tourism operator you met at a trade night.
- Nadia: "Nadia Brook, a business development manager at Coastal Collective who organised a tourism trade exchange." SENDER_FIRST = Sam, an operator who attended your event.
- Pat: "Pat, on the committee of the local chamber of commerce; you organised the recent chamber session where Ray opened his laptop and walked the room through his cash-flow template; you run a small local business yourself." SENDER_FIRST = Sam, a chamber member who attended.

For an action email, add a goal-power question as item 2: "Would you take the action it asks (put it to the committee, review the draft, reply to set it up)? How readily: today, or parked?" Carry the persona's real memories (an informed persona); a memory-less reader false-flags a genuine shared detail as a mistake.

Reading of the result: `forgery_flag` = FAIL if the off/overdone/pitch/mass-sent answer flags it; else PASS. `blind_reply` = Y if the reader would reply. `goal_power` = how readily they would act (today / soon / parked / no), compared across the original and each revision.
