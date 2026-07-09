# Continuity — Platform Abstraction Layer (PAL)

**Status:** Approved (0.2) — addendum 2026-07-07 pending approval
**Date:** 2026-03-13

## Purpose

The PAL is the contract between platform-agnostic core sync logic and platform-specific runtime environments. Every core module (`path_mapper.sh`, `sync_engine.sh`, `enrollment.sh`, `cold_start.sh`, etc.) operates exclusively through PAL-provided variables and functions. No core module ever hardcodes a device path, references a platform-specific binary location, or assumes a filesystem layout.

This means:
1. **Core modules are written and tested once.** They work on any platform that implements the PAL.
2. **Adding a platform = writing a PAL + entry points.** No changes to core sync logic.
3. **Automated tests use a test PAL.** Same core code, synthetic environment, no hardware needed.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                 Platform Entry Point                  │
│        (daemon, CLI, Android service, etc.)           │
│                                                       │
│  1. Source the platform PAL                           │
│  2. Call pal_init()                                   │
│  3. Call core functions (enrollment, cold start, etc.)│
└──────────────────────┬───────────────────────────────┘
                       │ sources
                       ▼
┌──────────────────────────────────────────────────────┐
│              Platform PAL Implementation              │
│     (pal_nextui.sh / pal_retrodeck.sh / pal_test.sh) │
│                                                       │
│  Sets: CONTINUITY_SAVES_ROOT, CONTINUITY_REPO_DIR,   │
│        CONTINUITY_DEVICE_NAME, CONTINUITY_PLATFORM,   │
│        CONTINUITY_GIT_BIN                             │
│                                                       │
│  Implements: pal_init(), pal_is_online(),             │
│              pal_log(), pal_get_platform_map()        │
└──────────────────────┬───────────────────────────────┘
                       │ used by
                       ▼
┌──────────────────────────────────────────────────────┐
│                Core Sync Modules                      │
│      (path_mapper, sync_engine, cold_start, etc.)     │
│                                                       │
│  Read: $CONTINUITY_SAVES_ROOT, $CONTINUITY_REPO_DIR  │
│  Call: pal_is_online(), pal_log(), etc.               │
│  Never: hardcode paths, assume platform, check OS     │
└──────────────────────────────────────────────────────┘
```

---

## PAL Interface

### Required Variables

Every PAL implementation must set these variables before `pal_init()` returns:

| Variable | Type | Description | Example (NextUI) |
|----------|------|-------------|------------------|
| `CONTINUITY_SAVES_ROOT` | path | Root directory containing system save subdirectories | `/mnt/SDCARD/Saves` |
| `CONTINUITY_REPO_DIR` | path | Path to the local git repo clone | `/mnt/SDCARD/.continuity/repo` |
| `CONTINUITY_DEVICE_NAME` | string | Human-readable device identifier (set during enrollment). Must contain only lowercase alphanumeric characters and hyphens (`[a-z0-9-]`), must not start or end with a hyphen, must not contain dots, spaces, or path separators, and must be at most 32 characters. Validated during enrollment. | `my-brick` |
| `CONTINUITY_PLATFORM` | string | Platform identifier matching a platform map filename | `nextui` |
| `CONTINUITY_GIT_BIN` | path | Path to the git binary (or just `"git"` if on PATH) | `/mnt/SDCARD/Tools/Continuity.pak/bin/git` |

### Required Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `pal_init` | `()` | 0 on success, 1 on error | Platform-specific initialization. Validate paths exist, set variables, perform any one-time setup. Called once at startup. |
| `pal_is_online` | `()` | 0 if online, 1 if offline | Check network reachability to GitHub. Implementation varies by platform. |
| `pal_log` | `(level, message)` | void | Log a message at the given level (`debug`, `info`, `warn`, `error`). Platform chooses destination (stderr, file, journald, logcat). |
| `pal_get_platform_map` | `()` | prints path to stdout | Return the absolute path to this platform's map JSON file (from `config/platform_maps/`). |

### Optional Variables

| Variable | Type | Description | Example (NextUI) |
|----------|------|-------------|------------------|
| `CONTINUITY_SD_ROOT` | path | Root of the SD card or external storage. Used by SD card enrollment triggers to locate `setup.json`. Not required on platforms without SD card enrollment (e.g. RetroDeck CLI enrollment). Not checked by `pal_validate`. | `/mnt/SDCARD` |

### Optional Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `pal_on_sync_complete` | `()` | void | Hook called after a successful sync cycle. Platform can use this for notifications, UI updates, etc. *Not yet called by core modules — planned for Sprint 1.1 daemon lifecycle.* |
| `pal_on_conflict` | `(canonical_repo_path)` | void | Hook called when a conflict `.local` file is created. Receives the canonical `.srm` repo path (e.g., `gba/minish_cap.srm`), not the `.local` file path. Platform can notify the user. |
| `pal_on_sync_result` | `(level, message)` | void | Hook called when a sync operation completes with a meaningful outcome. `level` is `green` (pushed), `yellow` (committed but offline), or `red` (action required). `message` is human-readable display text — platforms must NOT parse it. Called by `ss_notify` in `sync_status.sh`. See the notification behavior contract below. |

### Notification Behavior Contract

Platforms implementing `pal_on_sync_result` should follow these display rules:

| Level | Appearance | Duration | Dismissal |
|-------|-----------|----------|-----------|
| `green` | Small, subtle | 2-3 seconds, then fade | Auto-dismiss |
| `yellow` | Small, noticeable | 3-4 seconds, then fade | Auto-dismiss |
| `red` | Prominent | Persistent | User must resolve the condition or explicitly dismiss |

**Key rules:**
- `green` and `yellow` are transient — they appear briefly and disappear automatically.
- `red` is persistent — stays visible until the user addresses the underlying issue (e.g., resolves a conflict).
- Platforms branch on `level` only. The `message` string is for the user to read, not for platform logic to parse.
- If the platform needs structured data (e.g., conflict count), it calls `ch_count_conflicts` directly.
- Core re-fires `red` on every poll cycle where the condition persists. Platforms may debounce if needed.

---

## PAL Implementations

### NextUI PAL (`src/platforms/nextui/pal_nextui.sh`)

For TrimUI Brick running NextUI. BusyBox ash, FAT32 filesystem, no system git.

```sh
#!/bin/sh
# PAL implementation for NextUI (TrimUI Brick)

CONTINUITY_SAVES_ROOT="/mnt/SDCARD/Saves"
CONTINUITY_REPO_DIR="/mnt/SDCARD/.continuity/repo"
CONTINUITY_PLATFORM="nextui"
CONTINUITY_GIT_BIN="/mnt/SDCARD/Tools/Continuity.pak/bin/git"
CONTINUITY_SD_ROOT="/mnt/SDCARD"
# CONTINUITY_DEVICE_NAME read from enrollment config

pal_init() {
    # Read device name from enrollment config
    local config_file
    config_file="$CONTINUITY_REPO_DIR/.continuity/device_name"
    if [ -f "$config_file" ]; then
        CONTINUITY_DEVICE_NAME=$(cat "$config_file")
    else
        pal_log "error" "No device name found — enrollment incomplete?"
        return 1
    fi

    # Verify git binary exists
    if [ ! -x "$CONTINUITY_GIT_BIN" ]; then
        pal_log "error" "Git binary not found at $CONTINUITY_GIT_BIN"
        return 1
    fi
    return 0
}

pal_is_online() {
    ping -c 1 -W 3 github.com >/dev/null 2>&1 ||
    wget --spider -q -T 3 https://github.com 2>/dev/null
}

pal_log() {
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

pal_get_platform_map() {
    # Platform map ships with the PAK
    printf '%s\n' "/mnt/SDCARD/Tools/Continuity.pak/config/platform_maps/nextui.json"
}
```

### Onion OS PAL (`src/platforms/onion/pal_onion.sh`)

Nearly identical to NextUI — same BusyBox ash, same FAT32, same constraints. Different boot hook path and potentially different git binary location.

### RetroDeck PAL (`src/platforms/retrodeck/pal_retrodeck.sh`)

Full Linux. System git, `~/.config/` for config, systemd for logging, `ping` for connectivity.

```sh
CONTINUITY_SAVES_ROOT="$HOME/.var/app/net.retrodeck.retrodeck/data/saves"
CONTINUITY_REPO_DIR="$HOME/.config/continuity/repo"
CONTINUITY_PLATFORM="retrodeck"
CONTINUITY_GIT_BIN="git"

pal_is_online() {
    ping -c 1 -W 3 github.com >/dev/null 2>&1
}

pal_log() {
    logger -t continuity -p "user.$1" "$2"
}
```

### Test PAL (`tests/fixtures/pal_test.sh`)

For automated testing. All paths point to temp directories. Always "online." Deterministic device name.

```sh
#!/bin/sh
# PAL implementation for automated testing
# Caller must set TEST_TMPDIR before sourcing

CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/saves"
CONTINUITY_REPO_DIR="$TEST_TMPDIR/repo"
CONTINUITY_DEVICE_NAME="test-device"
CONTINUITY_PLATFORM="nextui"  # Use NextUI map by default for tests
CONTINUITY_GIT_BIN="git"
CONTINUITY_SD_ROOT="$TEST_TMPDIR/sdcard"

pal_init() {
    mkdir -p "$CONTINUITY_SAVES_ROOT" "$(dirname "$CONTINUITY_REPO_DIR")"
    return 0
}

pal_is_online() {
    # Always online in tests (override in specific tests to simulate offline)
    return 0
}

pal_log() {
    printf '[TEST %s] %s\n' "$1" "$2" >&2
}

pal_get_platform_map() {
    printf '%s\n' "$TEST_TMPDIR/platform_map.json"
}
```

**Key test PAL feature:** Tests can override individual PAL functions to simulate specific conditions:

```sh
# In a test that needs to simulate offline:
pal_is_online() { return 1; }
```

---

## PAL Loader (`src/core/pal.sh`)

The core provides a loader/validator that:
1. Verifies all required variables are set
2. Verifies all required functions are defined
3. Provides clear error messages if the PAL is incomplete

```sh
#!/bin/sh
# PAL interface loader and validator

pal_validate() {
    local missing=""

    # Check required variables
    [ -z "$CONTINUITY_SAVES_ROOT" ] && missing="$missing CONTINUITY_SAVES_ROOT"
    [ -z "$CONTINUITY_REPO_DIR" ] && missing="$missing CONTINUITY_REPO_DIR"
    [ -z "$CONTINUITY_DEVICE_NAME" ] && missing="$missing CONTINUITY_DEVICE_NAME"
    [ -z "$CONTINUITY_PLATFORM" ] && missing="$missing CONTINUITY_PLATFORM"
    [ -z "$CONTINUITY_GIT_BIN" ] && missing="$missing CONTINUITY_GIT_BIN"

    # Check required functions
    command -v pal_init >/dev/null 2>&1 || missing="$missing pal_init()"
    command -v pal_is_online >/dev/null 2>&1 || missing="$missing pal_is_online()"
    command -v pal_log >/dev/null 2>&1 || missing="$missing pal_log()"
    command -v pal_get_platform_map >/dev/null 2>&1 || missing="$missing pal_get_platform_map()"

    if [ -n "$missing" ]; then
        printf 'PAL validation failed. Missing:%s\n' "$missing" >&2
        return 1
    fi
    return 0
}
```

---

## How Core Modules Use the PAL

### Pattern: Every core module assumes the PAL is loaded

Core modules do NOT source the PAL themselves. The entry point (daemon, CLI, test harness) sources the PAL, calls `pal_init()`, then sources core modules. This keeps the loading order explicit and avoids circular dependencies.

```sh
# Entry point (e.g., NextUI daemon)
. /path/to/pal_nextui.sh
. /path/to/src/core/pal.sh
pal_init || exit 1
pal_validate || exit 1

. /path/to/src/core/path_mapper.sh
. /path/to/src/core/sync_engine.sh
. /path/to/src/core/enrollment.sh
. /path/to/src/core/change_detector.sh
. /path/to/src/core/cold_start.sh
. /path/to/src/core/boot_pull.sh
. /path/to/src/core/runtime_poll.sh
. /path/to/src/core/stale_boot.sh
. /path/to/src/core/conflict_handler.sh

# Now call core functions — they use PAL variables/functions transparently
pm_load_platform_map "$(pal_get_platform_map)"
# NOTE: This assumes enrollment is already complete. The daemon boot
# sequence must call enroll_is_enrolled() before reaching this point.
# If enrollment is not complete, pal_init() will have already failed
# (no device_name file), but callers should check explicitly.
se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"
```

### Path construction authority

`$CONTINUITY_SAVES_ROOT` (the PAL variable) is authoritative for path construction, NOT the `saves_root` field in platform map JSON files. The path mapper uses `$CONTINUITY_SAVES_ROOT` for the saves root prefix and the JSON `system_paths` entries for system directory names only. If `saves_root` appears in a platform map JSON, it is informational — runtime path construction always reads the PAL variable.

### Pattern: Core modules reference PAL variables, never literals

```sh
# CORRECT — core module uses PAL variable
find "$CONTINUITY_SAVES_ROOT" -name "*.srm"

# WRONG — core module hardcodes platform path
find "/mnt/SDCARD/Saves" -name "*.srm"
```

### Pattern: Network operations check pal_is_online()

```sh
# In sync_engine.sh
se_push() {
    if ! pal_is_online; then
        pal_log "info" "Offline — push deferred"
        return 2
    fi
    # ... git push logic
}
```

### Pattern: All logging goes through pal_log()

```sh
# CORRECT
pal_log "info" "Cold start sync complete — 3 saves synced"

# WRONG
echo "Cold start sync complete" >&2
```

---

## Device Name Lifecycle

The device name (`CONTINUITY_DEVICE_NAME`) is:

1. **Set during enrollment** — user chooses it (or a default is generated from platform + random suffix)
2. **Stored locally** — in a file the PAL knows how to read (e.g., `$CONTINUITY_REPO_DIR/.continuity/device_name`)
3. **Registered in the repo** — in `.continuity/devices/<name>.json` (committed and pushed)
4. **Used in commit messages** — `device: my-brick`
5. **Used in conflict file names** — `super_metroid.srm.my-brick.local`
6. **Immutable after enrollment** — changing it would orphan conflict files and device registration

The PAL's `pal_init()` is responsible for reading the stored device name and setting `CONTINUITY_DEVICE_NAME`. If the device name file doesn't exist, enrollment hasn't completed — `pal_init()` should return 1.

---

## Filesystem Assumptions

The PAL abstracts these platform differences:

| Concern | NextUI / Onion | RetroDeck | Android |
|---------|---------------|-----------|---------|
| Filesystem | FAT32/exFAT | ext4 | ext4 |
| mtime reliability | 2-second granularity, unreliable | Reliable | Reliable |
| File permissions | None (FAT32) | Unix perms | Android sandbox |
| Path separator | `/` | `/` | `/` |
| Max path length | 255 | 4096 | 4096 |
| Case sensitivity | Case-insensitive | Case-sensitive | Case-sensitive |
| Git binary | Static binary in PAK | System package | JGit (Java) |

Core modules avoid relying on any of these directly:
- Change detection uses `cmp -s` (byte comparison), not mtime
- No file permission operations (chmod, chown)
- No case-dependent path logic
- Git invoked via `$CONTINUITY_GIT_BIN`, not hardcoded `git`

---

## Adding a New Platform

To add support for a new platform:

1. **Create a platform map** in `config/platform_maps/<platform>.json`
2. **Implement the PAL** in `src/platforms/<platform>/pal_<platform>.sh`
3. **Write platform entry points** (daemon, enrollment trigger, etc.) in `src/platforms/<platform>/`
4. **Test with the test PAL first** — verify core logic works with the new platform map
5. **Then test with the real PAL** on hardware

No changes to `src/core/` should be needed. If they are, the PAL interface is incomplete and should be extended.

---

## Relationship to wifi_monitor.sh

The original architecture spec defined `wifi_monitor.sh` as a standalone core module. The PAL absorbs this: `pal_is_online()` replaces `wm_is_online()`. The rationale:

- Connectivity checking is inherently platform-dependent (ping vs wget vs Java ConnectivityManager)
- On some platforms, `ping` may be blocked or unavailable
- The PAL already abstracts all platform-specific behavior — connectivity fits naturally

There is no separate `wifi_monitor.sh` in the revised architecture. The `architecture.md` spec will be updated to reflect this when Sprint 0.2 is implemented.

---

## Addendum (2026-07-07) — PAL surface as hardware-validated on NextUI

The Phase 1 bring-up added contract surface beyond the original draft.
Platform PAL authors (Onion, RetroDeck, Android) must account for:

### Additional variables

| Variable | Meaning |
|----------|---------|
| `CONTINUITY_PAK_DIR` | Root of the installed platform package. Set by the entry point from its own location; the PAL provides a platform default. All bundled tooling paths derive from it. |
| `CONTINUITY_SD_ROOT` | User-visible storage root (`setup.json` staging, diagnostic report target). |

All PAL path variables are **env-defaulted** (`${VAR:-default}`) so test
sandboxes can redirect them; production leaves them unset.

### Bundled-git environment (any platform without a system git)

The PAL must export, pointing into the package's own copies, guarded on
existence and with pre-set env winning: `GIT_EXEC_PATH` (the exec dir
must contain `git` itself plus `git-remote-http` and `git-remote-https`
— git spawns helpers by re-invoking `git remote-<proto>`),
`GIT_SSL_CAINFO` (pristine Mozilla bundle), `GIT_TEMPLATE_DIR`, and the
package `bin/` on `PATH`. See `docs/platform/nextui-field-notes.md`.

### Function contract clarifications

- `pal_is_online` must honor `CONTINUITY_FORCE_ONLINE=1` (test/debug
  override) and be safe to poll (the daemon waits on it at boot; boot
  enrollment races platform WiFi bring-up).
- `pal_log` writes to stderr only; entry points own log-file redirection.
- Headless git safety belongs to callers (`GIT_TERMINAL_PROMPT=0`,
  low-speed abort) — implemented in `enroll_sd_card.sh`; replicate in
  any new enrollment trigger.

### Platform-integration surface deliberately OUTSIDE the PAL

Display (`show2.elf` on NextUI), boot-hook installation
(`$USERDATA_PATH/auto.sh`), and button input (`/dev/input/js0`,
platform-specific numbering) live in platform entry-point scripts
(`launch.sh`, `enroll_ui.sh`), not the PAL, and must degrade gracefully:
sync must work with all three absent.
