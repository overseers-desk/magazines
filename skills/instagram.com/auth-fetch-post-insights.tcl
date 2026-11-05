#!/usr/bin/env tclsh
# The owner's insights for posts and reels: follows gained, profile visits,
# views, viewers, interactions, read from the page instagram.com opens at
# "View insights", /insights/media/<media_id>/.
#
#     browser-serialiser instagram.com/auth-fetch-post-insights insights <ref>[,<ref>...]
#
# A ref is a shortcode, a permalink, a post_id (<media_id>_<user_id>) or a media id.

source [file join [file dirname [info script]] lib fetch-recent-posts.tcl]

# Output field <- the metric in the page's own query (data.media). Each was
# matched against the label the page prints beside it (2026-11-05).
set ::INSIGHT_FIELDS {
    follows          umapi_follows_from_impressions_count
    profile_visits   umapi_profile_views_from_impressions_count
    views            umapi_unified_total_content_views_count
    viewers          umapi_content_meta_viewers_count
    interactions     umapi_total_interactions_count
    accounts_engaged umapi_engaged_accounts
    likes            umapi_likes_count
    comments         umapi_comments_count
    saves            umapi_saves_count
    shares           umapi_reshares_count
    facebook_views   umapi_ig_posts_ccp_fb_views_count
}

# The data.media object for $media_id among captured triples, or {}.
proc insights_media {captured media_id} {
    foreach r $captured {
        set body [lindex $r 2]
        if {[string first umapi_ $body] < 0} continue
        if {[catch {json::json2dict $body} d]} continue
        set m [ig::dget [ig::dget $d data {}] media {}]
        if {[ig::dget $m instagram_media_id ""] eq $media_id} { return $m }
    }
    return {}
}

# A metric's total. The page prints 0 where the metric's result list is empty
# (Follows on a photo nobody followed from), so empty is 0; an absent metric
# is null.
proc metric_node {m key} {
    if {![dict exists $m $key]} { return [ig::n_null] }
    set results [ig::dget [ig::dget [dict get $m $key] value {}] results {}]
    if {![llength $results]} { return [ig::n_int 0] }
    return [ig::count_node [ig::dget [lindex $results 0] total_value null]]
}

proc serialiser_run {skillArgs} {
    set usage "Usage: instagram.com/auth-fetch-post-insights insights <shortcode|permalink|media_id>\[,...\]"
    if {[lindex $skillArgs 0] ne "insights" || [llength $skillArgs] < 2} { emit [envelope_fault $usage]; return }
    set refs {}
    foreach a [lrange $skillArgs 1 end] {
        foreach r [split $a ,] { if {[string trim $r] ne ""} { lappend refs [string trim $r] } }
    }

    nav "https://www.instagram.com/" --wait 3
    if {[dict get [state] terminal] ne ""} {
        emit [envelope_fault "login_wall: Not logged in to Instagram ([dict get [state] terminal])."]
        return
    }

    set rows {}
    set skipped {}
    foreach ref $refs {
        if {[catch {ig::resolve_post_ref $ref} mid]} {
            lappend skipped [ig::n_obj [list ref [ig::n_str $ref] reason [ig::n_str $mid]]]
            continue
        }
        set cap [capture "https://www.instagram.com/insights/media/$mid/" --seconds 8 --match {*graphql*}]
        set m [insights_media $cap $mid]
        if {![llength $m]} {
            dwell 4
            set m [insights_media [harvest --match {*graphql*}] $mid]
        }
        if {![llength $m]} {
            # Instagram answers "this page isn't available" when the signed-in
            # account does not own the post.
            lappend skipped [ig::n_obj [list ref [ig::n_str $ref] media_id [ig::n_str $mid] \
                reason [ig::n_str "no insights for this account: the signed-in account must own the post"]]]
            continue
        }
        set pairs [list ref [ig::n_str $ref] media_id [ig::n_str $mid]]
        foreach {field key} $::INSIGHT_FIELDS { lappend pairs $field [metric_node $m $key] }
        lappend rows [ig::n_obj $pairs]
    }
    emit [envelope_ok [dict create result [ig::jenc [ig::n_obj [list \
        posts [ig::n_arr $rows] skipped [ig::n_arr $skipped]]]]]]
}
