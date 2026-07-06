# li-profile.tcl - the li-profile B-job playbook, run inside the serialiser harness.
# Home: skillbooks/skills/linkedin.com/li-profile.tcl
#
# A job-envelope profile-header read for the BL04 persist leg. parse-profile.tcl
# stays as-is for interactive YAML use; this verb reuses its extraction and emits
# the CANONICAL envelope the BI server's persist consumes.
#
# It sources parse-profile.tcl as a library (its DOM helpers - infer_headline,
# infer_location, extract_about, the Experience parse, current_company/title) and
# li-canonical.tcl (the JSON emitters and the envelope). The genuinely new
# extraction here, on top of what parse-profile already derives, is:
#   - the two count PAIRS: connections and followers. LinkedIn shows "500+" once a
#     member passes 500 connections and formats follower counts for display
#     ("1,234", "10K"), so each field keeps the verbatim token in _raw and a
#     best-effort parsed integer beside it (null when the count is absent/unparseable).
#   - current_title: the ongoing Experience entry's title (sibling of current_company).
#
# Args JSON: {profileUrn, slug}. slug may be a vanity or an ACoAA id; it drives the
# /in/<slug>/ navigation. profileUrn is a fallback identity when the page's own
# owner urn cannot be read. One page per run (a profile is not paged): cursor "",
# hasMore false, like contact-info.

source [file join [file dirname [info script]] parse-profile.tcl]
source [file join [file dirname [info script]] li-canonical.tcl]

# A display-formed count token -> its best-effort integer, or "" if unparseable.
# Handles thousands commas, the "500+" over-cap marker, and K/M/B display suffixes
# ("10K" -> 10000, "1.2M" -> 1200000). "" (the caller emits null) when it is not a
# number, so a parse miss never fabricates a count.
proc parse_count_token {raw} {
    set s [string map {, {} + {}} [string trim $raw]]
    if {[regexp -nocase {^([0-9]*\.?[0-9]+)([KMB]?)$} $s -> num suf]} {
        set mult 1
        switch -nocase -- $suf { K { set mult 1000 } M { set mult 1000000 } B { set mult 1000000000 } }
        return [expr {int(double($num) * $mult)}]
    }
    return ""
}

# Pull the connections and followers count pairs out of the topcard DOM. LinkedIn
# renders the number and its label in adjacent (often separate) obfuscated spans,
# so the match tolerates a few tags between the digits and the label word rather
# than assuming one text node - and the label word anchors it to the real count,
# not a stray number. Returns a dict {connection_raw connection_count follower_raw
# follower_count}, each "" when the count is not on the page. Best-effort: the exact
# topcard DOM is a live-verification item (see the Step-6 checklist).
proc extract_counts {html} {
    set h [string map {&nbsp; " "} $html]
    set connRaw ""; set connInt ""
    if {[regexp -nocase {([0-9][0-9,]*\+?)\s*(?:<[^>]*>\s*){0,3}connections?\y} $h -> raw]} {
        set connRaw [string trim $raw]; set connInt [parse_count_token $connRaw]
    }
    set folRaw ""; set folInt ""
    if {[regexp -nocase {([0-9][0-9.,]*[KMB]?)\s*(?:<[^>]*>\s*){0,3}followers?\y} $h -> raw]} {
        set folRaw [string trim $raw]; set folInt [parse_count_token $folRaw]
    }
    return [dict create connection_raw $connRaw connection_count $connInt \
                        follower_raw $folRaw follower_count $folInt]
}

# Assemble the CANONICAL profile-header result from the topcard HTML and the
# Experience-details HTML (the latter may be "" when Experience was not read, e.g.
# the direct self-test feeds one file for both). profileUrnArg is the caller's
# fallback identity. Returns the result JSON object.
proc render_li_profile {main_html exp_html profileUrnArg slug} {
    # name off the title, as parse-profile does.
    set name ""
    if {[regexp {(?s)<title[^>]*>(.*?)</title>} $main_html -> t]} {
        set title [string trim $t]
        if {[string first "| LinkedIn" $title] >= 0} {
            set name [string trim [string map {" | LinkedIn" ""} $title]]
        } else { set name $title }
    }

    # Identity from the haul (owner_urn dominates the page), caller's arg as fallback.
    set profileUrn [owner_urn $main_html]
    if {$profileUrn eq "" || $profileUrn eq "urn:li:fsd_profile:"} { set profileUrn $profileUrnArg }

    set texts [extract_visible_texts [strip_viewer_content $main_html]]
    set headline [infer_headline $texts $name]
    set location [infer_location $texts $name]
    set about [extract_about $main_html]

    # current_company / current_title from the ongoing Experience entry.
    set currentCompany ""; set currentTitle ""
    if {$exp_html ne ""} {
        set entries [parse_experience_entries [extract_experience_texts $exp_html]]
        set currentCompany [current_company_from_entries $entries]
        set currentTitle   [current_title_from_entries $entries]
    }

    set counts [extract_counts $main_html]

    return [json::write object \
        profile_urn      [j_strornull $profileUrn] \
        headline         [j_strornull $headline] \
        about            [j_strornull $about] \
        location         [j_strornull $location] \
        current_title    [j_strornull $currentTitle] \
        current_company  [j_strornull $currentCompany] \
        connection_count [j_intornull [dict get $counts connection_count]] \
        connection_raw   [j_strornull [dict get $counts connection_raw]] \
        follower_count   [j_intornull [dict get $counts follower_count]] \
        follower_raw     [j_strornull [dict get $counts follower_raw]]]
}

proc pb_li_profile {a} {
    set profileUrn [dict_get_or $a profileUrn ""]
    set slug [dict_get_or $a slug ""]
    if {$slug eq ""} { set slug [slug_from_arg $profileUrn] }
    if {$slug eq ""} { error "no slug or profileUrn given" }

    # 1. Topcard (carries headline, location, about, and the count pairs).
    nav "https://www.linkedin.com/in/$slug/" --wait 6
    if {[dict get [state] terminal] ne ""} { error "login_wall: profile view hit a wall" }
    set main_html [scroll_and_dump]

    # 2. Experience details (for current_title / current_company). A wall here just
    #    leaves those null; the header read already succeeded.
    set exp_html ""
    nav "https://www.linkedin.com/in/$slug/details/experience/" --wait 5
    if {[dict get [state] terminal] eq ""} { set exp_html [scroll_and_dump] }

    set result [render_li_profile $main_html $exp_html $profileUrn $slug]
    return [dict create result $result cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_li_profile $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}

# --- direct-tclsh entry (offline extraction self-test against a saved page) ---
# Feeds one HTML file as BOTH the topcard and the Experience source, so the count/
# header/current-title extraction can be exercised offline. Skipped when sourced as
# a serialiser skill (no argv0 match).
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    fconfigure stdout -encoding utf-8
    if {[llength $argv] < 1} {
        puts stderr "Usage: li-profile.tcl <profile.html> \[slug\]"
        exit 1
    }
    lassign $argv file slug
    set f [open $file r]; fconfigure $f -encoding utf-8; set html [read $f]; close $f
    puts [render_li_profile $html $html "" $slug]
}
