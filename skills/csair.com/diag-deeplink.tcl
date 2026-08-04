# Throwaway diagnostic: fire the booking deep link with raw m/t/p values and
# emit every */api/shop/* response as pure ASCII (escaped text; hex for small
# bodies; key-structure summary for big ones). args: <m> <t> [p]. Delete after use.

package require json

# Targeted structure report for a /api/shop/search body: the keys at the
# levels the render walks, and row[0] in full, so the multi-slice question
# (one .slice per row, or something new) is answered without the whole dump.
proc diag_shape {body} {
    if {[catch {json::json2dict $body} d]} { return "  (does not parse as JSON)\n" }
    set out "  top keys: [join [dict keys $d] { }]\n"
    if {[catch {dict get $d ita} ita]} { return $out }
    append out "  ita keys: [join [dict keys $ita] { }]\n"
    if {[catch {dict get $ita sliceGrid} grid]} { return $out }
    append out "  sliceGrid keys: [join [dict keys $grid] { }]\n"
    if {![catch {dict get $grid row} rows]} {
        append out "  rows: [llength $rows]\n"
        if {[llength $rows]} {
            set r0 [lindex $rows 0]
            append out "  row0 keys: [join [dict keys $r0] { }]\n"
        }
    }
    return $out
}

proc diag_escape {s} {
    set out ""
    foreach ch [split $s ""] {
        scan $ch %c code
        if {$code >= 32 && $code < 127} {
            append out $ch
        } else {
            append out [format {\u%04x} $code]
        }
    }
    return $out
}

proc serialiser_run {skillArgs} {
    lassign $skillArgs m t p
    if {$p eq ""} { set p 100 }
    set url "https://oversea.csair.com/tk/au/en/book/flights?m=$m&t=$t&p=$p"

    set triples [capture $url --seconds 30 --match "*api/shop/*"]
    set st [state]
    set out "terminal='[dict get $st terminal]'\nlastNav=[dict get $st lastNav]\nmatches=[llength $triples]\n"
    foreach t2 $triples {
        lassign $t2 u status b
        set n [string length $b]
        append out "\n=== status=$status chars=$n url=$u\n"
        if {$n > 6000} {
            append out [diag_shape $b]
            append out "[diag_escape [string range $b 0 2999]]\n...TRUNCATED ($n chars total)...\n[diag_escape [string range $b end-999 end]]\n"
        } else {
            append out "[diag_escape $b]\n"
        }
        if {$n <= 200} {
            binary scan [encoding convertto utf-8 $b] H* hex
            append out "utf8-hex: $hex\n"
        }
    }
    emit $out
}
