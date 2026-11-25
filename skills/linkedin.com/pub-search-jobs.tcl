#!/usr/bin/env tclsh
# Job search by keyword and place, read signed out.
#
# Serialiser path:
#   browser-serialiser linkedin.com/pub-search-jobs "<keywords>"
#   browser-serialiser linkedin.com/pub-search-jobs '{"keywords":"chief AI officer","location":"Spain","posted":"month"}'
#
# Direct path (offline parser test against a saved list page):
#   tclsh9.0 pub-search-jobs.tcl <list-fragment.html>
#
# The source is the guest list fragment the public jobs page pages through
# (jobs-guest/jobs/api/seeMoreJobPostings/search). Its card classes are stable,
# where the signed-in search UI's are randomised and that UI offers no location
# control. A card carries no salary, work mode or closed marker; the posting
# fragment pub-parse-job reads carries the salary and the closed marker.

source [file join [file dirname [info script]] li-canonical.tcl]

set ::JOBS_LIST_BASE "https://www.linkedin.com/jobs-guest/jobs/api/seeMoreJobPostings/search"

# Caller-facing values -> LinkedIn's own query values.
set ::JOBS_POSTED    {day r86400 week r604800 month r2592000}
set ::JOBS_WORKPLACE {onsite 1 remote 2 hybrid 3}

# The caller's argument is a JSON object, or a bare string meaning keywords.
proc jobs_args {raw} {
    set raw [string trim $raw]
    if {$raw eq ""} { error "no search given: pass keywords, or a JSON object" }
    set a [dict create keywords "" location "" geoId "" posted "" workplace {} start 0 maxPages 10]
    if {[string index $raw 0] ne "\{"} {
        dict set a keywords $raw
        return $a
    }
    if {[catch {::json::json2dict $raw} in]} { error "arguments are not JSON: $in" }
    dict for {k v} $in {
        if {![dict exists $a $k]} {
            error "'$k' is not a job-search key (keywords, location, geoId, posted, workplace, start, maxPages)"
        }
        dict set a $k $v
    }
    set p [dict get $a posted]
    if {$p ne "" && ![dict exists $::JOBS_POSTED $p]} {
        error "posted must be one of: [dict keys $::JOBS_POSTED]"
    }
    foreach w [dict get $a workplace] {
        if {![dict exists $::JOBS_WORKPLACE $w]} {
            error "workplace takes a list of: [dict keys $::JOBS_WORKPLACE]"
        }
    }
    if {![string is integer -strict [dict get $a start]] || [dict get $a start] < 0} {
        error "start must be a non-negative integer"
    }
    if {![string is integer -strict [dict get $a maxPages]] || [dict get $a maxPages] < 1} {
        error "maxPages must be a positive integer"
    }
    if {[dict get $a keywords] eq "" && [dict get $a location] eq "" && [dict get $a geoId] eq ""} {
        error "no search given: keywords and location are both empty"
    }
    return $a
}

proc jobs_url {a start} {
    set pairs {}
    foreach k {keywords location geoId} {
        if {[dict get $a $k] ne ""} { lappend pairs "$k=[url_qcomp [dict get $a $k]]" }
    }
    if {[dict get $a posted] ne ""} {
        lappend pairs "f_TPR=[dict get $::JOBS_POSTED [dict get $a posted]]"
    }
    set wt {}
    foreach w [dict get $a workplace] { lappend wt [dict get $::JOBS_WORKPLACE $w] }
    if {[llength $wt]} { lappend pairs "f_WT=[join $wt %2C]" }
    lappend pairs "start=$start"
    return "$::JOBS_LIST_BASE?[join $pairs &]"
}

# The inner HTML of the element whose opening tag carries `marker`, up to the
# first `endTag`. Index slicing rather than a regex: in a Tcl regex the first
# quantifier sets the greediness of the whole expression, which let `.*?`
# run past the closing tag it was meant to stop at.
proc jobs_inner {html marker endTag} {
    set i [string first $marker $html]
    if {$i < 0} { return "" }
    set gt [string first ">" $html $i]
    set end [string first $endTag $html $gt]
    if {$gt < 0 || $end < 0} { return "" }
    return [string range $html [expr {$gt + 1}] [expr {$end - 1}]]
}

proc jobs_grab {html marker endTag} {
    return [html_text [jobs_inner $html $marker $endTag]]
}

# One list fragment -> a list of job dicts, in page order.
proc parse_job_cards {html} {
    set jobs {}
    foreach c [lrange [split [string map {<li> \x01} $html] \x01] 1 end] {
        if {![regexp {urn:li:jobPosting:(\d+)} $c -> id]} continue
        set company_url ""
        set sub [jobs_inner $c base-search-card__subtitle </h4>]
        if {[regexp {href="(https://[^"?]*/company/[^"?/]+)} $sub -> cu]} {
            set company_url "$cu/"
        }
        set posted_date ""
        regexp {(?is)<time[^>]*datetime="([0-9-]+)"} $c -> posted_date
        set flags {}
        set rest $c
        while {[set t [jobs_inner $rest job-posting-benefits__text </span>]] ne ""} {
            lappend flags [html_text $t]
            set rest [string range $rest [expr {[string first job-posting-benefits__text $rest] + 1}] end]
        }
        lappend jobs [dict create \
            job_id      $id \
            url         "https://www.linkedin.com/jobs/view/$id/" \
            title       [jobs_grab $c base-search-card__title </h3>] \
            company     [html_text $sub] \
            company_url $company_url \
            location    [jobs_grab $c job-search-card__location </span>] \
            posted      [jobs_grab $c "<time" </time>] \
            posted_date $posted_date \
            flags       $flags]
    }
    return $jobs
}

proc job_json {j} {
    set fl {}
    foreach f [dict get $j flags] { lappend fl [j_str $f] }
    return [json::write object \
        job_id      [j_str [dict get $j job_id]] \
        url         [j_str [dict get $j url]] \
        title       [j_str [dict get $j title]] \
        company     [j_str [dict get $j company]] \
        company_url [j_strornull [dict get $j company_url]] \
        location    [j_str [dict get $j location]] \
        posted      [j_strornull [dict get $j posted]] \
        posted_date [j_strornull [dict get $j posted_date]] \
        flags       [json::write array {*}$fl]]
}

# Page from `start` until a page brings no new job or maxPages is spent.
proc run_jobs {a} {
    set seen [dict create]
    set rows {}
    set start [dict get $a start]
    set pages 0
    set more 0
    while {1} {
        if {$pages >= [dict get $a maxPages]} { set more 1; break }
        nav [jobs_url $a $start] --wait 2
        if {[dict get [state] terminal] ne ""} {
            if {$pages == 0} { error "login_wall: terminal state '[dict get [state] terminal]'" }
            set more 1; break
        }
        incr pages
        set cards [parse_job_cards [dump]]
        set fresh 0
        foreach j $cards {
            set id [dict get $j job_id]
            if {[dict exists $seen $id]} continue
            dict set seen $id 1
            lappend rows [job_json $j]
            incr fresh
        }
        log "start=$start cards=[llength $cards] new=$fresh"
        if {$fresh == 0} break
        incr start [llength $cards]
    }

    set wp {}
    foreach w [dict get $a workplace] { lappend wp [j_str $w] }
    set result [json::write object \
        query [json::write object \
            keywords  [j_strornull [dict get $a keywords]] \
            location  [j_strornull [dict get $a location]] \
            geoId     [j_strornull [dict get $a geoId]] \
            posted    [j_strornull [dict get $a posted]] \
            workplace [json::write array {*}$wp]] \
        pages   $pages \
        count   [llength $rows] \
        results [json::write array {*}$rows]]
    set cursor [expr {$more ? $start : ""}]
    return [dict create result $result cursor $cursor hasMore $more]
}

proc serialiser_run {skillArgs} {
    if {[catch {run_jobs [jobs_args [lindex $skillArgs 0]]} r]} {
        emit [envelope_fault $r]
        return
    }
    emit [envelope_ok $r]
}

# Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts stderr "Usage: pub-search-jobs.tcl <list-fragment.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    set f [open [lindex $argv 0] r]; fconfigure $f -encoding utf-8
    set html [read $f]; close $f
    foreach j [parse_job_cards $html] { puts [job_json $j] }
}
