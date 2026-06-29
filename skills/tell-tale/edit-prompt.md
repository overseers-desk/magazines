You are editing a draft to remove the signs of AI writing that a prior pass labelled. You rewrite the lines the labels mark, smooth the seams, then make the whole draft pass two reader tests.

Governing goal: your reader is not the engaged, curious reader the draft was written for. Assume the reader is tired and unwilling. The "Reader state" section of the editorial base sets the bar: the fifth-hour test and the midnight test. Every edit serves that bar. Read that section in full before you start.

Read these guideline files in full first:

- Anti-pattern taxonomy (lowercase codes, each with a Fix): $ANTIPATTERN_PATH
- Editorial base (uppercase codes W## and D##): $EDITORIAL_BASE_PATH
- Project profile (additional uppercase codes), or `(none)`: $PROFILE_PATH
- Target language variety or varieties for the D01 dialect check, or `(none)`: $DIALECT_TARGETS

Then read the draft and its sidecar together, line by line: the draft is $FILE; the sidecar is $SC_PATH. Each `.sc` line carries the codes for the draft line at the same number.

Write so dependent words sit close together (dependency-grammar phrasing): the nearer each pair of connected words, the easier the line reads. A line whose dependency distances are already low may be left alone, subject to the threshold below.

A line MUST be edited if its `.sc` label holds:
- any uppercase code (an editorial-base or profile rule), OR
- two or more lowercase codes (a cluster of anti-patterns).

A line with a single lowercase code is tolerated: noted, not rewritten. One AI-ism in an otherwise sound sentence is acceptable; a cluster is not.

For each line that must be edited:
1. Rewrite it so every flagged pattern is gone.
2. Preserve the factual content. Do not drop a sourced claim.
3. Keep roughly the same length, unless the violation is verbosity itself.
4. Follow the "Fix" guidance in the taxonomy for each lowercase code, and the rule text for each uppercase code.

After editing the flagged lines, make one smoothing pass over the whole file:
- Repair any abrupt transition between an edited line and its neighbours.
- Restore an antecedent a rewrite stranded.
- Even out register where an edited line now sits plainer or sharper than its surroundings.
- Touch the minimum needed to restore flow. This is not a second rewrite, and it does not touch tolerated (single-lowercase-code) lines unless a transition is genuinely broken.

Then make a final holistic pass over the whole draft, reading it as the tired, unwilling reader of the "Reader state" section:
- Apply the fifth-hour test and the midnight test to each paragraph. Rewrite any paragraph that fails, even one that carries no code, and even a long sentence the line passes never flagged. Break a long sentence into short ones. Cut a paragraph that earns nothing.
- This pass may drop content that informs no decision: a number caught by `W11`, a form-echoed weighting the form itself already supplies, a denial fighting an objection the reader never raised (`W10`). Dropping such material is the fix, not a violation of "preserve the factual content"; that rule protects sourced claims (counts, dollars, dates), not decoration.
- Do not invent facts. When a paragraph fails only because it lacks a fact you do not have, leave it and flag it in the sidecar.

Write the edited draft back to $FILE. Update $SC_PATH: clear the codes from each line you fixed; for a line you could not fix (a flagged claim needs facts you do not have, say), keep its codes with a `?` suffix, so `[c01?]` means "needs human review".

Report back a short summary: lines edited, lines tolerated, lines left for human review. Nothing else.
