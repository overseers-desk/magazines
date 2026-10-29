#!/usr/bin/env tclsh
# Search Instagram accounts, hashtags and places, and report them.
#
# Serialiser path (see SKILL.md §1-2): browser-serialiser instagram.com/auth-parse-search <search terms>
#   types the terms into the search page's box and reports the type-ahead
#   results the page itself fetches.
# Direct path (legacy, file-fed): tclsh auth-parse-search.tcl <json-file>
#
# The search box's type-ahead query (xdt_api__v1__fbsearch__topsearch_connection)
# carries users[], hashtags[] and places[] in the shape the old REST route
# /web/search/topsearch/ returned; that route answers Instagram's "Page Not
# Found" page (observed 2026-10-29). The keyword results page
# (/explore/search/keyword/) carries posts, and its accounts unit arrives empty.
#
# The legacy file may be pure JSON or HTML-wrapped (headless --dump-dom wraps a
# JSON body in <html><body><pre>...). This script handles both.

package require json

# Unwrap a <pre>...</pre> body if present, decode HTML entities, and return the
# parsed dict, or {} on a non-JSON body (diagnostics written to stderr-or-stdout
# via the supplied reporter). $raw is the in-memory page/file text.
proc parse_payload {raw {reporter puts}} {
    # headless --dump-dom of a JSON endpoint wraps the body in <pre>...</pre>
    if {[regexp {(?s)<pre[^>]*>(.*?)</pre>} $raw -> inner]} {
        set body $inner
    } else {
        set body $raw
    }
    set body [string trim $body]
    # Decode HTML entities that the browser may have inserted.
    set body [string map {&amp; & &lt; < &gt; > &quot; \" &#39; '} $body]

    if {[catch {json::json2dict $body} data]} {
        {*}$reporter "ERROR: body is not valid JSON ($data)."
        set head [string range $raw 0 4999]
        set headLower [string tolower $head]
        if {[string first "login" $headLower] >= 0 || \
            [string first "/accounts/login" $headLower] >= 0} {
            {*}$reporter "Looks like the session redirected to /accounts/login/. Log in via a Chrome-compatible browser first."
        } else {
            {*}$reporter "First 500 chars of body:"
            {*}$reporter [string range $body 0 499]
        }
        return ""
    }
    return $data
}

# Read the file and parse it (the legacy file-fed path). Exits 1 if not JSON.
proc load_payload {path} {
    set f [open $path r]
    fconfigure $f -encoding utf-8
    set raw [read $f]
    close $f
    set data [parse_payload $raw]
    if {$data eq ""} { exit 1 }
    return $data
}

# Fetch a key from a dict, returning $default when absent.
proc dget {d key {default ""}} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}

# Build the human-readable search report string from a parsed topsearch dict.
# Single home for the report so the file-fed and serialiser paths render identically.
proc render_search_report {data} {
    set users [dget $data users {}]
    set places [dget $data places {}]
    set hashtags [dget $data hashtags {}]

    set out {}
    lappend out "users: [llength $users]   places: [llength $places]   hashtags: [llength $hashtags]"
    lappend out ""

    if {[llength $users]} {
        lappend out "=== Users ==="
        foreach entry $users {
            if {[dict exists $entry user]} {
                set u [dict get $entry user]
            } else {
                set u $entry
            }
            set handle [dget $u username "?"]
            set name [dget $u full_name ""]
            set verified [expr {[dget $u is_verified false] eq "true" ? "✓" : ""}]
            set private [expr {[dget $u is_private false] eq "true" ? "\[private\]" : ""}]
            set ctx [dget $u social_context ""]
            if {$ctx eq ""} { set ctx [dget $u search_social_context ""] }
            set url "https://www.instagram.com/$handle/"
            lappend out [string trimright "  @$handle $verified $private"]
            if {$name ne ""} { lappend out "    name: $name" }
            lappend out "    url:  $url"
            if {$ctx ne ""} { lappend out "    ctx:  $ctx" }
            lappend out ""
        }
    }

    if {[llength $hashtags]} {
        lappend out "=== Hashtags ==="
        foreach entry $hashtags {
            if {[dict exists $entry hashtag]} {
                set h [dict get $entry hashtag]
            } else {
                set h $entry
            }
            set name [dget $h name "?"]
            set count [dget $h media_count "?"]
            lappend out "  #$name   ($count posts)"
        }
        lappend out ""
    }

    if {[llength $places]} {
        lappend out "=== Places ==="
        foreach entry $places {
            if {[dict exists $entry place]} {
                set p [dict get $entry place]
            } else {
                set p $entry
            }
            set loc [dget $p location {}]
            set name ""
            set address ""
            if {[string is list -strict $loc] && [llength $loc] % 2 == 0} {
                set name [dget $loc name ""]
                set address [dget $loc address ""]
            }
            if {$name eq ""} { set name [dget $p title ""] }
            if {$name eq ""} { set name "?" }
            lappend out "  $name"
            if {$address ne ""} { lappend out "    $address" }
        }
        lappend out ""
    }
    return [join $out "\n"]
}

proc main {path} {
    puts [render_search_report [load_payload $path]]
}

# ---------------------------------------------------------------------------
# Serialiser entry: the policed-surface path. nav to the topsearch endpoint and
# dump the JSON body (the page wraps it in <pre>), then run the identical
# parse+report logic. Emits the report (or the diagnostic text on a non-JSON
# body, so the failure mode is the same as the file path).
#
# Invoked by reference through the serialiser (see SKILL.md §1-2):
#     browser-serialiser instagram.com/auth-parse-search <search terms>
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set terms [join $skillArgs " "]
    if {$terms eq ""} {
        emit [envelope_fault "Usage: instagram.com/auth-parse-search <search terms>"]
        return
    }
    capture "https://www.instagram.com/explore/search/" --seconds 6 --match {*graphql*}
    if {[dict get [state] terminal] ne ""} {
        emit [envelope_fault "login_wall: the session redirected to /accounts/login/. Log in via a Chrome-compatible browser first."]
        return
    }
    # Focus by script: a click on the box leaves the typed text unplaced.
    set focused [eval {(() => { const i = document.querySelector('input[type=text]');
        if (!i) return false; i.focus(); return document.activeElement === i; })()}]
    if {$focused ne "true"} {
        emit [envelope_fault "the search page offered no search box to type into"]
        return
    }
    type $terms
    set conn xdt_api__v1__fbsearch__topsearch_connection
    set data ""
    for {set i 0} {$i < 4 && $data eq ""} {incr i} {
        dwell 2
        foreach r [harvest --match {*graphql*}] {
            set body [lindex $r 2]
            if {[string first $conn $body] < 0} continue
            if {[catch {json::json2dict $body} d]} continue
            if {[dict exists $d data $conn]} { set data [dict get $d data $conn] }
        }
    }
    if {$data eq ""} {
        emit [envelope_fault "the search box fetched no results for \"$terms\""]
        return
    }
    emit [envelope_ok [dict create result [json::write string [render_search_report $data]]]]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts "Usage: auth-parse-search.tcl <topsearch-response.json|.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    main [lindex $argv 0]
}
