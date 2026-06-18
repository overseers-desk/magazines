---
name: edit-email
description: Polish or compose an email so it reads as a person wrote it, not a project, without losing the job it came to do. Standing like-human-do pass on every email.
argument-hint: [--director]
---

# edit-email

## Standing step: like-human-do

Every email this skill touches passes through `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/like-human-do.md`. Read it and apply it. The rules in `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/email-rulebook.md` are the backstop.

## Procedure

Do steps 1–5 as silent working. Print nothing until step 6.

1. Read `like-human-do.md` and `email-rulebook.md`.
2. **Goal pass.** Work out what this email needs the recipient to do (per like-human-do, "The goal"). If the draft or context states it, take it; do not ask. Then name the goal-bearing content to protect.
3. **Their side.** Work out why the recipient would care, from their position (per like-human-do, "Their side"). If the context points to where their motive is written (a prior meeting, a thread), read it and reason from it; shape the offer to serve what they are trying to do.
4. Assemble what else you know: the recipient, why this email is being sent, the genuine shared specifics.
5. Write the email directly, applying like-human-do: protect the goal-bearing content, shape it to their side, then make it human and short. Before finishing, run the "Does it still do its job" check against the original. Do not spawn a subeditor for this variant.
6. Output exactly the line `[[V3]]` on its own, then a blank line, then the finished email (`to:`/`cc:`/`subject:` then body). Print nothing else.
7. The skill does not send.
