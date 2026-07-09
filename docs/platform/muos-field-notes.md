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
