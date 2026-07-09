# Sprint 1.7 — Vendored Interpreter (BusyBox pinning, fail-open)

**Status:** Complete — merged to main (PR #3, 2026-07-07)
**Date:** 2026-07-07
**Dependencies:** Sprint 1.6 (OTA — the delivery path for this change),
hardware-validated daemon (1.1–1.3)

## Goal

Remove the last "works on OUR busybox, unknown on THEIRS" risk class.
The test suite runs under busybox ash 1.36.1; the device runs whatever
BusyBox build its firmware shipped, and NextUI forks vary. Ship the
exact interpreter the tests run under and have the daemon pin itself to
it — with a fail-open design so a bad binary can never brick the daemon
or the launch path. This narrows the portability contract for other
NextUI-family forks: the fork only needs to boot the PAK; the PAK
brings its own userland for the daemon.

## Design

- **Binary:** `scripts/build_busybox.sh` — busybox 1.36.1, static
  aarch64, defconfig + `CONFIG_STATIC` + `CONFIG_FEATURE_SH_STANDALONE`
  + `CONFIG_FEATURE_PREFER_APPLETS`, minus `CONFIG_TC` (does not compile
  against kernel headers >= 6.8). Output: `build/aarch64/prefix/bin/busybox`
  (~2.1 MB); `build_pak.sh` ships it as `bin/busybox` with a checksums
  entry and a preservation fallback (missing toolchain output = WARNING,
  not build failure — busybox is not launch-critical).
- **Re-exec (daemon only):** at the top of `cd_main`, before any state
  is touched, `cd_reexec_busybox` self-tests the binary
  (`busybox ash -c true` + `ash -n <daemon>`) and `exec`s the daemon
  under the vendored ash (same PID — PID file and SIGTERM supervision
  semantics unchanged). Every failure path falls through to the device
  shell with a named reason logged at startup ("Interpreter: ...").
  `CONTINUITY_BB_REEXEC=1` guards against loops;
  `CONTINUITY_VENDOR_SH=0` is the kill switch.
  **launch.sh and the enrollment UI never use the vendored interpreter**
  — bootstrap/recovery stays device-native.
- **Applet pinning:** SH_STANDALONE makes the vendored ash resolve bare
  command names to its own applets (no PATH symlink farm — exFAT has no
  symlinks). NOEXEC/NOFORK applets run in-process; plain applets
  (grep/sed/tr/cat/cmp/wc/...) self-exec via `/proc/self/exe` (native
  on-device) and fall back to PATH lookup if that ever fails. Absolute
  paths (the bundled git) are never shadowed.
- **Preflight:** a `busybox` check runs the daemon's exact self-test so
  `CONTINUITY_DIAGNOSTIC.txt` predicts the daemon's decision. Absent =
  info, broken = warn (never fatal — fail-open), healthy = ok.
- **OTA:** `bin/busybox` added to the update binary list (size-differ
  probe, chmod). Explicitly OTA-safe: a torn copy fails the self-test
  and the daemon falls back to device sh.

## Acceptance criteria

1. `scripts/validate_busybox.sh <binary>` passes 69/69 under
   `qemu-aarch64-static` against the SHIPPED `bin/busybox`: every
   daemon-path invocation form via direct dispatch, the in-process
   applet tier under `PATH=/nonexistent`, exec-tier PATH fall-through,
   absolute-path passthrough, and the ash semantics the daemon leans on
   (trap TERM + backgrounded sleep + wait, set -e rc capture, local,
   read -r loops, kill -0).
2. Daemon unit tests cover all re-exec decision paths: no binary, kill
   switch, failed self-test, failed parse probe, healthy exec (argv
   verified), re-exec loop guard.
3. The lifecycle integration test re-execs the REAL daemon under a real
   busybox planted in the fake PAK and the full boot→poll→SIGTERM
   sequence passes, including the "Interpreter: vendored busybox
   (pinned)" log line and same-PID SIGTERM handling.
4. Preflight tests cover absent/healthy/broken/disabled; broken is a
   warning, never a preflight failure.
5. Full suite green under busybox ash.

## Out of scope

- launch.sh/enrollment running under the vendored interpreter (the
  bootstrap path must have zero new dependencies).
- Replacing `show2.elf`, git, or any non-BusyBox device tool.
- Non-NextUI platforms (RetroDeck has a real userland; Onion gets this
  contract when its PAL lands).
