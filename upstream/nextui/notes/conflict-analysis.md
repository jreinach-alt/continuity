# NextUI / Ideal OS Integration Boundary and Conflict Analysis

## Integration Boundary

The line between NextUI platform layer and Ideal OS core services is defined at the file level. NextUI owns the platform: hardware init, display, input, emulation cores, and the base launcher UI. Ideal OS owns the intelligence layer: session management, cloud sync, notifications, task scheduling, and OTA orchestration.

### Boundary Table

| Layer | Owner | Files / Subsystems | Modification Allowed |
|-------|-------|--------------------|---------------------|
| Hardware init (GPIO, display, audio) | NextUI | `launch.sh` GPIO block, `trimui_inputd`, display drivers | No — use as-is |
| Input monitoring | NextUI | `keymon.elf`, `trimui_inputd` | No — consume events only |
| Battery monitoring | NextUI | `batmon.elf`, `libbatmondb.so` | No — read battery state via existing API |
| Audio monitoring | NextUI | `audiomon.elf` | No — use as-is |
| CPU frequency management | NextUI | `launch.sh` governor setup, per-game PAK settings | No — Ideal OS respects NextUI's CPU policy |
| WiFi / Bluetooth init | NextUI | `wifi_init.sh`, `bt_init.sh`, `nextval.elf` | No — toggle via existing NextUI settings mechanism |
| Emulator cores (libretro) | NextUI | `.system/tg5040/cores/*.so` | No — use as-is |
| Emulator frontend | NextUI | `minarch.elf` | Wrap — intercept launch/exit for session tracking |
| Launcher UI | NextUI | `nextui.elf` | Wrap — intercept game launch signals via `/tmp/next` |
| PAK runtime | NextUI | `Emus/*.pak/launch.sh`, `Tools/*.pak/launch.sh` | Extend — deliver Ideal OS components as user PAKs |
| Boot dispatcher | **Ideal OS** | `runtrimui.sh` (replaced) | Replace — Ideal OS boot coordinator |
| Launch orchestrator | **Ideal OS** | `MinUI.pak/launch.sh` (replaced) | Replace — start Ideal OS subsystems before NextUI loop |
| Session Manager | **Ideal OS** | `src/session/` | New — Ideal OS native |
| Task Scheduler | **Ideal OS** | `src/tasks/` | New — Ideal OS native |
| Cloud Sync | **Ideal OS** | `src/sync/` | New — Ideal OS native |
| Notifications | **Ideal OS** | `src/notifications/` | New — Ideal OS native |
| OTA Updater | **Ideal OS** | `src/updater/` | New — wraps NextUI install mechanism |
| Settings (Ideal OS) | **Ideal OS** | `.userdata/ideal/settings.json` | New — parallel to NextUI settings |
| Runtime data | **Ideal OS** | `.ideal/` on SD card | New — separate namespace from `.system/` |

---

## Conflict Zone: .system/ Folder

### What NextUI Does

`.system/` is the NextUI runtime root on the SD card. Structure:

```
.system/tg5040/
├── bin/          # nextui.elf, minarch.elf, keymon.elf, batmon.elf, audiomon.elf, etc.
├── lib/          # libmsettings.so, libbatmondb.so, libgametimedb.so, etc.
├── cores/        # Libretro emulator cores (*.so)
├── paks/
│   ├── MinUI.pak/  # Main launcher PAK (launch.sh + resources)
│   └── Emus/       # Built-in emulator PAKs
├── etc/          # bluetooth/bt_init.sh, wifi/wifi_init.sh, system.cfg
├── shaders/      # GLSL shader files
├── res/          # Fonts, logos
└── dbg/          # Debug tools (tg5040 only)
```

**Critical behavior:** During install/update, `bin/`, `lib/`, and `MinUI.pak/` are **deleted and replaced entirely** (see `boot.sh` lines 91-95). Anything placed in these directories will be destroyed on the next update.

### What Ideal OS Needs

- A persistent runtime directory that survives NextUI updates
- A place for Ideal OS binaries, libraries, and configuration
- Clear separation so NextUI updates don't break Ideal OS and vice versa

### Strategy: Separate Namespace

**Use `/mnt/SDCARD/.ideal/` as the Ideal OS runtime root.** This directory is completely outside NextUI's awareness and will never be touched by NextUI install/update logic.

```
.ideal/
├── bin/          # Ideal OS binaries and scripts
├── lib/          # Ideal OS libraries
├── etc/          # Ideal OS system configuration
├── runtime/      # Runtime state (event bus, session data)
└── version.json  # Ideal OS version manifest
```

### Affected Files

| File | Impact |
|------|--------|
| `boot.sh` (tg5040.sh) | No modification — `.ideal/` is outside its blast radius |
| `MinUI.pak/launch.sh` | Replace — Ideal OS version adds `.ideal/bin` to PATH, `.ideal/lib` to LD_LIBRARY_PATH |
| `install.sh` (update.sh) | No modification — only handles tg3040→tg5040 migration |

---

## Conflict Zone: PAK Store and Tools

### What NextUI Does

PAKs are the plugin system. Two locations:

- **System PAKs**: `.system/tg5040/paks/Emus/` — built-in, destroyed on update
- **User PAKs**: `Emus/tg5040/*.pak` and `Tools/tg5040/*.pak` — persistent across updates

**Discovery** (from `nextui.c`): The launcher searches for PAKs by tag name derived from ROM folder. For a ROM in `Roms/Game Boy (GB)/`, it looks for `GB.pak` in this order:
1. `Tools/tg5040/GB.pak`
2. `.system/tg5040/paks/Emus/GB.pak`
3. `Emus/tg5040/GB.pak`

**Launch**: Executes `launch.sh` inside the PAK directory with the ROM path as argument.

**Installation**: `.pakz` files at SD card root are extracted during boot. Optional `post_install.sh` runs after extraction.

### What Ideal OS Needs

- Ability to intercept game launches for session tracking
- Deliver Ideal OS components via the existing package mechanism
- Wrap emulator PAK launches without modifying PAK contents

### Strategy: Wrap

1. **Deliver Ideal OS components as `.pakz` packages** — use the existing boot-time extraction mechanism. Each `.pakz` extracts files to the SD card and runs `post_install.sh` for setup.

2. **Wrap game launches at the `/tmp/next` level** — rather than modifying individual PAK `launch.sh` scripts, intercept the game launch command in the modified `MinUI.pak/launch.sh` main loop. Before `eval`-ing the command from `/tmp/next`, log it to the event bus and update session state.

3. **Tool PAKs for Ideal OS features** — optional Ideal OS settings, sync status, etc. can be delivered as Tool PAKs in `Tools/tg5040/`.

### Affected Files

| File | Impact |
|------|--------|
| `nextui.elf` / `nextui.c` | No modification — PAK discovery logic stays as-is |
| Individual PAK `launch.sh` files | No modification — wrapping happens at the main loop level |
| `MinUI.pak/launch.sh` | Replace — add game launch interception in the main loop |
| `.pakz` delivery mechanism | Reuse as-is for Ideal OS package delivery |

---

## Conflict Zone: Settings Persistence

### What NextUI Does

All UI and system settings are stored in a single key-value text file:

**Location:** `.userdata/shared/minuisettings.txt`

**Format:** Simple `key=value` pairs, one per line. No nesting, no schema version, no JSON.

```
font=1
color1=0xFFFFFF
screentimeout=60
suspendTimeout=30
```

**Read/Write:** `config.c` reads the file at startup (`CFG_init()`), and writes the entire file on every setting change (`CFG_sync()`). Each setter calls `CFG_sync()` immediately.

**Settings scope:** UI appearance (fonts, colors, animations), power management (screen/suspend timeouts), emulation (save format), input (haptics), networking (WiFi, BT, NTP, timezone), notifications, and RetroAchievements credentials.

**System settings** (WiFi on/off, BT on/off, volume, brightness) are stored separately in a JSON file read by `nextval.elf`:

**Location:** `.userdata/tg5040/systemval.json` (platform-specific)

### What Ideal OS Needs

- Ideal OS has its own settings: session behavior, sync preferences, notification rules, guardian mode config
- Must not conflict with NextUI's settings file
- Should use JSON with schema versioning (per CLAUDE.md data format requirements)

### Strategy: Parallel Storage

**Create `.userdata/ideal/settings.json`** — a separate settings file in Ideal OS's own namespace. Ideal OS never reads or writes `minuisettings.txt` directly.

For NextUI settings that Ideal OS needs to be aware of (e.g., WiFi state, suspend timeout), read them via `nextval.elf` or by reading `minuisettings.txt` as a read-only source — never write to it.

```json
{
  "_schema_version": "1.0",
  "session": { ... },
  "sync": { ... },
  "notifications": { ... },
  "guardian": { ... }
}
```

### Affected Files

| File | Impact |
|------|--------|
| `minuisettings.txt` | No modification — read-only access from Ideal OS |
| `systemval.json` | No modification — read via `nextval.elf` |
| `config.c` / `config.h` | No modification — NextUI settings subsystem untouched |
| `.userdata/ideal/settings.json` | New — Ideal OS settings file |

---

## Conflict Zone: Updater / Install Flow

### What NextUI Does

Boot-time full-replacement model:

1. `.tmp_update/updater` detects platform
2. `.tmp_update/tg5040.sh` extracts `.pakz` packages and `MinUI.zip`
3. Old `bin/`, `lib/`, `MinUI.pak/` are deleted before extraction
4. `install.sh` runs post-install migration
5. System boots once to verify, then forces power-off

**No integrity checks** — no checksums, no signatures, no version comparison.
**No rollback** — a failed update leaves the system in an unknown state.
**No channels** — single release stream.

### What Ideal OS Needs

- Manifest-driven OTA with SHA-256 verification
- Package-level granularity (update session manager without touching emulator cores)
- Rollback capability
- Version tracking
- The ability to update Ideal OS independently of NextUI

### Strategy: Extend and Layer

1. **Extend the updater** — Replace `.tmp_update/updater` to check for an Ideal OS update manifest first. If an Ideal OS update is pending, the Ideal OS OTA coordinator runs (with integrity verification, manifest processing, rollback preparation). Then fall through to the standard NextUI install flow for NextUI updates.

2. **Separate update payloads** — Ideal OS updates are delivered as files in `.ideal/updates/`, not as `MinUI.zip`. This means NextUI updates and Ideal OS updates are independent.

3. **Reuse `.pakz` for components** — Individual Ideal OS components can be delivered as `.pakz` packages, leveraging the existing extraction mechanism.

4. **Add version tracking** — `.ideal/version.json` tracks installed Ideal OS version. The OTA coordinator compares against the update manifest.

5. **Reuse `show2.elf`** — Progress reporting during Ideal OS updates uses the same FIFO mechanism (`/tmp/show2.fifo`).

### Affected Files

| File | Impact |
|------|--------|
| `.tmp_update/updater` | Replace — Ideal OS OTA coordinator dispatches before NextUI install |
| `.tmp_update/tg5040.sh` | No modification — NextUI install flow unchanged |
| `install.sh` (update.sh) | No modification — migration logic unchanged |
| `show2.elf` | Reuse — same FIFO protocol for Ideal OS progress |
| `.ideal/updates/` | New — Ideal OS update staging directory |
| `.ideal/version.json` | New — installed version manifest |

---

## Conflict Zone: Launcher (nextui.elf)

### What NextUI Does

`nextui.elf` is the main UI application:
- Discovers and displays ROM folders and PAKs
- Renders game library with art, collections, recent games, favorites
- Provides settings menu
- Game switcher (quick-switch between recent games)
- Writes game launch commands to `/tmp/next` and exits
- Re-launched in a loop by `MinUI.pak/launch.sh`

**Lifecycle** (from `MinUI.pak/launch.sh`):
```sh
while [ -f /tmp/nextui_exec ]; do
    nextui.elf &> $LOGS_PATH/nextui.txt
    if [ -f /tmp/next ]; then
        CMD=$(cat /tmp/next)
        eval $CMD
        rm -f /tmp/next
    fi
    # check for poweroff/reboot
done
```

`nextui.elf` is a C binary (~2000+ lines). It handles:
- ROM scanning and metadata
- UI rendering (SDL-based)
- Input handling
- Settings management (via `config.c`)
- Game art loading
- Collection management

### What Ideal OS Needs

- Intercept game launches for session tracking
- Know when the launcher is active vs. when a game is running
- Eventually: integrate Ideal OS features into the launcher UI (long-term)

### Strategy: Wrap via Launch Script

**Do not modify `nextui.elf`** — it's a complex C binary and the primary UI. Instead, wrap at the shell level:

1. **Replace `MinUI.pak/launch.sh`** with an Ideal OS version that:
   - Starts Ideal OS subsystems before the main loop
   - Wraps the game launch `eval` to emit events to the event bus
   - Adds session state updates on game launch/exit
   - Handles Ideal OS shutdown coordination

2. **Game launch interception** — Before `eval $CMD`, parse the command to extract the PAK name and ROM path. Emit a `game_launched` event. After the game process exits, emit a `game_exited` event. This gives Session Manager and Cloud Sync the hooks they need.

3. **Launcher state tracking** — When `nextui.elf` is running (inside the while loop, before `/tmp/next` check), the launcher is in "browse" state. When a game command is being eval'd, it's in "game" state. This state is written to a runtime file for other subsystems to read.

### Affected Files

| File | Impact |
|------|--------|
| `nextui.elf` / `nextui.c` | No modification |
| `minarch.elf` | No modification — session tracking happens at launch script level |
| `MinUI.pak/launch.sh` | Replace — Ideal OS-aware main loop with event emission |
| `/tmp/next` | Read — parse game launch commands for session tracking |
| `/tmp/nextui_exec` | Read — launcher lifecycle sentinel |

---

## Resolved Open Questions

### Q6: Can the boot script be extended for Ideal OS OTA alongside NextUI updates?

**Answer: Yes.** The boot chain has clear extension points:

1. **`.tmp_update/updater`** can be replaced with an Ideal OS version that checks for Ideal OS updates first, then falls through to the standard NextUI platform dispatch (`tg5040.sh`). The platform dispatch is a single line (`/mnt/SDCARD/.tmp_update/$PLATFORM.sh`) that doesn't need modification.

2. **`.pakz` mechanism** allows Ideal OS components to be delivered as packages alongside NextUI updates. Each `.pakz` is extracted independently and can include a `post_install.sh` for setup.

3. **Ideal OS updates are independent** — they use `.ideal/updates/` and `.ideal/version.json`, completely separate from `MinUI.zip`. Both can coexist in the same boot cycle.

4. **Progress UI is reusable** — `show2.elf` accepts messages via `/tmp/show2.fifo`, so Ideal OS OTA can report progress through the same display mechanism.

**Caveat:** The forced power-off at the end of the install flow (sysrq trigger in `updater`) means the first boot after an Ideal OS update will always require a full cold start. This is acceptable.

### Q7: What is the exact boot handoff point where Ideal OS takes control?

**Answer: Two handoff points, depending on the flow.**

**Install/Update flow:**
- Handoff at `.tmp_update/updater` (step 2 in the first-boot sequence). Replace this script with an Ideal OS OTA coordinator. It runs Ideal OS update logic, then calls the original platform dispatch for NextUI updates.

**Normal boot flow:**
- Handoff at `MinUI.pak/launch.sh` (step 3 in the normal boot sequence). Replace this script with an Ideal OS-aware version. Everything before this point (platform firmware, `runtrimui.sh` dispatcher) is platform infrastructure that should not be modified.
- Secondary handoff: `auto.sh` (step 18) is a lightweight alternative for early Ideal OS bootstrap without replacing `launch.sh`, but it has limitations (runs once, no loop integration, no game launch interception).

**The recommended approach:** Replace both `updater` (for OTA) and `MinUI.pak/launch.sh` (for runtime). This gives Ideal OS full control over both the update flow and the runtime loop while keeping all platform infrastructure untouched.
