#!/usr/bin/env tclsh
# Read the horse-riding operator cards from newzealand.com's Horse Riding page.
#
# Usage:
#     browser-serialiser newzealand.com/pub-horse-riding-capture
#
# The page shows its operators in a lazy horizontal card scroller: the markup
# for a card is written only once the scroller has been pushed past it, so the
# first DOM holds a handful. Ten scroll-and-settle rounds bring the rest in,
# after which the container's markup carries every card the page will show.
#
# Public: no login, and no account to name.

# Evaluate JS in the page, naming the step in any fault, so a selector the site
# has renamed says which one instead of arriving as a bare JS exception.
proc nz_eval_step {jsExpr label} {
    if {[catch {eval $jsExpr} res]} {
        error "$label: $res"
    }
    return $res
}

proc serialiser_run {skillArgs} {
    nav "https://www.newzealand.com/nz/horse-riding/" --wait 6
    if {[dict get [state] terminal] ne ""} { return }

    for {set i 0} {$i < 10} {incr i} {
        nz_eval_step {(function(){
            var el = document.querySelector(".showcase__cards-scroller, .showcase__container");
            if (el) { el.scrollLeft = el.scrollWidth; el.dispatchEvent(new Event("scroll", {bubbles:true})); }
            window.scrollBy(0, 900);
            return "ok";
        })()} scroll
        dwell 2
    }

    set count [nz_eval_step {(function(){
        return document.querySelectorAll(".product-shared__card").length;
    })()} card-count]
    set cards [nz_eval_step {(function(){
        var c = document.querySelector(".showcase__container");
        return c ? c.outerHTML : "";
    })()} cards-container]
    if {$cards eq ""} {
        emit [envelope_fault "the showcase container is gone: .showcase__container"]
        return
    }

    emit [envelope_ok [dict create result [json::write object \
        card_count $count \
        cards_html [json::write string $cards]]]]
}
