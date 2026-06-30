# overseer-toolbox — notes for AI sessions

This repo is one Claude Code plugin. Skills live in `skills/<skill>/`, the
`browser-serialiser` harness sits in `bin/` (on PATH while the plugin is enabled),
`config.ini.example` sits in the root and `.claude-plugin/` holds the plugin
manifest, `plugin.json`. The marketplace that lists this plugin no longer lives
here; it sits in a separate repo, `overseers-desk/overseers-desk`, alongside the
sibling `office` plugin.

**Before any web-access work** (writing a new browser skill, or repairing one that broke), read the diagnosis methodology at [`../aesop/webworks/`](../aesop/webworks/README.md). It is the standing antidote to the firemaning, the premature commitment to "profile corrupt / fingerprint detected / we are rate-limited", that derails this work; the procedure and the case studies (`STORY.md`) live there.

## Conventions

- Inside a SKILL.md, reference sibling scripts and assets as
  `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/<script>`. Claude Code substitutes
  `${CLAUDE_PLUGIN_ROOT}` with the install path when the plugin loads. Prefer this
  over a hardcoded `$HOME/.claude/skills/...` for skill files.
- The harness and the policed command surface for authenticated SPAs live in the
  serialised-browsing skill: [`COMMAND-SURFACE.md`](skills/serialised-browsing/COMMAND-SURFACE.md)
  is the contract a new TCL skill is written against (the verbs, view-before-fetch,
  the per-call required headers, the type-B envelope), and
  [`BROWSER.md`](skills/serialised-browsing/BROWSER.md) is beside it. Invoke a skill by
  reference through `browser-serialiser`; do not write a raw `flock ... chromium`
  invocation inline. The same harness also runs under an external host, the
  overseer (a desktop application in a separate project); it is a compatibility
  target, not a runtime dependency, and standalone `browser-serialiser` needs no
  overseer installed (see COMMAND-SURFACE.md, "Why the sandbox holds with no
  overseer present").
- Site credentials live in `$HOME/.claude/skills/config.ini`. The path is absolute
  in the scripts and the wrapper, so it does not move with the plugin. The file is
  gitignored; do not commit it. Each skill's SKILL.md lists its keys under
  `Prerequisites`.
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

Load the plugin from disk and exercise the trigger end to end:

```bash
claude --plugin-dir . -p --dangerously-skip-permissions "<natural language request>"
```

Or inspect what the plugin exposes without running it:
`claude --plugin-dir . plugin details ot`. Calling a script directly
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
