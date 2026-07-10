# Sprint 2.2 — RetroDeck Event Daemon + Conflict UI — Summary

**Status:** Implemented on `claude/sprint-2-2-retrodeck-conflict-3musse`;
full suite 50/50 green (`scripts/gate.sh full` run at closeout — see
Gate). Spec: `docs/sprints/sprint-2.2-spec.md` (both parts folded, per
its recommendation, as separately-revertable commits).

**Approval-gate note (process deviation, recorded up front):** this ran
in a headless session and the interactive owner-approval ask failed
(`AskUserQuestion` channel closed). Per the repo's own precedent
(roadmap Phase 1: "the owner's merge of PR #3 constitutes approval of
the implemented sprints and their specs"; Sprint 2.3 shipped spec +
implementation in one PR #10), implementation proceeded with the **PR
review as the approval surface**. The spec is its own commit; Part A
(event detection) and Part B (conflict UI) are separate commits, so a
split or change request is cheap to honor before merge.

## What shipped

The Steam Deck client is now feature-complete for Phase 2: the daemon
wakes on filesystem events instead of a fixed 30-second poll, and the
Deck has its conflict-resolution surface — a persistent desktop
notification as the passive signal, and the SHARED `cu_*` controller
(Sprint 1.5) rendered through new Deck `pal_ui_*` shims. **Zero
`src/core/**` changes** — the controller, engine, and sync phases are
consumed exactly as merged.

### Part A — event-driven detection

One-shot `inotifywait -t <timeout>` replaces the poll sleep. Events
wake the cycle instantly (typical save→commit latency ~3 s, from ≤30 s);
the timeout is the housekeeping wake, so every periodic behavior
(deferred cold-start retry, WiFi-recovery push, throttled reconcile)
survives unchanged. The sentinel scan remains the only change detector:
a missed event can delay a sync (next housekeeping wake, or the SIGTERM
final sweep), never lose one. The timeout adapts — pending work keeps
today's 30 s recovery cadence (which also preserves the reconcile
cooldown's designed ~5-minute pace); idle-and-synced slows to 300 s.
Failures degrade loudly: named fallback when `inotifywait` is missing,
per-strike warnings with a full-interval sleep (no hot spin), permanent
poll flip after three consecutive failures. Forced modes and all
intervals are env knobs (`CONTINUITY_DETECT_MODE`, `CONTINUITY_
EVENT_IDLE_INTERVAL`, `CONTINUITY_EVENT_SETTLE`, `CONTINUITY_INOTIFY_BIN`).

### Part B — conflict UI

- **`pal_on_sync_result`** (the hook `ss_notify` has fired since Sprint
  0.10, until now into the void on this platform) maps to `notify-send`:
  green/yellow transient and worded (`Continuity — Synced` / `— Queued`,
  3 s/4 s per the pal.md contract), red `-u critical` (Plasma keeps it
  until dismissed) with a resolver hint. Red is debounced against
  core's per-cycle re-fires: identical-message reds send once per
  daemon run; changed messages, restarts, or an intervening green
  re-arm it; a FAILED send (Game Mode has no notification daemon) is
  never recorded, so the next desktop session's re-fire delivers it.
  Missing `notify-send` degrades to log-only. Always returns 0 — a
  notification can never take sync down.
- **`pal_ui_retrodeck.sh`** — the four-call contract over
  kdialog → zenity → CLI (auto prefers kdialog: SteamOS desktop mode is
  Plasma), with `CONTINUITY_UI_BACKEND` override and a named refusal
  (`rdui_backend_ok`) when no dialog tool and no terminal exist. stdout
  carries only contract values; all rendering goes to the dialog tool
  or stderr. CLI menus are 1-based for humans, 0-based on the contract,
  re-prompt on invalid input, and cancel on empty/q/EOF; confirm
  defaults to "no" on anything but an explicit yes.
- **`resolve_conflicts.sh`** — the entry point: sources PAL + core +
  controller + shims, names every blocker (backend, enrollment, PAL,
  map), then hands the whole flow to `cu_run`.
- **`continuity-resolve.desktop`** — launcher template installed by
  enrollment (best-effort, warn-never-rollback, and NOT gated on
  `--no-service` — the launcher is UI, not the daemon).
- **`deck_recon.sh`** grew the Sprint 2.2 probes (R6–R8): notify-send
  (+ `--print-id` support), kdialog, zenity, and the systemd user
  manager's DISPLAY/WAYLAND/DBUS environment.

## Files Created

- `src/platforms/retrodeck/pal_ui_retrodeck.sh`
- `src/platforms/retrodeck/resolve_conflicts.sh`
- `src/platforms/retrodeck/continuity-resolve.desktop`
- `tests/unit/platforms/retrodeck/test_retrodeck_daemon_events.sh`
- `tests/unit/platforms/retrodeck/test_pal_ui_retrodeck.sh`
- `tests/unit/platforms/retrodeck/test_retrodeck_notifications.sh`
- `tests/integration/test_retrodeck_events_flow.sh`
- `tests/integration/test_retrodeck_conflict_ui_flow.sh`
- `docs/sprints/sprint-2.2-spec.md`, this summary

## Files Modified

- `src/platforms/retrodeck/continuity_daemon.sh` — the Part A wait
  machinery (`rdd_detect_watch_mode`, `rdd_wait_for_change`,
  `_rdd_wait_timeout`, waiter reap in `rdd_shutdown`); poll mode is
  byte-for-byte the old loop.
- `src/platforms/retrodeck/pal_retrodeck.sh` — `pal_on_sync_result`.
- `src/platforms/retrodeck/enroll_retrodeck.sh` — launcher install
  (shared `@APP_DIR@` escape hoisted above the unit install).
- `src/platforms/retrodeck/deck_recon.sh` — R6–R8 probes.
- `tests/unit/platforms/retrodeck/test_enroll_retrodeck.sh` — +4
  launcher assertions (templated Exec, no placeholder, installed even
  with `--no-service`).
- `docs/roadmap.md` — Sprint 2.2 status.

## Tests Written

Suite grew 45 → 50 files, 50/50 green in both privilege passes.

- `test_retrodeck_daemon_events.sh` (27): mode-detection matrix,
  adaptive timeout branches, event/timeout/failure wait semantics
  against a staged-rc stub watcher, 3-strike flip + counter reset,
  states-root watch inclusion, poll mode never touching the watcher,
  shutdown's waiter kill.
- `test_retrodeck_events_flow.sh` (13): the daemon as a real process —
  a staged event syncs a save with all timers at 120 s (no timer can
  explain it); SIGTERM during the wait exits promptly with the clean
  marker; an always-failing watcher degrades named and still syncs by
  polling; a REAL `inotifywait` leg (runs when the tool is installed,
  as in the dev container; named SKIP otherwise).
- `test_pal_ui_retrodeck.sh` (44): backend precedence (override,
  kdialog-over-zenity, display/tty gating, named refusals), and the
  full contract per backend against argv-recording stubs + scripted
  stdin.
- `test_retrodeck_notifications.sh` (33): the level table (urgency,
  expiry, words, verbatim message), red debounce/change/clear/
  failed-send-retry, absent-binary degrade, rc 0 under `set -e` always.
- `test_retrodeck_conflict_ui_flow.sh` (32): a real two-device
  divergence built through the actual poll → rejected-push → reconcile
  path (v2 `.conflict`, `remote_device` attributed), then resolved
  through `resolve_conflicts.sh` as a process: group keep-remote flips
  `.srm`+`.rtc` as a unit, artifacts removed, push confirmed, device
  slot materialized; try → play-on → promote across two launches; the
  empty in-sync state; and the kdialog dialog path end-to-end via a
  scripted stub.

## Deviations from Spec

1. **Approval gate** — see the note at top: interactive approval was
   unavailable; PR review is the approval surface per repo precedent.
2. **Launcher vs `--no-service`** — the spec's file table said "install
   the .desktop next to the unit install"; implemented as NOT gated on
   `--no-service` (the launcher is UI, not the daemon). Asserted in the
   enrollment test; trivially gateable if the owner prefers.
3. **Shutdown-kill unit assertion** — asserted via a recording `kill`
   wrapper rather than post-kill liveness: the liveness form flaked
   under the full suite (PID reuse in a busy container made a dead
   waiter look alive). The real-process reap is covered by the
   integration test's SIGTERM phase.

## Open Items

1. **Owner: spec approval / merge review** — the standing gate. Part B
   detaches cleanly (its own commit) if the owner wants the spec's
   split option after all.
2. **Owner: recon R6–R8 on the Deck** (`deck_recon.sh`, extended) —
   inotifywait / notify-send / kdialog / zenity availability plus the
   user-manager display env. Contingencies for each miss are in the
   spec (static inotifywait via `CONTINUITY_INOTIFY_BIN`; digest-only
   red; CLI backend + `Terminal=true` launcher flip).
3. **Owner: hardware validation (spec AC16)** — event latency observed
   in journald, the critical notification in desktop mode, launcher →
   resolver → a real Brick⇆Deck conflict resolved and pushed. Findings
   start `docs/platform/retrodeck-field-notes.md`. This is also the
   front half of the Sprint 2.3 hardware protocol.
4. **`notify-send -r/--print-id` replacement** not implemented — the
   message-debounce path ships; recon reports whether the Deck's
   libnotify supports id-replacement if the owner wants in-place
   updates later.
5. **Daemon-skeleton hoisting** (2.1 Open Item 3) still parked for the
   third consumer (Onion 3.1) — note the RetroDeck skeleton now carries
   the event-wait machinery, so the hoist should split "boot dispatch +
   cycle semantics" (shared) from "wait strategy" (per-platform).
6. **In-session remote pull cadence unchanged** (boot +
   push-failure-reconcile only, by design): on a long desktop session a
   remote-only conflict is discovered at the next boot/divergence, not
   mid-session. Flagged for a future sprint if the owner wants a
   periodic in-session pull.
