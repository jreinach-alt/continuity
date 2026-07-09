# NextUI Component Manifest

This manifest documents every major directory and significant file in the NextUI source tree (`upstream/nextui/src/`), assigning each a disposition for Ideal OS integration.

**Disposition key:**

| Disposition | Meaning |
|-------------|---------|
| **Keep** | Use as-is. Stable platform layer — no Ideal OS modifications planned. |
| **Wrap** | Keep the component but add hooks, wrappers, or shims around it for Ideal OS integration. |
| **Branch** | Fork and incrementally modify. Too central to use as-is but too complex to rewrite from scratch. |
| **Rewrite** | Replace entirely with an Ideal OS native implementation. |
| **Reject** | Do not use. Stale, incompatible, or architecturally misaligned. |
| **Reference** | Not code — documentation, assets, or tooling used during development only. |

**Source:** Dispositions are derived from `docs/architecture/ideal_os_platform_component_audit_matrix.md`. Where the audit matrix doesn't cover a specific file, a reasoned disposition is provided with rationale.

---

## Root Files

### `makefile` — Top-Level Build Orchestrator

**Purpose:** Coordinates the full build pipeline: setup → build platforms → package releases.
**Disposition:** Keep
**Rationale:** Build orchestration is platform infrastructure. Ideal OS will extend or fork the build system in Phase 1 but the structure is sound.

### `makefile.toolchain` — Cross-Compilation Wrapper

**Purpose:** Docker-based cross-compilation. Pulls platform-specific toolchain images from `ghcr.io/loveretro/{PLATFORM}-toolchain` and runs builds inside containers.
**Disposition:** Keep
**Rationale:** Toolchain isolation via Docker is good practice. Ideal OS will use the same approach.

### `makefile.native` — Native Desktop Build

**Purpose:** Desktop (macOS/Linux) build variant using system GCC. Used for development and testing without target hardware.
**Disposition:** Keep
**Rationale:** Desktop builds are essential for development velocity.

### `.env_desktop` — Desktop Environment Config

**Purpose:** Sets `PLATFORM=desktop`, library paths, and userdata paths for local development.
**Disposition:** Keep
**Rationale:** Development infrastructure.

### `LICENSE`

**Purpose:** Project license (GPL).
**Disposition:** Keep
**Rationale:** Legal requirement.

### `README.md`, `PAKS.md`

**Purpose:** Project documentation. `PAKS.md` documents the PAK extension system.
**Disposition:** Reference
**Rationale:** Documentation only — not shipped.

### `commits.sh`

**Purpose:** Git commit history helper script.
**Disposition:** Reference
**Rationale:** Developer tooling.

### `todo.txt`

**Purpose:** Upstream development TODO tracker.
**Disposition:** Reference
**Rationale:** Upstream planning artifact.

### `tsan.supp`

**Purpose:** ThreadSanitizer suppressions for development builds.
**Disposition:** Keep
**Rationale:** Development tooling.

### `.gitignore`

**Purpose:** Git ignore rules.
**Disposition:** Keep

---

## `github/` — GitHub Assets

**Purpose:** README documentation, screenshots, and logo assets for the GitHub repository page.
**Key files:** `README.md`, `generate_screenshots.sh`, 15 PNG images (logos, UI screenshots).
**Disposition:** Reference
**Rationale:** GitHub presentation only. Ideal OS will have its own branding.

---

## `workspace/` — Source Code

### `workspace/makefile` — Workspace Build Orchestrator

**Purpose:** Coordinates compilation of all subsystems. Builds platform-specific early stage, then shared components, then platform final stage.
**Disposition:** Keep
**Rationale:** Build infrastructure.

---

### `workspace/all/` — Shared Components (All Platforms)

#### `workspace/all/nextui/` — Main Launcher

**Purpose:** Primary UI shell — game browsing, selection, launching, resume stack, quick menu, game switcher.
**Key files:** `nextui.c` (3362 lines, 103KB), `Makefile`
**Disposition:** Branch
**Rationale:** Too central to use as-is. Ideal OS needs session-aware UI, resume stack integration, notification display, and sync status. Will be branched and incrementally modified.
**Internals (see Resolved Questions Q1-Q3 for details):**
- **Game list:** Filesystem scan of `/Roms/` with optional `map.txt` aliasing. No database — rebuilt from disk every session.
- **Resume/recents:** File-based — `recent.txt` (24 entries max), save slot files for resume detection, `auto_resume.txt` for crash recovery.
- **Rendering:** SDL2 software rendering via `GFX_*()` wrappers. Three async worker threads (background loader, thumbnail loader, animation). Dirty-rect optimization, ~60 FPS with v-sync.
- **Game launch:** Adds to recents → writes resume slot to `/tmp/resume_slot.txt` → queues emulator command → exits launcher. Emulator is a separate process.
- **Navigation:** Directory stack model. Push on enter, pop on back. Alphabetic jump via L1/R1.

#### `workspace/all/minarch/` — Emulator Runtime Engine

**Purpose:** Minimal libretro front-end. Handles core loading, rendering, audio, input mapping, rewind, fast-forward, RetroAchievements, in-game quick menu, and CHD disc image support.
**Key files:** `minarch.c` (9209 lines, 272KB), `chd_reader.c/h`, `ra_integration.c/h`, `ra_consoles.h`, `rcheevos/` (RetroAchievements library), `libchdr.makefile`, `rcheevos.makefile`
**Disposition:** Wrap
**Rationale:** Core emulation engine is stable and feature-rich. Ideal OS wraps the launch path to hook session creation, suspend/resume, and gameplay policies. No need to modify the emulation internals.
**Internals (see Resolved Questions Q4-Q5 for details):**
- **Save states:** Multiple formats (default `.st0`–`.st8`). Raw libretro serialization, optional RASTATE header. Slot 9 is auto-resume (saved on exit, loaded on next launch via `/tmp/resume_slot.txt`).
- **SRAM:** `Saves/<System>/Game.sav` — written on game exit only. No intermediate checkpointing.
- **Rewind:** In-memory circular buffer (default 64MB), LZ4-compressed delta encoding. Does NOT survive suspend/resume — buffer cleared on state load/save/exit.
- **Launch protocol:** `minarch <core.so> <rom.path>`. Core loaded via `dlopen()`. ROM auto-extracted from zip to `/tmp/nextarch/<tag>/` if needed.
- **RetroAchievements:** rcheevos client, per-frame evaluation. Hardcore mode blocks save states. Can be fully disabled via settings.
- **Quick menu:** MENU button → pause emulation → save/load/options/quit overlay.

#### `workspace/all/common/` — Shared Libraries

**Purpose:** Shared C headers and implementations used by all components. Provides the core API surface.
**Key files:**

| File | Size | Purpose |
|------|------|---------|
| `api.h` / `api.c` | 29KB / 114KB | Graphics (GFX_), Sound (SND_), Input (PAD_), Power (PWR_), Haptics (VIB_), WiFi, Bluetooth, Timezone, Platform HAL |
| `config.h` / `config.c` | 11KB / 36KB | Settings persistence via `NextUISettings` struct and CFG_ getter/setter interface |
| `defines.h` | 6KB | Path constants (`/mnt/SDCARD/...`), hardware limits, color schemes, display resolution (1024x768) |
| `utils.h` / `utils.c` | 15KB | String manipulation, file I/O helpers |
| `scaler.h` / `scaler.c` | 21KB / 110KB | Image scaling algorithms (SHARP, CRISP, SOFT modes) |
| `notification.h` / `notification.c` | 5KB / 20KB | Toast/overlay notification system |
| `http.h` / `http.c` | 3KB / 9KB | HTTP client (sync/async GET/POST, 8MB max response, 30s timeout) |
| `ra_auth.h` / `ra_auth.c` | — | RetroAchievements authentication |
| `ra_badges.h` / `ra_badges.c` | — | Achievement badge rendering |
| `generic_wifi.c` | — | WiFi abstraction |
| `generic_bt.c` | — | Bluetooth abstraction |
| `generic_video.c` | — | Video subsystem abstraction |
| `sdl.h` | — | SDL2 wrapper definitions |

**Disposition:** Keep
**Rationale:** This is the core platform abstraction layer. Hardware integration, WiFi, Bluetooth, display, and input are all stable and well-tested. Ideal OS builds on top of this, not around it.

#### `workspace/all/settings/` — Settings Application

**Purpose:** System configuration UI. Manages WiFi, Bluetooth, theme/color customization, power timeouts, display settings, emulator preferences, and RetroAchievements credentials.
**Key files:** `settings.cpp` (52KB), `menu.cpp/hpp`, `btagent.cpp/hpp`, `btmenu.cpp/hpp`, `keyboardprompt.cpp/hpp`, `wifimenu.cpp/hpp`, `makefile`
**Disposition:** Branch
**Rationale:** Settings UI needs Ideal OS-specific pages (sync settings, notification preferences, session management, OTA channel selection). Core WiFi/BT/display settings can stay.

#### `workspace/all/show2/` — Splash/Loading Screen Tool

**Purpose:** Boot and loading screen display. Three modes: simple (static logo), progress (logo + progress bar + text), daemon (FIFO-controlled runtime updates via `/tmp/show2.fifo`).
**Key files:** `show2.cpp` (252KB directory), embedded TTF font, `boot-integration-example.sh`
**FIFO commands:** `TEXT:message`, `PROGRESS:0-100`, `BGCOLOR:0xRRGGBB`, `QUIT`
**Disposition:** Keep
**Rationale:** Useful for boot splash, OTA progress display, and system notifications. The FIFO daemon interface is clean and reusable.

#### `workspace/all/batmon/` — Battery Monitor Service

**Purpose:** Background daemon polling battery status every 15 seconds. Logs to SQLite via `libbatmondb`. Tracks session time and best-session records.
**Key files:** `batmon.c`, `makefile`
**Disposition:** Keep
**Rationale:** Battery monitoring is platform infrastructure. No Ideal OS modifications needed.

#### `workspace/all/battery/` — Battery Statistics UI

**Purpose:** Interactive battery history graph and session statistics viewer. Reads from `batmondb`.
**Key files:** `battery.c`, `makefile`
**Disposition:** Keep
**Rationale:** User-facing tool PAK. No modifications needed.

#### `workspace/all/libbatmondb/` — Battery Database Library

**Purpose:** SQLite wrapper for battery monitoring data. FILO log rotation (minimum 1000 entries).
**Key files:** `batmondb.c/h`, `makefile`
**Disposition:** Keep
**Rationale:** Internal library for batmon/battery. Stable.

#### `workspace/all/gametime/` — Playtime Tracker UI

**Purpose:** Display and manage per-game playtime statistics with thumbnail rendering.
**Key files:** `gametime.c`, `makefile`
**Disposition:** Keep
**Rationale:** User-facing tool PAK. Could be wrapped later if Library Manager needs to integrate playtime data, but no immediate changes.

#### `workspace/all/gametimectl/` — Playtime Control Tool

**Purpose:** CLI tool for game time tracking operations.
**Key files:** `gametimectl.c`, `makefile`
**Disposition:** Keep
**Rationale:** Background service supporting gametime.

#### `workspace/all/libgametimedb/` — Playtime Database Library

**Purpose:** SQLite wrapper for game playtime tracking data.
**Key files:** `gametimedb.c/h`, `makefile`
**Disposition:** Keep
**Rationale:** Internal library. Stable.

#### `workspace/all/minput/` — Input Test/Control Tool

**Purpose:** Input handling UI — displays button states and input events. Used as the "Input" tool PAK.
**Key files:** `minput.c`, `makefile`
**Disposition:** Keep
**Rationale:** Diagnostic/utility tool PAK. No modifications needed.

#### `workspace/all/nextval/` — Config Value CLI

**Purpose:** Command-line tool for querying and setting configuration values. Outputs JSON: `{"key": value}`.
**Key files:** `nextval.c`, `makefile`
**Usage:** `nextval <key>` (print single value) or `nextval` (print all config as JSON)
**Disposition:** Keep
**Rationale:** Useful for shell scripts that need to query device configuration.

#### `workspace/all/clock/` — Clock Tool

**Purpose:** Clock display/set utility PAK.
**Key files:** `clock.c`, `makefile`
**Disposition:** Keep
**Rationale:** Utility tool PAK. No modifications needed.

#### `workspace/all/bootlogo/` — Boot Logo Tool

**Purpose:** Boot logo customization utility.
**Key files:** `bootlogo.c`, `makefile`
**Disposition:** Keep / Wrap
**Rationale:** Ideal OS may want to set its own boot logo. The tool itself can stay; the default logo asset changes.

#### `workspace/all/ledcontrol/` — LED Control Utility

**Purpose:** LED customization tool for devices with LED support (tg5040/tg5050).
**Key files:** `ledcontrol.c`, `makefile`
**Disposition:** Keep
**Rationale:** Hardware utility. No modifications needed.

#### `workspace/all/audiomon/` — Audio Monitor

**Purpose:** Audio device monitoring daemon. Watches for audio device changes.
**Key files:** `audiomon.cpp`, `Makefile`
**Disposition:** Keep
**Rationale:** Platform service. Stable.

#### `workspace/all/syncsettings/` — Settings Sync

**Purpose:** Synchronizes settings across platform reboots and updates.
**Key files:** C++ implementation, `makefile`
**Disposition:** Keep / Wrap
**Rationale:** May need integration with Ideal OS Cloud Sync in Phase 5. For now, keep as-is.

#### `workspace/all/cores/` — Emulator Core Patches

**Purpose:** Build rules and patches for RetroArch emulator cores.
**Key files:** `patches/` subdirectory with gambatte (Game Boy) and pokemini (Pokemon Mini) patches.
**Disposition:** Keep
**Rationale:** Core emulation patches are platform-specific and well-tested.

#### `workspace/all/readmes/` — Documentation Build

**Purpose:** Build target for generating README documentation.
**Key files:** `makefile`
**Disposition:** Reference
**Rationale:** Documentation tooling only.

---

### `workspace/tg5040/` — TrimUI Brick (TG5040) Platform

This is the **primary target platform** for Ideal OS.

#### `workspace/tg5040/makefile` — Platform Build Orchestrator

**Purpose:** Coordinates early-stage and final-stage platform-specific builds.
**Disposition:** Keep

#### `workspace/tg5040/platform/` — Hardware Abstraction Layer

**Purpose:** TG5040-specific HAL implementation. Defines joystick mapping (Brick-specific reversed A/B), key codes, analog axes, screen resolution (1024x768 RGB565 @ 60.235 FPS), LED support (4 LEDs), CPU frequency scaling, power management, audio device polling.
**Key files:** `platform.c` (26KB), `platform.h` (150 lines), `makefile.env`, `makefile.copy`
**Disposition:** Keep
**Rationale:** Core hardware integration. This is the strongest reason to use NextUI as the base platform. Do not modify.

#### `workspace/tg5040/keymon/` — Input Event Monitor

**Purpose:** Low-level input event monitor for TG5040. Reads from `/dev/input/event*` (5 input devices), dispatches volume/brightness/colortemp adjustments, monitors mute state via GPIO, provides haptic feedback.
**Key files:** `keymon.c`
**Hardware integration:** GPIO (`/sys/class/gpio/gpio243/value`), motor control (`/sys/class/motor/voltage`), `msettings` API.
**Disposition:** Keep
**Rationale:** Hardware-specific input handling. Critical platform service.

#### `workspace/tg5040/libmsettings/` — Platform Settings Library

**Purpose:** Platform-specific settings persistence library. Provides `SetVolume`, `SetBrightness`, `SetColortemp`, `GetMute`, `SetMute`, `GetJack`, `SetJack` and other device-specific settings APIs.
**Disposition:** Keep
**Rationale:** Hardware configuration layer. All components depend on this.

#### `workspace/tg5040/btmanager/` — Bluetooth Manager

**Purpose:** Bluetooth device management for TG5040. 3-level deep directory structure.
**Disposition:** Keep
**Rationale:** Hardware connectivity. Stable.

#### `workspace/tg5040/cores/` — Platform Core Patches

**Purpose:** TG5040-specific emulator core build rules and patches.
**Disposition:** Keep
**Rationale:** Platform-specific core optimizations.

#### `workspace/tg5040/install/` — Installation Scripts

**Purpose:** Device installation and update scripts.
**Key files:**
- `boot.sh` → Becomes `.tmp_update/tg5040.sh` — Boot-time update installer
- `update.sh` → Becomes `.system/tg5040/bin/install.sh` — Post-update setup and migration
**Disposition:** Branch
**Rationale:** Ideal OS will modify the boot and update flow for its own OTA system. The existing scripts are the starting point.
**Open questions:** Can the boot script be extended to support Ideal OS OTA alongside NextUI updates? What is the exact handoff point where Ideal OS takes control?

#### `workspace/tg5040/poweroff_next/` — Power-Off Handler

**Purpose:** Handles clean power-off sequence for TG5040.
**Disposition:** Keep
**Rationale:** Platform power management. Critical for data integrity.

#### `workspace/tg5040/rfkill/` — RF Kill Control

**Purpose:** Wireless radio enable/disable utility.
**Key files:** `rfkill.elf` output
**Disposition:** Keep
**Rationale:** Hardware utility.

---

### `workspace/tg5050/` — TrimUI Brick (TG5050) Platform

Secondary target platform (TG5050 variant of the Brick).

#### `workspace/tg5050/makefile` — Platform Build Orchestrator

**Disposition:** Keep

#### `workspace/tg5050/platform/` — TG5050 HAL

**Purpose:** TG5050-specific hardware abstraction.
**Disposition:** Keep
**Rationale:** Same rationale as TG5040 — core hardware integration.

#### `workspace/tg5050/keymon/` — TG5050 Input Monitor

**Disposition:** Keep

#### `workspace/tg5050/libmsettings/` — TG5050 Settings Library

**Disposition:** Keep

#### `workspace/tg5050/cores/` — TG5050 Core Patches

**Disposition:** Keep

#### `workspace/tg5050/install/` — TG5050 Installation Scripts

**Disposition:** Branch
**Rationale:** Same as TG5040 — Ideal OS OTA integration point.

#### `workspace/tg5050/other/` — Miscellaneous Utilities

**Disposition:** Keep

---

### `workspace/desktop/` — Desktop Development Platform

#### `workspace/desktop/makefile` — Desktop Build Rules

**Disposition:** Keep

#### `workspace/desktop/platform/` — Desktop Platform Layer

**Purpose:** Desktop HAL implementation for development builds. Emulates device hardware using standard desktop APIs.
**Disposition:** Keep

#### `workspace/desktop/libmsettings/` — Desktop Settings Library

**Purpose:** Desktop-specific settings implementation.
**Disposition:** Keep

#### `workspace/desktop/cores/` — Desktop Core Patches

**Disposition:** Keep

#### `workspace/desktop/macos_create_gcc_symlinks.sh` — macOS Build Helper

**Purpose:** Creates GCC symlinks for Homebrew on macOS (needed because Homebrew uses versioned binary names).
**Disposition:** Keep

#### `workspace/desktop/prepare_fake_sd_root.sh` — Development Helper

**Purpose:** Creates a fake SD card root directory for desktop testing.
**Disposition:** Keep

---

### `workspace/_unmaintained/` — Legacy Platforms

**Purpose:** Historical device support for platforms no longer actively maintained. Contains platform-specific directories for 11 legacy devices.

**Platforms:**

| Directory | Device | Subdirectories |
|-----------|--------|---------------|
| `gkdpixel/` | GKD Pixel | 9 |
| `m17/` | M17 | 7 |
| `magicmini/` | Magic Mini | 6 |
| `miyoomini/` | Miyoo Mini | 12 |
| `my282/` | MY282 | 11 |
| `my355/` | MY355 | 9 |
| `rg35xx/` | RG35XX | 10 |
| `rg35xxplus/` | RG35XX Plus | 9 |
| `rgb30/` | RGB30 | 7 |
| `trimuismart/` | TrimUI Smart | 8 |
| `zero28/` | Zero28 | 8 |

**Disposition:** Reject (for Ideal OS purposes)
**Rationale:** Ideal OS targets TrimUI Brick (tg5040/tg5050) only. These legacy platforms are not relevant to Ideal OS development and will not be maintained.

---

## `skeleton/` — Runtime Filesystem Template

The skeleton directory defines the complete on-device directory structure. It is **not compiled** — it is copied to the SD card as-is during packaging.

### `skeleton/BASE/` — Base User Directory Structure

**Purpose:** Template for user-facing ROM library and data directories.
**Contents:**

| Directory | Purpose |
|-----------|---------|
| `Roms/` | Game ROM directories (GBA, GBC, PS, MD, SFC, FC, GB) |
| `Saves/` | Save game directories (one per system) |
| `Bios/` | BIOS files (one per system) |
| `Overlays/` | Game overlays/bezels (per-system subdirectories) |
| `Shaders/` | GLSL shader files |
| `Cheats/` | Cheat code databases (per system) |

**Disposition:** Keep
**Rationale:** Standard ROM library structure. Users expect this layout. Ideal OS preserves user-facing SD card structure.

### `skeleton/BOOT/` — Boot/Startup Configuration

**Purpose:** System bootstrap files executed during firmware boot.
**Contents:**

| File | Purpose |
|------|---------|
| `common/updater` | Boot-time update coordinator — detects platform from `/proc/cpuinfo` and dispatches to platform-specific script |
| `trimui/app/main.sh` | Main boot script |
| `trimui/app/MainUI` | Main UI binary placeholder |
| `trimui/app/keymon` | Keypad monitoring binary placeholder |
| `trimui/app/runtrimui.sh` | TrimUI launcher script |

**Disposition:** Branch
**Rationale:** Boot flow is a critical integration point. Ideal OS modifies boot to inject session resume, OTA check, and its own launcher startup. The existing updater coordinator is the starting point.
**Open questions:** Exact handoff point for Ideal OS boot sequence (Sprint 0.4 scope).

### `skeleton/SYSTEM/` — Core System Files

**Purpose:** Platform-specific runtime files deployed to `.system/` on the SD card.
**Contents (per platform — tg5040, tg5050, desktop):**

| Directory | Purpose |
|-----------|---------|
| `paks/MinUI.pak/` | Main UI application PAK (launch.sh + config) |
| `paks/Emus/` | Emulator PAKs (MD.pak, SFC.pak, PS.pak, GBA.pak, GBC.pak, FC.pak, GB.pak) |
| `etc/` | System configuration (bluetooth/bt_init.sh, wifi/wifi_init.sh) |
| `system.cfg` | System configuration file |
| `bin/` | Executables (suspend) |
| `lib/` | Shared libraries |
| `shaders/` | GLSL shaders (pixellate, noshader, overlay, colorfix, default) |
| `cores/` | Emulator cores |
| `dbg/` | Debug tools (tg5040 only) |
| `res/` | Resources (logo, etc.) |

**Disposition:** Branch
**Rationale:** Ideal OS modifies the system layout — adding its own services, adjusting PAK structure, and inserting its runtime directories alongside the NextUI system. The existing layout is the starting point.

### `skeleton/EXTRAS/` — Extended ROM & Tools Library

**Purpose:** Optional content beyond the base system — additional ROM system directories, extra emulator PAKs, and utility tool PAKs.

**ROM Systems (31+ beyond BASE):** NGP, 32X, MSX, SGB, GG, NGPC, Sega CD, Amstrad CPC, PKM, Atari 2600, PRBOOM, VB, LYNX, C64, C128, Colecovision, P8, Plus/4, SMS, SG-1000, FBN, PET, Atari 5200, PUAE, PCE, VIC20, Atari 7800, SUPA, FDS, and more.

**Tool PAKs (per-platform):** Clock.pak, Game Tracker.pak, Battery.pak, Settings.pak, Input.pak, LedControl.pak, Remove Loading.pak, Bootlogo.pak, Files.pak

**Extra Emulator PAKs:** 28+ additional emulator packages for extended systems.

**Standard directories:** Saves/, Bios/, Overlays/, Cheats/ for all extended systems.

**Disposition:** Keep
**Rationale:** Extended content is user-facing and doesn't affect Ideal OS core. Keep the full ROM system library and optional tools.

### `skeleton/_unmaintained/` — Legacy Device Overlays

**Purpose:** Historical device-specific PAK structures for legacy platforms. Mirrors the legacy platforms in `workspace/_unmaintained/`.
**Disposition:** Reject (for Ideal OS purposes)
**Rationale:** Same as workspace legacy platforms — not relevant to TrimUI Brick.

---

## Resolved Questions

These were originally flagged as open questions and have been resolved through source analysis.

### Q1: How is the game list populated? — RESOLVED

**Answer: Filesystem scan with optional `map.txt` aliasing. No database.**

`getRoms()` scans `/Roms/` using `opendir()`/`readdir()`. Each system directory is checked for ROM files and a matching emulator PAK. Optional `map.txt` files (tab-separated `filename<TAB>Display Name`) provide display name overrides. All data is in-memory per session — reconstructed from filesystem on every launcher start. No caching or database.

**Key data structure:** `Entry { path, name, unique, type, alpha }` stored in `Array*` within each `Directory` on a navigation stack.

### Q2: How does the existing resume/recent stack work? — RESOLVED

**Answer: Dual-layer file-based with in-memory caching.**

- **Recent games:** `/Roms/.userdata/shared/.minui/recent.txt` — text file, one path per line (optional tab-separated alias). Max 24 entries. Loaded into memory on startup; saved after each game launch. Newest entry always at index 0.
- **Resume state detection:** Launcher checks for save slot file (`/.userdata/shared/.minui/<EMU>/<romname>.txt`) and preview BMP (`<romname>.<slot>.bmp`). If both exist, "X RESUME" button hint appears.
- **Auto-resume:** `auto_resume.txt` stores a game path for auto-launch on next boot (used after crash/forced restart).
- **Game Switcher:** Carousel overlay showing top 8-12 recent games with save previews. Transient state via `game_switcher.txt` marker file.
- **Last position:** `/tmp/last.txt` stores cursor position and navigation stack for restoring UI state after returning from a game.

### Q3: What UI rendering framework is used? — RESOLVED

**Answer: SDL2 with custom software rendering. No GPU acceleration in the launcher UI.**

- `GFX_*()` functions from `api.h` wrap SDL2 surface operations (software blit, not OpenGL).
- Image loading via `SDL_image` (`IMG_Load`), font rendering via `SDL_ttf`.
- Layer-based composition with dirty-rect optimization — only redraws when `dirty = 1`.
- Three worker threads for async loading: background images, game thumbnails, pill selector animation.
- V-sync at ~60 FPS. Menu transitions use 150-200ms slide animations.

**Note:** The emulator (minarch) uses OpenGL ES for rendering. Only the launcher UI is software-rendered.

### Q4: What save state format does minarch use? — RESOLVED

**Answer: Multiple selectable formats. Default is MinUI-style `.st0`–`.st8`.**

- **Default (STATE_FORMAT_SAV):** `Game.st0` through `Game.st8` in `/.userdata/<platform>/<system>-<core>/`
- **RetroArch compat:** `Game.state.0` (extra dot) or `Game.state0` (no dot), compressed or uncompressed variants
- **File contents:** Raw libretro `core.serialize()` output. Optional RASTATE 16-byte header when compressed.
- **Slots:** 0-7 are user slots (displayed as 1-8 in UI). Slot 8 is MiniUI compat. **Slot 9 is AUTO_RESUME_SLOT** — auto-saved on game exit, loaded on next launch via `/tmp/resume_slot.txt`.
- **SRAM (battery saves):** Separate from save states. Stored at `Saves/<System>/Game.sav` (or `.srm`). Written on game exit only — no intermediate checkpointing.

### Q5: How does the rewind buffer interact with suspend/resume? — RESOLVED

**Answer: Rewind buffer is in-memory only and does NOT survive suspend/resume.**

- **Buffer:** Circular ring buffer (configurable, default 64MB, max 256MB). Delta-encoded (XOR previous state) + LZ4 compression. Captures every N frames (default 16).
- **On state load/save:** `Rewind_on_state_change()` → `Rewind_reset()` — entire buffer cleared and re-seeded with current state.
- **On suspend:** Auto-save to slot 9, rewind buffer freed. On resume: new empty buffer created.
- **On core reset:** Buffer cleared.
- **During menu pause:** Buffer is NOT updated (core doesn't run), but buffer contents survive — rewind continues on menu close.

### Q8: Does the updater check signatures or integrity? — RESOLVED

**Answer: No. Zero integrity verification of any kind.**

The updater script and both platform boot scripts (tg5040, tg5050) unconditionally extract `MinUI.zip` with `unzip -o` and delete it. No SHA256, MD5, GPG, checksum, or signature checks anywhere in the update pipeline. Grep for all verification-related terms across all update scripts yields zero results.

### Q9: Are binaries stripped? — RESOLVED

**Answer: Partially. Some libraries explicitly stripped; core binaries are not.**

- **Explicitly stripped** (`-s` in LDFLAGS): libbatmondb, libgametimedb, show2, syncsettings
- **Not explicitly stripped**: nextui.elf, minarch.elf, keymon.elf, settings, batmon
- **Debug symbols**: Only available when building with `GPERFTOOLS=1` (adds `-g`). Default builds have no `-g`.
- **Optimization**: All platforms use `-O3 -Ofast -fomit-frame-pointer` — aggressive optimization but not stripping.
- **No global NDEBUG**: Assertions remain in non-profiling builds.

---

## Remaining Open Questions

These require device-level validation or are scoped to future sprints.

| # | Component | Question | Suggested Sprint |
|---|-----------|----------|-----------------|
| 10 | platform | What is the exact CPU frequency scaling range and governor behavior on TG5040? | 1.2 |

### Q6: Can the boot script be extended for Ideal OS OTA alongside NextUI updates? — RESOLVED

**Answer: Yes.** See `upstream/nextui/notes/conflict-analysis.md` for full details.

- `.tmp_update/updater` can be replaced with an Ideal OS OTA coordinator that checks for Ideal OS updates first, then falls through to standard NextUI platform dispatch
- `.pakz` mechanism allows Ideal OS components to be delivered as packages alongside NextUI updates
- Ideal OS updates use a separate namespace (`.ideal/updates/`) and are independent of `MinUI.zip`
- Progress UI (`show2.elf` via `/tmp/show2.fifo`) is reusable

### Q7: What is the exact boot handoff point where Ideal OS takes control? — RESOLVED

**Answer: Two handoff points.** See `upstream/nextui/notes/boot-flow-analysis.md` and `conflict-analysis.md` for full details.

- **Install/Update flow:** Handoff at `.tmp_update/updater` — replace with Ideal OS OTA coordinator
- **Normal boot flow:** Handoff at `MinUI.pak/launch.sh` — replace with Ideal OS-aware launch script that starts subsystems before the NextUI main loop
- **Lightweight alternative:** `auto.sh` in `.userdata/tg5040/` runs before `nextui.elf` without replacing `launch.sh`, but has limited integration (no game launch interception)
