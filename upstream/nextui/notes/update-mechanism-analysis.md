# NextUI Update Mechanism Analysis

## Overview

NextUI uses a **boot-time, full-replacement update system**. Updates are distributed as ZIP archives via GitHub releases, placed on the SD card by the user, and applied at boot before the main UI launches. The `.system/` directory on the SD card is deleted and replaced entirely on each update.

---

## Distribution

### Primary: GitHub Releases

Updates are published to `https://github.com/LoveRetro/NextUI/releases` as ZIP archives:

| Archive | Contents |
|---------|----------|
| `NextUI-YYYYMMDD-N-base.zip` | Complete system (MinUI.zip + Bios + Roms templates + Shaders + Overlays + vendored .pakz) |
| `NextUI-YYYYMMDD-N-extras.zip` | Additional emulator PAKs |
| `NextUI-YYYYMMDD-N-all.zip` | Base + Extras combined |

### Secondary: In-App Updater

The `nextui.updater.pakz` package (vendored into base releases) provides a UI for checking and downloading updates from within NextUI. This PAK is downloaded from `https://github.com/LoveRetro/nextui-updater-pak/releases`.

### Installation Method

Users download the release ZIP, extract it to their SD card root (`/mnt/SDCARD/`), and reboot the device.

---

## Package Format

### Outer Layer: Release ZIP

The release ZIP contains:
- `MinUI.zip` — The actual system update payload
- `Bios/`, `Roms/`, `Saves/` — Template directories (empty, for user content)
- `Shaders/`, `Overlays/`, `Cheats/` — Default assets
- `*.pakz` — Vendored PAK packages (Pak Store, Updater)
- `trimui/app/` — Installation bootstrap for first-time setup

### Inner Layer: MinUI.zip

The core update payload containing:
- `.system/{platform}/` — Complete system files (binaries, libraries, cores, PAKs, config)
- `.tmp_update/` — Platform-specific boot scripts (the updater itself)
- `Tools/` — Utility tool PAKs

### PAK Packages (.pakz)

Individual component packages using the `.pakz` extension. Each is a ZIP containing:
- Application files (binaries, scripts, resources)
- Optional `post_install.sh` for post-extraction setup

---

## Apply Process

### Boot Sequence

```
Device powers on
    │
    ▼
Stock firmware boot
    │ Calls /usr/trimui/bin/runtrimui.sh (TrimUI Brick)
    ▼
Check for updater
    │ Looks for /mnt/SDCARD/.tmp_update/updater
    ▼
┌─── Found? ───┐
│ Yes          │ No
▼              ▼
Run updater    Launch NextUI normally
    │
    ▼
Detect platform
    │ Reads /proc/cpuinfo
    │ Maps to: tg5040, tg5050, etc.
    ▼
Run platform script
    │ Executes .tmp_update/{platform}.sh
    ▼
Apply update (see below)
    │
    ▼
Launch NextUI
    │
    ▼
Force power off
    │ sysrq: sync → unmount → power off
    ▼
Done
```

### Platform Update Script (boot.sh → .tmp_update/tg5040.sh)

The platform-specific update script performs these steps:

1. **Show splash screen** — Uses `show2.elf` to display "Installing..." or "Updating..." with progress indication
2. **Set CPU to performance mode** — Clocks CPU to 2000MHz for faster extraction
3. **Disable legacy services** — Kills old LED daemon if present
4. **Process .pakz packages** (if any exist on SD card root):
   - Unzip each `.pakz` to SD card root
   - Execute `post_install.sh` if present in the extracted package
   - Delete the `.pakz` file
5. **Apply MinUI.zip** (if present on SD card root):
   - **Delete existing system components:**
     ```sh
     rm -rf $SYSTEM_PATH/$PLATFORM/bin
     rm -rf $SYSTEM_PATH/$PLATFORM/lib
     rm -rf $SYSTEM_PATH/$PLATFORM/paks/MinUI.pak
     ```
   - **Extract MinUI.zip** to `/mnt/SDCARD/`
   - **Run install.sh** if present at `$SYSTEM_PATH/$PLATFORM/bin/install.sh`
   - **Delete MinUI.zip**
6. **Launch MinUI.pak/launch.sh** — Start NextUI normally
7. **Cleanup** — Kill input daemon, kill splash screen
8. **Force power off** via sysrq

### Post-Update Migration (install.sh / update.sh)

The install script handles device-specific migrations:
- Remove old platform directories (e.g., tg3040 → tg5040 migration)
- Migrate user configuration from old platform userdata to new platform userdata
- Rename configuration files to match new naming conventions
- Reboot device for clean restart

---

## The .system Replacement Behavior

### What .system Contains

```
/mnt/SDCARD/.system/{platform}/
├── bin/          # Executables (nextui.elf, minarch.elf, keymon.elf, etc.)
├── lib/          # Shared libraries (libmsettings.so, libretro cores, etc.)
├── cores/        # Emulator cores
├── paks/
│   └── MinUI.pak/  # Main UI application PAK
├── etc/          # Config (bluetooth, wifi init scripts, system.cfg)
├── shaders/      # GLSL shader files
├── res/          # Resources (logos, etc.)
└── dbg/          # Debug tools (tg5040 only)
```

### Critical Design Constraint

**`.system/` is deleted and replaced every time a user updates NextUI.**

From PAKS.md:
> "This folder is deleted and replaced every time a user updates NextUI."

The update script selectively deletes `bin/`, `lib/`, and `paks/MinUI.pak/` before extracting the new version. Other directories (etc/, shaders/, res/) are overwritten by the zip extraction but not explicitly deleted first.

### Implications for Ideal OS

1. **Do NOT place Ideal OS removable components in `.system/`** — Updates will destroy them
2. **Ideal OS core services need a separate namespace** — Suggested: `/mnt/SDCARD/.ideal/` or similar
3. **The update coordinator (`updater` script) is the hook point** — Ideal OS can replace or extend this to implement its own OTA flow
4. **User data is safe** — `.userdata/` is never touched by the update system

---

## User Data Preservation

### Protected Directories (Never Touched by Updates)

| Path | Contents |
|------|----------|
| `/mnt/SDCARD/.userdata/{platform}/` | User configurations, save states, game preferences |
| `/mnt/SDCARD/Roms/` | User's ROM library |
| `/mnt/SDCARD/Saves/` | Game save files |
| `/mnt/SDCARD/Bios/` | BIOS files |

### Files Replaced by Updates

| Path | Replaced How |
|------|-------------|
| `.system/{platform}/bin/` | Deleted and re-extracted |
| `.system/{platform}/lib/` | Deleted and re-extracted |
| `.system/{platform}/paks/MinUI.pak/` | Deleted and re-extracted |
| `.system/{platform}/etc/` | Overwritten by extraction |
| `.system/{platform}/shaders/` | Overwritten by extraction |
| `.tmp_update/` | Overwritten by extraction |
| `Tools/` | Overwritten by extraction |

---

## Key Files in the Update Pipeline

| File | Location | Role |
|------|----------|------|
| `updater` | `skeleton/BOOT/common/updater` → `/mnt/SDCARD/.tmp_update/updater` | Boot-time coordinator — detects platform and dispatches |
| `boot.sh` | `workspace/tg5040/install/boot.sh` → `.tmp_update/tg5040.sh` | Platform-specific installer |
| `update.sh` | `workspace/tg5040/install/update.sh` → `.system/tg5040/bin/install.sh` | Post-update migration |
| `show2.elf` | Built from `workspace/all/show2/` → `BOOT/common/tg5040/show2.elf` | Splash screen during update |
| `MinUI.pak/launch.sh` | `skeleton/SYSTEM/tg5040/paks/MinUI.pak/launch.sh` | NextUI startup after update |

---

## Reuse Assessment for Ideal OS

### What Ideal OS Can Reuse

| Component | Reusability | Notes |
|-----------|-------------|-------|
| **Boot hook mechanism** | High | Intercepting boot via `.tmp_update/updater` is clean and reliable. Ideal OS can use the same mechanism. |
| **Platform detection** | High | Reading `/proc/cpuinfo` to determine platform is simple and correct. |
| **show2.elf progress display** | High | FIFO-based progress reporting is well-suited for OTA progress UI. |
| **User data isolation** | High | `.userdata/` separation is a good pattern. Ideal OS preserves this. |
| **CPU performance mode for updates** | Medium | Useful for faster package extraction. |
| **.pakz package processing** | Medium | Individual component packages could map to Ideal OS OTA packages, but the format needs manifest/versioning additions. |

### What Ideal OS Must Replace

| Component | Why |
|-----------|-----|
| **Full-replacement update strategy** | Ideal OS needs manifest-driven, package-oriented updates — not wholesale `.system/` replacement. |
| **No version tracking** | NextUI has no installed-state tracking, no version comparison, no update eligibility checks. |
| **No integrity verification** | No checksums, no signatures, no validation of extracted files. |
| **No migration system** | The `install.sh` migration is ad-hoc (hardcoded platform renames). Ideal OS needs schema-driven migrations. |
| **Manual delivery** | Users manually download and place ZIPs. Ideal OS needs automated download and staging. |
| **No rollback** | If an update fails mid-extraction, the system is left in a partially-updated state. |
| **No channel support** | No stable/beta/dev channels. Single release stream. |

### Integration Strategy

The Ideal OS OTA architecture (see `docs/architecture/ideal_os_ota_update_architecture_spec.md`) should:

1. **Keep the boot hook** — Use `.tmp_update/updater` (or an Ideal OS equivalent) as the update entry point
2. **Keep show2.elf** — Reuse for OTA progress display during apply
3. **Replace the update payload format** — Move from MinUI.zip to manifest-driven packages with checksums
4. **Add version tracking** — Implement `installed-state.json` per the OTA spec
5. **Add integrity verification** — SHA-256 checksums on all packages (Phase 1), signed manifests (Phase 2)
6. **Add automated download** — Fetch updates from a release server, stage in a dedicated directory
7. **Add migration support** — Detect schema version changes and run ordered migrations
8. **Separate Ideal OS from .system/** — Use a dedicated namespace that survives NextUI-style updates
9. **Add channel support** — stable/beta/dev update channels

---

## Summary

NextUI's update mechanism is simple and effective for its purpose: a single-developer project distributing firmware updates via GitHub releases. The boot-hook pattern and user-data isolation are solid foundations.

However, the mechanism lacks version tracking, integrity verification, automated delivery, migration support, rollback, and channel management — all of which are required by the Ideal OS OTA architecture. Ideal OS will reuse the boot-hook mechanism and progress display but replace the update payload format, delivery pipeline, and apply strategy with a manifest-driven system.
