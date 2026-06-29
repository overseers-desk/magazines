# contact-info.tcl - the contact-info read verb, run inside the serialiser harness.
# Home: overseer-toolbox/skills/linkedin.com/contact-info.tcl
#
# Reads a member's self-listed Contact info (email, phones, websites, twitter,
# birthday) - the data LinkedIn's "Contact info" modal shows. The modal does not
# mount in a headless session, so the DOM is empty; instead this fetches the
# voyager GraphQL query the modal itself issues (profile-contact-info-finder),
# keyed by memberIdentity, and parses the privileged fields from the normalized
# {data, included} envelope. The same in-page-fetch pattern as li-inbox/li-thread.
#
# Email (and phone) are present only for members who have shared them with you
# (usually 1st-degree). When a member has not shared an email, the result carries
# the profile URL with an empty emails list and email_shared:false - a fetched
# empty, never silent success.

source [file join [file dirname [info script]] li-canonical.tcl]

# The profile-contact-info-finder query. LinkedIn ROTATES these hashes; the verb
# has no live-discovery path here (the modal that would issue it does not mount
# headless), so this id is the single source. Refresh by opening any profile's
# Contact info modal in DevTools and reading the voyagerIdentityDashProfiles
# request whose queryName is "profile-contact-info-finder".
set ::LI_CONTACT_QUERY voyagerIdentityDashProfiles.c7452e58fa37646d09dae4920fc5b4b9

# A profile slug from a vanity, an ACoAA fsd_profile id, or a full /in/<slug>/ URL.
# The voyager memberIdentity argument accepts the public slug and the ACoAA id
# alike, so the only normalisation is to strip a URL down to its /in/ token.
proc contact_member_token {arg} {
    if {[regexp {/in/([^/?#]+)} $arg -> slug]} { return $slug }
    return [string trim $arg]
}

# The Profile entity ($type ...identity.profile.Profile) out of the included list.
proc contact_profile_entity {body} {
    set d [::json::json2dict $body]
    foreach e [dict_get_or $d included {}] {
        if {[dstr $e {$type}] eq "com.linkedin.voyager.dash.identity.profile.Profile"} { return $e }
    }
    return ""
}

# One Profile entity -> the canonical contact result JSON.
proc parse_contact {prof} {
    set slug [dstr $prof publicIdentifier]
    set profileUrl [expr {$slug eq "" ? "" : "https://www.linkedin.com/in/$slug/"}]
    set name [string trim "[dstr $prof firstName] [dstr $prof lastName]"]

    # email: a single {emailAddress:...} object, or null. Modelled as a list so a
    # caller reads emails uniformly; email_shared is the explicit fetched-empty flag.
    set emails {}
    set ea [dict_get_or $prof emailAddress ""]
    if {$ea ne "" && $ea ne "null"} {
        set addr [dstr $ea emailAddress]
        if {$addr ne ""} { lappend emails [j_str $addr] }
    }
    set emailShared [expr {[llength $emails] > 0}]

    # phones: [{type, number}]
    set phones {}
    foreach p [dict_get_or $prof phoneNumbers {}] {
        set num [dstr [dict_get_or $p phoneNumber {}] number]
        if {$num eq ""} { continue }
        lappend phones [json::write object \
            number [j_str $num] \
            type   [j_strornull [dstr $p type]]]
    }

    # twitter: handle names
    set twitter {}
    foreach t [dict_get_or $prof twitterHandles {}] {
        set nm [dstr $t name]
        if {$nm ne ""} { lappend twitter [j_str $nm] }
    }

    # websites: [{url, label, category}]
    set websites {}
    foreach w [dict_get_or $prof websites {}] {
        set u [dstr $w url]
        if {$u eq ""} { continue }
        lappend websites [json::write object \
            url      [j_str $u] \
            label    [j_strornull [dstr $w label]] \
            category [j_strornull [dstr $w category]]]
    }

    # birthday: {month, day} (LinkedIn exposes no year) -> "MM-DD", or null.
    set birthday ""
    set b [dict_get_or $prof birthDateOn ""]
    if {$b ne "" && $b ne "null"} {
        set mo [dstr $b month]; set da [dstr $b day]
        if {$mo ne "" && $da ne ""} { set birthday [format %02d-%02d $mo $da] }
    }

    return [json::write object \
        profile_url  [j_strornull $profileUrl] \
        member       [j_strornull $slug] \
        name         [j_strornull $name] \
        email_shared [j_bool $emailShared] \
        emails       [json::write array {*}$emails] \
        phones       [json::write array {*}$phones] \
        twitter      [json::write array {*}$twitter] \
        websites     [json::write array {*}$websites] \
        birthday     [j_strornull $birthday]]
}

proc pb_contact_info {a} {
    set token [contact_member_token $a]
    if {$token eq ""} { error "no vanity/profile id given" }
    # View the profile first: establishes a same-origin page for the in-page fetch
    # (the verb is view-before-fetch like its siblings) and walls if logged out.
    nav "https://www.linkedin.com/in/$token/"
    if {[dict get [state] terminal] ne ""} { error "login_wall: profile view hit a wall" }
    set url "https://www.linkedin.com/voyager/api/graphql?includeWebMetadata=true&variables=(memberIdentity:[url_qcomp $token])&queryId=$::LI_CONTACT_QUERY"
    set body [fetch_voyager $url]
    set prof [contact_profile_entity $body]
    if {$prof eq ""} { error "no profile found for '$token' (bad vanity, or query id rotated)" }
    return [dict create result [parse_contact $prof] cursor "" hasMore 0]
}

proc serialiser_run {skillArgs} {
    set a [expr {[llength $skillArgs] ? [lindex $skillArgs 0] : {}}]
    if {[catch {pb_contact_info $a} r]} { emit [envelope_fault $r]; return }
    emit [envelope_ok $r]
}
