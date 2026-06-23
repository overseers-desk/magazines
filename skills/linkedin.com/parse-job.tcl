#!/usr/bin/env tclsh
# Parse a LinkedIn job posting into a structured YAML record.
#
# Serialiser path (see SKILL.md):
#   browser-serialiser linkedin.com/parse-job <job-id-or-url>
#     navigates to the guest job-posting fragment
#     (jobs-guest/jobs/api/jobPosting/<id>), dumps it, and reads its stable
#     class names. The guest fragment carries the FULL description untruncated,
#     so it sidesteps both the "… more" UI fold and the logged-in SPA's
#     randomised class names. Falls back to JobPosting JSON-LD (present on a
#     logged-out full job page) and then to the og:/<title> meta tags.
# Direct path (file-fed, for testing): tclsh parse-job.tcl <html-file> [job-id]
#
# LinkedIn's logged-in DOM uses randomised class names; the guest fragment's
# classes, the ld+json block, and the <title>/<meta> tags are the stable anchors.

package require json

# A direct-tclsh run has no `log` verb (the serialiser injects it as an alias
# before sourcing). Define a stderr fallback only when it is absent.
if {![llength [info commands log]]} {
    proc log {msg} { catch {puts stderr "  \[skill\] $msg"} }
}

# ---- text helpers --------------------------------------------------------

# Decode the HTML entities that appear in the fragment, og: meta, and JSON-LD.
# The named-entity literals must be quoted: a bare "&amp;" inside [list ... ]
# would let its ";" act as a command separator within the [...] substitution.
proc job_html_unescape {s} {
    set s [string map [list \
        "&amp;" "&" "&lt;" "<" "&gt;" ">" "&quot;" "\"" "&#39;" "'" "&apos;" "'" \
        "&nbsp;" " " "&#160;" " " "&mdash;" "—" "&ndash;" "–" "&hellip;" "…"] $s]
    foreach ent [lsort -unique [regexp -all -inline {&#x?[0-9A-Fa-f]+;} $s]] {
        if {[regexp {&#(x?)([0-9A-Fa-f]+);} $ent -> hx digits]} {
            if {$hx eq "x"} { set n [scan $digits %x] } else { set n $digits }
            catch {set s [string map [list $ent [format %c $n]] $s]}
        }
    }
    return $s
}

# Strip tags, decode entities, collapse whitespace -- for single-line fields.
proc job_clean {frag} {
    regsub -all {<[^>]+>} $frag "" frag
    set frag [job_html_unescape $frag]
    regsub -all {\s+} $frag " " frag
    return [string trim $frag]
}

# First capture group of $re in $html, cleaned; "" if no match.
proc job_grab {html re} {
    if {[regexp $re $html -> m]} { return [job_clean $m] }
    return ""
}

# Convert a description (HTML fragment) to readable plain text: block tags
# become line breaks, list items become "- " bullets, the rest is stripped.
proc job_desc_to_text {html} {
    set t $html
    regsub -all {(?i)<br\s*/?>} $t "\n" t
    regsub -all {(?i)<li[^>]*>} $t "\n- " t
    regsub -all {(?i)</(p|div|ul|ol|li|h[1-6]|tr|section)>} $t "\n" t
    regsub -all {(?i)<(p|div|ul|ol|h[1-6]|section)[^>]*>} $t "\n" t
    regsub -all {<[^>]+>} $t "" t
    set t [job_html_unescape $t]
    regsub -all {[ \t]+\n} $t "\n" t
    regsub -all {\n{3,}} $t "\n\n" t
    return [string trim $t]
}

# Safe dict accessor: "" when the key is absent or $d is not a usable dict.
proc job_get {d key} {
    if {[catch {dict get $d $key} v]} { return "" }
    return $v
}

# The job-criteria list (Seniority level, Employment type, Job function,
# Industries) -> a head->value dict. Empty when the fragment lacks the list.
proc job_criteria {html} {
    set heads {}
    foreach {f s} [regexp -all -inline \
            {(?is)description__job-criteria-subheader[^>]*?>(.*?)</h3>} $html] {
        lappend heads [job_clean $s]
    }
    set vals {}
    foreach {f s} [regexp -all -inline \
            {(?is)description__job-criteria-text[^>]*?>(.*?)</span>} $html] {
        lappend vals [job_clean $s]
    }
    set d [dict create]
    foreach h $heads v $vals { dict set d $h $v }
    return $d
}

# ---- JSON-LD fallback (logged-out full job page) -------------------------

proc job_node_is_jobposting {node} {
    if {[catch {dict get $node @type} ty]} { return 0 }
    foreach t $ty { if {[string equal -nocase $t JobPosting]} { return 1 } }
    return 0
}

proc job_find_jobposting {html} {
    foreach {full body} [regexp -all -inline \
            {(?is)<script[^>]*?type=["']application/ld\+json["'][^>]*?>(.*?)</script>} $html] {
        set body [string trim $body]
        if {$body eq ""} continue
        if {[catch {json::json2dict $body} data]} continue
        if {[job_node_is_jobposting $data]} { return $data }
        if {![catch {dict get $data @graph} graph]} {
            foreach node $graph { if {[job_node_is_jobposting $node]} { return $node } }
        }
        foreach node $data { if {[job_node_is_jobposting $node]} { return $node } }
    }
    return {}
}

proc job_one_location {loc} {
    if {[catch {dict get $loc address} addr]} { return "" }
    if {$addr eq ""} { return "" }
    set parts {}
    foreach k {addressLocality addressRegion addressCountry} {
        if {![catch {dict get $addr $k} v] && $v ne ""} { lappend parts $v }
    }
    return [join $parts ", "]
}

proc job_locations {jl} {
    if {$jl eq ""} { return "" }
    set locs {}
    if {![catch {dict get $jl address}]} {
        set s [job_one_location $jl]
        if {$s ne ""} { lappend locs $s }
    } else {
        foreach l $jl {
            set s [job_one_location $l]
            if {$s ne ""} { lappend locs $s }
        }
    }
    return [join $locs " | "]
}

# Read a <meta property="PROP" content="..."> value, either attribute order.
proc job_meta {html prop} {
    set p [string map {. \\.} $prop]
    if {[regexp -nocase "<meta\[^>]*property=\[\"']$p\[\"']\[^>]*content=\[\"'](\[^\"']*)" $html -> v]} {
        return [job_html_unescape $v]
    }
    if {[regexp -nocase "<meta\[^>]*content=\[\"'](\[^\"']*)\[\"']\[^>]*property=\[\"']$p\[\"']" $html -> v]} {
        return [job_html_unescape $v]
    }
    return ""
}

# ---- YAML emission (self-contained; no dependency on parse-profile) -------

# A double-quoted YAML scalar for single-line values (escapes \, ", and breaks).
proc job_yaml_dq {s} {
    set s [string map [list \\ {\\} \" {\"} \n {\n} \r {} \t {\t}] $s]
    return "\"$s\""
}

# A literal block scalar (key: |) for multi-line text. Each content line is
# indented two spaces; empty lines stay empty (they do not close the block).
proc job_yaml_block {key text} {
    set out "$key: |"
    foreach line [split $text "\n"] {
        if {$line eq ""} { append out "\n" } else { append out "\n  $line" }
    }
    return $out
}

# ---- the parse -----------------------------------------------------------

# Build the YAML report from a dumped DOM. Returns "@@LOGIN@@" on a sign-in wall.
proc render_job {html jobId url} {
    set title_tag ""
    if {[regexp {(?is)<title[^>]*?>(.*?)</title>} $html -> t]} {
        set title_tag [job_clean $t]
    }
    set tl [string tolower $title_tag]
    foreach m {"sign in" "log in" "iniciar sesi" "join linkedin to" "sign up"} {
        if {[string first $m $tl] >= 0} { return "@@LOGIN@@" }
    }

    # Primary: the guest job-posting fragment (stable class names).
    set title    [job_grab $html {(?is)topcard__title[^>]*?>(.*?)</h}]
    set company  [job_grab $html {(?is)topcard__org-name-link[^>]*?>(.*?)</a>}]
    set location [job_grab $html {(?is)topcard__flavor--bullet[^>]*?>(.*?)</span>}]
    set posted   [job_grab $html {(?is)posted-time-ago__text[^>]*?>(.*?)</span>}]
    set desc ""
    if {[regexp {(?is)show-more-less-html__markup[^>]*?>(.*?)</div>} $html -> raw]} {
        set desc [job_desc_to_text $raw]
    }
    set criteria [job_criteria $html]
    set src "guest"

    # Fallback 1: JobPosting JSON-LD (present on a logged-out full job page).
    if {$title eq "" && $desc eq ""} {
        set jp [job_find_jobposting $html]
        if {[llength $jp]} {
            set src "json-ld"
            set title [job_get $jp title]
            set desc  [job_desc_to_text [job_get $jp description]]
            set org [job_get $jp hiringOrganization]
            if {$org ne ""} { if {[catch {dict get $org name} company]} { set company $org } }
            set location [job_locations [job_get $jp jobLocation]]
            set posted [job_get $jp datePosted]
            if {[dict size $criteria] == 0} {
                set et [join [job_get $jp employmentType] ", "]
                if {$et ne ""} { dict set criteria "Employment type" $et }
            }
        }
    }
    # Fallback 2: og: meta tags.
    if {$title eq "" && $desc eq ""} {
        set src "og-meta"
        set ogt [job_meta $html og:title]
        set desc [job_meta $html og:description]
        if {![regexp {^(.*?) hiring (.*?) in (.*?)(?: \| LinkedIn)?$} $ogt -> company title location]} {
            set title $ogt
        }
    }
    if {$title eq ""} { set title $title_tag }

    set seniority  [job_get $criteria "Seniority level"]
    set employment [job_get $criteria "Employment type"]
    set jobfunc    [job_get $criteria "Job function"]
    set industries [job_get $criteria "Industries"]

    log "source=$src title=[string range $title 0 70] desc_chars=[string length $desc]"

    set out {}
    lappend out "# LinkedIn job $jobId (source: $src)"
    lappend out "job_id: [job_yaml_dq $jobId]"
    lappend out "url: [job_yaml_dq $url]"
    lappend out "title: [job_yaml_dq $title]"
    lappend out "company: [job_yaml_dq $company]"
    lappend out "location: [job_yaml_dq $location]"
    if {$posted ne ""}     { lappend out "posted: [job_yaml_dq $posted]" }
    if {$seniority ne ""}  { lappend out "seniority: [job_yaml_dq $seniority]" }
    if {$employment ne ""} { lappend out "employment_type: [job_yaml_dq $employment]" }
    if {$jobfunc ne ""}    { lappend out "job_function: [job_yaml_dq $jobfunc]" }
    if {$industries ne ""} { lappend out "industries: [job_yaml_dq $industries]" }
    if {$desc eq ""} {
        lappend out "description: \"\""
    } else {
        lappend out [job_yaml_block description $desc]
    }
    return [join $out "\n"]
}

# Accept a bare job id, a /jobs/view/<id> URL, or a ?currentJobId=<id> URL.
proc job_id_from_arg {arg} {
    foreach re {{/jobs/view/(\d+)} {currentJobId=(\d+)} {jobPosting/(\d+)} {^(\d+)$} {(\d{5,})}} {
        if {[regexp $re $arg -> id]} { return $id }
    }
    return ""
}

# ---- serialiser entry ----------------------------------------------------

proc serialiser_run {skillArgs} {
    set arg [lindex $skillArgs 0]
    if {$arg eq ""} {
        emit "Usage: linkedin.com/parse-job <job-id-or-url>"
        return
    }
    set jobId [job_id_from_arg $arg]
    if {$jobId eq ""} {
        emit "ERROR: could not find a job id in '$arg'"
        return
    }
    set guest "https://www.linkedin.com/jobs-guest/jobs/api/jobPosting/$jobId"
    set view  "https://www.linkedin.com/jobs/view/$jobId/"
    nav $guest --wait 6
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: terminal state '[dict get [state] terminal]'. Run linkedin.com/login first."
        return
    }
    set report [render_job [dump] $jobId $view]
    if {$report eq "@@LOGIN@@"} {
        emit "ERROR: LinkedIn session expired. Run linkedin.com/login first."
        return
    }
    emit $report
}

# ---- direct-tclsh entry (file-fed; skipped when sourced as a skill) -------

if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    if {[llength $argv] < 1} {
        puts "Usage: parse-job.tcl <html-file> \[job-id\]"
        exit 1
    }
    set f [open [lindex $argv 0] r]
    fconfigure $f -encoding utf-8
    set html [read $f]
    close $f
    set jobId [expr {[llength $argv] > 1 ? [lindex $argv 1] : "unknown"}]
    set report [render_job $html $jobId "https://www.linkedin.com/jobs/view/$jobId/"]
    if {$report eq "@@LOGIN@@"} {
        puts "ERROR: LinkedIn session expired or sign-in wall."
        exit 1
    }
    puts $report
}
