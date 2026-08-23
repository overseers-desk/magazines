# The member linkedin.com rendered this run's pages for, per SESSION-CONTRACT.md
# §4. LinkedIn has no cookie naming the member, so the only source is
# /voyager/api/me, and it is read the way every LinkedIn skill here reads
# voyager: an in-page fetch carrying the JSESSIONID as the csrf-token header,
# which is the header LinkedIn's own pages send. The policed `api` verb sends
# X-CSRFToken instead and earns a 403.
#
# Everything is swallowed. A run that cannot name its member reports nobody and
# carries on; a failed identity read is not a reason to fail the work.
proc site_identity {} {
    set js {
      (async () => {
        try {
          const j=(document.cookie.match(/JSESSIONID="?([^";]+)"?/)||[])[1]||'';
          if (!j) return '';
          const r=await fetch('https://www.linkedin.com/voyager/api/me',{credentials:'include',
            headers:{'accept':'application/vnd.linkedin.normalized+json+2.1','csrf-token':j,'x-restli-protocol-version':'2.0.0'}});
          if (!r.ok) return '';
          const t=await r.text();
          const m=t.match(/urn:li:fsd_profile:([A-Za-z0-9_-]+)/);
          return m ? m[1] : '';
        } catch (e) { return ''; }
      })()
    }
    if {[catch {eval $js} v]} { return "" }
    return [string trim $v]
}
