# overseer-toolbox

A Claude Code plugin of AI-executed skills. Each skill drives the user's own logged-in Chromium through the `not-google-chrome` wrapper, or talks to a site's API with the user's credentials. Claude invokes a skill automatically when a request matches its description, so you rarely type the name.

## What's inside

- **Logged-in site access:** LinkedIn, Instagram, Facebook, Reddit, Airbnb, Otter, DeviantArt, Clover, GetYourGuide.
- **Travel and award search:** Qantas Classic Rewards, RENFE, Interline cruises, IHG, Marriott, Premier Inn, Flightnetwork, SerpApi.
- **Editorial review:** edit-email, edit-economistly, sorry-im-late, quote-me.
- **Research and rendering:** build-dossier, typst-pdf, and the shared headless-browser fallback.

Skills are namespaced `ot:<skill>` (e.g. `ot:linkedin-com`).

## Install

```sh
claude plugin marketplace add git@github.com:SmartLayer/ot.git
claude plugin install ot@ot
```

`claude plugin list` then shows it enabled. For development, load it from disk without installing; this reads the working tree live, so edits take effect without reinstalling:

```sh
claude --plugin-dir /path/to/overseer-toolbox
```

## Prerequisites

- **Credentials.** Site skills read `$HOME/.claude/skills/config.ini` (see `config.ini.example`). Each skill's SKILL.md lists the keys it needs under `Prerequisites`.
- **Browser wrapper.** Browser-driving skills call `not-google-chrome`, shipped in `bin/` and placed on `PATH` while the plugin is enabled. It launches the user's logged-in Chromium against the real user-data-dir and locks it while running, so close your everyday Chromium before invoking a browser skill. macOS needs `flock` and `gtimeout`: `brew install util-linux coreutils` (Linux ships both).
- **Logged-in sessions.** Browser skills expect an existing signed-in Chromium session for the target site. If a fetch returns a sign-in page, the session has expired; log in and retry.

The headless-browser skill documents the wrapper, its flags, and the `--cdp` convention for authenticated single-page apps.
