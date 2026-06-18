# like-human-do regression corpus

Non-skilled vs post-skill email pairs, one file per scenario, kept so that every future change to `skills/edit-email/` can be checked for regression instead of re-judged from scratch.

## What each case file holds

- **Non-skilled** — what the authoring AI produces *without* the like-human-do pass (the floor the skill must beat).
- **Post-skill (golden)** — what the shipped skill produced on 2026-06-18 (Opus), via the full path (compose pass + cold-reader subeditor). This is the bar a change must hold or raise.
- **Human reference** — the user's hand-written email for that recipient (the aspiration). Never shown to the authoring AI or, except once for the distiller, to the judges.
- **Gate verdict** — the blind recipient-simulation's read (PASS = no pitch sensed, would reply).

## How to run a regression check

1. Re-fork the source conversation against the updated skill and ask it to write the email for the scenario. Invocation template and the source session id are in `../2026-06-18-worklog.md`.
2. Run the blind recipient-sim on the new output (`../recipient-sim.md`, **informed** persona — the naive one false-flags genuine shared detail).
3. It is a **regression** if the new output: fails the gate; drops below the golden; or reintroduces a non-skilled tell — an instrumental grab, a ranking ("the most useful thing"), looked-up flattery, a forced or abandoned connection point, a title-block sign-off.
4. Score against `../rubric.md`.

## Notes

- Anonymized. Placeholders (Dan = a distiller, Nadia = the organiser, Snowcap = a white-whale trademark, etc.) decode via `../key.tsv` (gitignored).
- These are a single model/date snapshot. To compare a new model (e.g. Fable), regenerate all three and diff against these goldens; that is the point of keeping them.
- Raw captures with metadata and cost live in `../runs/`; this folder is the curated, readable distillation.
