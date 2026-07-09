# Sprint 2.1 — RetroDeck PAL + Enrollment — Summary

**Status:** Implemented on `claude/sprint-2.1-retrodeck-9a0mqd`;
`scripts/gate.sh full` green (40/40 both privilege passes). Spec
approved 2026-07-09 (`docs/sprints/sprint-2.1-spec.md`); **merge is
gated on the on-device recon confirmation** (spec §Recon gate, R1–R5 —
owner runs `src/platforms/retrodeck/deck_recon.sh` on the Deck).

## What shipped

Continuity's second platform client. The Steam Deck daemon runs **on
the host as a `systemd --user` service** (settled by Flatpak-manifest
evidence: `--filesystem=host`, no `org.freedesktop.Flatpak` talk-name),
reading save/state/ROM roots from RetroDeck's own live config
(`retrodeck.json`, legacy `.cfg` fallback) because rdhome is
user-relocatable. All core sync phases run unchanged through the new
PAL — **zero `src/core/**` diffs**.

## Files Created

- `src/platforms/retrodeck/deck_recon.sh` — read-only on-device recon
  (paths, live RetroArch save settings, container sniff with the
  core-identical RZIP hex magic, nested-ROM detection, host tooling).
- `src/platforms/retrodeck/pal_retrodeck.sh` — the PAL. rd_conf-derived
  roots (env overrides win), `${XDG_DATA_HOME:-~/.local/share}/continuity/repo`,
  system git, ping→curl online check, stderr logging (journald).
- `src/platforms/retrodeck/enroll_retrodeck.sh` — desktop CLI
  enrollment: preflight (config/saves/git named errors), PAT via
  `--pat-file` or hidden prompt (argv `--pat` explicitly rejected —
  `ps` leak), core `enroll_run`, then systemd unit install + enable
  (`--no-service` to skip; failure is a warning, not a rollback).
- `src/platforms/retrodeck/continuity_daemon.sh` — daemon entry point:
  module loading, boot dispatch (cold/stale/normal), 30s poll loop with
  the NextUI daemon's cycle semantics (deferred cold start, recovery
  push, throttled in-session reconcile), SIGTERM → final sweep + push +
  conditional clean-shutdown marker. Exit 78 (EX_CONFIG) when not
  enrolled, exempted from restart thrash.
- `src/platforms/retrodeck/continuity.service` — user unit template
  (`@APP_DIR@` substituted by enrollment; `Restart=on-failure`,
  `RestartPreventExitStatus=78`).
- `tests/unit/platforms/retrodeck/test_pal_retrodeck.sh` — 14
  assertions: json/legacy derivation (spaced paths), env precedence,
  every named failure mode, validate pass, force-online, map path.
- `tests/unit/platforms/retrodeck/test_enroll_retrodeck.sh` — 29
  assertions: happy path (clone, 0600 credentials, pushed registration,
  unit templated, systemctl recorded via stub), re-run no-op,
  `--no-service`, validation failures, PAT hygiene.
- `tests/integration/test_retrodeck_flow.sh` — 30 assertions: CLI
  enrollment → cold start (RetroArch-native names → canonical repo) →
  poll (change push + RZIP quarantine + no repo leak) → clean shutdown →
  normal boot pull (materialize with ROM, sparse-skip without) → stale
  boot two-way reconcile → two-device conflict preservation
  (`.local` + `.conflict`) → the real daemon process syncing and
  handling SIGTERM.
- `docs/sprints/sprint-2.1-spec.md` — the approved spec (recon findings
  pinned to RetroDECK upstream source).

## Files Modified

- `config/platform_maps/retrodeck.json` — informational fields only:
  `saves_root` corrected to the rdhome truth (the Flatpak-data-dir
  value was wrong per upstream source), `_states_note` added
  (states arrive RZIP-compressed), `_rom_roots_note` expanded
  (content-dir sorting caveat). Also fixed `_schema_version`
  `"1.0"`→`"2.0"` — the file has carried v2 contract fields since
  Sprint 2.0 (cosmetic: the mapper keys on `save_name_style`).
- `docs/roadmap.md` — Sprint 2.1 status.

## Tests Written

Suite grew 37 → 40 files (73 new assertions), all green in both
privilege passes (`gate.sh full`). New unit-test directory
`tests/unit/platforms/retrodeck/` (first non-core unit module; the
runner's `tests/unit/**` discovery already covers it).

## Deviations from Spec

1. **Quarantine assertion moved to mapper level in the flow test.**
   Implementation surfaced a Sprint 2.0 defect (Open Item 1 below):
   every phase call site suppresses the mapper's named quarantine line.
   The flow test asserts the mapper contract (rc 3 + named line)
   directly plus the end-to-end guarantee (compressed save never
   reaches the repo).
2. **`set -u` dropped from enrollment entry point** — sourced core
   modules are not `set -u`-clean; the PAL was made `-u`-safe instead.

## Open Items

1. **Core defect (flagged, not fixed — core is out of 2.1's lane):**
   the RZIP quarantine's named log line ("Compressed save skipped — set
   save format to uncompressed") is emitted inside
   `pm_device_to_canonical`, but ALL phase call sites invoke the mapper
   with `2>/dev/null` (`runtime_poll.sh:69`, `cold_start.sh:184`,
   `stale_boot.sh:152`) and then log a **mislabeled** generic warn
   ("unknown system dir"). Net effect: on a real device, quarantine is
   observable only as the wrong message. Small core fix: distinguish
   rc 3 at the call sites (message without the suppressed stderr), or
   stop suppressing mapper stderr. Owner call on when.
2. **On-device validation (merge gate):** owner runs `deck_recon.sh`
   (R1–R5), then real enrollment + a save round-trip + a Game Mode
   session + reboot survival, per spec AC7. Findings go to
   `docs/platform/retrodeck-field-notes.md` (create on first hardware
   pass).
3. **Daemon-skeleton duplication:** the RetroDeck daemon mirrors the
   NextUI boot-dispatch/poll/shutdown semantics (~120 lines). A third
   consumer (Onion 3.1 is in flight) should trigger hoisting the shared
   skeleton into core per the two-platforms rule.
4. **R5 contingency unbuilt by design:** if the Deck lacks host git,
   the fallback (static x86_64 git under `~/.local/share/continuity/bin`)
   is a spec amendment, not yet built.
5. **Sprint 2.3 unblocked after merge + hardware pass:** Brick↔Deck
   cross-device is the payoff test and must not start before 2.1 is on
   `main` (kickoff coordination rule).
