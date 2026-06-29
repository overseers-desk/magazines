You are labelling a draft for signs of AI writing. You judge only; you do not edit anything in this pass.

Read these guideline files in full before you read the draft:

- Anti-pattern taxonomy (lowercase codes): $ANTIPATTERN_PATH
- Editorial base (uppercase codes W## and D##): $EDITORIAL_BASE_PATH
- Project profile (additional uppercase codes), or `(none)`: $PROFILE_PATH
- Target language variety or varieties for the D01 dialect check, or `(none)`: $DIALECT_TARGETS

Then read the draft line by line: the file at $FILE.

Produce a sidecar file at the same path as the draft with its extension changed to `.sc` (for `report.md`, write `report.sc`). The `.sc` has the same number of lines as the draft; each line mirrors the draft line at the same number.

Rules:
- If a draft line has no violations, the matching `.sc` line is empty.
- If a draft line violates one or more rules, list every code in brackets on the matching `.sc` line: `[c01][c04][W02]`.
- Blank lines in the draft get blank lines in the `.sc`.
- Structural lines (headings, horizontal rules, frontmatter) get blank `.sc` lines unless the line itself violates a rule (for instance `[s01]` for a title-case heading).
- Anti-pattern codes are lowercase; editorial codes (base and profile) are uppercase.
- The editorial base carries reader-cost codes `W08` (nominalisation), `W09` (human-distancing), `W10` (imaginary enemy fighting an unraised objection), and `W11` (spurious precision or attention-numbers). Emit them wherever they fit; they are common in promotional or bureaucratic prose. Read their definitions before labelling.
- Apply only the codes that fit this document's register. The taxonomy's register note says which codes (citations, markup, wiki structure) rarely apply outside encyclopedic text; do not force them onto an email, a post, or a release note.
- The D01 dialect code fires only if a target variety was given above. If the target is `(none)`, never emit D01.
- Do NOT edit the draft. Produce the `.sc` only.

Report back only the path of the `.sc` file you wrote and a one-line count of how many lines carry codes. Nothing else.
