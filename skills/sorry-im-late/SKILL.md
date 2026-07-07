---
name: sorry-im-late
description: Run before sending, publishing, or committing something written during a conversation, a draft or a staged code diff, so it stands on its own for a reader who has the project but wasn't there.
argument-hint: <draft-path> | --staged | --since <ref> [--plan-agent]
---

# sorry-im-late

A colleague walks into a working session already under way and says "sorry I'm late, I see you have started." He knows the project, the document produced by it, but not what this conversation has covered leading to the document. Everything you write from here has to land for him. This skill is in the family of edit-email and edit-economistly.

## Problem this skill exists to solve

This is a document tool, in the same family as edit-email and edit-economistly: it makes a finished text read for its reader. The reader here is an outsider who has the project but was not in the conversation that produced the text. The product is the document, not the conversation; the skill does not summarise the talk, it makes the text stand on its own. If most of the conversation is irrelevant to the document, none of it belongs in the document.

A draft written in the middle of a conversation carries that conversation into the text three ways, and all read badly to the imaginary person who arrived late:

- **Short of context.** The author holds the whole exchange, so the draft leans on it: "Option C", "the approach we agreed", "the current behaviour", a conclusion whose reason was spoken and not written, a change that never says what becomes of what it replaces. The reader cannot reconstruct any of it.
- **Conversation residue.** The draft also carries the conversation's leftovers: an idea raised and abandoned, an alternative weighed and dropped, deliberation replayed, kept only because it happened. A reader who wants the result, not the transcript, has to wade through it. That a thing was discussed is not a reason to include it.
- **Pitched at an insider.** The draft can hold every fact yet tell it from the seat of someone who walked the conversation: a present framed as a change from a before only an insider knew, a defence of an objection the reader never raised. To the newcomer it reads as the middle of a talk he never joined.

The reader-simulation maxim in CLAUDE.md is not enough on its own, because the author cannot see the scaffolding it carried in. A separate reader who never had the conversation can. This is the boundary from edit-economistly, whose reader is a generalist outside the project who needs entities glossed and acronyms expanded; here the reader is inside the project and needs none of that. The one thing withheld from him is this conversation.

The rules both the author and the colleague work to are in `${CLAUDE_PLUGIN_ROOT}/skills/sorry-im-late/rulebook.md`.

## Procedure

1. The draft must already be a file on disk (the finished text at a known path). The colleague reads it by that path, in full, the same way it reads the project's code — which is why the draft has to be written first. Take its path. Never paste the draft into the prompt, and never a condensed or excerpted version: the review is only as thorough as what the colleague actually sees, so a shortened draft silently blinds it to the sections you cut. With `--staged`, the draft is the commit about to be made: run the diff that shows what the commit form will commit (`git diff --cached` for a staged commit; `git diff HEAD -- <paths>` for a pathspec or `--only` commit; `git diff HEAD` for `-a`; a caller such as a commit gate may hand you the exact command) and write its full output to a temp file outside the repo (a scratchpad path), then use that file as the draft. With `--since <ref>`, the draft is everything the project changed after the dividing line: write `git diff <ref>..HEAD` to the temp file the same way, and name `<ref>` as the base in the agent prompt so the colleague knows where the before-state sits. The same no-condensing rule applies; the diff goes in whole.
2. Spawn a fresh-context general-purpose agent with `model: "sonnet"`, leaving its tools to read the project's materials available (the colleague reads the project, whatever form it takes: a codebase, a document set, a shared body of work). The prompt template is at `${CLAUDE_PLUGIN_ROOT}/skills/sorry-im-late/editor-prompt.md`; substitute `$RULEBOOK_PATH` with `${CLAUDE_PLUGIN_ROOT}/skills/sorry-im-late/rulebook.md` and `$DRAFT_PATH` with the absolute path to the draft file. Pass the result as the agent prompt. Do not add anything to the prompt that telegraphs what you hope the colleague will catch.
3. The agent returns three sections: READING (the colleague's interpretive write-back, in his own words), POLISHED (light fixes applied), and QUERIES (gaps only this conversation can close).
4. **Planner pass (opt-in via `--plan-agent`, for bug reports and feature requests).** Run this pass only when the caller invoked the skill with `--plan-agent`. Without the flag it is skipped, and only the cold-reader pass above runs. It costs a second agent and sometimes a re-run at wider scope, so it stays off by default; turn it on for a bug report or feature request that will be planned and executed. When it runs and the draft is a plannable document (a bug report or feature request), spawn a second fresh-context agent with `model: "sonnet"` using the prompt template at `${CLAUDE_PLUGIN_ROOT}/skills/sorry-im-late/planner-prompt.md`; substitute `$DRAFT_PATH` with the draft's path. Give this agent the same project access as the cold reader. It returns two lists: ERRORS (steps that cannot be executed as written) and MISSING (inputs the draft omits that the project already holds). It does not design a solution the draft has not already described. Skip the pass for emails, release notes, general documentation, and other non-plannable drafts.
   - **Adaptive scope.** Read the planner's findings. If any names a specific component, repository, or system boundary it could not reach but needs to settle an ownership or correctness claim, widen scope: re-run the planner agent with an updated prompt that explicitly points it to those materials in addition to the original scope. Surface the cross-boundary gaps that remain after the wider run as the inquiry to bring back to the caller.
5. Read the READING section first. Compare each interpretation against what you meant. Where the colleague's reading diverges from your intent, that is a defect even if no query fires, because the rule-driven checks cannot catch a confident wrong reading. Fix the draft so the next reader would resolve the same passages as you intended. Then resolve queries from your conversation, folding the answer into the draft in project terms where the matter was settled, or marking it open where the conversation never settled it rather than inventing a decision; and apply any POLISHED tightenings you agree with. When the planner pass ran, fold its ERRORS by correcting the draft and its MISSING inputs by adding them; treat the open decisions it surfaces as you would a query, since not every one needs settling now, keeping the draft a clarified statement of the work rather than a finished design.
6. Show the user the revised draft and any cross-boundary gaps the planner surfaced. Sending or publishing is the caller's act; this skill does neither.

## Files

`${CLAUDE_PLUGIN_ROOT}/skills/sorry-im-late/`:

- `rulebook.md` — the colleague's knowledge boundary and the gaps to query
- `editor-prompt.md` — the cold-reader subagent prompt template
- `planner-prompt.md` — the planner-evaluator subagent prompt template (bug reports and feature requests)

## Why a fresh-context subagent

The authoring role belongs to the caller, which holds the conversation. A subagent forked inside the same context inherits the same blindness about which sentences are conversation and which are draft. A brand-new agent that can read the project but never saw the conversation is the colleague the draft is actually for.

## Anti-cheating discipline

Rulebook examples come from outside any test fixture, so the subagent applies the rule rather than recognising a remembered phrase. The prompt carries only the rulebook path and the draft's path; no hint about the particular draft is leaked in, and the colleague reads the draft in full from its file (never a pasted or condensed copy), so the review covers every section rather than the ones the caller happened to include.
