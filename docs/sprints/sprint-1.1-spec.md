# Sprint 1.1 — Daemon Bootstrap + Enrollment

**Status:** Complete — merged to main (PR #3, 2026-07-07)
**Date:** 2026-03-16 (QA'd and corrected 2026-07-06)
**Dependencies:** Sprint 0.3 (enrollment), Sprint 0.2 (PAL, path mapper)

> **QA corrections (2026-07-06)** — the implementation deviates from this
> draft where the draft was wrong about NextUI; see
> `docs/sprints/sprint-1.1-1.3-summary.md` for the full QA report:
>
> 1. **Part 1 (per-PAK `auto.sh`) is based on a false premise.** NextUI has
>    no per-PAK `auto.sh` convention — the only boot hook is the single
>    user script at `$USERDATA_PATH/auto.sh`
>    (`upstream/.../MinUI.pak/launch.sh:149-152`, confirmed in
>    `docs/design/nextui-tool-pak-research.md` §7). The implementation
>    instead has the Tool PAK's `launch.sh` idempotently install the
>    daemon start line into that global hook on first run. There is no
>    `src/platforms/nextui/auto.sh` file.
> 2. **PAK path includes the platform dir:**
>    `/mnt/SDCARD/Tools/tg5040/Continuity.pak/`, not
>    `/mnt/SDCARD/Tools/Continuity.pak/`.
> 3. **`build_git.sh` uses plain `gcc-aarch64-linux-gnu`** with static
>    zlib/openssl/curl built from source, not the NextUI Docker toolchain.
>    Output lands at `build/aarch64/prefix/bin/git`.
> 4. **Unit tests live at `tests/unit/nextui/`** (repo convention), not
>    `tests/unit/platforms/nextui/`.

---

## Goal

Get the Continuity daemon starting on a TrimUI Brick at boot time, and running enrollment when a `setup.json` is present.

This is the foundation for everything in Phase 1. Without it, no other daemon functionality is testable on-device. The user drops a `setup.json` on the SD card, powers on the Brick, and the daemon automatically enrolls the device — cloning the repo, registering the device, and pushing the registration. On subsequent boots, the daemon verifies enrollment is intact and exits. (Boot dispatch, poll loop, and shutdown come in later sub-sprints.)

After this sprint, the daemon is a skeleton: it starts, checks enrollment, runs enrollment if needed, and exits. But it proves the critical path: `auto.sh` → daemon startup → module loading → PAL init → enrollment → clean exit.

**Why enrollment first:** Every subsequent sprint (boot dispatch, poll loop, shutdown) requires an enrolled device with a cloned repo. If we can't get enrollment working on-device, nothing else matters. This sprint validates the enrollment flow end-to-end on real hardware.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, required variables and functions
- `src/core/pal.sh` — `pal_validate()` (Sprint 0.2)
- `src/core/enrollment.sh` — `enroll_is_enrolled()`, `enroll_run()` (Sprint 0.3)
- `src/core/sync_engine.sh` — `se_init()`, `se_clone()` (Sprint 0.3)
- `src/core/path_mapper.sh` — `pm_load_platform_map()` (Sprint 0.2)
- `src/platforms/nextui/pal_nextui.sh` — NextUI PAL (Sprint 0.2)
- `src/platforms/nextui/enroll_sd_card.sh` — `esd_detect_setup_file()`, `esd_import()` (Sprint 0.3)
- `upstream/nextui/notes/build-system-analysis.md` — NextUI build system, cross-compilation toolchain

---

## Design

### Sprint 1.1 Overview — Daemon Lifecycle

Sprint 1.1 is broken into four sub-sprints (a through d), each building incrementally on the previous. Together they produce the full NextUI daemon. This section shows the complete lifecycle for context — this sub-sprint implements steps 1-5 only.

```
┌──────────────────────────────────────────────────────────────────┐
│                        auto.sh (boot)                            │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │             continuity_daemon.sh (background)              │  │
│  │                                                            │  │
│  │  1. PID guard ─── if already running → exit       ← 1.1  │  │
│  │  2. Source PAL + core modules                     ← 1.1  │  │
│  │  3. pal_init() + pal_validate()                   ← 1.1  │  │
│  │  4. se_init() + pm_load_platform_map()            ← 1.1  │  │
│  │  5. Enrollment check ─── if not enrolled → exit   ← 1.1  │  │
│  │  6. Boot dispatch:                                ← 1.2  │  │
│  │     ├── cold start? → cs_run()                             │  │
│  │     ├── stale boot? → sb_run()                             │  │
│  │     └── normal boot → bp_run()                             │  │
│  │  7. Set SIGTERM trap                              ← 1.3  │  │
│  │  8. Poll loop (30s):                              ← 1.3  │  │
│  │     ├── WiFi recovery (push queued commits)       ← 1.4  │  │
│  │     ├── rp_run()                                  ← 1.3  │  │
│  │     └── Log rotation check                        ← 1.4  │  │
│  │  9. On SIGTERM:                                   ← 1.3  │  │
│  │     ├── Final push attempt                                 │  │
│  │     ├── sb_mark_clean_shutdown()                            │  │
│  │     ├── Remove PID file                                    │  │
│  │     └── exit 0                                             │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Notifications: pal_on_sync_result (show2.elf)       ← 1.4    │
└──────────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

**PID file in `/tmp/` (tmpfs), not on the SD card.** FAT32 has no file locking, 2-second mtime granularity, and survives reboots. A PID file on FAT32 would be stale after every reboot, requiring extra cleanup logic. `/tmp/` is tmpfs on the Brick — it vanishes on reboot, so stale PIDs clean themselves up.

**Boot dispatch is NOT a core module.** The decision tree is platform-specific orchestration. Different platforms may have different boot flows (Android skips SD card enrollment, RetroDeck integrates with systemd). Each platform daemon owns its boot dispatch.

**Log file via stderr redirect.** `pal_log` writes to stderr. The daemon redirects stderr to a log file at startup. All modules automatically log to the file with no code changes.

**PAK directory structure.** The daemon locates everything relative to `CONTINUITY_PAK_DIR`:

```
/mnt/SDCARD/Tools/Continuity.pak/
├── auto.sh                          ← Boot hook
├── launch.sh                        ← Tool UI entry (Sprint 1.5 — stub)
├── bin/
│   └── git                          ← Static git binary (arm, musl-linked)
├── config/
│   └── platform_maps/
│       └── nextui.json              ← Platform map
└── scripts/
    ├── continuity_daemon.sh         ← Main daemon
    ├── pal_nextui.sh                ← NextUI PAL
    ├── enroll_sd_card.sh            ← SD card enrollment
    └── core/
        ├── pal.sh
        ├── path_mapper.sh
        ├── sync_engine.sh
        ├── enrollment.sh
        ├── change_detector.sh
        ├── cold_start.sh
        ├── boot_pull.sh
        ├── stale_boot.sh
        ├── runtime_poll.sh
        ├── conflict_handler.sh
        └── sync_status.sh
```

For testing, `CONTINUITY_PAK_DIR` is overridden to point at the repo's `src/` tree so we can source the actual source files without building a PAK.

---

## Scope

### Part 1: Boot Hook — `auto.sh`

**File:** `src/platforms/nextui/auto.sh`

NextUI runs `auto.sh` from each Tool PAK directory on boot. This is the entry point.

```sh
#!/bin/sh
# Continuity auto.sh — boot hook for NextUI
# Launched by NextUI on device boot. Starts the daemon in the background.

SCRIPT_DIR="$(dirname "$0")"
"$SCRIPT_DIR/scripts/continuity_daemon.sh" &
```

That's it. The hook's only job is to start the daemon in the background and return immediately so it doesn't block the NextUI boot sequence.

**Important:** `auto.sh` must not block. NextUI calls all `auto.sh` hooks sequentially during boot. A blocking hook delays the entire UI from appearing. The `&` is mandatory.

---

### Part 2: PID Management

**PID file location:** `/tmp/continuity.pid`

#### `cd_write_pid` — Write PID file

**Signature:** `cd_write_pid()`

No parameters. Writes `$$` to `/tmp/continuity.pid`.

**Returns:** 0 on success, 1 on write failure.

#### `cd_is_running` — Check if another instance is running

**Signature:** `cd_is_running()`

No parameters. Reads `/tmp/continuity.pid`, checks if the PID is alive via `kill -0`.

**Returns:** 0 if another instance is running, 1 if not (or PID file absent/stale).

**Behavior:**
1. If PID file doesn't exist → return 1.
2. Read PID from file.
3. If PID is not numeric → remove file, return 1.
4. `kill -0 "$pid"` → if process alive, return 0.
5. Otherwise (stale PID) → remove file, return 1.

#### `cd_remove_pid` — Remove PID file

**Signature:** `cd_remove_pid()`

No parameters. Removes `/tmp/continuity.pid`. Idempotent.

**Returns:** 0 always.

---

### Part 3: Module Loading

#### `cd_load_modules` — Source PAL and core modules

**Signature:** `cd_load_modules()`

No parameters. Uses `CONTINUITY_PAK_DIR` to locate scripts.

**Behavior:**
1. Source `$CONTINUITY_PAK_DIR/scripts/pal_nextui.sh`
2. Source `$CONTINUITY_PAK_DIR/scripts/core/pal.sh`
3. Source core modules in order:
   - `path_mapper.sh`
   - `sync_engine.sh`
   - `enrollment.sh`
   - `change_detector.sh`
   - `cold_start.sh`
   - `boot_pull.sh`
   - `stale_boot.sh`
   - `runtime_poll.sh`
   - `conflict_handler.sh`
   - `sync_status.sh`
4. Source platform modules:
   - `$CONTINUITY_PAK_DIR/scripts/enroll_sd_card.sh`

**Returns:** 0 on success. Exits the daemon with code 1 if any source fails.

**Error handling:** Each `. "$file"` is guarded:
```sh
if ! . "$file"; then
    printf '[%s] error: failed to source %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$file" >&2
    cd_remove_pid
    exit 1
fi
```

Note: `pal_log` is not yet available until after the PAL is sourced, so early errors use `printf` directly to stderr.

---

### Part 4: Log File Setup

**Log file location:** `/mnt/SDCARD/.continuity/continuity.log`

This is outside the repo directory (`/mnt/SDCARD/.continuity/repo/`). The `.continuity/` top-level directory is Continuity's home on the SD card.

The daemon redirects stderr to the log file at startup:

```sh
CONTINUITY_LOG_FILE="/mnt/SDCARD/.continuity/continuity.log"
mkdir -p "$(dirname "$CONTINUITY_LOG_FILE")"
exec 2>>"$CONTINUITY_LOG_FILE"
```

Since `pal_log` writes to stderr, all log messages from all modules automatically go to this file. No module changes needed.

**Why not use syslog:** The Brick doesn't have syslogd running. A simple log file is more predictable and has no dependencies.

**For testing:** `CONTINUITY_LOG_FILE` is overridable. Tests set it to a temp file.

---

### Part 5: Enrollment Integration

#### `cd_check_enrollment` — Verify or perform enrollment

**Signature:** `cd_check_enrollment()`

No parameters. Uses `CONTINUITY_REPO_DIR` from the PAL.

**Behavior:**
1. Call `enroll_is_enrolled`. If returns 0 → log "Enrolled", return 0.
2. If not enrolled, check for setup.json: `esd_detect_setup_file`.
3. If no setup.json → log "Not enrolled, no setup.json found", return 1.
4. If setup.json found → call `esd_import`.
5. If `esd_import` succeeds → re-init PAL (`pal_init`) since device name is now available, re-init sync engine (`se_init`), log "Enrollment complete", return 0.
6. If `esd_import` fails → log "Enrollment failed", return 1.

**Returns:** 0 if enrolled (either already or just now), 1 if not enrolled.

**Why re-init after enrollment:** `pal_init` reads `device_name` from the repo's `.continuity/device_name` file, which didn't exist before enrollment. `se_init` needs the device name for commit messages. After enrollment creates these, we re-initialize.

---

### Part 6: Main Entry Point — `cd_main` (skeleton)

**Signature:** `cd_main()`

No parameters. Called at the bottom of `continuity_daemon.sh`.

**Behavior (this sub-sprint):**
1. Set `CONTINUITY_PAK_DIR` from script location: `CONTINUITY_PAK_DIR=$(cd "$(dirname "$0")/.." && pwd)`.
2. Set `CONTINUITY_LOG_FILE` and redirect stderr.
3. Log: `"Daemon starting"`.
4. PID guard: `cd_is_running` → if yes, log `"Another instance running, exiting"` and exit 0.
5. Write PID: `cd_write_pid`.
6. Load modules: `cd_load_modules`.
7. Init PAL: `pal_init` → if fails, `cd_remove_pid`, exit 1.
8. Validate PAL: `pal_validate` → if fails, `cd_remove_pid`, exit 1.
9. Init sync engine: `se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"`.
10. Load platform map: `pm_load_platform_map "$(pal_get_platform_map)"`.
11. Enrollment check: `cd_check_enrollment` → if fails, `cd_remove_pid`, exit 1.
12. Log: `"Bootstrap complete, enrolled as $CONTINUITY_DEVICE_NAME"`.
13. **Exit 0.** (Boot dispatch added in 1.2, poll loop in 1.3.)
14. Cleanup: `cd_remove_pid` before exit.

**Note on step 7-8 ordering:** `pal_init` must run before enrollment check because enrollment code needs `CONTINUITY_SD_ROOT` and `CONTINUITY_REPO_DIR` (set by sourcing the PAL). However, `pal_init` will fail if the device is not yet enrolled (no `device_name` file). The solution:

- If `pal_init` fails AND `CONTINUITY_REPO_DIR` is set (PAL was sourced, just not fully initialized) → skip to enrollment check.
- If `pal_init` fails AND `CONTINUITY_REPO_DIR` is not set → real failure, exit.

Updated step 7:
```
7. Try pal_init:
   - If succeeds → proceed to pal_validate.
   - If fails AND CONTINUITY_REPO_DIR is set → skip validation, go to enrollment check.
   - If fails AND CONTINUITY_REPO_DIR is not set → cd_remove_pid, exit 1.
```

After successful enrollment, `pal_init` is re-called (in `cd_check_enrollment`) and should now succeed since `device_name` exists. Then `pal_validate` is called.

---

### Part 7: Static Git Binary — `scripts/build_git.sh`

**File:** `scripts/build_git.sh`

The TrimUI Brick has no system git. We cross-compile a static git binary using the existing NextUI Docker toolchain (`ghcr.io/loveretro/tg5040-toolchain`).

**Why cross-compile instead of downloading a binary:** Reproducible, guaranteed architecture match (ARM Cortex-A53), no third-party binary supply chain, and git is GPL-2.0 — same license as NextUI.

#### `scripts/build_git.sh` — Cross-compile static git for ARM

**Usage:** `./scripts/build_git.sh`

**Prerequisites:** Docker installed and running.

**Behavior:**
1. Pull or verify the NextUI toolchain image: `ghcr.io/loveretro/tg5040-toolchain:latest`.
2. Inside the container, download the git source tarball (pinned version, e.g., git 2.44.0).
3. Configure with minimal dependencies:
   - `NO_OPENSSL=1` — use BusyBox-compatible HTTPS (via `NO_CURL=1` with git's internal HTTP)
   - Actually: `CURL_LDFLAGS=-lcurl -lssl -lcrypto` if the toolchain provides libcurl+openssl. If not, use `NO_CURL=1` and rely on `git://` or configure with `USE_LIBPCRE2=` disabled, etc.
   - The key requirement: `git clone https://...`, `git pull`, `git push`, `git add`, `git commit`, `git diff`, `git log` must work over HTTPS to GitHub.
   - Static linking: `LDFLAGS=-static` so the binary has zero runtime dependencies on the device.
4. `make strip` — strip debug symbols (minimizes binary size).
5. Copy the resulting `git` binary to `build/bin/git`.
6. Print the binary size and verify it runs: `file build/bin/git` should show ARM ELF.

**Output:** `build/bin/git` — a single static ARM binary, typically 5-15 MB.

**Version pinning:** The git version is pinned in the script (not `latest`). This ensures reproducible builds. Update the version deliberately, not accidentally.

**What git features we need:** Only the plumbing required by `sync_engine.sh`:
- `git clone`, `git pull`, `git push` (HTTPS transport to GitHub)
- `git add`, `git commit`, `git log`, `git diff`, `git status`
- `git config`, `git branch`, `git rev-parse`
- Credential helper support (`credential.helper`)

**What we don't need:** GUI, SVN bridge, email tools, Perl scripts, documentation. The `make` invocation should use `NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1 NO_SVN_TESTS=1` to minimize the build.

**Toolchain investigation required:** Before implementation, verify what libraries the `tg5040-toolchain` Docker image provides. Specifically:
- Does it have `libcurl` + `libssl`/`libcrypto`? (Needed for HTTPS git operations.)
- If not, the build script must also compile these from source (curl + mbedtls or openssl) as static libraries.
- This is a known unknown — the build script must handle both cases.

---

### Part 8: PAK Assembly — `scripts/build_pak.sh`

**File:** `scripts/build_pak.sh`

Assembles the Continuity.pak directory from repo source files and the cross-compiled git binary.

**Usage:** `./scripts/build_pak.sh`

**Prerequisites:** `build/bin/git` exists (run `build_git.sh` first).

**Behavior:**
1. Create `build/Continuity.pak/` directory structure.
2. Copy `src/platforms/nextui/auto.sh` → `build/Continuity.pak/auto.sh`.
3. Create stub `launch.sh` → `build/Continuity.pak/launch.sh`:
   ```sh
   #!/bin/sh
   echo "Continuity — sync daemon is running in the background."
   ```
4. Copy `build/bin/git` → `build/Continuity.pak/bin/git`.
5. Copy `config/platform_maps/nextui.json` → `build/Continuity.pak/config/platform_maps/nextui.json`.
6. Copy `src/platforms/nextui/continuity_daemon.sh` → `build/Continuity.pak/scripts/continuity_daemon.sh`.
7. Copy `src/platforms/nextui/pal_nextui.sh` → `build/Continuity.pak/scripts/pal_nextui.sh`.
8. Copy `src/platforms/nextui/enroll_sd_card.sh` → `build/Continuity.pak/scripts/enroll_sd_card.sh`.
9. Copy all `src/core/*.sh` → `build/Continuity.pak/scripts/core/`.
10. `chmod +x` all `.sh` files and `bin/git`.
11. Print summary: file count, total size.

**Output:** `build/Continuity.pak/` — ready to copy to `/mnt/SDCARD/Tools/` on the Brick's SD card.

**Deploy step (manual):** Mount the Brick's SD card (or use adb/SSH), copy:
```sh
cp -r build/Continuity.pak /path/to/sdcard/Tools/
```

Power on the Brick. NextUI discovers the PAK and runs `auto.sh` on boot.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Boot dispatch (cold start / stale boot / boot pull) | 1.2 |
| Runtime poll loop | 1.3 |
| Graceful shutdown (SIGTERM handler) | 1.3 |
| WiFi recovery | 1.4 |
| Log rotation | 1.4 |
| `pal_on_sync_result` / show2.elf notifications | 1.4 |
| Tool PAK UI (status, manual sync, conflict resolution) | 1.5 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/platforms/nextui/continuity_daemon.sh` | Daemon skeleton: PID guard, module loading, PAL init, enrollment check, clean exit |
| `src/platforms/nextui/auto.sh` | Boot hook: starts daemon in background |
| `tests/unit/platforms/nextui/test_daemon_bootstrap.sh` | Unit tests for PID management, module loading, enrollment check |
| `tests/integration/test_daemon_enrollment.sh` | Integration test: full enrollment via daemon startup |
| `scripts/build_git.sh` | Cross-compile static git binary for ARM (TrimUI Brick) using Docker toolchain |
| `scripts/build_pak.sh` | Assemble Continuity.pak directory from source + git binary |
| `docs/sprints/sprint-1.1-spec.md` | This spec |

### Files Modified

| File | Change |
|------|--------|
| `src/platforms/nextui/pal_nextui.sh` | Add `CONTINUITY_PAK_DIR` variable (defaults to parent of script directory). |

### Directories Created

| Directory | Purpose |
|-----------|---------|
| `tests/unit/platforms/` | Platform-specific unit tests |
| `tests/unit/platforms/nextui/` | NextUI unit tests |
| `build/` | Build output directory (git-ignored) |
| `build/bin/` | Cross-compiled binaries |
| `build/Continuity.pak/` | Assembled PAK for deployment |

---

## Acceptance Criteria

### PID Management

1. `cd_is_running` returns 0 when another daemon process is alive at the recorded PID.
2. `cd_is_running` returns 1 when PID file is absent.
3. `cd_is_running` returns 1 when PID file contains a stale PID (process not running), and removes the stale file.
4. `cd_is_running` returns 1 when PID file contains non-numeric content, and removes the file.
5. `cd_write_pid` writes the current process PID to `/tmp/continuity.pid`.
6. `cd_remove_pid` removes the PID file. No error if file doesn't exist.
7. Starting the daemon when another instance is already running: new instance logs a message and exits 0 (not an error).

### Module Loading

8. `cd_load_modules` sources all required modules without error.
9. After `cd_load_modules`, core functions are available: `enroll_is_enrolled`, `se_init`, `pm_load_platform_map`, `cs_is_cold_start`, `sb_is_stale`, `bp_run`, `rp_run`.
10. If a module file is missing, daemon logs the specific missing file and exits 1.
11. If a module file is missing, PID file is cleaned up before exit.

### Enrollment — Already Enrolled

12. When `enroll_is_enrolled` returns 0, `cd_check_enrollment` returns 0 without calling `esd_import`.
13. Daemon logs that device is already enrolled.

### Enrollment — Fresh Enrollment via setup.json

14. When not enrolled and `setup.json` exists, `cd_check_enrollment` calls `esd_import`.
15. After successful `esd_import`, `pal_init` is re-called and succeeds.
16. After successful `esd_import`, `se_init` is re-called with the new device name.
17. `cd_check_enrollment` returns 0 after successful enrollment.
18. The cloned repo exists at `$CONTINUITY_REPO_DIR` after enrollment.
19. Device registration JSON is committed and pushed to the remote.
20. `setup.json` is deleted from the SD card root after enrollment.

### Enrollment — Not Enrolled, No setup.json

21. When not enrolled and no `setup.json` exists, `cd_check_enrollment` returns 1.
22. Daemon logs that no setup.json was found.
23. PID file is cleaned up before exit.

### Enrollment — Failed Enrollment

24. When `esd_import` fails (invalid credentials, clone failure, etc.), `cd_check_enrollment` returns 1.
25. Daemon logs the enrollment failure.
26. PID file is cleaned up before exit.

### PAL Init — Pre-enrollment

27. When `pal_init` fails because device is not yet enrolled (no device_name file), daemon does NOT exit if `CONTINUITY_REPO_DIR` is set.
28. Daemon proceeds to enrollment check after `pal_init` failure in this case.

### Log File

29. Daemon creates log directory (`/mnt/SDCARD/.continuity/`) if it doesn't exist.
30. Daemon redirects stderr to the log file in append mode.
31. All `pal_log` messages appear in the log file.
32. Log file path is overridable via `CONTINUITY_LOG_FILE` variable (for testing).

### `auto.sh` Boot Hook

33. `auto.sh` starts the daemon in the background (non-blocking).
34. `auto.sh` does not produce any output to stdout.
35. `auto.sh` returns immediately (exit code 0).

### Code Quality

36. All new code passes `shellcheck` with no errors.
37. All new code passes `busybox ash -n` syntax check.
38. No banned BusyBox ash constructs (per CLAUDE.md table).
39. All variable expansions are quoted.
40. All new functions use `printf` for output, not `echo`.
41. All tests pass under `busybox ash`.

### Static Git Build (`scripts/build_git.sh`)

42. `build_git.sh` produces a static ARM ELF binary at `build/bin/git`.
43. The binary is statically linked (no shared library dependencies on the device).
44. Git version is pinned in the script — not `latest`.
45. The binary supports HTTPS transport (`git clone https://...` works).
46. `git clone`, `git pull`, `git push`, `git add`, `git commit`, `git diff`, `git log`, `git config`, `git rev-parse` all function.
47. Build uses `NO_PERL=1 NO_PYTHON=1 NO_TCLTK=1 NO_GETTEXT=1` to minimize size.
48. Binary is stripped of debug symbols.
49. Build script exits with clear error if Docker is not running.

### PAK Assembly (`scripts/build_pak.sh`)

50. `build_pak.sh` produces `build/Continuity.pak/` with the directory structure matching the PAK layout in the Design section.
51. `build_pak.sh` exits with clear error if `build/bin/git` does not exist.
52. All `.sh` files and `bin/git` are `chmod +x` in the output.
53. `auto.sh` is at the PAK root (not in `scripts/`).
54. `launch.sh` stub exists at the PAK root.
55. `config/platform_maps/nextui.json` is included.
56. All 11 core modules are copied to `scripts/core/`.
57. PAK assembly prints a file count and total size summary.
58. The assembled PAK, when copied to `/mnt/SDCARD/Tools/` on a Brick, results in a working daemon on boot.

---

## Testing Strategy

### Unit Tests (`tests/unit/platforms/nextui/test_daemon_bootstrap.sh`)

The daemon script is sourced (not executed) so individual functions can be called. Uses the test PAL.

**PID management tests:**
- `cd_write_pid`: verify PID file exists and contains `$$`.
- `cd_is_running` with active PID: start a background `sleep 60` process, write its PID, verify returns 0. Kill the process after test.
- `cd_is_running` with stale PID: use a PID known to not be running (e.g., 99999 after verifying it's dead), verify returns 1, verify PID file removed.
- `cd_is_running` with no PID file: verify returns 1.
- `cd_is_running` with non-numeric PID: write "garbage" to PID file, verify returns 1, verify file removed.
- `cd_remove_pid`: write a PID file, call remove, verify file gone. Call remove again — no error, returns 0.

**Module loading tests:**
- Happy path: set `CONTINUITY_PAK_DIR` to a test directory mirroring the PAK structure (symlinks to actual source files). Call `cd_load_modules`. Verify key functions exist (`command -v enroll_is_enrolled`, `command -v cs_is_cold_start`, etc.).
- Missing module: remove one symlink, call `cd_load_modules`, verify it exits with code 1 (capture via subshell).

**Enrollment check tests (mocked):**
- Already enrolled: define `enroll_is_enrolled` to return 0. Call `cd_check_enrollment`. Verify returns 0, `esd_import` not called.
- Not enrolled, no setup.json: define `enroll_is_enrolled` to return 1, `esd_detect_setup_file` to return 1. Call `cd_check_enrollment`. Verify returns 1.
- Not enrolled, setup.json present, enrollment succeeds: mock `esd_import` to return 0, set up enough state for `pal_init` to succeed post-enrollment. Verify returns 0.
- Not enrolled, setup.json present, enrollment fails: mock `esd_import` to return 1. Verify returns 1.

### Integration Test (`tests/integration/test_daemon_enrollment.sh`)

**Setup:** Create a bare remote repo (git init --bare), set up test PAL with overrides, create a `setup.json` with repo URL and device name. Set `CONTINUITY_PAK_DIR` to point at repo source tree.

**Scenario 1: Fresh enrollment via setup.json**
1. Create `setup.json` with valid repo URL, PAT (test token), device name.
2. Verify `enroll_is_enrolled` returns 1 (not yet enrolled).
3. Source daemon, call `cd_check_enrollment`.
4. Verify returns 0.
5. Verify repo cloned at `$CONTINUITY_REPO_DIR`.
6. Verify `device_name` file exists.
7. Verify device JSON committed and pushed to remote.
8. Verify `setup.json` deleted.
9. Verify `pal_init` succeeds after enrollment.

**Scenario 2: Already enrolled — no-op**
1. Run enrollment (Scenario 1).
2. Call `cd_check_enrollment` again.
3. Verify returns 0.
4. Verify no new commits (enrollment not re-run).

**Scenario 3: Not enrolled, no setup.json**
1. No `setup.json` on "SD card."
2. No repo directory.
3. Call `cd_check_enrollment`.
4. Verify returns 1.
5. Verify log message mentions missing setup.json.

**Scenario 4: Enrollment failure (bad repo URL)**
1. Create `setup.json` with an invalid repo URL.
2. Call `cd_check_enrollment`.
3. Verify returns 1.
4. Verify log message mentions failure.

### On-Device Test Checklist

| # | Test | Steps | Expected |
|---|------|-------|----------|
| D1 | Boot auto-start | Install PAK, power on Brick | `ps` shows `continuity_daemon.sh` process (briefly — it exits after enrollment check in this sub-sprint) |
| D2 | Fresh enrollment | Place `setup.json` on SD root, power on | Log shows enrollment complete. Repo cloned. Device JSON in GitHub repo. `setup.json` deleted. |
| D3 | Already enrolled boot | Reboot after D2 | Log shows "Enrolled" and daemon exits cleanly. |
| D4 | No enrollment, no setup.json | Boot without `setup.json` and without prior enrollment | Log shows "Not enrolled" error. Daemon exits 1. |
| D5 | No duplicate daemon | Run `continuity_daemon.sh` manually while it's already running | Second instance exits immediately, log shows "Another instance running." |
| D6 | Log file created | After any boot | `/mnt/SDCARD/.continuity/continuity.log` exists with timestamped entries. |

---

## Definition of Done

- [ ] `src/platforms/nextui/continuity_daemon.sh` implements: PID guard, module loading, PAL init, enrollment check, clean exit.
- [ ] `src/platforms/nextui/auto.sh` starts daemon in background, non-blocking.
- [ ] `CONTINUITY_PAK_DIR` variable added to `pal_nextui.sh`.
- [ ] PID file in `/tmp/` prevents duplicate daemon instances.
- [ ] Enrollment runs automatically when `setup.json` is detected.
- [ ] Daemon exits cleanly when not enrolled and no `setup.json` found.
- [ ] Daemon exits cleanly after successful enrollment (boot dispatch comes in 1.2).
- [ ] Log file created and all messages logged.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration tests cover: fresh enrollment, already enrolled, no setup.json, enrollment failure.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] On-device test checklist documented.
- [ ] `scripts/build_git.sh` cross-compiles a static ARM git binary via Docker.
- [ ] `scripts/build_pak.sh` assembles `build/Continuity.pak/` from source + git binary.
- [ ] `build/` directory is git-ignored.
- [ ] Static git binary supports HTTPS clone/push/pull to GitHub.
- [ ] PAK can be copied to Brick SD card and daemon starts on boot.
- [ ] Sprint summary written to `docs/sprints/sprint-1.1-summary.md` on completion.
