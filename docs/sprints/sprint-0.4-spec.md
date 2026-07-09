# Sprint 0.4 — Cold Start Sync

**Status:** Approved
**Date:** 2026-03-13
**Dependencies:** Sprint 0.3 (complete — enrollment done, cloned repo exists, sync engine available: `se_pull`, `se_stage_files`, `se_commit`, `se_push`)

---

## Goal

Implement the cold start sync flow — the first bidirectional sync that runs after device enrollment, before any sentinel or stored commit hash exists. Cold start merges whatever the device has on-disk with whatever the repo already contains (from other enrolled devices), resolves differences using a deterministic policy (repo wins on conflict), and leaves behind a sentinel and commit hash so all subsequent sync phases can operate incrementally.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, required variables (`CONTINUITY_SAVES_ROOT`, `CONTINUITY_REPO_DIR`, `CONTINUITY_DEVICE_NAME`), required functions (`pal_is_online`, `pal_log`)
- `docs/roadmap.md` — Sprint 0.4 scope, acceptance criteria, and relationship to Sprint 0.5 (boot pull)
- `src/core/pal.sh` — PAL validator (Sprint 0.2 output, assumed present)
- `src/core/path_mapper.sh` — `pm_local_to_repo`, `pm_repo_to_local`, `pm_list_watched_dirs` (Sprint 0.2 output, assumed present)
- `src/core/sync_engine.sh` — `se_pull`, `se_stage_files`, `se_commit`, `se_push` (Sprint 0.3 output, assumed present)

---

## Scope

### 1. Change Detector (`src/core/change_detector.sh`)

Helper module providing file enumeration functions used by the cold start flow and (in later sprints) by the runtime poll. This module has no side effects — it only reads the filesystem.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `cd_detect_changes` | `(repo_dir)` | prints repo-relative paths of modified files, one per line; returns 0 | Run `git -C "$repo_dir" status --porcelain` and extract the repo-relative paths of files that are Added, Modified, or Deleted (status codes `A`, `M`, `D`, `??`). Filter to `.srm` files only. Print each path, one per line. Return 0 even if output is empty. |
| `cd_list_repo_saves` | `(repo_dir)` | prints repo-relative `.srm` paths, one per line; returns 0 | List all `.srm` files currently present in `repo_dir`, excluding paths under `.git/` and `.continuity/`. Print each as a repo-relative path (relative to `repo_dir`), one per line. Return 0 even if output is empty. |
| `cd_list_device_saves` | `()` | prints absolute device paths to `.srm` files, one per line; returns 0 | For each directory returned by `pm_list_watched_dirs`, use `find "$dir" -name "*.srm"` to enumerate `.srm` files. Print each absolute path, one per line. Silently skips directories that do not exist (not an error — some system dirs may never have been used). Return 0 even if output is empty. |

**Implementation notes:**

- `cd_detect_changes` parses `git status --porcelain` output. Each line begins with a two-character status code followed by a space and the filename. Extract the filename field (column 4 onward after trimming the two-character code and space). Filter with `grep '\.srm$'`.
- `cd_list_repo_saves` uses `find "$repo_dir" -name "*.srm"` with explicit exclusions. Exclude `.git/` with `! -path "*/.git/*"` and `.continuity/` with `! -path "*/.continuity/*"`. Strip the `repo_dir` prefix from each result to produce repo-relative paths: use `printf '%s\n' "$abs_path" | sed "s|^$repo_dir/||"`.
- `cd_list_device_saves` calls `pm_list_watched_dirs` (from path mapper, which must be loaded). For each line of output, run `find "$dir" -name "*.srm" 2>/dev/null`. The `2>/dev/null` suppresses errors for nonexistent dirs; the explicit existence check is not required but may be used for clarity.
- `.local` conflict files (e.g., `snes/super_metroid.srm.my-brick.local`) do NOT end in `.srm` and are never returned by these functions.
- All variable expansions are quoted. No unquoted `$var`.
- BusyBox ash compatible — no arrays, no `[[`, no `local var=$(cmd)`.

---

### 2. Cold Start Module (`src/core/cold_start.sh`)

Implements the full cold start sync flow and the sentinel/commit-hash lifecycle. This module depends on: PAL variables and functions (loaded by caller), path mapper (loaded by caller), sync engine (loaded by caller), change detector (loaded by caller or sourced internally — see implementation note).

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `cs_is_cold_start` | `(repo_dir)` | 0 if cold start needed, 1 if sentinel present | Return 0 if `.continuity/sentinel` does not exist inside `repo_dir`. Return 1 if it does. This is the entry-point check the daemon uses to decide whether to run cold start or boot pull. |
| `cs_store_commit` | `(repo_dir, commit_hash)` | 0 on success, 1 on error | Write `commit_hash` to `$repo_dir/.continuity/last_known_commit`. Create the `.continuity/` directory if it does not exist. The file contents are the bare commit hash with a trailing newline, no other text. |
| `cs_read_commit` | `(repo_dir)` | prints commit hash to stdout; 0 on success, 1 if not found | Read `$repo_dir/.continuity/last_known_commit`. Print the stored commit hash (stripping any trailing newline). Return 1 if the file does not exist or is empty. |
| `cs_create_sentinel` | `(repo_dir)` | 0 on success, 1 on error | Create the file `$repo_dir/.continuity/sentinel`. Contents: current ISO-8601 timestamp from `date '+%Y-%m-%dT%H:%M:%S'`. Create `.continuity/` directory if needed. |
| `cs_run` | `(repo_dir)` | 0 on success, 1 on error | Execute the full cold start sync flow described below. Log progress via `pal_log`. |

**Cold start flow — `cs_run(repo_dir)`:**

```
1.  If pal_is_online:
      se_pull "$repo_dir"
        — If se_pull returns 1 (diverged): log error, return 1
        — If se_pull returns 2 (network error): log warn, set was_offline=true
    Else:
      pal_log "warn" "Cold start: offline — working with local clone only"
      was_offline=true

2.  cd_list_repo_saves "$repo_dir"
      — Enumerate .srm files currently in the repo working tree.

3.  cd_list_device_saves
      — Enumerate .srm files on the device across all watched directories.

4.  For each repo .srm (repo-relative path, e.g. "snes/super_metroid.srm"):
      a. Derive local_path via pm_repo_to_local "$repo_path"
         — If pm_repo_to_local returns 1 (unknown system), log warn and skip.
      b. repo_file="$repo_dir/$repo_path"
      c. If local_path does not exist on device:
           mkdir -p "$(dirname "$local_path")"
           cp "$repo_file" "$local_path"
           pal_log "info" "Cold start: pulled $repo_path to device"
      d. Elif ! cmp -s "$repo_file" "$local_path":
           — Files differ. Repo wins.
           conflict_name="$repo_path.$CONTINUITY_DEVICE_NAME.local"
           cp "$local_path" "$repo_dir/$conflict_name"
           cp "$repo_file" "$local_path"
           — Write .conflict metadata alongside the .local file so that
             ch_list_conflicts and ch_resolve (Sprint 0.8) can discover and
             resolve cold start conflicts. Write JSON to
             "$repo_dir/$repo_path.conflict" via printf:
               {"canonical": "$repo_path",
                "local_device": "$CONTINUITY_DEVICE_NAME",
                "timestamp": "<current ISO 8601 from date -u>",
                "source": "cold_start"}
           — Accumulate both artifact paths for staging in step 6:
             Append "$conflict_name" and "$repo_path.conflict" to conflict_files
             (newline-delimited variable, initialized empty before step 4).
           pal_log "warn" "Cold start: conflict on $repo_path — device version preserved as $conflict_name"
           — (optional hook) pal_on_conflict "$repo_path" if function is defined
      e. Else (cmp -s returns 0 — files identical):
           — No-op. Do not write, do not log.

5.  For each device .srm (absolute path):
      a. Derive repo_path via pm_local_to_repo "$local_path"
         — If pm_local_to_repo returns 1 (unknown system dir), log warn and skip.
      b. repo_file="$repo_dir/$repo_path"
      c. If repo_file does not exist in repo_dir:
           mkdir -p "$(dirname "$repo_file")"
           cp "$local_path" "$repo_file"
           pal_log "info" "Cold start: pushed $repo_path from device"
      d. Else (repo file exists — already handled in step 4, skip):
           — No-op.

6.  Detect and stage all changes:
      changed=$(cd_detect_changes "$repo_dir")
      — cd_detect_changes returns only .srm files. Conflict artifacts
        (.local and .conflict files created in step 4d) are NOT .srm files,
        so they must be appended separately. cs_run accumulates conflict
        artifact paths in a variable (conflict_files) during step 4d.
      If conflict_files is non-empty:
        changed="$changed
$conflict_files"         # Append conflict artifacts to the change list
      If changed is non-empty:
        se_stage_files "$repo_dir" "$changed"

7.  If changed is non-empty:
      se_commit "$repo_dir" "$changed"
      If pal_is_online:
        se_push "$repo_dir"
          — If se_push returns 2 (offline/deferred): log info, set was_offline=true
          — If se_push returns 1 (persistent failure): log error, return 1
      Else:
        was_offline=true
    Else:
      pal_log "info" "Cold start: nothing to commit"

8.  If was_offline is NOT true:
      head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
      cs_store_commit "$repo_dir" "$head_hash"

9.    cs_create_sentinel "$repo_dir"
    Else:
      pal_log "info" "Cold start: offline — sentinel deferred until next boot with connectivity"

10. pal_log "info" "Cold start complete"
    return 0
```

**Error handling in `cs_run`:**

- If `se_pull` fails (non-zero, non-offline): log error, return 1. Do not proceed with stale or partial repo state.
- If `cp` fails at any point: log error with filename, return 1.
- If `se_commit` or `se_push` fails: log error, return 1. Do not create sentinel — a failed push means state is inconsistent.
- If `cs_store_commit` or `cs_create_sentinel` fails: log error, return 1.
- Partial runs (no sentinel created) are safe — the daemon will re-run cold start on next boot.

**Sentinel and commit hash file location:**

Both files live inside `$repo_dir/.continuity/`:

| File | Path | Contents |
|------|------|----------|
| Sentinel | `$repo_dir/.continuity/sentinel` | ISO-8601 timestamp |
| Last known commit | `$repo_dir/.continuity/last_known_commit` | Bare 40-character SHA-1 commit hash |

These files are local device state — they are NOT committed to the repo and NOT pushed. They must be listed in `$repo_dir/.gitignore` (or `.continuity/.gitignore`). The cold start module does not write the `.gitignore` — that is enrollment's responsibility (Sprint 0.3). However, if a `.gitignore` is absent, `cd_detect_changes` must not return sentinel or last-known-commit as changed files. This is ensured because `cd_detect_changes` filters to `.srm` files only.

**Conflict file naming:**

`<repo_relative_path>.<device_name>.local`

Examples:
- `snes/super_metroid.srm.my-brick.local`
- `gba/minish_cap.srm.steam-deck.local`

These `.local` files are committed to the repo (they are intentionally tracked). They are not filtered by the `.srm`-only filter in `cd_list_repo_saves` and `cd_list_device_saves` — this is correct and intentional.

**Calling the optional `pal_on_conflict` hook:**

If `pal_on_conflict` is defined as a function (check with `command -v pal_on_conflict >/dev/null 2>&1`), call it with the canonical `.srm` repo-relative path (e.g., `snes/super_metroid.srm`) as the single argument after creating the conflict file. This matches the standardized PAL contract used by Sprint 0.8's conflict handler. If the function is not defined, skip silently.

**Implementation notes:**

- `cold_start.sh` sources `change_detector.sh` if `cd_list_repo_saves` is not already defined. Recommended pattern: check `command -v cd_list_repo_saves >/dev/null 2>&1 || . "$(dirname "$0")/../core/change_detector.sh"`. However, the preferred approach for the test harness is to source both files explicitly before calling `cs_run`. Specify this in the module header comment.
- All `local` variable declarations use the BusyBox-compatible split pattern: `local var; var=$(cmd)`.
- **Conflict artifact staging:** `cd_detect_changes` filters to `.srm` files only, so `.local` and `.conflict` files created during step 4d will NOT appear in its output. `cs_run` must track conflict artifacts separately in a `conflict_files` variable (newline-delimited, initialized empty before step 4). In step 6, append `conflict_files` to `changed` before calling `se_stage_files`. This keeps `cd_detect_changes` clean for its reuse in Sprint 0.6 (runtime poll), where `.srm`-only filtering is correct.
- The two nested loops (repo saves and device saves) iterate over newline-delimited strings using a `while IFS= read -r line` pattern fed from a subshell: `cd_list_repo_saves "$repo_dir" | while IFS= read -r repo_path; do ... done`. Since this runs in a subshell, any variables set inside the loop are not visible outside. Use temp files to accumulate counts or state if needed for logging.
- `cmp -s` is used for byte comparison throughout — no mtime dependency, works correctly on FAT32.
- Device name is read from `$CONTINUITY_DEVICE_NAME` (set by PAL). Never hardcoded.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Boot pull (incremental sync using stored commit diff) | 0.5 |
| Runtime poll (`find -newer` change detection) | 0.6 |
| Stale boot recovery (sentinel present but unclean shutdown) | 0.7 |
| Conflict resolution UI / handler | 0.8 |
| `.local` file enumeration for user presentation | 0.8 |
| Writing `.gitignore` entries for sentinel and last-known-commit | 0.3 (enrollment) |
| Onion OS PAL | 3.1 |
| RetroDeck PAL | 2.1 |
| Android PAL | 3.2 |
| NextUI daemon loop (boot dispatch logic) | 1.1 |
| Handling git merge conflicts (concurrent pushes from two devices) | 0.8 |
| Syncing non-`.srm` files (save states, screenshots, configs) | never |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/change_detector.sh` | File enumeration helpers: `cd_detect_changes`, `cd_list_repo_saves`, `cd_list_device_saves` |
| `src/core/cold_start.sh` | Cold start sync flow: `cs_run`, `cs_is_cold_start`, `cs_store_commit`, `cs_read_commit`, `cs_create_sentinel` |
| `tests/unit/core/test_change_detector.sh` | Unit tests for all three `cd_*` functions |
| `tests/unit/core/test_cold_start.sh` | Unit tests for sentinel/commit helpers and `cs_run` scenarios |
| `tests/integration/test_cold_start_flow.sh` | Integration test: full cold start across multiple save scenarios |

### Files Modified

None. All prior sprint outputs (`src/core/pal.sh`, `src/core/path_mapper.sh`, `src/core/sync_engine.sh`, `tests/fixtures/pal_test.sh`) are used as-is.

---

## Acceptance Criteria

### Change Detector

1. `cd_list_repo_saves` returns all `.srm` files in the repo working tree, one repo-relative path per line.
2. `cd_list_repo_saves` excludes files under `.git/` and `.continuity/`.
3. `cd_list_repo_saves` returns 0 and produces no output when no `.srm` files exist in the repo.
4. `cd_list_device_saves` returns all `.srm` files across all directories returned by `pm_list_watched_dirs`, one absolute path per line.
5. `cd_list_device_saves` does not fail when a watched directory does not exist — it silently skips it.
6. `cd_list_device_saves` returns 0 and produces no output when no `.srm` files exist on the device.
7. `cd_detect_changes` returns only `.srm` files reported as changed by `git status --porcelain` (status codes `A`, `M`, `D`, `??`).
8. `cd_detect_changes` returns 0 and produces no output when there are no staged or unstaged changes to `.srm` files.
9. `change_detector.sh` passes `shellcheck` with no errors.
10. `change_detector.sh` passes `busybox ash -n` syntax check.

### Cold Start Helpers

11. `cs_is_cold_start` returns 0 (cold start needed) when `$repo_dir/.continuity/sentinel` does not exist.
12. `cs_is_cold_start` returns 1 (no cold start) when `$repo_dir/.continuity/sentinel` exists.
13. `cs_store_commit` writes the given commit hash to `$repo_dir/.continuity/last_known_commit` as a single line.
14. `cs_store_commit` creates `$repo_dir/.continuity/` if it does not exist.
15. `cs_read_commit` reads and prints the stored commit hash, returning 0.
16. `cs_read_commit` returns 1 when `last_known_commit` does not exist.
17. `cs_read_commit` returns 1 when `last_known_commit` exists but is empty.
18. `cs_create_sentinel` creates `$repo_dir/.continuity/sentinel` with an ISO-8601 timestamp as its contents.
19. `cs_create_sentinel` creates `$repo_dir/.continuity/` if it does not exist.

### Cold Start Flow — `cs_run`

20. **Empty repo, saves on device:** All device `.srm` files are copied to the correct repo paths, committed, and pushed. Sentinel and commit hash are created. No `.local` files exist.
21. **Saves in repo, empty device:** All repo `.srm` files are copied to correct device paths (directories created as needed). Commit hash and sentinel created. Nothing staged or committed (repo already had the files; no new changes to push unless conflict files were added — none in this scenario).
22. **Identical saves on both sides:** `cmp -s` returns 0 for all files. No writes to device or repo. No commit. Sentinel and commit hash created from existing HEAD.
23. **Differing saves (same game on both sides):** Repo version is written to device. Device version is preserved as `<repo_path>.$CONTINUITY_DEVICE_NAME.local` in the repo. The `.local` file is staged and committed. Sentinel and commit hash created.
24. **New save on device not present in repo:** Device file is copied to repo at correct path. File is staged and committed. Sentinel and commit hash created.
25. **Multiple systems mixed:** Scenario combining cases 20–24 across several systems — all handled correctly in a single `cs_run` call.
26. **Offline (pal_is_online returns 1):** `cs_run` sets `was_offline=true` and skips `se_pull`. Local saves are still merged and committed locally. `se_push` is skipped. Because `was_offline` is true, sentinel and commit hash are NOT created — steps 8-9 are skipped entirely, and `cs_run` logs that sentinel is deferred. On next boot with connectivity, cold start re-runs from scratch (idempotent).
27. **Unknown system directory on device:** `pm_local_to_repo` returns 1 — file is skipped with a warning. Other files sync normally.
28. **Unknown canonical system in repo:** `pm_repo_to_local` returns 1 — file is skipped with a warning. Other files sync normally.
29. **`pal_on_conflict` hook:** If defined, called once per conflict with the canonical `.srm` repo-relative path as argument (e.g., `snes/super_metroid.srm`, not the `.local` path), matching the standardized PAL contract.
30. **Failed `se_pull`:** `cs_run` returns 1 immediately. No device files written. No sentinel created.
31. Sentinel is NOT created if `cs_run` returns 1 (error in any step).
32. `cold_start.sh` passes `shellcheck` with no errors.
33. `cold_start.sh` passes `busybox ash -n` syntax check.

---

## Testing Strategy

### Unit Tests

All unit test files are self-contained: create a `TEST_TMPDIR` via `mktemp -d`, set up fixtures, run assertions, and clean up on EXIT via `trap 'rm -rf "$TEST_TMPDIR"' EXIT`. No network access. No physical device required. All tests run under `busybox ash`.

**`tests/unit/core/test_change_detector.sh`:**

Setup: Source `tests/fixtures/pal_test.sh`, call `pal_init`, load `src/core/path_mapper.sh` with a copy of `nextui.json` as the platform map, then source `src/core/change_detector.sh`.

Test cases:

- `cd_list_repo_saves`: create a git repo in `$TEST_TMPDIR/repo` with a few `.srm` files at various paths, plus files in `.git/` and `.continuity/` that must be excluded. Verify output is correct and excluded paths are absent.
- `cd_list_repo_saves` with empty repo: verify returns 0 with no output.
- `cd_list_device_saves`: create `.srm` files in `$CONTINUITY_SAVES_ROOT/SFC/` and `$CONTINUITY_SAVES_ROOT/GBA/`. Verify both appear in output as absolute paths.
- `cd_list_device_saves` with a nonexistent watched dir: verify no error, output contains only files from dirs that do exist.
- `cd_list_device_saves` with no saves: verify returns 0 with no output.
- `cd_detect_changes`: initialize a git repo, add a `.srm` file untracked, verify it appears. Stage and commit it, modify it, verify it appears as modified. Add a non-`.srm` file; verify it does NOT appear.
- `cd_detect_changes` with no changes: verify returns 0 with no output.

**`tests/unit/core/test_cold_start.sh`:**

Setup: Source `tests/fixtures/pal_test.sh`, `pal_init`, then load path mapper and sync engine, then source `src/core/cold_start.sh`.

Test cases for helpers:

- `cs_is_cold_start`: returns 0 when sentinel absent; returns 1 when sentinel present.
- `cs_store_commit` / `cs_read_commit` round-trip: store a known hash, read it back, verify equality.
- `cs_read_commit` with missing file: verify returns 1.
- `cs_read_commit` with empty file: verify returns 1.
- `cs_create_sentinel`: verify file created, contents non-empty (is a timestamp string).
- `cs_store_commit` creates `.continuity/` directory when absent.
- `cs_create_sentinel` creates `.continuity/` directory when absent.

Test cases for `cs_run` (each in its own subshell with a fresh `TEST_TMPDIR`):

- Empty repo + device saves (acceptance criterion 20).
- Repo saves + empty device (acceptance criterion 21).
- Identical saves on both sides (acceptance criterion 22). Verify no commit was made (git log has only initial commit).
- Conflicting saves — differing bytes (acceptance criterion 23). Verify `.local` file exists in repo, device file is repo version, `.local` file appears in git log.
- Device save not in repo (acceptance criterion 24).
- Unknown system directory on device — verify `cs_run` returns 0 and other files sync correctly.
- `pal_on_conflict` hook called on conflict: define a recording stub before calling `cs_run`, verify it was invoked with the correct argument.

Each `cs_run` test case uses a stub sync engine that records calls (or uses real git operations against a local bare repo clone acting as the "remote") — see note below.

**Test sync engine strategy:**

The sync engine from Sprint 0.3 requires a real git remote for `se_push`. For unit tests, either:

(a) Use a local bare git repo as the fake remote (created in `$TEST_TMPDIR/remote.git` via `git init --bare`), clone it as the working repo, and let `se_push` push to it. This is the preferred approach — it tests real git behavior without network access.

(b) Override `se_push` with a no-op stub: `se_push() { return 0; }`. Simpler but tests less end-to-end behavior.

The integration test must use approach (a). Unit tests may use approach (b) for simplicity, as long as at least one test exercises real git push behavior.

### Integration Test

**`tests/integration/test_cold_start_flow.sh`:**

Tests the full cold start cycle with real git operations, multiple systems, and multiple conflict scenarios in a single run.

Test setup:

1. Create `TEST_TMPDIR`.
2. Create a local bare git repo at `$TEST_TMPDIR/remote.git` (`git init --bare`).
3. Clone it to `$TEST_TMPDIR/repo` (simulates another device having already pushed saves).
4. Populate the remote with saves for 3 systems: `gb/links_awakening.srm`, `snes/super_metroid.srm`, `gba/minish_cap.srm`. Commit and push from a separate clone.
5. Clone the remote again to `$TEST_TMPDIR/repo` (fresh device clone — no sentinel).
6. Populate `$CONTINUITY_SAVES_ROOT` with:
   - `SFC/super_metroid.srm` — different bytes than the repo version (conflict)
   - `GBA/minish_cap.srm` — identical bytes to repo version (no conflict)
   - `GBC/pokemon_red.srm` — device-only save, not in repo
   - (No `GB/` save — `links_awakening.srm` is repo-only)
7. Source test PAL, load all modules, call `cs_run "$TEST_TMPDIR/repo"`.

Assertions:

- `cs_run` returns 0.
- `links_awakening.srm` exists on device at correct path (repo → device pull).
- `super_metroid.srm` on device matches repo version (repo wins on conflict).
- `snes/super_metroid.srm.test-device.local` exists in repo (device version preserved).
- `minish_cap.srm` on device is unchanged (identical — no write).
- `pokemon_red.srm` exists in repo at `gbc/pokemon_red.srm` (device → repo push).
- Sentinel exists at `$TEST_TMPDIR/repo/.continuity/sentinel`.
- `last_known_commit` exists and contains a valid 40-character SHA-1.
- `cs_is_cold_start "$TEST_TMPDIR/repo"` returns 1 after a successful run.
- Remote bare repo contains `snes/super_metroid.srm.test-device.local` and `gbc/pokemon_red.srm` (push succeeded).

---

## Definition of Done

- [ ] `src/core/change_detector.sh` implemented with `cd_detect_changes`, `cd_list_repo_saves`, `cd_list_device_saves`.
- [ ] `src/core/cold_start.sh` implemented with `cs_run`, `cs_is_cold_start`, `cs_store_commit`, `cs_read_commit`, `cs_create_sentinel`.
- [ ] `cs_run` follows the cold start flow exactly as specified (10-step sequence above).
- [ ] Conflict convention `<repo_path>.<device_name>.local` implemented correctly using `$CONTINUITY_DEVICE_NAME`.
- [ ] Sentinel and last-known-commit written to `$repo_dir/.continuity/` (local device state, not pushed).
- [ ] `cs_run` returns 1 and does not create sentinel on any error condition.
- [ ] `pal_on_conflict` optional hook called when conflict files are created (checked with `command -v` guard).
- [ ] Change detector unit tests pass under `busybox ash`.
- [ ] Cold start unit tests pass under `busybox ash`.
- [ ] Cold start integration test passes under `busybox ash`.
- [ ] `shellcheck` passes on all `.sh` files introduced by this sprint with no errors.
- [ ] `busybox ash -n` syntax check passes on all `.sh` files introduced by this sprint.
- [ ] No banned BusyBox ash constructs used in any file under `src/core/` (see CLAUDE.md table).
- [ ] All functions have a brief usage comment at the top of the function body.
- [ ] Sprint summary written to `docs/sprints/sprint-0.4-summary.md` on completion.

---

## Resolved Questions

1. **Offline cold start — should sentinel be created?** **Resolved — Option A (no sentinel when offline).** If `pal_is_online` returns 1 at startup, `se_pull` skips and `se_push` defers. The cold start completes locally but does NOT create the sentinel and does NOT store the commit hash. On next boot, cold start runs again from scratch. Rationale: cold start is cheap and idempotent; re-running it with connectivity gives a proper bidirectional merge against the real remote state, avoiding the complex interactions between boot pull, stale boot, and conflict handler for a first-boot edge case.

   **Implementation impact on `cs_run` flow:** Steps 8 and 9 (store commit hash and create sentinel) are skipped if `se_push` returned 2 (offline). The check is: if `se_push` deferred AND the system was offline at the start of `cs_run`, do not create sentinel. If `se_push` succeeded (or there was nothing to push), create the sentinel normally.

2. **What happens if `se_push` defers (offline) mid-cold-start?** **Resolved — linked to OQ1.** Since sentinel is NOT created when offline, this scenario is safe. The local commit exists but isn't pushed. On next boot, cold start re-runs, `se_pull` gets the remote state, and the merge includes both the previously-committed local changes and any new remote changes.

3. **`cd_detect_changes` — staged vs. unstaged filtering.** **Resolved — all changes, no filtering parameter needed.** Both Sprint 0.4 (cold start) and Sprint 0.6 (runtime poll) want the same thing: "which `.srm` files have changed in the working tree?" Neither needs a staged-vs-unstaged distinction. `git status --porcelain` returns both, and callers always stage everything returned. No parameter needed.
