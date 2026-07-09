# NextUI Build System Analysis

## Overview

NextUI uses a layered makefile system with Docker-based cross-compilation for ARM targets and native compilation for desktop development. The build produces a set of ZIP archives containing the complete runtime filesystem for the target device.

---

## Makefile Structure

```
makefile                          ← Top-level orchestrator
├── makefile.toolchain            ← Docker-based cross-compilation wrapper
├── makefile.native               ← Native desktop build (macOS/Linux)
└── workspace/
    ├── makefile                  ← Workspace orchestrator (compiles all components)
    ├── all/
    │   ├── nextui/makefile       ← Main launcher
    │   ├── minarch/makefile      ← Emulator runtime
    │   ├── settings/makefile     ← Settings UI
    │   ├── show2/makefile        ← Splash screen tool
    │   ├── batmon/makefile       ← Battery monitor daemon
    │   ├── battery/makefile      ← Battery stats viewer
    │   ├── gametime/makefile     ← Playtime tracker
    │   ├── gametimectl/makefile  ← Playtime controller
    │   ├── libbatmondb/makefile  ← Battery DB library
    │   ├── libgametimedb/makefile← Playtime DB library
    │   ├── minput/makefile       ← Input test tool
    │   ├── nextval/makefile      ← Config CLI tool
    │   ├── clock/makefile        ← Clock tool
    │   ├── bootlogo/makefile     ← Boot logo tool
    │   ├── ledcontrol/makefile   ← LED control
    │   ├── audiomon/Makefile     ← Audio monitor
    │   ├── syncsettings/makefile ← Settings sync
    │   └── cores/makefile        ← Emulator core patches
    ├── tg5040/
    │   ├── makefile              ← TG5040 platform orchestrator
    │   ├── platform/makefile.env ← Compiler flags and library paths
    │   ├── platform/makefile.copy← Artifact copy rules
    │   ├── cores/makefile        ← Platform-specific core patches
    │   └── install/              ← boot.sh, update.sh
    ├── tg5050/
    │   └── (same structure as tg5040)
    └── desktop/
        └── (same structure, native variant)
```

---

## Cross-Compilation Setup

### Toolchain (ARM Targets)

| Setting | Value |
|---------|-------|
| Docker image | `ghcr.io/loveretro/{PLATFORM}-toolchain:latest` |
| Toolchain repo | `https://github.com/LoveRetro/{PLATFORM}-toolchain/` |
| Local toolchain path | `toolchains/{PLATFORM}-toolchain/` |
| Host mount | `workspace/` → `/root/workspace/` in container |
| Target CPU | ARM Cortex-A53 (TG5040) |
| Architecture flag | `-mcpu=cortex-a53` |

The makefile.toolchain target:
1. Checks if the toolchain Docker image exists locally
2. If not, clones the toolchain repo and initializes it
3. Runs the build inside the Docker container with the workspace mounted

### Native (Desktop)

| Setting | Linux | macOS |
|---------|-------|-------|
| Compiler | System `gcc` at `/usr/bin/` | Homebrew GCC (requires symlink setup) |
| `CROSS_COMPILE` | `/usr/bin/` | `/usr/local/bin/` |
| `PREFIX` | `/usr` | `/opt/homebrew` |
| `PREFIX_LOCAL` | `/var/tmp/nextui` | `/var/tmp/nextui` |

macOS requires running `workspace/desktop/macos_create_gcc_symlinks.sh` to create unversioned GCC symlinks.

---

## Compiler Flags (TG5040)

```makefile
CFLAGS = -mcpu=cortex-a53 -flto
OPT = -O3 -Ofast -fomit-frame-pointer
CFLAGS += -DUSE_SDL2 -DUSE_GLES -DGL_GLEXT_PROTOTYPES
CFLAGS += -I$(PREFIX)/include -I$(PREFIX_LOCAL)/include
LDFLAGS = -L$(PREFIX)/lib -L$(PREFIX_LOCAL)/lib
LDFLAGS += -lSDL2_image -lSDL2_ttf -lpthread -ldl -lm -lz
```

Key characteristics:
- **LTO enabled** (`-flto`) — Link-time optimization across translation units
- **Aggressive optimization** (`-O3 -Ofast`) — Maximum performance for ARM target
- **OpenGL ES** (`-DUSE_GLES`) — GPU-accelerated rendering
- **SDL2** — Primary graphics, input, and audio framework

---

## Build Dependencies

### External Libraries

| Library | Purpose | Linked By |
|---------|---------|-----------|
| SDL2 | Graphics, input, audio | All components |
| SDL2_image | Image loading (PNG) | nextui, minarch, settings |
| SDL2_ttf | Font rendering | nextui, settings, show2 |
| OpenGL ES (GLES) | GPU rendering | minarch, nextui |
| SQLite3 | Data persistence | batmon, gametime |
| libsamplerate | Audio resampling | minarch |
| libzip | ZIP archive handling | minarch (CHD) |
| libbz2, liblzma, libzstd | Compression | minarch (CHD) |
| pthread | Threading | minarch, batmon |

### Internal Libraries

| Library | Purpose | Used By |
|---------|---------|---------|
| libmsettings | Platform settings (volume, brightness, etc.) | All components |
| libbatmondb | Battery monitoring database | batmon, battery |
| libgametimedb | Game playtime database | gametime, gametimectl |

### RetroAchievements

| Library | Purpose |
|---------|---------|
| rcheevos | RetroAchievements client library (vendored in `minarch/rcheevos/`) |

---

## Component Build Pattern

Each component follows the same pattern:

```makefile
# 1. Include platform environment
include ../../$(PLATFORM)/platform/makefile.env

# 2. Define target and sources
TARGET = component_name
SOURCE = $(TARGET).c ../common/utils.c ../common/api.c ../common/config.c \
         ../../$(PLATFORM)/platform/platform.c

# 3. Set include paths
INCDIR = -I. -I../common/ -I../../$(PLATFORM)/platform/

# 4. Add library dependencies
LDFLAGS += -lmsettings

# 5. Define output
PRODUCT = build/$(PLATFORM)/$(TARGET).elf

# 6. Build rule
$(PRODUCT): $(dependencies)
	mkdir -p build/$(PLATFORM)
	$(CROSS_COMPILE)gcc $(SOURCE) -o $(PRODUCT) $(CFLAGS) $(LDFLAGS)
```

The platform environment (`makefile.env`) provides `CROSS_COMPILE`, `CFLAGS`, `LDFLAGS`, `PREFIX`, and `PREFIX_LOCAL`.

---

## Build Order

The workspace makefile defines a specific compilation order:

### Non-Desktop Platforms (tg5040, tg5050)

1. **Platform early stage** — `{PLATFORM}/make early` (keymon, btmanager, rfkill on tg5040)
2. **nextui** — Main launcher
3. **minarch** — Emulator runtime
4. **battery** — Battery viewer
5. **clock** — Clock tool
6. **libbatmondb** — Battery DB library
7. **batmon** — Battery daemon
8. **libgametimedb** — Playtime DB library
9. **gametimectl** — Playtime controller
10. **gametime** — Playtime viewer
11. **minput** — Input tool
12. **syncsettings** — Settings sync
13. **nextval** — Config CLI
14. **settings** — Settings UI
15. **ledcontrol** — LED tool (tg5040/tg5050 only)
16. **bootlogo** — Boot logo tool (tg5040/tg5050 only)
17. **audiomon** — Audio monitor
18. **Emulator cores** (optional, `COMPILE_CORES` flag)
19. **Platform final stage** — `{PLATFORM}/make`

### Desktop

Simplified — skips batmon, gametimectl, gametime, syncsettings, ledcontrol, bootlogo, show2.

---

## Build Artifacts

### Output Directory Structure

```
build/
├── BASE/                          # User-facing content
│   ├── Roms/                      # ROM directory templates
│   ├── Saves/                     # Save directory templates
│   ├── Bios/                      # BIOS directory templates
│   ├── Shaders/                   # GLSL shader packs
│   ├── Overlays/                  # Game overlays/bezels
│   └── Cheats/                    # Cheat databases
├── EXTRAS/                        # Optional content
│   ├── Emus/{PLATFORM}/           # Extra emulator PAKs
│   └── Tools/{PLATFORM}/          # Utility tool PAKs
│       ├── Battery.pak/
│       ├── Clock.pak/
│       ├── Files.pak/
│       ├── Input.pak/
│       ├── Settings.pak/
│       ├── LedControl.pak/
│       └── Bootlogo.pak/
├── SYSTEM/{PLATFORM}/             # System runtime
│   ├── bin/                       # Executables
│   │   ├── nextui.elf
│   │   ├── minarch.elf
│   │   ├── keymon.elf
│   │   ├── batmon.elf
│   │   ├── gametimectl.elf
│   │   ├── rfkill.elf
│   │   ├── syncsettings.elf
│   │   └── install.sh
│   ├── lib/                       # Shared libraries
│   │   ├── libmsettings.so
│   │   ├── libbatmondb.so
│   │   ├── libgametimedb.so
│   │   ├── libsamplerate.*
│   │   ├── libzip.*
│   │   ├── libbz2.*
│   │   ├── liblzma.*
│   │   └── libzstd.*
│   ├── cores/                     # RetroArch cores (.so)
│   ├── paks/MinUI.pak/            # Main UI PAK
│   ├── etc/                       # Config (BT, WiFi init scripts)
│   ├── shaders/                   # GLSL shaders
│   └── res/                       # Resources
└── BOOT/                          # Boot-time files
    └── common/
        ├── {platform}.sh          # Platform boot script
        ├── {platform}/            # Platform boot assets
        │   ├── logo.png
        │   ├── show2.elf
        │   └── unzip
        └── updater                # Update coordinator
```

### Release Packages

The top-level makefile's `package` target creates release ZIP archives:

| Package | Contents | Purpose |
|---------|----------|---------|
| `NextUI-YYYYMMDD-N-base.zip` | MinUI.zip + Bios + Roms + Shaders + Overlays + vendored .pakz | Complete system for fresh install or update |
| `NextUI-YYYYMMDD-N-extras.zip` | Extra emulator PAKs | Optional additional emulators |
| `NextUI-YYYYMMDD-N-all.zip` | Base + Extras merged | All-in-one package |

**Inner archive:** `MinUI.zip` contains `.system/`, `.tmp_update/`, and `Tools/` — the actual system update payload.

**Vendored packages:** The build downloads two `.pakz` files from GitHub:
- `Pak.Store.pakz` — Community PAK store frontend
- `nextui.updater.pakz` — In-app system updater

### Release Naming Convention

```
NextUI-{YYYYMMDD}{-BRANCH}-{N}
```

- Date: Build date
- Branch: Omitted for `main`, otherwise branch name (e.g., `-develop`)
- N: Sequential number if multiple releases on same day (starts at 0)

---

## Platform-Specific Copy Rules

The `makefile.copy` in each platform directory defines what build artifacts get copied to their final locations:

### TG5040 Copy Rules

| Source | Destination | Purpose |
|--------|-------------|---------|
| `install/boot.sh` | `build/BOOT/common/tg5040.sh` | Boot-time update script |
| `install/update.sh` | `build/SYSTEM/tg5040/bin/install.sh` | Post-update migration |
| Boot PNGs | `build/BOOT/common/tg5040/` | Splash screen assets |
| `show2.elf` | `build/BOOT/common/tg5040/` | Splash renderer |
| `unzip` binary | `build/BOOT/common/tg5040/` | Archive extraction |
| `btmanager/*.pakz` | `build/BASE/` | Bluetooth upgrade package |
| `rfkill/rfkill.elf` | `build/SYSTEM/tg5040/bin/` | RF control |
| NextCommander output | `build/EXTRAS/Tools/tg5040/Files.pak/` | File manager tool |

---

## Path Constants (Runtime)

Defined in `workspace/all/common/defines.h`:

```c
#define SDCARD_PATH    "/mnt/SDCARD"
#define SYSTEM_PATH    "/mnt/SDCARD/.system/tg5040"
#define USERDATA_PATH  "/mnt/SDCARD/.userdata/tg5040"
#define BIN_PATH       "/mnt/SDCARD/.system/tg5040/bin"
#define PAKS_PATH      "/mnt/SDCARD/.system/tg5040/paks"
```

---

## Summary for Ideal OS

| Aspect | Assessment |
|--------|------------|
| **Build complexity** | Moderate — layered makefiles are standard, Docker isolation is clean |
| **Reproducibility** | Good — Docker-based toolchain ensures consistent cross-compilation |
| **Desktop builds** | Supported — enables development without target hardware |
| **Extensibility** | Good — component pattern is uniform and easy to add to |
| **Ideal OS impact** | Phase 1 will fork the build system to add Ideal OS packages, modify skeleton, and adjust release packaging |
