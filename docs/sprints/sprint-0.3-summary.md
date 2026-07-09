# Sprint 0.3 — Enrollment — Summary

**Status:** Complete
**Date:** 2026-03-14

## Files Created

| File | Purpose |
|------|---------|
| `src/core/sync_engine.sh` | Git operations layer: clone, pull, push, stage, commit, status queries |
| `src/core/enrollment.sh` | Platform-agnostic enrollment: clone, credential storage, device registration, git auth config |
| `src/platforms/nextui/enroll_sd_card.sh` | NextUI SD card enrollment trigger: detect, parse, import `setup.json` |
| `tests/fixtures/enroll_test.sh` | Test enrollment helper: bare remote creation, seeded saves, scripted enrollment for CI |
| `tests/unit/core/test_sync_engine.sh` | Unit tests for sync engine (26 tests) |
| `tests/unit/core/test_enrollment.sh` | Unit tests for core enrollment (43 tests) |
| `tests/unit/nextui/test_enroll_sd_card.sh` | Unit tests for SD card trigger (16 tests) |
| `tests/integration/test_enrollment_flow.sh` | Integration test: full enrollment + pull flow (19 tests) |
| `docs/sprints/sprint-0.3-summary.md` | This file |

## Files Modified

| File | Change |
|------|--------|
| `tests/fixtures/pal_test.sh` | Fixed `pal_init()` to create `$(dirname "$CONTINUITY_REPO_DIR")` instead of `$CONTINUITY_REPO_DIR` itself (clone-safe) |
| `docs/design/pal.md` | Updated test PAL example to match the `pal_init()` fix |

## Directories Created

| Directory | Purpose |
|-----------|---------|
| `tests/unit/nextui/` | Unit tests for NextUI platform modules |

## Tests Written

| Test File | Pass Count | Runner |
|-----------|-----------|--------|
| `tests/unit/core/test_sync_engine.sh` | 26 | busybox ash |
| `tests/unit/core/test_enrollment.sh` | 43 | busybox ash |
| `tests/unit/nextui/test_enroll_sd_card.sh` | 16 | busybox ash |
| `tests/integration/test_enrollment_flow.sh` | 19 | busybox ash |
| **Total** | **104** | |

All existing tests continue to pass (test_pal_validate: 3073, test_path_mapper: 41).

## Deviations from Spec

1. **`se_init` disables commit signing:** Added `commit.gpgsign false` to repo-local git config in `se_init`. Constrained devices (BusyBox ash targets) have no GPG or SSH signing capability. Without this, git commit fails if the system-wide git config enables signing.

2. **`se_init` checks local config only:** Uses `--local` flag when checking if `user.email` is already set, to avoid inheriting global git config values that may not apply to the Continuity repo.

3. **Test files disable commit signing via environment:** All test scripts set `GIT_CONFIG_COUNT=1` with `commit.gpgsign=false` to prevent interference from the CI environment's global git config.

## Open Items

None. All acceptance criteria met. All tests pass under busybox ash. Shellcheck reports no warnings or errors.
