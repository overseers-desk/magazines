#!/usr/bin/env tclsh
# Parse a Facebook profile page for structured information.
#
# Serialiser path (see SKILL.md §3-4): browser-serialiser facebook.com/auth-parse-profile <handle|profile-url>
#   navigates to the profile, dumps the rendered DOM, and runs the identical parse.
# Direct path (legacy, file-fed): tclsh auth-parse-profile.tcl <html-file>
#
# Facebook's DOM uses randomised class names (e.g. x1lliihq x6ikm8r), so we
# cannot select by class. Instead we extract:
#   1. <title> tag — usually "Name | Facebook" or just "Name"
#   2. <meta name="description"> / <meta property="og:description"> — bio
#   3. Raw visible text — >content< patterns, framework noise filtered
#   4. JSON-LD Person data if present

source [file join [file dirname [info script]] lib fb-common.tcl]

# Parse from in-memory HTML, the single home for the byte-identical extraction.
# The legacy file path reads the file then calls this; the serialiser path dumps
# the DOM then calls this.
# $subpages is a list of {name html} pairs, the About sub-tabs the serialiser
# path fetched; $about says the page asked for was an About tab, so its data
# payload is expected and its absence is a fault rather than an empty page.
proc parse_profile_html {html {subpages {}} {about 0}} {
    set title [fb::title $html "NOT FOUND"]

    # No-session detection. "USER_ID"/"ACCOUNT_ID" of "0" is the reliable
    # marker (fires even behind a login wall on a public profile whose title
    # reads real); the login form or a login title back it up.
    set no_session [expr {
        [regexp {"(?:USER_ID|ACCOUNT_ID)":"0"} $html] ||
        [regexp {id="login_form"} $html] ||
        [fb::title_is_login $title]
    }]
    if {$no_session} {
        puts "ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."
        exit 1
    }

    # A reference the site has no page for renders the signed-in shell with
    # a bare title and an unavailable notice: a report of it would carry the
    # operator's notifications as the profile.
    set name [fb::name_from_title $title]
    if {[fb::page_absent $html]} {
        puts "ERROR: removed: Facebook has no page at this reference (the site answers \"This page isn't available\")"
        exit 1
    }

    puts "Name: $name"
    puts "HTML size: [fb::commafy [fb::cp_length $html]] bytes"

    # --- Meta descriptions ---
    foreach tag {description og:description og:title} {
        set te [re_escape $tag]
        set content ""
        if {[regexp -- "<meta\[^>\]*(?:name|property)=\"$te\"\[^>\]*content=\"(\[^\"\]*)\"" $html -> c]} {
            set content $c
        } elseif {[regexp -- "<meta\[^>\]*content=\"(\[^\"\]*)\"\[^>\]*(?:name|property)=\"$te\"" $html -> c]} {
            set content $c
        }
        if {$content ne ""} {
            # Decode the same five entities the Python decoded here.
            set content [string map {&amp; & &lt; < &gt; > &#39; ' &quot; \"} $content]
            puts ""
            puts "$tag: [string range $content 0 499]"
        }
    }

    # --- JSON-LD Person data ---
    foreach blob [capture_list $html {(?s)<script[^>]*type="application/ld\+json"[^>]*>((?:(?!</script>).)*)</script>}] {
        if {[catch {json::json2dict $blob} data]} { continue }
        # Only treat as Person when it is a JSON object with @type Person.
        if {[catch {dict get $data @type} atype]} { continue }
        if {$atype ne "Person"} { continue }
        puts ""
        puts "JSON-LD Person data found:"
        dict for {k v} $data {
            if {[string index $k 0] eq "@"} { continue }
            puts "  $k: $v"
        }
    }

    # --- About data: what the page hands its client rather than draws ---
    # The tab's values are not rendered text: the headings are drawn and the
    # values are handed to the client per sub-tab, so a visible-text read
    # reports "Contact info" with nothing under it. They are read from the
    # payload by key here, and a payload without the key is said so.
    if {$about && ![fb::about_fields_present $html]} {
        puts "ERROR: unrecognised: About tab without its profile_field_sections payload (page data shape changed?)"
        exit 1
    }
    set call [fb::call_number $html]
    set rows [fb::about_fields $html]
    if {$call ne "" || [llength $rows] || [llength $subpages]} {
        puts ""
        puts "About:"
        if {$call ne ""} { puts "  Call button: $call" }
        foreach r $rows { puts "  [about_line $r]" }
        foreach {sub subhtml} $subpages {
            if {![fb::about_fields_present $subhtml]} {
                puts "ERROR: unrecognised: $sub sub-tab without its profile_field_sections payload (page data shape changed?)"
                exit 1
            }
            set subrows [fb::about_fields $subhtml]
            if {![llength $subrows]} {
                puts "  $sub: none declared"
                continue
            }
            puts "  $sub:"
            foreach r $subrows { puts "    [about_line $r]" }
        }
        set fetched [dict keys $subpages]
        set others {}
        foreach {name url} [fb::about_subtabs $html] {
            if {$name ni $fetched} { lappend others "$name $url" }
        }
        if {[llength $others]} {
            puts "  Other sub-tabs, readable by passing the URL as the reference:"
            foreach o $others { puts "    $o" }
        }
    }

    # --- Visible text ---
    set texts [fb::extract_visible_texts [fb::main_region $html] 5 500 5]

    # --- Bio / Intro ---
    set bio_keywords {
        "Lives in" "From" "Works at" "Studied at" "Went to"
        "Married" "Single" "In a relationship" "Engaged"
        "Born on" "Joined Facebook"
        "Vive en" "De" "Trabaja en" "Estudió en"
    }
    set bio_texts [filter_contains_any $texts $bio_keywords]
    if {[llength $bio_texts]} {
        puts ""
        puts "Bio/Intro lines:"
        foreach t [lrange $bio_texts 0 9] { puts "  - $t" }
    }

    # --- Work / Role ---
    set role_keywords {
        " at " "Director" "Manager" "CEO" "Founder" "Chairman"
        "Partner" "Consultant" "Engineer" "Analyst" "President"
        "Owner" "Principal" "CTO" "COO" "CFO" "VP "
        "Vice President" "Head of"
    }
    set role_texts {}
    foreach t $texts {
        if {[string length $t] >= 200} { continue }
        if {[contains_any $t $role_keywords]} { lappend role_texts $t }
    }
    if {[llength $role_texts]} {
        puts ""
        puts "Role/Work mentions:"
        foreach t [lrange $role_texts 0 9] { puts "  - $t" }
    }

    # --- Location ---
    set loc_re {India|Mumbai|Delhi|Bangalore|Kolkata|Chennai|Hyderabad|Pune|Singapore|Australia|London|New York|Hong Kong|San Francisco|Los Angeles|Toronto|Berlin|Paris|Tokyo|Dubai}
    set location_texts {}
    foreach t $texts {
        if {[string length $t] >= 150} { continue }
        if {[regexp -- $loc_re $t]} { lappend location_texts $t }
    }
    if {[llength $location_texts]} {
        puts ""
        puts "Location mentions:"
        foreach t [lrange $location_texts 0 4] { puts "  - $t" }
    }

    # --- All meaningful text blocks ---
    puts ""
    puts "--- Visible text blocks ([llength $texts] extracted) ---"
    foreach t [lrange $texts 0 79] { puts "  $t" }

    puts ""
    puts "--- End of profile parse ---"
}

# One About field as a report line: "Section (qualifier): value".
proc about_line {row} {
    lassign $row section ftype value qual
    set label $section
    if {$qual ne "" && $qual ne $section} { append label " ($qual)" }
    return "$label: [string map {\n "; "} $value]"
}

# Quote a string for use as a literal inside a Tcl regexp.
proc re_escape {s} {
    return [regsub -all {[][\\^$.|?*+(){}]} $s {\\&}]
}

# Capture-group-1 values for every match of $pat in $text.
proc capture_list {text pat} {
    set out {}
    foreach {whole cap} [regexp -all -inline -- $pat $text] {
        lappend out $cap
    }
    return $out
}

# True when $t contains any of the literal substrings in $needles.
proc contains_any {t needles} {
    foreach kw $needles {
        if {[string first $kw $t] >= 0} { return 1 }
    }
    return 0
}

# Filter $items to those containing any of the literal substrings in $needles.
proc filter_contains_any {items needles} {
    set out {}
    foreach t $items {
        if {[contains_any $t $needles]} { lappend out $t }
    }
    return $out
}

# Legacy file-fed entry: read the file, then run the shared parser.
proc parse_profile {html_path} {
    parse_profile_html [fb::read_file $html_path]
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the profile, dump the rendered DOM, run the identical
# parse under fb::report, emit the captured report. A login wall caught by
# `state`; the parser's own no-session exit is the captured fallback.
#
# Invoked by reference through the serialiser (see SKILL.md §3-4):
#     browser-serialiser facebook.com/auth-parse-profile <handle|profile-url>
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set target ""
    foreach a $skillArgs {
        if {[string match "--*" $a]} continue
        set target $a
        break
    }
    if {$target eq ""} {
        emit [envelope_fault "Usage: facebook.com/auth-parse-profile <handle|profile-url>"]
        return
    }
    set landing [nav [fb::profile_url $target] --wait 5]
    if {[dict get [state] terminal] ne ""} {
        emit [envelope_fault "login_wall: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."]
        return
    }
    set html [dump]
    # An About tab's contact and ownership detail sits on its own sub-tabs;
    # the two that carry it are fetched, the rest are listed by URL.
    set about [regexp {/about(?:[/?#]|$)|[?&]sk=(?:about|directory_)} $landing]
    set subpages {}
    if {$about} {
        foreach {name url} [fb::about_subtabs $html] {
            if {$name ni {"Contact info" "Details"}} continue
            nav $url --wait 5
            if {[dict get [state] terminal] ne ""} {
                emit [envelope_fault "login_wall: Facebook: session lost while reading the $name sub-tab."]
                return
            }
            lappend subpages $name [dump]
        }
    }
    emit [fb::report out { parse_profile_html $html $subpages $about }]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts "Usage: auth-parse-profile.tcl <profile.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_profile [lindex $argv 0]
}
