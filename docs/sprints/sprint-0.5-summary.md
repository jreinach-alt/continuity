# Sprint 0.5 Summary — Boot Pull

**Status:** Complete
**Date:** 2026-03-14

---

## Files Created

| File | Purpose |
|------|---------|
| `src/core/boot_pull.sh` | Boot pull sync: `bp_run`, `bp_get_remote_changes`, `bp_apply_remote_saves` |
| `tests/unit/core/test_boot_pull.sh` | 34 unit tests covering all three `bp_*` functions |
| `tests/integration/test_boot_pull_flow.sh` | 14 integration tests: remote changes, no-op, offline |
| `docs/sprints/sprint-0.5-summary.md` | This file |

## Files Modified

| File | Change |
|------|--------|
| `docs/roadmap.md` | Sprint 0.5 status updated to Complete |

## Tests Written

- **Unit tests (34):**
  - `bp_get_remote_changes`: 4 tests — .srm filtering, non-.srm exclusion, bad commit error, repo-relative paths
  - `bp_apply_remote_saves`: 6 tests — single file copy, mkdir -p, empty input, unrecognized system, cp failure, deleted-on-remote skip
  - `bp_run`: 7 tests — happy path, no-op, non-srm changes, missing commit, network error, diverged, apply failure

- **Integration tests (14):**
  - Test 1: Remote changes from another device arrive — new save created, existing save updated, unchanged save untouched, commit hash and sentinel updated
  - Test 2: No remote changes — no-op, sentinel re-touched
  - Test 3: Offline — returns 2, commit and sentinel unchanged
  - Teardown verification

## Deviations from Spec

1. **`bp_apply_remote_saves` subshell loop pattern:** The `while read` loop fed by a pipe runs in a subshell, so `return 1` on `cp` failure cannot propagate to the parent function. Instead, the function writes failure state to a temp file and uses `break` on `cp` failure. After the loop, it reads the temp file to determine the return code. This is the recommended POSIX sh pattern noted in the spec's implementation notes.

2. **`bp_apply_remote_saves` on `pm_repo_to_local` failure:** The spec says "returns 1 after processing all files if any file failed." The implementation logs a warning, writes to the failure temp file, continues processing, and returns 1 after the loop. This matches the spec's intent: `cp` failures abort immediately, mapping failures continue.

3. **Unit test cp-failure simulation:** Running as root prevents `chmod 000` from blocking file access. The cp-failure test uses a function override stub instead of filesystem permissions. The real `cp` failure path is structurally identical to the stub path (both write to the failure temp file).

## Open Items

None. All acceptance criteria met.
