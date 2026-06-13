# overseer-toolbox — notes for AI sessions

This repo is one Claude Code plugin. Skills live in `skills/<skill>/`, the
`browser-serialiser` harness sits in `bin/` (on PATH while the plugin is enabled),
`config.ini.example` and both manifests sit in the root. The repo is also its own
marketplace: `.claude-plugin/` holds `plugin.json` and `marketplace.json` (source `.`).

## Conventions

- Inside a SKILL.md, reference sibling scripts and assets as
  `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/<script>`. Claude Code substitutes
  `${CLAUDE_PLUGIN_ROOT}` with the install path when the plugin loads. Prefer this
  over a hardcoded `$HOME/.claude/skills/...` for skill files.
- The harness and the policed command surface for authenticated SPAs live in the
  serialised-browsing skill (`skills/serialised-browsing/COMMAND-SURFACE.md`) and
  the `BROWSER.md` beside it. Invoke a skill by reference through `browser-serialiser`;
  do not write a raw `flock ... chromium` invocation inline.
- Site credentials live in `$HOME/.claude/skills/config.ini`. The path is absolute
  in the scripts and the wrapper, so it does not move with the plugin. The file is
  gitignored; do not commit it. Each skill's SKILL.md lists its keys under
  `Prerequisites`.

## Testing

Load the plugin from disk and exercise the trigger end to end:

```bash
claude --plugin-dir . -p --dangerously-skip-permissions "<natural language request>"
```

Or inspect what the plugin exposes without running it:
`claude --plugin-dir . plugin details ot`. Calling a script directly
with `python3` or `tclsh` tests the script, not the skill trigger; a skill is not
working until `claude -p` returns real data.
