# Sprint 3.1 — muOS Client on the Anbernic RG40XX V

**Status:** DRAFT — Gate 0 RESOLVED (muOS, owner-confirmed 2026-07-09).
Blocked on (a) the on-device recon report and (b) owner approval of this
spec. Do not implement past the recon deliverable until both land.

**Kickoff brief:** `docs/sprints/sprint-3.1-anbernic-kickoff.md` (on
`claude/parallel-kickoff` until it merges). The brief targeted "Onion OS
on the RG40XX V"; Gate 0 below records why the platform is muOS.

**Development branch:** `claude/sprint-3.1-anbernic-kickoff-abjqjc` →
PR to `main`; owner merges.

## Goal

Bring up the Continuity platform client on the owner's Anbernic
**RG40XX V** (Allwinner H700, 4× Cortex-A53, aarch64) running **muOS**:
PAL, enrollment, daemon + boot hook, platform map v2, bundled-binary
validation — the same bring-up shape as NextUI Phase 1. Ends with a real
save round-trip on the device and a cross-device sync with the Brick
(the Sprint 2.3 analogue for this pairing).

The Fable-class core is the **binary port + exec-semantics validation
on a new userland** (git transport-helper re-exec; busybox
`/proc/self/exe` applet self-exec) — the historically fragile part per
`docs/platform/nextui-field-notes.md`. Same arch ≠ same userland;
verify, don't assume.

## Decision Gate 0 — firmware identity: RESOLVED (muOS)

Desk research (2026-07-09) found **no Onion OS build for H700/Anbernic
hardware** — Onion targets the Miyoo Mini family (ARMv7); H700 support
is an open feature request
([OnionUI/Onion discussion #1697](https://github.com/OnionUI/Onion/discussions/1697)).
Owner Q&A then confirmed: the device in hand IS an RG40XX V with
working WiFi, and (2026-07-09) **it runs muOS**. Consequences:

- **This sprint's platform id is `muos`.** Artifacts live at
  `src/platforms/muos/**`, `config/platform_maps/muos.json`,
  `tests/unit/muos/**`.
- **Onion OS stays on the roadmap as a future platform** (owner wants
  it, but has no Onion-capable hardware in the current fleet to
  validate against — and the project rule is that platform facts get
  validated on real devices). `config/platform_maps/onion.json` remains
  as the future placeholder; no Onion code ships in 3.1.
- Same aarch64 architecture as the Brick, so the binary-port plan
  stands; the roadmap's 2026-07-07 note "MuOS reading was wrong" is
  superseded by this confirmation.
- The owner has **no shell access** — recon and all future device
  interaction must be menu-driven (see Phase R).

## Phase R — Recon (deliverable shipped; awaiting device run)

`src/platforms/muos/recon_device.sh` — a one-shot, read-only,
BusyBox-ash diagnostic, firmware-agnostic so a surprise userland still
gets captured.

**How to run on muOS (no shell needed)** — muOS runs user scripts
placed in `MUOS/task/` on the primary SD card via Applications → Task
Toolkit ([muxtask module](https://muos.dev/tour/modules/muxtask),
[community docs](https://github.com/PetraOleum/handheld-script-examples)):

1. Power off the device, put SD1 (the card with the `MUOS` folder) in a
   PC reader.
2. Copy `recon_device.sh` to `MUOS/task/Continuity Recon.sh` on that
   card. Do NOT open/re-save it in a Windows editor (the CRLF trap —
   field notes).
3. Card back in, boot, open **Applications → Task Toolkit → Continuity
   Recon**, let it finish.
4. Power off, card back in the PC: send back `CONTINUITY_RECON.txt`
   from the card's root. No secrets are captured (no WiFi configs read;
   any `setup.json` PAT masked to a character count).

If `MUOS/task/` does not exist on the card (Task Toolkit location has
moved across muOS releases), send a top-level file listing of the card
instead and the payload location gets adjusted to the installed
version.

**What the report answers → which spec blank it fills:**

| Recon section | Fills |
|---|---|
| kernel/cpu, shell/userland (ELF class of `/bin/sh`, busybox, libc) | Binary strategy: port Brick binaries vs rebuild |
| firmware identity | muOS version; confirms Gate 0 on-device |
| git | Whether a usable firmware git exists (may eliminate the bundled-git problem) |
| mounts/storage + exec semantics (noexec, symlinks, `/proc/self/exe`, mtime) | Where binaries can live; whether the vendored-busybox tiers can work |
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
2. **PAL** — `pal_muos.sh`: the 5 required vars + 4 required functions
   (`src/core/pal.sh`), plus `CONTINUITY_STATES_ROOT`,
   `CONTINUITY_ROMS_ROOT`, and the git env wiring (GIT_EXEC_PATH,
   GIT_SSL_CAINFO, GIT_TEMPLATE_DIR, PATH belt) per the NextUI PAL.
3. **Platform map v2** — `config/platform_maps/muos.json` (new,
   `_schema_version 2.0`): `save_name_style` — expected `retroarch`,
   CONFIRMED against real device files; `save_container`; `rom_roots`;
   real `system_paths`. Every field derived from recon, none from
   memory. (`onion.json` is untouched — future platform placeholder.)
4. **Enrollment** — `enroll_sd_card.sh` adapted from NextUI (setup.json
   at SD root, `GIT_TERMINAL_PROMPT=0`, low-speed timeouts, stale-clone
   removal, network wait).
5. **Daemon + boot hook** — `continuity_daemon.sh` adapted from NextUI
   (PID file, module loading, boot dispatch, 30s poll, SIGTERM final
   push), started fully detached (`</dev/null >/dev/null 2>&1 &`) from
   muOS's boot mechanism (recon-gated; a Task Toolkit entry is the
   fallback manual trigger). Vendored-interpreter fail-open self-test
   preserved. Core sync engine used **unchanged**.
6. **Preflight doctor** — adapted `preflight.sh`; report to
   `CONTINUITY_DIAGNOSTIC.txt` at SD root; every failure names itself
   with the build stamp (observability protocol).
7. **Delivery packaging** — recon-gated: muOS's app/task convention
   (the PAK concept is NextUI's), shipped as a versioned zip built from
   the verified tree. OTA participation deferred (see out-of-scope).

### File table (Phase I)

| File | Action |
|---|---|
| `src/platforms/muos/recon_device.sh` | shipped in Phase R |
| `src/platforms/muos/pal_muos.sh` | create |
| `src/platforms/muos/continuity_daemon.sh` | create (adapted) |
| `src/platforms/muos/enroll_sd_card.sh` | create (adapted) |
| `src/platforms/muos/preflight.sh` | create (adapted) |
| `src/platforms/muos/<boot-hook installer>` | create — name/mechanism recon-gated |
| `config/platform_maps/muos.json` | create (schema 2.0, recon-derived) |
| `tests/unit/muos/test_recon_device.sh` | shipped in Phase R |
| `tests/unit/muos/test_pal_muos.sh` | create |
| `tests/unit/muos/test_continuity_daemon.sh` | create (adapted) |
| `tests/unit/muos/test_enroll_sd_card.sh` | create (adapted) |
| `tests/unit/muos/test_preflight.sh` | create (adapted) |
| `scripts/gate.sh` | add `src/platforms/muos/*.sh` to the full-tier shellcheck list (small shared edit — coordinate at merge) |
| `docs/platform/muos-field-notes.md` | create during hardware validation |
| `docs/sprints/sprint-3.1-summary.md` | update at completion |

If implementation requires a file not in this table (or any edit to
`src/core/**`): STOP and escalate — that's an architecture signal (the
PAL exists so bring-up needs no core changes).

## Acceptance criteria

Recon phase (now):
- R1. Recon script runs under `busybox ash`, exits 0 with probes
  degraded gracefully, writes a single report, leaves no artifacts,
  never exposes secrets. (Unit-tested; hardware run pending.)
- R2. Owner has run it on the RG40XX V via Task Toolkit and the report
  resolves muOS version, arch/libc, exec semantics, save landscape,
  boot hook.

Implementation phase (after approval):
- I1. Bundled `git` + `busybox` validated per the field-notes protocol
  under qemu AND on-device: live TLS clone, transport-helper re-exec,
  `/proc/self/exe` applet tier (or documented fall-through), with the
  host git hidden during emulated validation.
- I2. `pal_muos.sh` passes `pal_validate`; the full core suite passes
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
  muos PAL; daemon lifecycle against a real local git remote.
- Hardware checklist (owner-run, documented in the summary): enrollment,
  save round-trip, reboot cycles, crash recovery, cross-device with the
  Brick.

## Out of scope

- **Onion OS client** — deferred to its own future sprint when
  Onion-capable hardware (Miyoo Mini family, ARMv7 — new cross-compile
  target) exists in the fleet. `onion.json` placeholder retained.
- **Conflict UI** for this platform (own sprint, implements the approved
  conflict-UX design + UI design system).
- **Save-state restore / cross-device state sync** (designs exist;
  states remain one-way size-capped archive via core, which comes free).
- **Any `src/core/**` change** (escalate instead).
- **OTA channel** for this platform — decide after bring-up; card/manual
  delivery for 3.1.
- **RZIP codec integration** — if recon finds compressed saves, the
  Sprint 2.0 quarantine path applies; codec work stays Phase 3.

## Risks

1. **muOS release drift** — Task Toolkit location and boot hooks have
   moved across muOS versions; recon pins the installed version before
   anything ships.
2. **SD mount noexec** — bundled binaries may need to live on a
   different partition; exec probe answers this.
3. **RetroArch save compression enabled** → `.srm` files are RZIP
   containers → quarantine path until Phase 3 codec.
4. **musl vs glibc / kernel drift** — static Brick binaries should not
   care; the validation protocol proves it rather than assumes.
5. **Clock/TLS** — same trap as the Brick; preflight carries the check
   over.

## Coordination (parallel sessions)

This sprint owns `src/platforms/muos/**`, `config/platform_maps/
muos.json`, `tests/unit/muos/**`, and this spec/summary, plus the Gate 0
retarget edits to `docs/roadmap.md` and `CLAUDE.md` (surgical,
owner-directed 2026-07-09). It runs alongside RetroDeck 2.1, the UI
design system, and NextUI conflict UI 1.5 — all otherwise disjoint. The
single shared code touch (gate.sh shellcheck list) lands at
implementation time and is called out in the PR.

## Reference specs

- `docs/sprints/sprint-3.1-anbernic-kickoff.md` (brief; platform
  premise corrected by Gate 0)
- `docs/platform/nextui-field-notes.md` (ALWAYS in scope)
- `docs/sprints/sprint-1.1-1.3-summary.md` (bring-up precedent + defect
  history)
- `docs/sprints/sprint-2.0-spec.md` + save-format canonicalization
  design (map v2 contract)
- `docs/design/pal.md`, `docs/design/security-model.md`
