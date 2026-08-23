# The account instagram.com rendered this run's pages for, per SESSION-CONTRACT.md
# §4. ds_user_id is Instagram's own name for it and sits in document.cookie, so
# naming the account costs no request. Empty before the first navigation.
proc site_identity {} {
    if {[catch {eval {(document.cookie.match(/ds_user_id=(\d+)/)||[])[1]||''}} v]} { return "" }
    return [string trim $v]
}
