# Invariants

Rules whose breach is a design change, not a fix; changing one is the owner's decision.

- Skills live in `skills/<skill>/`, the shared harness in `bin/`, the plugin manifest in `.claude-plugin/`: the Claude Code loader discovers by these paths, so a file placed elsewhere silently does not ship.
- A SKILL.md references its sibling scripts and assets as `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/<file>`: the plugin runs from a per-machine install cache, so a hardcoded home path works only on the machine that wrote it.
- Site credentials live in `$HOME/.config/magazines/config.ini`, gitignored, outside the tree: a credential committed to this repo is published, and the config's absolute path is what lets it survive plugin reinstalls.
- A skill reference resolves inside `skills/` and nowhere else, and a skill's code sources only its own directory and `lib/`: the sandbox boundary is those two paths, so a skill cannot grow an undeclared dependency on another skill, and deleting any one skill leaves every other standing. Elaboration: `COMMAND-SURFACE.md`.
- Browser work goes through `browser-serialiser`, never an inline `flock ... chromium` launch: the serialiser is the one gate where pacing and the sandbox hold, and an inline launch bypasses both.
