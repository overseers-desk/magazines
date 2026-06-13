---
name: quote-me
description: Source-citation and minimum-edit workflow. Triggered when the user says "quote me". Locates the exact passage behind an AI claim, walks a challenge-and-minimum-edit cycle, then verifies the fix with a context-free subagent under explicit anti-cheat discipline.
---

# quote-me

## Problem this skill exists to solve

An AI agent reporting from a document or codebase will sometimes draw an inference the source does not support. The user suspects this but cannot easily see which words the agent is drawing from, or why. They need to see the exact text, challenge the reasoning, correct the minimum amount of text required to close the inference gap, and then verify — through a fresh-context agent — that the fix works. Without discipline around "minimum edit" the agent over-corrects, rewriting the whole section around the one problem the user named. Without an anti-cheat guard the verification is meaningless because the subagent gets the answer from the prompt rather than from the document.

## Procedure

### Step 1 — Quote

When the user says "quote me", identify the specific claim being challenged (the most recent AI claim if none is specified). Produce:

- **File path** (absolute, or repo-relative with the repo root named)
- **Line range** if applicable
- **Verbatim passage** — the exact text as it appears in the source, no paraphrase

If the claim drew from more than one passage, quote each separately. Do not summarise, do not interleave. The user reads the raw text and judges for themselves.

### Step 2 — Inference challenge (likely to follow)

The user will usually ask: *"What makes you think that conclusion follows from that quote?"*

Walk the reasoning chain explicitly: which words in the passage triggered which inference, in what order. Surface any gap between what the words actually say and what was concluded. Do not defend the conclusion; the goal is to expose the chain so the user can locate the break.

### Step 3 — Minimum edit

The user will identify where the reasoning went wrong and ask for a minimum edit to the source. Rules:

- **Minimum means minimum.** Change only the words needed to close the specific inference gap the user named. Do not rewrite surrounding context, do not restructure sections, do not improve adjacent phrasing.
- **Spotlight rule.** The spotlight effect causes an AI asked to "fix this" to rewrite the entire visible surface around the problem. Resist this. The only criterion for the edit is: does the wrong inference remain reachable after the change? If not, stop.
- **Show the diff.** Before applying, show the user the before and after inline so they can confirm the scope is truly minimum.
- Apply only after user approval.

### Step 4 — Anti-cheat reasoning (do this before spawning the subagent)

Cheating means: the verification subagent gets the correct answer because the prompt implies it, not because the edited document now yields it.

Before composing the subagent prompt, reason out loud in a clearly labelled block:

```
Anti-cheat check:
- The original question I will send is: "..."
- The correct answer is: "..."
- Does the question's phrasing imply the correct answer? [yes/no — explain]
- Does the question reveal what the prior error was? [yes/no — explain]
- Does the question direct the subagent toward the relevant passage? [yes/no — explain]
Verdict: [passes / fails — one sentence]
```

If the check fails, rewrite the question until it passes. Only then proceed.

### Step 5 — Verification subagent

Spawn a fresh general-purpose subagent (Agent tool, default model). The subagent must receive:

- **Same contextual access as the calling agent**: the same repository path, the same relevant files. Enough that the failure scenario is reliably reproducible; not so much that the correct answer is implied.
- **The original question only** — the same wording the user originally asked, with no added framing about the error, the correction, or what answer is expected.
- **An instruction to cite its source**: file path and the exact words it drew from.

The subagent must not receive: the correct answer, the nature of the prior error, the passage that was edited, or any framing that points toward the right conclusion.

### Step 6 — Outcome

Read the subagent's response.

- **Correct answer + correct citation of the edited passage**: the fix is verified. Report this to the user with the subagent's cited words.
- **Correct answer but citation does not point to the edit**: the subagent may have guessed or drawn from a different passage. Flag this — it is a weak verification. Investigate what the subagent actually drew from.
- **Wrong answer**: the edit was insufficient. Report the subagent's answer and its citation verbatim. Return to Step 3 for another round.

Do not declare the fix verified unless the subagent cited the edited passage.

## Why the subagent needs the same context as the caller

The failure to be corrected must be reproducible. A subagent given less context than the original agent may get the wrong answer for a different reason (missing file access, shorter retrieval) rather than confirming the specific inference gap was closed. Match the context so the only variable is the edited text.

## Why anti-cheat is a reasoning step, not a mechanical filter

There is no mechanical rule that reliably separates a neutral question from a loaded one. The calling agent must actively reason about whether its prompt leaks the answer, because only it knows what the correct answer is. A short explicit reasoning block forces this and makes the discipline auditable.

## Why minimum edit matters

When an AI is asked to fix an incorrect inference in a document, it tends to rewrite the passage that is currently visible to it — solving not just the named inference gap but also adjacent ambiguities, stylistic looseness, and anything else that occurs to it as improvable. This is the spotlight effect: the spotlight of attention makes everything under it seem improvable. The user's cost is a diff they did not ask for, and a document whose next misreading will be different and equally hard to anticipate. A minimum edit targets the single inference gap; if the document has other problems, they remain visible and correctable in their own right.
