#!/usr/bin/env tclsh
# Search WorkSafe NZ's Adventure Activities public register by Activity
# Provided, and return the result grid page by page.
#
# Usage:
#     browser-serialiser worksafe.govt.nz/pub-register-search <term>
#
# The register's filter field carries id="2", a numeric id no CSS id selector
# can name ("#2" is a parse error, not a miss), so getElementById reaches it
# (SKILL.md). Paging below stops at the portal's own Next link running out or
# six pages, whichever comes first.
#
# Public: no login, and no account to name.

namespace eval wr {}

# Evaluate JS in the page, naming the step in any fault. A selector the portal
# has renamed then says which one, instead of arriving as a bare JS exception.
proc wr::eval_step {jsExpr label} {
    if {[catch {eval $jsExpr} res]} {
        error "$label: $res"
    }
    return $res
}

proc serialiser_run {skillArgs} {
    set term [lindex $skillArgs 0]
    if {$term eq ""} {
        emit [envelope_fault "usage: worksafe.govt.nz/pub-register-search <term>"]
        return
    }

    nav "https://services.worksafe.govt.nz/adventure-activities-public-register/" --wait 6
    if {[dict get [state] terminal] ne ""} { return }
    dwell 2

    set field [wr::eval_step {(function(){
        var e = document.getElementById("2");
        return e ? "found" : "missing";
    })()} filter-field]
    if {$field ne "found"} {
        emit [envelope_fault "the register's filter field is gone: no element with id 2"]
        return
    }

    wr::eval_step {(function(){
        var e = document.getElementById("2");
        e.focus();
        e.value = "";
        return "ok";
    })()} filter-clear
    type $term
    dwell 1

    set button [wr::eval_step {(function(){
        var b = document.querySelector(".btn-entitylist-filter-submit");
        return b ? "found" : "missing";
    })()} submit-button]
    if {$button ne "found"} {
        emit [envelope_fault "the register's submit button is gone: .btn-entitylist-filter-submit"]
        return
    }
    set clicked [click ".btn-entitylist-filter-submit"]
    if {$clicked != 1} {
        emit [envelope_fault "the filter submit click reported $clicked"]
        return
    }
    dwell 4

    set pages {}
    for {set page 1} {$page <= 6} {incr page} {
        set rows [wr::eval_step {(function(){
            var t = document.querySelector(".view-grid table tbody");
            return t ? t.outerHTML : "";
        })()} result-grid]
        lappend pages [json::write object \
            page $page \
            rows_html [json::write string $rows]]
        set more [wr::eval_step {(function(){
            var n = document.querySelector("a[aria-label=\"Next Page\"], .pageNext:not(.disabled), li.next:not(.disabled) a");
            if (n && n.offsetParent !== null) { n.click(); return "yes"; }
            return "no";
        })()} next-page]
        if {$more ne "yes"} break
        dwell 3
    }

    emit [envelope_ok [dict create result [json::write object \
        term [json::write string $term] \
        pages [json::write array {*}$pages]]]]
}
