#!/usr/bin/env tclsh
# reddit.tcl - parse a Reddit .json dump and the shared printers/parser the
# CDP-driver scripts (reddit-discussions.tcl, reddit-saved.tcl) source.
#
# The headless-browser wrapper renders the JSON endpoint's response inside an
# HTML <pre>; load strips that wrapper, unescapes entities, and returns the
# decoded JSON. Reddit's JSON carries original-language text, so this path is
# immune to the account-locale auto-translation that corrupts the rendered
# old.reddit HTML.
#
# Sourced as a module it exposes: reddit::clean, reddit::iso, reddit::render_post,
# reddit::render_comment, reddit::print_saved, reddit::cmd_thread, reddit::cmd_search,
# reddit::cmd_saved, reddit::load. Run directly it is a CLI:
#   reddit.tcl search <dump.html> [--limit N]   # parse a search.json Listing
#   reddit.tcl thread <dump.html> [--limit N]   # parse a comments/<id>.json reply
#   reddit.tcl saved  <dump.html> [--limit N]   # parse a user/<n>/saved.json Listing

package require json

namespace eval reddit {}

# Decode a dump file: strip the wrapper's <pre>, unescape HTML entities, and
# return the parsed JSON (a Tcl dict/list). Exits with a plain diagnostic when
# the file is a browser error/interstitial page rather than Reddit JSON.
proc reddit::load {path} {
    set fh [open $path r]
    fconfigure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    set m [regexp -inline {(?s)<pre[^>]*>(.*?)</pre>} $text]
    if {[llength $m] >= 2} {
        set raw [reddit::HtmlUnescape [lindex $m 1]]
        set had_pre 1
    } else {
        set raw $text
        set had_pre 0
    }
    set raw [string trim $raw]
    # A bare HTML document (no <pre>-wrapped JSON) is a Chromium network-error
    # page or a login/block interstitial: the fetch failed at the browser, not
    # at Reddit. Say so plainly. Otherwise a CSS brace in that page leads the
    # JSON parser into a cryptic error that invites wrong guesses like
    # "rate limited".
    if {!$had_pre && [string index $raw 0] eq "<"} {
        set snippet [string trim [regsub -all {\s+} [string range $raw 0 159] " "]]
        puts stderr "reddit.tcl: $path is an HTML page, not JSON. The browser fetch\
 failed (profile lock, login wall, or Chromium error page); this\
 is not a Reddit rate limit. Starts: $snippet"
        exit 1
    }
    set start [string first "\{" $raw]
    set bracket [string first "\[" $raw]
    if {$bracket != -1 && ($bracket < $start || $start == -1)} {
        set start $bracket
    }
    if {$start > 0} {
        set raw [string range $raw $start end]
    }
    if {[catch {json::json2dict $raw} data]} {
        puts stderr "reddit.tcl: $path did not parse as JSON ($data);\
 likely a browser error page, not Reddit data."
        exit 1
    }
    return $data
}

# Unescape the HTML entities the wrapper's <pre> rendering introduces. Mirrors
# Python html.unescape for the entities Reddit JSON dumps actually carry.
# Numeric entities (&#NNN; / &#xHH;) decode to their code point; named ones map.
# No subst here: the input is untrusted page text, so command/variable
# substitution must never touch it.
proc reddit::HtmlUnescape {s} {
    # Hex numeric entities.
    while {[regexp -indices {&#[xX]([0-9A-Fa-f]+);} $s whole digits]} {
        set hex [string range $s [lindex $digits 0] [lindex $digits 1]]
        set ch [format %c [scan $hex %x]]
        set s [string replace $s [lindex $whole 0] [lindex $whole 1] $ch]
    }
    # Decimal numeric entities.
    while {[regexp -indices {&#([0-9]+);} $s whole digits]} {
        set dec [string range $s [lindex $digits 0] [lindex $digits 1]]
        set ch [format %c $dec]
        set s [string replace $s [lindex $whole 0] [lindex $whole 1] $ch]
    }
    # Named entities. &amp; last so it does not double-decode the others. Each
    # entity is brace-quoted because its trailing ; would otherwise terminate
    # the bracketed list command.
    set map [list {&lt;} {<} {&gt;} {>} {&quot;} {"} {&apos;} {'} {&nbsp;} { } {&amp;} {&}]
    return [string map $map $s]
}

# Format a unix epoch as YYYY-MM-DD in UTC; empty for a falsy/empty epoch.
proc reddit::iso {epoch} {
    if {$epoch eq "" || $epoch == 0} {
        return ""
    }
    return [clock format [expr {int($epoch)}] -format "%Y-%m-%d" -timezone :UTC]
}

# Collapse whitespace, undo Reddit's own entity escaping and markdown escapes,
# and truncate to n chars with an ellipsis. n empty means no truncation.
proc reddit::clean {s {n ""}} {
    if {$s eq ""} {
        return ""
    }
    # Reddit escapes <, >, & inside selftext/body, so unescape a second time
    # (the wrapper's <pre> unescape in load only undoes the HTML rendering
    # layer; for the §3/§4 in-page fetch path there is no <pre> layer and this
    # is the only unescape).
    set s [reddit::HtmlUnescape $s]
    set s [string map [list "\\~" "~" "\\_" "_" "\r" ""] $s]
    set s [string trim [regsub -all {\s+} $s " "]]
    if {$n ne "" && [string length $s] > $n} {
        return "[string range $s 0 [expr {$n-1}]]..."
    }
    return $s
}

# Read a key from a dict with a default when absent.
proc reddit::get {d key {default ""}} {
    if {[dict exists $d $key]} {
        return [dict get $d $key]
    }
    return $default
}

proc reddit::render_post {d} {
    puts "## [reddit::clean [reddit::get $d title]]"
    set meta [list \
        "r/[reddit::get $d subreddit]" \
        "u/[reddit::get $d author]" \
        "score [reddit::get $d score ?]" \
        "[reddit::get $d num_comments ?] comments" \
        [reddit::iso [reddit::get $d created_utc]]]
    puts "   [join $meta " | "]"
    puts "   https://old.reddit.com[reddit::get $d permalink]"
    set body [reddit::clean [reddit::get $d selftext] 200]
    if {$body ne ""} {
        puts "   $body"
    }
}

proc reddit::render_comment {d} {
    # A saved comment carries link_title (the post it sits under) but no title
    # of its own; its permalink points at the comment within that post.
    puts "## \[comment\] [reddit::clean [reddit::get $d link_title]]"
    set meta [list \
        "r/[reddit::get $d subreddit]" \
        "u/[reddit::get $d author]" \
        "score [reddit::get $d score ?]" \
        [reddit::iso [reddit::get $d created_utc]]]
    puts "   [join $meta " | "]"
    puts "   https://old.reddit.com[reddit::get $d permalink]"
    set body [reddit::clean [reddit::get $d body] 300]
    if {$body ne ""} {
        puts "   $body"
    }
}

proc reddit::cmd_search {data limit} {
    set children [dict get $data data children]
    set n 0
    foreach c $children {
        if {$n >= $limit} { break }
        reddit::render_post [dict get $c data]
        puts ""
        incr n
    }
}

# Print a saved Listing's children (mixed posts t3 and comments t1), newest
# first. Returns the number printed.
proc reddit::print_saved {children limit} {
    set n 0
    foreach c $children {
        if {$n >= $limit} { break }
        set kind [reddit::get $c kind]
        set d [reddit::get $c data]
        if {$kind eq "t3"} {
            reddit::render_post $d
        } elseif {$kind eq "t1"} {
            reddit::render_comment $d
        } else {
            continue
        }
        incr n
        puts ""
    }
    return $n
}

proc reddit::cmd_saved {data limit} {
    reddit::print_saved [dict get $data data children] $limit
}

# Recursively print a comment tree, capping the total emitted at limit. counter
# is passed by name (a Tcl idiom for the Python [0] mutable box).
proc reddit::walk {children limit counterVar {depth 0}} {
    upvar 1 $counterVar counter
    foreach c $children {
        if {$counter >= $limit} { return }
        if {[reddit::get $c kind] ne "t1"} { continue }
        set d [dict get $c data]
        set body [reddit::clean [reddit::get $d body]]
        if {$body ne ""} {
            incr counter
            set indent [string repeat "  " $depth]
            puts "$indent- u/[reddit::get $d author] (score [reddit::get $d score ?], [reddit::iso [reddit::get $d created_utc]]): $body"
        }
        set replies [reddit::get $d replies]
        # A leaf comment carries replies as "" (empty string); only a non-empty
        # dict with a data.children list recurses.
        if {[reddit::IsListingDict $replies]} {
            reddit::walk [dict get $replies data children] $limit counter [expr {$depth+1}]
        }
    }
}

# True when v is a dict shaped like a Reddit Listing (has data.children).
proc reddit::IsListingDict {v} {
    if {$v eq ""} { return 0 }
    if {[catch {dict get $v data children} children]} { return 0 }
    return 1
}

# True when v is a JSON object (a Tcl dict), as opposed to a scalar or the empty
# value Reddit sends when a saved listing is withheld. Mirrors Python's
# isinstance(data, dict): a withheld listing has no object body to read.
proc reddit::IsDict {v} {
    if {$v eq ""} { return 0 }
    if {[catch {dict size $v} sz]} { return 0 }
    return 1
}

proc reddit::cmd_thread {data limit} {
    set post [dict get [lindex [dict get [lindex $data 0] data children] 0] data]
    puts "# [reddit::clean [reddit::get $post title]]"
    puts "r/[reddit::get $post subreddit] | u/[reddit::get $post author] | score [reddit::get $post score ?] | [reddit::get $post num_comments ?] comments | [reddit::iso [reddit::get $post created_utc]]"
    puts "https://old.reddit.com[reddit::get $post permalink]"
    set selftext [reddit::clean [reddit::get $post selftext]]
    if {$selftext ne ""} {
        puts "\n$selftext\n"
    }
    puts "--- comments ---"
    set counter 0
    reddit::walk [dict get [lindex $data 1] data children] $limit counter
}

# ---------------------------------------------------------------------------
# Serialiser-path shared helper. The driver scripts (reddit-discussions.tcl,
# reddit-saved.tcl) run inside the policed safe interp and reach Reddit's .json
# endpoints through the `api` verb, which replays a same-origin fetch from the
# already-navigated old.reddit.com page (cookies + locale apply) and lets the
# harness classify 429/login walls. This helper splits an absolute old.reddit
# URL into the same-origin path + query the `api` verb expects, invokes it, and
# returns [list ok <dict>] or [list error <msg>] in the same shape the legacy
# in-page fetch_json used, so each driver's listing/paging flow is unchanged.
# Lives here, not in each driver, to keep the fetch logic single-sourced.
# Capture everything the byte-identical render/print procs `puts` to stdout while
# $body runs, returning the captured text. A `puts stderr ...` (diagnostics) is
# passed through to the shared stderr untouched; only default-channel and
# explicit-stdout writes are buffered. This lets the drivers reuse the legacy
# printers (reddit::render_post, reddit::cmd_thread, reddit::print_saved) verbatim
# under the serialiser, where the run's one output is the emitted string.
proc reddit::sv_capture {bodyVar script} {
    upvar 1 $bodyVar captured
    set captured ""
    rename ::puts ::reddit::_real_puts
    proc ::puts {args} {
        # Forms: puts ?-nonewline? ?channel? string
        set nonewline 0
        if {[lindex $args 0] eq "-nonewline"} {
            set nonewline 1
            set args [lrange $args 1 end]
        }
        if {[llength $args] == 2} {
            set chan [lindex $args 0]
            set str [lindex $args 1]
        } else {
            set chan stdout
            set str [lindex $args 0]
        }
        if {$chan in {stdout ""}} {
            append ::reddit::_sv_buf $str
            if {!$nonewline} { append ::reddit::_sv_buf "\n" }
            return
        }
        # stderr (or any other channel): pass through to the real puts.
        if {$nonewline} {
            ::reddit::_real_puts -nonewline $chan $str
        } else {
            ::reddit::_real_puts $chan $str
        }
    }
    set ::reddit::_sv_buf ""
    set code [catch {uplevel 1 $script} result options]
    set captured $::reddit::_sv_buf
    rename ::puts {}
    rename ::reddit::_real_puts ::puts
    unset -nocomplain ::reddit::_sv_buf
    return -options $options $result
}

proc reddit::sv_fetch_json {url} {
    # Same-origin split: drop the scheme://host, keep /path, hand ?query to
    # --params (the harness re-appends it). The Accept header keeps Reddit on the
    # JSON representation; the harness adds X-CSRFToken/X-Requested-With itself.
    if {![regexp {^[a-z]+://[^/]+(/[^?]*)(?:\?(.*))?$} $url -> path query]} {
        return [list error "could not split URL into path+query: $url"]
    }
    if {[catch {api $path --params $query --headers {Accept application/json}} body]} {
        return [list error $body]
    }
    if {[catch {json::json2dict $body} data]} {
        return [list error "non-JSON response (blocked or login wall): [string range $body 0 119]"]
    }
    return [list ok $data]
}

# --- CLI entry point (only when run directly, not when sourced). ---
proc reddit::main {argv} {
    set limit 25
    set positional {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        if {$arg eq "--limit"} {
            incr i
            set limit [lindex $argv $i]
        } else {
            lappend positional $arg
        }
    }
    if {[llength $positional] < 2} {
        puts stderr "usage: reddit.tcl {search|thread|saved} <dump> \[--limit N\]"
        exit 2
    }
    lassign $positional mode dump
    if {$mode ni {search thread saved}} {
        puts stderr "reddit.tcl: mode must be one of search, thread, saved"
        exit 2
    }
    set data [reddit::load $dump]
    switch -- $mode {
        search { reddit::cmd_search $data $limit }
        saved  { reddit::cmd_saved $data $limit }
        thread { reddit::cmd_thread $data $limit }
    }
}

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    reddit::main $argv
}
