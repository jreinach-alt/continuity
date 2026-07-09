# Sprint 0.7 — Stale Boot Recovery

**Status:** Approved
**Date:** 2026-03-13
**Dependencies:** Sprint 0.6 (runtime poll — complete; full sentinel lifecycle in steady state, `rp_update_sentinel` and the clean shutdown marker concept established as part of graceful exit design)

---

## Goal

Implement stale boot recovery — the sync phase that runs when a device boots and the sentinel exists (so cold start is not needed) but the device did not shut down cleanly. In a normal runtime, the daemon writes a clean shutdown marker before exiting (via SIGTERM). When that marker is absent on boot despite a sentinel being present, the device may have crashed, been killed, or lost battery during a play session. In that state the repo and device may be inconsistent in either or both directions: unsaved local changes that were never polled, and remote changes from other devices that were never pulled.

Stale boot recovery combines both inbound and outbound sync in the correct order: pull first (get the latest remote state), then scan all device saves and push any local changes not yet in the repo. After recovery, the device is in the same clean state as a normal successful boot pull, and subsequent runtime polls can proceed on a reliable baseline.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface: `CONTINUITY_SAVES_ROOT`, `CONTINUITY_REPO_DIR`, `CONTINUITY_DEVICE_NAME`, `CONTINUITY_GIT_BIN`, `pal_is_online()`, `pal_log()`
- `docs/roadmap.md` — Sprint 0.7 scope, acceptance criteria, and relationship to Sprint 1.1 (boot dispatcher)
- `src/core/pal.sh` — PAL validator (Sprint 0.2 output, assumed present)
- `src/core/path_mapper.sh` — `pm_local_to_repo()`, `pm_repo_to_local()`, `pm_list_watched_dirs()` (Sprint 0.2 output, assumed present)
- `src/core/sync_engine.sh` — `se_pull()`, `se_stage_files()`, `se_commit()`, `se_push()`, `se_has_unpushed_commits()`, `se_get_head_commit()` (Sprint 0.3 output, assumed present)
- `src/core/cold_start.sh` — `cs_store_commit()`, `cs_read_commit()` (Sprint 0.4 output, assumed present)
- `src/core/boot_pull.sh` — `bp_get_remote_changes()`, `bp_apply_remote_saves()` (Sprint 0.5 output, assumed present)
- `src/core/change_detector.sh` — `cd_detect_changes()`, `cd_list_device_saves()` (Sprint 0.4 output, assumed present)
- `src/core/runtime_poll.sh` — `rp_update_sentinel()` (Sprint 0.6 output, assumed present)

---

## Scope

### `src/core/stale_boot.sh`

Single-file module implementing stale boot detection and recovery. Assumes the PAL has been sourced, validated, and initialized before any `sb_*` function is called. Assumes all modules listed in Reference Specs have been sourced by the entry point. Holds no persistent module-level state of its own.

---

### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `sb_is_stale` | `(repo_dir)` | 0 if stale (recovery needed), 1 if clean | Returns 0 if `$repo_dir/.continuity/sentinel` exists AND `$repo_dir/.continuity/clean_shutdown` does NOT exist. Returns 1 if the sentinel does not exist (cold start case — not stale boot's concern) or if the clean shutdown marker is present (clean boot — use boot pull). |
| `sb_mark_clean_shutdown` | `(repo_dir)` | 0 on success, 1 on error | Create (or overwrite) `$repo_dir/.continuity/clean_shutdown` with the current ISO-8601 timestamp. This is called by the daemon on SIGTERM before the daemon exits. |
| `sb_clear_shutdown_marker` | `(repo_dir)` | 0 on success (including when file did not exist — idempotent), 1 if removal failed | Remove `$repo_dir/.continuity/clean_shutdown` if it exists. Called by `sb_run` at the start of recovery to consume the absence signal. Returns 0 if the file did not exist (idempotent). |
| `sb_run` | `(repo_dir)` | 0 on success/no-op, 1 on unrecoverable error | Full stale boot recovery flow. Orchestrates all other `sb_*` functions plus calls to prior sprint modules. Full flow described below. |

---

### `sb_run` Flow

```
sb_run(repo_dir):

  1. sb_clear_shutdown_marker "$repo_dir"
     — Consume the marker regardless of outcome. We are in recovery now.
     — Do not abort on failure (e.g. marker already absent is fine — return 0
       from sb_clear_shutdown_marker is expected in that case).

  2. If pal_is_online AND se_has_unpushed_commits "$repo_dir" returns 0 (commits are pending):
       se_push "$repo_dir"
         — If se_push returns 1 (persistent failure):
             pal_log "warn" "Stale boot: push of interrupted session commits failed — continuing"
             — Do not abort. The local commits exist; push can retry later.
         — If se_push returns 2 (offline — race between pal_is_online check and push):
             pal_log "warn" "Stale boot: went offline during push of interrupted session — continuing"
             — Do not abort. Treat same as push failure; local commits survive.
         — If se_push returns 0:
             pal_log "info" "Stale boot: pushed commits from interrupted session"
     — If offline or no unpushed commits: skip silently.

  3. Inbound pull phase:
     a. old_commit=$(cs_read_commit "$repo_dir")
        — If cs_read_commit returns empty or fails:
            pal_log "warn" "Stale boot: no stored commit — cold start may not have run"
            return 1
     b. se_pull "$repo_dir"
        — If se_pull returns 2 (network error):
            pal_log "warn" "Stale boot: offline — pull skipped, proceeding with local repo state"
            — Continue. Outbound scan may still find local changes to commit.
        — If se_pull returns 1 (diverged):
            pal_log "warn" "Stale boot: diverged history — conflict handler required (Sprint 0.8)"
            return 1
     c. new_commit=$(se_get_head_commit "$repo_dir")
     d. If old_commit != new_commit:
          changed_files=$(bp_get_remote_changes "$repo_dir" "$old_commit")
          — If bp_get_remote_changes returns 1:
              pal_log "error" "Stale boot: failed to determine remote changes"
              return 1
          — If changed_files is non-empty:
              bp_apply_remote_saves "$repo_dir" "$changed_files"
              — If bp_apply_remote_saves returns 1:
                  pal_log "error" "Stale boot: failed to apply one or more remote saves"
                  return 1
          cs_store_commit "$repo_dir" "$new_commit"
     e. If old_commit == new_commit:
          pal_log "info" "Stale boot: no remote changes since last sync"

  4. Outbound catch-up scan phase:
     a. device_saves=$(cd_list_device_saves)
        — Enumerate ALL .srm files on device (not find -newer — sentinel is stale).
     b. changed_count=0
        — Use a temp file to track whether any changes were found across the loop.
        # Do NOT use `trap EXIT` here — it would replace the caller's trap.
        # Clean up the temp file explicitly after the loop.
        tmpfile=$(mktemp)
        printf '0\n' > "$tmpfile"
     c. For each device save (while IFS= read -r device_path):
          repo_path=$(pm_local_to_repo "$device_path")
          — If pm_local_to_repo returns 1:
              pal_log "warn" "Stale boot: unknown system dir, skipping: $device_path"
              continue
          repo_file="$repo_dir/$repo_path"
          If repo_file does not exist OR ! cmp -s "$device_path" "$repo_file":
            mkdir -p "$(dirname "$repo_file")"
            cp "$device_path" "$repo_file"
            pal_log "info" "Stale boot: catch-up copied $device_path -> $repo_path"
            printf '1\n' > "$tmpfile"
     d. changed_count=$(cat "$tmpfile")
        rm -f "$tmpfile"

  5. If changed_count is 1 (any catches were made):
       staged=$(cd_detect_changes "$repo_dir")
       If staged is non-empty:
         se_stage_files "$repo_dir" "$staged"
         se_commit "$repo_dir" "$staged" "stale boot catch-up from $CONTINUITY_DEVICE_NAME"
           — On failure: pal_log "error", return 1
         If pal_is_online:
           se_push "$repo_dir"
             — If se_push returns 1: pal_log "error", return 1
             — If se_push returns 2: pal_log "warn" "Stale boot: offline — catch-up commit queued"
         head_hash=$(se_get_head_commit "$repo_dir")
         cs_store_commit "$repo_dir" "$head_hash"
           — On failure: pal_log "error", return 1
       Else:
         pal_log "info" "Stale boot: catch-up scan found file changes but git reports none"
     Else:
       pal_log "info" "Stale boot: catch-up scan found no local changes"

  6. rp_update_sentinel "$repo_dir"
       — On failure: pal_log "error", return 1

  7. pal_log "info" "Stale boot recovery complete"
     return 0
```

---

### Implementation Notes

**The clean shutdown marker:**

The clean shutdown marker is `$repo_dir/.continuity/clean_shutdown`. It is a plain file — its presence (not contents) is the signal. The daemon writes it on SIGTERM via `sb_mark_clean_shutdown`. The boot dispatcher (Sprint 1.1) checks for it via `sb_is_stale`:

```
if cs_is_cold_start "$repo_dir":       → cs_run     (Sprint 0.4)
elif sb_is_stale "$repo_dir":          → sb_run     (this sprint)
else:                                  → bp_run     (Sprint 0.5)
```

The clean shutdown marker is NOT committed to the repo. It is local device state, like the sentinel and `last_known_commit`. It must be listed in `.gitignore` (Sprint 0.3 enrollment is responsible for writing the `.gitignore`; however, `cd_detect_changes` filters to `.srm` files only, so an absent `.gitignore` entry does not cause accidental staging).

**`sb_is_stale` — all three sentinel states:**

| Sentinel | Clean shutdown marker | Result |
|----------|-----------------------|--------|
| Absent   | Absent                | Return 1 — cold start case, not stale boot |
| Absent   | Present               | Return 1 — cold start case (marker can exist from a prior clean session; it will be cleared on sb_run or is harmless) |
| Present  | Present               | Return 1 — clean shutdown, run boot pull |
| Present  | Absent                | Return 0 — stale boot, run recovery |

**Why no `.local` files in the catch-up scan (step 4):**

The catch-up scan treats the device version as authoritative for this device's saves. The device's own changes since the last sync (changes this device made) cannot be conflicts with this device's own repo perspective — they ARE this device's contribution. A true conflict (remote and local both changed the same save) is a Sprint 0.8 concern: `se_pull` returns 1 (diverged) in that case, and `sb_run` exits at step 3b.

For the current sprint: if `se_pull` succeeds (fast-forward) and the catch-up scan then finds a device file that differs from the post-pull repo copy, the device version wins. This is intentional and safe: the device file is the user's own save, the remote change arrived on a pull, and if they overlap on the same file, the local (more recent in wall-clock terms) version represents the user's most recent play session.

**BusyBox ash compatibility:**

- No arrays. All lists are newline-delimited strings iterated with `while IFS= read -r line`.
- `local var; var=$(cmd)` — never `local var=$(cmd)`.
- No `[[`, no `${var//pat/rep}`, no `<<<`, no process substitution.
- All variable expansions quoted.
- `printf` over `echo`.
- Assignments inside `while read` piped from subshells are not visible to the parent shell (no `lastpipe`). Step 4 uses a temp file (`$tmpfile`) to propagate the changed flag across the loop boundary.
- `command -v` for optional function checks (e.g. `pal_on_sync_complete`).

**Temp file management in step 4:**

```sh
# NOTE: Do NOT use 'trap EXIT' here — it would replace the caller's trap.
# Clean up the temp file explicitly after the loop.
_sb_tmpfile=$(mktemp)
printf '0\n' > "$_sb_tmpfile"
cd_list_device_saves | while IFS= read -r device_path; do
    # ... cmp and cp logic ...
    printf '1\n' > "$_sb_tmpfile"
done
_sb_changed=$(cat "$_sb_tmpfile")
rm -f "$_sb_tmpfile"
```

Because the `while` loop runs in a subshell (piped), writes to `$_sb_tmpfile` inside the loop are visible in the parent shell when the loop completes. The temp file acts as a cross-subshell signal.

**Handling offline during the inbound phase:**

If `se_pull` returns 2 (offline), `sb_run` continues without applying remote changes (there are none to apply since the pull was skipped). The stored commit is not updated yet. The catch-up scan and outbound commit proceed against the local repo state. The sentinel is still updated at the end so the runtime poll has a fresh baseline. On the next boot pull or poll cycle, if connectivity is restored, remote changes will be fetched then.

**Step 2 — push before pull:**

Pushing pending commits before pulling is correct and necessary. If the device had committed saves locally before the crash and then we pull first, `git pull --ff-only` may fail if the remote has also advanced (diverged). Pushing first ensures our local work is on the remote before we attempt to fast-forward. If push fails (non-fatal in step 2), we still attempt the pull — it may succeed if the remote has not diverged from our local state.

**Step 5 — `cd_detect_changes` after catch-up copy:**

After copying device files into the repo working tree, `cd_detect_changes` is called to determine what git actually considers changed (filtering out any false positives where the device and repo bytes happened to match despite `cmp -s` triggering). The `se_stage_files` and `se_commit` calls only proceed if git reports actual staged changes.

**Dependency sourcing:**

`stale_boot.sh` does not source its dependencies. The entry point (daemon or test harness) sources all modules before calling any `sb_*` function. The module header comment must list all required functions from other modules.

**Module header requirements:**

`stale_boot.sh` must include a usage comment at the top listing:
- Prerequisites: PAL loaded and initialized, `path_mapper.sh` loaded with platform map, `sync_engine.sh` initialized, `cold_start.sh` sourced, `boot_pull.sh` sourced, `change_detector.sh` sourced, `runtime_poll.sh` sourced.
- Public functions: `sb_run`, `sb_is_stale`, `sb_mark_clean_shutdown`, `sb_clear_shutdown_marker`.

**All git invocations:**

Use `$CONTINUITY_GIT_BIN` — never the literal string `git`. Specify the repo using `-C "$repo_dir"`.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Boot dispatch logic (deciding which phase to run) | 1.1 (NextUI daemon) |
| Conflict handler for diverged history on pull | 0.8 |
| `.local` file creation for conflicts during catch-up | 0.8 |
| Daemon SIGTERM handler (calls `sb_mark_clean_shutdown`) | 1.1 |
| Runtime poll loop | 1.1 |
| RetroDeck, Onion OS, Android platform clients | 2.1, 3.1, 3.2 |
| `pal_on_sync_complete` hook | 1.1 |
| Handling non-`.srm` files | never |
| Online-to-offline fallback during push retry | 0.3 (sync engine) |
| Stale boot for a device that has never run cold start (no sentinel) | N/A — `sb_is_stale` returns 1 when sentinel is absent |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/stale_boot.sh` | Stale boot recovery: `sb_run`, `sb_is_stale`, `sb_mark_clean_shutdown`, `sb_clear_shutdown_marker` |
| `tests/unit/core/test_stale_boot.sh` | Unit tests for all four `sb_*` functions |
| `tests/integration/test_stale_boot_flow.sh` | End-to-end stale boot integration test using test PAL and local bare remote |

### Files Modified

| File | Change |
|------|--------|
| `docs/roadmap.md` | Update Sprint 0.7 status to Complete after implementation |

### Directories Created (if not already present)

None. All target directories already exist per prior sprint structure.

---

## Acceptance Criteria

### `sb_is_stale`

1. Returns 0 (stale) when `$repo_dir/.continuity/sentinel` exists AND `$repo_dir/.continuity/clean_shutdown` does not exist.
2. Returns 1 (not stale) when `$repo_dir/.continuity/sentinel` exists AND `$repo_dir/.continuity/clean_shutdown` exists.
3. Returns 1 (not stale) when `$repo_dir/.continuity/sentinel` does not exist (regardless of whether the clean shutdown marker exists).
4. Does not modify any files or state when called.

### `sb_mark_clean_shutdown`

5. Creates `$repo_dir/.continuity/clean_shutdown` with a non-empty ISO-8601 timestamp as contents.
6. Creates `$repo_dir/.continuity/` if it does not already exist.
7. Overwrites an existing `clean_shutdown` file (idempotent — calling twice does not error).
8. Returns 0 on success.

### `sb_clear_shutdown_marker`

9. Removes `$repo_dir/.continuity/clean_shutdown` when it exists, and returns 0.
10. Returns 0 (not 1) when `$repo_dir/.continuity/clean_shutdown` does not exist (idempotent — clearing an already-absent marker is not an error).
11. After a call when the marker existed, `sb_is_stale` returns 0 for a repo with a sentinel (marker gone, sentinel present → stale).

### `sb_run` — Clean Shutdown Marker Handling

12. `sb_run` removes the clean shutdown marker as its first step, before any git or network operations.
13. After `sb_run` returns (success or failure), `$repo_dir/.continuity/clean_shutdown` does not exist.

### `sb_run` — Inbound Pull Phase

14. When the repo has remote changes since the stored commit, `sb_run` applies them to the device via `bp_apply_remote_saves` and updates the stored commit to the new HEAD.
15. When there are no remote changes (old and new commit are identical), `sb_run` does not call `bp_apply_remote_saves` and leaves the stored commit unchanged.
16. When `se_pull` returns 2 (offline), `sb_run` logs a warning, skips the apply step, and continues to the catch-up scan (does not return 2 at this point).
17. When `se_pull` returns 1 (diverged), `sb_run` returns 1 without proceeding to the catch-up scan.
18. When `cs_read_commit` returns empty (no stored commit), `sb_run` returns 1 and does not call `se_pull`.
19. When `bp_get_remote_changes` returns 1, `sb_run` returns 1.
20. When `bp_apply_remote_saves` returns 1, `sb_run` returns 1.

### `sb_run` — Unpushed Commits Before Pull

21. When online and `se_has_unpushed_commits` returns 0 (pending commits exist), `sb_run` calls `se_push` before pulling.
22. When `se_push` returns 1 (persistent failure) in this pre-pull step, `sb_run` logs a warning and continues (does not return 1).
23. When offline (`pal_is_online` returns 1), `sb_run` does not call `se_push` for pending commits.
24. When `se_has_unpushed_commits` returns 1 (no pending commits), `sb_run` does not call `se_push` for pending commits.

### `sb_run` — Catch-Up Scan Phase

25. Scans ALL `.srm` files on the device (using `cd_list_device_saves`) — not `find -newer` sentinel.
26. For each device save that differs from the repo copy (or has no repo copy), copies the device version into the repo working tree.
27. For each device save that is byte-for-byte identical to the repo copy, does NOT copy or stage it.
28. Files in system directories unrecognized by `pm_local_to_repo` are skipped with a warning; the rest of the scan continues normally.
29. After the catch-up copy, if `cd_detect_changes` reports changes, stages and commits them.
30. After commit, if online, pushes and updates `last_known_commit` to the new HEAD.
31. After commit, if offline, logs that the commit is queued locally and updates `last_known_commit` to the local HEAD.
32. If the catch-up scan finds no differing files, no commit is made.
33. Does NOT create `.local` conflict files during the catch-up scan — the device version always wins without a conflict artifact.

### `sb_run` — Sentinel and Commit State

34. On success, the sentinel mtime is updated (via `rp_update_sentinel`) as the final step.
35. On success, `last_known_commit` reflects the HEAD of the repo after all commits in this sprint's recovery run.
36. When `sb_run` returns 1 (error), the sentinel may or may not have been updated (steps before the failure may have partially completed). The sentinel is NOT guaranteed to be updated on error return.
37. When `sb_run` returns 1, a subsequent `sb_is_stale` call returns 0 (sentinel still present, clean shutdown marker still absent — recovery is incomplete, so the next boot should retry).

### Cross-Cutting

38. `stale_boot.sh` passes `shellcheck` with no errors.
39. `stale_boot.sh` passes `busybox ash -n` syntax check.
40. No banned BusyBox ash constructs are used (see CLAUDE.md table).
41. All git commands in `stale_boot.sh` use `$CONTINUITY_GIT_BIN`, not the literal string `git`.
42. All git commands specify the repo via `-C "$repo_dir"`, not by assuming the current working directory.
43. All variable expansions in `stale_boot.sh` are quoted.
44. All four public functions have a usage comment at their definition.
45. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_stale_boot.sh`)

All unit tests are self-contained. Each test creates a fresh temp directory, sets up the minimum required state, runs assertions, and removes the temp directory on EXIT via `trap 'rm -rf "$TEST_TMPDIR"' EXIT`. No network access. All tests run under `busybox ash`.

The test file sources: `tests/fixtures/pal_test.sh`, `src/core/path_mapper.sh`, `src/core/sync_engine.sh`, `src/core/cold_start.sh`, `src/core/change_detector.sh`, `src/core/boot_pull.sh`, `src/core/runtime_poll.sh`, `src/core/stale_boot.sh`.

If any prior sprint module does not exist when this sprint is implemented in isolation, the test file must provide stub implementations of the required functions for isolation. When prior sprint outputs are delivered, the stubs are replaced by the real sourced modules.

**`sb_is_stale` tests:**

- Sentinel absent, marker absent: verify returns 1.
- Sentinel present, marker absent: verify returns 0.
- Sentinel present, marker present: verify returns 1.
- Sentinel absent, marker present: verify returns 1.
- Calling `sb_is_stale` does not modify any file (check mtime of `.continuity/` contents before and after).

**`sb_mark_clean_shutdown` tests:**

- Call on a repo with no `.continuity/` directory: verify directory and file are both created, file contains a non-empty string, returns 0.
- Call when marker already exists: verify it is overwritten (contents change or mtime updates), returns 0.
- After `sb_mark_clean_shutdown`, verify `sb_is_stale` returns 1 (marker present → not stale).

**`sb_clear_shutdown_marker` tests:**

- Call when marker exists: verify file is removed, returns 0.
- Call when marker does not exist: verify returns 0, no error.
- After `sb_clear_shutdown_marker` (with sentinel present), verify `sb_is_stale` returns 0.

**`sb_run` unit tests:**

Each scenario uses a local bare repo acting as the fake remote, a working clone as `$CONTINUITY_REPO_DIR`, and the test PAL environment.

- **No stored commit:** Empty `last_known_commit`. Call `sb_run`. Verify returns 1. Verify `se_pull` not called (use a stub or an unreachable remote and confirm failure is pre-pull).

- **Offline, no unpushed commits, remote unchanged (catch-up only):** Override `pal_is_online() { return 1; }`. Sentinel present, clean shutdown marker absent. A device save differs from the repo copy. Call `sb_run`. Verify: no push attempted, device version copied to repo working tree, commit made locally, sentinel updated, returns 0.

- **Online, unpushed commits exist:** Use a stub for `se_has_unpushed_commits` returning 0. Use a stub for `se_push` recording calls. Call `sb_run`. Verify `se_push` was called before `se_pull` (first push of the pre-pull step was recorded ahead of any pull logic). Verify returns 0.

- **Online, unpushed commits, push fails in pre-pull step:** Stub `se_has_unpushed_commits` returning 0. Stub `se_push` returning 1 for the first call (pre-pull push). Verify `sb_run` logs a warning but continues (does not return 1 at this point). Verify pull phase executes.

- **Remote has new saves since stored commit:** Bare remote has a new save committed after the stored commit. Call `sb_run`. Verify the new remote save is applied to the device. Verify stored commit updated. Verify sentinel updated. Verify returns 0.

- **Remote unchanged, device has local changes:** Store current HEAD as `last_known_commit`. Write different bytes to a device save (relative to the repo working tree copy). Call `sb_run`. Verify device version ends up in repo. Verify a commit is made. Verify sentinel updated. Returns 0.

- **Remote unchanged, device unchanged (no-op):** Store current HEAD. Device saves match repo copies exactly. Call `sb_run`. Verify no commit is made (git log HEAD is the same before and after). Verify sentinel updated. Returns 0.

- **Diverged remote:** Stub `se_pull` returning 1. Call `sb_run`. Verify returns 1. Verify catch-up scan does not execute (no device copies made, no commits).

- **Unknown system directory on device:** A device save is in an unrecognized directory. `pm_local_to_repo` returns 1 for it. Verify: warning logged, that file not copied, other valid device saves still processed, `sb_run` returns 0.

- **Catch-up scan includes repo-only save (not on device):** A repo file has no corresponding device file. Verify: `sb_run` does not remove it from the repo, does not error, returns 0. (The catch-up scan only iterates device saves — repo-only files are left alone.)

- **`se_commit` fails during catch-up commit:** Stub `se_commit` returning 1 when called. Set up a confirmed device change. Call `sb_run`. Verify returns 1. Verify sentinel NOT updated.

- **`sb_clear_shutdown_marker` called even when later steps fail:** Set up a diverged repo (stubbed `se_pull` returning 1). Call `sb_run`. Verify `clean_shutdown` file does not exist after the call (marker was cleared even though recovery failed).

### Integration Test (`tests/integration/test_stale_boot_flow.sh`)

Tests the full stale boot recovery pipeline end-to-end using the test PAL, a local bare git remote, and real implementations of all dependencies (sync engine, path mapper, cold start helpers, boot pull, change detector, runtime poll).

**Setup:**

1. Create `TEST_TMPDIR`. Source test PAL with `TEST_TMPDIR` set.
2. Copy `config/platform_maps/nextui.json` to `$TEST_TMPDIR/platform_map.json`.
3. Initialize a bare git repo at `$TEST_TMPDIR/remote` with an initial commit containing `snes/super_metroid.srm` and `gba/minish_cap.srm`.
4. Clone the bare remote to `$CONTINUITY_REPO_DIR` (`$TEST_TMPDIR/repo`).
5. Create the `.continuity/` directory structure. Write the current HEAD commit to `last_known_commit`. Create the sentinel file (`cs_create_sentinel`). Do NOT create `clean_shutdown` — simulating an unclean shutdown.
6. Create matching device saves at `$CONTINUITY_SAVES_ROOT` representing state at last poll.
7. Source all modules: `path_mapper.sh`, `sync_engine.sh`, `cold_start.sh`, `change_detector.sh`, `boot_pull.sh`, `runtime_poll.sh`, `stale_boot.sh`.
8. Call `pm_load_platform_map "$(pal_get_platform_map)"` and `se_init "$CONTINUITY_REPO_DIR" "test-device"`.

**Test 1 — Stale with only remote changes:**

Scenario: Device crashed after boot pull. Another device pushed a new save. Device has no local changes.

9. In a separate worktree (simulating another device), add `gb/links_awakening.srm` and update `snes/super_metroid.srm`. Commit and push to the bare remote.
10. Verify `sb_is_stale "$CONTINUITY_REPO_DIR"` returns 0 (sentinel present, no clean shutdown marker).
11. Call `sb_run "$CONTINUITY_REPO_DIR"`. Assert returns 0.
12. Assert `$CONTINUITY_SAVES_ROOT/<nextui-gb-dir>/links_awakening.srm` exists and matches the remote content.
13. Assert `$CONTINUITY_SAVES_ROOT/<nextui-snes-dir>/super_metroid.srm` matches the remote content.
14. Assert `$CONTINUITY_SAVES_ROOT/<nextui-gba-dir>/minish_cap.srm` is unchanged.
15. Assert stored commit equals current remote HEAD.
16. Assert sentinel mtime is recent (updated by `rp_update_sentinel`).
17. Assert `$CONTINUITY_REPO_DIR/.continuity/clean_shutdown` does not exist.
18. Assert `sb_is_stale "$CONTINUITY_REPO_DIR"` now returns 1 (sentinel present, no marker → still 0). Wait — the sentinel is present, marker is absent. `sb_is_stale` returns 0 still. This is expected and correct: the next boot will also run `sb_run` (since `sb_mark_clean_shutdown` is the daemon's job, not `sb_run`'s). Verify the test framework understands this: `sb_is_stale` will return 0 again. Confirm `sb_run` is idempotent (running it again with no changes produces no new commit).

**Test 2 — Stale with only local changes (device played after crash):**

19. Reset `TEST_TMPDIR` for a fresh run (or use a new test function with its own setup).
20. Set up: sentinel present, no clean shutdown marker, no remote changes since `last_known_commit`.
21. Write new bytes to `$CONTINUITY_SAVES_ROOT/<nextui-snes-dir>/super_metroid.srm` (simulating play after the last poll and before crash).
22. Call `sb_run "$CONTINUITY_REPO_DIR"`. Assert returns 0.
23. Assert `$CONTINUITY_REPO_DIR/snes/super_metroid.srm` now contains the new bytes.
24. Assert a new commit exists in git log mentioning `stale boot catch-up`.
25. Assert the remote bare repo was pushed to (contains new bytes for `snes/super_metroid.srm`).
26. Assert stored commit matches current HEAD.
27. Assert sentinel updated.

**Test 3 — Stale with both remote and local changes (different files):**

28. Set up: sentinel present, no clean shutdown marker.
29. In a separate worktree, add `gb/links_awakening.srm` to the remote. Commit and push.
30. Write new bytes to `$CONTINUITY_SAVES_ROOT/<nextui-gba-dir>/minish_cap.srm` on the device (different save, no conflict).
31. Call `sb_run "$CONTINUITY_REPO_DIR"`. Assert returns 0.
32. Assert `links_awakening.srm` arrived on device (inbound pull).
33. Assert `$CONTINUITY_REPO_DIR/gba/minish_cap.srm` now has the device bytes (catch-up outbound).
34. Assert a commit was made containing the catch-up changes.
35. Assert sentinel updated, stored commit reflects final HEAD.

**Test 4 — Clean boot (marker present) — sb_run not called:**

36. Create `$CONTINUITY_REPO_DIR/.continuity/clean_shutdown` via `sb_mark_clean_shutdown`.
37. Assert `sb_is_stale "$CONTINUITY_REPO_DIR"` returns 1 (clean — do not run stale boot).
38. This test verifies the detection contract; `sb_run` is not called.

**Test 5 — Offline, local changes only:**

39. Override `pal_is_online() { return 1; }`.
40. Write new bytes to a device save.
41. Call `sb_run "$CONTINUITY_REPO_DIR"`. Assert returns 0.
42. Assert commit made locally.
43. Assert remote is NOT updated (push was skipped).
44. Assert sentinel updated.
45. Restore `pal_is_online` to the test PAL default (returns 0).

**Teardown:**

46. `rm -rf "$TEST_TMPDIR"`. Assert directory gone.

---

## Definition of Done

- [ ] `src/core/stale_boot.sh` implemented with `sb_run`, `sb_is_stale`, `sb_mark_clean_shutdown`, `sb_clear_shutdown_marker`.
- [ ] `sb_run` flow matches the spec exactly, including all error, offline, and no-op branches.
- [ ] Clean shutdown marker is removed as the first action of `sb_run`, before any network or git operations.
- [ ] Step 2 (push pending commits before pull) executes only when online AND unpushed commits exist; push failure in this step is non-fatal.
- [ ] Inbound pull phase reuses `bp_get_remote_changes` and `bp_apply_remote_saves` from Sprint 0.5.
- [ ] Catch-up scan uses `cd_list_device_saves` (not `find -newer`) to scan all device saves.
- [ ] Catch-up scan uses `cmp -s` for file comparison; no mtime dependency.
- [ ] No `.local` files created during catch-up scan — device version wins without a conflict artifact.
- [ ] Sentinel updated via `rp_update_sentinel` as the final step of a successful `sb_run`.
- [ ] `last_known_commit` updated via `cs_store_commit` after every commit made during recovery.
- [ ] `tests/unit/core/test_stale_boot.sh` implemented and all unit tests pass under `busybox ash`.
- [ ] `tests/integration/test_stale_boot_flow.sh` implemented and passes under `busybox ash`.
- [ ] `shellcheck` passes with no errors on `stale_boot.sh` and both test files.
- [ ] `busybox ash -n` syntax check passes on `stale_boot.sh` and both test files.
- [ ] No banned BusyBox ash constructs (see CLAUDE.md) in `stale_boot.sh`.
- [ ] All four public functions in `stale_boot.sh` have a usage comment.
- [ ] `stale_boot.sh` file header comment lists all prerequisites (PAL loaded, modules sourced) and public functions.
- [ ] Sprint summary written to `docs/sprints/sprint-0.7-summary.md`.

---

## Resolved Questions

1. **Should `sb_run` return 2 when offline and pull was skipped?** **Resolved — return 0.** Recovery ran meaningfully: catch-up scan completed, local commits queued, sentinel updated. The device is in a valid state for runtime polling. Returning 2 would signal "network error" to the dispatcher and risk skipping the runtime poll loop.

2. **`sb_is_stale` when sentinel is absent and clean shutdown marker is present.** **Resolved — return 1 (not stale), correct as written.** The dispatcher checks `cs_is_cold_start` first, which catches this case (no sentinel → cold start needed). The marker is harmless and will be consumed by `sb_run` after cold start eventually creates the sentinel.

3. **Should `clean_shutdown` be in `.gitignore`?** **Resolved — yes, added to Sprint 0.3.** `clean_shutdown` has been added to the `.continuity/.gitignore` list in Sprint 0.3's spec (alongside `credentials`, `device_name`, `sentinel`, `last_known_commit`). Belt and suspenders — `cd_detect_changes` filters to `.srm` only, but explicit gitignore prevents any edge case.

4. **`sb_is_stale` after successful `sb_run` / idempotency.** **Resolved — correct by design.** After `sb_run`, the clean shutdown marker remains absent (only the daemon's SIGTERM handler writes it). So `sb_is_stale` returns 0 on next boot — this is correct and safe. Each recovery run is idempotent: running `sb_run` again with no changes produces no new commits. The integration test validates this by calling `sb_run` twice.

5. **Catch-up scan and repo-only files.** **Resolved — leave repo-only files untouched.** The catch-up scan iterates device saves only (outbound). Repo-only files were pushed by another device and must remain. Deleting them would destroy another device's save. They'll be applied to the local device on the next boot pull.
