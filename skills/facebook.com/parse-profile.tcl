#!/usr/bin/env tclsh
# Parse a Facebook profile page for structured information.
#
# Serialiser path (see SKILL.md §3-4): browser-serialiser facebook.com/parse-profile <handle|profile-url>
#   navigates to the profile, dumps the rendered DOM, and runs the identical parse.
# Direct path (legacy, file-fed): tclsh parse-profile.tcl <html-file>
#
# Facebook's DOM uses randomised class names (e.g. x1lliihq x6ikm8r), so we
# cannot select by class. Instead we extract:
#   1. <title> tag — usually "Name | Facebook" or just "Name"
#   2. <meta name="description"> / <meta property="og:description"> — bio
#   3. Raw visible text — >content< patterns, framework noise filtered
#   4. JSON-LD Person data if present

source [file dirname [info script]]/fb-common.tcl

# Parse from in-memory HTML, the single home for the byte-identical extraction.
# The legacy file path reads the file then calls this; the serialiser path dumps
# the DOM then calls this.
proc parse_profile_html {html} {
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

    set name [fb::name_from_title $title]

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

    # --- Visible text ---
    set texts [fb::extract_visible_texts $html 5 500 5]

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

# Resolve a profile reference (handle, numeric id, or full URL) to a URL.
proc fb_profile_url {ref} {
    if {[string match "http*://*" $ref]} { return $ref }
    if {[regexp {^\d+$} $ref]} {
        return "https://www.facebook.com/profile.php?id=$ref"
    }
    return "https://www.facebook.com/[string trimleft $ref @/]"
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the profile, dump the rendered DOM, run the identical
# parse under fb::capture, emit the captured report. A login wall caught by
# `state`; the parser's own no-session exit is the captured fallback.
#
# Invoked by reference through the serialiser (see SKILL.md §3-4):
#     browser-serialiser facebook.com/parse-profile <handle|profile-url>
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set target ""
    foreach a $skillArgs {
        if {[string match "--*" $a]} continue
        set target $a
        break
    }
    if {$target eq ""} {
        emit "Usage: facebook.com/parse-profile <handle|profile-url>"
        return
    }
    nav [fb_profile_url $target] --wait 5
    if {[dict get [state] terminal] ne ""} {
        emit "ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."
        return
    }
    set html [dump]
    emit [fb::capture out { parse_profile_html $html }]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] != 1} {
        puts "Usage: parse-profile.tcl <profile.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_profile [lindex $argv 0]
}
