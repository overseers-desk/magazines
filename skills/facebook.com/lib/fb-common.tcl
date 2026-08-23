# fb-common.tcl - shared parsing helpers for the facebook.com site-skill scripts.
#
# Facebook serves randomised CSS class names, no semantic ids, and deeply nested
# div trees, so the parsers work structurally: pull <title>/<meta>/JSON markers
# and visible >text< fragments, filtering framework noise. The handful of
# routines every parser needs live here so the per-script files hold only their
# own extraction logic, mirroring the Python predecessors' shared functions.

package require json

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
    set name $title
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
# The legacy parsers print their report line-by-line with `puts` to stdout and
# `exit 1` on a login wall; under the serialiser there is one output channel
# (`emit`) and stdout does not exist in the safe interp. fb::capture renames
# `puts` to a buffer so the byte-identical printers run untouched, returning the
# captured text; a parser `exit 1` (the login-wall path) surfaces as a catchable
# error in the Safe Base, so the buffer printed before it is returned as-is.
# Keeping this here is single-source-of-truth: every sibling reuses it rather
# than each re-implementing the rename.
# ---------------------------------------------------------------------------

# Run $script, capturing everything its body `puts` to stdout (or explicit
# stdout) into $bodyVar; `puts stderr ...` passes through to the shared stderr.
# A parser `exit` inside the body ends the capture with whatever was buffered
# (under the serialiser, `exit` is the parser's "printed an error, stop" signal,
# not a process exit). Returns the captured text in $bodyVar; the proc's own
# return value is the captured text too, for convenience.
proc fb::capture {bodyVar script} {
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
    # A parser exit (the login-wall path) raised as a Safe Base error: the report
    # printed up to that point is already captured, so swallow it and return the
    # buffer. A different error is re-raised.
    if {$code && $result eq {wrong # args: should be "exit"}} {
        return $captured
    }
    if {$code} {
        return -code $code $result
    }
    return $captured
}
