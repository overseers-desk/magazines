# magazines — notes for AI sessions

This repo is one Claude Code plugin. The layout and sandbox rules that must
hold are in [`INVARIANTS.md`](INVARIANTS.md); a change that breaks one is a
design change, the owner's to make. `config.ini.example` sits in the root. The
marketplace that lists this plugin sits in a separate repo,
`overseers-desk/overseers-desk`.

@INVARIANTS.md

**Before any web-access work** (writing a new browser skill, or repairing one that broke), read the diagnosis methodology at [`../aesop/webworks/`](../aesop/webworks/README.md). It is the standing antidote to the firemaning, the premature commitment to "profile corrupt / fingerprint detected / we are rate-limited", that derails this work; the procedure and the case studies (`STORY.md`) live there.

## Conventions

- The harness (`bin/browser-serialiser`) and the policed command surface for
  authenticated SPAs: [`COMMAND-SURFACE.md`](COMMAND-SURFACE.md) is the contract a
  new TCL skill is written against (the verbs, view-before-fetch, the per-call
  required headers, the type-B envelope), sitting at the top level beside `bin/`
  and `lib/`, and [`BROWSER.md`](docs/BROWSER.md) records the rationale. The same
  harness also runs under an external host, the overseer (a desktop application
  in a separate project); it is a compatibility target, not a runtime dependency,
  and standalone `browser-serialiser` needs no overseer installed (see
  COMMAND-SURFACE.md, "Why the sandbox holds with no overseer present").
- A skill that prices flights (an airline site, an OTA, a metasearch) takes its query and
  reports its answer per [`FLIGHT-SEARCH.md`](FLIGHT-SEARCH.md), so sites swap
  without the request changing and two answers sit side by side.
- Every entry under `skills/` is a website skill, named for the site's domain and
  reaching that one site. Work that orchestrates several of them, or that does no
  browsing at all, is a command under `commands/` (`find-person`,
  `knowledge-capture`). A workflow placed in `skills/` reads as a site and gets
  invoked as one.
- Each skill's SKILL.md lists its config keys under `Prerequisites`.
- A SKILL.md `description` is a discovery surface, not documentation: its only job
  is to make the model invoke the skill when the situation calls for it. How the
  skill works belongs in the body and scripts, which the model reads after it
  decides to call, with all the time it needs then. Writing the description as a
  how-it-works account is the failure AI-written READMEs share. Write it as the
  trigger instead: name the problem or symptom that should make the model reach
  for the skill — a 403, a blocked fetch, a login-walled page — not what the
  skill is or does, since the model matches on its own situation, not on the
  skill's machinery. Do not restate the skill's name or open with a
  self-referential preamble ("this skill uses a headless browser to ..."): the
  description always renders after the name, so the model already knows it is a
  skill and what it is called. Cut to the bare offer — "headless browser for X",
  not "this skill browses X with a headless browser". Keep it to 25 words; 40 in
  exceptional cases; anything longer is a bug to cut, not a richer description.

## Testing

Load the plugin from disk and exercise the trigger end to end, with the working
tree's `bin/` ahead of the installed one:

```bash
PATH="$PWD/bin:$PATH" claude --plugin-dir . -p --dangerously-skip-permissions "<natural language request>"
```

The PATH half is what makes this a test of the working tree. `--plugin-dir`
loads the skill definitions from disk, but a browser skill's SKILL.md tells the
model to run `browser-serialiser`, which resolves through PATH to the installed
plugin cache, whose tree is pinned at the commit that was installed. Without it
the model reads the new SKILL.md while the harness runs the old script, and the
run comes back in the previous output shape as though the change had not been
made. The override covers delegation too: the serialiser hands an overseer the skill path this checkout resolved, so a delegated run also executes the file being edited.

The `PATH="$PWD/bin:$PATH"` form is for the session doing the editing. Any
other session, and any batch job, runs skills from the installed plugin, not
from this checkout. A checkout being edited can be broken between two edits,
and a run that picks up that moment fails as if the skill were broken.

The checks run themselves rather than being handed to `tclsh`: each carries the
same trampoline `bin/browser-serialiser` uses, so it runs on the newest
interpreter present. Running one as `tclsh <file>` bypasses the trampoline and
tests different behaviour from the one the harness has.

    ./lib/serialiser-harness-selftest.tcl
    ./lib/session-contract-selftest.tcl
    ./lib/cdp-client-selftest.tcl

Or inspect what the plugin exposes without running it:
`claude --plugin-dir . plugin details magazines`. Calling a script directly
with `python3` or `tclsh` tests the script, not the skill trigger; a skill is not
working until `claude -p` returns real data.

Each `claude -p` has a warm floor of ~4s (process spawn + auth + one model
round-trip) — inherent per invocation, not a bug. Measured: MCP servers and
model tier are **not** the cause (disabling MCP with `--strict-mcp-config`, or
switching to `--model haiku`, does not move it), so do not chase them. The first
run right after `plugin install` is slower (one-off marketplace cache refresh).
Therefore: batch several checks into ONE `-p` call rather than spawning many,
and keep a discovery probe tiny — ask only for the skill name (`is there a
linkedin skill? name only`), not its description.
