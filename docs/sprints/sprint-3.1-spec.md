# Sprint 3.1 — Onion OS Client on the Anbernic RG40XX V

**Status:** DRAFT — blocked on (a) on-device recon results and (b) owner
approval. Do not implement past the recon deliverable until both land.

**Kickoff brief:** `docs/sprints/sprint-3.1-anbernic-kickoff.md` (on
`claude/parallel-kickoff` until it merges).

**Development branch:** `claude/sprint-3.1-anbernic-kickoff-abjqjc` →
PR to `main`; owner merges.

## Goal

Bring up the Continuity platform client on the owner's Anbernic
**RG40XX V** (Allwinner H700, 4× Cortex-A53, aarch64): PAL, enrollment,
daemon + boot hook, platform map v2, bundled-binary validation — the
same bring-up shape as NextUI Phase 1. Ends with a real save round-trip
on the device and a cross-device sync with the Brick (the Sprint 2.3
analogue for this pairing).

The Fable-class core is the **binary port + exec-semantics validation
on a new userland** (git transport-helper re-exec; busybox
`/proc/self/exe` applet self-exec) — the historically fragile part per
`docs/platform/nextui-field-notes.md`. Same arch ≠ same userland;
verify, don't assume.

## Decision Gate 0 — firmware identity (MUST resolve first)

Desk research (2026-07-09) found **no Onion OS build for H700/Anbernic
hardware** — Onion officially targets the Miyoo Mini family (ARMv7);
H700 support is an open feature request
([OnionUI/Onion discussion #1697](https://github.com/OnionUI/Onion/discussions/1697)).
The established H700 CFWs are **muOS**, **Knulli** (Batocera-based),
**ROCKNIX**, and modified **stock**. This conflicts with the project
premise "Anbernic (Onion OS)" (CLAUDE.md, roadmap) and with the owner's
2026-07-07 note "platform list = OnionOS … MuOS reading was wrong."

The recon report settles it factually (`=== firmware identity (Gate 0)
===` section). Branches:

- **A — the device really runs an Onion build** (unofficial port):
  proceed per this spec as written.
- **B — the device runs muOS / Knulli / ROCKNIX / stock:** owner
  decision required. The sprint retargets to that firmware: platform id,
  `src/platforms/<fw>/`, `config/platform_maps/<fw>.json`, taxonomy
  alias, plus CLAUDE.md + roadmap wording — approval-class changes.
  The bring-up shape (this spec's scope) is unchanged; paths, boot hook,
  and delivery mechanism re-anchor to the real firmware.
- **C — the Onion target is actually a Miyoo-family device** (owner has
  a different device in mind for Onion): that device is **ARMv7, not
  aarch64** — the Brick's binaries cannot port and `build_git.sh` /
  `build_busybox.sh` need a new target triple. Materially bigger sprint;
  re-spec before implementing.

Everything below assumes branch A or B (H700 aarch64 device in hand);
"onion" naming is provisional pending the gate.

## Phase R — Recon (deliverable shipped with this spec)

`src/platforms/onion/recon_device.sh` — a one-shot, read-only,
BusyBox-ash diagnostic. The owner copies it to the SD card and runs it
on the device; it writes `CONTINUITY_RECON.txt` at the SD root.

**How to run** (whichever access path the firmware offers):

1. Copy `recon_device.sh` to the SD card root (any OS, any filename —
   e.g. `recon_continuity.sh`).
2. Get a shell on the device: SSH (Knulli/ROCKNIX enable it in settings;
   muOS ships a terminal app / SSH via its utilities) or any on-device
   terminal.
3. `sh /mnt/SDCARD/recon_continuity.sh` (adjust the mount point if the
   report of step 4 says otherwise — the script autodetects common SD
   roots).
4. Send back `CONTINUITY_RECON.txt` from the SD root. It contains no
   secrets: it never reads WiFi configs and masks any `setup.json` PAT
   to its character count.

**What the report answers → which spec blank it fills:**

| Recon section | Fills |
|---|---|
| kernel/cpu, shell/userland (ELF class of `/bin/sh`, busybox, libc) | Binary strategy: port Brick binaries vs rebuild |
| firmware identity (Gate 0) | Gate 0 branch; platform id and naming |
| git | Whether a usable firmware git exists (may eliminate the bundled-git problem) |
| mounts/storage + exec semantics (noexec, symlinks, `/proc/self/exe`, mtime) | Where binaries can live; delivery packaging; whether the vendored-busybox tiers can work |
| saves/roms landscape + first-bytes RZIP check | `saves_root`, `rom_roots`, `save_name_style`, `save_container` for the v2 map — validated against REAL files, never assumed |
| retroarch config | Save/state dir layout (`sort_savefiles_*`), compression risk (`save_file_compression` → RZIP quarantine path) |
| boot/autostart | The boot-hook mechanism (the `auto.sh` equivalent) |
| network/clock, input, misc | WiFi race analogue, TLS clock sanity, UI affordances |

## Phase I — Implementation (BLOCKED until recon + approval)

Mirrors NextUI Phase 1 (Sprints 1.1–1.3 compressed, minus conflict UI):

1. **Binary strategy (Fable core).** Try the Brick's shipped static
   aarch64 `git` + `busybox` on the RG40XX V. Validation protocol from
   the field notes transfers verbatim: qemu smoke with the **host git
   hidden**, every ARM→ARM exec edge shimmed, no binfmt_misc;
   `scripts/validate_busybox.sh` against the shipped busybox; then
   on-device: a live `git ls-remote`/clone over TLS, and the transport-
   helper re-exec + `/proc/self/exe` applet self-exec proven on the
   device's actual kernel/userland. Rebuild via the existing
   parameterized `build_git.sh`/`build_busybox.sh` only on demonstrated
   mismatch.
2. **PAL** — `pal_onion.sh`: the 5 required vars + 4 required functions
   (`src/core/pal.sh`), plus `CONTINUITY_STATES_ROOT`,
   `CONTINUITY_ROMS_ROOT`, and the git env wiring (GIT_EXEC_PATH,
   GIT_SSL_CAINFO, GIT_TEMPLATE_DIR, PATH belt) per the NextUI PAL.
3. **Platform map v2** — `config/platform_maps/onion.json` upgraded to
   `_schema_version 2.0` (`save_name_style` — expected `retroarch`,
   CONFIRMED against real device files; `save_container`; `rom_roots`;
   real `system_paths`). The current file is a Sprint 0.1 placeholder
   with Miyoo-guessed paths — every field gets re-derived from recon.
4. **Enrollment** — `enroll_sd_card.sh` adapted from NextUI (setup.json
   at SD root, `GIT_TERMINAL_PROMPT=0`, low-speed timeouts, stale-clone
   removal, network wait).
5. **Daemon + boot hook** — `continuity_daemon.sh` adapted from NextUI
   (PID file, module loading, boot dispatch, 30s poll, SIGTERM final
   push), started fully detached (`</dev/null >/dev/null 2>&1 &`) from
   the firmware's boot hook; vendored-interpreter fail-open self-test
   preserved. Core sync engine used **unchanged**.
6. **Preflight doctor** — adapted `preflight.sh`; report to
   `CONTINUITY_DIAGNOSTIC.txt` at SD root; every failure names itself
   with the build stamp (observability protocol).
7. **Delivery packaging** — recon-gated: the PAK concept is NextUI's;
   this platform gets whatever its firmware's app/script convention is,
   as a versioned zip built from the verified tree. OTA participation
   deferred (see out-of-scope).

### File table (Phase I)

| File | Action |
|---|---|
| `src/platforms/onion/recon_device.sh` | shipped in Phase R |
| `src/platforms/onion/pal_onion.sh` | create |
| `src/platforms/onion/continuity_daemon.sh` | create (adapted) |
| `src/platforms/onion/enroll_sd_card.sh` | create (adapted) |
| `src/platforms/onion/preflight.sh` | create (adapted) |
| `src/platforms/onion/<boot-hook installer>` | create — name/mechanism recon-gated |
| `config/platform_maps/onion.json` | upgrade to schema 2.0 |
| `tests/unit/onion/test_recon_device.sh` | shipped in Phase R |
| `tests/unit/onion/test_pal_onion.sh` | create |
| `tests/unit/onion/test_continuity_daemon.sh` | create (adapted) |
| `tests/unit/onion/test_enroll_sd_card.sh` | create (adapted) |
| `tests/unit/onion/test_preflight.sh` | create (adapted) |
| `scripts/gate.sh` | add `src/platforms/onion/*.sh` to the full-tier shellcheck list (small shared edit — coordinate at merge) |
| `docs/platform/<device>-field-notes.md` | create during hardware validation |
| `docs/sprints/sprint-3.1-summary.md` | update at completion |

If implementation requires a file not in this table (or any edit to
`src/core/**`): STOP and escalate — that's an architecture signal (the
PAL exists so bring-up needs no core changes).

## Acceptance criteria

Recon phase (now):
- R1. Recon script runs under `busybox ash`, exits 0 with probes
  degraded gracefully, writes a single report, leaves no artifacts,
  never exposes secrets. (Unit-tested; hardware run pending.)
- R2. Owner has run it on the RG40XX V and the report resolves Gate 0,
  arch/libc, exec semantics, save landscape, boot hook.

Implementation phase (after approval):
- I1. Bundled `git` + `busybox` validated per the field-notes protocol
  under qemu AND on-device: live TLS clone, transport-helper re-exec,
  `/proc/self/exe` applet tier (or documented fall-through), with the
  host git hidden during emulated validation.
- I2. `pal_onion.sh` passes `pal_validate`; the full core suite passes
  against it via the PAL-swap test pattern with **zero core changes**.
- I3. Platform map v2 fields byte-validated against real device files
  (name style, container, paths) — never asserted from memory.
- I4. On-device enrollment via `setup.json`: clone, device registration
  pushed, visible in the user's saves repo.
- I5. Boot hook starts the daemon detached; cold start, boot pull,
  stale recovery, and runtime poll all function on-device; a real save
  round-trips device → repo → device.
- I6. Cross-device: a save synced Brick → RG40XX V and reverse; a
  deliberate two-device conflict preserves both versions with device
  attribution (never-silently-overwrite holds across platforms).
- I7. `scripts/gate.sh full` green: suite passes as current user AND
  unprivileged (`nobody`), fast tier clean.
- I8. Observability: preflight report at SD root; every on-screen/log
  failure names itself with the build stamp; logs at
  `.continuity/*.log` equivalents.

## Tests required

- Unit: recon (shipped), PAL, daemon (adapted 51-assertion pattern),
  enrollment, preflight — all under `busybox ash`, self-contained in
  `$TMPDIR`-derived per-process dirs, both privilege passes.
- Integration: existing `test_pal_swap.sh` pattern extended to the
  onion PAL; daemon lifecycle against a real local git remote.
- Hardware checklist (owner-run, documented in the summary): enrollment,
  save round-trip, reboot cycles, crash recovery, cross-device with the
  Brick.

## Out of scope

- **Conflict UI** for this platform (own sprint, implements the approved
  conflict-UX design + UI design system).
- **Save-state restore / cross-device state sync** (designs exist;
  states remain one-way size-capped archive via core, which comes free).
- **Any `src/core/**` change** (escalate instead).
- **OTA channel** for this platform — decide after bring-up; card/manual
  delivery for 3.1.
- **RZIP codec integration** — if recon finds compressed saves, the
  Sprint 2.0 quarantine path applies; codec work stays Phase 3.
- Roadmap/CLAUDE.md renaming for Gate 0 branch B (needs owner approval
  first; done as part of the retarget decision, not preemptively).

## Risks

1. **Gate 0 mismatch** (likeliest): premise says Onion, hardware likely
   runs muOS/Knulli/ROCKNIX/stock → retarget decision blocks naming but
   not the bring-up shape.
2. **SD mount noexec** — bundled binaries may need to live on a
   different partition; exec probe answers this.
3. **RetroArch save compression enabled** → `.srm` files are RZIP
   containers → quarantine path until Phase 3 codec.
4. **musl vs glibc / kernel drift** — static Brick binaries should not
   care; the validation protocol proves it rather than assumes.
5. **Boot-hook model unknown** — Onion's launch model differs from
   NextUI's single `auto.sh`; muOS/Knulli have their own conventions;
   recon captures candidates.
6. **Clock/TLS** — same trap as the Brick; preflight carries the check
   over.

## Coordination (parallel sessions)

This sprint owns `src/platforms/onion/**`, `config/platform_maps/
onion.json`, `tests/unit/onion/**`, and this spec/summary. It runs
alongside RetroDeck 2.1, the UI design system, and NextUI conflict UI
1.5 — all disjoint. The single shared touch (gate.sh shellcheck list)
lands at implementation time and is called out in the PR.

## Reference specs

- `docs/sprints/sprint-3.1-anbernic-kickoff.md` (brief)
- `docs/platform/nextui-field-notes.md` (ALWAYS in scope)
- `docs/sprints/sprint-1.1-1.3-summary.md` (bring-up precedent + defect
  history)
- `docs/sprints/sprint-2.0-spec.md` + save-format canonicalization
  design (map v2 contract)
- `docs/design/pal.md`, `docs/design/security-model.md`
