# Browser strategy for skills

## Editorial rule

The word **Chrome** appears in this repository under three permitted forms only:

1. As part of the unsuitability argument that follows in this file — explaining why Chrome the product is not used.
2. As part of the phrase **Chrome-compatible**, used to describe a class of browsers, a User-Agent shape, or a binary surface.
3. As part of a technology name defined by Chrome — for example **Chrome DevTools Protocol** (CDP) — where the word is the proper name of the technology, not a reference to the product.

It must not appear as a product reference outside form 1. New code or documentation that names Chrome as the product to use, install, or launch is to be rewritten in terms of Chromium. This is because Chrome has an outsized representation in LLM training data, any mention of Chrome once in documents or code, AI starts to launch Chrome when this document detailed why we chose to use Chromium for the skills.

The word **Chromium** in this repository should be changed to Chrome-compatible when it refers to generic idea of Chrome-like browsers such as Chromium.

## Problem

Skills that reach the web face a tangle of related problems.

1. Some target sites refuse to log in inside Cursor's MCP browser, inside headless Chrome with a separate user-data-dir, or inside any session that registers as "obviously automated." The user has been denied at login this way and the exact triggering signal was never isolated.
2. Chrome 136 and later (released April 2025) refuse `--remote-debugging-port` and `--remote-debugging-pipe` whenever `--user-data-dir` points at the default user-data-dir. Browser skills that need the cookies there cannot use Chrome at all.
3. Chrome on macOS hangs after `--dump-dom` finishes rendering. Even where the user-data-dir restriction would not bite, the dom-dump skills cannot exit cleanly.
4. Each browser-using skill independently encounters the same questions: which binary, which user-data-dir, what to do when the user is not logged in, how to ask the user to log in. Without a shared answer, every new skill rediscovers the constraints and each prompts the user with different wording when cookies are missing.
5. The bot-detection question itself is open-ended. Datadome, Akamai Bot Manager, PerimeterX, Cloudflare, and hCaptcha each run their own probes (CDP runtime side-effects, headless markers, fresh-session signals, mouse-entropy scoring), and the probes change without notice. Walking into that space costs days and yields a fix that may break on the vendor's next deploy.
6. A skill that drives an authenticated SPA cannot use a one-shot DOM dump; it needs a browser that stays up across a multi-step CDP flow and is then taken down. A one-shot render is killed while its launcher is still its parent, so the launcher's signal always reaches it. A persistent browser is the hard case: when its launcher returns, the still-running browser is reparented to the user service manager, and a kill aimed at the PID captured at launch lands on nothing. Left running, it holds the user-data-dir lock and its Singleton symlinks, and the next launch fails. The process facts behind this are in `chromium-process-model.md`.

## Decisions

The following decisions resolve the problems above.

**D1. Use Chromium, not Chrome.** Resolves problems 2 and 3. The currently installed Chromium build (from the snap channel on Linux, the Homebrew cask on macOS) does not enforce the upstream user-data-dir restriction that Chrome 136+ ships, and Chromium exits cleanly after `--dump-dom` on macOS. Recorded in commit `5d1dc6f`.

**D2. Use the user's real, logged-in user-data-dir, not a fresh one.** Resolves problem 1 in the most direct way available: a session indistinguishable from the user's own activity is hard to flag, because it is the user's own activity. A fresh user-data-dir fails both fingerprinting probes and account-level "new device" heuristics; the operational cost of using the live one (see D5) is accepted in exchange.

**D3. Decline to diagnose why Cursor's MCP browser was denied on specific sites.** Resolves problem 5 by not entering it. Whether the cause was CDP runtime side-effects, headless markers (software WebGL, screen-size leaks, Sec-CH-UA mismatches), or fresh-session signals, the design chosen under D2 sidesteps all three categories at once. A diagnosis tuned to one probe is bypassed when the vendor adds another.

**D4. Browser skills use uniform wording when cookies are missing.** The convention is "please open Chromium, log in to X, then tell me to proceed." Resolves problem 4 on the human-facing side. Implementation lives inside each skill; the prompt wording is the cross-skill contract.

**D5. Sessions are short-lived and exclusive on the user-data-dir.** Chromium locks `--user-data-dir` for the duration of the process. Two browser skills cannot run in parallel against the same user-data-dir, and the user's Chromium has to be closed while a skill runs (user use it to login then close to leave ai working using it). The design accepts this rather than holding a long-running browser process, so the user can inspect login status.

**D6. The serialiser harness owns the CDP browser lifecycle; the skill is a pure websocket peer.** Resolves problem 6. The harness launches the browser, waits for a page target, drives the skill over that websocket through `cdp-client.tcl`, and reaps the browser on every exit path. Because a persistent browser reparents when its launcher returns (`chromium-process-model.md`), the reap finds it by a stable attribute, its `--remote-debugging-port` string, rather than by a PID captured at launch: SIGTERM to let it flush, then SIGKILL, then removal of any Singleton symlinks a SIGKILL leaves pointing at a dead PID. A skill therefore holds no browser PID and never launches a browser of its own; the policed verbs read the websocket and drive the page. Recorded in commit `cd951b0`.

## Resulting state

Skills split into two groups by whether the decisions above apply.

**Browser skills** ride D1-D5. Examples: otter.ai, ihg.com, qantas.com, linkedin.com, facebook.com, instagram.com, supplier.getyourguide.com, atdw-online.com.au, australia.skal.org, interlinetravel.com.au, deviantart.com, marriott.com. Each runs Chromium against the user's user-data-dir through the serialiser harness, which dumps DOM or hosts a CDP session, runs the task, exits, releases the lock.

**API / non-browser skills** are not affected by D1-D5 because they do not touch a browser. Examples: serpapi, renfe.com, claude-api, send-email, mailroom. Credentials live in environment variables or `~/.claude/skills/config.ini`.

User-data-dirs per platform: `~/snap/chromium/common/chromium` on Linux snap, `~/.config/chromium` on Linux non-snap, `~/Library/Application Support/Chromium` on macOS (Chromium installed via the Homebrew cask). The snap-vs-non-snap probe and the canonical launch flags live in `bin/browser-serialiser`, the harness all skills run under.

When a skill written for the future runs into a login denial on a target site, the first action is not to harden the fingerprint. The first action is to verify the user is actually logged in inside the same Chromium user-data-dir, run the page in a non-headless Chromium to confirm the account itself works, and only then ask whether D3 needs revisiting for that specific site.

## Caveats worth tracking

- D1 rests on a snap/distro version observation, not an architectural guarantee. Upstream Chromium has the user-data-dir restriction patch. If the snap channel ever ships a build that adopts it, every browser skill breaks at the CDP launch step and there is no fallback wired in. A periodic check of `chromium --version` against the upstream announcement is the only early warning.
- D2 does not eliminate fingerprint detection. The software WebGL renderer that comes with `--disable-gpu` is detectable, and some sites may still deny on that signal even with the user's real user-data-dir. Treated as a residual failure mode handled per-skill if it becomes recurring, not by reopening the global strategy.
- The snap and non-snap Chromium variants read different user-data-dirs and are not interchangeable. The user logs in once in whichever variant is installed; skills follow the same variant.
- D6's reap is platform-aware: the Singleton-symlink cleanup is Linux-only (it checks PID liveness through `/proc`). On macOS there is no user service manager to reparent the browser and the Homebrew launch execs in place, so a per-PID SIGTERM then SIGKILL suffices.
- **Profile startup must be "Open the New Tab page", not "Continue where you left off".** Under resume-last, every headless launch restores the previous session's tabs; a one-shot render (`--dump` or `--pdf`) then waits for all of them to finish loading and hangs forever with no output, because authenticated tabs (LinkedIn, Facebook) hold persistent connections that never reach network-idle. The profile must therefore carry `restore_on_startup:5` (New Tab page) before a render runs against it. CDP is immune: it opens its own target and reads the DOM on a timer rather than waiting for the browser to settle. This was the cause of the recurring "profile corruption" (a fresh profile worked, a used one did not), and creating new profiles only resets it until the saved session refills.

  The constraint bounds the paradigm. Some sites keep the login only in a session cookie that Chromium drops when the browser closes, and "Continue where you left off" is the one setting that preserves such cookies across a close. So the normal flow, where the user logs in, closes the browser, and hands the rest to an agent that later finds the session expired on close, cannot be served for a site that expires its session on closure: keeping the session alive needs resume-last, which breaks the render, and turning resume-last off loses the login. Such a site needs the login performed inside the same run over CDP, or a browser that is never closed.

## Playwright as a future alternative

Playwright is the obvious off-the-shelf alternative and is held out today on detection grounds, not capability grounds. The gap that once separated the two has closed: every serialiser path now attaches CDP (`--dump` and `--pdf` read the DOM and print the page over the same debugging port the skill paths use), so the old advantage of a no-CDP render mode is gone. A site that probes for CDP attachment sees it on a serialiser session as it would on a Playwright one.

The non-discriminators are worth naming so the comparison stays honest. UA can be set on either side. The logged-in user-data-dir can be reused on either side (`userDataDir` in Playwright), and a staff member running either solution from a fresh machine has to log in once either way, so account-level "known device" history accrues equivalently. The system Chromium binary can be driven on either side (`executablePath` in Playwright). `navigator.webdriver` and a small set of automation observables remain visible on Playwright but are addressable with a stealth patch.

With every browser path on CDP, the remaining gap narrows to those observables, and Playwright becomes a like-for-like replacement on the detection front. The case for staying on the in-house harness now rests on the policed command surface and the central rate budget, not on a structural detection edge, and a Playwright swap is worth re-evaluating on that footing.
