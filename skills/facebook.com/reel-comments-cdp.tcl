#!/usr/bin/env tclsh
# Fetch comments from a Facebook reel.
#
# The reel viewer (https://www.facebook.com/reel/{id}) is an authenticated SPA
# that defers comment loading until the user clicks the Comment button. A plain
# DOM dump captures the player chrome but no comment text. This script drives the
# viewer: clicks Comment, switches sort to an unfiltered view, scrolls the
# comment list, and clicks "View more comments" / "View N replies" until the
# harvested set stops growing, then reads the comment bodies from the page's own
# GraphQL responses.
#
# Serialiser path (see SKILL.md §9): browser-serialiser facebook.com/reel-comments-cdp URL [--max-rounds N]
#   navigates via capture (the page's GraphQL comment responses are the primary
#   data path), drives the expansion through the in-page eval, harvests the
#   GraphQL bodies, builds the synthetic comment HTML, and emits the parsed
#   Markdown directly (reusing parse-reel-comments' byte-identical parser).
# Direct path (legacy CDP): CDP_WS_URL is supplied by the serialiser harness or
#   the overseer relay; this file is then a pure CDP client. It writes a
#   synthetic HTML document (one block per top-level comment) for parse-reel-comments.tcl.
#
# Usage:
#   browser-serialiser facebook.com/reel-comments-cdp URL [--out PATH]
#       [--bodies-json PATH] [--max-rounds N] [--debug]

package require json

# The legacy CDP engine is for the direct-tclsh path only; under the serialiser
# harness raw CDP is removed (the policed verbs replace it), so source it only
# when it is not already present and reachable. Sourcing it inside the safe
# interp is a no-op (the file is outside the access path / cdp already absent).
if {![namespace exists cdp]} {
    catch { source [file dirname [info script]]/../lib/cdp-client.tcl }
}
source [file dirname [info script]]/fb-common.tcl

namespace eval fbcdp {
    variable debug 0
    # This file's directory, captured at load time ([info script] is only valid
    # here, not at proc-runtime), so the lazy sibling source resolves correctly
    # both under plain tclsh and inside the safe interp's access path.
    variable dir [file dirname [info script]]
}

proc fbcdp::log {msg} {
    variable debug
    if {$debug} { puts stderr "\[reel\] $msg" }
}

# Sleep for $secs seconds (fractional) in the event loop, the way the Python
# time.sleep pauses let the page settle between CDP actions.
proc fbcdp::sleep {secs} {
    after [expr {int($secs * 1000)}]
}

# Runtime.evaluate of $expr; mirror the Python js() helper: returnByValue,
# awaitPromise=false, swallow JS exceptions to $default, return the value.
proc fbcdp::js {c expr {default ""}} {
    if {[catch {
        $c cdpBuffered Runtime.evaluate [dict create \
            expression $expr awaitPromise false returnByValue true]
    } resp]} {
        return $default
    }
    if {![dict exists $resp result]} { return $default }
    set result [dict get $resp result]
    if {[dict exists $result exceptionDetails]} { return $default }
    if {![dict exists $result result]} { return $default }
    set inner [dict get $result result]
    if {![dict exists $inner value]} { return $default }
    return [dict get $inner value]
}

# Like js, but parse the returned JSON-string value into a dict (the harvest
# stats expression returns an object). Returns $default on any failure.
proc fbcdp::js_dict {c expr default} {
    set v [fbcdp::js $c $expr ""]
    if {$v eq ""} { return $default }
    # The harvest expression returns an object via returnByValue, so the CDP
    # value is already a dict (json2dict applied by the relay? no: returnByValue
    # gives a JS object serialised into the CDP result.value as a nested
    # structure, which the client returns as a Tcl dict).
    if {[catch {dict size $v}]} { return $default }
    return $v
}

# ---------------------------------------------------------------------------
# In-page JS expressions. These run inside the reel page and return plain
# values through Runtime.evaluate(returnByValue). They are byte-identical to
# the Python predecessor's constants (the logic lives in the browser, not here).
# ---------------------------------------------------------------------------

set fbcdp::JS_COMMENT_COUNT {
(function(){
  var arts = document.querySelectorAll('div[role="article"][aria-label^="Comment by "]');
  return arts.length;
})()
}

set fbcdp::JS_REPLY_COUNT {
(function(){
  var arts = document.querySelectorAll('div[role="article"][aria-label^="Reply by "]');
  return arts.length;
})()
}

set fbcdp::JS_CLICK_COMMENT_BUTTON {
(function(){
  var btns = document.querySelectorAll('[aria-label="Comment"]');
  for (var i = 0; i < btns.length; i++) {
    var b = btns[i];
    var r = b.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) {
      b.click();
      return true;
    }
  }
  return false;
})()
}

set fbcdp::JS_SCROLL_COMMENTS {
(function(){
  var art = document.querySelector('div[role="article"][aria-label^="Comment by "]');
  if (!art) return false;
  var el = art.parentElement;
  while (el) {
    var s = getComputedStyle(el);
    if ((s.overflowY === 'auto' || s.overflowY === 'scroll') &&
        el.scrollHeight > el.clientHeight + 5) {
      el.scrollTop = el.scrollHeight;
      return true;
    }
    el = el.parentElement;
  }
  window.scrollTo(0, document.body.scrollHeight);
  return false;
})()
}

set fbcdp::JS_CLICK_VIEW_MORE {
(function(){
  var clicked = 0;
  var seen = new Set();
  var spans = document.querySelectorAll('span, div[role="button"], a[role="button"]');
  for (var i = 0; i < spans.length; i++) {
    var n = spans[i];
    var t = (n.textContent || '').trim().toLowerCase();
    if (!t || t.length > 80) continue;
    var match = (
      t === 'view more comments' ||
      t === 'view previous comments' ||
      /^view\s+\d[\d,]*\s+more\s+(comment|reply|replie)/.test(t) ||
      /^view\s+\d[\d,]*\s+(reply|replie)/.test(t) ||
      /^\d[\d,]*\s+(reply|replies)$/.test(t) ||
      t === 'view more replies' ||
      t === 'view all replies' ||
      t === 'see more'
    );
    if (!match) continue;
    var r = n.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    var key = Math.round(r.top) + ':' + Math.round(r.left) + ':' + t;
    if (seen.has(key)) continue;
    seen.add(key);
    try { n.click(); } catch(e) {}
    var clickable = n.closest('[role="button"], [tabindex="0"], button, a');
    if (clickable && clickable !== n) {
      try { clickable.click(); } catch(e) {}
    }
    clicked++;
  }
  return clicked;
})()
}

set fbcdp::JS_SWITCH_SORT_ALL {
(function(){
  var btns = document.querySelectorAll('div[role="button"], span[role="button"], button');
  for (var i = 0; i < btns.length; i++) {
    var b = btns[i];
    var t = (b.textContent || '').trim();
    if (!t || t.length > 60) continue;
    if (!t.toLowerCase().startsWith('most relevant')) continue;
    var r = b.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    b.click();
    return 'opened';
  }
  return null;
})()
}

set fbcdp::JS_PICK_SORT_OPTION {
(function(){
  var preferred = ['all comments', 'newest', 'newest first'];
  var nodes = document.querySelectorAll(
    '[role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"], ' +
    'div[role="button"], span[role="button"], button'
  );
  for (var p = 0; p < preferred.length; p++) {
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var t = (n.textContent || '').trim().toLowerCase();
      if (!t || t.length > 60) continue;
      if (!t.startsWith(preferred[p])) continue;
      var r = n.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      n.click();
      return preferred[p];
    }
  }
  return null;
})()
}

set fbcdp::JS_TOTAL_COMMENT_COUNT {
(function(){
  var html = document.documentElement.outerHTML;
  var matches = html.match(/"total_comment_count":\s*(\d+)/g) || [];
  var max = 0;
  for (var i = 0; i < matches.length; i++) {
    var n = parseInt(matches[i].split(':')[1], 10);
    if (n > max) max = n;
  }
  return max || null;
})()
}

set fbcdp::JS_HARVEST_COMMENTS {
(function(){
  if (!window.__harvested) window.__harvested = {};
  if (!window.__order) window.__order = [];
  var arts = document.querySelectorAll(
    'div[role="article"][aria-label^="Comment by "], ' +
    'div[role="article"][aria-label^="Reply by "]'
  );
  var added = 0, expanded = 0;
  for (var i = 0; i < arts.length; i++) {
    var a = arts[i];
    var link = a.querySelector('a[href*="comment_id="]');
    if (!link) continue;
    var m = link.getAttribute('href').match(/comment_id=([^&"]+)/);
    if (!m) continue;
    var cid = m[1];
    var newHtml = a.outerHTML;
    var existing = window.__harvested[cid];
    if (existing) {
      if (newHtml.length > existing.html.length) {
        existing.html = newHtml;
        expanded++;
      }
      continue;
    }
    var parent_cid = null;
    var p = a.parentNode ? a.parentNode.closest(
      'div[role="article"][aria-label^="Comment by "]'
    ) : null;
    if (p && p !== a) {
      var pl = p.querySelector('a[href*="comment_id="]');
      if (pl) {
        var pm = pl.getAttribute('href').match(/comment_id=([^&"]+)/);
        if (pm) parent_cid = pm[1];
      }
    }
    var isReply = a.getAttribute('aria-label').indexOf('Reply by ') === 0;
    window.__harvested[cid] = {
      html: newHtml, parent_cid: parent_cid, is_reply: isReply
    };
    window.__order.push(cid);
    added++;
  }
  return {
    total: Object.keys(window.__harvested).length,
    added: added, expanded: expanded
  };
})()
}

set fbcdp::JS_DUMP_HARVEST {
(function(){
  if (!window.__harvested) return null;
  var parts = ['<!DOCTYPE html><html><head><title>__TITLE__</title></head><body>'];
  var order = window.__order || Object.keys(window.__harvested);
  for (var i = 0; i < order.length; i++) {
    var cid = order[i];
    var v = window.__harvested[cid];
    if (!v) continue;
    if (v.is_reply) continue;
    parts.push(v.html);
  }
  for (var j = 0; j < order.length; j++) {
    var cid2 = order[j];
    var v2 = window.__harvested[cid2];
    if (!v2 || !v2.is_reply) continue;
    if (v2.parent_cid && window.__harvested[v2.parent_cid]) continue;
    parts.push(v2.html);
  }
  parts.push('</body></html>');
  return parts.join('\n');
})()
}

set fbcdp::JS_CLICK_SEE_MORE {
(function(){
  var divs = document.querySelectorAll('div[role="button"][tabindex="0"], span[role="button"]');
  var clicked = 0;
  for (var i = 0; i < divs.length; i++) {
    var d = divs[i];
    if (d.textContent.trim() !== 'See more') continue;
    var r = d.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) continue;
    try {
      d.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true}));
      d.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, cancelable: true}));
      d.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true}));
    } catch(e) {}
    clicked++;
  }
  return clicked;
})()
}

set fbcdp::JS_SCROLL_TOP {
(function(){
  var art = document.querySelector('div[role="article"]');
  if (!art) return; var el = art.parentElement;
  while (el) { var s = getComputedStyle(el);
    if ((s.overflowY=='auto'||s.overflowY=='scroll') &&
        el.scrollHeight > el.clientHeight+5) {
      el.scrollTop = 0; return;
    }
    el = el.parentElement;
  } window.scrollTo(0,0);
})()
}

set fbcdp::JS_SCROLL_STEP {
(function(){
  var art = document.querySelector('div[role="article"]');
  if (!art) return false; var el = art.parentElement;
  while (el) { var s = getComputedStyle(el);
    if ((s.overflowY=='auto'||s.overflowY=='scroll') &&
        el.scrollHeight > el.clientHeight+5) {
      var before = el.scrollTop;
      el.scrollTop = before + el.clientHeight * 0.6;
      return el.scrollTop !== before;
    }
    el = el.parentElement;
  } return false;
})()
}

# Pull every {legacy_fbid -> body.text} pair from a GraphQL response body.
# Comment edges look like:
#   "legacy_fbid":"NUMERIC","depth":N,"body":{"text":"...","ranges":[...]}
# Anchor on legacy_fbid, scan forward for the nearest body.text.
proc fbcdp::extract_comment_bodies {response_text} {
    set out [dict create]
    foreach {whole cap} [regexp -all -inline -indices -- {"legacy_fbid":"(\d+)"} $response_text] {
        set cid [string range $response_text {*}$cap]
        if {[dict exists $out $cid]} { continue }
        set we [lindex $whole 1]
        set window [string range $response_text [expr {$we+1}] [expr {$we+4000}]]
        # The body text is a JSON string literal that may contain escapes.
        if {[regexp -- {"body":\{"text":"((?:[^"\\]|\\.)*)"} $window -> text]} {
            # JSON-unescape (\n \" \\ \uXXXX) by parsing as a JSON string.
            if {[catch {json::json2dict "\"$text\""} decoded]} {
                dict set out $cid $text
            } else {
                dict set out $cid $decoded
            }
        }
    }
    return $out
}

# Emit a JSON object {legacy_fbid: full_text} matching Python json.dump with
# ensure_ascii=False (raw UTF-8, compact separators).
proc fbcdp::bodies_to_json {bodies} {
    set parts {}
    dict for {k v} $bodies {
        lappend parts "[json::write string $k]: [json::write string $v]"
    }
    return "{[join $parts ", "]}"
}

# ---------------------------------------------------------------------------
# Main fetch routine.
# ---------------------------------------------------------------------------
proc fbcdp::fetch {c url max_rounds bodies_out} {
    variable JS_COMMENT_COUNT
    variable JS_REPLY_COUNT
    variable JS_CLICK_COMMENT_BUTTON
    variable JS_SCROLL_COMMENTS
    variable JS_CLICK_VIEW_MORE
    variable JS_SWITCH_SORT_ALL
    variable JS_PICK_SORT_OPTION
    variable JS_TOTAL_COMMENT_COUNT
    variable JS_HARVEST_COMMENTS
    variable JS_DUMP_HARVEST
    variable JS_CLICK_SEE_MORE
    variable JS_SCROLL_TOP
    variable JS_SCROLL_STEP

    # Buffer network events for the GraphQL body harvest at the end.
    $c cdpBuffered Network.enable
    $c cdpBuffered Network.setCacheDisabled [dict create cacheDisabled false]
    $c cdpBuffered Page.enable

    fbcdp::log "navigate $url"
    $c cdpBuffered Page.navigate [dict create url $url]
    fbcdp::sleep 4

    # Wait for page chrome to render (the Comment action button).
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < 20000} {
        if {[fbcdp::js $c {!!document.querySelector('[aria-label="Comment"]')} false] eq "true"} {
            break
        }
        $c drainEvents 0.5
    }

    # No-session detection.
    set title [fbcdp::js $c {document.title} ""]
    set no_session [fbcdp::js $c \
        {/"(?:USER_ID|ACCOUNT_ID)":"0"/.test(document.documentElement.outerHTML)} false]
    fbcdp::log "title=$title no_session=$no_session"
    set tl [string tolower $title]
    if {$no_session eq "true" || \
        [string first "log in" $tl] >= 0 || \
        [string first "log into" $tl] >= 0 || \
        [string first "iniciar sesi" $tl] >= 0} {
        puts stderr "ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."
        exit 1
    }

    set total [fbcdp::js $c $JS_TOTAL_COMMENT_COUNT ""]
    fbcdp::log "total_comment_count=$total"

    # Open the comment panel.
    set clicked [fbcdp::js $c $JS_CLICK_COMMENT_BUTTON false]
    fbcdp::log "clicked Comment button: $clicked"
    fbcdp::sleep 3

    # Wait for the panel to render before switching sort.
    set t1 [clock milliseconds]
    while {[clock milliseconds] - $t1 < 15000} {
        if {[num [fbcdp::js $c $JS_COMMENT_COUNT 0]] > 0} { break }
        $c drainEvents 0.5
    }

    # Switch sort from "Most relevant" to an unfiltered view.
    if {[fbcdp::js $c $JS_SWITCH_SORT_ALL ""] ne ""} {
        fbcdp::sleep 1.5
        set chosen [fbcdp::js $c $JS_PICK_SORT_OPTION ""]
        fbcdp::log "sort switched to: $chosen"
        fbcdp::sleep 3
    } else {
        fbcdp::log "sort trigger not found; staying on default"
    }

    # Harvest loop: scroll + click "view more" until the harvest stops growing.
    fbcdp::js $c $JS_HARVEST_COMMENTS ""
    set stable_rounds 0
    for {set round_num 0} {$round_num < $max_rounds} {incr round_num} {
        fbcdp::js $c $JS_SCROLL_COMMENTS false
        $c drainEvents 0.6
        set clicked_more [num [fbcdp::js $c $JS_CLICK_VIEW_MORE 0]]
        if {$clicked_more} { $c drainEvents 1.2 }
        set stats [fbcdp::js_dict $c $JS_HARVEST_COMMENTS [dict create total 0 added 0]]
        set h_total [num [dict_get0 $stats total]]
        set h_added [num [dict_get0 $stats added]]
        set mounted [expr {[num [fbcdp::js $c $JS_COMMENT_COUNT 0]] + [num [fbcdp::js $c $JS_REPLY_COUNT 0]]}]
        fbcdp::log "round $round_num: harvested=$h_total (+$h_added)  mounted=$mounted  view-more-clicked=$clicked_more"

        if {$total ne "" && $total ne "null" && $h_total >= [num $total]} {
            fbcdp::log "reached total_comment_count; stopping"
            break
        }
        if {$h_added == 0 && $clicked_more == 0} {
            incr stable_rounds
            if {$stable_rounds >= 8} {
                fbcdp::log "no growth for $stable_rounds rounds; stopping"
                break
            }
        } else {
            set stable_rounds 0
        }
    }

    # Final pass: scroll top->bottom expanding "See more".
    fbcdp::log "final pass: scrolling top->bottom expanding See more"
    foreach direction {0 1} {
        if {$direction == 0} {
            fbcdp::js $c $JS_SCROLL_TOP ""
            fbcdp::sleep 2.0
        }
        for {set step 0} {$step < 50} {incr step} {
            set sm [num [fbcdp::js $c $JS_CLICK_SEE_MORE 0]]
            if {$sm} { $c drainEvents 1.4 }
            set vm [num [fbcdp::js $c $JS_CLICK_VIEW_MORE 0]]
            if {$vm} { $c drainEvents 1.0 }
            fbcdp::js $c $JS_HARVEST_COMMENTS ""
            set moved [fbcdp::js $c $JS_SCROLL_STEP false]
            if {$moved ne "true" && $sm == 0 && $vm == 0} { break }
        }
    }

    set title [fbcdp::js $c {document.title} "Facebook reel"]
    if {$title eq ""} { set title "Facebook reel" }
    set title_clean [string map {' ""} $title]
    set dump_expr [string map [list __TITLE__ $title_clean] $JS_DUMP_HARVEST]
    set html [fbcdp::js $c $dump_expr ""]
    if {$html eq ""} { set html "" }

    # Splice the live head metadata (og:url, feedback counts) into the dump.
    set head_html [fbcdp::js $c \
        {(function(){var head = document.querySelector('head');return head ? head.outerHTML : '';})()} ""]
    if {$head_html ne "" && [string first "<head>" $html] >= 0} {
        set needle "<head><title>$title_clean</title></head>"
        set pos [string first $needle $html]
        if {$pos >= 0} {
            set html "[string range $html 0 [expr {$pos-1}]]$head_html[string range $html [expr {$pos+[string length $needle]}] end]"
        }
    }

    # Drain GraphQL response bodies for canonical comment text.
    if {$bodies_out ne ""} {
        # Flush, then collect graphql request ids from buffered network events.
        $c cdpBuffered Runtime.evaluate [dict create expression 1 returnByValue true]
        set gql_rids {}
        foreach e [$c events] {
            if {![dict exists $e method] || [dict get $e method] ne "Network.responseReceived"} {
                continue
            }
            set params [dict get $e params]
            set resp [expr {[dict exists $params response] ? [dict get $params response] : {}}]
            set url_ [expr {[dict exists $resp url] ? [dict get $resp url] : ""}]
            set rid [expr {[dict exists $params requestId] ? [dict get $params requestId] : ""}]
            if {$rid ne "" && [string first "graphql" $url_] >= 0} {
                lappend gql_rids $rid
            }
        }
        fbcdp::log "draining [llength $gql_rids] graphql responses for bodies"
        set bodies [dict create]
        foreach rid $gql_rids {
            if {[catch {
                set body_resp [$c cdp Network.getResponseBody [dict create requestId $rid]]
            }]} { continue }
            if {![dict exists $body_resp result body]} { continue }
            set txt [dict get $body_resp result body]
            if {[dict exists $body_resp result base64Encoded] && \
                [dict get $body_resp result base64Encoded] eq "true"} {
                set txt [encoding convertfrom utf-8 [binary decode base64 $txt]]
            }
            if {[string first {"legacy_fbid"} $txt] < 0} { continue }
            foreach {k v} [fbcdp::extract_comment_bodies $txt] {
                dict set bodies $k $v
            }
        }
        fbcdp::log "canonical bodies extracted: [dict size $bodies]"
        set f [open $bodies_out w]
        fconfigure $f -encoding utf-8
        puts -nonewline $f [fbcdp::bodies_to_json $bodies]
        close $f
    }

    return $html
}

# Coerce a CDP-returned value to an integer (null/empty -> 0).
proc num {v} {
    if {$v eq "" || $v eq "null" || $v eq "false"} { return 0 }
    if {$v eq "true"} { return 1 }
    if {[string is integer -strict $v]} { return $v }
    if {[regexp {^-?\d+} $v m]} { return $m }
    return 0
}

# dict get with a 0 default for the harvest-stats fields.
proc dict_get0 {d key} {
    if {[catch {dict get $d $key} v]} { return 0 }
    return $v
}

# ---------------------------------------------------------------------------
# Serialiser path. The interaction logic and every in-page JS expression are the
# legacy ones verbatim (the logic lives in the browser); only the transport
# changes — `eval` replaces fbcdp::js, `capture`/`harvest` replace the raw
# Network.enable + getResponseBody drain. The harvested synthetic HTML and the
# GraphQL bodies feed parse-reel-comments' byte-identical parser, and the run
# emits the Markdown directly (the serialiser has one output channel).
# ---------------------------------------------------------------------------

# eval-over-the-verb, mirroring fbcdp::js's swallow-to-default contract: the
# policed `eval` raises "JS exception: ..." on a page error, which we catch and
# return $default, exactly as the legacy js() swallowed exceptions.
proc fbcdp::sv_js {expr {default ""}} {
    if {[catch {eval $expr} v]} { return $default }
    if {$v eq ""} { return $default }
    return $v
}

# js_dict variant: the harvest-stats expression returns an object; eval returns
# it as a Tcl dict (returnByValue). On failure return $default.
proc fbcdp::sv_js_dict {expr default} {
    set v [fbcdp::sv_js $expr ""]
    if {$v eq ""} { return $default }
    if {[catch {dict size $v}]} { return $default }
    return $v
}

# Drive the reel viewer over the policed surface and return the synthetic comment
# HTML plus the {legacy_fbid -> body} dict harvested from the page's GraphQL
# responses. The expansion loop and the JS constants are byte-identical to
# fbcdp::fetch; the differences are transport-only (sv_js / capture / harvest).
proc fbcdp::sv_fetch {url max_rounds} {
    variable JS_COMMENT_COUNT
    variable JS_REPLY_COUNT
    variable JS_CLICK_COMMENT_BUTTON
    variable JS_SCROLL_COMMENTS
    variable JS_CLICK_VIEW_MORE
    variable JS_SWITCH_SORT_ALL
    variable JS_PICK_SORT_OPTION
    variable JS_TOTAL_COMMENT_COUNT
    variable JS_HARVEST_COMMENTS
    variable JS_DUMP_HARVEST
    variable JS_CLICK_SEE_MORE
    variable JS_SCROLL_TOP
    variable JS_SCROLL_STEP

    # capture navigates (paced) with Network buffering on, settles the initial
    # render, and returns the initial GraphQL responses.  The reel viewer
    # pre-renders comments without requiring a click — the comment panel is open
    # by default.  Clicking the "Comment" toggle button closes it (confirmed by
    # testing: comment articles appear after ~20 s of natural load; the click
    # hides them).  We wait 22 s so comments are in the DOM before we proceed.
    set init_triples [capture $url --seconds 22 --match "*graphql*"]
    ::log "sv_fetch: init_triples=[llength $init_triples] graphql responses from initial load"

    set st [state]
    if {[dict get $st terminal] ne ""} {
        return [list "" [dict create] [dict get $st terminal]]
    }

    # No-session detection (the legacy check, over the policed eval).
    set title [fbcdp::sv_js {document.title} ""]
    set no_session [fbcdp::sv_js \
        {/"(?:USER_ID|ACCOUNT_ID)":"0"/.test(document.documentElement.outerHTML)} false]
    set tl [string tolower $title]
    ::log "sv_fetch: title=$title no_session=$no_session"
    if {$no_session eq "true" || \
        [string first "log in" $tl] >= 0 || \
        [string first "log into" $tl] >= 0 || \
        [string first "iniciar sesi" $tl] >= 0} {
        return [list "" [dict create] no-session]
    }

    set total [fbcdp::sv_js $JS_TOTAL_COMMENT_COUNT ""]
    ::log "sv_fetch: total_comment_count=$total"

    # Do NOT click the Comment toggle — the panel is already open.
    # Wait up to 5 s for any stragglers (usually 0 extra waits needed at this point).
    set cc 0
    for {set w 0} {$w < 10} {incr w} {
        set cc [num [fbcdp::sv_js $JS_COMMENT_COUNT 0]]
        if {$cc > 0} { break }
        dwell 0.5
    }
    ::log "sv_fetch: comment_count_in_dom=$cc (no click needed)"

    # Switch sort from "Most relevant" to an unfiltered view.
    set sort_result [fbcdp::sv_js $JS_SWITCH_SORT_ALL ""]
    ::log "sv_fetch: switch_sort_result=$sort_result"
    if {$sort_result ne ""} {
        dwell 1.5
        set picked [fbcdp::sv_js $JS_PICK_SORT_OPTION ""]
        ::log "sv_fetch: sort_picked=$picked"
        dwell 8
    }

    # Harvest loop: incremental scroll + click "view more" until harvest stops growing.
    # Use JS_SCROLL_STEP (viewport-height increments) rather than a single jump to
    # the absolute bottom so Facebook's IntersectionObserver triggers at page
    # boundaries rather than overrunning them.
    fbcdp::sv_js $JS_HARVEST_COMMENTS ""
    set stable_rounds 0
    for {set round_num 0} {$round_num < $max_rounds} {incr round_num} {
        set clicked_more [num [fbcdp::sv_js $JS_CLICK_VIEW_MORE 0]]
        if {$clicked_more} { dwell 2.0 }
        set scrolled [fbcdp::sv_js $JS_SCROLL_STEP false]
        if {$scrolled eq "true"} { dwell 0.8 } else { dwell 0.3 }
        set stats [fbcdp::sv_js_dict $JS_HARVEST_COMMENTS [dict create total 0 added 0]]
        set h_total [num [dict_get0 $stats total]]
        set h_added [num [dict_get0 $stats added]]
        ::log "sv_fetch: round=$round_num harvested=$h_total (+$h_added) scrolled=$scrolled vm=$clicked_more stable=$stable_rounds"
        if {$total ne "" && $total ne "null" && $h_total >= [num $total]} {
            break
        }
        if {$h_added == 0 && $clicked_more == 0} {
            incr stable_rounds
            if {$stable_rounds >= 8} {
                dwell 3
                set stats2 [fbcdp::sv_js_dict $JS_HARVEST_COMMENTS [dict create total 0 added 0]]
                if {[num [dict_get0 $stats2 added]] > 0} {
                    set stable_rounds 0
                } else {
                    break
                }
            }
        } else {
            set stable_rounds 0
        }
    }

    # Final pass: scroll top->bottom expanding "See more".
    foreach direction {0 1} {
        if {$direction == 0} {
            fbcdp::sv_js $JS_SCROLL_TOP ""
            dwell 2.0
        }
        for {set step 0} {$step < 50} {incr step} {
            set sm [num [fbcdp::sv_js $JS_CLICK_SEE_MORE 0]]
            if {$sm} { dwell 1.4 }
            set vm [num [fbcdp::sv_js $JS_CLICK_VIEW_MORE 0]]
            if {$vm} { dwell 1.0 }
            fbcdp::sv_js $JS_HARVEST_COMMENTS ""
            set moved [fbcdp::sv_js $JS_SCROLL_STEP false]
            if {$moved ne "true" && $sm == 0 && $vm == 0} { break }
        }
    }

    # Build the synthetic harvest HTML (identical to the legacy dump + head splice).
    set title [fbcdp::sv_js {document.title} "Facebook reel"]
    if {$title eq ""} { set title "Facebook reel" }
    set title_clean [string map {' ""} $title]
    set dump_expr [string map [list __TITLE__ $title_clean] $JS_DUMP_HARVEST]
    set html [fbcdp::sv_js $dump_expr ""]
    if {$html eq ""} { set html "" }
    set head_html [fbcdp::sv_js \
        {(function(){var head = document.querySelector('head');return head ? head.outerHTML : '';})()} ""]
    if {$head_html ne "" && [string first "<head>" $html] >= 0} {
        set needle "<head><title>$title_clean</title></head>"
        set pos [string first $needle $html]
        if {$pos >= 0} {
            set html "[string range $html 0 [expr {$pos-1}]]$head_html[string range $html [expr {$pos+[string length $needle]}] end]"
        }
    }

    # The comment bodies are the page's own GraphQL responses, the primary
    # private-data path: combine the initial-load triples (captured at
    # navigation) with any further triples from clicking Comment / scrolling.
    set later_triples [harvest --match "*graphql*"]
    ::log "sv_fetch: init=[llength $init_triples] later=[llength $later_triples] graphql triples"
    set bodies [dict create]
    foreach triple [concat $init_triples $later_triples] {
        lassign $triple resp_url resp_status txt
        if {[string first {"legacy_fbid"} $txt] < 0} { continue }
        foreach {k v} [fbcdp::extract_comment_bodies $txt] {
            dict set bodies $k $v
        }
    }
    ::log "sv_fetch: bodies=[dict size $bodies]  html_len=[string length $html]"

    return [list $html $bodies ""]
}

# The entry the harness calls. Drives the viewer, then runs parse-reel-comments'
# byte-identical parse_html + to_markdown over the harvested HTML and GraphQL
# bodies, emitting the Markdown (the run's single output).
#
# Invoked by reference through the serialiser (see SKILL.md §9):
#     browser-serialiser facebook.com/reel-comments-cdp URL [--max-rounds N]
proc serialiser_run {skillArgs} {
    set url ""
    set max_rounds 80
    for {set i 0} {$i < [llength $skillArgs]} {incr i} {
        set a [lindex $skillArgs $i]
        switch -- $a {
            --max-rounds { incr i; set max_rounds [lindex $skillArgs $i] }
            default      { if {$url eq ""} { set url $a } }
        }
    }
    if {$url eq ""} {
        emit "Usage: facebook.com/reel-comments-cdp URL \[--max-rounds N\]"
        return
    }
    ::log "serialiser_run: calling sv_fetch url=$url max_rounds=$max_rounds"
    lassign [fbcdp::sv_fetch $url $max_rounds] html bodies wall
    ::log "serialiser_run: sv_fetch done wall=$wall bodies=[dict size $bodies] html_len=[string length $html]"
    if {$wall ne ""} {
        emit "ERROR: Facebook: not logged in - no session in this profile. Log in via the GUI Chromium, then close it and retry."
        return
    }
    set data [parse_html $html $bodies]
    ::log "serialiser_run: parse_html done comments=[llength [dict get $data comments]]"
    set md [to_markdown $data $url]
    ::log "serialiser_run: to_markdown len=[string length $md]"
    emit $md
}

# The byte-identical comment parser/renderer lives in the sibling parse-reel-comments.
# Source it at load time (the Safe Base's `source` works during a file's own load,
# even with the `eval` verb aliased; a runtime source does not). The guard skips
# the source when its procs are already present, so the two files' mutual
# load-time sources resolve without recursion: each defines its own procs first,
# then sources the other, which then sees those procs and skips back.
if {![llength [info commands parse_html]]} {
    source [file join $fbcdp::dir parse-reel-comments.tcl]
}

# Direct-tclsh entry (legacy CDP). Skipped when sourced as a serialiser skill.
if {[info exists argv0] && [file tail [info script]] eq [file tail $argv0]} {
    # --- Argument parsing ---
    set url ""
    set out_path ""
    set bodies_json ""
    set max_rounds 80
    set positional {}
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        switch -- $a {
            --out         { incr i; set out_path [lindex $argv $i] }
            --bodies-json { incr i; set bodies_json [lindex $argv $i] }
            --max-rounds  { incr i; set max_rounds [lindex $argv $i] }
            --debug       { set fbcdp::debug 1 }
            default       { lappend positional $a }
        }
    }
    if {[llength $positional] != 1} {
        puts stderr "Usage: reel-comments-cdp.tcl URL \[--out PATH\] \[--bodies-json PATH\] \[--max-rounds N\] \[--debug\]"
        exit 1
    }
    set url [lindex $positional 0]

    if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
        puts stderr "ERROR: CDP_WS_URL not set; run via: browser-serialiser facebook.com/reel-comments-cdp <reel-url> \[--out FILE\]"
        exit 1
    }

    fconfigure stdout -encoding utf-8
    fconfigure stderr -encoding utf-8

    set c [cdp::connect]
    set rc [catch {fbcdp::fetch $c $url $max_rounds $bodies_json} html]
    catch {$c close}
    if {$rc} {
        error $html
    }

    if {$out_path ne ""} {
        set f [open $out_path w]
        fconfigure $f -encoding utf-8
        puts -nonewline $f $html
        close $f
        puts stderr "wrote [fb::commafy [string length $html]] bytes to $out_path"
    } else {
        puts -nonewline $html
    }
}
