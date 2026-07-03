# skillbooks

A Claude Code plugin of AI-executed skills. Each skill drives the user's own logged-in Chromium through the `browser-serialiser` harness, or talks to a site's API with the user's credentials. Claude invokes a skill automatically when a request matches its description, so you rarely type the name.

## What's inside

- **Logged-in site access:** LinkedIn, Instagram, Facebook, Reddit, Airbnb, Otter, DeviantArt, Clover, GetYourGuide.
- **Travel and award search:** Qantas Classic Rewards, RENFE, Interline cruises, IHG, Marriott, Premier Inn, Flightnetwork, SerpApi.
- **Editorial review:** edit-email, edit-economistly, sorry-im-late, quote-me.
- **Research and rendering:** build-dossier, typst-pdf, and the shared serialised-browsing harness.
- **Command-line tools:** `bin/brave-search "query" [count]` prints title/url/snippet web results from the Brave Search API. It reads its token from the same config file as the harness (`[brave.com]` `api_key`).

Skills are namespaced `skillbooks:<skill>` (e.g. `skillbooks:linkedin-com`).

## Install

```sh
claude plugin marketplace add overseers-desk/overseers-desk
claude plugin install skillbooks@overseers-desk
```

`claude plugin list` then shows it enabled. For development, load it from disk without installing; this reads the working tree live, so edits take effect without reinstalling:

```sh
claude --plugin-dir /path/to/skillbooks
```

## Prerequisites

- **Credentials.** Site skills read `$HOME/.claude/skills/config.ini` (see `config.ini.example`). Each skill's SKILL.md lists the keys it needs under `Prerequisites`.
- **Browser harness.** Browser-driving skills run under `browser-serialiser`, shipped in `bin/` and placed on `PATH` while the plugin is enabled. It launches the user's logged-in Chromium against the real user-data-dir and locks it while running, so close your everyday Chromium before invoking a browser skill. macOS needs `flock` and `gtimeout`: `brew install util-linux coreutils` (Linux ships both).
- **Logged-in sessions.** Browser skills expect an existing signed-in Chromium session for the target site. If a fetch returns a sign-in page, the session has expired; log in and retry.

The serialised-browsing skill documents the harness, its [policed command surface](skills/serialised-browsing/COMMAND-SURFACE.md) (the contract a new browser skill is written against), and the `--dump`/`--pdf` render modes.

