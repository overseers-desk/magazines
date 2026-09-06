#!/usr/bin/env tclsh
# Parse a Facebook profile photos-tab into the image URLs behind it.
#
# Serialiser path: browser-serialiser facebook.com/auth-parse-photos <handle|profile-url>
#   navigates to the photos tab, dumps the rendered DOM, and runs the parse.
# Direct path (legacy, file-fed): tclsh auth-parse-photos.tcl <html-file>
#
# URL form: https://www.facebook.com/USERNAME/photos
#        or https://www.facebook.com/profile.php?id=NUMERIC_ID&sk=photos
#
# What it is for: a printed business card, a float or trade-vehicle decal, a
# name tag, signage or an awards plaque sits in a small business's gallery and
# carries the legal name, the ABN or an address that appears nowhere in the
# page's text. The parse ends at the URL. Reading what an image SHOWS is the
# caller's job, and needs a vision pass over the downloaded file: this runs in
# the harness's safe interpreter, which reaches no disk.
#
# Reference form matters. A Page reachable at /alice.starheart/photos answered,
# while the same Page's vanity username returned a generic shell with the title
# "Facebook" and no grid, so the reference is passed through as given rather
# than normalised to a username.
#
# Structural markers (class names are randomised and cannot be used):
#   - A grid tile links to /photo/?fbid=<id>.
#   - Image sources sit on the CDN under /v/t39.<n>-6/ for uploaded content and
#     /v/t39.<n>-1/ for profile pictures, the -6 set being the gallery itself.
#   - Signed CDN URLs carry their query string; it is kept, since the URL does
#     not fetch without it.

source [file join [file dirname [info script]] lib fb-common.tcl]

set ::PHOTO_LINK_RE {/photo/\?fbid=(\d+)}
set ::CDN_IMG_RE {https://scontent[^"\\]+}

# Parse from in-memory HTML, the single home for the extraction.
proc parse_photos_html {html} {
    set title [fb::title $html "NOT FOUND"]
    if {[fb::title_is_login $title]} {
        puts "ERROR: Facebook session expired. Log in via a Chrome-compatible browser first."
        exit 1
    }

    set name [fb::name_from_title $title]
    puts "Profile: $name"
    puts "HTML size: [fb::commafy [fb::cp_length $html]] bytes"

    # A photos tab that never resolved renders the signed-in shell, whose title
    # is the bare site name. Saying so beats reporting an empty gallery, which
    # reads as a profile with no photos.
    # The title arrives with an unread-count prefix, "(20+) Name", so the bare
    # site name has to be tested after that is taken off.
    set bare [string trim [regsub {^\(\d+\+?\)\s*} $name ""]]
    if {$bare eq "Facebook" || $bare eq ""} {
        puts ""
        puts "This did not land on a photos tab: the page title carries no profile name."
        puts "Check the reference. A Page may answer on one of its handles and not another."
        return
    }

    set fbids {}
    foreach {whole id} [regexp -all -inline -- $::PHOTO_LINK_RE $html] {
        if {$id ni $fbids} { lappend fbids $id }
    }

    # Dedupe on the path, since the same image recurs at several render sizes,
    # but report the full signed URL, which is what actually fetches.
    set seen {}
    set images {}
    foreach url [regexp -all -inline -- $::CDN_IMG_RE $html] {
        set url [string map {&amp; &} $url]
        set path [lindex [split $url ?] 0]
        if {[dict exists $seen $path]} { continue }
        dict set seen $path 1
        set kind [expr {[string match {*t39.*-1/*} $path] ? "profile" : "content"}]
        lappend images [list $kind $url]
    }

    if {![llength $fbids] && ![llength $images]} {
        puts ""
        puts "No photos found on the rendered page."
        puts "The gallery may be empty, or the DOM structure has changed."
        return
    }

    puts "Photo permalinks: [llength $fbids]"
    puts "Distinct images:  [llength $images]"
    puts "(Headless dumps do not scroll-load; the gallery may be longer.)"
    puts ""

    set i 0
    foreach id $fbids {
        incr i
        puts "=== PHOTO $i ==="
        puts "  Permalink: https://www.facebook.com/photo/?fbid=$id"
        puts ""
    }

    set i 0
    foreach entry $images {
        lassign $entry kind url
        incr i
        puts "=== IMAGE $i ($kind) ==="
        puts "  $url"
        puts ""
    }

    puts "--- End of photos-tab parse ---"
    puts "To read what an image shows, download it and view the file; the URL is signed and expires."
}

# Legacy file-fed entry: read the file, then run the shared parser.
proc parse_photos {html_path} {
    parse_photos_html [fb::read_file $html_path]
}

# Resolve a profile reference to its photos-tab URL.
proc fb_photos_url {ref} {
    if {[string match "http*://*" $ref]} { return $ref }
    if {[regexp {^\d+$} $ref]} {
        return "https://www.facebook.com/profile.php?id=$ref&sk=photos"
    }
    return "https://www.facebook.com/[string trimleft $ref @/]/photos"
}

# ---------------------------------------------------------------------------
# Serialiser entry: nav to the photos tab, dump the rendered DOM, run the
# identical parse under fb::capture, emit the report.
# ---------------------------------------------------------------------------
proc serialiser_run {skillArgs} {
    set target ""
    foreach a $skillArgs {
        if {[string match "--*" $a]} continue
        set target $a
        break
    }
    if {$target eq ""} {
        emit [envelope_fault "Usage: facebook.com/auth-parse-photos <handle|profile-url>"]
        return
    }
    nav [fb_photos_url $target] --wait 6
    if {[dict get [state] terminal] ne ""} {
        emit [envelope_fault "login_wall: Facebook session expired. Log in via a Chrome-compatible browser first."]
        return
    }
    set html [dump]
    emit [fb::report out { parse_photos_html $html }]
}

# Direct-tclsh entry (legacy, file-fed). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    if {[llength $argv] < 1} {
        puts "Usage: auth-parse-photos.tcl <photos-tab.html>"
        exit 1
    }
    fconfigure stdout -encoding utf-8
    parse_photos [lindex $argv 0]
}
