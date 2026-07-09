# Sprint 1.7 Summary — Vendored Interpreter (BusyBox pinning)

**Date:** 2026-07-07
**Status:** Complete — merged to main (PR #3); awaiting on-device confirmation
(the log's "Interpreter:" line + preflight's `busybox` row)

## Files Created

- `scripts/build_busybox.sh` — cross-compile static aarch64 busybox
  1.36.1 (defconfig + STATIC + SH_STANDALONE + PREFER_APPLETS, −TC),
  installs to `build/aarch64/prefix/bin/busybox`, qemu smoke test.
- `scripts/validate_busybox.sh` — 69-check qemu validation matrix
  (direct applet dispatch for every daemon invocation form, in-process
  tier under empty PATH, exec-tier PATH fall-through, ash semantics).
- `docs/sprints/sprint-1.7-spec.md`, this summary.

## Files Modified

- `src/platforms/nextui/continuity_daemon.sh` — `cd_reexec_busybox`
  (fail-open self-tested exec, loop guard, `CONTINUITY_VENDOR_SH=0`
  kill switch, `CONTINUITY_DAEMON_SELF` test hook) called at the top of
  `cd_main`; startup log now names the interpreter and the fallback
  reason.
- `src/platforms/nextui/preflight.sh` — `pf_check_busybox` (same
  self-test the daemon runs; info/warn only — never fatal).
- `src/platforms/nextui/update.sh` — `bin/busybox` in the OTA binary
  list; chmod widened to `bin/*`.
- `scripts/build_pak.sh` — bundles `bin/busybox` (warning if toolchain
  output absent), checksums entry, preservation fallback
  (`build/busybox.preserved`).
- `.gitattributes` — binary attrs for `bin/busybox` + preserved copy.
- `CLAUDE.md` — build/validation/OTA protocol updated (busybox is the
  OTA-safe binary class).
- `docs/platform/nextui-field-notes.md` — "Vendored BusyBox" section:
  fail-open invariant, applet tiers, qemu testability boundary, tc.c
  kernel-header trap, plain-vs-NOEXEC applet reality in 1.36.1.

## Tests Written

- `tests/unit/nextui/test_continuity_daemon.sh` — 6 new cases (9
  asserts): absent binary, kill switch, failed self-test, failed parse
  probe, healthy exec (subshell-exec trick verifies argv
  `ash <self> <args>` and the fake binary's rc), loop guard.
- `tests/unit/nextui/test_preflight.sh` — 4 new cases (7 asserts):
  absent=info, healthy=ok/predicts pinning, broken=warn+green run,
  kill switch=info.
- `tests/integration/test_daemon_lifecycle.sh` — real daemon re-execs
  under a real (host) busybox planted in the fake PAK; asserts the
  pinned-interpreter log line; existing SIGTERM/wait assertions prove
  same-PID exec semantics.

Suite: 30 files, 0 failures. `scripts/validate_busybox.sh` 69/69
against the shipped `build/Continuity.pak/bin/busybox`.

## Defects Found and Fixed (CI bring-up, same session)

The first CI run in the repo's history (the new
`.github/workflows/ci.yml`) surfaced three environment assumptions
that always-root, absolute-path local sessions never exercised:

1. `validate_busybox.sh` broke when given a relative binary path (the
   matrix `cd`s around; every check after the first cd failed "not
   found"). Fixed: canonicalize at entry.
2. The matrix's `ping` check asserted raw-socket success — root-only,
   and CI runners are unprivileged. Fixed: assert flag parsing (the
   device always runs as root).
3. `test_runtime_poll`'s read-only-sentinel case only executes when
   unprivileged, so it had NEVER run — and its assertion was wrong
   (`touch` on an existing owned file succeeds despite a 555 parent;
   utimensat ownership rule). Fixed: remove the sentinel so touch must
   create through the read-only dir.

Plus one diagnosability fix: `scripts/test.sh` now prints a failing
test's captured output (the CI failure was undiagnosable from the
runner log without it).

## Deviations from Spec

None — spec written alongside implementation (Fable session; approval
pending, consistent with 1.1–1.6 status).

## Open Items

- **On-device confirmation** (next OTA install): `continuity.log`
  should show `Interpreter: vendored busybox (pinned)`;
  `CONTINUITY_DIAGNOSTIC.txt` should show
  `ok busybox vendored interpreter passes self-test`.
  If either shows a fallback reason instead, the daemon is still fully
  functional on device sh — investigate at leisure, nothing is broken.
- `wget` https fallback inside `pal_is_online` now resolves to the
  vendored busybox wget under the pinned ash (TLS without certificate
  verification, reachability probe only — git does all real transfers
  with the CA bundle). Acceptable; noted for the security review pass.
- Launch-path scripts still run under device sh by design; if a fork
  ever ships a broken device ash, the enrollment UI is the remaining
  exposure (accepted — that path must have zero new dependencies).
