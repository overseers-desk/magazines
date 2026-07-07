# magazines

A Claude Code plugin of AI-executed skills. Each skill drives your own logged-in Chromium through the `browser-serialiser` harness, or talks to a site's API with your credentials. Claude invokes a skill automatically when a request matches its description, so you rarely type the name.

**A Chromium browser is required.** Everything here works by acting as you inside your own browser profile, so there is nothing to install per site and no passwords to hand over.

## How the browser skills work

You sign in to a site once in your own Chromium browser, the ordinary way, then quit Chromium. The harness drives that same profile in headless mode, so a skill arrives at the site already logged in as you and never needs a site password. Chromium must be closed while a skill runs, because the harness holds the browser profile's lock for the duration. This is the operating model for every site skill: log in, close the browser, let the skill work.

## What's inside

- **Logged-in site access:** LinkedIn, Instagram, Facebook, Reddit, Airbnb, Otter, DeviantArt, GetYourGuide, and others.
- **Travel and award search:** Qantas Classic Rewards, RENFE, Interline cruises, IHG, Marriott, Premier Inn, Flightnetwork.
- **Slash commands (typed, `/magazines:<name>`):** `build-dossier` and `find-person` drive the site skills into a source-cited brief; `serpapi` runs Google Flights, Search, Maps, and Hotels lookups.
- **Command-line tools:** `bin/brave-search "query" [count]` prints title/url/snippet web results from the Brave Search API. It reads its token from the same config file as the harness (`[brave.com]` `api_key`).

Skills are namespaced `magazines:<skill>` (e.g. `magazines:linkedin-com`) and Claude invokes them automatically; the three commands you type yourself as `/magazines:build-dossier`, `/magazines:find-person`, `/magazines:serpapi`.

## Install

```sh
claude plugin marketplace add overseers-desk/overseers-desk
claude plugin install magazines@overseers-desk
```

`claude plugin list` then shows it enabled. For development, load it from disk without installing; this reads the working tree live, so edits take effect without reinstalling:

```sh
claude --plugin-dir /path/to/magazines
```

## Prerequisites

- **Chromium.** The browser skills drive a real Chromium (or a Chrome-compatible browser) against your own profile. Install it from your OS package manager or from chromium.org. Sign in to the sites you want a skill to reach, then close Chromium before invoking one.
- **Credentials.** Site skills read `~/.config/magazines/config.ini` (or `$XDG_CONFIG_HOME/magazines/config.ini` when that is set). Copy the top-level `config.ini.example` there and fill in the keys each skill's SKILL.md lists under `Prerequisites`.
- **Tcl 9+.** The `browser-serialiser` harness and the browser skills' scripts run on `tclsh` 9 or newer; 8.x is not supported. macOS: `brew install tcl-tk`. Linux: install your distribution's Tcl 9 package.
- **Browser harness.** Browser-driving skills run under `browser-serialiser`, shipped in `bin/` and placed on `PATH` while the plugin is enabled. It launches the user's logged-in Chromium against the real user-data-dir and locks it while running, so close your everyday Chromium before invoking a browser skill. macOS needs `flock` and `gtimeout`: `brew install util-linux coreutils` (Linux ships both).
- **Logged-in sessions.** Browser skills expect an existing signed-in Chromium session for the target site. If a fetch returns a sign-in page, the session has expired; log in and retry.

The serialised-browsing command documents the harness, its [policed command surface](COMMAND-SURFACE.md) (the contract a new browser skill is written against), and the `--dump`/`--pdf` render modes.

