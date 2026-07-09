# Sprint 3.1 — Summary

**Status:** Phase I code COMPLETE (spec approved 2026-07-09; core
extension approved same day); hardware validation pending — needs the
packaged app on the RG40XX V.
**Sessions:** 2026-07-09 (Fable kickoff → recon → spec → Phase I).
**Branch:** `claude/sprint-3.1-anbernic-kickoff-abjqjc`

## Gate 0 / recon history (earlier same-session)

Onion OS has no H700 build → owner confirmed device is an RG40XX V
running **muOS** → sprint retargeted (Onion deferred to roadmap 3.3);
recon ran via Task Toolkit and resolved every spec blank except the
boot hook. The device's own version files disagree (Banana vs Pixie) →
owner requirement: **feature-probe, never version-gate** (spec Version
Support Policy, acceptance I9). Recon probe defect fixed (exec-probe
argv0 misread — recon-2).

## Files Created (Phase I)

- `src/platforms/muos/pal_muos.sh` — PAL with existence-probed fallback
  chains (`/run/muos/storage/save/*` → `MUOS/save/*`; `/mnt/union/ROMS`
  → `ROMS`), env-defaulted seams (`CONTINUITY_MUOS_RUNROOT/_UNION`),
  git env wiring, logged resolutions.
- `src/platforms/muos/continuity_daemon.sh` — adapted from NextUI
  (PID lifecycle, vendored-busybox fail-open re-exec, module loading,
  enrollment check with network wait, boot dispatch, 30s poll loop,
  SIGTERM final push). App dir replaces PAK dir; log at
  `/mnt/mmc/.continuity/continuity.log`.
- `src/platforms/muos/enroll_sd_card.sh` — adapted (setup.json at the
  SD1 exFAT root; enrollment lock; hang-proof git env).
- `src/platforms/muos/preflight.sh` — adapted + muOS additions: BOTH
  version signals recorded verbatim (I9), path-resolution surfacing,
  boot-hook recon lines (init.d + /opt/muos/script), Snes9x mapping
  probe.
- `src/platforms/muos/task_continuity.sh` — Task Toolkit entry
  (`MUOS/task/Continuity.sh`): breadcrumb-always launch log, preflight
  → CONTINUITY_DIAGNOSTIC.txt at card root, state-driven dispatch
  (guidance / supervised enrollment / daemon start / status). Never
  uses the vendored interpreter (bootstrap stays device-native).
- `config/platform_maps/muos.json` — schema **2.1**: per-core
  `system_paths` (gb+gbc→Gambatte, gba→mGBA, snes→Snes9x,
  n64→Mupen64Plus-Next, ps1→PCSX-ReARMed — device-proven cores only),
  `rom_paths` to muOS ROM folder names, `retroarch` name style, raw
  container.
- `tests/unit/muos/`: test_pal_muos (18), test_continuity_daemon (83),
  test_enroll_sd_card (20), test_preflight (45 — incl. I9 version-
  signal and boot-hook assertions), test_task_continuity (19 — incl. a
  full real enrollment through the task against a bare git remote),
  test_recon_device (25).
- `tests/unit/core/test_path_mapper_rom_paths.sh` (21) — the schema-2.1
  extension: GB/GBC disambiguation through the shared Gambatte dir
  (mirrors the device's real files), rom_paths precedence, dedupe,
  fallbacks, v2.0 backward compatibility.

## Files Modified

- `src/core/path_mapper.sh` — **owner-approved core extension**
  (schema 2.1): optional `rom_paths` block parse; `pm_rom_dir` prefers
  it; `pm_device_to_canonical` resolves shared save dirs by ROM anchor;
  `pm_canonicals_for_dir` helper; `pm_list_watched_dirs` dedupes;
  fixed a latent nondeterminism (multi-line grep) in `pm_local_to_repo`
  for duplicate-value maps. All 100 pre-existing mapper assertions
  unchanged and green.
- `scripts/gate.sh` — full-tier shellcheck now covers
  `src/platforms/muos/*.sh` (the coordinated shared edit from the
  spec's file table).
- Spec/summary docs.

## Test State

`scripts/gate.sh full` PASSED end-to-end in the dev container:
44 test files green as current user AND as `nobody`; shipped-PAK
checksums verified; busybox 69-check matrix under qemu; bundled git
runs under qemu (qemu-user-static installed this session). The
qemu/container leg of acceptance I1 is done; the on-device leg
(exec on real kernel, live TLS clone, transport-helper re-exec) is
what hardware validation covers.

## Packaging (owner-approved file-table addition, 2026-07-09)

`scripts/build_muos_app.sh` + `tests/unit/muos/test_build_muos_app.sh`
(28 assertions). Stages the card-mirroring layout (`.continuity/app/**`
+ `MUOS/task/Continuity.sh` + `MUOS/task/Continuity Recon.sh`) from the
VERIFIED PAK binaries (byte-compare enforced at build; checksums
manifest for on-device preflight verification; minute-granular version
stamp; CRLF guard; zip from the staging root so Extract-All onto the
card root installs everything). Staging/zip live under gitignored
`build/` — only `build/Continuity.pak` stays a committed artifact.
First real build `0.1.0-muos-20260709-2236` (13 MB): staged git and
busybox byte-identical to the hardware-validated PAK set, git runs
under qemu, busybox passes the 69-check matrix. The live-TLS leg runs
on-device (preflight ls-remote) — the container's TLS proxy makes an
emulated live-clone unrepresentative and the bytes already passed it
when the PAK shipped.

## Deviations from Spec

- The spec's file table named a `<boot-hook installer>`; what shipped
  is the Task Toolkit launcher (manual start + status), per the spec's
  own decision to defer boot-hook wiring to the first validation round
  (preflight's boot-hook lines gather the data for it).

## Hardware validation (2026-07-09, owner's RG40XX V)

- Build `…-2236`: enrollment succeeded on-device (clone over TLS with
  the ported Brick git, registration pushed) but the cold-start save
  push never ran — **field defect: muOS's Task Toolkit kills the
  task's process group on exit**, taking the plain-backgrounded daemon
  with it. Fixed in `…-2336`: `tc_start_daemon` detaches via `setsid`
  and VERIFIES the start (PID liveness polled and reported either
  way). Recorded in `docs/platform/muos-field-notes.md`.
- Build `…-2336`: **cold-start push of the device's existing save
  library succeeded** — acceptance I1 (on-device binaries + TLS), I4
  (enrollment), and the device→repo half of I5 are hardware-proven.
- Boot hook resolved: muOS's documented **"User Init Scripts"**
  mechanism (`MUOS/init/*.sh`, toggle in Advanced Settings) — hook +
  test shipped, packaged as `MUOS/init/continuity.sh`.

## Open Items

1. **Owner: enable the boot hook** (Configuration → General Settings →
   Advanced Settings → User Init Scripts) after installing the build
   that ships `MUOS/init/continuity.sh`; reboot; confirm via the
   Continuity task that the daemon is already running.
2. **Owner: verify repo layout on GitHub** (I3 field check): gb/ and
   gbc/ split correctly out of the shared Gambatte dir; N64 names with
   `[!]` intact; the Mystic Quest save present under snes/.
3. **Remaining I5 checks**: runtime-poll push while playing (save →
   quit game → ~30s → commit); repo→device materialization (boot
   pull); reboot/crash-recovery cycles.
4. **Cross-device test with the Brick** (I6), then PR to main
   (owner merges).
5. Unproven cores (nes, genesis, sms, gg, pce, arcade …) get map
   entries as the daemon's unknown-dir warnings surface them — never
   from memory.
6. Refactor candidate for a future sprint (architecture signal, not
   3.1): daemon + enroll_sd_card are near-identical copies in two
   platform dirs — CLAUDE.md's "two platforms need it → core" rule
   points at extracting a shared daemon skeleton.
7. Roadmap: Onion OS deferred as Sprint 3.3 (needs Miyoo-family
   hardware; new ARMv7 cross-compile target).
