# Sprint 0.2 — Platform Abstraction Layer and Path Mapper

**Status:** Approved
**Date:** 2026-03-13
**Dependencies:** Sprint 0.1 (complete — taxonomy, platform maps, test harness)

---

## Goal

Define and implement the Platform Abstraction Layer (PAL) interface — the contract between all platform-agnostic core logic and platform-specific runtime environments — and implement the path mapper that uses it to translate between device save paths and canonical repo paths.

---

## Reference Specs

- `docs/design/pal.md` — PAL architecture, interface definition, and implementation patterns (primary reference)
- `config/system_taxonomy.json` — canonical system names used as repo directory names
- `config/platform_maps/nextui.json` — NextUI platform map (primary target)
- `config/platform_maps/onion.json` — Onion OS platform map
- `config/platform_maps/retrodeck.json` — RetroDeck platform map
- `config/platform_maps/retroarch_android.json` — Android platform map (contains paths with spaces)

---

## Scope

### 1. PAL Interface Loader and Validator (`src/core/pal.sh`)

Provides the `pal_validate()` function that all entry points call after sourcing a PAL implementation. This file does NOT source or load any PAL — it only validates that one has already been sourced.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `pal_validate` | `()` | 0 on success, 1 on failure | Check that all required PAL variables are set and all required PAL functions are defined. Print a descriptive error listing every missing item to stderr. Return 1 if anything is missing. |

**Required PAL variables checked by `pal_validate`:**

| Variable | Description |
|----------|-------------|
| `CONTINUITY_SAVES_ROOT` | Root directory containing system save subdirectories on this device |
| `CONTINUITY_REPO_DIR` | Path to the local git repo clone |
| `CONTINUITY_DEVICE_NAME` | Human-readable device identifier (set during enrollment) |
| `CONTINUITY_PLATFORM` | Platform identifier matching a platform map filename (e.g. `nextui`) |
| `CONTINUITY_GIT_BIN` | Path to the git binary, or `git` if on PATH |

**Required PAL functions checked by `pal_validate`:**

| Function | Description |
|----------|-------------|
| `pal_init` | Platform initialization — validate paths, read device name from enrollment config |
| `pal_is_online` | Check network reachability to GitHub |
| `pal_log` | Log a message at a given level (`debug`, `info`, `warn`, `error`) |
| `pal_get_platform_map` | Print the absolute path to this platform's map JSON file |

**Implementation notes:**
- `pal_validate` checks each variable with `[ -z "$VAR" ]` and each function with `command -v fn_name >/dev/null 2>&1`.
- All missing items are accumulated before printing. The error output lists them all at once so the caller can see every gap in a single run.
- `pal_validate` does not call `pal_init`. Initialization is the caller's responsibility, after validation.

---

### 2. NextUI PAL Implementation (`src/platforms/nextui/pal_nextui.sh`)

PAL implementation for TrimUI Brick running NextUI. BusyBox ash, FAT32 filesystem, no system git.

**Variables set:**

| Variable | Value |
|----------|-------|
| `CONTINUITY_SAVES_ROOT` | `/mnt/SDCARD/Saves` |
| `CONTINUITY_REPO_DIR` | `/mnt/SDCARD/.continuity/repo` |
| `CONTINUITY_PLATFORM` | `nextui` |
| `CONTINUITY_GIT_BIN` | `/mnt/SDCARD/Tools/Continuity.pak/bin/git` |
| `CONTINUITY_DEVICE_NAME` | Read from enrollment config by `pal_init` |

**Functions implemented:**

| Function | Implementation |
|----------|----------------|
| `pal_init` | Read device name from `$CONTINUITY_REPO_DIR/.continuity/device_name`. Return 1 if file absent (enrollment incomplete). Verify `$CONTINUITY_GIT_BIN` is executable. Return 1 if not. |
| `pal_is_online` | Try `ping -c 1 -W 3 github.com >/dev/null 2>&1`. Fall back to `wget --spider -q -T 3 https://github.com 2>/dev/null` if ping unavailable. Return 0 if either succeeds. |
| `pal_log` | `printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2` |
| `pal_get_platform_map` | Print `/mnt/SDCARD/Tools/Continuity.pak/config/platform_maps/nextui.json` |

**Implementation notes:**
- `pal_init` uses `local config_file; config_file=...` (separate declaration and assignment) for BusyBox ash compatibility.
- `pal_init` does not create directories — it validates that enrollment has already run.
- The git binary path is a PAK-relative path. It will not exist in CI — this is expected. The test PAL uses system `git`.

---

### 3. Test PAL (`tests/fixtures/pal_test.sh`)

Synthetic PAL for automated CI testing. All paths point to temp directories created at test time. Always reports online. Deterministic device name. No hardware dependencies.

**Variables set:**

| Variable | Value |
|----------|-------|
| `CONTINUITY_SAVES_ROOT` | `$TEST_TMPDIR/saves` |
| `CONTINUITY_REPO_DIR` | `$TEST_TMPDIR/repo` |
| `CONTINUITY_DEVICE_NAME` | `test-device` |
| `CONTINUITY_PLATFORM` | `nextui` |
| `CONTINUITY_GIT_BIN` | `git` |
| `CONTINUITY_SD_ROOT` | `$TEST_TMPDIR/sdcard` |

**Contract with callers:**
- The caller must set `TEST_TMPDIR` to an existing writable directory before sourcing this file.
- `pal_get_platform_map` returns `$TEST_TMPDIR/platform_map.json`. The caller is responsible for placing a valid platform map JSON at that path before calling `pm_load_platform_map`.

**Functions implemented:**

| Function | Implementation |
|----------|----------------|
| `pal_init` | `mkdir -p "$CONTINUITY_SAVES_ROOT" "$CONTINUITY_REPO_DIR"`. Always returns 0. |
| `pal_is_online` | Always returns 0. Individual tests can override this function locally to simulate offline conditions. |
| `pal_log` | `printf '[TEST %s] %s\n' "$1" "$2" >&2` |
| `pal_get_platform_map` | `printf '%s\n' "$TEST_TMPDIR/platform_map.json"` |

**Implementation notes:**
- Tests that need to simulate offline conditions override `pal_is_online` after sourcing: `pal_is_online() { return 1; }`.
- Tests that need a different platform map copy the appropriate JSON from `config/platform_maps/` to `$TEST_TMPDIR/platform_map.json` at setup.

---

### 4. Path Mapper (`src/core/path_mapper.sh`)

Translates between platform-specific save paths on the device and canonical repo-relative paths. Uses `pal_get_platform_map` to locate its configuration. Requires the PAL to be loaded and validated before the mapper is sourced.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `pm_load_platform_map` | `(platform_map_file)` | 0 on success, 1 on error | Parse the platform map JSON at the given path. Set module-internal variables for `saves_root`, `save_extension`, and all `system_paths` key/value pairs. Must be called before any other `pm_*` function. |
| `pm_local_to_repo` | `(local_path)` | prints repo-relative path; 0 on success, 1 if system unrecognized | Convert an absolute local device path to a repo-relative path. Example: `/mnt/SDCARD/Saves/SFC/super_metroid.srm` → `snes/super_metroid.srm`. Log a warning to stderr and return 1 if the path's system directory is not in the platform map. |
| `pm_repo_to_local` | `(repo_path)` | prints absolute local path; 0 on success, 1 if system unrecognized | Convert a repo-relative path to an absolute local device path. Example: `snes/super_metroid.srm` → `/mnt/SDCARD/Saves/SFC/super_metroid.srm`. Log a warning to stderr and return 1 if the canonical system name is not in the platform map. |
| `pm_list_watched_dirs` | `()` | prints one absolute path per line | List every local save directory that the daemon should monitor. Constructed from `saves_root` + each platform-specific system directory. Prints only; does not check whether the directories exist. |

**JSON parsing approach:**

The platform map files are small (under 30 lines), schema-versioned, and have a predictable structure. They are parsed using `grep` and `sed` — no `jq` required.

```sh
# Extract saves_root
saves_root=$(grep '"saves_root"' "$map_file" | sed 's/.*"saves_root" *: *"\(.*\)".*/\1/')

# Extract save_extension
save_extension=$(grep '"save_extension"' "$map_file" | sed 's/.*"save_extension" *: *"\(.*\)".*/\1/')

# Extract system_paths entries (one canonical:platform pair per line)
# Each entry has the form:   "canonical": "platform_dir",
# The block is bounded by "system_paths" and the next "}"
```

`pm_load_platform_map` builds two lookup structures from the parsed data:
- Forward map (local system dir → canonical name): used by `pm_local_to_repo`
- Reverse map (canonical name → local system dir): used by `pm_repo_to_local`

Because BusyBox ash does not support associative arrays, these maps are stored as newline-delimited strings of `key=value` pairs in module-level variables, looked up with `grep` and `sed` at call time.

**Path-with-spaces handling:**

RetroArch Android uses directory names like `Nintendo - Game Boy`. These must be handled correctly throughout:
- `pm_load_platform_map` must not break on values containing spaces.
- `pm_local_to_repo` receives the path as a single quoted argument — callers must quote it.
- `pm_list_watched_dirs` prints paths via `printf '%s\n'` so consumers can handle them line-by-line.
- All internal `grep`/`sed` operations use the full value including spaces, not word-splitting.

**Unknown system directory handling:**

If `pm_local_to_repo` receives a path whose system directory does not appear in the platform map, it must:
1. Log a warning to stderr via `pal_log "warn" "..."`.
2. Return 1.
3. Not crash, not print a partial path to stdout.

The same applies to `pm_repo_to_local` for unrecognized canonical names. This allows new or custom system directories to exist on a device without breaking the mapper for all other systems.

**Implementation notes:**
- `pm_load_platform_map` sets module-level variables (not exported). All `pm_*` functions assume the map has been loaded.
- The mapper does not validate that directories exist — it only translates paths. Existence checks are the caller's responsibility.
- All variable expansions are quoted throughout. No unquoted `$var` in the implementation.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Onion OS PAL implementation (`pal_onion.sh`) | 2.1 or 3.1 |
| RetroDeck PAL implementation (`pal_retrodeck.sh`) | 2.1 |
| Android PAL implementation | 3.2 |
| Sync engine (git add/commit/push/pull) | 0.3 |
| Enrollment logic and credential import | 0.3 |
| Cold start sync flow | 0.4 |
| Boot pull sync flow | 0.5 |
| Runtime poll (find -newer) | 0.6 |
| Stale boot recovery | 0.7 |
| Conflict handler | 0.8 |
| Platform daemon loop (NextUI) | 1.1 |
| NextUI Tool PAK | 1.2 |
| Updating `docs/design/architecture.md` to remove wifi_monitor.sh reference | 0.2 summary task |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/pal.sh` | PAL interface validator (`pal_validate`) |
| `src/platforms/nextui/pal_nextui.sh` | NextUI PAL implementation |
| `tests/fixtures/pal_test.sh` | Test PAL for CI — synthetic environment, always online |
| `src/core/path_mapper.sh` | Path translation between device paths and repo paths |
| `tests/unit/core/test_pal_validate.sh` | Unit tests for `pal_validate` |
| `tests/unit/core/test_path_mapper.sh` | Unit tests for path mapper (all 4 platform maps, spaces, unknown systems) |
| `tests/integration/test_pal_swap.sh` | Integration test proving same path mapper works with both test PAL and NextUI PAL |

### Files Modified

| File | Change |
|------|--------|
| `docs/design/architecture.md` | Remove `wifi_monitor.sh` reference; note that connectivity checking is absorbed into `pal_is_online()` |

---

## Acceptance Criteria

### PAL Validator

1. `pal_validate` returns 0 when all 5 required variables are set and all 4 required functions are defined.
2. `pal_validate` returns 1 and prints a descriptive error when any required variable is missing.
3. `pal_validate` returns 1 and prints a descriptive error when any required function is missing.
4. `pal_validate` accumulates all missing items and reports them in a single error message, not one-at-a-time.
5. `pal_validate` does not call `pal_init` — it only checks that the interface is complete.

### NextUI PAL

6. Sourcing `pal_nextui.sh` sets all 4 static variables (`CONTINUITY_SAVES_ROOT`, `CONTINUITY_REPO_DIR`, `CONTINUITY_PLATFORM`, `CONTINUITY_GIT_BIN`) to their NextUI-correct values.
7. `pal_init` reads `CONTINUITY_DEVICE_NAME` from `$CONTINUITY_REPO_DIR/.continuity/device_name` and returns 0 when the file exists.
8. `pal_init` returns 1 when the device name file does not exist.
9. `pal_init` returns 1 when `CONTINUITY_GIT_BIN` is not executable.
10. `pal_get_platform_map` prints the absolute path to `nextui.json` within the PAK directory.
11. `pal_nextui.sh` passes `shellcheck` with no errors.
12. `pal_nextui.sh` passes `busybox ash -n` syntax check.

### Test PAL

13. Sourcing `pal_test.sh` with `TEST_TMPDIR` set produces all 5 required variables pointing into `$TEST_TMPDIR`.
14. `pal_init` creates `$CONTINUITY_SAVES_ROOT` and `$CONTINUITY_REPO_DIR` and returns 0.
15. `pal_is_online` returns 0 by default.
16. `pal_is_online` can be overridden after sourcing to return 1 for offline simulation.
17. `pal_test.sh` passes `shellcheck` with no errors.
18. `pal_test.sh` passes `busybox ash -n` syntax check.

### Path Mapper

19. `pm_load_platform_map` loads the NextUI platform map without error.
20. `pm_load_platform_map` loads the Onion OS platform map without error.
21. `pm_load_platform_map` loads the RetroDeck platform map without error.
22. `pm_load_platform_map` loads the RetroArch Android platform map (which has paths with spaces) without error.
23. `pm_local_to_repo` correctly maps a NextUI save path to its repo-relative path (e.g. `/mnt/SDCARD/Saves/SFC/super_metroid.srm` → `snes/super_metroid.srm`).
24. `pm_local_to_repo` correctly maps a RetroArch Android path containing spaces (e.g. `/storage/emulated/0/RetroArch/saves/Nintendo - Game Boy/links_awakening.srm` → `gb/links_awakening.srm`).
25. `pm_repo_to_local` correctly maps a repo-relative path to a NextUI device path.
26. `pm_repo_to_local` correctly maps a repo-relative path to a RetroArch Android device path containing spaces.
27. Round-trip holds for all 4 platforms: `pm_repo_to_local(pm_local_to_repo(path)) == path`.
28. `pm_local_to_repo` logs a warning to stderr and returns 1 for a path whose system directory is not in the platform map — does not crash, does not print to stdout.
29. `pm_repo_to_local` logs a warning to stderr and returns 1 for an unrecognized canonical system name — does not crash, does not print to stdout.
30. `pm_list_watched_dirs` prints one directory path per line for every system in the loaded platform map.
31. `pm_list_watched_dirs` output for the RetroArch Android map includes paths with spaces, one per line, intact.
32. `path_mapper.sh` passes `shellcheck` with no errors.
33. `path_mapper.sh` passes `busybox ash -n` syntax check.

### Cross-PAL Portability

34. The same `path_mapper.sh` code, loaded after the test PAL, produces correct translations using `$TEST_TMPDIR/platform_map.json`.
35. The same `path_mapper.sh` code, loaded after the NextUI PAL (with a device name file present), produces correct translations using the NextUI platform map path returned by `pal_get_platform_map`.
36. All unit and integration tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests

All unit test files are self-contained: they create temp directories, install fixtures, run assertions, and clean up on EXIT via `trap`. No network access. No physical device required.

**`tests/unit/core/test_pal_validate.sh`:**

Tests `pal_validate` in isolation by manually setting and unsetting variables and defining/undefining functions in a subshell before calling `pal_validate`.

- Pass case: all 5 variables set, all 4 functions defined → returns 0.
- Fail case: each required variable missing individually → returns 1, error message names the missing variable.
- Fail case: each required function missing individually → returns 1, error message names the missing function.
- Fail case: multiple items missing simultaneously → returns 1, error message lists all missing items.
- Verify `pal_validate` does not invoke `pal_init` (define `pal_init` as a function that sets a flag; verify flag unset after `pal_validate`).

**`tests/unit/core/test_path_mapper.sh`:**

Sources `tests/fixtures/pal_test.sh`, then sources `src/core/path_mapper.sh`. For each of the 4 platform maps:

- Copy the platform map JSON to `$TEST_TMPDIR/platform_map.json`.
- Call `pm_load_platform_map "$(pal_get_platform_map)"`.
- Verify `pm_local_to_repo` for at least 3 canonical systems.
- Verify `pm_repo_to_local` for at least 3 canonical systems.
- Verify round-trip for at least 3 systems.
- Verify `pm_list_watched_dirs` produces the expected number of lines.

Additional tests for the RetroArch Android map specifically:
- Verify `pm_local_to_repo` correctly handles `Nintendo - Game Boy` (path with spaces).
- Verify `pm_repo_to_local` correctly reconstructs `Nintendo - Game Boy` in the output path.
- Verify `pm_list_watched_dirs` output includes a line with spaces intact.

Unknown system tests (using the NextUI map):
- Verify `pm_local_to_repo "/mnt/SDCARD/Saves/UNKNOWN/game.srm"` returns 1 and writes to stderr.
- Verify `pm_repo_to_local "unknownsys/game.srm"` returns 1 and writes to stderr.
- Verify neither call prints anything to stdout.

### Integration Test

**`tests/integration/test_pal_swap.sh`:**

Proves that `path_mapper.sh` is genuinely PAL-agnostic by loading it twice in separate subshells, once with the test PAL and once simulating the NextUI PAL (with a hand-crafted device name file), and asserting both produce identical translation results for a representative set of paths.

Test flow:
1. Create `TEST_TMPDIR`. Copy `nextui.json` to `$TEST_TMPDIR/platform_map.json`.
2. **Subshell A (test PAL):** Source `pal_test.sh`, call `pal_init`, call `pal_validate`, load path mapper via `pm_load_platform_map "$(pal_get_platform_map)"`. Translate a fixed set of 5 representative paths (covering NextUI, Android paths-with-spaces, and unknown system). Capture output.
3. **Subshell B (NextUI PAL simulation):** Set `TEST_TMPDIR` as `CONTINUITY_REPO_DIR`, write a device name file, override `pal_get_platform_map` to return the same `nextui.json` path, source `src/core/pal.sh`, call `pal_validate`, load path mapper. Translate the same 5 paths. Capture output.
4. Assert that `pm_local_to_repo` and `pm_repo_to_local` results from subshell A and subshell B are identical.
5. Assert `pal_validate` returned 0 in both subshells.
6. Clean up.

---

## Definition of Done

- [ ] `src/core/pal.sh` implemented with `pal_validate` matching the interface in `docs/design/pal.md`.
- [ ] `src/platforms/nextui/pal_nextui.sh` implements all 4 required functions and sets all 5 required variables.
- [ ] `tests/fixtures/pal_test.sh` provides a fully functional synthetic PAL for CI use.
- [ ] `src/core/path_mapper.sh` implements all 4 `pm_*` functions.
- [ ] All 4 platform maps load without error through `pm_load_platform_map`.
- [ ] Paths with spaces (RetroArch Android) handled correctly throughout.
- [ ] `pal_validate` unit tests pass under `busybox ash`.
- [ ] Path mapper unit tests pass under `busybox ash`.
- [ ] PAL-swap integration test passes under `busybox ash`.
- [ ] `shellcheck` passes on all `.sh` files introduced by this sprint with no errors.
- [ ] `busybox ash -n` syntax check passes on all `.sh` files introduced by this sprint.
- [ ] No banned BusyBox ash constructs used anywhere in `src/core/` or `src/platforms/nextui/` (see CLAUDE.md).
- [ ] All functions in all files have a brief usage comment at the top of the function.
- [ ] `docs/design/architecture.md` updated to remove `wifi_monitor.sh` reference.
- [ ] Sprint summary written to `docs/sprints/sprint-0.2-summary.md`.

---

## Open Questions

None.
