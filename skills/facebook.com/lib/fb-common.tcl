# fb-common.tcl - shared parsing helpers for the facebook.com site-skill scripts.
#
# Facebook serves randomised CSS class names, no semantic ids, and deeply nested
# div trees, so the parsers work structurally: pull <title>/<meta>/JSON markers
# and visible >text< fragments, filtering framework noise. The handful of
# routines every parser needs live here so the per-script files hold only their
# own extraction logic, mirroring the Python predecessors' shared functions.

package require json
package require json::write

namespace eval fb {}

# Read a file as UTF-8 and return its whole content.
proc fb::read_file {path} {
    set f [open $path r]
    fconfigure $f -encoding utf-8
    set data [read $f]
    close $f
    return $data
}

# Python-equivalent code-point length. Tcl 8.6 stores a non-BMP char as a
# surrogate pair (2 units); subtract the high-surrogate count so the value
# matches Python's len(), which counts one code point per character.
proc fb::cp_length {s} {
    set n [string length $s]
    set hi [regexp -all {[\uD800-\uDBFF]} $s]
    return [expr {$n - $hi}]
}

# Insert thousands separators into a non-negative integer string (Python {:,}).
proc fb::commafy {n} {
    set s $n
    set out ""
    while {[string length $s] > 3} {
        set out ",[string range $s end-2 end]$out"
        set s [string range $s 0 end-3]
    }
    return "$s$out"
}

# The first <title>...</title> content, trimmed; $default when absent.
# The capture is [^<]* (title text is <-free) rather than the Python .*?,
# because Tcl's ARE is POSIX longest-match: a .*? would run to the LAST
# </title> on a page with more than one title, whereas Python's .*? (and this
# [^<]*) take the first. Both yield the first title's text.
# Resolve a profile reference (handle, numeric id, path, or full URL) to a URL
# Facebook serves.
#
# A Page whose slug carries its numeric id, `Name-ID` or `p/Name-ID`, is served
# at /ID/...: the site resolves the hyphenated forms to its own /about, which
# redirects out to meta.com, and the harness ends the run off-site; the
# /people/Name/ID/about route it also offers renders "This content isn't
# available" for the same page. The fold happens before the navigation so the
# guard never sees the redirect.
proc fb::profile_url {ref} {
    set base "https://www.facebook.com"
    set path ""
    if {[regexp {^https?://(?:[a-z0-9-]+\.)?facebook\.com(/.*)?$} $ref -> path]} {
    } elseif {[string match "http*://*" $ref]} {
        return $ref
    } elseif {[regexp {^\d+$} $ref]} {
        return "$base/profile.php?id=$ref"
    } else {
        set path "/[string trimleft $ref @/]"
    }
    if {[regexp {^/(?:p/)?([^/?#]+)-(\d{10,})(/[^?#]*)?(\?.*)?$} $path -> name id rest query]} {
        return "$base/$id$rest$query"
    }
    return "$base$path"
}

proc fb::title {html {default ""}} {
    if {[regexp {(?s)<title[^>]*>([^<]*)</title>} $html -> t]} {
        return [string trim $t]
    }
    return $default
}

# True when the title looks like a Facebook login page (any of the locales the
# Python scripts checked: English and Spanish).
proc fb::title_is_login {title} {
    set lower [string tolower $title]
    foreach t {"log in" "log into" "iniciar sesión"} {
        if {[string first $t $lower] >= 0} { return 1 }
    }
    return 0
}

# Strip the " | Facebook" / " - Facebook" / " – Facebook" suffix from a title to
# recover the bare profile/page name.
proc fb::name_from_title {title} {
    # A signed-in tab prefixes the title with its unread badge, "(4) Name".
    set name [regsub {^\(\d+\)\s*} $title ""]
    foreach sep {" | Facebook" " - Facebook" " – Facebook"} {
        set idx [string first $sep $name]
        if {$idx >= 0} {
            return [string trim [string range $name 0 [expr {$idx-1}]]]
        }
    }
    return $name
}

# Decode the small set of HTML entities the Python scripts decoded inline.
# The mapping and its order mirror the predecessors (each script decoded a
# subset; this is the union, applied left-to-right). &amp; is handled by the
# map alongside the rest, matching the Python str.replace chains (not a second
# pass), so a literal "&amp;amp;" decodes one level, as it did in Python.
proc fb::decode_entities {s} {
    return [string map {
        &amp; & &lt; < &gt; > &#39; ' &quot; \" &#x2F; / &nbsp; " "
    } $s]
}

# Fuller HTML-entity unescape mirroring Python's html.unescape for the entities
# Facebook actually emits in comment data (names, ages, bodies): the common
# named entities plus numeric decimal (&#NNN;) and hex (&#xHH;) references.
# Numeric refs resolve to their code point; named refs map. &amp; is applied
# last so an already-decoded "&" is not reprocessed.
proc fb::unescape {s} {
    # Hex numeric: &#xHH; (case-insensitive x and digits).
    while {[regexp -indices -nocase {&#x([0-9a-f]+);} $s whole digits]} {
        set hex [string range $s [lindex $digits 0] [lindex $digits 1]]
        set ch [format %c [scan $hex %x]]
        set s [string replace $s [lindex $whole 0] [lindex $whole 1] $ch]
    }
    # Decimal numeric: &#NNN;
    while {[regexp -indices {&#([0-9]+);} $s whole digits]} {
        set dec [string range $s [lindex $digits 0] [lindex $digits 1]]
        set ch [format %c $dec]
        set s [string replace $s [lindex $whole 0] [lindex $whole 1] $ch]
    }
    set s [string map {
        &lt; < &gt; > &quot; \" &apos; ' &nbsp; " "
        &mdash; — &ndash; – &hellip; … &middot; · &bull; •
    } $s]
    # &amp; last so it does not double-decode the above.
    return [string map {&amp; &} $s]
}

# Visible-text extractor shared by parse-profile / parse-posts. Find every
# >text< fragment whose inner length is min..max chars, trim it, drop framework
# noise (CSS props, JS, Facebook's randomised class names, module system,
# accessibility attributes), dedupe preserving order, decode entities, and keep
# only fragments of at least min_keep chars. Matches the Python
# extract_visible_texts: same noise list, same min length, same dedup-before-
# decode ordering.
#
# The {min max} window differs per caller (profile uses 5..500, posts uses
# 3..2000), so it is a parameter; min_keep is the post-strip length floor
# (5 for profile, 3 for posts).
# The page's own content: the document from its role="main" region on, less
# the script blocks. What precedes the region is the signed-in chrome, the
# notifications tray and chat drawers among it, whose text otherwise fills a
# report before the page's body arrives; the scripts after it carry the
# chrome's data payloads, which a keyword count would otherwise include. A
# document with no such region is returned whole.
proc fb::main_region {html} {
    if {[regexp -indices {<[a-z]+[^>]*\srole="main"} $html at]} {
        set main [string range $html [lindex $at 0] end]
        return [regsub -all {(?s)<script[\s>][^>]*>.*?</script>} $main ""]
    }
    return $html
}

# True when the document is Facebook's answer for a reference it has no page
# for: the signed-in shell whose content region holds only the notice. The
# title does not tell, since a rendered timeline also captures with the bare
# "Facebook" title, and a post whose attachment is gone carries its own
# "isn't available at the moment" line, which is not this.
proc fb::page_absent {html} {
    set main [fb::main_region $html]
    return [regexp {This (?:page|content) isn.t available(?: right now)?<} $main]
}

proc fb::extract_visible_texts {html {min 5} {max 500} {min_keep 5}} {
    set filtered {}
    set seen {}
    # Capture every >fragment< unbounded, then apply the min..max length window
    # as a filter. This is byte-equivalent to Python's >([^<]{min,max})< — a
    # fragment shorter than min or longer than max never had a matching <
    # within the bound, so it was dropped there too — and sidesteps Tcl's ARE
    # repetition cap of 255 (the Python bounds run to 2000). regexp -all
    # -inline returns {whole sub whole sub ...}; take every 2nd.
    foreach {whole text} [regexp -all -inline -- {>([^<]+)<} $html] {
        set L [string length $text]
        if {$L < $min || $L > $max} { continue }
        set text [string trim $text]
        if {$text eq "" || [dict exists $seen $text]} { continue }
        if {[fb::is_noise $text]} { continue }
        if {[string length $text] < $min_keep} { continue }
        set text [fb::decode_entities $text]
        dict set seen $text 1
        lappend filtered $text
    }
    return $filtered
}

# The noise filter for extract_visible_texts: true when the fragment matches any
# CSS/JS/framework pattern the Python noise_patterns list rejected. Kept as one
# alternation for speed; the alternatives are the Python entries verbatim.
proc fb::is_noise {text} {
    # Anchored-at-start patterns (Python used ^\s* on these).
    if {[regexp {^\s*[\{.]} $text]} { return 1 }
    if {[regexp {^\s*(?:var |function|return |if\s*\()} $text]} { return 1 }
    # Substring/style patterns (Python matched these anywhere via re.search).
    set pat {width:|padding|margin:|font-|display:|background|border|position:|overflow|opacity|color:|transform|transition|animation|z-index|box-shadow|text-decoration|line-height|letter-spacing|white-space|flex|grid|align-|justify-|cursor:|visibility|pointer-events|x[0-9a-z]{7,}|__MODULE|webpack|require\(|exports\.|React\.|componentkey|data-display|tabindex|aria-}
    return [regexp -- $pat $text]
}

# ---------------------------------------------------------------------------
# Serialiser support, shared by every facebook.com script's serialiser_run.
# The parsers print their report line-by-line with `puts` to stdout and `exit 1`
# on a login wall. Under the serialiser there is one output channel (`emit`),
# stdout does not exist in the safe interp, and what a caller reads is the
# canonical envelope. fb::report renames `puts` to a buffer so the printers run
# untouched, then wraps what they printed as the envelope's `result`.
#
# A parser `exit 1` surfaces as a catchable error in the Safe Base, and it means
# the page was a login wall. That returns a fault of shape `login_wall`, so a
# caller reading the envelope sees the wall rather than a half-written report.
# ---------------------------------------------------------------------------

# Run $script, capturing everything its body `puts` to stdout (or explicit
# stdout) into $bodyVar; `puts stderr ...` passes through to the shared stderr.
# Returns the canonical envelope, ready to hand to `emit`.
proc fb::report {bodyVar script} {
    upvar 1 $bodyVar captured
    set ::fb::_cap_buf ""
    rename ::puts ::fb::_cap_real
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
            append ::fb::_cap_buf $str
            if {!$nonewline} { append ::fb::_cap_buf "\n" }
            return
        }
        # stderr (or any other channel): pass through to the real puts.
        if {$nonewline} {
            ::fb::_cap_real -nonewline $chan $str
        } else {
            ::fb::_cap_real $chan $str
        }
    }
    set code [catch {uplevel 1 $script} result]
    set captured $::fb::_cap_buf
    rename ::puts {}
    rename ::fb::_cap_real ::puts
    unset -nocomplain ::fb::_cap_buf
    # A parser exit raised as a Safe Base error: the report printed up to that
    # point is already captured, so swallow it and return it as the fault. The
    # message names its shape after the ERROR: prefix ("removed: ..." for a page
    # the site says is not there, "unrecognised: ..." for a page the parser
    # cannot read); an untagged message is the login wall. A different error
    # is re-raised.
    if {$code && $result eq {wrong # args: should be "exit"}} {
        set msg [regsub {^ERROR:\s*} [string trim $captured] ""]
        if {$msg eq ""} { set msg "Facebook served a login wall" }
        if {[regexp {^unrecognised:\s+} $msg]} {
            regsub {^unrecognised:\s+} $msg "" msg
        } elseif {[fault_shape_of $msg] eq "unrecognised"} {
            set msg "login_wall: $msg"
        }
        return [envelope_fault $msg]
    }
    if {$code} {
        return -code $code $result
    }
    return [envelope_ok [dict create result [json::write string $captured]]]
}
