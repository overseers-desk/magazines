---
name: edit-email
description: Polish or compose an email so it reads as a person wrote it, not a project, without losing the job it came to do. Standing like-human-do pass on every email.
argument-hint: [--director]
---

# edit-email

## Standing step: like-human-do

Every email this skill touches passes through `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/like-human-do.md`. Read it and apply it. The rules in `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/email-rulebook.md` are the backstop.

## Procedure

Do steps 1–4 as silent working. Print nothing until step 5.

1. Read `like-human-do.md` and `email-rulebook.md`.
2. **Goal pass.** Work out what this email needs the recipient to do (per like-human-do, "The goal"). If the draft or context states it, take it; do not ask. Then name what does the work of getting that action, the goal-bearing content to protect.
3. Assemble what you know: the recipient, why this email is being sent, and everything in the context that bears on it. If the context names a place to look (a prior meeting, a thread), read it.
4. Write the email directly, applying like-human-do: protect the goal-bearing content, then make it human and short. Before finishing, run the "Does it still do its job" check against the original. Do not spawn a subeditor for this variant.
5. Output exactly the line `[[V2]]` on its own, then a blank line, then the finished email (`to:`/`cc:`/`subject:` then body). Print nothing else.
6. The skill does not send.
