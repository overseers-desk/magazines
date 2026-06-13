# LinkedIn Connect Automation — Reconnaissance Notes

Date: 2026-04-05

## Status

The `/linkedin` skill handles search, profile parsing, keyword search, and connect eligibility verification using `--dump-dom`. Sending a connection request (with or without a note) requires browser automation beyond `--dump-dom` — that is the next step.

## Connect flow structure (as of April 2026)

### Entry point

The connect button on a profile page is an `<a>` tag linking to:

```
/preload/custom-invite/?vanityName=USERNAME
```

This URL is constructable directly from a vanity name — no profile DOM parsing needed.

### Modal (rendered by `--dump-dom`)

The custom-invite page renders an Ember.js modal inside `<div id="artdeco-modal-outlet">`:

```
Header:  <h2 id="send-invite-modal">Add a note to your invitation?</h2>
Body:    <p>Personalize your invitation to <strong>[Name]</strong> by adding a note.
         LinkedIn members are more likely to accept invitations that include a note.</p>
Buttons: <button aria-label="Add a note" class="artdeco-button--secondary">Add a note</button>
         <button aria-label="Send without a note" class="artdeco-button--primary">Send without a note</button>
```

Premium accounts see an extra line: "You have unlimited notes with Premium".

Some high-profile accounts require email verification — an `<input type="email">` appears with text "please enter their email to connect".

### What `--dump-dom` cannot reach

The "Add a note" textarea is injected dynamically when the "Add a note" button is clicked. It does not exist in the initial DOM. Similarly, the "Send" action requires a button click. Therefore, sending a connection (with or without a note) requires one of:

1. **Puppeteer / Playwright** — launch browser, navigate to custom-invite URL, interact with modal.
2. **Chrome DevTools Protocol (CDP)** — connect to a running Chromium instance via `--remote-debugging-port`, send click/type commands.
3. **Voyager REST API** — POST directly to LinkedIn's internal API with CSRF token and session cookie. The invitation API uses type `com.linkedin.voyager.dash.relationships.invitation.Invitation` with fields: `inviteeMember` (member URN), `message` (the note text), `sharedSecret`, `invitationState`, `invitationId`.

### Recommendation for next step

Option 1 (Puppeteer/Playwright) is the most straightforward. The flow would be:

1. Launch browser with the existing profile (cookies).
2. Navigate to `https://www.linkedin.com/preload/custom-invite/?vanityName=USERNAME`.
3. Wait for `#send-invite-modal` to appear.
4. If note desired: click the "Add a note" button (aria-label match), wait for textarea, type message, click Send.
5. If no note: click "Send without a note".
6. Confirm success (page state change or redirect).

The page uses reCAPTCHA (`g-recaptcha-response` textarea exists in DOM) but it does not appear to activate for normal logged-in sessions.

## DOM parsing notes

- CSS class names are randomised per session (e.g. `_38cb7509 d1e9ae31`). Select by `id`, `aria-label`, `data-test-*`, or tag structure — never by class.
- Stable selectors found: `id="send-invite-modal"`, `aria-label="Add a note"`, `aria-label="Send without a note"`, `data-test-modal-close-btn`, `data-test-send-invite-modal-check-email-link`.
- The modal uses `artdeco-modal` component framework (Ember.js). Element IDs like `ember34` change between loads but the structure is stable.
- Page locale follows the account's language setting (e.g. Spanish: "Invita a [Name] a conectar", "Enviar sin nota"). Use aria-labels for detection as they appear to be English regardless of locale.

Wait — the aria-labels might also be localised. On the Spanish account, aria-label was still in English ("Add a note", "Send without a note"). This needs verification if accounts in other locales (Chinese, Arabic) are used.

## LinkedIn experiment flags observed (for future reference)

These LIX (LinkedIn Experiment) keys appeared in the custom-invite page JSON state. They govern the connect flow and might change behaviour in future:

- `voyager.web.messaging-custom-invite` — gates the custom-invite flow itself
- `voyager.web.premium-magic-wand-custom-invites` — AI-generated note suggestions (Premium)
- `voyager.web.premium-custom-invite-copy-test-free` — copy variants for free users
- `voyager.web.premium-custom-invite-copy-test-premium` — copy variants for premium users
- `voyager.web.premium-custom-invite-last-credit-upsell` — upsell when last free note credit used
- `voyager.web.premium-custom-invites-unlimited-notes-callout` — "unlimited notes" banner
- `voyager.infra.web.connection-count` — segments by connection count (LT_30, LT_500, etc.)

## Retiring the old method

The skill at `~/.claude/skills/linkedin/` replaces `aesop/linkedin-lookup-method/`. The scripts (`parse-search.tcl`, `parse-profile.tcl`, `keyword-search.tcl`) are copied into the skill directory. Once confirmed working, remove the LinkedIn lookup line from `~/.claude/CLAUDE.md` and optionally delete the old directory.
