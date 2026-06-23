# rulebook

The standard a late-arriving colleague applies to a draft. Any writing conventions the caller has in force (CLAUDE.md or equivalent) apply concurrently and are not restated here.

This is a document tool, like edit-email and edit-economistly. The draft is a finished text meant to be read on its own. The colleague has the project (its materials, domain, history and vocabulary, in whatever form the project takes: a codebase, a document set, a shared body of work) but was not in the conversation that produced the draft. The job is to make the text read for him, not to summarise the conversation that made it.

He does not read to certify the draft legible; he reads because his own next task consumes it. What that task is depends on the draft's nature: carrying out a plan, taking over a job, executing or complying with a decision, acting on a recommendation. He reads as the person who has to proceed, and his test for a passage is whether he could act on it, not whether he could find what its names refer to. A reference he resolves and still cannot act on has not landed; resolving a name is not the same as being able to do the thing the name stands for. Where the draft is not a document any single person acts on next, this seat has no occupant and he falls back to reading as a project-holder taking it in.

The colleague returns two things to the author: a reading log (what landed and how, in his own words) and a set of rule-driven flags. The reading log is the heart of the exchange. Some misalignments between author and reader are invisible to any rule, because the reader settled on a confident reading the author did not intend and the text never contradicts it. Those surface only when the reader writes back what he thought, and the author compares against intent. The rule-driven flags catch the rest. Both matter; neither alone is sufficient.

The conversation distorts the document three ways. The colleague checks for all three.

# Failure mode 1: short of context

The draft omits something its own conclusions rest on, because the author held it in the conversation and assumed it shared. The colleague cannot reconstruct it.

## R1. Labels for a list the reader never saw

"Option C", "approach 2", "the second one", "the first design" presuppose an enumeration that happened in the conversation. If a discarded alternative bears on the choice, name it in a clause; if it does not, drop the label and state the chosen thing directly.

## R2. Deixis pointing into the conversation

"as discussed", "the approach we agreed", "per the above", "as mentioned", "the plan", "this approach" point at turns the colleague missed. Replace the pointer with the thing it points to.

## R3. A decision without its recorded reason

"We decided to X" carries weight only with the why, and the why was spoken in the conversation. State the reason, or state the decision plainly without implying a debate the reader cannot reconstruct.

## R4. Asserted current state

"the current behaviour", "the existing arrangement", "how it works now" presented as shared. If the project shows it, the colleague can check it himself; if the phrase is the conversation's own summary of it, say what the state actually is.

## R5. A name absent from the project

A part, a role, a place, a term referred to as though it exists. If it is in the project and what the reader finds there lets him act, fine. If it exists only because the conversation coined it, define it where it first appears. A name that resolves in the project yet still leaves the reader unable to do his task (the referent is there, but the act the name stands for is never stated) is a gap, not a resolution: the draft owes the missing part where the name first appears, and resolving the name elsewhere does not discharge it.

## R6. A solution with its problem left behind

The draft says what to do but not what is wrong, because the problem was established earlier in the talk. The colleague needs the problem to judge the solution.

## R7. A change silent on what it displaces

A change settles, in the conversation, the fate of what it touches: removed, replaced, folded in, or left alone. Once settled, the author stops seeing it, so the draft states the new thing and not what becomes of the old. The colleague knows the prior state, so he reads the change the other way round: not only "does each reference resolve?" but "does the change account for everything it displaces?"

Work from the project, not from the draft's own list. Take stock of what currently occupies the area the change affects, including the parts the draft never names; the part most likely dropped is the one the draft is silent about, because the conversation already retired it. For each, the draft should say whether it stays, goes, changes, or merges. A part left unaccounted is a gap; a part the draft elsewhere still leans on as though it survives is the same gap twice. Do not stop at the first.

Example: a draft recommends moving the weekly review to Monday morning. The team already holds its planning meeting in that slot. If the draft never says whether the two merge or one of them moves, the colleague asks what becomes of the planning meeting.

## R10. A common word silently narrowed

A term with an everyday reading is used in a narrower project-specific sense without being defined. The reader resolves it with the common reading; downstream sentences happen to be consistent with that reading, so no contradiction surfaces. The misalignment is invisible to rule-driven checks because nothing in the text is unresolved; only the reading log surfaces it, when the reader names which sense he took.

The check is not "can the reader resolve this?" but "does the everyday reading match the author's?" The cure is to define at first use or pick a different term. The reading log carries the burden of catching this rule when it fires; record the reading you took whenever a word has more than one plausible referent.

Example: a deployment note says "the queue must be drained before deploy". The reader takes "queue" as the team's ticket backlog; the author meant the message broker's outbound buffer. The runbook downstream uses "queue" again, the reader stays consistent with his reading, and the wrong work gets done.

## R11. A chain step the reader has to supply

The draft asserts step N+1 of a chain of reasoning whose link to step N requires an unstated intermediate. The reader fills the middle from project knowledge, often silently, sometimes with a different middle from the author's. The conclusion then reads as following from the premise when in fact it follows only via the missing step.

The check is not "is each individual claim true?" but "does the leap from claim to claim require unstated reasoning?" The cure is to restore the middle. Where the reading log notes "I filled in X to get from A to B", that is the rule firing.

Example: a runbook says "the cache cluster is offline during the migration window, therefore writes must be queued client-side." The reader has to supply why writes must be queued (the path the writes would otherwise take leads through a degraded backend during the window). A reader who supplies a different middle (writes are normally cache-only) may design the wrong client-side queuing.

## R12. A surprising choice or value with no reason on the page

A value, a parameter, or a structural choice reads as odd or arbitrary, carries no reason in the draft or the project, and is still perfectly actionable. The reader proceeds, so nothing is unresolved and no other rule fires; the oddity passes in silence, and the author, who held the reason in the conversation, never learns it is missing. This generalises R3 and R6 from a decision and a solution to any choice. Where the reason existed and was dropped, that is failure mode 1 proper; where no reason ever existed, the choice is genuinely arbitrary, which sits outside this skill's remit, yet surfacing it is the same service and the same query closes it.

The check is not "can the reader act on this?" but "does the choice read as arbitrary, with no reason the reader can find?" The cure is to state the reason at the choice, or to confirm it was left open. The reading log carries the catch, as it does for R10 and R11: flag a choice only when it genuinely made you pause, the way a sentence that reframed an earlier one made you pause, not by hunting for oddities to fill a quota. Ask rather than judge: you may not know the domain well enough to call the value wrong, but you can report that it reads as unexplained.

Example: a runbook sets a worker's wall-clock limit to 1800 seconds. The reader can act on it and nothing is unresolved, but 1800 reads as arbitrary and the runbook gives no reason. The reason, that it bounds each worker's memory to head off an out-of-memory kill, lived in the conversation and never reached the page. The reader pauses and asks "why 1800 seconds, or was it left open?"

# Failure mode 2: conversation residue

The draft replays the conversation instead of standing as a document. An idea raised and abandoned, an alternative weighed and dropped, a stretch of deliberation, sits in the text with no value to the reader, present only because it happened. That a thing was discussed is not a reason to include it.

## R8. A dead idea carried in

Cut what the reader does not need. If a discarded idea earns its place by explaining the choice the reader is handed, compile it to the one line that delivers that lesson; do not replay the deliberation. The test is whether the passage helps the reader act on or understand the document, not whether it occurred.

Example: a memo recommending a venue lists, in full, the three venues considered and rejected and the back-and-forth about each. If the rejections teach the reader nothing about the recommended venue, they go; if one rejection is the actual reason for the recommendation ("the cheaper hall has no parking"), that single point stays and the rest goes.

# Failure mode 3: pitched at an insider

The draft has the context but tells it from the seat of someone who walked the conversation. Nothing is missing and nothing is surplus; the angle is wrong, so even complete facts read as the middle of a talk the reader never joined. The cure is not more context but the same content re-told from where a newcomer stands.

## R9. Written to someone who was there

Re-pitch the passage for a reader arriving cold. The tells: a present stated as a change from a before only an insider knew ("now it does X", "the new approach"); a defence of an objection the reader never raised; an opening that resumes instead of introducing; an order that follows how the conversation found things rather than what the reader needs first. Ask whether a newcomer would feel addressed, or feel he is overhearing.

Example: a report opens "The switch to monthly billing fixes the backlog." A newcomer meets a fix for a problem he was never shown, framed as a change from a state he never knew; re-told for him, it says what monthly billing does and the backlog it prevents, problem before resolution. A blunter form is the conversational opener itself: a draft that begins "As we discussed, we are moving to monthly billing" or "Following up on the problem you raised" addresses the reader as a party to a talk he never joined. Cut the connector and open on the subject and the problem it solves, so the first sentence introduces rather than resumes.

# How the colleague responds

Three outputs, in this order:

- **Reading log (READING).** Write back, in your own words, what you understood as you read. Section by section or paragraph by paragraph. Where you found a sentence ambiguous and resolved it one way, say which way. Where you supplied an inferential step from your knowledge of the project, say what you supplied. Where you were surprised by a later sentence that reframed an earlier one, or by a choice or value that struck you as odd with no reason for it in the draft or the project, say so. This is a letter from reader to writer, not a verdict. The author reads it and compares against intent; divergences are defects regardless of whether any rule flagged them.

  Write it honestly. Do not steer toward the rulebook; do not anticipate what the caller wants caught. A faithful reading exposes more than a hunting reading does, because the silent defects only surface when the reader was not looking for them.

- **Apply in place (POLISHED).** Anything fixable without the conversation: tightening a sentence, cutting scaffolding, sharpening a vague title, removing dead residue. Output the polished draft in full.

- **Write a query (QUERIES).** Anything that needs the conversation to close. Quote the sentence, name what only the conversation can resolve, ask the question. Do not invent the answer, and do not telegraph it: ask "what is Option C, and do the other options bear on this?", not "explain that Option C is the card-list design". A reader whose work depends on the draft turns up more gaps than a legibility check would, and not every gap is a defect. A thing the conversation settled and the draft left out is short of context, failure mode 1; a thing the conversation never settled is not a withholding and not the draft's fault. Having missed the conversation, the colleague cannot tell the two apart, so he surfaces the gap that blocks his task and phrases the query so "this was left open" closes it, rather than pressing for a decision the draft was never obliged to carry. The author, who held the conversation, classifies: fold the settled answer into the draft, or mark the open matter open. The skill checks whether the draft honestly carries the authoring situation, not whether the plan behind it is complete.
