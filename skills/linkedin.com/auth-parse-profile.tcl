#!/usr/bin/env tclsh
# Parse a LinkedIn profile page into a structured YAML record.
#
# Serialiser path: browser-serialiser linkedin.com/auth-parse-profile <slug-or-url> [--quick]
# Direct-tclsh path: auth-parse-profile.tcl <profile.html> [profile-url-or-slug]

source [file join [file dirname [info script]] lib parse-profile.tcl]

proc serialiser_run {skillArgs} {
    set quick 0
    set arg ""
    foreach a $skillArgs {
        if {$a eq "--quick"} { set quick 1; continue }
        # --experience is accepted as a no-op alias: the default now fetches it.
        if {$a eq "--experience" || $a eq "--full"} { continue }
        if {$arg eq ""} { set arg $a }
    }
    if {$arg eq ""} {
        emit [envelope_fault "usage: linkedin.com/auth-parse-profile <slug-or-url> \[--quick\]"]
        return
    }
    set slug [slug_from_arg $arg]
    if {$slug eq ""} {
        emit [envelope_fault "could not derive a profile slug from '$arg'"]
        return
    }

    # 1. Topcard (always).
    nav "https://www.linkedin.com/in/$slug/" --wait 6
    if {[dict get [state] terminal] ne ""} {
        emit [envelope_fault "login_wall: LinkedIn session expired. Log in via a Chrome-compatible browser first."]
        return
    }
    set main_html [scroll_and_dump]
    set record [render_profile $main_html $arg]
    if {$record eq "@@LOGIN@@"} {
        emit [envelope_fault "login_wall: LinkedIn session expired. Log in via a Chrome-compatible browser first."]
        return
    }
    set cov [dict create topcard fetched experience not_fetched \
        skills not_fetched about not_fetched]
    # Owner name (for filtering it out of the skills chrome), from the title.
    set pname ""
    if {[regexp {(?s)<title[^>]*>(.*?)</title>} $main_html -> _t]} {
        set pname [string trim [string map {" | LinkedIn" ""} [string trim $_t]]]
    }

    # --quick: header only. current_company is honest -- the headline rarely
    # carries it, and Experience was not read, so it is not_fetched, never null.
    if {$quick} {
        append record "\ncurrent_company: not_fetched"
        append record "\n[render_coverage $cov]"
        emit [envelope_ok [dict create result [json::write string $record]]]
        return
    }

    # 2. Experience details (default).
    set entries {}
    nav "https://www.linkedin.com/in/$slug/details/experience/" --wait 5
    if {[dict get [state] terminal] eq ""} {
        set entries [parse_experience_entries [extract_experience_texts [scroll_and_dump]]]
        dict set cov experience fetched
    }

    # 3. Skills details (default).
    set skills {}
    nav "https://www.linkedin.com/in/$slug/details/skills/" --wait 5
    if {[dict get [state] terminal] eq ""} {
        set skills [extract_skills [scroll_and_dump] $pname]
        dict set cov skills fetched
    }

    # 4. About: best-effort from the (already scrolled) main page.
    set about [extract_about $main_html]
    if {$about ne ""} { dict set cov about fetched } else { dict set cov about not_found }

    # current_company is now grounded: the ongoing position's company when
    # Experience was read, else null (a real "no current role" once read).
    if {[dict get $cov experience] eq "fetched"} {
        set cc [current_company_from_entries $entries]
        append record "\ncurrent_company: [emit_or_null $cc]"
    } else {
        append record "\ncurrent_company: not_fetched"
    }
    append record "\n[render_experience_entries $entries]"
    append record "\n[render_skills_block $skills]"
    append record "\nabout: [emit_or_null $about]"
    append record "\n[render_coverage $cov]"
    emit [envelope_ok [dict create result [json::write string $record]]]
}

# Direct-tclsh entry: an HTML path and optional url/slug. Skipped when sourced as
# a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 1} {
        puts stderr "Usage: auth-parse-profile.tcl <profile.html> \[profile-url-or-slug\]"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_profile [lindex $argv 0] [expr {[llength $argv] > 1 ? [lindex $argv 1] : ""}]
}
