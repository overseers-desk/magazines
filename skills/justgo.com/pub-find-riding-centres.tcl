#!/usr/bin/env tclsh
# Read the accredited riding centres out of the JustGo Coach and Club Finder.
#
# Usage:
#     browser-serialiser justgo.com/pub-find-riding-centres
#
# Pony Club Australia's "Find An Accredited Riding Centre" page embeds this
# weblet, so the centres are JustGo's data on a JustGo origin. A skill filed
# under the pony club's own domain is leased that domain and is refused the
# moment the capture lands here, which is why this one is filed by the host it
# actually reads.
#
# The weblet renders nothing useful into its first DOM: results arrive as POST
# replies to WidgetService.mvc/ExecuteWidgetCommandAlt, so the run captures
# those bodies rather than scraping the page.
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
