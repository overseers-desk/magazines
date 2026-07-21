#!/usr/bin/env tclsh
# cdp-client-selftest.tcl - smoke-test the cdp module.
#
# With CDP_WS_URL pointing at any plain-RFC6455 flat-CDP target (a real Chromium
# page target or the overseer relay), this sources the helper and exercises the
# API: Browser.getVersion via the generic cdp call, and evaluate {1+1}.
#
#   CDP_WS_URL=ws://127.0.0.1:9333/devtools/page/XXXX tclsh cdp-client-selftest.tcl
#
# Prints the product version and the evaluate result; exits non-zero on mismatch.
# With no CDP_WS_URL it runs an offline frame round-trip check on a multibyte
# payload instead (mask then unmask must reproduce the original bytes).

::tcl::tm::path add [file dirname [file normalize [info script]]]
package require cdp

# Offline path (a live target unavailable): a frame round-trip on a multibyte
# payload. Mask a client frame with the cdp module's own framing, then unmask it
# here (mirroring an RFC6455 server) and confirm the bytes survive. Self-
# contained: no socket, no cross-repo source.
proc unmask_client_frame {framed} {
    binary scan $framed cucu b0 b1
    set len [expr {$b1 & 0x7f}]
    set off 2
    if {$len == 126} {
        binary scan [string range $framed 2 3] Su len
        set off 4
    } elseif {$len == 127} {
        binary scan [string range $framed 2 9] Wu len
        set off 10
    }
    set mask [string range $framed $off [expr {$off+3}]]
    incr off 4
    set payload [string range $framed $off [expr {$off+$len-1}]]
    binary scan $mask cu4 mb
    binary scan $payload cu* pb
    set out {}
    set i 0
    foreach byte $pb { lappend out [expr {$byte ^ [lindex $mb [expr {$i%4}]]}]; incr i }
    return [encoding convertfrom utf-8 [binary format cu* $out]]
}

if {![info exists ::env(CDP_WS_URL)] || $::env(CDP_WS_URL) eq ""} {
    set sample "hello 世界 \U0001F600 mask round-trip"
    # Reach the (unexported) framing method by mixing the class into a bare
    # object and exporting the method on that object only.
    set probe [oo::object new]
    oo::objdefine $probe {
        mixin cdp::Client
        export FrameMasked
    }
    set framed [$probe FrameMasked $sample]
    set got [unmask_client_frame $framed]
    $probe destroy
    if {$got eq $sample} {
        puts "offline frame round-trip OK (multibyte preserved): $got"
        exit 0
    }
    puts stderr "FAIL: round-trip mismatch\n  in : $sample\n  out: $got"
    exit 1
}

set cdp [cdp::connect]

set ver [$cdp cdp Browser.getVersion]
set product [dict get $ver result product]
puts "Browser.getVersion product: $product"

set two [$cdp evaluate {1+1}]
puts "evaluate {1+1} = $two"

# A multibyte/UTF-8 round-trip through evaluate (the Python skills carry emoji).
set emoji [$cdp evaluate {"hi \u{1F600} 世界"}]
puts "evaluate emoji = $emoji"

$cdp close

if {![string match "*Chrom*" $product]} {
    puts stderr "FAIL: product does not look like Chrome/Chromium"
    exit 1
}
if {$two != 2} {
    puts stderr "FAIL: 1+1 did not return 2"
    exit 1
}
puts "SMOKE OK"
