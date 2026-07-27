# serialiser-tray.tcl - standalone-host tray icon: one icon per run process,
# alive exactly while the run holds (or queues for) the shared Chromium profile.
# Presence answers the one desktop question the lock creates: "is an agent using
# the browser profile right now, may I open Chromium myself?" Absence means idle.
# Two looks: an amber ring while waiting (queued for the lock, or pacing the
# inter-run gap), a teal disc while the browser is actually being driven, with
# the skill and its current query-stripped page in the tooltip. When several
# runs queue, each process shows its own icon, so the tray shows the queue.
#
# Host machinery, like the diagnostics log: it lives in the master interp only
# and adds nothing to the safe-interp verb surface. The overseer-delegated path
# never sources this file's callers into action (the overseer's own UI is the
# status surface there), and every proc is a silent no-op unless init succeeded.
#
# Drawing needs Tk 9's built-in `tk systray` / `tk sysnotify` (TIP 325; X11 tray
# on Linux, menu-bar item on macOS). init probes for it and for a display, and
# returns 0 without complaint when either is absent, so a Tcl 8.6 or headless
# run behaves exactly as if this file did not exist.

namespace eval ::tray {
    variable On 0
    variable Label ""
    variable Wake 0
    # 22x22 PNGs, embedded so the plugin ships no separate asset files.
    variable PngActive {
        iVBORw0KGgoAAAANSUhEUgAAABYAAAAWCAYAAADEtGw7AAAAR0lEQVR4nGNgGH5gWsd/rJjq
        BlJkAbGGkmQ4qYYSZTi5hhI0nCYGU2ooTsNHDR7CBtMsudHUYEoMJwrQxFBSDScbUN3AwQoA
        8EMdH9IP1AIAAAAASUVORK5CYII=
    }
    variable PngWait {
        iVBORw0KGgoAAAANSUhEUgAAABYAAAAWCAYAAADEtGw7AAAAV0lEQVR4nGNgGHbg/wKG/9gw
        1Q2kyAJiDSXJcGI0kmw4qS4hWj05YUdQD7mRQlAfJUlp1GDSDaZq5JHrapLTMVUzCDbFVMnS
        +DTSvYQjyVBiLCDbwEELAMm1ePBghZXvAAAAAElFTkSuQmCC
    }
}

# Probe and, when possible, raise the icon (in the waiting look). Returns 1 when
# the icon is up, 0 otherwise; failure is silent by design, since a machine
# without Tk 9 or a desktop simply has no tray to draw on. On success the cdp
# module is switched to pumped reads so the Tcl event loop keeps servicing the
# icon (tooltip, repaints) through pacing sleeps and CDP waits.
proc ::tray::init {} {
    variable On
    if {$On} { return 1 }
    if {![::tray::Usable]} { return 0 }
    if {[catch {
        wm withdraw .
        image create photo ::tray::ImgActive -data [string map {" " "" "\n" ""} $::tray::PngActive]
        image create photo ::tray::ImgWait   -data [string map {" " "" "\n" ""} $::tray::PngWait]
        tk systray create -image ::tray::ImgWait -text "browser-serialiser"
        cdp::pumpMode 1
    }]} { return 0 }
    set On 1
    return 1
}

# Waiting look: the run holds no browser yet. $reason names which wait it is
# (queued for the lock, or pacing the inter-run gap).
proc ::tray::waiting {reason} {
    variable On
    if {!$On} return
    catch {tk systray configure -image ::tray::ImgWait -text "browser-serialiser: waiting, $reason"}
}

# Active look: the browser is up and $label (skill ref, or render URL) drives it.
proc ::tray::active {label} {
    variable On
    variable Label
    if {!$On} return
    set Label $label
    catch {tk systray configure -image ::tray::ImgActive -text $label}
}

# Live tooltip update as the skill navigates. Callers pass the query-stripped
# URL (serialiser::LogUrl), so no session token reaches the tooltip.
proc ::tray::page {url} {
    variable On
    variable Label
    if {!$On} return
    catch {tk systray configure -text "$Label @ $url"}
}

# True when a display is reachable and Tk 9 loads; the withdrawn root window is
# raised as a side effect. Silent on failure, so callers no-op cleanly.
proc ::tray::Usable {} {
    if {$::tcl_platform(os) eq "Linux"
        && !([info exists ::env(DISPLAY)] && $::env(DISPLAY) ne "")
        && !([info exists ::env(WAYLAND_DISPLAY)] && $::env(WAYLAND_DISPLAY) ne "")} {
        return 0
    }
    if {[catch {package require Tk 9}]} { return 0 }
    catch {wm withdraw .}
    return 1
}

# Desktop notification; used for the login-wall message, since the icon dies
# with the process and cannot carry it. Deliberately independent of init: the
# overseer-delegated path fires this too (a login wall needs the user's hand
# whichever host hit it), with no icon ever shown there. The short pump lets
# the notification reach the desktop before the caller exits.
proc ::tray::notify {title msg} {
    variable On
    if {!$On && ![::tray::Usable]} return
    catch {
        tk sysnotify $title $msg
        after 300 [list set ::tray::Wake 1]
        vwait ::tray::Wake
    }
}

proc ::tray::done {} {
    variable On
    if {!$On} return
    catch {tk systray destroy}
    set On 0
}

# Sleep $ms without starving the icon: loop-serviced when the icon is up, the
# host's plain blocking sleep otherwise.
proc ::tray::sleep {ms} {
    variable On
    if {!$On} {
        after $ms
        return
    }
    variable Wake
    after $ms [list set ::tray::Wake 1]
    vwait ::tray::Wake
}
