---
name: edit-email
description: Polish or compose an email so it reads as a person wrote it, not a project: fixes AI tells (to-do lists, session dates, smuggled inferences, buried lead) and applies a standing like-human-do pass. Flags add director register and voice impersonation.
argument-hint: [--director] [--Liansu]
---

# edit-email

## Problem this skill exists to solve

AI-drafted email reads to its sender like an email and to its recipient like a project. The drafting agent has the brief in conversation; when it composes, it paraphrases liberally, defends inferences the reader has never drawn, anchors timestamps to its own session, and turns asks into numbered lists. The recipient sees something that will take effort to handle and defers it.

A general newspaper maxim in CLAUDE.md is not enough on its own: the drafting agent cannot see the scaffolding it has carried in from its brief. The fix is a cold reader who has only the email, applies the rulebook, and returns a polished draft plus queries.

The rules the drafting agent and the subeditor both work to are in `email-rulebook.md` alongside this file.

## Standing step: like-human-do

Every email this skill touches passes through `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/like-human-do.md`. This is not a flag and not optional; it runs on warm follow-ups, cold first-contacts, and everything between. Read it before you draft.

It is compose-time work, done by you the caller before you assemble the draft, because the thing it fixes (an ask wrapped in warmth, a business takeaway where a real shared moment belongs) lives in the structure of the email, and the subeditor, polishing prose, cannot remove it. The subeditor remains the backstop, not the cure.

## Procedure

1. Apply like-human-do first, as silent working before you write a word of the draft. Take the passes in order:
   - **Goal.** Say plainly what action the email needs the recipient to take, or that it needs none (a true note of thanks or relationship). If the draft or context states the action, take it; do not ask the user. Name the goal-bearing content that earns that action, the credibility the ask or offer rests on, and protect it through every later cut. If the email needs no action, do not manufacture a soft one (a referral, a future deal); the job is warmth, led by a genuine shared moment.
   - **Connection and ask.** From the conversation log, list the concrete non-business things this recipient personally said or shared, and separately name what the email wants. Sort the want into a grab (cut it), a genuine humble ask (keep it bare), or an offer (keep it, with the achievement that earns it). Decide the give. Lead with a real shared moment only if one exists; never force one.
   - **Does it still do its job.** Before you assemble, check the draft against the original: the reader must be at least as likely to act. If warmth or brevity dropped what earned the action, restore it.
   Then assemble the draft as a text block with the YAML-style header preamble (`to:`, `cc:`, `from:`, `subject:`) and the body below.
1a. If the draft relies on prior correspondence (a reply, or a fresh message that picks up an unresolved ask from earlier mail), assemble a THREAD block of the relevant prior messages. One issue often spans several threads: include every thread the draft draws on, not only the one the headers say it replies to. Each message in the block carries its own from/date/subject and body. The subeditor cannot fetch mail; whatever the cold reader needs to judge whether the draft omits a fact the recipient is waiting on must be in this block. If the draft stands on its own, the THREAD value is `(none)`.
2. Spawn a fresh-context agent. Use the prompt template at `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/editor-prompt.md`; substitute `$RULEBOOK_PATH` with the rulebook path, `$EMAIL` with the draft text, `$THREAD` with the THREAD block (or `(none)`), `$REGISTER` with the register tag (`general` by default; `director-to-staff` when the caller invokes with `--director`), and `$VOICE_GUIDE` with the content of the named voice guide file (`(none)` when no voice flag is given; the content of `voice-warm-proprietor.md` when `--Liansu` is given). When `--Liansu` is given, use Opus as the agent model. Pass the result as the agent prompt.
3. When `$VOICE_GUIDE` is `(none)`: the agent is a cold subeditor. It returns READING (paragraph-by-paragraph log of how the draft landed), POLISHED (mechanical fixes applied), and QUERIES (rule citations for things needing the brief).
   When `$VOICE_GUIDE` has content: the agent is an impersonator. It returns READING (first-person friction notes as the named author), POLISHED (the email as the author would send it), and QUERIES (what the author would need to know to finalise it herself).
4. Read READING first. Compare each friction point or interpretation against what the draft meant. Fix the draft based on what the agent surfaces. Resolve queries from your conversation context, asking the user if the brief does not answer. Do not invent.
5. Show the user the polished body inline; revise as requested by re-running the skill.
6. Send via mailroom once approved. The skill does not send.

## Files

`${CLAUDE_PLUGIN_ROOT}/skills/edit-email/`:

- `like-human-do.md` — the standing compose-time pass: give don't grab, real connection point, person's voice
- `email-rulebook.md` — the rules
- `editor-prompt.md` — the subeditor prompt template
- `voice-warm-proprietor.md` — voice guide for `--Liansu`; derived from Liansu Yu's sent mail corpus

## Why a fresh-context subeditor

The drafting role belongs to the caller, which holds the brief and the user's surface phrasing. A subagent in the same context inherits the same blindness about which sentences are scaffolding and which are the email. A brand-new agent reading only the rulebook and the draft is the cleanest cold reader available.

## Anti-cheating discipline

Rulebook examples must come from outside any test fixture, otherwise the subeditor matches lexically rather than applying the rule. If a rule example appears in a draft to be tested, the example is contamination and must be rewritten before the test result is meaningful.
