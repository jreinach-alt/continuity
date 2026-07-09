# Sprint 0.8 — Conflict Handler

**Status:** Approved
**Date:** 2026-03-13
**Dependencies:** Sprint 0.7 (all sync phases operational — stale boot recovery complete; conflicts can arise during any pull phase)

---

## Goal

Implement the conflict handler — the module that preserves both sides of a diverged-history save conflict, writes structured metadata, and provides resolution functions to clean up conflict artifacts. When `se_pull` returns 1 (branches have diverged and a fast-forward pull is not possible), the sync engine cannot automatically merge `.srm` files. This sprint gives the system a safe, deterministic way to handle that case: preserve the local device's version alongside the remote (canonical) version, commit the conflict state so all devices can see it, and provide resolution functions that platform UIs (Sprint 1.5 Tool PAK, Sprint 2.2 RetroDeck app) can call to resolve conflicts when the user makes a choice.

The invariant this sprint enforces is stated in the architecture spec: **no save data is ever silently overwritten.** After Sprint 0.8, the only path where a `.srm` file is replaced is through an explicit resolution call.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface: `CONTINUITY_DEVICE_NAME`, `CONTINUITY_GIT_BIN`, `CONTINUITY_REPO_DIR`, `pal_log()`, `pal_on_conflict()` (optional hook)
- `docs/design/architecture.md` — Conflict Resolution Strategy section; conflict preservation convention; `.conflict` metadata format
- `docs/roadmap.md` — Sprint 0.8 scope and acceptance criteria
- `src/core/sync_engine.sh` — `se_pull()` return codes, `se_stage_files()`, `se_commit()`, `se_push()` (Sprint 0.3 output, assumed present)
- `src/core/cold_start.sh` — `cs_store_commit()` (Sprint 0.4 output, assumed present)

---

## Scope

### Conflict Handler Module (`src/core/conflict_handler.sh`)

Single-file module implementing all conflict detection, preservation, enumeration, and resolution logic. Designed to be sourced by entry points after the PAL and all prior core modules are loaded. Has no module-level state — all state is on the filesystem (conflict artifact files and git history). No `ch_init` function is required.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `ch_handle_pull_conflict` | `(repo_dir)` | 0 on success, 1 on error | Called when `se_pull` returns 1 (diverged). Fetches the remote, identifies conflicted `.srm` files, preserves local versions with device attribution, accepts remote as canonical, writes `.conflict` metadata, commits all conflict artifacts, pushes, and calls `pal_on_conflict` for each conflict if the function is defined. |
| `ch_preserve_conflict` | `(repo_dir, repo_path, device_name)` | 0 on success, 1 on error | Preserves the local version of a single conflicted file as `<repo_path>.<device_name>.local`, writes the `.conflict` JSON metadata file for that save. Does not commit — the caller batches and commits. |
| `ch_list_conflicts` | `(repo_dir)` | prints newline-delimited repo-relative paths of `.conflict` files, one per line; returns 0 | Enumerate all unresolved conflict metadata files in `repo_dir` by finding files matching `*.conflict`. Print each as a repo-relative path. Returns 0 always, even if no conflicts exist (empty output is not an error). |
| `ch_list_local_files` | `(repo_dir)` | prints newline-delimited records of `<repo_path> <device_name>`, one per line; returns 0 | Enumerate all `.local` files in `repo_dir`. For each, parse the device name from the filename (the component between the last `.srm` and `.local`), and print `<repo_path_of_canonical> <device_name>`. Returns 0 always. |
| `ch_resolve` | `(repo_dir, repo_path, resolution)` | 0 on success, 1 on error | Resolve a single conflict identified by `repo_path` (the canonical `.srm` path). `resolution` is one of: `keep_remote`, `keep_local`, `keep_newest`, `prompt`. See resolution logic below. Commits the result. |
| `ch_resolve_all` | `(repo_dir, resolution)` | 0 if all resolved, 1 if any failed | Call `ch_list_conflicts` to enumerate all unresolved conflicts. For each, derive the canonical `repo_path` from the `.conflict` filename, and call `ch_resolve` with the given `resolution`. Returns 0 only if every call to `ch_resolve` returned 0. |

---

### Conflict File Conventions

The following naming conventions are used throughout this sprint and must be treated as canonical — all prior mentions of `.local` files (Sprint 0.4 cold start) used a similar but less specific convention. This sprint formalizes and extends the convention with device attribution.

**For a conflicted save at `snes/super_metroid.srm`:**

| File | Convention | Meaning |
|------|------------|---------|
| `snes/super_metroid.srm` | Canonical path | The remote version — accepted as the authoritative save after conflict detection |
| `snes/super_metroid.srm.<device_name>.local` | e.g. `snes/super_metroid.srm.my-brick.local` | The local device's version at time of conflict |
| `snes/super_metroid.srm.conflict` | Fixed suffix `.conflict` | JSON metadata for this conflict |

All three files are committed to the repo. `.local` and `.conflict` files are not gitignored — they must be visible to all enrolled devices so any device can enumerate and resolve conflicts.

The device name embedded in the `.local` filename is `$CONTINUITY_DEVICE_NAME` at time of conflict creation. Device names must not contain dots (enforced during enrollment). This is a pre-existing constraint — see `docs/design/pal.md`.

---

### Conflict Metadata Format (`.conflict` JSON)

Written by `ch_preserve_conflict`. The file is committed to the repo alongside the `.local` file.

```json
{
  "_schema_version": "1.0",
  "file": "snes/super_metroid.srm",
  "remote_device": "my-deck",
  "remote_timestamp": "2026-03-12T13:00:00Z",
  "local_device": "my-brick",
  "local_timestamp": "2026-03-12T14:30:00Z",
  "status": "unresolved"
}
```

Field notes:

- `file`: the canonical repo-relative path of the `.srm` file (not the `.local` or `.conflict` path)
- `remote_device`: read from the most recent git commit message that touched `<repo_path>` on the remote branch, by parsing the `device:` trailer in the commit body (see `se_commit` convention from Sprint 0.3). If the device name cannot be parsed, use the string `"unknown"`.
- `remote_timestamp`: the committer timestamp of that same commit, formatted as ISO-8601 UTC. Derived from `git log --format="%cI"`.
- `local_device`: `$CONTINUITY_DEVICE_NAME` at time of conflict creation.
- `local_timestamp`: the mtime of the local `.srm` file at time of conflict, formatted as ISO-8601 UTC. On BusyBox (FAT32, 2-second mtime granularity), this is approximate. Use `date -u '+%Y-%m-%dT%H:%M:%SZ'` combined with `stat` where available; fall back to current time if `stat` is not available or returns an error.
- `status`: always `"unresolved"` when written. Updated to `"resolved"` by resolution functions before the artifact files are removed — but in practice the file is deleted as part of resolution cleanup, so `"resolved"` need not be written to disk. The `status` field exists for diagnostic purposes in the unlikely case a resolution is interrupted.

JSON is written via `printf` (no `jq` dependency — not available on BusyBox). Use a heredoc-style `printf` pattern:

```sh
printf '{\n  "_schema_version": "1.0",\n  "file": "%s",\n  ...\n}\n' \
  "$file" ...
```

All string values must have any embedded double-quotes escaped (`\"`). Device names and repo paths are not expected to contain quotes, but the code must not fail if they do.

---

### `ch_handle_pull_conflict` — Full Flow

```
ch_handle_pull_conflict(repo_dir):

  1. Fetch the remote to get the latest commits without merging:
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" fetch origin
       — On failure: pal_log "error" "Conflict handler: fetch failed"; return 1

  2. Identify conflicted .srm files — files that differ between local HEAD
     and the remote (origin/main):
       conflicted=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" \
           diff --name-only HEAD origin/main -- '*.srm')
       — If conflicted is empty: no .srm files differ, nothing to conflict.
         Accept remote by resetting to origin/main:
           "$CONTINUITY_GIT_BIN" -C "$repo_dir" reset --hard origin/main
         pal_log "info" "Conflict handler: no .srm conflicts — reset to remote"
         return 0

  3. For each repo_path in conflicted (while IFS= read -r):
       a. ch_preserve_conflict "$repo_dir" "$repo_path" "$CONTINUITY_DEVICE_NAME"
            — On failure: pal_log "error" "Failed to preserve $repo_path"; return 1

  4. Accept the remote version as canonical for all conflicted files:
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" reset --hard origin/main
       — This replaces all conflicted .srm files in the working tree with the
         remote version, while the .local files created in step 3 are
         untracked at this point and are preserved.

  5. Stage all conflict artifacts in a single call:
       Build a newline-delimited list of all .local and .conflict files:
       stage_list=""
       For each repo_path in conflicted:
         stage_list="$stage_list$repo_path.$CONTINUITY_DEVICE_NAME.local
$repo_path.conflict
"
       se_stage_files "$repo_dir" "$stage_list"

  6. Commit all conflict artifacts in a single commit:
       # NOTE: This intentionally uses raw `git commit -m` instead of
       # se_commit. Conflict preservation commits have their own message
       # format and do not need the device/timestamp trailers that
       # se_commit appends. This bypass is by design.
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
           -m "conflict: $(printf '%s\n' "$conflicted" | wc -l | tr -d ' ') save(s) preserved from $CONTINUITY_DEVICE_NAME"
       — On failure: pal_log "error" "Conflict handler: commit failed"; return 1

  7. Push to remote so all devices see the conflict state:
       se_push "$repo_dir"
       — If se_push returns 1 (persistent failure): pal_log "error"; return 1
       — If se_push returns 2 (offline): pal_log "warn" "Conflict artifacts committed locally — push pending"; do NOT return 1

  8. Update last_known_commit:
       head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
       cs_store_commit "$repo_dir" "$head_hash"

  9. Call pal_on_conflict hook for each conflicted file (if defined):
       For each repo_path in conflicted:
         if command -v pal_on_conflict >/dev/null 2>&1; then
           pal_on_conflict "$repo_path"
         fi

 10. pal_log "info" "Conflict handler: $(count) conflict(s) preserved"
     return 0
```

**Step 3 / Step 4 ordering rationale:** The local `.srm` bytes must be copied out (to the `.local` file) before the `reset --hard` overwrites the working tree with the remote version. `ch_preserve_conflict` performs this copy as its first operation. After step 4, the canonical path contains the remote bytes and the `.local` file contains the local bytes.

**Step 5 staging note:** `se_stage_files` (Sprint 0.3) accepts a newline-delimited list of repo-relative paths. `.local` and `.conflict` files are not tracked before this sprint, so they appear as `??` (untracked) in `git status --porcelain`. `se_stage_files` must call `git add` (not `git add -u`) so untracked files are staged. Verify this is consistent with the Sprint 0.3 implementation before coding begins.

**Branch name:** This spec assumes `main` as the remote branch name, consistent with Sprint 0.3 enrollment convention. If the enrollment sprint uses a different default branch name, this spec must be updated.

---

### `ch_preserve_conflict` — Implementation Detail

```
ch_preserve_conflict(repo_dir, repo_path, device_name):

  1. local_file="$repo_dir/$repo_path.$device_name.local"
     conflict_meta="$repo_dir/$repo_path.conflict"

  2. Copy local .srm bytes to .local file:
       cp "$repo_dir/$repo_path" "$local_file"
       — On failure: pal_log "error" "ch_preserve_conflict: cp failed for $repo_path"; return 1

  3. Derive conflict metadata:
       remote_device: parse from git log (see metadata format section above)
       remote_timestamp: parse from git log
       local_timestamp: mtime of "$repo_dir/$repo_path" (before reset --hard)

  4. Write .conflict JSON to $conflict_meta via printf.
       — On failure: pal_log "error" "ch_preserve_conflict: write failed for $conflict_meta"; return 1

  5. return 0
```

`ch_preserve_conflict` does NOT commit. It only writes files to disk. The caller (`ch_handle_pull_conflict`) batches all conflict artifacts and commits them in one commit (step 6 of the handle flow).

**Deriving `remote_device` and `remote_timestamp`:**

```sh
# Most recent commit on origin/main that touched $repo_path
remote_info=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" \
    log -1 --format="%cI%n%B" origin/main -- "$repo_path")

# remote_timestamp: first line (ISO-8601 committer date)
remote_timestamp=$(printf '%s\n' "$remote_info" | head -1)

# remote_device: parse "device: <name>" trailer from commit body
remote_device=$(printf '%s\n' "$remote_info" | grep '^device:' | head -1 | sed 's/^device: *//')
[ -z "$remote_device" ] && remote_device="unknown"
```

BusyBox compatibility: `head -1` and `grep` are available. `sed 's/^device: *//'` strips the `device: ` prefix. No arrays, no `[[`.

**Deriving `local_timestamp`:**

```sh
# BusyBox stat -c '%Y' gives mtime as Unix timestamp (seconds since epoch)
# Convert to ISO-8601 UTC with date -d or date -u
local_mtime_epoch=$(stat -c '%Y' "$repo_dir/$repo_path" 2>/dev/null)
if [ -n "$local_mtime_epoch" ]; then
    # BusyBox date does not support -d @epoch; use awk or accept current time
    local_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
else
    local_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fi
```

**Note on BusyBox `date`:** BusyBox `date` does not support `date -d @<epoch>` for timestamp conversion. The spec does not require exact mtime-to-ISO conversion — using the current time as a fallback is acceptable. The timestamp is informational for conflict resolution UI; approximate is sufficient. Implementations on full Linux (RetroDeck) may use the exact mtime. Do not introduce a non-BusyBox dependency to get exact precision on constrained devices.

---

### `ch_list_conflicts` — Implementation Detail

```sh
ch_list_conflicts() {
    # repo_dir: $1
    # Find all *.conflict files, print repo-relative paths
    find "$1" \
        ! -path "*/.git/*" \
        -name "*.conflict" \
        2>/dev/null \
    | sed "s|^$1/||"
}
```

Output is unsorted. Callers must not assume order. Returns 0 always (consistent with `cd_list_repo_saves` convention from Sprint 0.4).

---

### `ch_list_local_files` — Implementation Detail

```sh
ch_list_local_files() {
    # repo_dir: $1
    # Find all *.local files, parse device name from filename
    find "$1" \
        ! -path "*/.git/*" \
        -name "*.local" \
        2>/dev/null \
    | sed "s|^$1/||" \
    | while IFS= read -r local_path; do
        # local_path: e.g. "snes/super_metroid.srm.my-brick.local"
        # canonical: strip ".<device_name>.local" suffix
        # device_name: the component between last ".srm" and ".local"
        base=$(printf '%s' "$local_path" | sed 's/\.[^.]*\.local$//')
        device=$(printf '%s' "$local_path" | sed 's/.*\.srm\.\([^.]*\)\.local$/\1/')
        printf '%s %s\n' "$base" "$device"
    done
}
```

Output format: `<canonical_repo_path> <device_name>`, one per line. Example: `snes/super_metroid.srm my-brick`.

**Parsing caveat:** The sed pattern `s/.*\.srm\.\([^.]*\)\.local$/\1/` extracts the device name for files with the naming convention `<name>.srm.<device>.local`. If the device name contains a dot (violating the enrollment constraint), parsing will be incorrect — this is a known and accepted limitation consistent with the enrollment design.

---

### `ch_resolve` — Resolution Logic

```
ch_resolve(repo_dir, repo_path, resolution):

  1. conflict_meta="$repo_dir/$repo_path.conflict"
     local_file="$repo_dir/$repo_path.<device_name>.local"

     Determine local_file: find any file matching "$repo_dir/$repo_path.*.local"
       local_file=$(find "$repo_dir" -name "$basename.*.local" ! -path "*/.git/*" | head -1)
     — If no .local file found: log warn "ch_resolve: no .local file for $repo_path"; return 1
     — If conflict_meta does not exist: log warn "ch_resolve: no .conflict metadata for $repo_path"; return 1

  2. case $resolution in

     keep_remote)
       # Remote (canonical) version is already in place — just remove artifacts
       rm -f "$local_file" "$conflict_meta"
       se_stage_files "$repo_dir" \
           "$(printf '%s' "$repo_path.*.local" | sed "s|$repo_dir/||") $repo_path.conflict"
       # Stage the deletions
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached \
           "$repo_path.$(basename "$local_file" | sed 's/.*\.srm\.\(.*\)\.local/\1/').local" \
           "$repo_path.conflict" 2>/dev/null || true
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
           -m "resolve: keep remote $repo_path"
       ;;

     keep_local)
       # Copy local version over canonical, then remove artifacts
       cp "$local_file" "$repo_dir/$repo_path"
       rm -f "$local_file" "$conflict_meta"
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" add "$repo_path"
       local_file_relpath=$(printf '%s' "$local_file" | sed "s|^$repo_dir/||")
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached \
           "$local_file_relpath" \
           "$repo_path.conflict" 2>/dev/null || true
       "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
           -m "resolve: keep local $repo_path"
       ;;

     keep_newest)
       # Compare timestamps in .conflict metadata; pick the newer device's version
       # Read remote_timestamp and local_timestamp from the .conflict JSON
       remote_ts=$(grep '"remote_timestamp"' "$conflict_meta" | sed 's/.*: *"\([^"]*\)".*/\1/')
       local_ts=$(grep '"local_timestamp"' "$conflict_meta" | sed 's/.*: *"\([^"]*\)".*/\1/')
       # ISO-8601 strings sort lexicographically; string comparison is valid
       if [ "$local_ts" \> "$remote_ts" ]; then
           ch_resolve "$repo_dir" "$repo_path" "keep_local"
       else
           ch_resolve "$repo_dir" "$repo_path" "keep_remote"
       fi
       return $?
       ;;

     prompt)
       # Default — do nothing. Leave artifacts in place for platform UI.
       pal_log "info" "ch_resolve: $repo_path left unresolved (prompt mode)"
       return 0
       ;;

     *)
       pal_log "error" "ch_resolve: unknown resolution '$resolution'"
       return 1
       ;;

  esac

  3. Update last_known_commit after a successful commit:
       head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
       cs_store_commit "$repo_dir" "$head_hash"

  4. Push if online:
       if pal_is_online; then
           se_push "$repo_dir"
       fi

  5. return 0
```

**Implementation notes for `ch_resolve`:**

The `keep_remote` and `keep_local` resolution paths both use `git rm --cached` to remove the `.local` and `.conflict` files from the index (since they were previously committed), then `rm -f` to delete them from the working tree, then commit. This is the correct sequence: `git rm --cached` removes from index without touching the working tree, then `rm -f` removes from disk, then the commit records the deletion.

**Note on `git rm --cached`:** `se_stage_files` uses `git add` which cannot remove files from the index. For deletion of conflict artifacts, `ch_resolve` must use `$CONTINUITY_GIT_BIN -C "$repo_dir" rm --cached` directly. This is the only place in the codebase where raw `git rm` is used outside the sync engine, and it is acceptable because artifact cleanup is an operation unique to conflict resolution.

The inline pseudocode above shows the logical intent. The actual implementation must handle the exact filename of the `.local` file (which includes the device name) carefully. Avoid hard-coding `$CONTINUITY_DEVICE_NAME` in `ch_resolve` — instead, derive the `.local` filename from what actually exists on disk using `find`.

**Multi-device `.local` cleanup:** When resolving a conflict, `ch_resolve` must clean up ALL `.local` files matching `<repo_path>.*.local` (not just the first one found). In multi-device conflict scenarios (rare but possible), the repo may contain `save.srm.device-a.local` and `save.srm.device-b.local`. For `keep_local`, `head -1` picks which `.local` file becomes canonical — this is acceptable since multi-device conflict UI (Sprint 1.5) can offer per-device selection. For `keep_remote`, all `.local` files are simply deleted. All `.local` files must be removed from both disk and git index as part of resolution cleanup.

The `keep_newest` path calls `ch_resolve` recursively with `keep_local` or `keep_remote`. The recursive call includes the commit and push. There is no infinite recursion risk since the recursive call always uses `keep_local` or `keep_remote`, not `keep_newest`.

**Timestamp comparison:** ISO-8601 UTC strings (`2026-03-12T14:30:00Z`) sort correctly with lexicographic string comparison (`[ "$a" \> "$b" ]`). This works as long as both timestamps are in UTC with the same format, which this spec guarantees.

---

### Integration with Sprint 0.5 (Boot Pull)

Sprint 0.5 `bp_run` currently returns 1 and logs a warning when `se_pull` returns 1 (diverged), with a comment: "Sprint 0.8 will replace this with a call to the conflict handler."

After Sprint 0.8, `boot_pull.sh` must be updated so that the diverged branch at step 2 calls `ch_handle_pull_conflict` instead of returning 1:

```sh
# In bp_run, step 2 — se_pull diverged case:
if ! ch_handle_pull_conflict "$repo_dir"; then
    pal_log "error" "Boot pull: conflict handler failed"
    return 1
fi
return 0
```

This change to `boot_pull.sh` is in scope for Sprint 0.8. It is a one-function call addition — not a structural change to `boot_pull.sh`.

Similarly, `stale_boot.sh` (Sprint 0.7) may contain the same placeholder. If it does, the same update applies to `stale_boot.sh` in this sprint.

---

### `pal_on_conflict` Hook

The optional PAL function `pal_on_conflict(repo_path)` is defined in `docs/design/pal.md`. `ch_handle_pull_conflict` calls it after all conflict artifacts are committed, once per conflicted file. The call is guarded:

```sh
if command -v pal_on_conflict >/dev/null 2>&1; then
    pal_on_conflict "$repo_path"
fi
```

This sprint does not implement `pal_on_conflict` in any platform PAL — that is Sprint 1.5 (NextUI Tool PAK). The guard ensures `conflict_handler.sh` is safe to call from any PAL that does not define this function.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| `pal_on_conflict` implementation in NextUI PAL | 1.2 |
| Conflict resolution UI in the NextUI Tool PAK | 1.2 |
| `pal_on_conflict` implementation in RetroDeck PAL | 2.2 |
| Three-way merge of `.srm` files (binary, not meaningful) | never |
| Syncing non-`.srm` files | never |
| `keep_device` resolution mode (prefer a specific device always) | post-1.0 |
| Reading `conflict_resolution` from `.continuity/config.json` to auto-resolve | 1.1 (daemon lifecycle) |
| Stale boot module implementation | 0.7 |
| Runtime push conflict (push rejection) — push failures are retried, not conflicted | not applicable |
| Deleting `.local` files as part of normal (non-conflict) sync | never |
| Android conflict resolution UI | 3.2 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/conflict_handler.sh` | Conflict detection, preservation, enumeration, and resolution: `ch_handle_pull_conflict`, `ch_preserve_conflict`, `ch_list_conflicts`, `ch_list_local_files`, `ch_resolve`, `ch_resolve_all` |
| `tests/unit/core/test_conflict_handler.sh` | Unit tests for all six `ch_*` functions |
| `tests/integration/test_conflict_flow.sh` | Integration test: two-device conflict scenario end-to-end using local bare remotes |

### Files Modified

| File | Change |
|------|--------|
| `src/core/boot_pull.sh` | Replace the Sprint 0.5 diverged-branch placeholder with a call to `ch_handle_pull_conflict` |
| `src/core/stale_boot.sh` | If Sprint 0.7 contains the same diverged-branch placeholder in its pull step, replace it with a call to `ch_handle_pull_conflict` |

### Directories Created

None. All target directories exist from prior sprints.

---

## Acceptance Criteria

### `ch_preserve_conflict`

1. Given a repo with a committed `.srm` file, `ch_preserve_conflict` creates a `.local` file at `<repo_path>.<device_name>.local` containing the same bytes as the original `.srm` file before any overwrite.
2. `ch_preserve_conflict` writes a valid JSON `.conflict` file with all required fields (`_schema_version`, `file`, `remote_device`, `remote_timestamp`, `local_device`, `local_timestamp`, `status: "unresolved"`).
3. The `local_device` field in the `.conflict` JSON matches `$CONTINUITY_DEVICE_NAME`.
4. The `file` field in the `.conflict` JSON is the canonical repo-relative `.srm` path (not the `.local` or `.conflict` path).
5. `ch_preserve_conflict` returns 1 and logs an error if the `cp` to create the `.local` file fails.
6. `ch_preserve_conflict` does not commit anything — it only writes files to disk.
7. If `remote_device` cannot be determined from git log, the `.conflict` JSON uses `"unknown"` for that field rather than failing.

### `ch_list_conflicts`

8. Returns repo-relative paths of all `.conflict` files in `repo_dir`, one per line, and returns 0.
9. Returns 0 and produces no output when no `.conflict` files exist.
10. Does not return paths under `.git/`.
11. Does not return paths for files that end in `.local` (only `.conflict` files).

### `ch_list_local_files`

12. Returns one line per `.local` file in the format `<canonical_repo_path> <device_name>`.
13. Correctly parses device name from `snes/super_metroid.srm.my-brick.local` as `my-brick` and canonical path as `snes/super_metroid.srm`.
14. Returns 0 always, even when no `.local` files exist (produces no output).
15. Does not return paths under `.git/`.
16. When multiple `.local` files exist (multiple devices in conflict), all are returned.

### `ch_handle_pull_conflict`

17. When called after a diverged pull, identifies all `.srm` files that differ between local HEAD and `origin/main`, and calls `ch_preserve_conflict` for each.
18. After `ch_handle_pull_conflict` completes successfully, the canonical `.srm` paths contain the remote version's bytes.
19. After `ch_handle_pull_conflict` completes successfully, a `.local` file exists for each conflicted save containing the bytes from the local device's version.
20. After `ch_handle_pull_conflict` completes successfully, a `.conflict` JSON file exists for each conflicted save.
21. The `.local` and `.conflict` files are committed to the repo in a single commit.
22. After `ch_handle_pull_conflict` completes successfully, `last_known_commit` equals the HEAD commit hash.
23. `ch_handle_pull_conflict` calls `pal_on_conflict` for each conflicted file if `pal_on_conflict` is defined, and does not fail if `pal_on_conflict` is not defined.
24. If the fetch from remote fails, `ch_handle_pull_conflict` logs an error and returns 1 without modifying any files.
25. If no `.srm` files differ between the branches (only non-save files diverged), `ch_handle_pull_conflict` resets to origin/main and returns 0 without creating any conflict artifacts.
26. If `se_push` returns 2 (offline) after committing conflict artifacts, `ch_handle_pull_conflict` returns 0 (offline is non-fatal — the conflict state is preserved locally and will push when connectivity returns).

### `ch_resolve` — `keep_remote`

27. After `ch_resolve` with `keep_remote`, the canonical `.srm` file retains the remote bytes.
28. After `ch_resolve` with `keep_remote`, the `.local` file is removed from disk and from the git index.
29. After `ch_resolve` with `keep_remote`, the `.conflict` file is removed from disk and from the git index.
30. A commit is made recording the resolution.
31. `last_known_commit` is updated after the resolution commit.

### `ch_resolve` — `keep_local`

32. After `ch_resolve` with `keep_local`, the canonical `.srm` file contains the bytes from the `.local` file.
33. After `ch_resolve` with `keep_local`, the `.local` file is removed from disk and from the git index.
34. After `ch_resolve` with `keep_local`, the `.conflict` file is removed from disk and from the git index.
35. A commit is made recording the resolution.
36. `last_known_commit` is updated after the resolution commit.

### `ch_resolve` — `keep_newest`

37. When `local_timestamp` is more recent than `remote_timestamp` (lexicographic ISO-8601 comparison), `keep_newest` resolves using `keep_local` behavior.
38. When `remote_timestamp` is more recent or equal to `local_timestamp`, `keep_newest` resolves using `keep_remote` behavior.
39. `keep_newest` reads timestamps from the `.conflict` JSON file, not from filesystem mtime.

### `ch_resolve` — `prompt`

40. `ch_resolve` with `prompt` returns 0 and makes no changes to files, git index, or commit history.
41. After `ch_resolve` with `prompt`, the `.local` and `.conflict` files still exist and are still committed.

### `ch_resolve` — Error Cases

42. `ch_resolve` returns 1 and logs a warning if no `.local` file is found for the given `repo_path`.
43. `ch_resolve` returns 1 and logs a warning if no `.conflict` metadata file is found for the given `repo_path`.
44. `ch_resolve` returns 1 and logs an error for an unrecognized `resolution` value.

### `ch_resolve_all`

45. `ch_resolve_all` calls `ch_resolve` for every conflict found by `ch_list_conflicts`.
46. `ch_resolve_all` returns 0 if all `ch_resolve` calls return 0.
47. `ch_resolve_all` returns 1 if any `ch_resolve` call returns non-zero.
48. `ch_resolve_all` with no conflicts (empty `ch_list_conflicts` output) returns 0 immediately.

### Integration with `boot_pull.sh`

49. After Sprint 0.8, `bp_run` calls `ch_handle_pull_conflict` when `se_pull` returns 1 (diverged), and returns 0 if `ch_handle_pull_conflict` returns 0.
50. The modified `bp_run` returns 1 if `ch_handle_pull_conflict` returns 1.

### Code Quality

51. `conflict_handler.sh` passes `shellcheck` with no errors.
52. `conflict_handler.sh` passes `busybox ash -n` syntax check.
53. No banned BusyBox ash constructs used (see CLAUDE.md table).
54. All six public functions have a brief usage comment at the top of the function body.
55. `conflict_handler.sh` includes a file header comment listing all prerequisites (PAL loaded, `sync_engine.sh` sourced, `cold_start.sh` sourced).
56. All variable expansions are quoted throughout.
57. All git invocations use `$CONTINUITY_GIT_BIN`, not the literal string `git`.
58. All git invocations specify the repo via `-C "$repo_dir"`.
59. All tests pass under `busybox ash`.
60. Test files pass `shellcheck` and `busybox ash -n`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_conflict_handler.sh`)

All unit tests are self-contained. Each test function creates a fresh `TEST_TMPDIR` via `mktemp -d`, initializes a minimal git repo with the required commit history, sources the test PAL and core modules, runs assertions, and removes `TEST_TMPDIR` on EXIT via `trap 'rm -rf "$TEST_TMPDIR"' EXIT`. No network access. All tests run under `busybox ash`.

**Setup pattern:**

```sh
#!/bin/sh
set -e
FIXTURES_DIR="$(dirname "$0")/../../fixtures"
CORE_DIR="$(dirname "$0")/../../../src/core"

run_test() {
    TEST_TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TEST_TMPDIR"' EXIT
    export TEST_TMPDIR
    . "$FIXTURES_DIR/pal_test.sh"
    pal_init
    . "$CORE_DIR/path_mapper.sh"
    pm_load_platform_map "$(pal_get_platform_map)"
    . "$CORE_DIR/sync_engine.sh"
    se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME"
    . "$CORE_DIR/cold_start.sh"
    . "$CORE_DIR/conflict_handler.sh"
}
```

A bare remote at `$TEST_TMPDIR/remote.git` simulates the GitHub repo. The working clone lives at `$CONTINUITY_REPO_DIR`. Commit history is built by making commits in a second worktree (simulating another device) and pushing to the bare remote.

**`ch_preserve_conflict` test cases:**

- Write bytes to `snes/super_metroid.srm` in the repo working tree. Call `ch_preserve_conflict "$CONTINUITY_REPO_DIR" "snes/super_metroid.srm" "my-brick"`. Assert `snes/super_metroid.srm.my-brick.local` exists with identical bytes. Assert `snes/super_metroid.srm.conflict` exists and is valid JSON with all required fields. Assert no new git commit was made.
- Make a commit that touches `snes/super_metroid.srm` with a commit body containing `device: my-deck`. Call `ch_preserve_conflict`. Assert `remote_device` in the JSON is `"my-deck"`.
- Commit touching `snes/super_metroid.srm` with no `device:` trailer. Assert `remote_device` in the JSON is `"unknown"`.
- Make the destination of the `.local` copy unwritable (`chmod 000` on the parent directory). Assert `ch_preserve_conflict` returns 1.

**`ch_list_conflicts` test cases:**

- Create two `.conflict` files in the repo (not committed, just on disk). Assert `ch_list_conflicts` returns both paths.
- Empty repo (no `.conflict` files). Assert returns 0 with no output.
- Create a `.local` file and a `.conflict` file. Assert `ch_list_conflicts` returns only the `.conflict` path, not the `.local` path.
- Create a `.conflict` file inside `.git/` (should be impossible in practice, but test the exclusion). Assert `ch_list_conflicts` does not return it.

**`ch_list_local_files` test cases:**

- Create `snes/super_metroid.srm.my-brick.local` on disk. Assert `ch_list_local_files` returns `snes/super_metroid.srm my-brick`.
- Create multiple `.local` files for different systems and devices. Assert all are returned.
- Empty repo. Assert returns 0 with no output.
- Create `gb/links_awakening.srm.my-deck.local`. Assert device name parsed as `my-deck`, canonical path as `gb/links_awakening.srm`.

**`ch_handle_pull_conflict` test cases:**

Setup: Initialize bare remote. In a second worktree (simulating Device A), commit `snes/zelda.srm` with content "device-a-bytes". In the main working clone (simulating Device B), commit `snes/zelda.srm` with content "device-b-bytes" (diverging from Device A's commit). Device B has NOT fetched Device A's commit.

- Call `ch_handle_pull_conflict "$CONTINUITY_REPO_DIR"` (after manually setting up the diverged state with `git fetch origin` failing to fast-forward). Assert returns 0. Assert `snes/zelda.srm` contains "device-a-bytes" (remote wins). Assert `snes/zelda.srm.test-device.local` contains "device-b-bytes". Assert `snes/zelda.srm.conflict` exists with correct fields. Assert a commit exists containing both artifact files.
- Multiple conflicted files: diverge on both `snes/zelda.srm` and `gb/links_awakening.srm`. Assert both conflicts are preserved in a single commit.
- No `.srm` files differ (only `.continuity/devices/other.json` differs). Assert `ch_handle_pull_conflict` returns 0 with no `.local` or `.conflict` files created. Assert repo is reset to remote.
- Fetch failure: remove network access (use an invalid remote URL). Assert returns 1.
- `pal_on_conflict` defined: define a recording stub. Assert it is called once per conflicted file after commit.
- `pal_on_conflict` not defined (unset): Assert `ch_handle_pull_conflict` completes without error.

**`ch_resolve` test cases (one scenario per resolution mode):**

For each test: set up a committed conflict state (canonical `.srm`, `.local`, and `.conflict` all committed) before calling `ch_resolve`.

- `keep_remote`: Call `ch_resolve "$CONTINUITY_REPO_DIR" "snes/zelda.srm" "keep_remote"`. Assert returns 0. Assert `snes/zelda.srm` content unchanged (remote bytes). Assert `.local` file gone from disk and git index. Assert `.conflict` file gone from disk and git index. Assert new commit in git log. Assert `last_known_commit` updated.
- `keep_local`: Call `ch_resolve` with `keep_local`. Assert `snes/zelda.srm` now contains the bytes that were in the `.local` file. Assert `.local` and `.conflict` removed. Assert new commit.
- `keep_newest` — local is newer: Set `local_timestamp` to `"2026-03-12T15:00:00Z"` and `remote_timestamp` to `"2026-03-12T13:00:00Z"` in the `.conflict` JSON. Assert resolution behaves like `keep_local`.
- `keep_newest` — remote is newer: Set `remote_timestamp` to `"2026-03-12T15:00:00Z"` and `local_timestamp` to `"2026-03-12T13:00:00Z"`. Assert resolution behaves like `keep_remote`.
- `keep_newest` — equal timestamps: Assert resolution behaves like `keep_remote` (remote wins on tie).
- `prompt`: Assert returns 0. Assert no new commit. Assert `.local` and `.conflict` still exist.
- Unknown resolution string: Assert returns 1.
- Missing `.local` file: Assert returns 1.
- Missing `.conflict` file: Assert returns 1.

**`ch_resolve_all` test cases:**

- Two conflicts, `keep_remote` mode: Assert both resolved, returns 0.
- Two conflicts, one `ch_resolve` call fails (stub): Assert `ch_resolve_all` returns 1.
- No conflicts: Assert returns 0 immediately.

### Integration Test (`tests/integration/test_conflict_flow.sh`)

Full end-to-end test using two separate working clones from the same bare remote, simulating two devices. Uses real git operations throughout.

**Setup:**

1. Create `TEST_TMPDIR`. Initialize bare remote at `$TEST_TMPDIR/remote.git` with one initial commit containing `snes/super_metroid.srm` (seeded bytes).
2. Clone to `$TEST_TMPDIR/device-a` (simulates Device A — the device that pushes first).
3. Clone to `$TEST_TMPDIR/device-b` (simulates Device B — the device that pulls and gets a conflict). This is the primary working clone, set as `CONTINUITY_REPO_DIR` for the test PAL.
4. Set `CONTINUITY_DEVICE_NAME="device-b"` in the test PAL environment.
5. Source test PAL, load all modules (path mapper, sync engine, cold start, conflict handler).

**Scenario 1: Two-device conflict — full flow**

1. In `device-a` worktree: write "device-a-progress" to `snes/super_metroid.srm`. `git add`, `git commit -m "snes/super_metroid.srm updated\n\ndevice: device-a"`, `git push origin main`.
2. In `device-b` worktree: write "device-b-progress" to `snes/super_metroid.srm`. `git add`, `git commit -m "snes/super_metroid.srm updated\n\ndevice: device-b"`. (Do NOT push — this creates the diverged state.)
3. Store device-b's current HEAD as `last_known_commit`.
4. Call `ch_handle_pull_conflict "$CONTINUITY_REPO_DIR"`.
5. Assert returns 0.
6. Assert `$CONTINUITY_REPO_DIR/snes/super_metroid.srm` contains "device-a-progress".
7. Assert `$CONTINUITY_REPO_DIR/snes/super_metroid.srm.device-b.local` contains "device-b-progress".
8. Assert `$CONTINUITY_REPO_DIR/snes/super_metroid.srm.conflict` exists.
9. Read `.conflict` JSON: assert `remote_device` is `"device-a"`, `local_device` is `"device-b"`, `status` is `"unresolved"`.
10. Assert bare remote at `$TEST_TMPDIR/remote.git` contains the `.local` and `.conflict` files (push succeeded).
11. Assert `last_known_commit` equals current HEAD.

**Scenario 2: Resolve with `keep_local`**

Continuing from Scenario 1:

12. Call `ch_resolve "$CONTINUITY_REPO_DIR" "snes/super_metroid.srm" "keep_local"`.
13. Assert returns 0.
14. Assert `$CONTINUITY_REPO_DIR/snes/super_metroid.srm` contains "device-b-progress".
15. Assert `.local` file gone from disk.
16. Assert `.conflict` file gone from disk.
17. Assert `git log --oneline` shows a resolution commit as the most recent commit.
18. Assert bare remote contains the resolved canonical file (push happened).

**Scenario 3: Resolve with `keep_newest`**

Set up a fresh conflict (repeat steps 1–4 with new saves). Edit the `.conflict` file to set `remote_timestamp` newer than `local_timestamp`. Call `ch_resolve` with `keep_newest`. Assert resolves as `keep_remote`.

**Scenario 4: `ch_resolve_all`**

Set up two conflicts (`snes/zelda.srm` and `gb/links_awakening.srm`). Call `ch_resolve_all "$CONTINUITY_REPO_DIR" "keep_remote"`. Assert both resolved. Assert `ch_list_conflicts` returns empty output.

**Scenario 5: `boot_pull.sh` integration**

Set up diverged state (same as Scenario 1). Call `bp_run "$CONTINUITY_REPO_DIR"`. Assert returns 0. Assert conflict artifacts are present (the diverged pull triggered `ch_handle_pull_conflict`). Assert no data was silently overwritten.

---

## Definition of Done

- [ ] `src/core/conflict_handler.sh` implemented with all six `ch_*` functions.
- [ ] `ch_handle_pull_conflict` follows the 10-step flow exactly as specified.
- [ ] `ch_preserve_conflict` writes `.local` and `.conflict` files before the `reset --hard` in `ch_handle_pull_conflict` so local bytes are not lost.
- [ ] `.conflict` JSON written via `printf` with no external JSON tool dependency.
- [ ] `keep_newest` uses ISO-8601 lexicographic comparison (no external date arithmetic).
- [ ] `keep_remote`, `keep_local`, `keep_newest` all clean up both `.local` and `.conflict` files from disk and git index, and commit the result.
- [ ] `prompt` resolution makes no changes and returns 0.
- [ ] `ch_resolve_all` iterates all conflicts and returns 1 if any individual resolution fails.
- [ ] `pal_on_conflict` hook called (guarded with `command -v`) after all conflict artifacts committed.
- [ ] `src/core/boot_pull.sh` updated to call `ch_handle_pull_conflict` when `se_pull` returns 1.
- [ ] `src/core/stale_boot.sh` updated similarly if it contains the same diverged-branch placeholder.
- [ ] All variable expansions quoted; no banned BusyBox ash constructs used.
- [ ] `conflict_handler.sh` passes `shellcheck` with no errors.
- [ ] `conflict_handler.sh` passes `busybox ash -n` syntax check.
- [ ] All test files pass `shellcheck` and `busybox ash -n`.
- [ ] Unit tests pass under `busybox ash`.
- [ ] Integration test passes under `busybox ash`.
- [ ] All six functions have a usage comment at the top of the function body.
- [ ] `conflict_handler.sh` file header lists all prerequisites.
- [ ] Sprint summary written to `docs/sprints/sprint-0.8-summary.md` on completion.

---

## Resolved Questions

1. **`se_stage_files` and untracked files.** **Resolved — confirmed safe.** Sprint 0.3's `se_stage_files` uses `git add <path>` (not `git add -u`), which correctly stages untracked files. The Sprint 0.3 spec has been updated with an explicit note clarifying this. Conflict artifacts (`.local`, `.conflict`) will be staged correctly.

2. **Branch name.** **Resolved — hardcoded `main`, validated during enrollment.** Sprint 0.3 enrollment now validates that the cloned repo's default branch is `main`, failing enrollment if it's not. All downstream modules (including this sprint's `conflict_handler.sh`) can safely reference `origin/main`. Configurable branch names deferred to a future sprint.

3. **Multiple `.local` files for the same save (multi-device conflicts).** **Resolved — `ch_resolve` cleans up ALL `.local` files for a given save.** For `keep_local`, `head -1` picks which `.local` file becomes canonical. For `keep_remote`, all `.local` files are simply deleted. All `.local` files matching `<repo_path>.*.local` are removed from both disk and git index during resolution. Multi-device conflict UI (Sprint 1.5) can offer per-device selection with more granularity.

4. **`reset --hard` and uncommitted device saves.** **Resolved — safe.** Analysis confirms no core module leaves uncommitted tracked changes in the repo working tree outside of a `se_commit` call. All local-only files (`sentinel`, `last_known_commit`, `credentials`, `device_name`, `clean_shutdown`) are gitignored. `.local` and `.conflict` artifacts are created by `ch_preserve_conflict` before `reset --hard` and are untracked at that point, so `reset --hard` preserves them. **Invariant:** No core module leaves uncommitted tracked changes in the repo working tree outside of a `se_commit` call.

5. **Cold start `.local` files and this sprint's convention.** **Resolved — naming is consistent.** Sprint 0.4 spec line 87 uses `conflict_name="$repo_path.$CONTINUITY_DEVICE_NAME.local"` and examples show `snes/super_metroid.srm.my-brick.local`. Sprint 0.8 uses the identical convention. The `.srm` extension is part of `$repo_path`, so the full `.local` filename naturally includes `.srm` in both sprints. No changes needed.

6. **`ch_resolve` `keep_remote` pseudocode contradicts itself on staging deletions.** **Resolved — use `git rm --cached`, not `se_stage_files`.** The pseudocode (lines 296–306) calls `se_stage_files` and then `git rm --cached` for the same files. `se_stage_files` uses `git add` which cannot stage a deletion of a removed file. The spec's own implementation note (lines 360–366) clarifies that `git rm --cached` is the correct mechanism for removing conflict artifacts from the index. Implementation will use `rm -f` (disk) + `git rm --cached` (index) + commit — no `se_stage_files` call in resolution paths.

7. **`ch_resolve` step 1 — `$basename` undefined in pseudocode.** **Resolved — derive from `$repo_path`.** The pseudocode references `$basename` without defining it. The intent is to `find` files matching `<filename>.*.local` in the directory containing `$repo_path`. Implementation will derive the basename from `$repo_path` (e.g., `super_metroid.srm` from `snes/super_metroid.srm`) and search in the correct subdirectory within `$repo_dir`.

8. **`local_timestamp` derivation uses current time as fallback.** **Resolved — acceptable.** BusyBox `date` cannot convert epoch timestamps. The spec (lines 220–230) explicitly states that using current time as a fallback is acceptable since the timestamp is informational for conflict resolution UI. Implementation will use `date -u '+%Y-%m-%dT%H:%M:%SZ'`.

9. **Boot pull / stale boot test updates required.** **Resolved — expected.** Existing tests for `bp_run` and `sb_run` assert return code 1 on diverged pull (the pre-Sprint-0.8 placeholder behavior). After Sprint 0.8, the diverged path calls `ch_handle_pull_conflict` instead of returning 1, so these test expectations must be updated. The tests will be modified to verify the new conflict-handling behavior rather than the old placeholder return.
