# Sprint 2.3 — Cross-Device Integration (Brick ⇆ Deck)

**Status:** APPROVED 2026-07-09 (owner decisions below). Rebased onto
current main (Sprint 1.5 merged — `.conflict` schema v2 + `conflict_ui.sh`
are now landed, so the cross-device conflict is IN scope for this sprint).

**Model:** Opus. **Branch:** `claude/sprint-2.3-cross-device-v004i1`.
PR to main; owner merges.

## Goal

Prove, headlessly and deterministically, the end-to-end claim Sprint 2.0
was built for: **the same save on two different-platform devices.** A
MinUI-named save written on the TrimUI Brick becomes the one canonical
repo representation and materializes on the Steam Deck under its
RetroArch-native name — and the reverse — with ROM-anchored sparse
materialization in both directions (a game that lives on only one device
is never clobbered onto the other). Additionally: a cross-format
divergence on the SAME game (Brick `.sav` vs Deck `.srm`) collapses to
ONE canonical identity + ONE `.local`, proving canonicalization holds
through the conflict path.

This sprint adds no core code. It exercises the existing engine and the
two **real** PALs (`pal_nextui.sh`, `pal_retrodeck.sh`) against one shared
`file://` remote, and it hands the owner a hardware validation protocol
for the two physical devices.

## Owner decisions (approval)

1. **Drive via core phases directly with the real PALs sourced** — source
   the real `pal_nextui.sh` / `pal_retrodeck.sh` and call `cs_run` /
   `rp_run` / `bp_run` / `se_pull` / `ch_handle_pull_conflict` directly.
   Keep both sides symmetric via the core phases where practical. Daemon
   lifecycle (boot dispatch, poll loop, SIGTERM) is separately covered by
   `test_daemon_lifecycle.sh` and `test_retrodeck_flow.sh` (Phase 6), so
   this test does not re-boot either daemon.
2. **Include the cross-device conflict** (Sprint 1.5 is merged; the
   earlier deferral no longer applies): one divergence on the same game,
   asserting the v2 `.conflict` **identity/class grouping** — prove a
   Brick `.sav` and a Deck `.srm` for the same game collapse to one
   canonical identity + one `.local`, bytes preserved.
3. **Full hardware validation protocol** — both directions, both sparse
   checks, `sha256sum` byte-match, and log / on-repo / GitHub-UI
   verification.

## Context / what already exists

- Sprint 2.0 (merged): canonicalization mapper
  (`pm_device_to_canonical` / `pm_canonical_to_device`), ROM-anchored
  identity, per-device sparse materialization, RZIP quarantine. Gated on
  `save_name_style` + an existing `CONTINUITY_ROMS_ROOT`.
- Sprint 2.1 (merged): real RetroDeck PAL + CLI enrollment + daemon.
- Sprint 1.5 (merged): `.conflict` schema v2 — every `.conflict` carries
  `identity` (canonical path minus the save-class extension) and `class`
  (`srm` covers both `.srm` and the Brick's `.sav`; `rtc` for `.rtc`), so
  a game's saves resolve as one unit.
- `test_canonicalization_flow.sh` proves the cross-STYLE mapping through
  the **test** PAL. `test_retrodeck_flow.sh` proves every phase through
  the **real** RetroDeck PAL.

The gap this sprint closes: no test drives **both real PALs** against
**one shared remote**. That is the actual cross-device claim.

## Design

**Two devices = two subshells against one bare `file://` remote.** Each
device action runs in a `( … )` subshell that sets that platform's
`CONTINUITY_*` env, sources exactly ONE real PAL + the core modules from
`src/core/`, runs `pal_init` + `pm_load_platform_map`, and invokes a sync
phase. Isolation is by subshell (each PAL defines the same `pal_*`
symbols); all persistent device state lives on disk (each device's own
repo clone + saves/roms trees + the shared remote) — exactly like two
physical devices. Pattern precedent: `test_pal_swap.sh` (per-device
subshells) and `test_retrodeck_flow.sh` (real-PAL env overrides).

Real-PAL wiring:
- **Brick:** real `pal_nextui.sh`, env-defaulted paths overridden
  (`CONTINUITY_SAVES_ROOT`, `CONTINUITY_ROMS_ROOT`, `CONTINUITY_REPO_DIR`);
  `CONTINUITY_PAK_DIR=$PROJECT_ROOT` so `pal_get_platform_map` returns the
  real `config/platform_maps/nextui.json`; `CONTINUITY_GIT_BIN=git`. The
  PAL's git-exec-path wiring is existence-gated, so it does not hijack the
  sandbox's system git.
- **Deck:** real `pal_retrodeck.sh`, paths derived from a live
  `retrodeck.json` (via `CONTINUITY_RD_CONF`, rdhome with a space);
  `CONTINUITY_APP_DIR=$PROJECT_ROOT` so `pal_get_platform_map` returns the
  real `config/platform_maps/retrodeck.json`.

Lightweight enroll per device (clone + `se_init` + write
`.continuity/device_name` + `.continuity/.gitignore`) — enrollment itself
is covered by `test_enrollment_flow.sh` / `test_enroll_retrodeck.sh`; this
test only needs an enrolled clone the real `pal_init` accepts.

Turn-taking for the sync parts (each device pulls before it writes the
shared file) — the ONLY intentional divergence is Part 3's conflict.

## Scope

- One new real-PAL cross-device integration test.
- One new hardware validation protocol doc.
- The sprint summary handoff artifact.

**No changes to** `src/core/**`, `src/platforms/nextui/**`, or
`src/platforms/retrodeck/**` (read-only). Any real bug is FLAGGED in the
summary, not fixed in-lane unless trivial and owner-approved.

## File table

| Action | Path | Purpose |
|---|---|---|
| Create | `tests/integration/test_cross_device_flow.sh` | Real-PAL Brick⇆Deck sync + cross-format conflict collapse over one `file://` remote |
| Create | `docs/platform/cross-device-validation.md` | Owner's hardware validation protocol (two real devices) |
| Create | `docs/sprints/sprint-2.3-summary.md` | Handoff artifact (at implementation end) |

No new top-level folders. No core/platform edits.

## The test flow (`test_cross_device_flow.sh`)

Sandbox: `mktemp -d` under `$TMPDIR`, per-process, cleaned on EXIT;
`commit.gpgsign=false` via `GIT_CONFIG_*`; `CONTINUITY_FORCE_ONLINE=1`.
One bare `file://` remote with `main`.

**Part 1 — Brick → repo → Deck (minui ⇒ canonical ⇒ retroarch).**
Brick has ROMs `Super Metroid (USA).sfc` + `Chrono Trigger.sfc` and MinUI
saves `Super Metroid (USA).sfc.sav` (+ `.rtc`) + `Chrono Trigger.sfc.sav`.
Brick cold-starts → pushes. Assert repo carries canonical
`snes/Super Metroid (USA).srm`, `snes/Super Metroid (USA).rtc`,
`snes/Chrono Trigger.srm`; no device-native `.sfc.sav` leaked. Deck has
ONLY the metroid ROM; Deck boot-pulls → materializes
`snes/Super Metroid (USA).srm` (RA-native) with the Brick's exact bytes,
`.rtc` travelled, and `Chrono Trigger.srm` is ABSENT (sparse: no ROM).

**Part 2 — Deck → repo → Brick (retroarch ⇒ canonical ⇒ minui).**
Deck writes a NEW RA-named `gba/Zelda Minish Cap (USA).srm` for a ROM it
has, plus a Deck-only `psx/Some PS1 Game.srm` (+ ROM) the Brick lacks;
Deck poll pushes. Brick pulls → materializes
`GBA/Zelda Minish Cap (USA).gba.sav` — **MinUI native, ROM extension
embedded, reconstructed from the Brick's ROM** — with the Deck's exact
bytes; `Some PS1 Game` is NOT materialized on the Brick (reverse sparse).

**Part 3 — cross-format divergence collapses to one identity.**
Both devices have `Super Metroid (USA)` (Brick ROM `.sfc`, Deck ROM
`.sfc`). Brick's native save is `Super Metroid (USA).sfc.sav`; Deck's is
`Super Metroid (USA).srm`. Each diverges to different bytes; both
canonicalize to the SAME repo path `snes/Super Metroid (USA).srm`. One
device syncs first (advances the remote as canonical); the other's pull
diverges (`se_pull` rc 1) → `ch_handle_pull_conflict`. Assert:
- Exactly ONE `.conflict` (`snes/Super Metroid (USA).srm.conflict`) and
  exactly ONE `.local` — NOT one per native extension.
- `.conflict` `identity` == `snes/Super Metroid (USA)` (save-class ext
  stripped) and `class` == `srm`.
- `.local` holds the losing device's exact bytes; canonical holds the
  winner's exact bytes (bytes preserved on both sides).
Assertions are on artifact existence, the `identity`/`class` grouping
fields, and bytes — the v2 schema's stable grouping contract, not
transient UI state.

All assertions are on materialized filenames, bytes (`cmp`/content), or
`ls-tree` names / `.conflict` grouping fields — deterministic, no timing.

## Acceptance criteria

1. `test_cross_device_flow.sh` drives BOTH real PALs against ONE shared
   `file://` remote and passes (0 failed) under `busybox ash` AND the
   system shell.
2. Brick→Deck: MinUI-named save → canonical repo name → Deck RA-native
   name, byte-identical; `.rtc` travels with its game.
3. Deck→Brick: RA-named save → canonical repo name → Brick MinUI-native
   name (ROM ext embedded, reconstructed from the ROM), byte-identical.
4. Sparse materialization proven BOTH ways.
5. No device-native name ever leaks into the repo (canonical `.srm` only).
6. Cross-format divergence on one game yields ONE `.conflict` (one
   `identity`, `class=srm`) + ONE `.local`, bytes preserved both sides.
7. `docs/platform/cross-device-validation.md` gives ordered steps to
   reproduce 2–4 + 6 on the two real devices, with `sha256sum` byte-match
   and log/repo/GitHub-UI verification.
8. `scripts/gate.sh full` green before any PR.
9. No edits to `src/core/**` or the two platform dirs; any bug FLAGGED.

## Tests

- New: `tests/integration/test_cross_device_flow.sh`.
- Passes under `busybox ash` and unprivileged `nobody` (artifacts under
  `$TMPDIR`, per-process names, never writes into the repo tree).
- Full suite (`scripts/gate.sh full`) stays green.

## Hardware validation protocol (`docs/platform/cross-device-validation.md`)

Owner-run on the real Brick + real Deck sharing one private saves repo:
1. Enroll both to the same repo (Brick: `setup.json` SD flow; Deck:
   `enroll_retrodeck.sh`).
2. Brick → Deck: save on the Brick, quit to flush the `.srm` (field-notes
   flush timing), let the daemon push; on the Deck verify the save under
   its RA-native name with matching bytes (`sha256sum` both sides), and a
   Brick-only game does NOT appear.
3. Deck → Brick: reverse — verify the MinUI-native `<rom>.<ext>.sav` name
   + bytes + reverse sparse check.
4. Cross-format conflict: save the same game on BOTH offline, reconnect,
   confirm one `.local` + one grouped conflict entry in the Brick conflict
   UI, bytes preserved.
5. What to watch in `.continuity/continuity.log` (Brick) and
   `journalctl --user` (Deck) at each step; the canonical names to confirm
   in the GitHub web UI.

## Out of scope (deferred)

- Any core / PAL / daemon code change.
- RZIP-compressed save handling beyond the existing quarantine (Phase 3).
- Fuzzy/alias name matching.
- Conflict *resolution* UI mechanics (try/promote/resolve) — covered by
  `test_conflict_resolution_flow.sh`; this sprint asserts only the
  cross-device *preservation + grouping* contract.

## Reference specs

- `docs/design/save-format-canonicalization.md`
- `docs/design/nextui-format-matrix.md`
- `docs/platform/nextui-field-notes.md` (always in scope for NextUI work)
- Patterns: `tests/integration/test_canonicalization_flow.sh`,
  `tests/integration/test_retrodeck_flow.sh`
