# Sprint 0.5 — Boot Pull

**Status:** Approved
**Date:** 2026-03-13
**Dependencies:** Sprint 0.4 (cold start — sentinel file and stored commit hash must be established before boot pull runs)

---

## Goal

Implement the boot pull sync phase that runs on a normal boot: an existing sentinel file and stored commit hash are present, meaning cold start has already run at least once. Boot pull fetches remote changes since the last known commit, applies only the changed `.srm` files to the device, updates the stored commit hash to the new HEAD, and touches the sentinel so the runtime poll has a clean baseline.

This is the steady-state sync entry point for every subsequent boot after initial enrollment. It is inbound-only: it does not detect or push local changes. That is the runtime poll's job (Sprint 0.6) and stale boot recovery's job (Sprint 0.7).

---

## Reference Specs

- `docs/design/pal.md` — PAL variables and functions used by all core modules; required variable names; logging pattern
- `docs/roadmap.md` — Sprint 0.5 scope and acceptance criteria

---

## Scope

### `src/core/boot_pull.sh`

Platform-agnostic boot pull logic. Assumes the PAL has been sourced, validated, and initialized before any `bp_*` function is called. Assumes `cold_start.sh`, `sync_engine.sh`, and `path_mapper.sh` have already been sourced (Sprint 0.3 and 0.4 outputs).

---

#### Functions

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `bp_run` | `(repo_dir)` | 0 success/no-op, 1 unrecoverable error, 2 network error | Full boot pull flow. Reads stored commit, pulls remote, diffs old..new, applies changed saves, updates stored commit, touches sentinel. See flow detail below. |
| `bp_get_remote_changes` | `(repo_dir, old_commit)` | prints newline-delimited repo-relative paths to stdout; 0 on success, 1 on failure | Run `git diff --name-only <old_commit>..HEAD` in `repo_dir`. Filter output to `.srm` files only. Print each matching path on its own line. Returns 1 if the git command fails. Note: `git diff --name-only` may include files that were deleted on the remote. These will appear in the diff output but will not exist in the working tree after the pull. `bp_apply_remote_saves` must handle this case — if the repo file does not exist after pull (deleted on remote), skip copying and optionally remove the corresponding device file. |
| `bp_apply_remote_saves` | `(repo_dir, changed_files)` | 0 on success, 1 on first copy failure | For each repo-relative path in the newline-delimited `changed_files` string: resolve to an absolute local device path via `pm_repo_to_local`, create the target directory if needed (`mkdir -p`), copy the file from the repo working tree to the device save dir. Log each copy via `pal_log`. Returns 0 if all copies succeed. Returns 1 immediately on the first copy failure, after logging the error. If the repo file at `$repo_dir/$repo_path` does not exist (deleted on remote), skip the copy. Optionally log an info message. Do not treat a missing repo file as an error. |

---

#### `bp_run` Flow

```
bp_run(repo_dir):
  1. old_commit=$(cs_read_commit "$repo_dir")
     — If cs_read_commit returns empty or fails:
         pal_log "warn" "No stored commit found — cold start may not have run"
         return 1

  2. se_pull "$repo_dir"
     — If se_pull returns 2 (network error):
         pal_log "warn" "Boot pull skipped — network unavailable"
         return 2
     — If se_pull returns 1 (diverged — conflict):
         pal_log "warn" "Boot pull deferred — diverged history, conflict handler required"
         return 1
         (Sprint 0.8 will replace this with a call to the conflict handler)

  3. new_commit=$(se_get_head_commit "$repo_dir")

  4. If old_commit == new_commit:
         pal_log "info" "Boot pull: no remote changes since last sync"
         touch "$repo_dir/.continuity/sentinel"
         return 0

  5. changed_files=$(bp_get_remote_changes "$repo_dir" "$old_commit")
     — If bp_get_remote_changes returns 1:
         pal_log "error" "Boot pull: failed to determine changed files"
         return 1

  6. If changed_files is empty (pull happened but no .srm files changed):
         pal_log "info" "Boot pull: remote changes contain no .srm files"
         cs_store_commit "$repo_dir" "$new_commit"
         touch "$repo_dir/.continuity/sentinel"
         return 0

  7. bp_apply_remote_saves "$repo_dir" "$changed_files"
     — If bp_apply_remote_saves returns 1:
         pal_log "error" "Boot pull: failed to apply one or more saves"
         return 1

  8. cs_store_commit "$repo_dir" "$new_commit"

  9. touch "$repo_dir/.continuity/sentinel"

  10. pal_log "info" "Boot pull complete"
      return 0
```

---

#### Implementation Notes

**BusyBox ash compatibility:**

- No arrays. `changed_files` is a newline-delimited string. Iterate using a `while read` loop fed via a temp file or pipe, not `for item in $list` (word-splits on spaces in filenames).
- Separate local variable declarations from assignments: `local var; var=$(cmd)`, never `local var=$(cmd)`.
- Use `[ ... ]` not `[[ ... ]]` throughout.
- All variable expansions quoted.
- `printf` over `echo`.

**Iterating the changed files list (BusyBox ash safe pattern):**

```sh
printf '%s\n' "$changed_files" | while IFS= read -r repo_path; do
    # process $repo_path
done
```

Note: assignments inside a `while read` loop piped from a subshell are not visible to the parent shell in POSIX sh (no `lastpipe`). If `bp_apply_remote_saves` needs to track failures across iterations, it must write failure state to a temp file and read it after the loop, rather than setting a variable inside the loop.

**`bp_get_remote_changes` filtering:**

The git diff output may include non-`.srm` files (e.g. `.continuity/devices/<name>.json` from a new device enrollment on another device). Only `.srm` lines should be returned. Use `grep '\.srm$'` on the diff output. If no `.srm` files match, print nothing and return 0 (empty output is not an error).

**New systems / missing dirs:**

`bp_apply_remote_saves` must use `mkdir -p` on the target directory before each `cp`. A remote device may have saves for a system the local device has never seen. This is not an error — create the directory and copy the file.

**Sentinel path:**

The sentinel file lives at `$repo_dir/.continuity/sentinel`. This is the same sentinel created by cold start (Sprint 0.4). Boot pull touches it (updates its mtime) so the runtime poll's `find -newer sentinel` has a fresh baseline immediately after boot pull completes.

**Stored commit functions:**

`cs_read_commit(repo_dir)` and `cs_store_commit(repo_dir, commit_hash)` are defined in `src/core/cold_start.sh` (Sprint 0.4). `boot_pull.sh` does not re-implement them — it calls them directly, passing `$repo_dir` as the first argument. They read from and write to `$repo_dir/.continuity/last_known_commit`.

**All git invocations:**

Use `$CONTINUITY_GIT_BIN` — never the literal string `git`. Specify the repo explicitly using `-C "$repo_dir"`.

**Module-level state:**

`boot_pull.sh` holds no persistent module-level state. All inputs come from parameters, PAL variables, or outputs of prior sprint functions. There is no `bp_init` function.

**File header comment:**

`boot_pull.sh` must include a brief usage comment block at the top explaining: prerequisites (PAL loaded, `cold_start.sh` sourced, `sync_engine.sh` sourced, `path_mapper.sh` loaded with platform map), and which functions are public.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Detecting and pushing local save changes on boot | 0.7 (stale boot recovery) |
| Resolving diverged history (git merge conflicts) | 0.8 (conflict handler) |
| Runtime change detection and push during play | 0.6 (runtime poll) |
| Stale boot recovery (sentinel present, unclean shutdown) | 0.7 |
| Determining whether to run cold start vs boot pull vs stale boot | 1.1 (NextUI daemon) |
| `.local` file handling for conflicts | 0.8 |
| `se_pull` implementation | 0.3 (sync engine, Sprint 0.3 output) |
| `pm_repo_to_local` implementation | 0.2 (path mapper, Sprint 0.2 output) |
| `cs_read_commit` / `cs_store_commit` implementation | 0.4 (cold start, Sprint 0.4 output) |
| NextUI daemon integration (boot hook, dispatch logic) | 1.1 |
| Onion OS, RetroDeck, Android clients | 2.1, 3.1, 3.2 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/boot_pull.sh` | Boot pull sync: `bp_run`, `bp_get_remote_changes`, `bp_apply_remote_saves` |
| `tests/unit/core/test_boot_pull.sh` | Unit tests for all three `bp_*` functions |
| `tests/integration/test_boot_pull_flow.sh` | End-to-end boot pull integration test using test PAL and local bare remote |

### Files Modified

| File | Change |
|------|--------|
| `docs/roadmap.md` | Update Sprint 0.5 status to Complete after implementation |

### Directories Created (if not already present)

None. All target directories already exist per prior sprint structure.

---

## Acceptance Criteria

### `bp_get_remote_changes`

1. Given two commits where `.srm` files changed, `bp_get_remote_changes` prints each changed `.srm` path on its own line and returns 0.
2. Given two commits where only non-`.srm` files changed (e.g. a device JSON registration), `bp_get_remote_changes` prints nothing and returns 0.
3. Given two commits where both `.srm` and non-`.srm` files changed, `bp_get_remote_changes` prints only the `.srm` paths.
4. Given a commit hash that does not exist in the repo, `bp_get_remote_changes` returns 1.
5. Output paths are repo-relative (e.g. `snes/super_metroid.srm`), not absolute.

### `bp_apply_remote_saves`

6. For each path in `changed_files`, `bp_apply_remote_saves` calls `pm_repo_to_local` and copies the file from the repo working tree to the resolved device path.
7. The device save file after copy has identical byte content to the repo file (verified with `cmp -s`).
8. If the target device directory does not exist, `bp_apply_remote_saves` creates it with `mkdir -p` before copying.
9. If `pm_repo_to_local` returns 1 for a path (unrecognized system), `bp_apply_remote_saves` logs a warning via `pal_log` and continues to the next file (does not abort the entire apply). The function returns 1 after processing all files if any file failed.
10. If the `cp` command fails for a path, `bp_apply_remote_saves` logs an error via `pal_log` and returns 1.
11. `bp_apply_remote_saves` with an empty `changed_files` string performs no operations and returns 0.

### `bp_run` — Happy Path

12. When remote has new saves since the stored commit, `bp_run` copies all changed `.srm` files to their correct device paths and returns 0.
13. After a successful `bp_run`, the stored commit hash equals the new HEAD commit of the repo.
14. After a successful `bp_run`, the sentinel file mtime is newer than it was before `bp_run` was called.
15. When `old_commit == new_commit` (no remote changes), `bp_run` returns 0 without copying any files, but still touches the sentinel.
16. When `old_commit == new_commit`, the stored commit hash is unchanged after `bp_run`.
17. When the remote pull produces no `.srm` file changes (only metadata changes), `bp_run` still updates the stored commit hash and touches the sentinel, then returns 0.

### `bp_run` — Error and Offline Paths

18. When `cs_read_commit` returns an empty string, `bp_run` logs a warning and returns 1. It does not call `se_pull`.
19. When `se_pull` returns 2 (network error), `bp_run` logs a warning, leaves the stored commit hash unchanged, does not touch the sentinel, and returns 2.
20. When `se_pull` returns 1 (diverged), `bp_run` logs a warning, leaves the stored commit hash unchanged, does not touch the sentinel, and returns 1.
21. When `bp_apply_remote_saves` returns 1, `bp_run` returns 1 and does not update the stored commit hash.

### Cross-Cutting

22. `boot_pull.sh` passes `shellcheck` with no errors.
23. `boot_pull.sh` passes `busybox ash -n` syntax check.
24. No banned BusyBox ash constructs are used (see CLAUDE.md).
25. All git commands in `boot_pull.sh` use `$CONTINUITY_GIT_BIN`, not the literal string `git`.
26. All git commands specify the repo via `-C "$repo_dir"`, not by assuming the current working directory.
27. All variable expansions in `boot_pull.sh` are quoted.
28. All three public functions have a usage comment at their definition.
29. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_boot_pull.sh`)

All unit tests are self-contained. Each test creates a fresh temp directory, sets up the minimum required state (a real local git repo, a test PAL environment, a mock or real platform map), runs assertions, and removes the temp directory on EXIT via `trap`.

The test file sources: `tests/fixtures/pal_test.sh`, `src/core/path_mapper.sh`, `src/core/sync_engine.sh`, `src/core/cold_start.sh`, `src/core/boot_pull.sh`.

Because Sprint 0.4 (cold_start.sh) may not exist when this sprint is implemented in isolation, the test file must be resilient: if `cold_start.sh` does not exist, it provides stub implementations of `cs_read_commit` and `cs_store_commit` directly in the test file for isolation purposes. When Sprint 0.4 is delivered, the stubs are replaced by the real sourced file.

**`bp_get_remote_changes` tests:**

- Set up a local bare remote and a working clone. Make two commits in the remote: first with a `.srm` file, second with another `.srm` file and a device JSON file. Pull to get both commits in the working clone. Call `bp_get_remote_changes` with the first commit hash. Assert: output contains exactly the two `.srm` paths, does not contain the device JSON path, returns 0.
- Make a commit with only a device JSON file (no `.srm` files). Call `bp_get_remote_changes` between the commit before and after. Assert: output is empty, returns 0.
- Call `bp_get_remote_changes` with a nonexistent SHA (`deadbeef00000000000000000000000000000000`). Assert returns 1.

**`bp_apply_remote_saves` tests:**

- Set up a repo with a committed `snes/super_metroid.srm`. Set up a device saves directory via the test PAL. Load the NextUI platform map. Call `bp_apply_remote_saves` with `"snes/super_metroid.srm"`. Assert the file exists at the device path, content matches the repo file (`cmp -s`), returns 0.
- Set up a repo with `gb/links_awakening.srm` where the device save dir `gb/` equivalent does not exist yet. Call `bp_apply_remote_saves`. Assert the directory was created and the file was copied.
- Pass an empty string to `bp_apply_remote_saves`. Assert returns 0 and no files are created.
- Pass a repo-relative path for an unrecognized system (e.g. `fakesys/game.srm`). Assert returns 1, no crash.
- Pass a valid path but make the `cp` fail (e.g. destination is read-only via `chmod 000` on the directory). Assert returns 1, error logged.

**`bp_run` tests:**

- Full happy path: bare remote with one commit (old), add a new `.srm` commit to remote. Store old commit as `last_known_commit`. Call `bp_run`. Assert: new save exists on device, stored commit updated to new HEAD, sentinel mtime updated, returns 0.
- No-op path: store current HEAD as `last_known_commit`. Call `bp_run`. Assert: no new files on device, stored commit unchanged, sentinel mtime updated, returns 0.
- Non-SRM remote change: add a device JSON file commit to the remote. Store old commit. Call `bp_run`. Assert: no `.srm` files copied, stored commit updated to new HEAD, sentinel touched, returns 0.
- Missing stored commit: empty `last_known_commit` file. Call `bp_run`. Assert: returns 1, `se_pull` not called (verify by confirming the remote's HEAD is not fetched — use a network-unreachable remote and confirm the function returns 1 before hitting the network, or use a `se_pull` stub).
- Network error: override `se_pull` to return 2. Call `bp_run`. Assert: returns 2, stored commit unchanged, sentinel not touched.
- Diverged: override `se_pull` to return 1. Call `bp_run`. Assert: returns 1, stored commit unchanged, sentinel not touched.
- Apply failure: override `bp_apply_remote_saves` to return 1. After a real pull with new commits. Assert `bp_run` returns 1, stored commit not updated.

### Integration Test (`tests/integration/test_boot_pull_flow.sh`)

Tests the full boot pull pipeline end-to-end using the test PAL, a local bare git remote, and the real implementations of all dependencies (sync engine, path mapper, cold start helpers).

**Setup:**

1. Create `TEST_TMPDIR`. Source test PAL with `TEST_TMPDIR` set.
2. Copy `config/platform_maps/nextui.json` to `$TEST_TMPDIR/platform_map.json`.
3. Initialize a bare git repo at `$TEST_TMPDIR/remote` with an initial commit containing `snes/super_metroid.srm` and `gba/minish_cap.srm`.
4. Clone the bare remote to `$CONTINUITY_REPO_DIR` (`$TEST_TMPDIR/repo`).
5. Create the `.continuity/` directory structure in the clone. Write the current HEAD commit to `last_known_commit`. Create the sentinel file.
6. Create matching device saves at `$CONTINUITY_SAVES_ROOT` to represent the state after cold start.
7. Source `path_mapper.sh`, call `pm_load_platform_map "$(pal_get_platform_map)"`.
8. Source `sync_engine.sh`, call `se_init "$CONTINUITY_REPO_DIR" "test-device"`.
9. Source `cold_start.sh` (or stubs). Source `boot_pull.sh`.

**Test 1 — Changes from another device arrive:**

10. In a separate worktree (simulating another device), add a new save `gb/links_awakening.srm` and update `snes/super_metroid.srm` with different content. Commit and push to the bare remote.
11. Call `bp_run "$CONTINUITY_REPO_DIR"`. Assert returns 0.
12. Assert `$CONTINUITY_SAVES_ROOT/<nextui-gb-dir>/links_awakening.srm` exists and matches the remote content.
13. Assert `$CONTINUITY_SAVES_ROOT/<nextui-snes-dir>/super_metroid.srm` matches the new remote content.
14. Assert `$CONTINUITY_SAVES_ROOT/<nextui-gba-dir>/minish_cap.srm` is unchanged (not in the diff).
15. Assert stored commit equals new HEAD.
16. Assert sentinel mtime is recent (within the last few seconds).

**Test 2 — No remote changes:**

17. Record current sentinel mtime. Record stored commit. Call `bp_run "$CONTINUITY_REPO_DIR"`. Assert returns 0.
18. Assert stored commit is unchanged. Assert sentinel mtime is updated (re-touched).

**Test 3 — Offline:**

19. Override `pal_is_online` to return 1. Override `se_pull` to return 2. Call `bp_run`. Assert returns 2. Assert stored commit is unchanged. Assert sentinel is not touched.

**Teardown:**

20. `rm -rf "$TEST_TMPDIR"`. Assert directory gone.

---

## Definition of Done

- [ ] `src/core/boot_pull.sh` implemented with `bp_run`, `bp_get_remote_changes`, and `bp_apply_remote_saves`.
- [ ] `bp_run` flow matches the spec exactly, including all error and offline branches.
- [ ] `tests/unit/core/test_boot_pull.sh` implemented and all unit tests pass under `busybox ash`.
- [ ] `tests/integration/test_boot_pull_flow.sh` implemented and passes under `busybox ash`.
- [ ] `shellcheck` passes with no errors on `boot_pull.sh` and both test files.
- [ ] `busybox ash -n` syntax check passes on `boot_pull.sh` and both test files.
- [ ] No banned BusyBox ash constructs (see CLAUDE.md) in `boot_pull.sh`.
- [ ] All public functions in `boot_pull.sh` have a usage comment.
- [ ] `boot_pull.sh` file header comment lists all prerequisites (PAL loaded, modules sourced).
- [ ] Sprint summary written to `docs/sprints/sprint-0.5-summary.md`.

---

## Resolved Questions

1. **Dependency on Sprint 0.4 (`cold_start.sh`):** **Resolved — stubs in test files are acceptable.** Coding agents may provide stub implementations of `cs_read_commit` and `cs_store_commit` in test files only when Sprint 0.4 has not yet been implemented. `boot_pull.sh` itself must always call the real `cs_*` functions without fallback stubs. When Sprint 0.4 is delivered, the stubs are replaced by the real sourced file.

2. **Sentinel touch on network error:** **Resolved — do NOT touch sentinel on network error.** The spec is correct as written. The sentinel represents "last time we confirmed a clean state with the remote." If we couldn't confirm (offline), we shouldn't advance the marker. The old baseline remains valid; `find -newer` may return the same candidates, but `cmp -s` filters false positives harmlessly.

3. **`bp_apply_remote_saves` partial failure behavior:** **Resolved — immediate abort on `cp` failure.** A `cp` failure indicates a serious underlying issue (disk full, permissions, hardware error). Continuing is unlikely to succeed and produces a harder-to-reason-about partial state. Immediate abort with a clear error lets the user address the root cause. On next boot, boot pull re-runs from the same stored commit and retries everything. `pm_repo_to_local` failures (unrecognized system) continue processing remaining files, since that's a data issue not a system issue.
