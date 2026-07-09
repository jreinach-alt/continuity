# Sprint 0.4 — Cold Start Sync — Summary

**Status:** Complete
**Date:** 2026-03-14

## Files Created

| File | Purpose |
|------|---------|
| `src/core/change_detector.sh` | File enumeration: `cd_detect_changes`, `cd_list_repo_saves`, `cd_list_device_saves` |
| `src/core/cold_start.sh` | Cold start sync flow: `cs_run`, `cs_is_cold_start`, `cs_store_commit`, `cs_read_commit`, `cs_create_sentinel` |
| `tests/unit/core/test_change_detector.sh` | Unit tests for change detector (17 tests) |
| `tests/unit/core/test_cold_start.sh` | Unit tests for cold start helpers and `cs_run` scenarios (39 tests) |
| `tests/integration/test_cold_start_flow.sh` | Integration test: full cold start with mixed scenarios (18 tests) |
| `docs/sprints/sprint-0.4-summary.md` | This file |

## Files Modified

| File | Change |
|------|--------|
| `docs/roadmap.md` | Updated Sprint 0.4 status to Complete |

## Directories Created

None.

## Tests Written

| Test File | Pass Count | Runner |
|-----------|-----------|--------|
| `tests/unit/core/test_change_detector.sh` | 17 | busybox ash |
| `tests/unit/core/test_cold_start.sh` | 39 | busybox ash |
| `tests/integration/test_cold_start_flow.sh` | 18 | busybox ash |
| **Total** | **74** | |

All existing tests continue to pass (3218 from prior sprints).

## Deviations from Spec

1. **`cd_detect_changes` uses `-uall` flag:** The spec says `git status --porcelain`, but without `-uall`, git shows untracked directories rather than individual files (e.g., `?? snes/` instead of `?? snes/super_metroid.srm`). Added `-uall` to get individual file paths. This is safe for the Continuity save repo which contains a small number of files.

## Open Items

None. All acceptance criteria met. All tests pass under busybox ash. Shellcheck reports no warnings or errors.
