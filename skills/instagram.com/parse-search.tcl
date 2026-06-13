#!/usr/bin/env tclsh
# Parse Instagram topsearch JSON response.
#
# Usage: tclsh parse-search.tcl <json-file>
#
# Instagram's web search page is GraphQL-hydrated and does not populate results
# in a headless DOM dump within a reasonable virtual-time budget. The internal
# endpoint /web/search/topsearch/?query=X, when fetched with an authenticated
# session, returns clean JSON directly and is the primitive this script expects.
#
# The file may be pure JSON or HTML-wrapped (headless --dump-dom wraps the JSON
# body in <html><body><pre>...). This script handles both.

package require json

# Read the file, unwrap a <pre>...</pre> body if present, decode HTML entities,
# and return the parsed dict. Exits 1 with a diagnostic if the body is not JSON.
proc load_payload {path} {
    set f [open $path r]
    fconfigure $f -encoding utf-8
    set raw [read $f]
    close $f

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
        puts "ERROR: body is not valid JSON ($data)."
        set head [string range $raw 0 4999]
        set headLower [string tolower $head]
        if {[string first "login" $headLower] >= 0 || \
            [string first "/accounts/login" $headLower] >= 0} {
            puts "Looks like the session redirected to /accounts/login/. Log in via a Chrome-compatible browser first."
        } else {
            puts "First 500 chars of body:"
            puts [string range $body 0 499]
        }
        exit 1
    }
    return $data
}

# Fetch a key from a dict, returning $default when absent.
proc dget {d key {default ""}} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}

proc main {path} {
    set data [load_payload $path]
    set users [dget $data users {}]
    set places [dget $data places {}]
    set hashtags [dget $data hashtags {}]

    puts "users: [llength $users]   places: [llength $places]   hashtags: [llength $hashtags]"
    puts ""

    if {[llength $users]} {
        puts "=== Users ==="
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
            set line [string trimright "  @$handle $verified $private"]
            puts $line
            if {$name ne ""} { puts "    name: $name" }
            puts "    url:  $url"
            if {$ctx ne ""} { puts "    ctx:  $ctx" }
            puts ""
        }
    }

    if {[llength $hashtags]} {
        puts "=== Hashtags ==="
        foreach entry $hashtags {
            if {[dict exists $entry hashtag]} {
                set h [dict get $entry hashtag]
            } else {
                set h $entry
            }
            set name [dget $h name "?"]
            set count [dget $h media_count "?"]
            puts "  #$name   ($count posts)"
        }
        puts ""
    }

    if {[llength $places]} {
        puts "=== Places ==="
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
            puts "  $name"
            if {$address ne ""} { puts "    $address" }
        }
        puts ""
    }
}

if {[llength $argv] != 1} {
    puts "Usage: parse-search.tcl <topsearch-response.json|.html>"
    exit 1
}
fconfigure stdout -encoding utf-8
main [lindex $argv 0]
