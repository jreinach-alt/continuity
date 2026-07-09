# Sprint 0.8 Summary — Conflict Handler

**Status:** Complete
**Date:** 2026-03-15

---

## Files Created

| File | Purpose |
|------|---------|
| `src/core/conflict_handler.sh` | Conflict detection, preservation, enumeration, and resolution (6 public functions: `ch_handle_pull_conflict`, `ch_preserve_conflict`, `ch_list_conflicts`, `ch_list_local_files`, `ch_resolve`, `ch_resolve_all`) |
| `tests/unit/core/test_conflict_handler.sh` | 96 unit test assertions covering all 6 functions |
| `tests/integration/test_conflict_flow.sh` | 30 integration test assertions across 5 end-to-end scenarios |

## Files Modified

| File | Change |
|------|--------|
| `src/core/boot_pull.sh` | Replaced diverged-branch placeholder (`return 1`) with `ch_handle_pull_conflict` call. Returns 0 on success, 1 on handler failure. |
| `src/core/stale_boot.sh` | Same change — replaced diverged-branch placeholder with `ch_handle_pull_conflict` call. Falls through to catch-up scan on success (no early return). |
| `tests/unit/core/test_boot_pull.sh` | Updated diverged-pull test to stub `ch_handle_pull_conflict` (success and failure cases). Added `conflict_handler.sh` source. |
| `tests/unit/core/test_stale_boot.sh` | Updated diverged-pull tests similarly. Added `conflict_handler.sh` source. |

## Tests Written

- **Unit tests:** 96 assertions across `ch_preserve_conflict` (8), `ch_list_conflicts` (6), `ch_list_local_files` (6), `ch_handle_pull_conflict` (26), `ch_resolve` (37), `ch_resolve_all` (7), plus additional index verification assertions.
- **Integration tests:** 30 assertions across 5 scenarios: two-device conflict, resolve with `keep_local`, resolve with `keep_newest`, `ch_resolve_all` with multiple conflicts, and `boot_pull.sh` integration.
- All tests pass under `busybox ash`.
- All source and test files pass `shellcheck` and `busybox ash -n`.

## Deviations from Spec

1. **Stage list temp file location:** The spec's pseudocode implies building `stage_list` in a `while` loop. Because `printf | while` runs in a subshell in POSIX sh, the variable cannot escape. Implementation uses `mktemp` for the temp file instead of `$repo_dir/.continuity/_ch_stage_list` to avoid the file being affected by `reset --hard origin/main` (which can remove untracked directories if their parent was involved in the reset).

2. **`ch_resolve` `se_stage_files` not used:** Per resolved question #6 in the spec, resolution paths use `rm -f` (disk) + `git rm --cached` (index) + `git add` (for `keep_local` canonical update) + commit. `se_stage_files` is not called in resolution paths because `git add` cannot stage file deletions.

3. **`stale_boot.sh` does not `return 0` early:** Unlike `boot_pull.sh` which returns 0 immediately after the conflict handler, `stale_boot.sh` falls through to continue the catch-up scan. This ensures uncommitted local changes from a crashed session are not lost.

## Open Items

- **Sentinel mtime after boot_pull conflict resolution:** The `return 0` in boot_pull skips the sentinel touch. The runtime poll's next `find -newer` scan may detect repo `.srm` files as "changed." This is a Sprint 1.1 (daemon lifecycle) concern — the daemon should check for unresolved conflicts before syncing.
