# Sprint 2.0 — Save-Format Canonicalization

**Status:** Approved 2026-07-09 (owner green-light; Decisions 1A + 2A
below). Implements `docs/design/save-format-canonicalization.md` (now
Approved) with the `docs/design/nextui-format-matrix.md` §8 deltas and §6
prerequisites.

**Branch:** `claude/sprint-2.0-canonicalization` → PR to `main` (owner
merges). No remote CI — `scripts/gate.sh full` is the verification.

## Goal

One canonical repo representation of a save plus per-device
materialization, so "the same save" is a single repo path across
platforms. Prerequisite for RetroDeck (Sprint 2.1) and cross-device sync
(Sprint 2.3).

## Approved scope decisions

- **Decision 1A — RZIP saves: quarantine.** Sniff the 8-byte magic; raw
  saves normalize and sync; RZIP-compressed saves are quarantined with a
  named log line and status ping, repo untouched. The `continuity-rzip`
  codec exists and is oracle-validated but stays out of the PAK until
  Phase 3 (no current device produces compressed saves).
- **Decision 2A — save-state coverage only.** Back up all five state
  name-shapes plus `.state.auto` verbatim (closes the silent gap where 4
  of 5 formats are never backed up). Slot *canonicalization*
  (`st9 ↔ state.auto`, RA bare `.state` slot-0) is deferred to the
  save-state-sync track where restore semantics live.

## Design gate

`pm_local_to_repo`/`pm_repo_to_local` today translate only the system
*directory*; the filename passes through byte-for-byte. The `.srm`+`.sav`
extension pair is hard-coded across seven enumeration sites with no shared
constant. Neither `save_name_style`/`save_container`/`rom_roots` nor any
ROM-path exposure exists yet. This sprint adds the name-style + container +
ROM-anchoring layer and consolidates the enumeration sites.

**Backward-compatibility gate (bounds blast radius):** name-style
canonicalization engages **only** when the loaded platform map declares
`save_name_style` **and** the PAL exposes an existing `CONTINUITY_ROMS_ROOT`
directory. When either is absent, `pm_device_to_canonical` /
`pm_canonical_to_device` delegate to the legacy passthrough primitives
(plus a harmless RZIP-magic sniff that only ever fires on real compressed
bytes). Every existing test has neither signal, so all current
phase/flow/mapper tests keep their behavior unchanged.

## In scope

1. **Canonical repo format** — `<canonical_system>/<basename>.srm`, raw
   SRAM bytes (design Decision 1).
2. **Name-style mapper** — `pm_device_to_canonical` /
   `pm_canonical_to_device` in `path_mapper.sh`, per `save_name_style`
   (`minui` | `retroarch` | `generic`). Core sync phases call these; no
   format logic leaks into `sync_engine`/daemons. The legacy
   `pm_local_to_repo`/`pm_repo_to_local` remain as the directory
   primitives the canonical layer builds on.
3. **Platform-map schema v2** — add `save_name_style`, `save_container`,
   `rom_roots` to `config/platform_maps/*.json`; bump `_schema_version`.
   `pm_load_platform_map` parses `save_name_style`/`save_container`.
4. **ROM-anchored identity** (matrix §5) — a save basename matches either
   a ROM's full filename (MinUI style) or a ROM's ext-stripped name
   (RA/Generic). Exact match against the device ROM list is definitive;
   the 2–4-char ext-strip heuristic (matrix §2) is the repo-side fallback.
5. **ROM-gated materialization** (Decision 3) — repo→device materializes
   only where a matching ROM exists in `CONTINUITY_ROMS_ROOT` for that
   system; the native name (embedded ROM ext for MinUI) is derived from
   that ROM. Per-device sparse sync; a skipped save is an info line, not
   an error.
6. **Container sniff** — raw passthrough + RZIP detection (Decision 1A):
   real magic → quarantine + named log line + status ping, repo untouched.
7. **Single source of truth for save/state patterns** — consolidate the
   seven hard-coded enumeration sites onto shared helpers; add `.rtc` as a
   save-class sibling (same identity + conflict rules — §8.2); expand the
   state pattern set to all five shapes + `.state.auto` (Decision 2A). The
   `tools/saves-repo/` digest classifier is updated to match (it deploys
   into the user's saves repo and cannot source core — kept consistent by
   hand with a pointer comment). All git-output parsing stays `-z`/
   quotepath-immune (field notes).
8. **Migration script** — `scripts/migrate_repo.sh` with a mandatory
   dry-run: `git mv` device-native repo names → canonical basenames;
   idempotent; run once from an enrolled full device.
9. **Daemon wiring** — cold/boot/stale/poll + conflict materialization go
   through the canonical functions (no-op-equivalent when canonicalization
   is disabled).

## Acceptance criteria

1. Name round-trip `device → canonical → device` per style, for spaced,
   apostrophe, and parenthesized names (all three styles).
2. Container sniff: raw fixture syncs; RZIP fixture (real magic)
   quarantines with the named log line, repo untouched; the snes9x
   `#!s9xsnp` state classifies raw (not a container).
3. No-ROM-no-materialize both ways: ROM present → native name
   reconstructed with correct embedded extension; ROM absent → skipped.
4. Cross-style integration: a MinUI-named save from device A appears on a
   RetroArch-named device B under B's native name (file:// remote).
5. Scanner coverage: every filename shape in matrix §3/§4 is detected;
   `.rtc` travels with its game's SRAM identity; all five state shapes +
   `.state.auto` back up. Spaced + apostrophe names included.
6. `.rtc` conflict: a two-device `.rtc` divergence is preserved exactly
   like `.srm` (`.local` + `.conflict`).
7. Migration: dry-run lists exact renames and writes nothing; the real run
   renames to canonical with byte-identical content (`cmp`) and is a no-op
   on re-run.
8. All tests pass under busybox ash in both privilege passes (current user
   + `nobody`); `scripts/gate.sh full` green.

## Tests required

- **Unit** (`tests/unit/core/`): canonical mapper round-trips per style,
  container sniff/quarantine, ROM-anchored identity + heuristic fallback,
  the consolidated pattern set (every §3/§4 shape + `.rtc`). Extend the
  scanner/change-detector/boot-pull/conflict tests for `.rtc` + states.
- **Integration** (`tests/integration/`): cross-style file:// sync,
  two-device `.rtc` conflict, migration dry-run + apply.
- **Fixtures** (`tests/fixtures/`): one real-shaped file per matrix row;
  compressed rows via the reference rzip encoder oracle. Byte claims about
  the user's data are validated against the real device files already
  swept in the field notes.

## Out of scope

- RZIP encode/decode integration in the PAK (Phase 3).
- Fuzzy / alias name matching (future opt-in `config/aliases.json`).
- Save-state slot canonicalization + restore/cross-device state
  (save-state-sync track S1–S3).
- Changing what any device *writes* locally — we adapt to devices.
- Physical-hardware re-validation of the NextUI naming change. 2.0's
  verification is the local `full` gate + file:// cross-style integration;
  a Brick round-trip and confirmation of the on-device ROM-folder names
  (see the NextUI platform-map note) are a follow-up **before** the
  migration is run against the live saves repo.

## Delivery ordering (constraint, not a task)

The mapper-aware daemon and the migration must deploy in lockstep: an
old-PAK device would re-push device-native names and un-migrate the repo.
With the current single-Brick fleet the order is: deploy the 2.0 PAK →
then run `migrate_repo.sh`. The migration operates on the user's saves
repo (a separate repo), so the owner runs it on-device after the dry-run.
