# Validating the profile-edit capabilities

This document gives the validation method for each row of the "What this skill
can and cannot edit" table in SKILL.md. Use it when an edit run fails, when you
suspect LinkedIn changed its edit DOM, or when you want to assess building one of
the unautomated sections.

Last validated: 2026-06-25, against the signed-in account, on LinkedIn's
server-driven-UI profile (edit forms carry `componentkey="com.linkedin.sdui…"`).

## Preconditions (check these first, every time)

1. **Session live.** `browser-serialiser linkedin.com/login --check` must report
   `already_logged_in`. Anything else (a sign-in title, a terminal `logged-out`)
   means the failure is the session, not the edit DOM.
2. **Own profile resolves.** `/in/me/` redirects to the signed-in account's
   profile (`/in/<slug>/?isSelfProfile=true`). No slug is hardcoded anywhere.
3. **Editors lazy-mount.** The rich-text editors render only after the form is
   scrolled into view. Any field inventory taken before a scroll pass will miss
   them. Scroll the whole page (`for (var y=0;y<=document.body.scrollHeight;y+=400) window.scrollTo(0,y)`),
   settle, then query.

## Per-capability validation

### Headline (claimed: automated)

Run `browser-serialiser linkedin.com/set-profile-field headline --dump`.
Expect `{"status":"dump","field":"headline","current_len":N,"current":"<your headline>"}`
with the current headline text. This exercises the whole open+locate path without
saving.

If it returns `{"status":"error","reason":"… editor not ready"}`:
- the intro route `/in/me/edit/intro/` may no longer render the form inline, or
- the headline editor is no longer the single `[role="textbox"]` in that form.
Re-recon: nav `/in/me/edit/intro/`, scroll-hydrate, count `[role="textbox"]` and
read the element near the "Headline*" label / the `headlineCounterRefIntroForm`
counter; update `FIELD_OPEN`/`FIELD_READY`/`FIELD_LOCATE` for `headline`.

### About (claimed: automated)

Run `browser-serialiser linkedin.com/set-profile-field about --dump`.
Expect a dump with the current About text. The open is racy (it clicks the "Edit
about" pencil; the SPA click sometimes routes to a URL that redirects back to the
profile), so the skill retries up to three times — one `--dump` may still fail on
a browser-level crash; rerun once before concluding.

Persistent failure means the pencil's aria-label changed (no longer contains
"edit about") or the summary editor is no longer a `[role="textbox"]`. Re-recon:
nav `/in/me/`, scroll-hydrate, list `a,button` whose `aria-label` contains "edit"
and read their `href` to find the About control; then open it and inventory the
editor.

### Save mechanism (cross-cutting; the basis for both rows above)

The Save button in these forms fires its React handler only from an in-page
`HTMLElement.click()`, not from the harness `click` verb. To validate this still
holds: open a form (a `--dry-run` types into the editor without saving), then in
the page tag the Save button and click it with the verb — if the form stays open
(`location.href` unchanged, the button still present) the verb is still inert and
the in-page `el.click()` path is required. If a future LinkedIn build makes the
verb work, the in-page click in `sv_click_save` can be simplified back to it.

Note the same risk for `send-invite`/`send-message`, which send through the
`click` verb (see BUGS.md): a "sent" result there may be a silent no-op if their
buttons behave like these. Validate a send against a real recipient.

## Recon method for the unautomated sections

To assess or build Experience, Skills, Featured, or Open-to-Work, two probes
(run their JS through the serialiser `eval` verb, e.g. from a throwaway skill arm
modelled on the edit path):

- **Find a section's edit route.** Nav `/in/me/`, scroll-hydrate, then
  enumerate every `a,button` whose `aria-label` contains "edit" or "add" and read
  its `href`. This surfaced `Edit about -> /in/<slug>/edit/forms/summary/new/`,
  `Add new position -> /in/<slug>/edit/forms/position/new/`, and the
  Open-to-Work route `/in/<slug>/opportunities/job-opportunities/edit/`.
- **Inventory a form's fields.** Open the form (direct route, or click its pencil
  with `el.click()`), scroll-hydrate, then list `input,textarea,[role="textbox"],
  [contenteditable]` resolving each label via `aria-label`, `aria-labelledby`, or
  `label[for]` (the element `id`s are randomised React placeholders like `«r0»`
  and are useless as selectors).

Section-specific obstacles to expect (anticipated, not confirmed):
- **Experience** (set end date / add entry): a multi-field form with month/year
  date-picker dropdowns and a "currently working here" toggle. The text editor
  and Save mechanics carry over from this skill; the date pickers are the unbuilt
  part. A direct nav to `/edit/forms/position/new/` likely redirects to the
  profile (as the About route does); open via the pencil instead.
- **Skills**: reordering is drag-and-drop, which the `click`/`type` surface does
  not express; check whether a non-drag reorder control exists before assuming.
- **Featured**: a media/post picker; confirm whether an item can be added by URL
  or only through an upload/selection dialog.
- **Open to Work**: a settings form at its own route; likely a set of toggles and
  selects rather than a text editor.
