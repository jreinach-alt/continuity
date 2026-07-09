# Sprint 2.3 — Cross-Device Integration (Brick ⇆ Deck)

**Status:** DRAFT — awaiting owner approval. Spec-gated: no
implementation until this is approved.

**Model:** Opus. **Branch:** `claude/sprint-2.3-cross-device-v004i1`.
PR to main; owner merges.

## Goal

Prove, headlessly and deterministically, the end-to-end claim Sprint 2.0
was built for: **the same save on two different-platform devices.** A
MinUI-named save written on the TrimUI Brick becomes the one canonical
repo representation and materializes on the Steam Deck under its
RetroArch-native name — and the reverse — with ROM-anchored sparse
materialization in both directions (a game that lives on only one device
is never clobbered onto the other).

This sprint adds no core code. It exercises the existing engine and the
two **real** PALs (`pal_nextui.sh`, `pal_retrodeck.sh`) against one shared
`file://` remote, and it hands the owner a hardware validation protocol
for the two physical devices.

## Context / what already exists

- Sprint 2.0 (merged) shipped canonicalization: `pm_device_to_canonical`
  / `pm_canonical_to_device` in `src/core/path_mapper.sh`, ROM-anchored
  identity, per-device sparse materialization, RZIP quarantine. Gated on
  `save_name_style` + an existing `CONTINUITY_ROMS_ROOT`.
- Sprint 2.1 (merged) shipped the real RetroDeck PAL + CLI enrollment +
  `systemd --user` daemon.
- `tests/integration/test_canonicalization_flow.sh` proves the cross-STYLE
  mapping through the **test** PAL (globals swapped per simulated device).
- `tests/integration/test_retrodeck_flow.sh` proves every sync phase
  through the **real** RetroDeck PAL with env-overridden paths.

The gap this sprint closes: no test drives **both real PALs at once**
against **one shared remote**. That is the actual cross-device claim; the
canonicalization flow test approximates it with one PAL and swapped
globals.

## Design decisions (please confirm at approval)

1. **Two devices = two subshells against one bare `file://` remote.**
   Each device runs in its own `( … )` subshell that sets that platform's
   `CONTINUITY_*` env, sources exactly ONE real PAL, and drives the sync
   phases. This mirrors two physical devices (isolated global state,
   independent clones) and avoids sourcing both PALs into one shell (they
   define the same `pal_*` symbols). Pattern precedent: `test_pal_swap.sh`
   uses per-device subshells; `test_retrodeck_flow.sh` uses the real-PAL
   env-override technique.

2. **Deck side drives the REAL RetroDeck daemon surface**
   (`rdd_load_modules` + the core phases it loads), exactly as
   `test_retrodeck_flow.sh` does — `CONTINUITY_APP_DIR=$PROJECT_ROOT`
   makes its module loader read the repo tree directly.

3. **Brick side sources the REAL `pal_nextui.sh` + core modules from
   `src/core/` and drives the core phases directly** (`cs_run`, `rp_run`,
   `bp_run`, `se_pull`) — it does NOT boot the nextui daemon. Reason: the
   nextui daemon's `cd_load_modules` sources from
   `$CONTINUITY_PAK_DIR/scripts/core/…` (the on-device PAK layout), not
   the repo's `src/core/`; standing up a fake PAK scripts/ tree would test
   the PAK packaging, not cross-device sync. The real `pal_nextui.sh` is
   fully env-overridable (`CONTINUITY_PAK_DIR`, `CONTINUITY_GIT_BIN`,
   `CONTINUITY_SAVES_ROOT`, `CONTINUITY_ROMS_ROOT`, `CONTINUITY_REPO_DIR`);
   its git-exec-path wiring is existence-gated, so pointing
   `CONTINUITY_PAK_DIR=$PROJECT_ROOT` yields the real nextui platform map
   without hijacking the sandbox's system git. Both real PALs are
   therefore genuinely exercised end-to-end.

4. **Conflicts are DEFERRED (per kickoff scope).** The flow is strictly
   turn-taking — each device pulls before it writes the shared file — so
   histories never diverge and the `.conflict` path is never entered. If
   any assertion nonetheless lands on a conflict artifact, it asserts only
   on **artifact existence + preserved bytes**, never on `.conflict` JSON
   fields (which belong to the in-flight Sprint 1.5 v2 schema).

## Scope

- One new real-PAL cross-device integration test.
- One new hardware validation protocol doc (owner-run, two real devices).
- The sprint summary handoff artifact.

**No changes to** `src/core/**`, `src/platforms/nextui/**`, or
`src/platforms/retrodeck/**` (read-only). If a real bug surfaces, it is
FLAGGED in the summary (like the 2.1 agent did), not fixed in-lane unless
trivial and owner-approved.

## File table

| Action | Path | Purpose |
|---|---|---|
| Create | `tests/integration/test_cross_device_flow.sh` | Real-PAL Brick⇆Deck sync over one `file://` remote |
| Create | `docs/platform/cross-device-validation.md` | Owner's hardware validation protocol (two real devices) |
| Create | `docs/sprints/sprint-2.3-summary.md` | Handoff artifact (at implementation end) |

No new top-level folders. No parent dirs created. No core/platform edits.

## The test flow (`test_cross_device_flow.sh`)

Sandbox: `mktemp -d` under `$TMPDIR`, per-process, cleaned on EXIT;
`commit.gpgsign=false` via `GIT_CONFIG_*`; `CONTINUITY_FORCE_ONLINE=1`.
One bare `file://` remote with a `main` branch, enrolled with the
`.continuity/.gitignore` both devices expect.

Two device worlds:
- **Brick (nextui, real `pal_nextui.sh`):** saves under `SFC/`, `GBA/`;
  ROMs under `Roms/…`; MinUI naming (`<rom_fullname>.sav`, ROM ext
  embedded). `CONTINUITY_PAK_DIR=$PROJECT_ROOT`, `CONTINUITY_GIT_BIN=git`.
- **Deck (retrodeck, real `pal_retrodeck.sh`):** paths from a live
  `retrodeck.json` (rdhome with a space); saves under `snes/`, `gba/`;
  RetroArch naming (`<rom_stripped>.srm`). `CONTINUITY_APP_DIR=$PROJECT_ROOT`.

**Part 1 — Brick → repo → Deck (minui ⇒ canonical ⇒ retroarch).**
1. Brick has ROMs `Super Metroid (USA).sfc` and `Chrono Trigger.sfc`, and
   MinUI saves `Super Metroid (USA).sfc.sav` (+ its `.rtc`) and
   `Chrono Trigger.sfc.sav`. Brick cold-starts → pushes.
2. Assert the repo (via `git -C "$REMOTE" ls-tree`) carries the **canonical**
   names `snes/Super Metroid (USA).srm`, `snes/Super Metroid (USA).rtc`,
   `snes/Chrono Trigger.srm`, and that **no** device-native `.sfc.sav`
   leaked in.
3. Deck has ONLY the `Super Metroid (USA).sfc` ROM (no Chrono ROM). Deck
   boot-pulls → assert it materializes `snes/Super Metroid (USA).srm`
   (RA-native) with the Brick's exact bytes, `.rtc` travelled, and — the
   sparse guard — `Chrono Trigger.srm` is **absent** (no ROM on the Deck).

**Part 2 — Deck → repo → Brick (retroarch ⇒ canonical ⇒ minui).**
4. Deck writes a NEW RetroArch-named save `gba/Zelda Minish Cap (USA).srm`
   for a ROM it has; Deck poll pushes it. Deck also has a Deck-only game
   (e.g. `psx/Some PS1 Game.srm` with its ROM) that the Brick lacks.
5. Brick pulls (boot-pull against its stored commit). Assert the headline
   name transformation: the Brick materializes
   `GBA/Zelda Minish Cap (USA).gba.sav` — **MinUI native, ROM extension
   embedded** — with the Deck's exact bytes. This is the reverse mapping
   canonicalization exists for.
6. Sparse guard reverse: the Brick has no PS1 ROM, so `Some PS1 Game`'s
   save is **not** materialized on the Brick.

Turn-taking guarantees no divergence; the `.conflict` path is never
reached. Every assertion is on a materialized filename, its bytes, or a
`ls-tree` name — deterministic, no timing.

## Acceptance criteria

1. `test_cross_device_flow.sh` drives BOTH real PALs
   (`pal_nextui.sh` + `pal_retrodeck.sh`) against ONE shared `file://`
   remote, and passes (0 failed) under `busybox ash` **and** the system
   shell.
2. Brick→Deck: a MinUI-named save becomes the canonical repo name and
   materializes on the Deck under its RA-native name with byte-identical
   content; `.rtc` travels with its game.
3. Deck→Brick: an RA-named save becomes the canonical repo name and
   materializes on the Brick under its MinUI-native name (ROM extension
   embedded, reconstructed from the Brick's ROM) with byte-identical
   content.
4. Sparse materialization proven BOTH ways: a game present on only one
   device is never materialized on the other.
5. No device-native name ever leaks into the repo (canonical `.srm` only).
6. `docs/platform/cross-device-validation.md` gives the owner exact,
   ordered steps to reproduce 2–4 on the two real devices.
7. `scripts/gate.sh full` is green (current-user + unprivileged `nobody` +
   shipped-PAK integrity) before any PR.
8. No edits to `src/core/**` or the two platform dirs; any bug found is
   FLAGGED in the summary.

## Tests

- New: `tests/integration/test_cross_device_flow.sh` (the above).
- Must pass under `busybox ash` and unprivileged `nobody` (artifacts under
  `$TMPDIR`, per-process names, never write into the repo tree).
- Full suite (`scripts/gate.sh full`) must stay green — no regressions.

## Hardware validation protocol (`docs/platform/cross-device-validation.md`)

Owner-run steps on the real Brick + real Deck sharing one private saves
repo:
1. Enroll both devices to the same repo (Brick: `setup.json` SD-card
   flow; Deck: `enroll_retrodeck.sh`).
2. Brick → Deck: save a game on the Brick, quit to flush the `.srm`
   (field-notes flush timing), let the daemon push; on the Deck verify the
   save appears under its RetroArch-native name with matching bytes
   (`sha256sum` both sides), and that a Brick-only game does NOT appear.
3. Deck → Brick: reverse, verifying the MinUI-native `<rom>.<ext>.sav`
   name and bytes, and the reverse sparse check.
4. Exactly what to look for in `.continuity/continuity.log` (Brick) and
   `journalctl --user` (Deck) at each step; the on-repo canonical names to
   confirm via the GitHub web UI.

## Out of scope (deferred)

- Cross-device CONFLICT scenario (entangled with Sprint 1.5 `.conflict` v2
  + conflict UI). Asserted elsewhere; this sprint stays turn-taking.
- Any core / PAL / daemon code change.
- RZIP-compressed save handling beyond the existing quarantine (Phase 3).
- Fuzzy/alias name matching.

## Reference specs

- `docs/design/save-format-canonicalization.md`
- `docs/design/nextui-format-matrix.md`
- `docs/platform/nextui-field-notes.md` (always in scope for NextUI work)
- Patterns: `tests/integration/test_canonicalization_flow.sh`,
  `tests/integration/test_retrodeck_flow.sh`
