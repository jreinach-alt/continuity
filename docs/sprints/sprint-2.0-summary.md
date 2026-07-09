# Sprint 2.0 — Save-Format Canonicalization — Summary

**Status:** Implemented on `claude/sprint-2.0-canonicalization`;
`scripts/gate.sh full` green (37/37 current user + 37/37 unprivileged
`nobody`; CRLF + shellcheck clean; shipped-PAK integrity ok). Spec:
`docs/sprints/sprint-2.0-spec.md` (Decisions 1A quarantine + 2A
state-coverage-only).

## What shipped

One canonical repo representation of a save (`<system>/<basename>.srm`,
raw) plus ROM-anchored per-device materialization. The mapper is the only
place format logic lives; core sync phases call it. Canonicalization is
**gated**: it engages only when the loaded platform map declares
`save_name_style` AND the PAL exposes an existing `CONTINUITY_ROMS_ROOT`.
Absent either, the new functions delegate to the legacy passthrough
primitives — so every pre-2.0 test keeps its behavior unchanged.

## Files Created

- `docs/sprints/sprint-2.0-spec.md` — the approved spec.
- `scripts/migrate_repo.sh` — one-time repo canonicalization, dry-run by
  default (`--apply` to write); artifact-aware, RZIP-quarantining,
  collision-safe, idempotent.
- `tests/unit/core/test_canonical_mapper.sh` — 62 assertions: name-style
  round-trips (spaced/apostrophe/parenthesized), ROM-anchoring + heuristic
  fallback, container sniff (incl. reference-encoder fixtures), quarantine
  (rc 3), sparse skip (rc 2), `pm_repo_canonicalize`, pattern helpers.
- `tests/integration/test_canonicalization_flow.sh` — MinUI↔RetroArch
  cross-style flow over a file:// remote, `.rtc` travel, sparse (no-ROM)
  skip, two-device `.rtc` conflict preservation.
- `tests/integration/test_migrate_repo.sh` — dry-run/apply/idempotency,
  artifact carry, quarantine, state pass-through, collision skip.

## Files Modified

- `src/core/path_mapper.sh` — schema-v2 parsing (`save_name_style`,
  `save_container`); `pm_device_to_canonical` / `pm_canonical_to_device`;
  `pm_repo_canonicalize`; ROM-anchoring (`pm_rom_dir` /
  `pm_rom_match_basename` / `pm_rom_fullname`); container sniff
  (`pm_container_class`); `pm_rom_ext_strip`; and the shared save/state
  pattern helpers (`pm_save_grep_re` / `pm_state_grep_re` /
  `pm_save_or_state_grep_re` / `pm_find_saves` / `pm_find_states`).
- `src/core/change_detector.sh`, `src/core/runtime_poll.sh`,
  `src/core/boot_pull.sh`, `src/core/stale_boot.sh`,
  `src/core/conflict_handler.sh` — routed every enumeration site through
  the shared helpers (add `.rtc`; expand states to all five shapes +
  `.state.auto`); wired materialization/detection to the canonical mapper
  with rc-2 (sparse) and rc-3 (quarantine) handling.
- `tools/saves-repo/build_digest.sh` — classifier updated to match
  (`.rtc` under saves; all five state shapes), with a lockstep pointer to
  the core source of truth.
- `config/platform_maps/nextui.json` (v2: minui/raw) and
  `config/platform_maps/retrodeck.json` (v2: retroarch/raw).
- `src/platforms/nextui/pal_nextui.sh` — exposes `CONTINUITY_ROMS_ROOT`.
- `docs/design/save-format-canonicalization.md` (status → Approved),
  `docs/roadmap.md` (Sprint 2.0 status).
- `tests/unit/core/test_change_detector.sh`,
  `tests/unit/tools/test_saves_digest.sh` — extended for `.rtc` + states.

## Tests Written

Suite grew 34 → 37 files, all green in both privilege passes. New unit
mapper test (62 assertions), two new integration tests (17 + 22
assertions), plus `.rtc`/state coverage added to the change-detector and
digest tests. Container sniffing is tied to the committed
reference-encoder rzip fixtures.

## Deviations from Spec

1. **onion.json / retroarch_android.json left at schema 1.0.** Their
   `save_name_style`/`save_container` are byte-level format facts for
   platforms not yet brought up; per the "validate against vendored
   source" rule they get their v2 fields in their own bring-up sprints,
   not from memory now. They behave legacy (passthrough) meanwhile, which
   is correct. nextui + retrodeck (the Phase 2 fleet) are v2.
2. **RZIP quarantine "status ping" is the named log line.** The mapper
   emits the AC-required named `pal_log` line
   ("Compressed save skipped — set save format to uncompressed: …") but
   does not itself call `ss_notify` — the mapper stays independent of the
   sync-status module. AC2 checks for the named log line, which is
   satisfied; a UI ping can be layered in a daemon-side follow-up.

## Open Items (for the owner / follow-up)

1. **Physical-Brick re-validation before running the migration on the
   live saves repo.** 2.0's verification is the local `full` gate +
   file:// cross-style integration (no second physical device exists). Two
   on-device facts need a hardware pass first: (a) the new naming
   round-trips a real save through the migrated repo, and (b) the actual
   NextUI ROM-folder layout (`Roms/<TAG>` vs `Roms/<Display (TAG)>`).
   `pm_rom_dir` handles both forms, but confirm on hardware — a wrong
   folder name fails safe (nothing materializes) but defeats the sprint.
   See the `_rom_roots_note` in `nextui.json`.
2. **Delivery ordering (lockstep):** deploy the 2.0-aware PAK to every
   device FIRST, then run `migrate_repo.sh --apply` once from an enrolled
   full device. An old-PAK device would re-push device-native names and
   undo the migration.
3. **qemu ARM checks were skipped in this environment** (qemu-aarch64
   absent). No binaries were touched, so they are unaffected; a host/CI
   gate run with qemu present should still confirm green.
4. **Phase 3:** integrate the `continuity-rzip` codec into the PAK to lift
   the quarantine (decompress inbound / recompress for rzip-container
   devices). Codec + oracle already exist.
5. **Deferred (Decision 2A):** save-state slot canonicalization
   (`st9 ↔ state.auto`, RA bare `.state` slot-0) and restore/cross-device
   state — the save-state-sync track (S1–S3). 2.0 fixed backup coverage
   only.
