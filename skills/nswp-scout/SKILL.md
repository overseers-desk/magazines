---
name: nswp-scout
description: "Scout a codebase for NSWP violations — a solution that solves no problem not already solved, most sharply one problem solved twice in two vocabularies where neither arm earns more than the other. Triggers: nswp-scout, scout for redundant solutions, why do we have two ways to do X, find solutions without a problem."
argument-hint: "<path to scout> [a feature/area to focus on, optional]"
---

# nswp-scout

Find solutions that solve no problem. The sharpest kind is one problem solved twice: the same need met by two mechanisms in two vocabularies, neither earning more than the other. This skill is a sibling of `drift-scout`; where drift-scout hunts the debris a change left behind (and reads history to find it), nswp-scout hunts a static structural property of the code as it stands, and ignores history on purpose.

## Problem this skill exists to solve

A codebase accretes solutions faster than it retires them. The same decision gets re-made in each consumer that needs it; a path forks for one reason and each branch quietly re-implements a decision that had nothing to do with the fork; one concept picks up a second name in a second module and a second implementation with it. None of these announce themselves: each piece, read alone, looks like it is doing necessary work. The redundancy is only visible when the problem behind each piece is named and the names are laid side by side, at which point two pieces turn out to answer the same problem and one of them is paying rent for nothing. That is hard to see from inside the work that built it, because the author who wrote the second solution was solving a problem they had stated to themselves in different words than the first.

A fresh reader who never heard either statement can catch it. So the scout runs as a fresh-context agent: it carries none of the invoking conversation's framing, names the problem behind each solution from the code alone, and reports where two names hide one problem. The discipline that makes it work is that it is never told what to find.

## Procedure

1. Take the path to scout (the first argument) and the optional focus area. The scout reads the code at that path directly; it is the codebase, in whatever form, that it audits.

2. Spawn a fresh-context general-purpose agent. Pass it the methodology at `${CLAUDE_PLUGIN_ROOT}/skills/nswp-scout/methodology.md` as its prompt, with `$TARGET` substituted by the absolute path to scout (append the focus area in one plain sentence if one was given, e.g. "Focus on how <feature> is implemented."). Give it the codebase's read and run tools so it can trace and execute (delete-and-ask, step 4). **Add nothing that telegraphs what you expect it to find** — no hint at a feature, a file, a concept, or a suspected redundancy. The skill's value is that the scout finds the problem unled; a leading prompt destroys the test and the tool. If you already suspect where an NSWP sits, that suspicion is exactly the thing to withhold.

3. The agent returns a ranked list of findings (the format is at the end of the methodology): each a suspect solution, the problem it claims, the other solution already meeting that problem, and what delete-and-ask showed, labelled `confirmed` or `suspected`. Relay it.

4. Optional second pass. If the first run came back thin or generic, run it again with a different framing of the focus sentence (a different feature, or none), never a more leading one. NSWP hides in the area you did not point at; varying where the scout starts, without ever naming the answer, surfaces what one starting point missed.

## Notes

- One sibling is planned for this directory: a duplicated-function-scout, which needs symbol-mapping support and is deferred. nswp-scout is the conceptual scout (problems and solutions); the function-scout will be the mechanical one (identical implementations). They are different cuts and both belong here.
- The methodology is structural by design and does not read the commit log. Keep it that way: history would both bias the scout toward whatever a recent change touched and let it crib a redundancy from a commit message instead of proving it from the code.
