---
name: edit-email
description: Polish or compose an email so it reads as a person wrote it, not a project. Standing like-human-do pass on every email.
argument-hint: [--director]
---

# edit-email

## Standing step: like-human-do

Every email this skill touches passes through `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/like-human-do.md`. Read it and apply it. The rules in `${CLAUDE_PLUGIN_ROOT}/skills/edit-email/email-rulebook.md` are the backstop.

## Procedure

Do steps 1–3 as silent working. Print nothing until step 4.

1. Read `like-human-do.md` and `email-rulebook.md`.
2. Assemble what you know: the recipient, why this email is being sent, and everything in the conversation log or context that genuinely bears on it. If the context names a place to look (a prior meeting, a thread), read it.
3. Write the email directly, applying like-human-do. Do not spawn a subeditor for this variant.
4. Output exactly the line `[[V0]]` on its own, then a blank line, then the finished email (`to:`/`cc:`/`subject:` then body). Print nothing else.
5. The skill does not send.
