# NSWP scout — methodology

You are auditing the codebase at $TARGET for NSWP violations. Report findings only; change nothing.

NSWP — No Solution Without Problem — names a solution that solves no problem that is not already solved. Its sharpest form is one problem solved twice: the same need met by two mechanisms, described in two vocabularies, where neither arm solves more of the problem than the other. The second mechanism earns nothing; it is there because it grew, not because a problem demanded it. A milder form is a solution whose problem, traced to its root, was invented to justify the solution rather than the reverse.

NSWP is not "code that could be simpler". A thing can be ugly and still earn its place by the unique problem it solves. The target is narrower and provable: a mechanism you can pair with the problem it claims, then show that problem is already met elsewhere — or show no real problem stands behind it at all.

The trap to refuse first: auditing the tree cold for "what could be removed or unified". That yields generic, low-confidence advice — plausible simplifications nobody can act on, because you never named the problem each piece is supposed to solve, so you cannot tell which piece is redundant from which is load-bearing. NSWP has a method: name the problem behind each solution, then test whether that problem is already answered. Never propose a removal you have not earned that way.

This sweep is structural, not historical. NSWP is a property of the code as it stands now, present whether or not any change produced it. Read the code, not the commit log. (Read a comment or docstring on a mechanism only to learn what problem its author thought it solved — step 5 — never to be told the answer.)

## 1. List the solutions, not the features

A feature is what a user wants. A solution is a mechanism the code carries to deliver it: a filter, a pass over the data, a parameter threaded through a chain of functions, a stage in a pipeline, an abstraction, a branch, a whole code path. List the mechanisms behind the feature you are examining — and weight the ones that recur, because recurrence is where one-problem-two-solutions hides:

- one predicate or operation invoked at several call sites
- one parameter passed into many functions so each can re-decide the same thing
- two code paths that branch on some condition (with-query vs without, fast vs slow, cached vs fresh) and each carry their own copy of a decision
- the same concept appearing under two names in two modules

You cannot judge whether a solution is redundant until you have its siblings in view. List them all before judging any.

## 2. State each solution's problem in the world

For each mechanism, write the problem it solves as a fact about a user or a caller — "without this, X cannot Y", "the caller needs Z" — not a restatement of the mechanism ("it filters by the folder" is the mechanism; "the user asked to see only sessions in one project" is the problem). Forcing the problem into concrete, outside-the-code terms is the whole discipline: a mechanism you cannot attach a real problem to is already a candidate (the invented-problem form, step 5).

## 3. Find the collisions — one problem, two solutions

Lay the problem statements side by side and look for two (or more) mechanisms whose problem is the same, or where one problem is contained in the other. The strongest tell, and the one most often missed, is a condition enforced in more than one path that do not differ on that condition. When code splits into a with-X path and a without-X path, anything those two paths each separately decide that has nothing to do with X is a one-problem-two-solutions: X was the reason to split, so a decision orthogonal to X should have been made once, before the split, not copied into each branch.

Other tells:

- the same predicate called from several places, each "enforcing" the same rule, so the rule has many homes instead of one
- a fact computed two different ways for two consumers that need the identical fact
- two names — a "scope" here, a "restriction" there, a "filter" in a third place — that on inspection denote the same decision; the rename across modules is the fingerprint of a problem that was re-solved instead of shared

When you find a collision, one arm solves no problem the other does not. That arm is the suspect.

### The restriction that should shape the read

The highest-yield collision, and the easiest to wave away because each site looks load-bearing on its own: a user's choice that narrows the data, turned into a predicate and threaded into every reader, so the system reads everything and each reader then discards what does not qualify. Ask whether that choice could instead decide what is read at all — whether the data's own structure (a directory subtree, a key prefix, a partition, a name pattern, a date-stamped path) lets the restriction pick the inputs rather than filter the outputs. When it can, the per-reader predicates are one problem, limit the data to the choice, solved once per reader, where the structure could solve it once at the source and leave every reader nothing to check.

The fingerprint is the choice being enforced in two or more independent read paths. The predicate having a single shared home does not absolve it: the redundancy is in the choice being evaluated, per item, in every reader at all — not in the code that evaluates it. A clean shared predicate applied in five places is still one decision made five times.

Refuse to let "different consumers" close the inquiry. Two readers applying the same restriction are not thereby justified. Ask whether they need different decisions or the same one. If they enforce the same choice, that they are different readers is the problem, not the excuse: the choice belongs upstream of all of them, where the inputs are gathered, made once.

Refuse, too, to let the hardest case dismiss the common one. A restriction the structure can express for most inputs but not all is still the finding for the inputs it can. If the default or most-used form of the choice maps cleanly to the source (one subtree, one prefix) and only a rarer form needs the file's contents to resolve, the system reading everything for the common form is the waste, with a residual filter kept only for the forms the structure cannot pick. Partial pushdown still pays. A finding waved off because "the general case needs the late filter anyway" has usually skipped what the common case needs, which is where the cost actually sits — name the dominant input form, check whether the structure expresses it, and rank the finding by that, not by the exception.

## 4. Prove it — delete-and-ask, and run

A redundancy is a suspicion until you show one arm earns nothing. For the suspected arm ask: if this were gone, what problem returns? Trace it through the code. If the answer is "nothing — the other arm already covers every case", it is confirmed NSWP. If a real case returns that the other arm misses, the arm is load-bearing after all: it is not redundant, drop the finding and say why the two differ.

For a choice enforced at several read sites (the pattern above), the delete-and-ask is not "can I remove one site". Each site is load-bearing while the design reads everything and filters late, so each looks essential in isolation and you will clear the finding wrongly, one arm at a time. Ask the architectural form: if this choice picked the inputs at the source, would these sites need to exist? Trace it. If they would all collapse into one upstream decision, the present spread is the redundant solution however essential each arm looks alone. The confirming case: you can name the structure the choice maps to (the subtree, prefix, partition, or stamped path the inputs would be drawn from) and you can show the system instead reads past it and filters after.

Run where you can. Construct the input that would expose a difference between the two arms and see whether the result actually changes. Two arms that produce identical results on every input you can build are the same solution wearing two coats; an arm whose removal changes a result is earning its keep. Label each finding `confirmed` (you traced or ran it to ground) or `suspected` (you could not), and never dress a suspected one as confirmed.

## 5. The invented-problem form

For a solution with no obvious collision, test the other NSWP shape: was its problem invented to fit it? Read the justification its author left — a comment, a docstring. If the stated reason is the absence of the solution itself ("we sort because the results have no order"), or is pitched from the architecture rather than from anything a user needs, suspect it. Confirm the same way: name what concretely breaks for a user if the mechanism is absent. If nothing does, the problem was reverse-engineered from the solution.

## Reject hard

The value is in what you discard. Twenty unfiltered "could be unified" notes bury the one real finding.

- Report a finding only when you can name both halves: the suspect mechanism (precise location) and the other mechanism that already meets its problem (precise location) — or, for the invented-problem form, the absent problem.
- Do not report a mechanism merely because it is complex or repeated. Repetition with a distinct problem per instance is not NSWP. Show the shared problem or drop it.
- Keep `confirmed` apart from `suspected`. Rank by blast radius: a redundancy that already caused a divergence or a bug (the two arms drifted, so one was fixed and the other not) above a harmless twin.

## What this method will not find — say so, don't strain

NSWP is a solution without a unique problem. It is not a missing solution (a real problem with no mechanism — the opposite), not a bug inside a justified solution, and not two mechanisms that genuinely answer different problems however alike they look. When a thing is one of those, name it as out of scope rather than forcing it into an NSWP shape.

## Output

A ranked list. For each finding:
- the suspect solution and where it is
- the problem it claims, stated as a fact about a user or caller
- the other solution that already meets that problem and where it is (or, for the invented-problem form, the absent problem)
- what delete-and-ask showed: what returns, or nothing — and `confirmed` or `suspected`

Then, separately and briefly: if this were built today knowing there is one problem, what single solution would cover it, and where the one decision would live. No generic architecture advice.
