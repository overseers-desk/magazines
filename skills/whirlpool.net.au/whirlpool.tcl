#!/usr/bin/env tclsh
# whirlpool.tcl - parse Whirlpool forum pages into clean records.
#
# Both surfaces this touches are static HTML served to a plain fetch (no
# browser, no login): the forum search results page
# (forums.whirlpool.net.au/search?q=...) and the per-thread archive page
# (forums.whirlpool.net.au/archive/<id>). The site's value is buried in deeply
# nested, whitespace-heavy markup; this script pulls the signal out.
#
#   whirlpool.tcl search <dump.html | search-URL> [--limit N]
#   whirlpool.tcl thread <dump.html | archive-URL> [--limit N]
#
# Given a URL rather than a file it fetches with curl (a plain GET; the pages
# are public). Given a file it parses what is already on disk, so a page fetched
# some other way (WebFetch, a browser --dump) parses the same.

namespace eval wp {
    # A desktop UA. The pages do not cloak on UA (verified), but a browser-ish
    # string keeps the fetch indistinguishable from an ordinary read.
    variable ua "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
}

# Read a dump file, or fetch a URL with curl. Exits with a plain diagnostic
# rather than letting a fetch failure surface as an empty parse.
proc wp::load {src} {
    variable ua
    if {[regexp {^https?://} $src]} {
        if {[catch {exec curl -sS -A $ua --compressed $src} body]} {
            puts stderr "whirlpool.tcl: fetch failed: $body"
            exit 1
        }
        return $body
    }
    set fh [open $src r]
    fconfigure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    return $text
}

# Decode the HTML entities Whirlpool pages actually carry. No subst: the input
# is untrusted page text, so command/variable substitution must never touch it.
proc wp::unescape {s} {
    while {[regexp -indices {&#[xX]([0-9A-Fa-f]+);} $s whole d]} {
        set ch [format %c [scan [string range $s [lindex $d 0] [lindex $d 1]] %x]]
        set s [string replace $s [lindex $whole 0] [lindex $whole 1] $ch]
    }
    while {[regexp -indices {&#([0-9]+);} $s whole d]} {
        set ch [format %c [string range $s [lindex $d 0] [lindex $d 1]]]
        set s [string replace $s [lindex $whole 0] [lindex $whole 1] $ch]
    }
    set map [list {&lt;} {<} {&gt;} {>} {&quot;} {"} {&apos;} {'} \
                  {&nbsp;} { } {&raquo;} {»} {&ndash;} {–} {&mdash;} {—} \
                  {&hellip;} {…} {&amp;} {&}]
    return [string map $map $s]
}

# Strip tags to plain text, collapsing runs of whitespace. Keeps paragraph and
# line breaks as newlines so a post body reads as it was written.
proc wp::text {html} {
    # Block boundaries -> newlines before tags are stripped.
    set html [regsub -all {(?i)<br\s*/?>} $html "\n" ]
    set html [regsub -all {(?i)</p>} $html "\n\n" ]
    set html [regsub -all {(?i)<li[^>]*>} $html "\n- " ]
    set html [regsub -all {(?i)</blockquote>} $html "\n" ]
    # Drop every remaining tag.
    set html [regsub -all {<[^>]+>} $html "" ]
    set html [wp::unescape $html]
    # Normalise whitespace: collapse spaces/tabs, trim each line, cap blank runs.
    set out {}
    foreach line [split $html "\n"] {
        lappend out [string trim [regsub -all {[ \t]+} $line " "]]
    }
    set joined [join $out "\n"]
    set joined [regsub -all {\n{3,}} $joined "\n\n"]
    return [string trim $joined]
}

# Collapse to a single trimmed line, truncate to n chars with an ellipsis.
proc wp::oneline {s {n ""}} {
    set s [regsub -all {<[^>]+>} $s ""]
    set s [string trim [regsub -all {\s+} [wp::unescape $s] " "]]
    if {$n ne "" && [string length $s] > $n} {
        return "[string range $s 0 [expr {$n-1}]]..."
    }
    return $s
}

# --- search --------------------------------------------------------------

# Parse the search results page. Each hit is an <li value="N"> inside
# <ol class="results">, carrying a title+archive link, a forum/subforum/age
# detail line, a canonical URL, and a snippet.
proc wp::cmd_search {html limit} {
    if {![regexp {(?s)<ol class="results">(.*?)</ol>} $html -> block]} {
        puts stderr "whirlpool.tcl: no results list found (not a search page, or zero hits)."
        return
    }
    # Index-split on the <li> opening tag. A regexp `.*?</li>` cannot be used:
    # Tcl sets a branch's greediness from its first quantifier, and the leading
    # `\d+` is greedy, so the trailing `.*?` would run to the last </li>.
    set opens {}
    foreach idx [regexp -all -inline -indices {<li value="\d+">} $block] {
        lappend opens [lindex $idx 0]
    }
    set nitems [llength $opens]
    set n 0
    for {set k 0} {$k < $nitems} {incr k} {
        set from [lindex $opens $k]
        set to [expr {$k+1 < $nitems ? [lindex $opens [expr {$k+1}]]-1 : [string length $block]-1}]
        set li [string range $block $from $to]
        incr n
        if {$limit ne "" && $n > $limit} break
        set title "" ; set url "" ; set forum "" ; set age "" ; set snippet ""
        if {[regexp {(?s)<div class="title"><a href="([^"]+?)">(.*?)</a>} $li -> url title] } {}
        regexp {(?s)<div class="detail">(.*?)</div>} $li -> detail
        if {[info exists detail]} {
            # Forum trail: the <a> texts joined by »; age is the trailing text.
            set trail {}
            foreach a [regexp -all -inline {(?s)<a [^>]*?>(.*?)</a>} $detail] {
                if {[string match {<a *} $a]} continue
                lappend trail [wp::oneline $a]
            }
            set forum [join $trail " » "]
            # Strip the <a>..</a> away; what remains (minus » and nbsp) is the age.
            set rest [regsub -all {(?s)<a [^>]*>.*?</a>} $detail ""]
            set age [wp::oneline $rest]
            set age [string trim [regsub -all {(?:»|&raquo;| )+} $age " "]]
            set age [string trim $age]
            unset detail
        }
        if {[regexp {(?s)<div class="snippet">(.*?)</div>} $li -> snippet]} {}
        set full $url
        if {[string match /* $url]} { set full "https://forums.whirlpool.net.au$url" }
        puts "$n. [wp::oneline $title]"
        puts "   forum:   $forum   ($age)"
        puts "   archive: $full"
        set sn [wp::oneline $snippet 280]
        if {$sn ne ""} { puts "   snippet: $sn" }
        puts ""
    }
    if {$n == 0} { puts stderr "whirlpool.tcl: results list present but held no items." }
}

# --- thread --------------------------------------------------------------

# Parse an archive thread page. The whole thread is on one page (archive pages
# do not paginate, even at hundreds of posts), so one fetch yields every post.
# Each post is a <div class="reply reply-archived"> block.
proc wp::cmd_thread {html limit} {
    set title ""
    if {[regexp {(?s)<title>(.*?)</title>} $html -> title]} {
        set title [wp::oneline $title]
    }
    # Split on the post-block opening tag; the first shard is page chrome.
    # Match the post div whatever its attribute order or extras: some carry a
    # style="", the thread's last post leads with an id="rr0".
    set shards [regexp -all -inline -indices {<div [^>]*class="reply reply-archived[^"]*"[^>]*>} $html]
    set starts {}
    foreach idx $shards { lappend starts [lindex $idx 0] }
    if {[llength $starts] == 0} {
        puts stderr "whirlpool.tcl: no posts found (not an archive thread page)."
        return
    }
    set nshards [llength $starts]
    # First pass: parse each shard, keeping only real posts. The newer archive
    # layout (2026 alphanumeric ids) opens with a "last updated" metadata div of
    # the same class that carries neither poster nor body; it drops out here.
    set posts {}
    for {set i 0} {$i < $nshards} {incr i} {
        set from [lindex $starts $i]
        set to [expr {$i+1 < $nshards ? [lindex $starts [expr {$i+1}]]-1 : [string length $html]-1}]
        set post [string range $html $from $to]

        set poster "" ; set userid "" ; set iso "" ; set human "" ; set body ""
        regexp {(?s)<span class="bu_name"[^>]*?>(.*?)</span>} $post -> poster
        regexp {(?s)<span class="userid">(.*?)</span>} $post -> userid
        regexp {(?s)<span itemprop="datePublished" content="([^"]+)"} $post -> iso
        regexp {(?s)<span itemprop="datePublished"[^>]*?>(.*?)</span>} $post -> human
        set is_op [regexp {class="op"} $post]
        # Body: the itemprop="text" span. Cut it out before tag-stripping so
        # quoted-reference blocks stay attached where they belong.
        if {[regexp {(?s)<span itemprop="text">(.*?)</span>\s*(?:<div class="tags"|</div>)} $post -> body]} {
        } elseif {[regexp {(?s)<span itemprop="text">(.*)$} $post -> body]} {
            # Fallback: take to the block end if the closing anchor moved.
            regexp {(?s)^(.*?)</span>} $body -> body
        }
        set poster [wp::oneline $poster]
        if {$poster eq "" && [string trim [wp::text $body]] eq ""} continue
        lappend posts [list $poster [wp::oneline $userid] [wp::oneline $human] $iso $is_op $body]
    }

    set total [llength $posts]
    puts "# $title"
    puts "# $total post(s)\n"
    set num 0
    foreach p $posts {
        incr num
        if {$limit ne "" && $num > $limit} break
        lassign $p poster userid human iso is_op body
        set marker ""
        if {$is_op} { set marker " \[O.P.\]" }
        puts "===== POST $num/$total ====="
        puts "$poster ($userid)$marker"
        puts [string trim "$human [expr {$iso ne "" ? "($iso)" : ""}]"]
        puts ""
        puts [wp::text $body]
        puts ""
    }
}

proc wp::main {argv} {
    set positional {}
    set limit ""
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        switch -- $a {
            --limit { incr i; set limit [lindex $argv $i] }
            default { lappend positional $a }
        }
    }
    lassign $positional mode src
    if {$mode ni {search thread} || $src eq ""} {
        puts stderr "usage: whirlpool.tcl search|thread <dump.html | URL> \[--limit N\]"
        exit 2
    }
    set html [wp::load $src]
    switch -- $mode {
        search { wp::cmd_search $html $limit }
        thread { wp::cmd_thread $html $limit }
    }
}

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    wp::main $argv
}
