# Sprint 3.1 — muOS Client on the Anbernic RG40XX V

**Status:** DRAFT — Gate 0 RESOLVED (muOS, owner-confirmed 2026-07-09);
**recon report received and analyzed 2026-07-09** (see Recon Findings).
Blocked only on **owner approval of this spec**. Do not implement until
it lands.

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

## Recon Findings (2026-07-09 — CONTINUITY_RECON.txt, RG40XX V)

The owner ran the recon via Task Toolkit; the report resolves every
Phase R blank except the boot hook. Facts (device-measured, not
assumed):

**Identity.** The device reports **conflicting versions about itself**:
`/etc/os-release` says "2410 banana" while `/opt/muos/config/version.txt`
says "2502.0_PIXIE". Owner assessment (2026-07-09): probably 2410
Banana — the device hasn't been updated in a while. Standing
consequence (owner requirement): **muOS version identity is unreliable
and fleet versions are unknown — the client supports a RANGE of muOS
releases and must not version-gate behavior** (see Version Support
Policy below). Kernel 4.9.170 aarch64, Allwinner sun50iw9 (H700), 4×
Cortex-A53, 1 GB RAM. Buildroot/glibc userland
(`ld-linux-aarch64.so.1`), `/bin/sh` → busybox **1.36.1** (same version
we vendor), 289 applets. Runs as root.

**Toolchain gaps.** NO git, NO ssh/scp, NO inotifywait, NO `stat`
applet (don't rely on stat). `wget`, `curl`, `timeout`, `find`, `cmp`,
`sha256sum` present. → Bundled git required; polling daemon — the Brick
shape exactly.

**Storage & exec semantics (the Fable-core answers).**
- SD1's user-visible partition (`/dev/mmcblk0p6`, exFAT via fuseblk) is
  `/mnt/mmc` — mounted `rw,nosuid,nodev` and **NOT noexec**: the exec
  probe's copied binary ran from the card (report shows busybox's
  "applet not found" from the renamed copy — the exec itself succeeded;
  recon-2 fixes the probe naming and the misleading heuristic line).
  Bundled binaries can live on the card.
- Symlinks NOT supported (as on the Brick) — ship real file copies.
- `/proc/self/exe` resolves — the vendored-busybox applet self-exec
  tier is viable. Kernel 4.9 ≥ every static-binary floor we use.
- 78 GB free on the card; `/tmp` is tmpfs and writable; muOS rootfs is
  ext4 on the same card (p5), invisible to Windows — all user file
  drops (setup.json, payloads) go through `/mnt/mmc` (p6), which is
  what a PC reader sees.

**Saves (real files, byte-checked).**
- RetroArch, `savefile_directory=/run/muos/storage/save/file` — a
  stable indirection the PAL should use as `CONTINUITY_SAVES_ROOT`
  (backed today by `/mnt/mmc/MUOS/save/file`).
- Layout is **per-CORE**, not per-system (`sort_savefiles_enable=true`):
  `save/file/<Core>/<rom_basename>.srm` — Gambatte, mGBA, Snes9x,
  PCSX-ReARMed, Mupen64Plus-Next observed. `save_name_style` =
  `retroarch` CONFIRMED against real files (`Chrono Trigger.srm`,
  `Cruis'n USA (U) (V1.2) [!].srm` — spaces + apostrophes: the
  porcelain `-z` rule applies everywhere).
- `save_file_compression = "false"` and first-bytes of six real saves
  are raw SRAM — **no RZIP quarantine needed** (risk retired; keep the
  detector in the scanner anyway, the setting is user-flippable).
- States at `save/state/<Core>/<rom>.state[N]` **plus `.png`
  thumbnail siblings** — the state-archive filter must handle the
  RetroArch shapes and decide on thumbnails (cheap; include).
- `autosave_interval=0` → SRAM hits disk on exit/close-content, same
  "sync when you take a break" story as the Brick.

**The mapping design task (flagged for implementation).** muOS's
per-core save dirs break the "system dir" assumption baked into
`system_paths`: one core can serve two systems (Gambatte = GB+GBC) and
one system can accumulate saves under multiple cores if the user
switches. Plan: scanner watches `save/file/*/` generically; repo-path
identity resolves via Sprint 2.0 ROM-anchoring against
`CONTINUITY_ROMS_ROOT=/mnt/union/ROMS` (muOS's unionfs merge of SD1/SD2
ROMS; folder names like `Nintendo - SNES`); device-bound
materialization must place a save where the assigned core will look —
likely readable from muOS's core assignments (`MUOS/info/core`),
confirm during implementation. If this can't be expressed without
touching `src/core/path_mapper.sh`, STOP and escalate per the file
table rule (it is the likeliest escalation candidate in this sprint).

**Network/clock/input.** WiFi up with working DNS; ping AND https to
github.com succeed from the device; clock correct (TLS-safe). muOS
ships syncthing support (its storage mount exists) — background network
daemons are a normal pattern on this firmware. `/dev/input/js0`
present (future UI).

**Still open (the ONE remaining recon blank): the boot hook.** No
user-level autostart mechanism surfaced at the SD level; muOS's own
init is `/etc/init.d/S01muos`, task scripts live at `MUOS/task/` (SD)
and `/opt/muos/share/task/` (internal). Official docs don't clearly
bless a user boot hook. Implementation resolves this in its first
validation round (preflight dumps `S01muos` + `/opt/muos/script/`), with
a Task Toolkit "Start Continuity" entry as the guaranteed manual
fallback from day one; enrollment does not depend on the answer.

## Version Support Policy (owner requirement, 2026-07-09)

Fleet devices may run anything from 2410 Banana through current
releases, and the device's own version files disagree with each other —
so the muOS client is **feature-probed, never version-gated** (the same
philosophy as the vendored-busybox self-test: probe the capability,
fail open):

- **Paths resolve by existence, with fallback chains.** Saves root:
  `/run/muos/storage/save/file` if present (the stable indirection on
  this device), else `/mnt/mmc/MUOS/save/file` directly. Same pattern
  for states, ROMs (`/mnt/union/ROMS` → `/mnt/mmc/ROMS`), and any other
  muOS-provided path. The chosen resolution is logged at daemon start
  and reported by preflight.
- **Version strings are diagnostics, not switches.** Preflight records
  BOTH `/etc/os-release` and `/opt/muos/config/version.txt` verbatim
  (they disagree on the reference device); nothing branches on them.
- **Layout variants are fixture-tested.** Unit tests run the PAL and
  scanner against fixture trees for each known layout (with/without the
  `/run/muos/storage` indirection, task-folder location variants), so
  cross-version support is proven headlessly — the fleet can't supply
  one hardware unit per release.
- **Delivery instructions are probe-first**: the install/enrollment
  docs tell the user to look for `MUOS/task/` and fall back to the
  `ARCHIVE`-era locations, rather than asserting one true path per
  version.

## Phase I — Implementation (BLOCKED on owner approval)

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
| `scripts/build_muos_app.sh` | create — packaging (owner-approved addition 2026-07-09): stages the card layout from the VERIFIED PAK binaries, checksums manifest, versioned zip |
| `tests/unit/muos/test_build_muos_app.sh` | create (with the above) |
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
- R2. SATISFIED 2026-07-09: owner ran it via Task Toolkit; the report
  resolves muOS version, arch/libc, exec semantics, and save landscape
  (boot hook deferred to Phase I's first validation round — see Recon
  Findings).

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
- I9. Version Support Policy holds: no code path branches on a muOS
  version string; every muOS-provided path resolves through an
  existence-probed fallback chain whose choice is logged; PAL + scanner
  pass fixture tests for each known layout variant; preflight reports
  both version signals verbatim.

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

1. **Per-core save mapping** (see Recon Findings) — the likeliest
   escalation candidate; resolve the design before writing the scanner,
   and STOP if it needs core changes.
2. **Boot hook unknown** — mitigated: Task Toolkit manual start works
   from day one; hook resolved in the first validation round.
3. **muOS release drift** — fleet versions are unknown and the
   reference device's own version files disagree (os-release: 2410
   Banana; version.txt: 2502.0 Pixie; owner: probably Banana).
   Mitigated by the Version Support Policy: feature-probe, never
   version-gate; both strings recorded as diagnostics only.
4. ~~SD mount noexec~~ RETIRED: exec-from-SD proven on-device.
5. ~~RetroArch RZIP saves~~ RETIRED for this device
   (`save_file_compression=false`, real saves byte-checked raw) — keep
   the scanner's detector, the setting is user-flippable.
6. **Kernel 4.9 / glibc drift** — static Brick binaries should not
   care; the validation protocol proves it rather than assumes.
7. **Clock/TLS** — clock verified correct on-device; preflight keeps
   the check anyway.

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
