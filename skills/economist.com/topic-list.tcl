# topic-list.tcl - enumerate a topic's articles, newest first, paging the
# Economist topic feed by its cursor. Emits a TSV of one article per line:
#   datePublished<TAB>url-path<TAB>headline
#
# The topic page server-renders 12 articles plus a cursor; the next page is the
# same URL with ?after=<endCursor>. ?page=N is ignored by the server, so cursor
# paging is the only way through the feed. Stops at the requested year boundary:
# once a whole page holds no article of the target year (the feed is newest
# first), nothing older can match, so paging ends.
#
#   browser-serialiser economist.com/topic-list [topic-slug] [--year YYYY] [--max-pages N]

source [file join [file dirname [info script]] economist.tcl]

proc serialiser_run {skillArgs} {
    set topic artificial-intelligence
    set year 2026
    set maxPages 80
    set positional {}
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set arg [lindex $skillArgs $i]
        switch -- $arg {
            --year      { incr i; set year [lindex $skillArgs $i] }
            --max-pages { incr i; set maxPages [lindex $skillArgs $i] }
            default     { lappend positional $arg }
        }
    }
    if {[llength $positional]} { set topic [lindex $positional 0] }

    set base "https://www.economist.com/topics/$topic"
    set rows {}
    set seen {}
    set cursor ""
    for {set page 0} {$page < $maxPages} {incr page} {
        set url $base
        if {$cursor ne ""} { append url "?after=$cursor" }
        nav $url --wait 4
        if {[dict get [state] terminal] ne ""} {
            log "wall hit on page $page: [dict get [state] terminal]"
            break
        }
        set pp [economist::nextdata [dump]]
        set articles [economist::topic_articles $pp]
        lassign [economist::topic_pageinfo $pp] hasNext endCursor total

        # Two counts: matchedHere is articles whose canonical (URL) date is the
        # target year — what we keep; pubInYear is articles whose datePublished
        # is the target year — what the stop condition watches, since the feed is
        # ordered by datePublished. They differ because a republished older
        # article carries a bumped datePublished, so it rides high in the feed
        # (counts for pubInYear) yet belongs to an earlier year (excluded from
        # matchedHere). Paging therefore continues on datePublished and the year
        # filter is applied on the URL date.
        set matchedHere 0
        set pubInYear 0
        foreach rec $articles {
            lassign $rec date datepub u headline rubric
            if {[string range $datepub 0 3] eq $year} { incr pubInYear }
            if {[string range $date 0 3] ne $year} { continue }
            if {[dict exists $seen $u]} { continue }
            dict set seen $u 1
            incr matchedHere
            lappend rows "$date\t$u\t$headline"
        }
        log "page $page: [llength $articles] articles, $matchedHere dated $year (pub-$year $pubInYear), total feed $total, hasNext $hasNext"
        # Newest-first by datePublished: once a whole page has no datePublished in
        # the target year, the bumped-forward tail is exhausted and nothing older
        # can re-enter. Stop only after collecting something, so a topic whose
        # newest items predate the target year is not cut at page 0.
        if {$pubInYear == 0 && [llength $rows] > 0} { break }
        if {!$hasNext || $endCursor eq "" || $endCursor eq $cursor} { break }
        set cursor $endCursor
        dwell 2
    }
    emit [join $rows "\n"]
}
