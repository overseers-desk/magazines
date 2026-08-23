# The member linkedin.com rendered this run's pages for, per SESSION-CONTRACT.md
# §4. LinkedIn has no cookie naming the member, so this is the one voyager read
# that does: /voyager/api/me, whose body carries the member's own fsd_profile
# urn. The envelope calls this once per run and remembers the answer, so a run
# pays for it once however many times it emits.
proc site_identity {} {
    if {[catch {api GET /voyager/api/me} body]} { return "" }
    if {[regexp {urn:li:fsd_profile:([A-Za-z0-9_-]+)} $body -> id]} { return $id }
    return ""
}
