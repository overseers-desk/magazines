#!/usr/bin/env tclsh
# Read the accredited riding centres out of the JustGo Coach and Club Finder.
#
# Usage:
#     browser-serialiser justgo.com/pub-find-riding-centres
#
# The weblet renders nothing useful into its first DOM: results arrive as POST
# replies to WidgetService.mvc/ExecuteWidgetCommandAlt, so the run captures
# those bodies rather than scraping the page. Filed under justgo.com rather
# than the pony club's own domain that embeds it (SKILL.md).
#
# Public: no login, and no account to name.

proc serialiser_run {skillArgs} {
    set triples [capture "https://PCA.JustGo.com/weblets/CoachAndClubFinder/96528f3b-1e94-44fc-8217-e70f15954445/" \
        --seconds 45 --match "*ExecuteWidgetCommandAlt*"]
    set replies {}
    foreach t $triples {
        lassign $t url status body
        lappend replies [json::write object \
            url [json::write string $url] \
            status [json::write string $status] \
            body [json::write string $body]]
    }
    emit [envelope_ok [dict create result [json::write array {*}$replies]]]
}
