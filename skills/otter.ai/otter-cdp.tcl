#!/usr/bin/env tclsh
# Otter.ai recording management over the serialised-browsing command surface.
#
# The harness sources this file into a per-run safe interpreter and calls
# serialiser_run with the subcommand args. The flow navigates to otter.ai (the
# covering view for the /forward/api/v1/* endpoints) and runs Otter's internal
# API through the policed `eval` verb — reads (list, fetch) and writes (rename,
# trash) alike are page-context fetch() calls carried by the session's own
# cookies + CSRF token. Each subcommand emits a JSON document.
#
# Invoked by reference through the serialiser (see SKILL.md):
#   browser-serialiser otter.ai/otter-cdp list [--page-size N] [--last-load-ts TS]
#   browser-serialiser otter.ai/otter-cdp rename <otid> <new_title>
#   browser-serialiser otter.ai/otter-cdp trash <otid>
#   browser-serialiser otter.ai/otter-cdp fetch <otid>
#
# fetch returns a recording's transcript from the /forward/api/v1/speech endpoint.
# The legacy CDP-client path (main + cdp::connect) is retained for direct `tclsh`
# runs.
#
# Note: `trash` moves the recording to Otter Trash (recoverable via the web UI
# for ~30 days). There is deliberately no `delete` subcommand. See the DANGER
# block near cmd_trash for the endpoint names that must not be called and why.

package require json

# Legacy CDP engine, kept for the direct-tclsh path (main, which calls
# cdp::connect when run as `tclsh otter-cdp.tcl ...` outside the serialiser).
# Sourced only when not already present, so loading this file under the
# serialiser harness (where the policed verbs replace raw CDP and the socket
# transport is unavailable in the safe interp) is a no-op rather than an error.
# The harness path uses serialiser_run.
if {![namespace exists cdp]} {
    catch { source [file dirname [info script]]/../lib/cdp-client.tcl }
}

# Pretty-print a compact JSON document with 2-space indentation, the shape
# Python's json.dumps(indent=2, ensure_ascii=False) emits. Values pass through
# verbatim (no re-typing), so numbers, booleans and unicode survive unchanged.
proc json_pretty {text {indent 0}} {
    set out ""
    set n [string length $text]
    set i 0
    set instr 0
    set depth $indent
    while {$i < $n} {
        set c [string index $text $i]
        if {$instr} {
            append out $c
            if {$c eq "\\"} {
                append out [string index $text [expr {$i+1}]]
                incr i 2
                continue
            }
            if {$c eq "\""} { set instr 0 }
            incr i
            continue
        }
        switch -- $c {
            "\"" { set instr 1; append out $c; incr i }
            "\{" - "\[" {
                # Look ahead: an empty container stays on one line.
                set j [expr {$i+1}]
                while {$j < $n && [string is space [string index $text $j]]} { incr j }
                set close [expr {$c eq "\{" ? "\}" : "\]"}]
                if {[string index $text $j] eq $close} {
                    append out $c$close
                    set i [expr {$j+1}]
                } else {
                    incr depth
                    append out $c "\n" [string repeat "  " $depth]
                    incr i
                }
            }
            "\}" - "\]" {
                incr depth -1
                append out "\n" [string repeat "  " $depth] $c
                incr i
            }
            "," {
                append out ",\n" [string repeat "  " $depth]
                incr i
            }
            ":" { append out ": "; incr i }
            " " - "\t" - "\n" - "\r" { incr i }
            default { append out $c; incr i }
        }
    }
    return $out
}

# Quote a Tcl string as a JSON string literal (for error/raw wrappers built here
# rather than received from the page, and for JS string literals embedded in
# expressions — JSON string syntax is a subset JavaScript accepts).
proc json_str {s} {
    set out "\""
    foreach ch [split $s ""] {
        scan $ch %c code
        switch -- $ch {
            "\"" { append out {\"} }
            "\\" { append out {\\} }
            "\n" { append out {\n} }
            "\r" { append out {\r} }
            "\t" { append out {\t} }
            default {
                if {$code < 0x20} {
                    append out [format {\u%04x} $code]
                } else {
                    append out $ch
                }
            }
        }
    }
    append out "\""
    return $out
}

# Runtime.evaluate of $expr, returning the JS value as a JSON document string.
# Mirrors the Python eval_js: the JS is expected to return a JSON string, so the
# value is taken verbatim when it parses as JSON, else wrapped as {"raw":...};
# a JS exception becomes {"error":...}, a missing value {"error":"No value..."}.
# Returns a two-element list {kind doc}: kind is json|raw|error.
#
# Dual transport, single classifier. Direct-tclsh path: $cdp is a cdp::Client and
# the raw Runtime.evaluate value is read here. Serialiser path: $cdp is the
# sentinel `serialiser` and the policed `eval` verb returns the JS value (raising
# `JS exception: ...` on a page error). Either way the same JSON document string
# is classified into {kind doc}, so every cmd_* below renders byte-identically
# whichever host drives it.
proc eval_js {cdp expr} {
    if {$cdp eq "serialiser"} {
        if {[catch {eval $expr} val]} {
            set text $val
            if {[string match "JS exception:*" $text]} {
                set text [string trim [string range $text [string length "JS exception:"] end]]
            }
            return [list error "\{[json_str error]:[json_str $text]\}"]
        }
    } else {
        set resp [$cdp cdp Runtime.evaluate [dict create \
            expression $expr awaitPromise true returnByValue true]]
        set result [dict get $resp result]
        if {[dict exists $result exceptionDetails]} {
            set exc [dict get $result exceptionDetails]
            set text [expr {[dict exists $exc text] ? [dict get $exc text] : "JS exception"}]
            return [list error "\{[json_str error]:[json_str $text]\}"]
        }
        if {![dict exists $result result value]} {
            return [list error "\{[json_str error]:[json_str {No value returned from JS}]\}"]
        }
        set val [dict get $result result value]
    }
    if {[catch {json::json2dict $val}]} {
        # Not JSON: wrap the raw string, matching Python's {"raw": val}.
        return [list raw "\{[json_str raw]:[json_str $val]\}"]
    }
    return [list json $val]
}

# Pull a scalar string out of an eval_js return. document.title returns a bare
# string, so eval_js parses it as a JSON string value (kind=json) or wraps it
# raw; either way recover the text.
proc extract_scalar {kind doc} {
    if {$kind eq "json"} {
        if {![catch {json::json2dict $doc} v]} { return $v }
        return $doc
    }
    if {![catch {json::json2dict $doc} d]} {
        if {[dict exists $d raw]} { return [dict get $d raw] }
        if {[dict exists $d error]} { return [dict get $d error] }
    }
    return $doc
}

proc navigate_and_wait {cdp url {wait_seconds 6}} {
    $cdp cdp Page.navigate [dict create url $url]
    after [expr {int($wait_seconds * 1000)}]
}

# False when the page title shows a sign-in/log-in wall.
proc check_logged_in {cdp} {
    lassign [eval_js $cdp {document.title}] kind doc
    set title [extract_scalar $kind $doc]
    if {[string match "*Sign In*" $title] || [string match "*Log In*" $title]} {
        return 0
    }
    return 1
}

# --- Commands ---
# Each cmd_* returns a {kind doc} list, doc being a JSON document string.

proc cmd_list {cdp argsd} {
    set page_size [dict get $argsd page_size]
    set last_load_ts [dict get $argsd last_load_ts]
    set params "page_size=$page_size"
    if {$last_load_ts ne ""} {
        # Otter's API requires `modified_after` on subsequent pages; the cursor
        # is `last_load_ts` from the previous response. Setting modified_after=1
        # (epoch start) means "no modification-time filter" so the cursor alone
        # controls pagination.
        append params "&modified_after=1&last_load_ts=$last_load_ts"
    }
    set js "
    (async () => {
        const csrf = document.cookie.match(/csrftoken=(\[^;\]+)/)?.\[1\] || '';
        const resp = await fetch('/forward/api/v1/speeches?$params', {
            credentials: 'include',
            headers: {'x-csrftoken': csrf}
        });
        const data = await resp.json();
        if (data.speeches) {
            data.speeches = data.speeches.map(s => ({
                otid: s.otid,
                title: s.title,
                created_at: s.created_at,
                duration: s.duration,
                summary: s.summary,
                start_time: s.start_time,
                process_finished: s.process_finished,
                folder: s.folder,
                link: 'https://otter.ai/u/' + s.otid,
            }));
        }
        return JSON.stringify(data);
    })()
    "
    return [eval_js $cdp $js]
}

# Return {title found} for <otid> by reading the speeches list. A successful
# rename bumps the recording's modification time, so the list (newest-modified
# first) carries it near the top; a small page is enough. {{} 0} when absent or
# on read failure.
proc fetch_speech_title {cdp otid {page_size 25}} {
    set js "
    (async () => {
        const csrf = document.cookie.match(/csrftoken=(\[^;\]+)/)?.\[1\] || '';
        const resp = await fetch('/forward/api/v1/speeches?page_size=$page_size', {
            credentials: 'include',
            headers: {'x-csrftoken': csrf}
        });
        const data = await resp.json();
        const s = (data.speeches || \[\]).find(x => x.otid === [json_str $otid]);
        return JSON.stringify({title: s ? s.title : null, found: !!s});
    })()
    "
    lassign [eval_js $cdp $js] kind doc
    if {$kind eq "json" && ![catch {json::json2dict $doc} d]} {
        set title [expr {[dict exists $d title] ? [dict get $d title] : ""}]
        if {$title eq "null"} { set title "" }
        set found [expr {[dict exists $d found] && [dict get $d found] eq "true"}]
        return [list $title $found]
    }
    return [list "" 0]
}

# Rename a recording, then verify the change actually persisted.
#
# set_speech_title returns a {"status": "OK"} body even when the rename does not
# stick (observed 2026-05-14: two calls reported OK, the title stayed "Note").
# Checking the HTTP status would not catch that, so this reads the title back
# from the speeches list and only reports OK once it matches.
proc cmd_rename {cdp argsd} {
    set otid [dict get $argsd otid]
    set title [dict get $argsd new_title]
    set warning ""
    if {![string match "*.txt" $title]} {
        set warning "Title '$title' does not end in '.txt'. Project convention is\
 YYYY-MM-DD-kebab-case-description.txt; transcripts are picked up downstream by\
 their .txt suffix, so a non-.txt title means the next rename pass will see this\
 recording as still-unnamed and rename it again (not idempotent)."
        puts stderr "Warning: $warning"
    }
    set js "
    (async () => {
        const csrf = document.cookie.match(/csrftoken=(\[^;\]+)/)?.\[1\] || '';
        const params = new URLSearchParams({
            otid: [json_str $otid],
            title: [json_str $title],
        });
        const resp = await fetch('/forward/api/v1/set_speech_title?' + params.toString(), {
            method: 'POST',
            credentials: 'include',
            headers: {'x-csrftoken': csrf}
        });
        return await resp.text();
    })()
    "
    set attempts 2
    set post_response ""
    set observed_title ""
    set found 0
    for {set attempt 1} {$attempt <= $attempts} {incr attempt} {
        lassign [eval_js $cdp $js] pkind post_response
        lassign [fetch_speech_title $cdp $otid] observed_title found
        if {$found && $observed_title eq $title} {
            set pairs [list "[json_str status]:[json_str OK]" \
                "[json_str verified]:true" \
                "[json_str title]:[json_str $title]"]
            # If the POST body parsed to JSON carrying modified_time, surface it.
            if {![catch {json::json2dict $post_response} pd] \
                    && [dict exists $pd modified_time]} {
                lappend pairs "[json_str modified_time]:[json_str [dict get $pd modified_time]]"
            }
            if {$attempt > 1} {
                lappend pairs "[json_str attempts]:$attempt"
            }
            if {$warning ne ""} {
                lappend pairs "[json_str warning]:[json_str $warning]"
            }
            return [list json "\{[join $pairs ,]\}"]
        }
        if {$attempt < $attempts} {
            puts stderr "Rename verification failed (attempt $attempt/$attempts):\
 API returned '$post_response' but list shows title='$observed_title'\
 found=$found; retrying."
            after 2000
        }
    }

    set obs [expr {$observed_title eq "" ? "null" : [json_str $observed_title]}]
    set pairs [list \
        "[json_str error]:[json_str {Rename not persisted: the API reported success but the recording's title did not change after verification.}]" \
        "[json_str otid]:[json_str $otid]" \
        "[json_str requested_title]:[json_str $title]" \
        "[json_str observed_title]:$obs" \
        "[json_str found_in_list]:[expr {$found ? {true} : {false}}]" \
        "[json_str post_response]:[json_str $post_response]"]
    if {$warning ne ""} {
        lappend pairs "[json_str warning]:[json_str $warning]"
    }
    return [list json "\{[join $pairs ,]\}"]
}

# =============================================================================
# DANGER: do not call /forward/api/v1/delete_speech (or permanently_delete_speech,
# bulk_delete_speech). They are HARD DELETES that bypass Otter Trash and are
# unrecoverable, even though their names sound like "move to recycle bin" from
# UI vocabulary. The UI's "Move to Trash" button calls move_to_trash_bin, which
# IS recoverable from Trash for ~30 days. This skill only exposes the
# move_to_trash_bin variant. A 2026-05-13 incident lost a real recording to
# delete_speech because the name was assumed to mean soft-delete; the lesson is
# that destructive endpoints in Otter's API are differentiated only by the
# token "permanently" or by belonging to a *_trash_bin family. When in doubt,
# pick the *_trash_bin one.
#
# Endpoint family observed in main.<hash>.js bundle (Speech*-prefixed registry):
#   SpeechMoveToTrashBin        -> move_to_trash_bin           [SAFE: recoverable]
#   SpeechBulkMoveToTrashBin    -> bulk_to_trash_bin           [SAFE: recoverable]
#   SpeechMoveOutTrashBin       -> move_back_from_trash_bin    [SAFE: restore]
#   SpeechBulkMoveOutTrashBin   -> bulk_back_from_trash_bin    [SAFE: restore]
#   SpeechListTrashBin          -> get_deleted_speeches        [SAFE: read]
#   SpeechClearTrashBin         -> clear_trash_bin             [DANGER: empties trash]
#   SpeechPermanentlyDelete     -> permanently_delete_speech   [DANGER: hard]
#   SpeechBulkPermanentlyDelete -> bulk_delete_speech          [DANGER: hard]
#   SpeechDelete                -> delete_speech               [DANGER: hard, named misleadingly]
# =============================================================================

# Move a recording to Otter Trash (recoverable from the web UI for ~30 days).
# Calls POST /forward/api/v1/move_to_trash_bin with `otid=<otid>` as a form body.
# Returns the JSON response from Otter on success, {"error": ...} otherwise.
# Before changing the endpoint, read the DANGER block above this function.
proc cmd_trash {cdp argsd} {
    set otid [dict get $argsd otid]
    set js "
    (async () => {
        const csrf = document.cookie.match(/csrftoken=(\[^;\]+)/)?.\[1\] || '';
        const body = 'otid=' + encodeURIComponent([json_str $otid]);
        const resp = await fetch('/forward/api/v1/move_to_trash_bin', {
            method: 'POST',
            credentials: 'include',
            headers: {
                'x-csrftoken': csrf,
                'content-type': 'application/x-www-form-urlencoded',
            },
            body,
        });
        const text = await resp.text();
        return JSON.stringify({status_code: resp.status, body: text});
    })()
    "
    lassign [eval_js $cdp $js] kind doc
    if {$kind eq "error"} { return [list $kind $doc] }
    if {[catch {json::json2dict $doc} raw]} {
        return [list raw $doc]
    }
    set status_code [expr {[dict exists $raw status_code] ? [dict get $raw status_code] : ""}]
    set body [expr {[dict exists $raw body] ? [dict get $raw body] : ""}]
    if {$status_code ne "200"} {
        set snippet [string range $body 0 299]
        return [list json "\{[json_str error]:[json_str "move_to_trash_bin returned HTTP $status_code"],[json_str body]:[json_str $snippet]\}"]
    }
    if {[catch {json::json2dict $body}]} {
        return [list raw "\{[json_str raw]:[json_str $body]\}"]
    }
    return [list json $body]
}

# Fetch a recording's transcript directly from /forward/api/v1/speech?otid= (the
# call the recording page itself makes to render). Reconstructs a speaker-labelled
# transcript from speech.transcripts[] — joining each segment's text, grouping
# consecutive same-speaker turns, naming speakers via speech.speakers[] (segment
# speaker_id -> speaker_name), falling back to the diarisation label otherwise.
# Output: {"otid","title","created_at","duration","segments","transcript"} or {"error"}.
# The JS is a braced literal (no Tcl substitution); the otid is injected via string map.
proc cmd_fetch {cdp argsd} {
    set otid [dict get $argsd otid]
    set js {
    (async () => {
        try {
            const csrf = document.cookie.match(/csrftoken=([^;]+)/)?.[1] || '';
            const resp = await fetch('/forward/api/v1/speech?otid=@OTID@', {
                credentials: 'include',
                headers: {'x-csrftoken': csrf}
            });
            if (!resp.ok) return JSON.stringify({error: 'speech fetch HTTP ' + resp.status});
            const data = await resp.json();
            const sp = (data && data.speech) || data;
            const segs = sp.transcripts || sp.monologues || [];
            const names = {};
            (sp.speakers || []).forEach(s => { names[s.id] = s.speaker_name || ('Speaker ' + s.id); });
            const out = [];
            let curSpk = null, buf = [];
            const flush = () => { if (buf.length) { out.push(curSpk + ': ' + buf.join(' ')); buf = []; } };
            for (const seg of segs) {
                const t = (seg.transcript || seg.text || '').trim();
                if (!t) continue;
                let spk;
                if (seg.speaker_id != null && names[seg.speaker_id]) spk = names[seg.speaker_id];
                else if (seg.speaker_id != null) spk = 'Speaker ' + seg.speaker_id;
                else spk = 'Speaker ' + (seg.label != null ? seg.label : '?');
                if (spk !== curSpk) { flush(); curSpk = spk; }
                buf.push(t);
            }
            flush();
            return JSON.stringify({
                otid: sp.otid,
                title: sp.title,
                created_at: sp.created_at,
                duration: sp.duration,
                segments: segs.length,
                transcript: out.join('\n\n')
            });
        } catch (e) { return JSON.stringify({error: String(e)}); }
    })()
    }
    set js [string map [list @OTID@ $otid] $js]
    return [eval_js $cdp $js]
}

proc usage {} {
    puts stderr "Otter.ai CDP helper"
    puts stderr "Usage:"
    puts stderr "  ... -- tclsh otter-cdp.tcl list \[--page-size N\] \[--last-load-ts TS\]"
    puts stderr "  ... -- tclsh otter-cdp.tcl rename <otid> <new_title>"
    puts stderr "  ... -- tclsh otter-cdp.tcl trash <otid>"
    puts stderr "  ... -- tclsh otter-cdp.tcl fetch <otid>"
}

# Parse argv into {command argsd}. argsd is a dict of the resolved options.
proc parse_args {argv} {
    if {[llength $argv] == 0} {
        usage
        exit 1
    }
    set command [lindex $argv 0]
    set rest [lrange $argv 1 end]

    switch -- $command {
        list {
            set d [dict create page_size 50 last_load_ts ""]
            for {set i 0} {$i < [llength $rest]} {incr i} {
                set a [lindex $rest $i]
                switch -- $a {
                    --page-size    { incr i; dict set d page_size [lindex $rest $i] }
                    --last-load-ts { incr i; dict set d last_load_ts [lindex $rest $i] }
                    default        { puts stderr "unknown argument: $a"; exit 2 }
                }
            }
            return [list list $d]
        }
        rename {
            if {[llength $rest] < 2} { puts stderr "rename requires <otid> <new_title>"; exit 2 }
            return [list rename [dict create otid [lindex $rest 0] new_title [lindex $rest 1]]]
        }
        trash {
            if {[llength $rest] < 1} { puts stderr "trash requires <otid>"; exit 2 }
            return [list trash [dict create otid [lindex $rest 0]]]
        }
        fetch {
            if {[llength $rest] < 1} { puts stderr "fetch requires <otid>"; exit 2 }
            return [list fetch [dict create otid [lindex $rest 0]]]
        }
        default {
            usage
            exit 1
        }
    }
}

proc main {argv} {
    lassign [parse_args $argv] command argsd

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser otter.ai/otter-cdp ..."
        exit 1
    }

    fconfigure stdout -encoding utf-8
    set cdp [cdp::connect]
    try {
        navigate_and_wait $cdp "https://otter.ai/my-notes"

        if {![check_logged_in $cdp]} {
            puts [json_pretty "\{[json_str error]:[json_str {Not logged in to Otter.ai. Log in via a Chrome-compatible browser first.}]\}"]
            exit 1
        }

        switch -- $command {
            list              { set res [cmd_list $cdp $argsd] }
            rename            { set res [cmd_rename $cdp $argsd] }
            trash             { set res [cmd_trash $cdp $argsd] }
            fetch             { set res [cmd_fetch $cdp $argsd] }
        }
        lassign $res kind doc
        puts [json_pretty $doc]
    } finally {
        $cdp close
    }
}

# ---------------------------------------------------------------------------
# Serialiser entry: the policed-surface path. The harness sources this file into
# a safe interp and calls serialiser_run with the skill args. The flow navigates
# to the covering Otter page (the view-before-fetch view for /forward/api/v1/*),
# checks for a wall via `state`, then dispatches to the same cmd_* procs the
# legacy path uses. Each cmd_* drives the policed `eval` verb (the `serialiser`
# sentinel into eval_js) with its JS unchanged, and json_pretty renders the same
# document, so the emitted result is byte-identical to the direct-tclsh output.
# ---------------------------------------------------------------------------

# Parse the subcommand into {command argsd}, emitting a usage error instead of
# exiting (the safe interp has no exit, and the harness's one channel is emit).
# Returns "" on a parse error after emitting. argsd dict shapes mirror parse_args.
proc sv_parse_args {skillArgs} {
    if {![llength $skillArgs]} {
        emit [json_pretty "\{[json_str error]:[json_str {Usage: otter.ai/otter-cdp <list|rename|trash|fetch> ...}]\}"]
        return ""
    }
    set command [lindex $skillArgs 0]
    set rest [lrange $skillArgs 1 end]
    switch -- $command {
        list {
            set d [dict create page_size 50 last_load_ts ""]
            for {set i 0} {$i < [llength $rest]} {incr i} {
                set a [lindex $rest $i]
                switch -- $a {
                    --page-size    { incr i; dict set d page_size [lindex $rest $i] }
                    --last-load-ts { incr i; dict set d last_load_ts [lindex $rest $i] }
                    default        { emit [json_pretty "\{[json_str error]:[json_str "unknown argument: $a"]\}"]; return "" }
                }
            }
            return [list list $d]
        }
        rename {
            if {[llength $rest] < 2} { emit [json_pretty "\{[json_str error]:[json_str {rename requires <otid> <new_title>}]\}"]; return "" }
            return [list rename [dict create otid [lindex $rest 0] new_title [lindex $rest 1]]]
        }
        trash {
            if {[llength $rest] < 1} { emit [json_pretty "\{[json_str error]:[json_str {trash requires <otid>}]\}"]; return "" }
            return [list trash [dict create otid [lindex $rest 0]]]
        }
        fetch {
            if {[llength $rest] < 1} { emit [json_pretty "\{[json_str error]:[json_str {fetch requires <otid>}]\}"]; return "" }
            return [list fetch [dict create otid [lindex $rest 0]]]
        }
        default {
            emit [json_pretty "\{[json_str error]:[json_str "unknown command: $command"]\}"]
            return ""
        }
    }
}

proc serialiser_run {skillArgs} {
    set parsed [sv_parse_args $skillArgs]
    if {$parsed eq ""} { return }
    lassign $parsed command argsd

    # Covering view: navigate to my-notes (the view-before-fetch view for the
    # /forward/api/v1/* endpoints), then read the harness's wall classification.
    nav "https://otter.ai/my-notes" --wait 6
    if {[dict get [state] terminal] ne ""} {
        emit [json_pretty "\{[json_str error]:[json_str {Not logged in to Otter.ai. Log in via a Chrome-compatible browser first.}]\}"]
        return
    }

    switch -- $command {
        list              { set res [cmd_list serialiser $argsd] }
        rename            { set res [cmd_rename serialiser $argsd] }
        trash             { set res [cmd_trash serialiser $argsd] }
        fetch             { set res [cmd_fetch serialiser $argsd] }
    }
    lassign $res kind doc
    emit [json_pretty $doc]
}

# Run main only when executed directly, not when sourced under the harness.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    main $argv
}
