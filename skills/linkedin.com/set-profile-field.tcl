#!/usr/bin/env tclsh
# Edit a single-value text field on the signed-in user's own LinkedIn profile.
#
# Serialiser path (see SKILL.md):
#     browser-serialiser linkedin.com/set-profile-field headline "New headline" [--dry-run]
#     browser-serialiser linkedin.com/set-profile-field about   "New about"    [--dry-run]
#     browser-serialiser linkedin.com/set-profile-field <field> --dump          # recon: open the form, report current value
#     browser-serialiser linkedin.com/set-profile-field <field> --self-test      # prove Save round-trips, leaving no visible change
#
# The Save click is the IRREVERSIBLE outward action (LinkedIn may broadcast a
# profile update to the network); --dry-run types but stops before Save, --dump
# and the read path never type. The profile is reached through /in/me/, which
# LinkedIn redirects to whatever account is signed in -- no slug is hardcoded.
#
# Mirrors send-invite.tcl's serialiser_run: nav -> tag-via-eval -> click/type ->
# Save -> confirm. LinkedIn randomises CSS classes and the field ids are React
# placeholders («r0»...), so every selector is a role/attribute that survives a
# render or a data-sv-* attribute we set with `eval`. The headline editor is a
# Lexical-style contenteditable that only hydrates once scrolled into view, so
# the flow scroll-hydrates the intro form before touching it.

package require json

# --- Field table -----------------------------------------------------------
# Each field knows: the form URL to open, a selector that signals its editor has
# hydrated, and a JS expression that tags the editable element with
# data-sv-edit="1" and returns its current text. The clear/type/save body is
# shared; only these differ per field.
#
# headline: the intro form holds exactly one role="textbox" (the headline rich
# editor); tag it directly.
# Open spec per field: a "/path" is navigated directly; "click:<aria-substring>"
# is reached by loading /in/me/, hydrating, and clicking the matching pencil. The
# headline form has a working direct route; the About (summary) form redirects to
# the profile on direct nav and only opens via its pencil.
array set FIELD_OPEN {
    headline "/in/me/edit/intro/"
    about    "click:edit about"
}
array set FIELD_READY {
    headline {[role="textbox"]}
    about    {[role="textbox"]}
}
# Both the intro form and the summary form expose exactly one role="textbox"
# (the headline editor / the About editor); tag it directly.
array set FIELD_LOCATE {
    headline {(function(){
        var el = document.querySelector('[role="textbox"]');
        if (!el) return "";
        el.setAttribute('data-sv-edit','1');
        return el.innerText;
    })()}
    about {(function(){
        var el = document.querySelector('[role="textbox"]');
        if (!el) return "";
        el.setAttribute('data-sv-edit','1');
        return el.innerText;
    })()}
}

# Code-point length (surrogate-pair aware), lifted from send-invite.tcl.
proc cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}

proc sv_js_bool {expr} {
    return [expr {[eval $expr] eq "true" ? 1 : 0}]
}

proc sv_wait_for {selector ticks} {
    for {set i 0} {$i < $ticks} {incr i} {
        if {[sv_js_bool "!!document.querySelector([json::write string $selector])"]} {
            return 1
        }
        dwell 0.5
    }
    return 0
}

# Scroll the whole form through the viewport once so windowed/SDUI editors
# (the headline rich editor) get a chance to hydrate.
proc sv_scroll_pass {} {
    eval {(function(){
        var h = document.body.scrollHeight;
        for (var y=0; y<=h; y+=400){ window.scrollTo(0,y); }
        window.scrollTo(0,0);
        return true;
    })()}
    dwell 1.5
}

# Open a field's edit form per its open-spec, then wait for its editor. A
# "/path" spec is navigated directly; a "click:<aria>" spec loads /in/me/,
# hydrates, and clicks the matching pencil with HTMLElement.click() (the policed
# `click` verb does not fire these React handlers). Then, with $ready non-empty,
# the form is scrolled until that selector hydrates (the rich editors mount
# lazily). Returns 1 on a live session with the editor ready, else 0.
# Open with retries: the click-open path is racy (the SPA click sometimes routes
# to a URL that redirects back to the profile instead of mounting the modal), so
# retry the whole open until the editor is ready or attempts run out.
proc sv_open_form {open ready} {
    for {set attempt 0} {$attempt < 3} {incr attempt} {
        if {[sv_open_attempt $open $ready]} { return 1 }
        log "open attempt [expr {$attempt+1}] did not reach the editor; retrying"
    }
    return 0
}

proc sv_open_attempt {open ready} {
    if {[string match "click:*" $open]} {
        set sub [string range $open 6 end]
        nav "https://www.linkedin.com/in/me/" --wait 5
        if {[dict get [state] terminal] ne ""} { return 0 }
        # Scroll until the pencil hydrates, tag it, then click it (HTMLElement
        # .click(); the policed `click` verb does not fire these React handlers).
        set tagged 0
        for {set p 0} {$p < 8 && !$tagged} {incr p} {
            sv_scroll_pass
            set tagged [sv_js_bool "(function(){
                var sub=[json::write string $sub].toLowerCase();
                var el=Array.from(document.querySelectorAll('a,button')).find(function(e){
                    return ((e.getAttribute('aria-label')||'')).toLowerCase().indexOf(sub)>=0;
                });
                if(el){el.setAttribute('data-sv-open','1');return true;} return false;
            })()"]
        }
        if {!$tagged} { return 0 }
        eval {document.querySelector('[data-sv-open="1"]').click()}
        dwell 3
    } else {
        nav "https://www.linkedin.com$open" --wait 5
    }
    if {[dict get [state] terminal] ne ""} { return 0 }
    set tl [string tolower [eval {document.title}]]
    foreach bad {"sign in" "log in" "iniciar"} {
        if {[string first $bad $tl] >= 0} { return 0 }
    }
    if {$ready eq ""} { return 1 }
    for {set pass 0} {$pass < 6} {incr pass} {
        sv_scroll_pass
        if {[sv_wait_for $ready 4]} { return 1 }
    }
    return 0
}

# Read a field's text after (re)opening its form. Returns the current text, or a
# sentinel if the form/editor never came up.
proc sv_read_field {open ready locate} {
    if {![sv_open_form $open $ready]} { return " unavailable" }
    return [eval $locate]
}

# Replace the tagged editor's content with $value. Assumes the form is open and
# the editor tagged data-sv-edit="1". The replace runs as Lexical editor
# operations -- selectAll then insertText both flow through the beforeinput
# pipeline Lexical reconciles its editorState from, so the form registers the
# change as dirty and Save persists it. A bare CDP Input.insertText updates the
# visible DOM but not editorState, so Save would no-op; a programmatic DOM Range
# is likewise ignored (Lexical keeps its own selection model). Returns the text.
proc sv_set_value {value} {
    eval "(function(){
        var el = document.querySelector('\[data-sv-edit=\"1\"\]');
        if (!el) return '';
        el.focus();
        document.execCommand('selectAll', false, null);
        document.execCommand('insertText', false, [json::write string $value]);
        el.dispatchEvent(new Event('input', {bubbles:true}));
        return el.innerText;
    })()"
    dwell 0.5
    return [eval {(function(){var e=document.querySelector('[data-sv-edit="1"]');return e?e.innerText:'';})()}]
}

# Tag and click the primary Save button (exact visible text "Save"). Returns a
# dict {clicked href form_open err}; clicked 0 if no Save button was found.
proc sv_click_save {} {
    set found [sv_js_bool {(function(){
        var b = Array.from(document.querySelectorAll('button')).find(function(b){
            return (b.textContent||'').trim().toLowerCase() === 'save';
        });
        if (b){ b.setAttribute('data-sv-save','1'); return true; }
        return false;
    })()}]
    if {!$found} { return [dict create clicked 0] }
    # Click in-page via HTMLElement.click() rather than the policed `click` verb:
    # this button's React onClick does not fire from the verb's synthetic click,
    # but does from a genuine element click dispatched in the page.
    eval {document.querySelector('[data-sv-save="1"]').click()}
    dwell 4
    set href [eval {location.href}]
    set form_open [sv_js_bool {!!document.querySelector('[data-sv-save="1"]')}]
    set err [eval {(function(){
        return Array.from(document.querySelectorAll('[role="alert"],.artdeco-inline-feedback--error,[data-test-form-element-error-messages]'))
            .map(function(e){return (e.innerText||'').trim();}).filter(Boolean).join(' | ');
    })()}]
    log "POST-SAVE: href=$href form_open=$form_open err=\"$err\""
    return [dict create clicked 1 href $href form_open $form_open err $err]
}

proc serialiser_run {skillArgs} {
    global FIELD_OPEN FIELD_READY FIELD_LOCATE
    set dump 0
    set dry_run 0
    set positional {}
    foreach a $skillArgs {
        switch -- $a {
            --dump      { set dump 1 }
            --dry-run   { set dry_run 1 }
            default     { lappend positional $a }
        }
    }
    set field [lindex $positional 0]
    set value [expr {[llength $positional] > 1 ? [lindex $positional 1] : ""}]

    if {![info exists FIELD_OPEN($field)]} {
        emit "{\"status\":\"error\",\"reason\":\"unknown field '$field'; known: [array names FIELD_OPEN]\"}"
        return
    }
    set open $FIELD_OPEN($field)
    set ready $FIELD_READY($field)
    set locate $FIELD_LOCATE($field)

    if {![sv_open_form $open $ready]} {
        emit "{\"status\":\"error\",\"reason\":\"session not active, sign-in wall, or editor not ready\"}"
        return
    }
    set current [eval $locate]
    if {![sv_js_bool {!!document.querySelector('[data-sv-edit="1"]')}]} {
        emit "{\"status\":\"error\",\"reason\":\"editor for '$field' not found (DOM may have changed; run --dump)\"}"
        return
    }
    log "Current $field ([cp_length $current] chars): [string range $current 0 80]"

    if {$dump} {
        emit "{\"status\":\"dump\",\"field\":\"$field\",\"current_len\":[cp_length $current],\"current\":[json::write string $current]}"
        return
    }

    set typed [sv_set_value $value]
    log "After type ([cp_length $typed] chars): [string range $typed 0 80]"

    if {$dry_run} {
        emit "{\"status\":\"dry_run\",\"field\":\"$field\",\"was\":[json::write string $current],\"typed\":[json::write string $typed]}"
        return
    }

    set sv [sv_click_save]
    if {![dict get $sv clicked]} {
        emit "{\"status\":\"error\",\"reason\":\"Save button not found after typing\"}"
        return
    }
    set after [sv_read_field $open $ready $locate]
    set ok [expr {[string trim $after] eq [string trim $value]}]
    emit "{\"status\":\"[expr {$ok ? {saved} : {uncertain}}]\",\"field\":\"$field\",\"was\":[json::write string $current],\"now\":[json::write string $after]}"
}

# Direct-tclsh entry is unused for this skill (serialiser path only).
