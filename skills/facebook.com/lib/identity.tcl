# The account facebook.com rendered this run's pages for, per SESSION-CONTRACT.md
# §4. c_user is Facebook's own name for it and sits in document.cookie, so
# naming the account costs no request. xs, the session secret, is httpOnly and is
# never touched here. Empty before the first navigation.
proc site_identity {} {
    if {[catch {eval {(document.cookie.match(/c_user=(\d+)/)||[])[1]||''}} v]} { return "" }
    return [string trim $v]
}
