# Chromium process management: observed facts and the misreadings they correct

This records how Chromium, as installed on this machine, manages its own processes: how a launch maps to PIDs, where the browser sits in the cgroup tree, how it is reached by a signal, and when it is reparented. It is a description of reality, not of any one program that drives Chromium. Anyone writing or revising such a program can hold their design against these facts and see for themselves where it agrees or disagrees.

The second half lists readings that are easy to form from partial observation and that are false. They are stated plainly so that a reader who holds one can recognise it.

## Observation basis

Live process trees and cgroup-v2 membership read from `/proc` during headless one-shot renders, on snap Chromium 147 (revision 3423), user-data-dir `~/snap/chromium/common/chromium`. One contrasting data point (the `.deb` scope name in F8) is from a prior recorded test of an upstream xtradeb build. Every fact below names what was seen; re-verification needs only `cat /proc/<pid>/cgroup` and the `PPid:` line of `/proc/<pid>/status` against a running render.

## Facts

**F1. The launch is an exec chain that preserves one PID.** A launcher forks one child and execs `chromium`; on snap that entry execs onward through `snap run` and `snap-confine` into `/snap/chromium/<rev>/usr/lib/chromium-browser/chrome`. The PID assigned at the fork is kept across every exec in the chain. No intermediate launcher-stub process survives alongside the browser. Observed: launcher PID *N*, browser one PID later running `…/chrome`, with `PPid` equal to *N*, and nothing between them in the tree.

**F2. snapd puts the browser in its own transient systemd user scope.** The scope is `snap.chromium.chromium-<uuid>.scope` (a fresh UUID each launch) under `user@<uid>.service/app.slice`. Under cgroup-v2 a process is in exactly one cgroup; the browser and all its child processes share this single scope. Observed: every `chrome` process of a render in `…/app.slice/snap.chromium.chromium-<uuid>.scope`.

**F3. cgroup membership is independent of parentage and of PID.** Entering the snap scope changes neither the browser's PID nor its parent. While its launcher lives, the browser stays the launcher's direct child and a member of the launcher's process group, even though it sits in a different cgroup from the launcher. Observed: browser in the `snap.chromium…` scope, launcher in the terminal's `vte-spawn…` scope, yet the browser's `PPid` is the launcher's PID and the browser's PGID is the launcher's PGID.

**F4. Signals are delivered by PID and by process group, never by cgroup.** A per-PID SIGTERM or SIGKILL to the browser's PID, or a signal to the shared process group, reaches the browser whatever cgroup it occupies. The cgroup boundary takes no part in signal delivery. Follows from F1–F3 and POSIX signal semantics, and is consistent with `timeout`, which on expiry signals the same PID it exec'd.

**F5. Reparenting to the user service manager happens only when the launcher exits first.** If the launcher dies while the browser still runs, the browser is reparented to the nearest subreaper, `systemd --user` (the `user@<uid>.service` manager), and its `PPid` becomes that manager's. A browser killed, or self-exiting, while its launcher is still alive is never reparented. Observed: a one-shot render keeps `PPid` equal to its launcher throughout; a prior recorded instance of a persistent browser left running after its launching script returned had `PPid` equal to `systemd --user` nine minutes later.

**F6. Only the main process carries the launch flags.** The flags given at launch (for example `--dump-dom`, `--remote-debugging-port=<n>`, `--user-data-dir=…`) appear on the main process. The children carry `--type=zygote|gpu-process|utility|renderer`, plus a crashpad handler, and do not repeat a launch-distinguishing flag such as `--remote-debugging-port`. A search keyed on a launch flag therefore selects the main process alone, never the children. Observed in the full process list of a render.

**F7. The main process's death reaps the children only on a graceful exit, not reliably under SIGKILL.** When the main browser exits in an orderly way (it took SIGTERM and ran its own shutdown), it brings its child processes down with it. Under SIGKILL there is no orderly shutdown, and whether a child then dies depends on whether that child asked the kernel for a parent-death signal (`PR_SET_PDEATHSIG`). Renderers generally arrange this; the GPU, network, utility, and crashpad helpers generally do not. So a hard-killed main process can leave those helpers orphaned, reparented to the user service manager, still holding profile resources. This is why mature launchers (Puppeteer, Playwright, chrome-launcher) signal the whole process group rather than the main process alone. (Research-derived, not observed firsthand here. To verify: SIGKILL the main process of a throwaway launch and check whether any `--type=` process survives.)

**F8. The scope name is set by packaging, and the two packagings differ.** Snap names the scope `snap.chromium.chromium-<uuid>.scope` (snapd device-cgroup confinement, UUID-keyed). An upstream `.deb` build instead self-registers `app-org.chromium.Chromium-<pid>.scope` (Chromium's own cooperation with systemd-oomd, PID-keyed). A machine shows one or the other by which build is installed, not both. Observed: the snap name on this machine; the `app-org.chromium…` name from the prior `.deb` test.

## Anti-facts

Each item is a belief that observation can suggest and that is false, paired with the fact that corrects it.

**A1. "Chromium re-execs into its own systemd scope, so a signal aimed at the launched process cannot reach the browser."** False. The scope is a cgroup, and cgroups do not intercept signals (F4). The browser keeps the PID it was launched with (F1) and stays reachable by it. Whatever defeated an earlier kill, the scope was not the cause.

**A2. "Entering the scope is what defeated a direct per-process terminate."** False, and self-contradicting: a direct per-process terminate is itself a per-PID signal, and per-PID signals reach the browser regardless of scope (F4). A per-PID terminate fails for a different reason, a stale PID: a persistent browser reparents when its launcher exits (F5), and a kill aimed at the PID captured at launch, or routed through a launcher that has since exited, lands on nothing. The remedy is to name the browser by a stable attribute at kill time (F6), not to defeat the cgroup.

**A3. "The deployed (snap) browser lives in `app-org.chromium.Chromium-<pid>.scope`."** False on a snap install. That is the `.deb` name (F8). Snap uses `snap.chromium.chromium-<uuid>.scope`. A stop or match keyed on the `.deb` name does nothing on snap, because no such scope exists there.

**A4. "A one-shot render is exposed to the same orphaning as a persistent session."** False. Orphaning needs the launcher to exit while the browser runs (F5). A one-shot render is killed or self-exits while its launcher is still its parent, so the launcher's signal always reaches it (F3, F4) and it is never reparented. The orphan belongs to a browser that outlives its launcher, the persistent debugging-session case, not the one-shot dump.

**A5. "Stopping the scope is necessary to kill the browser."** Overstated as put, but with a real core. The main process is reachable by a per-PID kill whatever its scope (F4), so the scope is not needed to reach it. What a whole-group action (a scope stop, or a `killpg`) adds is removing every process in the group at once, including the helpers that carry no launch flag (F6). After a graceful exit that is redundant, because the main process reaps its own children (F7). After a hard SIGKILL it is not redundant, because the helpers can orphan (F7). So a whole-group reap is the safe form of the SIGKILL fallback, and on snap it has to key on the snap scope name to do anything (F8, A3).
