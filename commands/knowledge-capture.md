---
description: "Turn recorded meetings into corrected, searchable transcripts and summaries in the business repo: real names, companies and events resolved, references to earlier meetings linked. Triggers: capture meetings, knowledge capture."
argument-hint: "[no arg = last 3 days | N = last N days | <recording id> = one recording]"
---

Capture scope (the command argument): **$ARGUMENTS**. Empty means recordings created in the last 3 days.

## What this command does

A spoken source arrives imprecise. The speaker says a name the transcriber renders phonetically, refers to a company by half its trading name, calls an event "the school thing", and points back at an earlier meeting without dating it. This command turns that into a record whose names, companies and events are spelled the way the rest of the business spells them, so a future search for a person or a booking finds the meeting where it was discussed, and whose references to other meetings resolve to those meetings' files.

Email needs none of this: a writer names their people and states their subject, so it arrives resolved. The work here is on speech.

## Underlying skills

This command orchestrates; it does not drive a browser itself.

- The `otter.ai` skill for the recording platform: list, fetch a transcript, rename a recording.
- The `find-person` command when an unfamiliar person turns out to matter externally.
- Built-in WebSearch for companies, venues, brands and place names.

If the recording platform's skill is unavailable, halt and report a setup issue rather than improvising with raw browser commands.

## Model routing

Classification, correction and entity resolution want Sonnet. Under Opus or any non-Sonnet main session, delegate the whole run to a Sonnet subagent, passing the capture scope and a pointer to this command so the subagent reads these steps and runs them. Escalations to `find-person` are the subagent's to make.

## Step 1 — discover the businesses

Each business is a repo containing a `knowledge-capture/` folder. Glob `"$HOME/code"/*/knowledge-capture/precis.md` (a path argument overrides the scan root). Read every `precis.md`: each names a business, its people and its recognition cues. The business-folder basename is the routing key and the recording-title prefix.

## Step 2 — list and filter

List recordings at page size 100. Keep those whose `created_at` falls inside the window and whose title is not already a done-signal — skip titles matching `<business-folder>/*.txt` (captured by this pipeline) or a bare `*.txt` (legacy). A single-recording invocation skips both filters.

## Step 3 — per recording

### 3.1 Fetch and classify

Fetch the transcript. Read it against the precis set and decide the single owning business, applying the subject-versus-context rule each precis carries: the business the meeting is *about* owns it, even where another appears as a venue or as a speaker's other venture.

No business matches (school, medical, family, or no business at all): skip, writing and renaming nothing, and report it as not business. Exactly one: proceed. Two or more co-equal subjects: ask the user which owns it; unattended, take the most central subject and record the secondary business in the staging frontmatter and the report.

### 3.2 Already-captured check

Step 2's title filter catches only recordings this pipeline renamed. One transcribed by an earlier run, or saved under a different filename, still looks new, and re-capturing duplicates it.

`created_at` is a UTC epoch and filenames carry the local date, so a recording near midnight lands on the adjacent day: derive the local date and test the day before and the day after as well. List `knowledge-capture/incoming/` and `knowledge-capture/staging/` for files whose `YYYY-MM-DD` prefix is any of those three dates, and read each candidate. A single day holds several meetings, so confirm identity by participants, topic and distinctive facts rather than by date. Where one is the same meeting, skip to the rename (§3.10) pointing the done-signal at the existing file's stem, and report it as already captured. Only where no candidate matches does the run continue.

### 3.3 Correct against the glossary

Correct against the owning repo's `knowledge-capture/capture-correction-index.md`. Read the whole index and the whole transcript and correct holistically; a grep for a wrong spelling cannot find mistranscriptions, which vary without limit. Fix names, places and domain terms, and remove stutter, filler and false starts. A false start is a statement abandoned before it is complete; a completed statement the speaker later withdraws is a retraction, and it stays with its withdrawal. Nothing else changes: what was asserted, by whom, with what hedge or condition, with what figure and with what strength. That includes accusations and suspicions about named people, unkind or unproven statements, rebuttals, and swearing that carries the speaker's feeling. Add no hedge the speaker did not use. A stretch that cannot be made out becomes `[unclear]`, and a speaker label changes only where the content makes the speaker certain. A capture is quoted later as the record of the meeting, in HR and dispute files among others: a changed assertion misstates that record, and a dropped word (drugs, theft) is missing from every search for it. Strip any transcription-service suffix the recording carried. Keep the transcript as fetched in scratch for §3.7.

### 3.4 Resolve what the glossary does not know

The glossary holds the entities the business has already met. This step handles the rest: a new supplier, a visiting agent, a company named once, an event referred to obliquely. An entity resolved here becomes a search keyword; one left as the transcriber heard it is invisible to every future search.

Collect the candidates first. A candidate is a proper noun or noun phrase naming a person, an organisation, a venue or an event, which the glossary does not cover. Then work the ladder, stopping at the first rung that confirms.

1. **The repo's own records.** Most names spoken today have been written down somewhere in the business already. Search `contacts.md`, the `sot/` files (contacts and suppliers, department structure, past staff, the guest calendar), and the existing capture corpus. This rung is free and resolves the majority.
2. **The capture corpus by sound.** A person or company mentioned in an earlier meeting may sit in `incoming/` under a different mishearing. Search the corpus for phonetic neighbours of what was said, not the literal string.
3. **The mailbox, where a mail tool is installed.** A meeting that says "Chantelle and Mark are coming this week with their circus tent" is preceded by a thread that arranged it, and the thread carries the surname, the company, and the date. Written correspondence states plainly what speech leaves to context, which makes it the strongest rung for anyone the business has actually dealt with. `courier` covers this where the operator has it (`courier install-claude-commands`); use whatever mail tool the environment offers, and where none is installed, skip to the next rung rather than treating the entity as unresolvable. Search on the name as heard and on the topic beside it, since the spelling in the mailbox is the one you are trying to find.
4. **One web search.** Place names, brands, local businesses and venues usually resolve in a single search. Where the business is Australian and the candidate looks like a sole trader or small company, an ABN lookup returns the registered legal name.
5. **`find-person`**, for a person who turns out to matter externally: a supplier, an agent, a counterparty, someone with a decision to make about the business. A first name mentioned once in passing does not warrant the fan-out.

Write a resolved form into the transcript only where the evidence names it: for a person, a match on role or organisation as well as name; for a company, a registry or website record; for an event, an entry in the guest calendar or an earlier capture. Where the ladder ends without confirmation, leave what was said and list the term in the run report — an invented spelling is worse than a heard one, because it greps.

A resolved event carries its own name where the business has one. "The school thing" becomes the booking as the guest calendar names it.

### 3.5 Link the meetings this one refers to

A transcript points back at earlier discussions without naming them: last week's board meeting, the conversation with the celebrant, "what we agreed with Michal". Each such reference is a link waiting to be made, and the corpus is where it resolves.

For each reference, search `incoming/` and `staging/` on the three signals the reference gives: the date it implies relative to this recording, the participants it names, and the topic. Filenames carry date, topic and people, so filenames narrow the field before content confirms it.

Record a confident match as the other file's stem, without a path or an extension, so the link survives a move. Where two candidates are equally plausible, record both and mark them as such rather than choosing. Where nothing matches, leave the reference unlinked and say so in the report — the meeting may predate the corpus or never have been recorded.

### 3.6 Frontmatter and files

Prepend to the corrected transcript:

```yaml
---
date: YYYY-MM-DD
participants: [names, as resolved]
problems:
  - summary: one-line statement of a specific problem the meeting addressed
    detail: names, dates, concrete specifics — a solution is not a problem
    <taxonomy>: [codes]
---
```

One entry per distinct problem. The `<taxonomy>` key belongs to the target repo: use what its correction index defines, and omit the line where it defines none.

The staging document carries the search surface:

```yaml
---
date: YYYY-MM-DD
people: [resolved names, internal and external]
organisations: [companies, agencies, suppliers, schools]
events: [named bookings, functions, public events]
related_meetings:
  - stem: YYYY-MM-DD-topic-people
    basis: what the transcript said, and what matched it
    confidence: confirmed | probable
---
```

Omit a key with nothing under it. The corrected transcript carries its entities inline, spelled correctly, which is what makes it searchable; the staging block is the index over them, so there is one authoring pass and no second list to maintain.

Both files are written into someone else's repository, so that repository's own conventions govern them: read its `CLAUDE.md` and any `INVARIANTS.md` before writing, not only the `knowledge-capture/README.md`. A house style on spelling, on escaping, or on what a document may contain applies to a capture exactly as it applies to anything else committed there.

Name the file `YYYY-MM-DD-topic-key-people`: lowercase, hyphenated, the recording's date unless the content clearly indicates another, two or three key people. Write both files into the owning repo — `knowledge-capture/incoming/<name>.txt` for the corrected transcript with its frontmatter, and `knowledge-capture/staging/<name>.md` for a prose summary in topic sections with line ranges back to the transcript, covering decisions, facts, names, numbers, methods and reasoning, in British English. Where the repo's `knowledge-capture/README.md` documents a staging format, it governs.

The summary and the `problems` entries attribute any suspicion, allegation or proposal to the person who voiced it, and state none of them as fact or as a decision. They keep the transcript's word for it (drugs, theft, lying), since a gentler category such as welfare concerns hides the meeting from a later disciplinary search.

### 3.7 Check fidelity against the recording

A fresh-context Sonnet reader receives the transcript as fetched in §3.1, the corrected transcript, the staging summary and the correction index. It lists every changed assertion, dropped or added hedge, reattribution and altered figure, and every accusation, rebuttal or meaningful swearing that was dropped. A name, place or term corrected as the index records, or as §3.4's evidence supports, is the correction this command exists to make, and the reader leaves it alone; undoing it hides the meeting from a search for that person. The reader is a subagent, or `claude -p --model sonnet` where the run is itself a subagent and cannot spawn one; it is never the context that did the correction, which reads its own version as faithful. Correct each listed item back to what the fetched transcript says. An item the fetched text cannot settle becomes `[unclear]`. The capture commits only when the list is clear.

### 3.8 Return what was resolved to the glossary

The glossary is loaded whole into every later capture, so it is a working reference and not a register of everyone the business has met. An entity earns a line by being likely to recur: a colleague, a supplier or counterparty the business deals with repeatedly, someone influential, a term the speakers use often. A customer named once, an entity the transcript can barely identify, and a mishearing that arose from one speaker stumbling over a word all stay out, however confidently resolved — they cost every future capture context and buy nothing back.

An entity that clears the bar goes into the owning repo's `capture-correction-index.md`, in the section its type belongs to, carrying the mishearings this transcript produced and a short note of what confirmed it. The next capture then gets it from rung zero. Add only confirmed entities; a term still uncertain stays in the run report.

### 3.9 Commit

`git add` the transcript, the staging document and the glossary if it changed, then commit as `Add <name>`. A failed commit stops this recording before the rename.

### 3.10 Mark the recording done

Rename the recording to `<business-folder>/<name>.txt`, or to the existing file's stem where §3.2 found one. The next run reads the prefix and skips it. Read-back verification scans only the recent-recordings page, so renaming an older recording can report a false failure; confirm by fetching the recording's title rather than trusting the verify flag.

## Step 4 — report

Per recording: title, owning business, fetch, commit and rename status. Then the three things this command exists to produce, which the user reads to know whether the record is trustworthy:

- Entities resolved, each with the rung that resolved it, and entities left unresolved with what was tried.
- Meetings linked, each with its basis, and references that resolved to nothing.
- Glossary entries added.
- The fidelity check: items found, items corrected, and items left `[unclear]`.

List skipped recordings with the reason.
