# ig-html.tcl - shared helpers for reading Instagram HTML pages: meta-tag
# extraction, HTML entity decoding, and follower/following/post count parsing.
#
# Shared verbatim by the skillbooks skills and the BI overseer's playbooks:
# both folders carry a byte-identical copy. Edit the home and re-vendor.
# Home: skillbooks/skills/instagram.com/ig-html.tcl
#
# Pure Tcl (no socket / exec / file), so it runs unchanged inside the safe interp.

# "1,234" / "27.4K" / "686M" -> integer. Suffixed (rounded) values are approx;
# callers prefer an exact comma-number when the page offers one. "" stays "".
proc count_to_int {s} {
    set s [string map {, ""} [string trim $s]]
    if {[regexp -nocase {^([0-9]+(?:\.[0-9]+)?)([kmb]?)$} $s -> num suf]} {
        switch -- [string tolower $suf] {
            k       { return [expr {int($num * 1000)}] }
            m       { return [expr {int($num * 1000000)}] }
            b       { return [expr {int($num * 1000000000)}] }
            default { return [expr {int($num)}] }
        }
    }
    return ""
}

# <meta property="PROP" content="..."> in either attribute order.
proc html_meta {html prop} {
    if {[regexp "<meta\[^>]*?property=\"$prop\"\[^>]*?content=\"(\[^\"]*)\"" $html -> c]} { return $c }
    if {[regexp "<meta\[^>]*?content=\"(\[^\"]*)\"\[^>]*?property=\"$prop\"" $html -> c]} { return $c }
    return ""
}

# <meta name="NAME" content="..."> in either attribute order. The content has no
# literal '"' (Instagram emits inner quotes as &quot;), so [^"]* is a safe bound;
# a greedy .* would overrun the tag (Tcl regexp is leftmost-longest). Multi-line
# content (a bio with newlines) is fine. Returns "" if the named meta is absent.
proc html_meta_named {html name} {
    if {[regexp -- "<meta\[^>]*?name=\"$name\"\[^>]*?content=\"(\[^\"]*)\"" $html -> c]} { return $c }
    if {[regexp -- "<meta\[^>]*?content=\"(\[^\"]*)\"\[^>]*?name=\"$name\"" $html -> c]} { return $c }
    return ""
}

# Minimal HTML entity decode for the text extracted from attributes (bio, name):
# the named/numeric entities Instagram emits in meta content and visible text.
# Numeric entities are decoded by an explicit scan-and-replace (no [subst], which
# would either skip the substitution or be an injection hazard on page content).
# A decimal entity is read with [scan ... %d] so a leading-zero form like &#039;
# (a common apostrophe encoding) is taken as decimal, not as an invalid octal that
# [format %c] would reject. Note: Instagram emits emoji in bios as raw UTF-8, not
# numeric entities, so the numeric path sees only BMP punctuation in practice. This
# Tcl is 8.6 (16-bit internal rep): [format %c] cannot build a codepoint above
# U+FFFF, so a non-BMP numeric entity is left as its literal "&#...;" rather than
# corrupted.
proc html_unescape {s} {
    # numeric entities first, so a literal "&amp;#38;" is not collapsed early.
    set out ""; set i 0
    while {[regexp -indices -start $i {&#[xX]?[0-9a-fA-F]+;} $s span]} {
        lassign $span lo hi
        set tok [string range $s $lo $hi]
        if {[regexp {&#[xX]([0-9a-fA-F]+);} $tok -> hex]} { set code [scan $hex %x] } \
        else { regexp {&#([0-9]+);} $tok -> dec; set code [scan $dec %d] }
        append out [string range $s $i [expr {$lo - 1}]]
        append out [expr {$code <= 0xffff ? [format %c $code] : $tok}]
        set i [expr {$hi + 1}]
    }
    append out [string range $s $i end]
    return [string map {&quot; \" &#039; ' &#39; ' &apos; ' &lt; < &gt; > &nbsp; " " &amp; &} $out]
}
