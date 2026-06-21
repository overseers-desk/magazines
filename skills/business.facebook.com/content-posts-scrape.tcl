# Scrape Meta Business Suite published-posts table (last-90-days window) row by
# row. The table is virtualised (~10 rows in the DOM), so scroll and accumulate,
# keyed by date+caption, until rows reach March or growth stops.
# Columns by aria-colindex: 2 Title, 3 Date, 5 Reach, 6 Views, 9 Interactions.
# Emits TSV: date<TAB>reach<TAB>views<TAB>interactions<TAB>caption
# Args: [platform-url]  (default the all-accounts published_posts list)

package require json

proc serialiser_run {skillArgs} {
    set url [lindex $skillArgs 0]
    if {$url eq ""} { set url "https://business.facebook.com/latest/posts/published_posts" }

    nav $url --wait 10
    if {[dict get [state] terminal] ne ""} { emit "error\twall"; return }

    array set seen {}
    set scrapeJs {(function(){
        var rows=Array.from(document.querySelectorAll('tr[role=row]'));
        var out=[];
        rows.forEach(function(r){
            var c={};
            r.querySelectorAll('td[aria-colindex]').forEach(function(td){c[td.getAttribute('aria-colindex')]=(td.innerText||'').replace(/\s+/g,' ').trim();});
            if(c['3']){out.push({d:c['3'],cap:(c['2']||'').slice(0,70),r:c['5']||'',v:c['6']||'',i:c['9']||''});}
        });
        return JSON.stringify(out);
    })()}
    # The scroll container is the table[role=grid] itself; step by ~80% of a
    # viewport so virtualised rows are not skipped. Returns "top/height".
    set scrollJs {(function(){
        var t=document.querySelector('table[role=grid]'); if(!t)return '0/0';
        t.scrollTop=Math.min(t.scrollTop+Math.round(t.clientHeight*0.8),t.scrollHeight);
        return Math.round(t.scrollTop)+'/'+Math.round(t.scrollHeight-t.clientHeight);
    })()}

    set stale 0
    set atBottom 0
    for {set iter 0} {$iter < 70} {incr iter} {
        set before [array size seen]
        foreach row [::json::json2dict [eval $scrapeJs]] {
            set d [dict get $row d]
            set key "$d\t[dict get $row cap]"
            set seen($key) "$d\t[dict get $row r]\t[dict get $row v]\t[dict get $row i]\t[dict get $row cap]"
        }
        set after [array size seen]
        set pos [eval $scrollJs]
        regexp {^(\d+)/(\d+)$} $pos -> top max
        if {$max ne "" && $top >= $max - 5} { incr atBottom } else { set atBottom 0 }
        log "iter $iter: rows=$after pos=$pos"
        if {$after == $before} { incr stale } else { set stale 0 }
        if {$atBottom >= 3 || $stale >= 6} break
        dwell 2
    }

    set lines {}
    foreach k [array names seen] { lappend lines $seen($k) }
    emit [join [lsort $lines] "\n"]
}
