# Sprint 2.3 — Cross-Device Integration (Brick ⇆ Deck) — Summary

**Status:** Implemented on `claude/sprint-2.3-cross-device-v004i1`
(rebased onto main after Sprint 1.5 merged). `scripts/gate.sh full` green.
Spec: `docs/sprints/sprint-2.3-spec.md` (owner decisions: drive via core
phases with the real PALs sourced; include the cross-format conflict
collapse; full hardware protocol).

## What shipped

The end-to-end proof of Sprint 2.0's canonicalization: one automated
integration test drives BOTH real PALs (`pal_nextui.sh` +
`pal_retrodeck.sh`) against ONE shared `file://` remote, and one owner-run
hardware protocol reproduces it on the two physical devices. No core, PAL,
or daemon code changed — the existing engine + two real PALs were
exercised as-is.

The test proves, deterministically (no timing-dependent assertions):
- **Brick → Deck (minui ⇒ canonical ⇒ retroarch):** a MinUI-named
  `Super Metroid (USA).sfc.sav` becomes the single canonical
  `snes/Super Metroid (USA).srm` and materializes on the Deck under its
  RetroArch-native `.srm` name, byte-identical; the `.rtc` sibling travels
  with its game; a Brick-only game (no Deck ROM) is NOT materialized on the
  Deck (per-device sparse sync).
- **Deck → Brick (retroarch ⇒ canonical ⇒ minui):** an RA-named
  `Zelda Minish Cap (USA).srm` becomes canonical and materializes on the
  Brick under its MinUI-native `Zelda Minish Cap (USA).gba.sav` name — the
  ROM extension embedded, reconstructed from the Brick's own ROM — 
  byte-identical; a Deck-only PS1 game (canonical system `ps1`, no Brick
  ROM) is NOT materialized on the Brick (reverse sparse).
- **No device-native name ever leaks into the repo** (canonical `.srm`
  only, both directions).
- **Cross-format divergence collapses to ONE identity:** the Brick's
  `.sav` and the Deck's `.srm` for the same game both canonicalize to
  `snes/Super Metroid (USA).srm`, so a genuine divergence yields exactly
  ONE `.conflict` (v2 `identity` = `snes/Super Metroid (USA)`,
  `class` = `srm`) and exactly ONE `.local`, with bytes preserved on both
  sides (`.local` = the Brick's divergent bytes, canonical = the Deck's).

## Design

Each device runs in its own subshell that sources exactly ONE real PAL +
the core modules and drives the core sync phases directly (`cs_run`,
`rp_run`, `bp_run`, `se_pull`, `ch_handle_pull_conflict`). Subshell
isolation is what lets two real PALs (which define the same `pal_*`
symbols) coexist in one test; all persistent device state lives on disk
(each device's own repo clone + saves/roms trees + the shared remote),
exactly like two physical devices.

Real-PAL wiring: the Brick uses `pal_nextui.sh` with env-overridden paths
and `CONTINUITY_PAK_DIR=$PROJECT_ROOT` (real `nextui.json` map, system
git kept via the PAL's existence-gated git-exec wiring); the Deck uses
`pal_retrodeck.sh` deriving its paths from a live `retrodeck.json` (via
`CONTINUITY_RD_CONF`) with `CONTINUITY_APP_DIR=$PROJECT_ROOT` (real
`retrodeck.json` map). Daemon lifecycle (boot dispatch, poll loop,
SIGTERM) is deliberately NOT re-tested here — it is covered by
`test_daemon_lifecycle.sh` and `test_retrodeck_flow.sh` Phase 6.

## Files Created

- `docs/sprints/sprint-2.3-spec.md` — the approved spec.
- `tests/integration/test_cross_device_flow.sh` — 35 assertions across
  three parts (Brick→Deck, Deck→Brick, cross-format conflict collapse).
  Passes under `busybox ash`, the system shell, and unprivileged `nobody`.
- `docs/platform/cross-device-validation.md` — owner's hardware protocol
  (enroll both to one repo; both directions with `sha256sum` byte-match;
  both sparse checks; the cross-format conflict collapse; log / on-repo /
  GitHub-UI verification).
- `docs/sprints/sprint-2.3-summary.md` — this file.

## Files Modified

None under `src/**`, `config/**`, or `scripts/**`. Read-only exercise of
the existing engine and the two real PALs, as scoped.

## Tests Written

`tests/integration/test_cross_device_flow.sh` (new). Auto-discovered by
`scripts/test.sh` (globs `tests/integration/*.sh`). Full suite:
`scripts/gate.sh full` green — current user, unprivileged `nobody`, and
shipped-PAK integrity (qemu checks skipped: `qemu-aarch64-static` not
installed in this environment, same as prior sprints here).

## Deviations from Spec

- None material. One spec-time path was corrected during implementation:
  the PS1 canonical repo path is `ps1/…` (canonical system name), not the
  Deck's local `psx/…` folder name — the test asserts the canonical `ps1`
  path and PS1 bytes accordingly. This is the mapper behaving per Decision
  2 of the canonicalization spec (repo uses canonical system names), not a
  change to it.

## Open Items

- **Bugs found:** none. Every canonicalization, sparse-materialization, and
  cross-format conflict-grouping claim held on the first green run once the
  test's own busybox `find -newer` mtime ordering was fixed (sleep BEFORE
  writing new saves, per the retrodeck-flow pattern) — a test-side issue,
  not an engine bug.
- **Hardware validation is owner-run** and still pending: execute
  `docs/platform/cross-device-validation.md` on the real Brick + Deck and
  attach the `sha256sum` pairs + screenshots to close Sprint 2.3's
  hardware gate. The headless proof is complete; the on-device proof is
  the owner's to run (no device access here).
- Roadmap Sprint 2.3 entry can be marked implemented (pending the
  owner-run hardware pass) once this branch merges.
