# Sprints 1.1–1.3 — QA + Defect-Fix Summary

**Status:** Complete (QA pass over pre-existing implementation)
**Date:** 2026-07-06

The daemon code for Sprints 1.1–1.3 was implemented in a prior session
(commit `2764236`) ahead of spec approval and without tests, and had never
executed on hardware (the Tool PAK launch path was broken until the canary
test confirmed execution — see `docs/design/pak-launch-failure-findings.md`).
This pass QA'd that implementation against the three sprint specs, fixed
the defects found, and added the missing test coverage. It also applied
the post-canary launch.sh observability fix.

## Defects Found and Fixed

| # | Severity | Defect | Fix |
|---|----------|--------|-----|
| 1 | **P0** | Every core phase call in the daemon (`cs_is_cold_start`, `cs_run`, `sb_is_stale`, `sb_run`, `bp_run`, `rp_run`, `sb_mark_clean_shutdown`) was made **without the required `repo_dir` argument**. `cs_is_cold_start ""` tests `/.continuity/sentinel` (never exists) → every boot dispatched to cold start against an empty path; every poll cycle errored. | All phase calls now pass `$CONTINUITY_REPO_DIR` / the dispatch parameter. Pinned by unit tests asserting the argument value received by each phase. |
| 2 | **P0** | `pal_nextui.sh` hardcoded the PAK at `/mnt/SDCARD/Tools/Continuity.pak/` — **missing the `tg5040` platform directory** — so `CONTINUITY_GIT_BIN` and the platform-map path pointed at nonexistent files and `pal_init` failed on every boot even when enrolled. | Both paths now derive from `CONTINUITY_PAK_DIR` (exported by the daemon from its own location; Brick default as fallback). |
| 3 | **P1** | Fresh-enrollment boots skipped `pal_validate` and `pm_load_platform_map` entirely (the deferred-init branch never re-ran them after enrollment), so the first sync after enrollment ran with no platform map. | `cd_main` now has a single unconditional init block (pal_init → pal_validate → se_init → pm_load_platform_map) after the enrollment check, each step fatal-with-cleanup on failure. |
| 4 | **P1** | Normal boot never consumed the clean-shutdown marker (spec 1.2 requires it), so after the first clean shutdown, every subsequent crash was misclassified as a normal boot and stale recovery never ran. | `cd_boot_dispatch` calls `sb_clear_shutdown_marker` on the normal-boot path. Pinned by unit test. |
| 5 | **P1** | `cd_boot_dispatch` swallowed phase exit codes (spec 1.2 AC 5/8-11: codes must propagate; caller logs and continues). | Dispatch returns the phase's code; `cd_main` captures it and logs a warning without exiting. |
| 6 | **P2** | Bare `se_init`/`pm_load_platform_map`/`sb_mark_clean_shutdown` calls under `set -e`: a failure either killed the daemon with no log (in `cd_main`) or aborted the SIGTERM handler before PID cleanup (in `cd_shutdown`). | All guarded with explicit error handling; the shutdown handler now always reaches `cd_remove_pid` and `exit 0`. |
| 7 | **P2** | The auto.sh hook line left the daemon attached to the boot shell's stdio (git output leaked to the MinUI console; risk of blocking on a closed descriptor). | Hook line now fully detaches: `</dev/null >/dev/null 2>&1 &`. |
| 8 | **P3** | `launch.sh` gated all debug output behind `CONTINUITY_DEBUG`, which nothing on the device can set — a failed launch would have been invisible again. | Unconditional one-line breadcrumb appended to `<PAK>/launch.log` on every launch; xtrace remains behind `CONTINUITY_DEBUG`. |

## Files Modified

- `src/platforms/nextui/continuity_daemon.sh` — defects 1, 3, 4, 5, 6; added
  test hooks (`CONTINUITY_PID_FILE`/`CONTINUITY_POLL_INTERVAL` env overrides,
  `CONTINUITY_DAEMON_NO_MAIN` source guard).
- `src/platforms/nextui/pal_nextui.sh` — defect 2.
- `src/platforms/nextui/launch.sh` — defects 7, 8; `CONTINUITY_HOME` /
  `CONTINUITY_SD_ROOT` overridable for tests.
- `build/Continuity.pak/` — rebuilt via `scripts/build_pak.sh` with all of
  the above.
- `docs/sprints/sprint-1.{1,2,3}-spec.md` — status → "Implemented — pending
  user approval"; QA-correction notes (including the Sprint 1.1 per-PAK
  `auto.sh` premise, which does not exist in NextUI).
- `docs/roadmap.md` — Sprint 1.1–1.3 statuses updated.

## Tests Written

- `tests/unit/nextui/test_continuity_daemon.sh` — 51 assertions against the
  sprint acceptance criteria: PID lifecycle (live/stale/garbage/absent),
  module loading (happy path + missing-module exit/PID cleanup), enrollment
  check (enrolled / no setup.json / fresh success / failure), boot dispatch
  (phase selection, repo_dir propagation, marker consumption, rc
  propagation), shutdown marker logic (clean / push-success / push-failure /
  offline).
- `tests/unit/nextui/test_launch_sh.sh` — 16 assertions: hook install with
  pre-existing auto.sh preserved, stdio-detached hook line, idempotency,
  breadcrumb accumulation, first-run and status-run show2 messages.
- `tests/integration/test_daemon_lifecycle.sh` — 14 assertions: the real
  daemon as a background process against a real git remote — normal-boot
  dispatch, marker consumption, poll-loop push of a changed save,
  duplicate-instance refusal, SIGTERM → final push → clean marker → PID
  cleanup → exit 0.

Full suite: **27 test files, 0 failures**, all under `busybox ash`.

## Deviations from Spec

- Sprint 1.1 Part 1 (per-PAK `auto.sh`) replaced by launch.sh-installed
  global `$USERDATA_PATH/auto.sh` hook — NextUI has no per-PAK hook
  (see spec addendum).
- Sprint 1.1 Part 7: git cross-compile uses plain `gcc-aarch64-linux-gnu`
  + static deps, not the Docker toolchain.
- Sprint 1.3: constant named `CONTINUITY_POLL_INTERVAL`, env-overridable
  (tests run at 1s).
- `cd_check_enrollment` no longer re-inits PAL/sync-engine itself; the
  unified init block in `cd_main` covers both enrollment paths.
- Sprint 1.4's WiFi-recovery push already exists in the poll loop (carried
  over from the pre-QA implementation; left in place, covered by the
  shutdown/poll tests only incidentally).

## Addendum (2026-07-06, later): enrollment UX hardening after on-device hang

First on-device enrollment attempt hung indefinitely at "Enrolling
device..." and required a hard power-off. Two hang vectors existed:
git prompting for credentials on /dev/tty when the credential helper
fails (blocks forever — the device has no keyboard), and a stalled
network transfer with no timeout. Neither path produced any log.

Changes:

- `enroll_sd_card.sh` — `esd_import` now exports `GIT_TERMINAL_PROMPT=0`
  (credential prompt becomes a fast failure) and
  `GIT_HTTP_LOW_SPEED_LIMIT/TIME` (abort transfers under 1 KB/s for 30s).
  Applies to both the launch.sh and daemon enrollment paths.
- `enroll_ui.sh` (new) — enrollment supervisor for the Tool PAK:
  `esd_import` runs backgrounded with all output captured to
  `.continuity/enroll.log`; the foreground loop mirrors the newest log
  line to the screen via the show2 daemon FIFO, reads face buttons from
  the kernel joystick device (`/dev/input/js0`, 8-byte js_event records;
  tg5040 numbers B=0, Y=2, X=3 per upstream `platform.h`), and enforces a
  ~3-minute watchdog. **B cancels** (child + bundled git killed;
  `setup.json` is preserved for retry), **X/Y replays** the last 12 log
  lines one at a time, unmapped button numbers are logged so a
  differently-mapped device self-documents on first press. Missing js0
  degrades gracefully (buttons off, watchdog still active).
- `launch.sh` — enrollment branch now uses the supervisor; distinct
  end-states for enrolled / failed (last error line shown) / cancelled /
  timed out, always pointing at the log file.
- Tests: `tests/unit/nextui/test_enroll_ui.sh` (22 assertions) covers
  binary js_event decoding (presses vs releases/axis/init noise),
  cancel, watchdog, log replay, live mirroring with timestamp stripping,
  64-char display truncation, and failure-code normalization.

## Addendum 2 (2026-07-06, later still): second on-device round

Reported behavior: after the enrollment hang and a hard power-off, the
next boot auto-started the daemon (boot hook confirmed working on
hardware), but tapping the pak showed "Continuity is running." and
exited. Three defects behind that:

1. **Stale partial clone poisons enrollment** — the hard power-off left
   `.continuity/repo` partially cloned; `git clone` refuses a non-empty
   target, so every subsequent enrollment attempt failed instantly.
   Fixed: `esd_import` removes a repo dir that exists without a
   completed enrollment before cloning (pre-enrollment the local clone
   is disposable; the remote is the source of truth).
2. **Boot enrollment races WiFi** — MinUI backgrounds `wifi_init.sh`
   seconds before `auto.sh` runs the daemon, so boot-time enrollment ran
   before the network was up and exited. Fixed: `cd_check_enrollment`
   waits (bounded, default 12×5s, test-overridable) for `pal_is_online`
   before attempting enrollment.
3. **Misleading status text** — launch.sh showed "Continuity is
   running." whenever the log existed with no success line, even though
   the daemon had exited at boot. Fixed: launch.sh is now state-driven:
   not-enrolled + setup.json → supervised enrollment on the spot (WiFi
   is up by menu time, making the pak tap the natural retry path);
   not-enrolled without setup.json → staging guidance; enrolled → PID
   liveness check with "Daemon running/NOT running", last sync line, and
   last error line when dead.

Also: NextUI PAL path variables are env-defaulted for sandbox testing,
and `test_launch_sh.sh` now exercises a full real enrollment through
launch.sh (bare git remote, stale-clone precondition, supervisor UI).
Suite: 28 files green.

## Addendum 3 (2026-07-07): HTTPS transport + in-container hardware-parity validation

Attempt 4's on-device logs (delivery pipeline now clean) exposed the real
enrollment blocker: `fatal: unable to find remote helper for 'https'`.
Git's HTTPS transport is a separate helper program (`git-remote-https`)
with the build prefix baked in — the PAK only ever shipped `bin/git`.

- `build_git.sh`: switched to reachable canonical mirrors (kernel.org
  dist tarball for git, curl.se, zlib.net; Ubuntu's pristine openssl
  3.0.13 LTS orig tarball), fails the build if `git-remote-https` wasn't
  produced.
- `build_pak.sh`: ships `libexec/git-core/git-remote-http{,s}` (both
  names required — transport re-invokes the canonical `http` name; exFAT
  has no symlinks so both are real copies), a pristine Mozilla CA bundle
  from curl.se (`share/ca-bundle.crt` — deliberately NOT the build
  host's system bundle, which contains environment-specific CAs), and an
  empty `share/templates/` dir.
- `pal_nextui.sh`: exports `GIT_EXEC_PATH`, `GIT_SSL_CAINFO`,
  `GIT_TEMPLATE_DIR` at the PAK's own copies (existence-guarded,
  pre-set env wins so test sandboxes keep the system git). Added
  `CONTINUITY_FORCE_ONLINE` test/debug hook to `pal_is_online`.
- **Validation protocol change:** the exact shipped artifact
  (`build/Continuity.pak/bin/git` + its helpers) now performs a real
  HTTPS clone from live GitHub under `qemu-aarch64-static` before
  packaging. Untested cross-compiled binaries no longer ship.
- **Preflight doctor** (`preflight.sh`, run by launch.sh before
  enrollment): build stamp, clock sanity (wrong clock breaks TLS),
  module CRLF scan, git binary + https helper + CA bundle presence, an
  unauthenticated `git ls-remote` against a public repo (DNS + TCP +
  TLS + CA + clock in one probe), setup.json shape (PAT masked, only
  its length reported), joystick device, free space. Full report →
  `CONTINUITY_DIAGNOSTIC.txt` at the SD root and appended to
  enroll.log; first fatal check named on screen. One card round-trip
  now captures the complete environment.

Tests: `test_preflight.sh` (23 assertions), launch.sh preflight-gate
integration asserts. Suite: 29 files green.

## Addendum 4 (2026-07-07): HARDWARE VALIDATION — first successful enrollment

Attempt 7 succeeded on the TrimUI Brick: boot hook → daemon → network
wait → preflight (all green) → vendored git over TLS → repo cloned →
device registration committed and pushed to the user's saves repo
(`.continuity/devices/my-brick.json` visible on GitHub). The full Sprint
1.1 + 1.2 critical path is now hardware-proven; Sprint 1.3's poll loop
runs but has not yet synced a real save (the card has no SRAM files yet).

Followed by Sprint 1.6 (OTA updates — see `sprint-1.6-spec.md`) and the
Opus-era documentation package: `docs/platform/nextui-field-notes.md`
(all hardware-won facts), CLAUDE.md "NextUI Build, Validation & Delivery
Protocol" + "Model Regimen" sections, and the PAL contract addendum in
`docs/design/pal.md`.

## Open Items

1. **On-device validation checklist not yet run** (specs 1.1 D1–D6, 1.2
   D1+): needs the physical Brick — first enrollment via `setup.json`,
   cold start, reboot cycles, crash recovery.
2. **Static git binary unverified on hardware**: cross-compiles and is
   bundled, but `git clone https://` has never run on the Brick.
3. **Sprint 1.4 remainder**: log rotation and `pal_on_sync_result`
   colored-dot notifications (core `ss_notify` exists; NextUI PAL side
   not implemented).
4. **Spec approval**: 1.1–1.3 marked "Complete — merged to main (PR #3, 2026-07-07)".
