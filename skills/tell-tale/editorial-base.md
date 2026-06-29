# Editorial Base

The uppercase editorial codes shipped with `tell-tale` and loaded on every run. They pair with the lowercase anti-pattern codes in `anti-pattern.md`. A project may add its own uppercase codes through a profile passed with `--profile`; this base is always present underneath that profile.

The edit threshold treats every uppercase code alike: a line carrying any uppercase code is edited (the threshold and the rest of the process live in `SKILL.md`).

**Reserved prefixes.** This base owns the letters `W` and `D`. A project profile must use other letters for its own codes, so the namespaces never collide.

---

## Writing rules (Orwell)

Six rules from George Orwell's "Politics and the English Language" (1946), adopted as house style. They apply to content in any language: prefer the common word over the bureaucratic one in Chinese and Spanish as well.

**`W01` Never use a metaphor, simile, or other figure of speech which you are accustomed to seeing in print.** Dead metaphors ("level playing field," "move the needle," "at the end of the day") signal that the writer stopped thinking. If the image no longer produces a mental picture, drop it.

**`W02` Never use a long word where a short one will do.** "Use" not "utilise." "Begin" not "commence." "Help" not "facilitate."

**`W03` If it is possible to cut a word out, always cut it out.** Every word must earn its place. Remove filler ("it should be noted that," "in terms of," "the fact that"), qualifiers that add nothing ("very," "quite," "somewhat"), and throat-clearing introductions.

**`W04` Never use the passive where you can use the active.** "The board removed the maintainers" not "The maintainers were removed." Passive voice hides the actor, which is often the most important part of the sentence.

**`W05` Never use a foreign phrase, a scientific word, or a jargon word if you can think of an everyday equivalent.** If the audience is general, write "proof of origin" before introducing "provenance attestation." If the audience is technical, jargon is fine, but only jargon the audience actually uses, not jargon the writer finds impressive.

**`W06` Break any of these rules sooner than say anything outright barbarous.** `W01`–`W05` are defaults, not laws. When following a rule makes the sentence ugly, unclear, or misleading, break the rule.

---

## Punctuation

**`W07` Em dash, LHD-strict.** Any em dash (—) forces a rewrite of its line; one is enough. Recast so dependent words sit closer together and the dash becomes unnecessary, or replace it with a comma, parentheses, a colon, or a full stop, whichever the sense calls for. Two things are not this code and are left alone: attribution after a quotation (`"Knowledge is power." — Bacon`), and the en dash (–) in a numeric range (`pages 12–18`), which is a different mark. This is stricter than the anti-pattern taxonomy's `s05`, which tolerated a lone em dash; the office LHD rule treats a single one as a defect, so em dash lives here as a forcing editorial code rather than there as a tolerated tell.

---

## Reader state (high-level acceptance)

Before editing a single line, fix who reads this draft and in what state. The draft was almost always written for an engaged, curious reader who has time and enjoys the writer's cleverness. The real reader is the opposite. Write for the real one.

Two tests govern the whole document. A draft that fails either has not passed, however clean its individual lines read:

- **Fifth-hour test.** The reader has worked all day and is in the fifth hour, having already read twenty to thirty documents before this one. Does the text still make sense, and does it feel comfortable to read, or does it make the reader hate the job? If the draft is not clearly easier to read than the average document in that stack, it fails.
- **Midnight test.** The reader has had a few beers, a full dinner, and two hours of Netflix, then this is put in front of them. Can they still read it? If they have to sit up, fetch their glasses, or make a tea to get through it, it fails.

The skill is named *tell-tale* for two reasons, and both bear on these tests. First, good text reads as if someone tells you a tale; the failure is text that reads like a final-year examination paper. Second, the rules below are the tell-tale signs of why a text is hard, each a thing to find and remove.

These two tests are not line codes. After the line-level passes, re-read the whole draft as this reader and rewrite any paragraph that fails, including paragraphs that no code flagged.

---

## Reader-cost rules

The reader pays for every gram of difficulty the writer leaves in. Each rule below names a way a writer adds difficulty while feeling productive: the thinking was done, then the writing buried it. All are forcing; one instance rewrites the line.

**`W08` Nominalisation.** An action written as an abstract noun carried by a light verb (`is`, `are`, `was`, `use`, `provide`, `make`, `conduct`). The tell-tale sign is one of those verbs sitting where a plain verb belongs. "Sanitary standard in our household is a priority" for "clean your room"; "Access to the venue is structured around community affordability" for "anyone can afford to come." **Fix:** find the buried verb and let a person do it.

**`W09` Human-distancing.** Institutional third person and abstract subjects where a person doing a thing reads truer. "The demand-proven anchor use is the autumn market, which the works let the venue continue and scale to a monthly series" for "We run the autumn market. It works: over a thousand visitors every time. The demand is there and we cannot meet it." **Fix:** name the actor, often "we", and let them act.

**`W10` Imaginary enemy.** Piling denials or qualifications against an objection the reader never raised. "No Development Application is required: the works are at grade with no excavation, no change to levels, no sealed surface, no drainage works, no new buildings, no vegetation removal, no in-stream works" fights "no" seven times. A tired reader has no energy to assume you are guilty, and the long defence reads as guilt. **Fix:** state the positive fact once ("The works are at grade, so no Development Application is required") and stop.

**`W11` Spurious precision and attention-numbers.** A number used as a volume knob, not as information. False precision ("45.4827% hungry"), escalation ("a five- to eight-fold uplift", "the consequence is dire"), and figures the form already supplies echoed back in bold ("(Weight: 45%)") shout for attention without changing what the reader does. The shape is a toddler raising its voice. **Fix:** cut the number, or round to the one figure that drives a decision. A number earns its place only if the reader would act differently knowing it. Keep a number that is a required form field.

These overlap by design: W08 and W09 often fire on the same clause, and W02/W05 (a long or jargon word where a short one serves) carry the same instinct at word level that W08-W10 carry at clause level. Flag whichever fits; one good rewrite serves them all.

---

## Dialect

**`D01` The text departs from its declared target language variety.** This code is a conformance *check*, not a declaration of how many varieties a project should maintain. It flags a line whose spelling, vocabulary, or idiom drifts away from the variety the run was told to target (for example British English flagged for an American spelling, or Castilian Spanish flagged for a Latin-American term).

The target variety, or set of varieties, is supplied from outside this base: by the `--dialect` argument or by a project profile that declares it. `D01` carries no default target of its own. With no target declared for the run, `D01` is inert and never fires, so a run that does not care about dialect raises no dialect flags.

**Fix:** Bring the flagged word or construction into the declared target variety. When the project maintains several varieties, each variety's own content is checked against that variety; `D01` does not ask one variety's text to match another.
