# muOS / Anbernic RG40XX V — Field Notes

Hardware-validated facts from the Sprint 3.1 bring-up (2026-07-09).
Read this before touching the muOS platform code. Companion docs:
`docs/sprints/sprint-3.1-spec.md` (Version Support Policy, recon
findings), `docs/platform/nextui-field-notes.md` (the traps that
transferred), `docs/sprints/sprint-3.1-summary.md` (defect history).

## The task-runner process-group kill (the bring-up's field defect)

muOS's Task Toolkit kills the task's PROCESS GROUP when the task
script exits. A daemon started with a plain `... &` from a task dies
silently the moment the task returns — enrollment (synchronous)
worked, the cold-start push (daemon's job) never happened, and nothing
said why. Two rules came out of it:

1. **Every daemon spawn detaches via `setsid`** (new session AND
   process group; busybox carries the applet — nohup is the fallback).
   Assume boot init scripts get the same cleanup treatment.
2. **A spawner must verify and REPORT the start**: poll the PID file
   for liveness for a few seconds and print "Daemon confirmed alive
   (PID n)" or "did NOT stay up — see .continuity/continuity.log".
   A silently-dead daemon must be impossible.

## Version identity is unreliable (Version Support Policy)

The reference device reports TWO different versions about itself:
`/etc/os-release` says "muOS 2410 Banana" while
`/opt/muos/config/version.txt` says "2502.0_PIXIE" (owner: probably
Banana — not updated in a while). Consequence, owner-mandated:
**feature-probe, never version-gate**. Preflight records both strings
verbatim as diagnostics; every muOS path resolves by existence probe
with a fallback chain (see pal_muos.sh); nothing branches on a
version string.

## Storage layout (device-measured)

- SD1 is one card, three partitions: boot (vfat), muOS rootfs (ext4,
  invisible to Windows), and the big user partition — exFAT via
  fuseblk, mounted at `/mnt/mmc`. **A PC reader sees only /mnt/mmc**:
  every user file drop (zip extraction, setup.json) targets it.
- muOS bind-mounts stable indirections from the user partition:
  `/run/muos/storage/save/{file,state}` (→ `MUOS/save/...`),
  `/run/muos/storage/init` (→ `MUOS/init`), and more. The PAL prefers
  the `/run/muos/storage` paths and falls back to direct `MUOS/...`
  paths (older layouts).
- ROMs: `/mnt/union/ROMS` is a unionfs merge of SD1/SD2 ROMS — the
  canonical ROM view for ROM-anchored identity. Falls back to
  `/mnt/mmc/ROMS`.
- `/mnt/mmc` mount flags: `rw,nosuid,nodev` — **NOT noexec: binaries
  execute from the card** (proven by recon's exec probe; nosuid is
  irrelevant, everything runs as root). No symlinks (exFAT) — ship
  real file copies, same as the Brick.

## Saves are per-CORE, names are RetroArch style

`sort_savefiles_enable=true` → `save/file/<CoreName>/<rom_basename>.srm`
(Gambatte, mGBA, Snes9x, PCSX-ReARMed, Mupen64Plus-Next observed).
One core dir can serve TWO systems (Gambatte = GB+GBC — both proven in
the owner's real files), which is why platform-map schema 2.1 has
`rom_paths` and the mapper resolves shared save dirs by ROM anchor.
`save_file_compression=false` on the reference device and every real
save byte-checked raw — but the setting is user-flippable, so the RZIP
detector stays in the scanner (quarantine path). States:
`save/state/<Core>/<rom>.state[N]` with `.png` thumbnail siblings.

## Exec-probe trap (recon lesson)

A busybox copy probe-executed under an arbitrary filename reports
"applet not found" (rc 127) — which reads exactly like a failed exec
but actually PROVES the exec worked (multi-call dispatch on argv[0]).
Name probe copies `busybox`. The recon's heuristic now distinguishes
output-produced (exec worked) from silent rc 126/127 (exec failed).

## Boot hook: MUOS/init (toggle-gated)

muOS runs `MUOS/init/*.sh` during boot when **"User Init Scripts"** is
enabled: Configuration → General Settings → Advanced Settings
(documented in the muxtweakadv module; the storage mount exists on the
reference device). The shipped hook (`MUOS/init/continuity.sh`) must
return immediately — boot never blocks on Continuity — so it
setsid-spawns the daemon without the liveness wait and leaves a
breadcrumb in `.continuity/launch.log`. The Task Toolkit entry stays
the human-driven start/status/verify path.

## Userland facts (recon, 2026-07-09)

- Kernel 4.9.170 aarch64, Allwinner sun50iw9 (H700), 4× Cortex-A53,
  1 GB RAM; runs as root; `/tmp` is tmpfs.
- Buildroot glibc userland; `/bin/sh` → busybox **1.36.1** (same
  version we vendor — vendor anyway, drift across releases is the
  point).
- NO git, NO ssh/scp, NO inotifywait, NO `stat` applet. wget, curl,
  `timeout`, find, cmp, sha256sum present.
- The Brick's static aarch64 git (2.47.1) + busybox port cleanly:
  byte-identical copies enrolled a real device over TLS on first
  successful daemon run.
- WiFi + DNS + HTTPS to github.com work from the device; clock
  correct. muOS ships syncthing support, so long-running network
  daemons are a normal pattern on this firmware.

## Delivery

`scripts/build_muos_app.sh` → versioned zip whose tree mirrors the
card root (`.continuity/app/**`, `MUOS/task/*`, `MUOS/init/*`) —
install = Extract-All onto SD1's root. Binaries come from the
VERIFIED `build/Continuity.pak` set (byte-compare enforced), checksums
manifest byte-verified by on-device preflight. Never distribute from a
git working tree (CRLF history — NextUI field notes rule, carried
over).

## State size cap (owner decision, 2026-07-09)

The RG40XX V's N64 (~16-25 MB) and Dreamcast (~30 MB) states all hit
the original 8 MB `CONTINUITY_STATE_MAX_KB` default — the cap predated
big-console cores in the fleet. Owner raised the default to **64 MB**
(covers every current core, stays under GitHub's 100 MB hard file
limit; env-tunable per device). Companion defect, same log: a skipped
state re-candidates on every scan, so the warning repeated ~9×/30s
poll forever — `cd_state_size_ok` now warns once per file per daemon
run via a per-process ledger (subshell-safe).

## OTA updates (Sprint 3.2)

After the one-time zip install, muOS updates arrive over WiFi through
the same channel infrastructure as the Brick — `src/platforms/muos/update.sh`
(the ota_* functions) driven by the **"Continuity Update"** Task Toolkit
tap (`MUOS/task/Continuity Update.sh`).

- **Safety boundary (same as the Brick).** Scripts and the vendored
  busybox are OTA-safe: a torn or corrupt fetch fails verification and
  the live install is left untouched, and a bad busybox copy fails the
  daemon's fail-open self-test (falls back to device sh). A **git-binary
  change still warrants a card swap** — the transport the updater itself
  rides is not something to trust to a partial over-the-air copy.
- **Task-tap is the consent.** muOS has no show2 / button prompt, so
  tapping the task IS the go-ahead: it reports current → fetched
  version, stage-applies, and says the change takes effect on the next
  daemon restart/boot. Failures name themselves + the `.continuity/update.log`
  path; the exit code is honest.
- **Staged verified apply.** The updater fetches the channel's pinned
  commit into a persistent sparse clone at `.continuity/ota-repo`
  (sparse path `build/Continuity-muos.app`), verifies the fully
  materialized tree (CRLF scan on shipped scripts + checksums.txt
  byte/sha) BEFORE any copy touches the live tree, then fans the app out
  to `.continuity/app/**` and the `MUOS/task`/`MUOS/init` entries back to
  the card root. A verification failure copies nothing — no half-applied
  tree. Binaries are rewritten only when their size differs (SD wear +
  interruption window). Applied commit recorded in `.continuity/.ota_commit`.
- **Channels are data on main, not branches** (identical to NextUI): the
  durable channel name lives in `.continuity/ota_channel`, seeded once
  from the build's `ota_channel.txt` (default `nightly`), never
  overwritten by installs. Each check fetches `main`, reads
  `release/channels.json` via `git show` (no checkout), and fetches the
  pinned commit — file:// test remotes need `uploadpack.allowAnySHA1InWant`.
  Unpublished commits on main are invisible. **No legacy branch
  fallback** — NextUI's exists only for pre-manifest devices, and no
  such muOS devices exist; an unreachable/missing manifest simply holds.
- **One pin, whole fleet.** The same manifest commit carries both
  `build/Continuity.pak` (NextUI) and `build/Continuity-muos.app` (muOS),
  so `scripts/publish_channel.sh` publishing once updates every platform.
- **`CONTINUITY_OTA=0`** is the kill switch — every entry point checks
  it and names itself in the log.
- **SD-root derivation** never trusts `$0` alone: muOS bind-mounts
  `MUOS/task` to `/run/muos/storage/task`, so `$0/../..` resolves to
  tmpfs. The update task probes `/mnt/mmc` first (env-overridable) and
  records `$0` in the breadcrumb, same as the boot hook.
