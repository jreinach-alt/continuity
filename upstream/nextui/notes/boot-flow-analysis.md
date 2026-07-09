# NextUI Boot Flow Analysis

## Overview

NextUI has two distinct boot flows, both triggered by the platform firmware calling a shell script at a fixed path:

1. **First Boot / Install-Update** — Triggered when `.tmp_update/updater` exists on the SD card. Handles platform detection, package extraction, system installation, and forces a power-off. This same flow handles both fresh installs and updates.

2. **Normal Boot** — Triggered when `.tmp_update/updater` does NOT exist. The platform's original boot script runs, which starts hardware init, daemons, and the NextUI launcher loop.

The key difference: the first-boot flow is **destructive and one-shot** (it replaces `.system/`, runs once, and forces power-off). The normal boot flow is the **steady-state loop** that runs every time the device powers on.

Both flows share the same initial entry point: the platform firmware calls a boot script at a well-known path (`/usr/trimui/bin/runtrimui.sh` on tg5040, `/etc/main` on trimuismart). NextUI replaces that script with its own dispatcher.

---

## Flow 1: First Boot / Install-Update

### Trigger Condition

The platform firmware calls `/usr/trimui/bin/runtrimui.sh` (on TrimUI Brick/Smart Pro). NextUI's replacement `runtrimui.sh` checks:

```sh
if [ -f /mnt/SDCARD/.tmp_update/updater ]; then
    /mnt/SDCARD/.tmp_update/updater
```

If `.tmp_update/updater` exists, the install flow runs. Otherwise, the normal boot path is taken.

### Execution Sequence

| Step | File | What Happens |
|------|------|-------------|
| 1 | `runtrimui.sh` | Waits for SD card mount (polls `/proc/mounts` up to 3 seconds), then dispatches to `updater` |
| 2 | `.tmp_update/updater` | Reads `/proc/cpuinfo`, maps CPU identifier to platform name (`TG5040`/`TG3040` → `tg5040`). Fallback: if no match but `/usr/trimui/bin/runtrimui.sh` exists, assumes `tg5040` |
| 3 | `.tmp_update/updater` | Executes platform-specific boot script: `.tmp_update/tg5040.sh` |
| 4 | `.tmp_update/tg5040.sh` | Detects device model (Brick vs Smart Pro) by inspecting strings in `/usr/trimui/bin/MainUI` |
| 5 | `.tmp_update/tg5040.sh` | Shows splash screen via `show2.elf` (if `MinUI.zip` or `.pakz` files exist). Supports custom splash via `.media/splash_logo.png` |
| 6 | `.tmp_update/tg5040.sh` | Sets CPU to max performance: userspace governor, 2000 MHz |
| 7 | `.tmp_update/tg5040.sh` | Cleans up old LED daemon (`LedControl`, `lcservice`) |
| 8 | `.tmp_update/tg5040.sh` | **Extracts `.pakz` packages** — for each `.pakz` file at SD card root: extracts with `unzip`, runs `post_install.sh` if present, deletes the `.pakz` |
| 9 | `.tmp_update/tg5040.sh` | **Installs/updates NextUI** — if `MinUI.zip` exists: deletes `bin/`, `lib/`, and `MinUI.pak/` from `.system/tg5040/`, extracts `MinUI.zip` to SD card root, deletes `MinUI.zip` |
| 10 | `.tmp_update/tg5040.sh` | Runs post-install migration: `.system/tg5040/bin/install.sh` (if present) |
| 11 | `install.sh` (update.sh) | Handles platform migration: detects old `tg3040` system folder, copies configs to `tg5040` userdata with `-brick.cfg` suffix, deletes old folder, reboots |
| 12 | `.tmp_update/tg5040.sh` | Launches NextUI: `.system/tg5040/paks/MinUI.pak/launch.sh` (runs full normal boot sequence once to verify installation) |
| 13 | `.tmp_update/tg5040.sh` | On return from `launch.sh`: kills `trimui_inputd`, calls `poweroff` |
| 14 | `.tmp_update/updater` | After platform script returns: forces immediate shutdown via sysrq (`echo s > /proc/sysrq-trigger`, sync, unmount, power off) |

### File Reference Table

| File | Source Path | Deployed Path | Role |
|------|------------|---------------|------|
| `runtrimui.sh` | `skeleton/BOOT/trimui/app/runtrimui.sh` | `/usr/trimui/bin/runtrimui.sh` | Platform boot dispatcher — chooses updater vs normal boot |
| `main.sh` | `skeleton/BOOT/trimui/app/main.sh` | `/etc/main` | Same role as `runtrimui.sh` but for trimuismart platform |
| `updater` | `skeleton/BOOT/common/updater` | `.tmp_update/updater` | Platform detector — maps CPU info to platform name |
| `tg5040.sh` (boot.sh) | `workspace/tg5040/install/boot.sh` | `.tmp_update/tg5040.sh` | Install/update orchestrator for tg5040 platform |
| `show2.elf` | built from `workspace/all/show2/` | `.tmp_update/tg5040/show2.elf` | Progress display daemon (FIFO-based: writes to `/tmp/show2.fifo`) |
| `unzip` | bundled | `.tmp_update/tg5040/unzip` | Archive extraction tool |
| `install.sh` (update.sh) | `workspace/tg5040/install/update.sh` | `.system/tg5040/bin/install.sh` | Post-install migration (tg3040 → tg5040) |
| `MinUI.zip` | release artifact | `/mnt/SDCARD/MinUI.zip` | NextUI system archive (consumed and deleted) |
| `.pakz` files | user/release | `/mnt/SDCARD/*.pakz` | Package archives (consumed and deleted) |

### Hook Points for Ideal OS

| Hook Point | File | Mechanism | Enables |
|------------|------|-----------|---------|
| **OTA dispatch** | `.tmp_update/updater` | Replace updater script to check for Ideal OS update manifest before falling through to NextUI install | Ideal OS OTA coordinator can run first, with NextUI install as fallback |
| **Package staging** | `.tmp_update/tg5040.sh` (step 8) | Use `.pakz` mechanism to deliver Ideal OS components — each `.pakz` can include a `post_install.sh` for setup | Deliver session manager, sync engine, etc. as packages without modifying NextUI install |
| **Integrity verification** | `.tmp_update/tg5040.sh` (step 9) | Wrap or replace the `unzip` step to add SHA-256 verification before extraction | Prevent corrupted updates from bricking the system |
| **Post-install hook** | `.system/tg5040/bin/install.sh` | Extend migration script to also set up Ideal OS runtime directories and migrate Ideal OS config | First-boot provisioning of Ideal OS data directories |
| **Progress UI** | `show2.elf` | Reuse FIFO-based progress reporting (`/tmp/show2.fifo`) for Ideal OS install steps | User sees unified install progress for both NextUI and Ideal OS |
| **Custom splash** | `.media/splash_logo.png` | Drop-in replacement, already supported by boot script | Brand the install experience |

---

## Flow 2: Normal Boot

### Trigger Condition

Platform firmware calls `/usr/trimui/bin/runtrimui.sh`. The script checks for `.tmp_update/updater` — if it does NOT exist, it calls the original boot script:

```sh
/usr/trimui/bin/runtrimui-original.sh
```

This stock script starts the TrimUI runtime, which eventually reaches `.system/tg5040/paks/MinUI.pak/launch.sh` — the NextUI entry point.

### Execution Sequence

| Step | File | What Happens |
|------|------|-------------|
| 1 | `runtrimui.sh` | Waits for SD card mount, falls through to `runtrimui-original.sh` |
| 2 | stock trimui init | Platform firmware initializes hardware, mounts filesystems, starts `trimui_inputd`, eventually calls `MainUI` path — but NextUI has replaced it |
| 3 | `MinUI.pak/launch.sh` | **Poweroff/reboot guard**: checks for `/tmp/poweroff` or `/tmp/reboot` sentinel files — exits early if found |
| 4 | `MinUI.pak/launch.sh` | **Environment setup**: exports all path variables (`SDCARD_PATH`, `SYSTEM_PATH`, `USERDATA_PATH`, `SAVES_PATH`, etc.) |
| 5 | `MinUI.pak/launch.sh` | **Directory provisioning**: creates `Bios/`, `Roms/`, `Saves/`, `Cheats/`, `.userdata/`, logs directories |
| 6 | `MinUI.pak/launch.sh` | **Device detection**: determines Brick vs Smart Pro via `strings /usr/trimui/bin/MainUI` |
| 7 | `MinUI.pak/launch.sh` | **LED daemon cleanup**: removes old `LedControl`/`lcservice` |
| 8 | `MinUI.pak/launch.sh` | **Shader cache clear**: removes `.shadercache/` unconditionally |
| 9 | `MinUI.pak/launch.sh` | **GPIO init**: exports and configures GPIO pins (VCC-5V on PD11, rumble motor on PH3, gamepad on PD14/PD18 for Smart Pro, DIP switch on PH19) |
| 10 | `MinUI.pak/launch.sh` | **Syslog start**: `syslogd -S` |
| 11 | `MinUI.pak/launch.sh` | **PATH/LD_LIBRARY_PATH setup**: prepends `.system/tg5040/bin` and `.system/tg5040/lib` |
| 12 | `MinUI.pak/launch.sh` | **LED off**: writes 0 to `max_scale` (and `max_scale_lr`, `max_scale_f1f2` on Brick) |
| 13 | `MinUI.pak/launch.sh` | **Input daemon**: starts stock `trimui_inputd` |
| 14 | `MinUI.pak/launch.sh` | **CPU governor**: sets userspace governor at 2000 MHz |
| 15 | `MinUI.pak/launch.sh` | **Daemon startup**: launches `keymon.elf`, `batmon.elf`, `audiomon.elf` in background |
| 16 | `MinUI.pak/launch.sh` | **Bluetooth init**: reads setting via `nextval.elf bluetooth`, starts/stops BT via `bt_init.sh` |
| 17 | `MinUI.pak/launch.sh` | **WiFi init**: reads setting via `nextval.elf wifi`, starts/stops WiFi via `wifi_init.sh` |
| 18 | `MinUI.pak/launch.sh` | **User auto script**: runs `$USERDATA_PATH/auto.sh` if it exists (user hook point) |
| 19 | `MinUI.pak/launch.sh` | **Kill show2**: kills any lingering splash screen process |
| 20 | `MinUI.pak/launch.sh` | **Main loop**: creates `/tmp/nextui_exec` sentinel, enters `while` loop |
| 21 | `nextui.elf` | **Launcher UI**: displays ROM library, collections, game art, settings. User navigates and selects games |
| 22 | `MinUI.pak/launch.sh` | **Game dispatch**: when `nextui.elf` exits, checks `/tmp/next` for a command, `eval`s it (typically launches a PAK's `launch.sh` with ROM path) |
| 23 | PAK `launch.sh` | **Emulator launch**: PAK script sets up emulator, calls `minarch.elf` with libretro core and ROM |
| 24 | `MinUI.pak/launch.sh` | **Loop continues**: after game exits, resets CPU speed, loops back to step 21 |
| 25 | `MinUI.pak/launch.sh` | **Shutdown**: on `/tmp/poweroff` or `/tmp/reboot` sentinel, calls `poweroff_next` or `reboot_next` |

### File Reference Table

| File | Source Path | Deployed Path | Role |
|------|------------|---------------|------|
| `runtrimui.sh` | `skeleton/BOOT/trimui/app/runtrimui.sh` | `/usr/trimui/bin/runtrimui.sh` | Boot dispatcher |
| `MinUI.pak/launch.sh` | `skeleton/SYSTEM/tg5040/paks/MinUI.pak/launch.sh` | `.system/tg5040/paks/MinUI.pak/launch.sh` | NextUI startup orchestrator — hardware init, daemons, main loop |
| `nextui.elf` | built from `workspace/all/nextui/` | `.system/tg5040/bin/nextui.elf` | Main launcher UI (ROM browser, collections, settings) |
| `keymon.elf` | built from `workspace/tg5040/keymon/` | `.system/tg5040/bin/keymon.elf` | Keyboard/button input monitor daemon |
| `batmon.elf` | built from `workspace/tg5040/batmon/` | `.system/tg5040/bin/batmon.elf` | Battery monitoring and LED control daemon |
| `audiomon.elf` | built from `workspace/tg5040/audiomon/` | `.system/tg5040/bin/audiomon.elf` | Audio state monitoring daemon |
| `nextval.elf` | built from `workspace/all/nextval/` | `.system/tg5040/bin/nextval.elf` | JSON settings reader (reads `systemval.json`) |
| `minarch.elf` | built from `workspace/all/minarch/` | `.system/tg5040/bin/minarch.elf` | Libretro frontend — launches emulator cores |
| `poweroff_next` | built from `workspace/tg5040/poweroff_next/` | `.system/tg5040/bin/poweroff_next` | Safe shutdown: kills processes, unmounts SD, triggers PMIC power off |
| `bt_init.sh` | `skeleton/SYSTEM/tg5040/etc/bluetooth/bt_init.sh` | `.system/tg5040/etc/bluetooth/bt_init.sh` | Bluetooth initialization |
| `wifi_init.sh` | `skeleton/SYSTEM/tg5040/etc/wifi/wifi_init.sh` | `.system/tg5040/etc/wifi/wifi_init.sh` | WiFi initialization |
| `trimui_inputd` | stock firmware | `/usr/trimui/bin/trimui_inputd` | Stock input daemon (not part of NextUI) |
| `auto.sh` | user-created | `.userdata/tg5040/auto.sh` | Optional user script — runs once per boot before launcher |

### Hook Points for Ideal OS

| Hook Point | File | Mechanism | Enables |
|------------|------|-----------|---------|
| **Boot dispatcher** | `runtrimui.sh` | Replace to add Ideal OS boot coordinator before falling through to NextUI | Boot animation, integrity check, session resume decision before NextUI launches |
| **Launch script replacement** | `MinUI.pak/launch.sh` | Replace with Ideal OS version that starts Ideal OS subsystems before entering the NextUI main loop | Session Manager, Task Scheduler, Cloud Sync, Notification System startup |
| **auto.sh hook** | `.userdata/tg5040/auto.sh` | Create this file to run arbitrary code before `nextui.elf` starts — no NextUI modification needed | Lightweight Ideal OS bootstrap without replacing `launch.sh`. Limited: runs once, no loop integration |
| **Game launch intercept** | `/tmp/next` signal file | Wrap the `eval` of `/tmp/next` contents to log game launches, update session state, trigger sync | Session tracking, play-time logging, cloud save triggers |
| **Pre-launcher injection** | `MinUI.pak/launch.sh` (between daemon start and main loop) | Insert Ideal OS subsystem startup after step 17 (WiFi) and before step 20 (main loop) | All Ideal OS background services running before UI appears |
| **Shutdown hook** | `poweroff_next` / `/tmp/poweroff` sentinel | Intercept shutdown signal to flush session state and sync before power off | Graceful session persistence, cloud save upload on shutdown |
| **Environment extension** | `MinUI.pak/launch.sh` (exports) | Add Ideal OS environment variables (e.g., `IDEAL_SESSION_ID`, `IDEAL_HOME`) to the export block | All child processes (PAKs, emulators) inherit Ideal OS context |

---

## Comparison Table

| Aspect | First Boot / Install-Update | Normal Boot |
|--------|---------------------------|-------------|
| **Trigger** | `.tmp_update/updater` exists | `.tmp_update/updater` absent |
| **Entry point** | `runtrimui.sh` → `updater` → `tg5040.sh` | `runtrimui.sh` → `runtrimui-original.sh` → `launch.sh` |
| **Purpose** | Install/update system files | Run the launcher and games |
| **Destructive** | Yes — deletes and replaces `.system/` | No — reads `.system/` only |
| **User interaction** | Splash screen only, no input | Full UI interaction |
| **Duration** | ~30 seconds, ends with forced power-off | Entire session until user powers off |
| **Runs `launch.sh`** | Yes, once (for verification) | Yes, continuously (main loop) |
| **Daemon startup** | Via `launch.sh` (same as normal boot) | Via `launch.sh` |
| **Package extraction** | `.pakz` and `MinUI.zip` | None |
| **Ends with** | `poweroff` + sysrq forced shutdown | `poweroff_next` (graceful) |

---

## Open Questions (Device-Dependent)

These require on-device testing, flagged for Sprint 1.2 (First Boot and Smoke Test):

1. **Stock boot chain**: What exactly does the stock TrimUI firmware do between power-on and calling `runtrimui.sh`? How much time elapses? Is there a bootloader we can hook?

2. **`runtrimui-original.sh` behavior**: What does the stock `runtrimui-original.sh` do before reaching `launch.sh`? Does it start any services that conflict with NextUI/Ideal OS?

3. **`auto.sh` timing**: How early does `auto.sh` run relative to UI display? Is there enough time to start background services before the user sees the launcher?

4. **Shutdown reliability**: Does `poweroff_next` reliably flush all pending writes? What happens if cloud sync is mid-upload during shutdown?

5. **Boot time budget**: How much time can Ideal OS add to the boot sequence before it feels slow? What's the current power-on to launcher-visible time?
