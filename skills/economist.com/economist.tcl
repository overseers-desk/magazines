#!/usr/bin/env tclsh
# economist.tcl - shared parser for The Economist's Next.js pages, plus the CLI
# the serialiser drivers (topic-list.tcl, fetch-article.tcl) source as a library.
#
# Every Economist page embeds its data in a <script id="__NEXT_DATA__"> JSON
# blob; the rendered DOM lists are a view of it. Parsing that blob is immune to
# the markup churn the visible HTML carries between design-system releases.
#
# Sourced as a module it exposes: economist::nextdata, economist::topic_articles,
# economist::article_markdown, economist::clean. Run directly it is a CLI for
# testing against a saved dump:
#   economist.tcl list    <dump.html> [--year YYYY]   # topic page -> TSV
#   economist.tcl article <dump.html>                 # article page -> markdown

package require json

namespace eval economist {}

# Pull the __NEXT_DATA__ JSON out of a rendered page and return props.pageProps
# as a Tcl dict. Exits with a plain diagnostic when the blob is absent: that is a
# Chromium error page or a login wall, a browser-side fetch failure, not an
# Economist response to reason about.
proc economist::nextdata {html} {
    set m [regexp -inline {(?s)<script id="__NEXT_DATA__"[^>]*>(.*?)</script>} $html]
    if {[llength $m] < 2} {
        set snippet [string trim [regsub -all {\s+} [string range $html 0 159] " "]]
        return -code error "no __NEXT_DATA__ in page (browser error or login wall, not an\
 Economist payload). Starts: $snippet"
    }
    set data [json::json2dict [lindex $m 1]]
    return [dict get $data props pageProps]
}

proc economist::get {d key {default ""}} {
    if {[dict exists $d $key]} { return [dict get $d $key] }
    return $default
}

# Collapse whitespace; the body `text` fields are already plain (no entities).
# json::json2dict renders a JSON null as the literal "null"; an absent optional
# field (byline, rubric) arrives that way, so treat it as empty.
proc economist::clean {s} {
    if {$s eq "null"} { return "" }
    return [string trim [regsub -all {\s+} $s " "]]
}

# The canonical publish date is the YYYY-MM-DD embedded in the URL path
# (/section/YYYY/MM/DD/slug). datePublished is unreliable for this: a republished
# or revised article carries a bumped datePublished (an article first run in 2024
# can show a 2026 datePublished), which would misfile it by year. Empty when the
# path carries no date (a few hub URLs do not).
proc economist::url_date {url} {
    if {[regexp {/(\d{4})/(\d{2})/(\d{2})/} $url -> y m d]} {
        return "$y-$m-$d"
    }
    return ""
}

# A topic page's article list: one {date datepub url headline rubric} record per
# article, in the page's own order. date is the canonical URL-path date used for
# year filtering and display; datepub is datePublished, the field the feed is
# ordered by and which a caller pages against.
proc economist::topic_articles {pageProps} {
    set out {}
    foreach a [economist::get [economist::get $pageProps content] articles] {
        set url [economist::get $a url]
        lappend out [list [economist::url_date $url] \
            [string range [economist::get $a datePublished] 0 9] \
            $url \
            [economist::clean [economist::get $a headline]] \
            [economist::clean [economist::get $a rubric]]]
    }
    return $out
}

# The pageInfo a driver pages on: {hasNext endCursor totalCount}.
proc economist::topic_pageinfo {pageProps} {
    set pg [economist::get $pageProps pagination]
    set info [economist::get $pg pageInfo]
    return [list [economist::get $info hasNextPage 0] \
                 [economist::get $info endCursor] \
                 [economist::get $pg totalCount]]
}

# Flatten one body node to text lines, appended to listVar. Handles the node
# types the AI-topic articles actually carry; an unknown type with a `text`
# field still renders, anything else is skipped rather than guessed at.
proc economist::RenderNode {node listVar} {
    upvar 1 $listVar lines
    set type [economist::get $node type]
    switch -- $type {
        CROSSHEAD {
            lappend lines "" "## [economist::clean [economist::get $node text]]" ""
        }
        UNORDERED_LIST - ORDERED_LIST {
            foreach item [economist::get $node items] {
                lappend lines "- [economist::clean [economist::get $item text]]"
            }
            lappend lines ""
        }
        INFOBOX {
            foreach c [economist::get $node components] {
                economist::RenderNode $c lines
            }
        }
        default {
            set t [economist::clean [economist::get $node text]]
            if {$t ne ""} { lappend lines $t "" }
        }
    }
}

# Render an article pageProps as markdown: headline, fly/rubric, date, byline,
# then the body. The `text` fields are the clean reading text; textHtml (links,
# emphasis) is dropped on purpose, since the ask is the article text.
proc economist::article_markdown {pageProps} {
    set c [economist::get $pageProps content]
    set lines {}
    lappend lines "# [economist::clean [economist::get $c headline]]"
    set sub [economist::clean [economist::get $c rubric]]
    if {$sub ne ""} { lappend lines "" "*[set sub]*" }
    set meta {}
    set fly [economist::clean [economist::get $c flyTitle]]
    if {$fly ne ""} { lappend meta $fly }
    set date [economist::url_date [economist::get $c url]]
    if {$date ne ""} { lappend meta $date }
    set by [economist::clean [economist::get $c byline]]
    if {$by ne ""} { lappend meta $by }
    if {[llength $meta]} { lappend lines "" [join $meta " · "] }
    lappend lines "" "https://www.economist.com[economist::get $c url]" ""
    foreach node [economist::get $c body] {
        economist::RenderNode $node lines
    }
    return [join $lines "\n"]
}

# --- CLI entry point (only when run directly, not when sourced). ---
proc economist::main {argv} {
    set year ""
    set positional {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        if {$arg eq "--year"} { incr i; set year [lindex $argv $i] } else { lappend positional $arg }
    }
    if {[llength $positional] < 2} {
        puts stderr "usage: economist.tcl {list|article} <dump.html> \[--year YYYY\]"
        exit 2
    }
    lassign $positional mode dump
    set fh [open $dump r]; fconfigure $fh -encoding utf-8
    set html [read $fh]; close $fh
    set pp [economist::nextdata $html]
    switch -- $mode {
        list {
            foreach rec [economist::topic_articles $pp] {
                lassign $rec date datepub url headline rubric
                if {$year ne "" && [string range $date 0 3] ne $year} { continue }
                puts "$date\t$url\t$headline"
            }
            puts stderr "pageinfo: [economist::topic_pageinfo $pp]"
        }
        article { puts [economist::article_markdown $pp] }
        default { puts stderr "economist.tcl: mode must be list or article"; exit 2 }
    }
}

if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    economist::main $argv
}
