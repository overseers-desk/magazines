# Enumerate published-content identities for a Meta Business Suite asset over a
# date range — the "cursor" half of a cursor+fetcher pair. Emits identity only
# (id, permalink, title, publish date, object type), including archived/older
# rows the 90-day CSV export drops; the metrics are a separate fetcher.
#
#   browser-serialiser business.facebook.com/posts-cursor <asset_id> <range>
#     <range> = a date_preset keyword (last_year, last_90d, this_year, ...) which
#               this skill maps to a from/to span, OR an explicit dd/mm/yyyy pair:
#                 ... <asset_id> 24/06/2025 23/06/2026
#
# WHY the calendar dance: the /latest/insights/content page IGNORES every URL
# date param (date_preset / since / until) and always lands on "Last 28 days".
# The range is settable ONLY through the in-page calendar popover, which on
# Update fires the list GraphQL with the chosen span. The list query
# (BusinessContentManagerPublishedContentTableQueryRendererQuery, root
# BizWebUnifiedTable) carries the rows.
#
# WHY in-page fetch interception (not CDP harvest): Network.getResponseBody
# returns EMPTY for Meta's /api/graphql/ responses (streamed/deferred bodies the
# CDP cache does not retain). The page's Relay network layer calls window.fetch,
# so a fetch wrapper installed after load captures every list/loadMore response
# body verbatim. We scroll the virtualised grid to page through the range; each
# scroll fires a loadMore the wrapper records.
#
# Identity location in a list body (per BizWebUnifiedTableRow node):
#   row_id                              -> post / media id
#   header.entity.entity_type           -> object type (IG_POST, IG_STORY,
#                                          FB_PAGE_POST, FB_PAGE_STORY, FB_EVENT,
#                                          REEL ...)
#   header.entity.entity_info.title     -> caption/title ("" for stories)
#   header.entity.entity_info.created_at-> publish time (epoch seconds)
#   header.entity.entity_info.cross_posted_entities -> the FB<->IG twin ids
# The connection also carries `all_ids` (the full ordered id list for the range,
# capped at 200). all_ids == 200 signals the range was truncated at the cap, so
# the caller should split the span into sub-ranges to cover everything.
#
# Permalink: the payload exposes NO permalink. We construct one for Facebook
# object types (https://www.facebook.com/<id>); Instagram media carry no shortcode
# here, so their permalink column is left empty (id + type still identify them).

package require json

namespace eval bizcur {}

# ---- in-page JS (kept simple + locale-robust; see probe history) -------------

# Install a fetch + XHR wrapper that buffers every /api/graphql/ response body
# into window.__gq. Idempotent.
set bizcur::JS_PATCH {(function(){
    if(window.__gi)return 'already';window.__gi=1;window.__gq=[];
    var of=window.fetch;
    window.fetch=function(){
        var a=arguments;var u=(a[0]&&a[0].url)?a[0].url:(''+a[0]);
        return of.apply(this,a).then(function(r){
            if(u&&u.indexOf('/api/graphql/')>=0){try{r.clone().text().then(function(t){window.__gq.push(t);});}catch(e){}}
            return r;
        });
    };
    var oo=XMLHttpRequest.prototype.open,os=XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open=function(m,u){this.__u=u;return oo.apply(this,arguments);};
    XMLHttpRequest.prototype.send=function(){var x=this;this.addEventListener('load',function(){try{if((''+x.__u).indexOf('/api/graphql/')>=0)window.__gq.push(x.responseText);}catch(e){}});return os.apply(this,arguments);};
    return 'installed';
})()}

# Click the date-range button. It is the [role=button] whose label is the current
# range ("Last NN days" or "DD Mon YYYY - DD Mon YYYY"). Locale tolerant: matches
# a 4-digit year with a dash, or the "Last <n>" prefix.
set bizcur::JS_OPEN_RANGE {(function(){
    var e=document.querySelectorAll('[role=button],[aria-label],button');
    for(var i=0;i<e.length;i++){
        var t=(e[i].getAttribute('aria-label')||e[i].innerText||'').replace(/\s+/g,' ').trim();
        if((/\d{4}/.test(t)&&/[-–]/.test(t))||/^Last \d+/.test(t)){(e[i].closest('[role=button]')||e[i]).click();return 'ok';}
    }
    return 'no';
})()}

# True once the calendar popover (with its stable CUSTOM radio) is present.
set bizcur::JS_HAS_CUSTOM {(function(){return !!document.querySelector('input[type=radio][value=CUSTOM]');})()}

# Count the two dd/mm/yyyy date inputs (placeholder match; locale-stable token).
set bizcur::JS_COUNT_DATE {(function(){var n=0;document.querySelectorAll('input').forEach(function(x){if((x.placeholder||'').toLowerCase().indexOf('dd/mm')>=0)n++;});return n;})()}

# Click the popover's submit button (Update / Actualizar / Apply / Aplicar).
set bizcur::JS_UPDATE {(function(){
    var e=document.querySelectorAll('[role=button],button');
    for(var i=0;i<e.length;i++){var t=(e[i].getAttribute('aria-label')||e[i].innerText||'').trim();
        if(t==='Update'||t==='Actualizar'||t==='Apply'||t==='Aplicar'){(e[i].closest('[role=button]')||e[i]).click();return 'u';}}
    return 'no';
})()}

# The current range label, for verification/logging.
set bizcur::JS_LABEL {(function(){var e=document.querySelectorAll('[role=button],[aria-label],button');for(var i=0;i<e.length;i++){var t=(e[i].getAttribute('aria-label')||e[i].innerText||'').replace(/\s+/g,' ').trim();if(/\d{1,2}\s+\w+\s+\d{4}\s*[-–]\s*\d{1,2}\s+\w+\s+\d{4}/.test(t)||/^Last \d+/.test(t))return t.slice(0,80);}return '?';})()}

# Page the virtualised grid. Setting scrollTop alone does NOT advance the
# virtualiser (its loadMore is wired to scroll/wheel events and to the last row
# entering view); a WheelEvent on the grid plus scrolling the last data row into
# view is what fires the next page. Each step mounts ~10 more rows and the page's
# Relay layer issues a loadMore the response wrapper records. Returns
# "scrollTop/maxScroll gq=N rows=M".
set bizcur::JS_SCROLL {(function(){
    var t=document.querySelector('table[role=grid]')||document.querySelector('div[role=grid]');
    if(!t)return 'nogrid';
    var step=Math.max(800,Math.round((t.clientHeight||670)*0.9));
    t.dispatchEvent(new WheelEvent('wheel',{deltaY:step,bubbles:true}));
    t.scrollTop=Math.min(t.scrollTop+step,t.scrollHeight);
    var rs=document.querySelectorAll('tr[role=row]');
    if(rs.length)rs[rs.length-1].scrollIntoView({block:'end'});
    var gq=window.__gq?window.__gq.length:-1;
    return Math.round(t.scrollTop)+'/'+Math.round(t.scrollHeight-t.clientHeight)+' gq='+gq+' rows='+rs.length;
})()}

# ---- helpers -----------------------------------------------------------------

# eval that swallows page-side errors to a default (mirrors the reel script's sv_js).
proc bizcur::ev {expr {default ""}} {
    if {[catch {eval $expr} v]} { return $default }
    if {$v eq ""} { return $default }
    return $v
}

# Map a date_preset keyword to a from/to dd/mm/yyyy span, anchored on today.
# Unknown keywords (or an explicit "dd/mm/yyyy dd/mm/yyyy" passed as two args) are
# handled by the caller; this only covers the presets the skill advertises.
proc bizcur::preset_span {preset} {
    set now [clock seconds]
    set today [clock format $now -format %d/%m/%Y]
    switch -- $preset {
        last_year - last_12m {
            set from [clock add $now -1 year]
        }
        last_90d { set from [clock add $now -90 days] }
        last_30d - last_28d { set from [clock add $now -28 days] }
        this_year {
            set y [clock format $now -format %Y]
            return [list "01/01/$y" $today]
        }
        max - maximum - all {
            # No true "all" preset exists; reach back generously. The 200-id cap
            # still applies per query, surfaced via all_ids length.
            set from [clock add $now -5 years]
        }
        default { set from [clock add $now -1 year] }
    }
    return [list [clock format $from -format %d/%m/%Y] $today]
}

# Type a date string into date input #idx (0=start, 1=end). The field is a masked
# input that reconstructs its value from React state, so a single value-reset does
# not reliably empty it (the end field in particular keeps its old text and the
# typed digits append, producing "22/6/202624"). So clear-and-verify in a loop:
# focus, select-all, set value '', confirm empty; only then `type` the date. The
# whole set retries until the readback carries the target year. Returns the final
# readback value.
proc bizcur::set_date {idx value} {
    # Target year, to verify the field took the new date (not the leftover one).
    set year ""
    regexp {(\d{4})} $value -> year

    set clearJs [subst -nocommands {(function(){
        var ins=Array.from(document.querySelectorAll('input')).filter(function(n){return (n.placeholder||'').toLowerCase().indexOf('dd/mm')>=0;});
        var el=ins[$idx]; if(!el)return 'no';
        el.focus();
        if(el.setSelectionRange)el.setSelectionRange(0,(el.value||'').length);
        var s=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
        s.call(el,'');
        el.dispatchEvent(new Event('input',{bubbles:true}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        el.focus(); if(el.select)el.select();
        return el.value;
    })()}]
    set readJs [subst -nocommands {(function(){var ins=Array.from(document.querySelectorAll('input')).filter(function(n){return (n.placeholder||'').toLowerCase().indexOf('dd/mm')>=0;});return ins[$idx]?ins[$idx].value:'?';})()}]

    for {set attempt 0} {$attempt < 4} {incr attempt} {
        # Clear, verifying the field actually empties (retry the clear itself).
        for {set c 0} {$c < 4} {incr c} {
            set cur [bizcur::ev $clearJs "?"]
            if {$cur eq "" || $cur eq "?"} break
            dwell 1
        }
        type $value
        dwell 1
        set read [bizcur::ev $readJs "?"]
        # A clean date ends in the 4-digit target year (e.g. "24 June 2025" or
        # "24/06/2025"). A garbled append leaves trailing digits ("22/6/202624"),
        # so require the year to be the LAST token, nothing after it.
        if {$year eq "" || [regexp "${year}\$" $read]} { return $read }
    }
    return $read
}

# Parse one captured body for identities. The list bodies are large, multi-line
# streamed/deferred JSON; rather than walk the deeply-nested dict (Tcl's recursion
# limit and the dict/list type ambiguity after json2dict both bite there), scan
# the raw text the way fb-common's extract_comment_bodies does: anchor on each
# "row_id":"<id>", then read the row's entity_type / title / created_at from a
# bounded window after it (the fields appear in that order inside the row's
# header.entity.entity_info). Also harvest every "all_ids":[...] array. Merges
# into `rows` (keyed by id) and `allids`, preferring a non-empty value over a
# previously stored empty one (a later body may hydrate a field an earlier one
# left blank).
proc bizcur::collect {body rowsVar allidsVar} {
    upvar 1 $rowsVar rows $allidsVar allids

    # all_ids arrays (the full ordered id list for the range; capped at 200).
    foreach {whole inner} [regexp -all -inline -- {"all_ids":\[([^\]]*)\]} $body] {
        foreach id [regexp -all -inline -- {\d+} $inner] {
            if {[lsearch -exact $allids $id] < 0} { lappend allids $id }
        }
    }

    # Each table row: anchor on its row_id, window forward for the identity fields.
    foreach {whole rid} [regexp -all -inline -- {"row_id":"(\d+)"} $body] {
        set pos [string first "\"row_id\":\"$rid\"" $body]
        if {$pos < 0} continue
        set win [string range $body $pos [expr {$pos + 2500}]]
        set type ""; set title ""; set created ""
        regexp -- {"entity_type":"([^"]+)"} $win -> type
        if {[regexp -- {"title":"((?:[^"\\]|\\.)*)"} $win -> t]} {
            set title [bizcur::json_unescape $t]
        }
        regexp -- {"created_at":(\d+)} $win -> created
        if {[dict exists $rows $rid]} {
            set p [dict get $rows $rid]
            if {$type eq ""}    { set type    [dict get $p type] }
            if {$title eq ""}   { set title   [dict get $p title] }
            if {$created eq ""} { set created [dict get $p created] }
        }
        dict set rows $rid [dict create type $type title $title created $created]
    }
}

# JSON-unescape a string literal's inner text (\n \" \\ \/ \uXXXX) by parsing it
# back through the JSON reader.
proc bizcur::json_unescape {s} {
    if {[catch {json::json2dict "\"$s\""} v]} { return $s }
    return $v
}

# Shift every buffered body out of the page (window.__gq) one at a time and parse
# each into rows/allids, leaving the page-side buffer empty. One body per eval
# keeps each returnByValue small; a guard caps the per-call drain so a runaway
# does not loop forever.
proc bizcur::drain {rowsVar allidsVar} {
    upvar 1 $rowsVar rows $allidsVar allids
    for {set k 0} {$k < 400} {incr k} {
        set body [bizcur::ev {(function(){return (window.__gq&&window.__gq.length)?window.__gq.shift():" EMPTY";})()} " EMPTY"]
        if {$body eq " EMPTY"} break
        if {$body eq ""} continue
        bizcur::collect $body rows allids
    }
}

# Build a permalink from id + type. Facebook objects resolve at facebook.com/<id>;
# Instagram media carry no shortcode in this payload, so their permalink is "".
proc bizcur::permalink {id type} {
    switch -glob -- $type {
        FB_* { return "https://www.facebook.com/$id" }
        default { return "" }
    }
}

# ---- entry -------------------------------------------------------------------

proc serialiser_run {skillArgs} {
    set asset_id [lindex $skillArgs 0]
    set a1 [lindex $skillArgs 1]
    set a2 [lindex $skillArgs 2]
    if {$asset_id eq ""} { emit "Usage: business.facebook.com/posts-cursor <asset_id> <range|dd/mm/yyyy dd/mm/yyyy>"; return }

    # Resolve the date span. Two explicit dd/mm/yyyy args, else a preset keyword.
    if {[string match */*/* $a1] && [string match */*/* $a2]} {
        set fromDate $a1; set toDate $a2; set rangeName "custom"
    } else {
        if {$a1 eq ""} { set a1 "last_year" }
        lassign [bizcur::preset_span $a1] fromDate toDate
        set rangeName $a1
    }

    set url "https://business.facebook.com/latest/insights/content?asset_id=$asset_id&date_preset=last_year"
    capture $url --seconds 14 --match "*__none__*"
    set st [state]
    if {[dict get $st terminal] ne ""} { emit "ERROR: terminal=[dict get $st terminal] (logged out / checkpoint / rate-limited)"; return }

    # No-session guard (the page renders chrome even when logged out of this asset).
    set noSession [bizcur::ev {/"USER_ID":"0"/.test(document.documentElement.outerHTML)?'1':'0'} 0]
    if {$noSession eq "1"} { emit "ERROR: not logged in (USER_ID:0). Log in via the GUI Chromium, then retry."; return }

    log "asset=$asset_id range=$rangeName span=$fromDate..$toDate"

    # Install the response wrapper before any refetch.
    log "patch=[bizcur::ev $::bizcur::JS_PATCH]"

    # Apply the date span through the popover. The masked date inputs are finicky:
    # a freshly typed END can fail to commit (its React state reverts to the default
    # end) even though the field displays the typed text, and the START edit can
    # clobber the END, so set END first then START. After Update the button label
    # is polled (it renders a beat after the grid refetch). The verification is
    # advisory: if the committed label does not carry both target years we re-set
    # the dates in the still-open/ re-opened popover up to twice, but we never abort
    # the run on it — whatever range applied is reported in the emitted header.
    regexp {(\d{4})} $fromDate -> fromYear
    regexp {(\d{4})} $toDate -> toYear
    set applied 0
    set label "?"
    for {set attempt 0} {$attempt < 3 && !$applied} {incr attempt} {
        for {set w 0} {$w < 12} {incr w} {
            bizcur::ev $::bizcur::JS_OPEN_RANGE
            if {[bizcur::ev $::bizcur::JS_HAS_CUSTOM 0] eq "true"} break
            dwell 1
        }
        if {[bizcur::ev $::bizcur::JS_HAS_CUSTOM 0] ne "true"} {
            log "WARNING: popover did not open on attempt $attempt"
            dwell 2
            continue
        }
        for {set w 0} {$w < 12} {incr w} {
            if {[bizcur::ev $::bizcur::JS_COUNT_DATE 0] >= 2} break
            dwell 1
        }
        # END first, then START (editing a date auto-selects CUSTOM mode).
        log "end=[bizcur::set_date 1 $toDate]"
        log "start=[bizcur::set_date 0 $fromDate]"
        dwell 1
        log "update=[bizcur::ev $::bizcur::JS_UPDATE]"
        # Poll the button label until it renders the committed range.
        for {set w 0} {$w < 8} {incr w} {
            dwell 2
            set label [bizcur::ev $::bizcur::JS_LABEL "?"]
            if {$label ne "?"} break
        }
        log "range-now=$label (attempt $attempt)"
        if {[string first $fromYear $label] >= 0 && [string first $toYear $label] >= 0} {
            set applied 1
        }
    }
    if {!$applied} {
        log "WARNING: committed range may not match $fromDate..$toDate (label=$label); proceeding"
    }
    set appliedLabel $label
    for {set w 0} {$w < 15} {incr w} {
        set pos [bizcur::ev $::bizcur::JS_SCROLL "?"]
        regexp {rows=(\d+)} $pos -> r0
        regexp {^(\d+)/(\d+)} $pos -> t0 m0
        if {([info exists m0] && $m0 ne "" && $m0 > 50) || ([info exists r0] && $r0 >= 8)} break
        dwell 2
        unset -nocomplain r0 m0 t0
    }

    # Page through the virtualised grid, draining captured bodies each round so the
    # page-side __gq buffer never grows large. Holding 200 rows' worth of 1MB+ list
    # responses in the page bloats it and stalls every later eval; so after each
    # scroll we shift bodies out (window.__gq.shift(), one per eval — returnByValue
    # on a 1MB string is cheap, on a 50MB array is not) and parse them here. We
    # stop when the hydrated id set covers all_ids, or after a run of scrolls that
    # add no new rows.
    set rows [dict create]
    set allids {}
    set lastRows 0
    set stale 0
    for {set iter 0} {$iter < 120} {incr iter} {
        set pos [bizcur::ev $::bizcur::JS_SCROLL "?"]
        bizcur::drain rows allids
        set hyd [dict size $rows]
        set nIds [llength $allids]
        if {$hyd > $lastRows} { set stale 0; set lastRows $hyd } else { incr stale }
        log "scroll $iter: $pos hydrated=$hyd/$nIds stale=$stale"
        if {$nIds > 0 && $hyd >= $nIds} break
        if {$stale >= 8} break
        dwell 2
    }
    # Final drain in case the last scroll's responses landed after the loop check.
    dwell 2
    bizcur::drain rows allids
    log "captured: hydrated=[dict size $rows] all_ids=[llength $allids]"

    # Emit: a header line (machine-parseable, # prefixed) then one TSV row per id.
    # Columns: id  type  publish_iso  permalink  title
    set total [dict size $rows]
    set capHit [expr {[llength $allids] >= 200 ? "yes" : "no"}]
    set out {}
    lappend out "# asset_id\t$asset_id"
    lappend out "# range\t$rangeName\t$fromDate\t$toDate"
    lappend out "# applied_range\t$appliedLabel"
    lappend out "# all_ids\t[llength $allids]\thydrated\t$total\tcap_hit\t$capHit"
    lappend out "# columns\tid\ttype\tpublish_iso\tpublish_epoch\tpermalink\ttitle"
    # Sort rows by publish time descending (newest first), unknowns last.
    set ordered {}
    dict for {rid info} $rows {
        set c [dict get $info created]
        if {$c eq "" || ![string is integer -strict $c]} { set c 0 }
        lappend ordered [list $c $rid $info]
    }
    set ordered [lsort -integer -decreasing -index 0 $ordered]
    foreach item $ordered {
        lassign $item c rid info
        set type [dict get $info type]
        set title [dict get $info title]
        set epoch [dict get $info created]
        set iso ""
        if {$epoch ne "" && [string is integer -strict $epoch]} {
            set iso [clock format $epoch -format "%Y-%m-%d %H:%M" -gmt 0]
        }
        set perma [bizcur::permalink $rid $type]
        # TSV-safe: collapse whitespace in title (TSV has no quoting).
        regsub -all {[\t\n\r]+} $title " " title
        lappend out "$rid\t$type\t$iso\t$epoch\t$perma\t$title"
    }
    emit [join $out "\n"]
}
