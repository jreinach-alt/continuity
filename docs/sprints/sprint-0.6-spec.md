# Sprint 0.6 — Runtime Poll

**Status:** Approved
**Date:** 2026-03-13
**Dependencies:** Sprint 0.5 (boot pull — complete; sentinel exists at `$repo_dir/.continuity/sentinel`, `last_known_commit` exists, repo is in steady-state post-boot)

---

## Goal

Implement the runtime poll cycle — the mechanism by which Continuity detects save file changes during active play and syncs them to the user's private repo. Each poll cycle does one pass: find candidate changed files using `find -newer` against the sentinel, confirm genuine changes via `cmp -s` byte comparison against the repo working tree copy, copy confirmed changes into the repo, stage and commit them, push if online, and update the sentinel. This sprint delivers one callable cycle function. The enclosing daemon loop (calling this cycle on a 30-second interval) is Sprint 1.1.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface: `CONTINUITY_SAVES_ROOT`, `CONTINUITY_REPO_DIR`, `CONTINUITY_GIT_BIN`, `pal_is_online()`, `pal_log()`
- `docs/roadmap.md` — Sprint 0.6 scope, acceptance criteria, and relationship to Sprint 1.1 (daemon loop)
- `src/core/pal.sh` — PAL validator (Sprint 0.2 output, assumed present)
- `src/core/path_mapper.sh` — `pm_local_to_repo()`, `pm_list_watched_dirs()` (Sprint 0.2 output, assumed present)
- `src/core/sync_engine.sh` — `se_stage_files(repo_dir, file_list)`, `se_commit(repo_dir, file_list)`, `se_push(repo_dir)`, `se_has_unpushed_commits(repo_dir)` (Sprint 0.3 output, assumed present)
- `src/core/change_detector.sh` — `cd_detect_changes()` (Sprint 0.4 output, assumed present)
- `src/core/cold_start.sh` — `cs_store_commit()` (Sprint 0.4 output, assumed present)

---

## Scope

### Runtime Poll Module (`src/core/runtime_poll.sh`)

Single-file module implementing one complete poll cycle. Designed to be called repeatedly by a daemon loop. Has no internal state between calls — all state is on the filesystem (sentinel mtime, repo working tree). Depends on: PAL variables and functions (loaded by caller), path mapper (loaded by caller), sync engine (loaded by caller), change detector (loaded by caller), cold start helpers for commit tracking (loaded by caller).

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `rp_run` | `(repo_dir)` | 0 nothing to do or sync succeeded, 1 error | Execute one complete poll cycle. Orchestrates all other `rp_*` functions. Full flow described below. |
| `rp_find_candidates` | `(repo_dir)` | prints absolute device paths to stdout, one per line; returns 0 | Use `find -newer` against the sentinel file to enumerate all `.srm` files under `$CONTINUITY_SAVES_ROOT` whose mtime is newer than the sentinel. Prints nothing and returns 0 when no candidates are found. |
| `rp_confirm_changes` | `(repo_dir, candidates)` | prints confirmed-changed absolute device paths to stdout, one per line; returns 0 | For each candidate device path (from the newline-delimited `candidates` argument), derive the repo path via `pm_local_to_repo`, then run `cmp -s` against the repo working tree copy. Print only the device paths where `cmp -s` reports a difference (exit code 1). Returns 0 always — the count of confirmed changes is determined by the caller from the output. |
| `rp_update_sentinel` | `(repo_dir)` | 0 on success, 1 on error | `touch "$repo_dir/.continuity/sentinel"` to set its mtime to the current time. This becomes the new baseline for the next `find -newer` scan. |

**`rp_run` flow — single poll cycle:**

```
rp_run(repo_dir):

  1. sentinel="$repo_dir/.continuity/sentinel"
     If sentinel does not exist:
       pal_log "error" "Sentinel missing — cold start not complete?"
       return 1

  2. candidates=$(rp_find_candidates "$repo_dir")
     If candidates is empty (no output):
       return 0    # Nothing newer than sentinel — nothing to do

  3. changed=$(rp_confirm_changes "$repo_dir" "$candidates")
     If changed is empty (all candidates were false positives):
       rp_update_sentinel "$repo_dir"
       return 0    # FAT32 false positives only — sentinel advanced

  4. For each device path in changed (while IFS= read -r device_path):
       a. repo_path=$(pm_local_to_repo "$device_path")
          If pm_local_to_repo returns 1:
            pal_log "warn" "Unknown system dir, skipping: $device_path"
            continue
       b. repo_file="$repo_dir/$repo_path"
          mkdir -p "$(dirname "$repo_file")"
          cp "$device_path" "$repo_file"
          pal_log "info" "Poll: copied $device_path -> $repo_path"

  5. changed_in_repo=$(cd_detect_changes "$repo_dir")
     If changed_in_repo is empty:
       # All cp operations resulted in files git considers unchanged
       # (edge case: cmp said different, git says not — e.g. content reverted)
       pal_log "info" "Poll: no git changes after copy — skipping commit"
       rp_update_sentinel "$repo_dir"
       return 0

  6. se_stage_files "$repo_dir" "$changed_in_repo"
     se_commit "$repo_dir" "$changed_in_repo"
       — On failure: pal_log "error", return 1

  7. If pal_is_online:
       se_push "$repo_dir"
         — If se_push returns 1 (persistent failure): pal_log "error", return 1
         — If se_push returns 2 (deferred/offline): should not occur here since
           pal_is_online returned 0, but treat as non-fatal: log warn, continue
     Else:
       pal_log "info" "Poll: offline — commit queued locally"

  8. head_hash=$(se_get_head_commit "$repo_dir")
     cs_store_commit "$repo_dir" "$head_hash"
       — On failure: pal_log "error", return 1

  9. rp_update_sentinel "$repo_dir"
       — On failure: pal_log "error", return 1

 10. pal_log "info" "Poll: sync complete"
     return 0
```

**`rp_find_candidates` implementation notes:**

- The sentinel path is `$repo_dir/.continuity/sentinel`.
- Command: `find "$CONTINUITY_SAVES_ROOT" -name "*.srm" -newer "$sentinel"`.
- Output is absolute device paths, one per line.
- If `$CONTINUITY_SAVES_ROOT` does not exist, `find` will error. Suppress with `2>/dev/null` and return 0 (empty output is valid — nothing to sync).
- Do NOT use `-newer` with a timestamp string. Use the sentinel file itself as the reference (POSIX `find -newer reffile`). This avoids any timestamp parsing and is correct on BusyBox.
- BusyBox `find` supports `-newer reffile` and `-name pattern`. Do not use `-newer` combined with other time predicates.

**`rp_confirm_changes` implementation notes:**

- `candidates` is a newline-delimited string of absolute device paths (same format as `rp_find_candidates` output).
- For each candidate: derive `repo_path` with `pm_local_to_repo "$device_path"`. If `pm_local_to_repo` returns 1, log a warning and skip — do not print this candidate (it is neither confirmed nor denied; it is unroutable).
- `repo_file="$repo_dir/$repo_path"`. If `repo_file` does not exist, `cmp -s` will fail — treat a missing repo copy as a confirmed change (print the device path). A new file with no repo baseline is definitely changed from the repo's perspective.
- Run `cmp -s "$device_path" "$repo_file"`. If exit code is non-zero (files differ OR one doesn't exist): print `$device_path`.
- If exit code is 0 (files identical): do not print (false positive, filtering it out).
- The function always returns 0 — the caller determines results from output, not return code.
- BusyBox ash: iterate using `while IFS= read -r device_path; do ... done` fed from `printf '%s\n' "$candidates"`.

**`rp_update_sentinel` implementation notes:**

- Command: `touch "$repo_dir/.continuity/sentinel"`.
- This is the only write to the sentinel in the runtime poll module. `rp_update_sentinel` is called in all exit paths where a scan was performed (step 3 false-positive exit, step 5 no-git-changes exit, and step 9 success exit). It is NOT called if no candidates were found (step 2 early return) — the sentinel should not advance when no scan work was done.
- If `touch` fails (e.g. filesystem full), return 1. The caller (`rp_run`) logs and returns 1.

**`rp_run` step 6 — `se_commit` argument:**

The `se_commit` function (Sprint 0.3) takes `(repo_dir, file_list)` as its first two arguments. Pass `"$repo_dir"` and `"$changed_in_repo"` (the output of `cd_detect_changes`, which is repo-relative paths). The commit message subject is generated by `se_commit` from the file list (1 file → `<system>/<file> updated`; multiple → `N saves updated`). The device name and timestamp trailers are added automatically.

**`rp_run` step 7 — `se_push` return value convention (Sprint 0.3):**

`se_push` returns:
- `0` — push succeeded
- `1` — persistent failure after all retries
- `2` — deferred (offline at time of call)

Since `rp_run` calls `se_push` only when `pal_is_online` already returned 0 (online), a return value of `2` from `se_push` is unexpected but not fatal — log a warning and do not return 1. Only `se_push` returning `1` (persistent failure) causes `rp_run` to return 1.

**Idempotency:**

If `rp_run` is called twice with no intervening save file changes, the second call returns 0 immediately at step 2 (no candidates newer than the sentinel that was just updated by the first call). No new commits are created.

**BusyBox ash compatibility:**

- No arrays. Newline-delimited strings for all lists.
- `while IFS= read -r line; do ... done` for iteration.
- `local var; var=$(cmd)` — no `local var=$(cmd)`.
- No `[[`, no `${var//pat/rep}`, no process substitution.
- `command -v` for optional function checks.
- All variable expansions quoted.

**Dependency sourcing:**

`runtime_poll.sh` does not source its dependencies. The entry point (daemon or test harness) sources all modules before calling `rp_run`. If `rp_run` is called and `cd_detect_changes` or `cs_store_commit` is not defined, it will fail at the call site with a meaningful error from the shell. The module header comment must list all required functions from other modules.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Daemon loop (sleep 30, call rp_run repeatedly) | 1.1 |
| Boot dispatch logic (cold start vs boot pull vs stale boot) | 1.1 |
| Stale boot recovery (unclean shutdown catch-up scan) | 0.7 |
| Conflict handler (git merge conflict on push) | 0.8 |
| inotifywait-based event-driven change detection (RetroDeck) | 2.2 |
| Syncing non-`.srm` files | never |
| FAT32 mtime granularity workaround beyond `cmp -s` filtering | not needed |
| Updating `last_sync` / `last_push` timestamps in device JSON | 1.1 |
| Calling `pal_on_sync_complete` hook | 1.1 |
| Boot pull (pulling remote changes on startup) | 0.5 |
| Cold start detection and flow | 0.4 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/runtime_poll.sh` | Runtime poll cycle: `rp_run`, `rp_find_candidates`, `rp_confirm_changes`, `rp_update_sentinel` |
| `tests/unit/core/test_runtime_poll.sh` | Unit tests for all four `rp_*` functions |
| `tests/integration/test_runtime_poll_flow.sh` | Integration test: full poll cycle with real git operations |

### Files Modified

None. All prior sprint outputs (`src/core/pal.sh`, `src/core/path_mapper.sh`, `src/core/sync_engine.sh`, `src/core/change_detector.sh`, `src/core/cold_start.sh`, `tests/fixtures/pal_test.sh`, `tests/fixtures/enroll_test.sh`) are used as-is.

---

## Acceptance Criteria

### `rp_find_candidates`

1. Returns all `.srm` files under `$CONTINUITY_SAVES_ROOT` whose mtime is newer than the sentinel, one absolute path per line.
2. Returns 0 and produces no output when no `.srm` files are newer than the sentinel.
3. Returns 0 and produces no output when `$CONTINUITY_SAVES_ROOT` does not exist (find error suppressed).
4. Does not return files with extensions other than `.srm`.
5. Does not return the sentinel file itself.

### `rp_confirm_changes`

6. Returns only device paths where the device file and the repo working tree copy differ (as determined by `cmp -s`).
7. Treats a candidate with no corresponding repo copy as a confirmed change (new file — prints it).
8. Does not print candidates where `cmp -s` returns 0 (files are byte-for-byte identical).
9. Skips and logs a warning for any candidate whose system directory is not recognized by `pm_local_to_repo` (does not print it as confirmed).
10. Returns 0 regardless of how many or how few candidates are confirmed.
11. Returns 0 and produces no output when `candidates` is an empty string.

### `rp_update_sentinel`

12. Sets the mtime of `$repo_dir/.continuity/sentinel` to the current time after a call.
13. Returns 0 on success.
14. Returns 1 if `touch` fails (e.g. read-only filesystem — simulate by making the `.continuity/` directory read-only in a test).

### `rp_run` — core behavior

15. Returns 0 immediately (without touching sentinel) when `rp_find_candidates` returns no candidates.
16. Updates sentinel and returns 0 when candidates exist but all are false positives (confirmed by `cmp -s` as identical).
17. Copies changed `.srm` files into the repo working tree for each confirmed change.
18. Calls `cd_detect_changes` after copying to get the list of files git considers actually changed.
19. Skips commit and advances the sentinel when `cd_detect_changes` returns nothing after the copy step (edge case: cmp differed but git does not).
20. Stages and commits all files returned by `cd_detect_changes`.
21. Pushes when `pal_is_online` returns 0 (online).
22. Skips push and logs an info message when `pal_is_online` returns 1 (offline).
23. Updates `last_known_commit` via `cs_store_commit` after a successful commit.
24. Updates sentinel via `rp_update_sentinel` as the final step of a successful sync.
25. Returns 1 and does not update sentinel when the sentinel is missing.
26. Returns 1 and does not update sentinel when `se_commit` fails.
27. Returns 1 and does not update sentinel when `se_push` returns 1 (persistent push failure while online).
28. Is idempotent: calling `rp_run` twice with no intervening save changes produces only one commit and leaves `rp_find_candidates` returning empty on the second call.
29. Skips a changed file with an unrecognized system directory (logs warning) and continues processing remaining changed files.
30. Creates intermediate directories (`mkdir -p`) before copying a file whose parent directory does not yet exist in the repo working tree.

### Code quality

31. `runtime_poll.sh` passes `shellcheck` with no errors.
32. `runtime_poll.sh` passes `busybox ash -n` syntax check.
33. No banned BusyBox ash constructs used (see CLAUDE.md table).
34. All four functions have a brief usage comment at the top of each function body.

---

## Testing Strategy

### Unit Tests

All unit test files are self-contained: create `TEST_TMPDIR` via `mktemp -d`, set up fixtures, run assertions, and clean up on EXIT via `trap 'rm -rf "$TEST_TMPDIR"' EXIT`. No network access. All tests run under `busybox ash`.

**Setup pattern for all unit tests in `tests/unit/core/test_runtime_poll.sh`:**

```sh
#!/bin/sh
set -e
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

. "$FIXTURES_DIR/pal_test.sh"
export TEST_TMPDIR
pal_init

. "$CORE_DIR/path_mapper.sh"
pm_load_platform_map "$(pal_get_platform_map)"

. "$CORE_DIR/sync_engine.sh"
se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"

. "$CORE_DIR/change_detector.sh"
. "$CORE_DIR/cold_start.sh"
. "$CORE_DIR/runtime_poll.sh"
```

A git repo must be initialized in `$TEST_TMPDIR/repo` (the test PAL's `$CONTINUITY_REPO_DIR`) with an initial commit and a sentinel file at `.continuity/sentinel`. A local bare repo at `$TEST_TMPDIR/remote.git` acts as the fake remote.

**Test cases for `rp_find_candidates`:**

- Create the sentinel. Create an `.srm` file under `$CONTINUITY_SAVES_ROOT/SFC/` (mtime newer than sentinel via `sleep 1 && touch`). Verify `rp_find_candidates` prints the absolute path of that file.
- No new files: verify `rp_find_candidates` returns 0 with empty output.
- File modified before sentinel (older mtime): verify `rp_find_candidates` does not include it.
- `$CONTINUITY_SAVES_ROOT` does not exist: verify `rp_find_candidates` returns 0 with empty output (no error output to stderr about find failure).
- Non-`.srm` file newer than sentinel: verify `rp_find_candidates` does not return it.

**Test cases for `rp_confirm_changes`:**

- Candidate device file differs from repo copy: verify device path is printed.
- Candidate device file is identical to repo copy (write same bytes to both): verify device path is NOT printed.
- Candidate with no corresponding repo copy (new file): verify device path is printed.
- Unknown system directory: override `pm_local_to_repo` to return 1; verify candidate is NOT printed and a warning is logged.
- Empty `candidates` string: verify returns 0 with no output.
- Multiple candidates, mixed results (some differ, some identical): verify only differing ones are printed.

**Test cases for `rp_update_sentinel`:**

- Sentinel exists: call `rp_update_sentinel`, verify mtime increased (compare mtime before and after using a test file as reference, or re-check with `find -newer`).
- Sentinel exists and `touch` succeeds: verify returns 0.
- Read-only `.continuity/` directory (use `chmod 555 "$CONTINUITY_REPO_DIR/.continuity"`): verify returns 1. Restore permissions in test cleanup.

**Test cases for `rp_run`:**

Each scenario uses a fresh `TEST_TMPDIR`. For `rp_run` tests that need to verify push behavior, use a local bare repo as the remote (approach (a) from Sprint 0.4 testing strategy). For simpler isolation tests, override `se_push` with a recording stub.

- **No candidates:** Set sentinel mtime to now. Verify `rp_run` returns 0. Verify `git log` has no new commits. Verify sentinel mtime is unchanged.
- **Candidates, all false positives:** Write an `.srm` file to device and identical bytes to repo copy. Touch the device file after the sentinel. Call `rp_run`. Verify returns 0. Verify no new commit in git log. Verify sentinel mtime updated.
- **One confirmed change, online:** Write an `.srm` to device. Write different bytes to the repo copy. Touch device file after sentinel. Call `rp_run` (with `pal_is_online` returning 0). Verify new commit in git log. Verify repo working tree now contains device bytes. Verify sentinel updated. Verify `last_known_commit` matches `git rev-parse HEAD`.
- **One confirmed change, offline:** Same setup but override `pal_is_online() { return 1; }`. Verify commit created locally. Verify `se_push` not called (stub records calls). Verify sentinel and `last_known_commit` updated.
- **New file on device, no repo copy:** Write `.srm` to device path with no corresponding repo file. Touch device file after sentinel. Call `rp_run`. Verify file appears in repo. Verify commit created.
- **Missing sentinel:** Remove sentinel before calling `rp_run`. Verify returns 1. Verify no new commit.
- **`se_commit` fails (stub):** Override `se_commit() { return 1; }`. Run with a confirmed change. Verify `rp_run` returns 1. Verify sentinel NOT updated.
- **Idempotency:** Run `rp_run` once with a confirmed change. Run again immediately. Verify second run produces no new commit and returns 0.
- **Unknown system dir in changed files:** Override `pm_local_to_repo` to return 1 for a specific path. Include both an unknown-system file and a valid file in the candidate set. Verify `rp_run` returns 0 (not 1). Verify only the valid file was committed.
- **`cmp` false positive after copy (git edge case):** Simulate the scenario where `rp_confirm_changes` returns a device path but after `cp` the `cd_detect_changes` call returns empty. Override `cd_detect_changes` to return empty. Verify `rp_run` returns 0, no commit, sentinel updated.

### Integration Test

**`tests/integration/test_runtime_poll_flow.sh`:**

A full end-to-end test using real git operations, a local bare remote, and multiple poll cycles.

**Test setup:**

1. Create `TEST_TMPDIR`.
2. Create bare remote at `$TEST_TMPDIR/remote.git` (`git init --bare`).
3. Use `tests/fixtures/enroll_test.sh` — call `et_setup "$TEST_TMPDIR"` to create an enrolled clone with pre-seeded saves.
4. Simulate boot pull completion: create sentinel at `$ET_REPO_DIR/.continuity/sentinel` and write current HEAD to `last_known_commit` (or call `cs_create_sentinel` + `cs_store_commit`).
5. Source test PAL, load all modules.

**Scenario 1: Single file change syncs correctly**

1. Write new bytes to `$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm` (the save on the device).
2. Sleep 1 second (ensures mtime is strictly newer than sentinel).
3. Touch the save file to guarantee its mtime is after the sentinel.
4. Call `rp_run "$ET_REPO_DIR"`.
5. Assert `rp_run` returns 0.
6. Assert `$ET_REPO_DIR/snes/super_metroid.srm` contains the new bytes.
7. Assert `$ET_REMOTE_DIR` contains the new bytes (push reached the remote).
8. Assert sentinel mtime is recent.
9. Assert `last_known_commit` matches `git -C "$ET_REPO_DIR" rev-parse HEAD`.

**Scenario 2: No-op when files unchanged**

1. Immediately call `rp_run "$ET_REPO_DIR"` again after Scenario 1 (no new file changes).
2. Assert returns 0.
3. Assert no new commit in `git log` (same HEAD as after Scenario 1).

**Scenario 3: New device-only save synced to repo**

1. Create a new save file: `$CONTINUITY_SAVES_ROOT/GBC/pokemon_red.srm`.
2. Sleep 1 second, touch file.
3. Call `rp_run "$ET_REPO_DIR"`.
4. Assert returns 0.
5. Assert `$ET_REPO_DIR/gbc/pokemon_red.srm` exists.
6. Assert commit message contains `pokemon_red.srm`.

**Scenario 4: Multiple files changed in one cycle**

1. Write new bytes to two separate saves (`SFC/super_metroid.srm` and `GBA/minish_cap.srm`).
2. Touch both files after sentinel.
3. Call `rp_run "$ET_REPO_DIR"`.
4. Assert returns 0.
5. Assert both files updated in repo.
6. Assert commit subject contains `2 saves updated` (or `N saves updated` per `se_commit` convention).

**Scenario 5: FAT32 false positive (identical bytes, different mtime)**

1. Read the bytes of `$ET_REPO_DIR/snes/super_metroid.srm`.
2. Write identical bytes back to `$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm`.
3. Touch device file after sentinel.
4. Call `rp_run "$ET_REPO_DIR"`.
5. Assert returns 0.
6. Assert no new commit in git log (false positive filtered by `cmp -s`).
7. Assert sentinel mtime updated.

---

## Definition of Done

- [ ] `src/core/runtime_poll.sh` implemented with `rp_run`, `rp_find_candidates`, `rp_confirm_changes`, `rp_update_sentinel`.
- [ ] `rp_run` follows the 10-step flow exactly as specified above.
- [ ] Two-stage detection implemented: `find -newer` sentinel for candidates, `cmp -s` repo copy for confirmation.
- [ ] `rp_update_sentinel` called in all appropriate exit paths (false positives, git-no-change edge case, and success), and NOT called when there are no candidates.
- [ ] `cs_store_commit` called after every successful commit to keep `last_known_commit` current.
- [ ] Push gated on `pal_is_online()` — offline devices commit locally and skip push.
- [ ] `rp_run` returns 1 on error conditions (missing sentinel, commit failure, push failure while online) and does NOT update sentinel on error.
- [ ] Unknown system directories logged as warnings and skipped without aborting the cycle.
- [ ] All variable expansions quoted; no banned BusyBox ash constructs used.
- [ ] Unit tests pass under `busybox ash`.
- [ ] Integration tests pass under `busybox ash`.
- [ ] `shellcheck` passes with no errors on all `.sh` files introduced by this sprint.
- [ ] `busybox ash -n` syntax check passes on all `.sh` files introduced by this sprint.
- [ ] All functions have a brief usage comment at the top of the function body.
- [ ] Sprint summary written to `docs/sprints/sprint-0.6-summary.md` on completion.

---

## Resolved Questions

1. **Should `rp_update_sentinel` be called when there are no candidates (step 2 early return)?** **Resolved — no.** The spec is correct. If nothing was scanned, the sentinel does not advance. This is safer for FAT32 (avoids losing changes modified right at the sentinel-touch boundary). Re-scanning the same window is harmless since `find -newer` returns the same nothing.

2. **Handling `se_push` return value 2 (deferred) when `pal_is_online` said we're online.** **Resolved — treat as non-fatal warning, defer pending-push retry to Sprint 1.1.** The commit exists locally. The daemon lifecycle (Sprint 1.1) will handle "push pending commits on connectivity restore." The runtime poll is deliberately minimal: one cycle, no cross-cycle state.

3. **`rp_confirm_changes` and `pm_local_to_repo` for new files.** **Resolved — confirmed.** `cmp -s "$device_path" "$repo_file"` returns non-zero when `$repo_file` doesn't exist, so the `cmp -s ... || echo "$device_path"` pattern correctly treats new files (no repo copy) as confirmed changes. No special-casing needed.

4. **`se_commit` argument convention from Sprint 0.3.** **Resolved — confirmed compatible.** Sprint 0.3's `se_commit(repo_dir, file_list)` accepts the repo directory as the first argument and newline-delimited repo-relative paths as the second. Sprint 0.4's `cd_detect_changes` outputs repo-relative paths, one per line. `se_commit "$repo_dir" "$(cd_detect_changes "$repo_dir")"` works directly. Coding agents should verify this during implementation.
