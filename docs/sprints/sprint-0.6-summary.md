# Sprint 0.6 Summary — Runtime Poll

**Date:** 2026-03-14
**Status:** Complete

---

## Files Created

| File | Purpose |
|------|---------|
| `src/core/runtime_poll.sh` | Runtime poll cycle: `rp_run`, `rp_find_candidates`, `rp_confirm_changes`, `rp_update_sentinel` |
| `tests/unit/core/test_runtime_poll.sh` | Unit tests for all four `rp_*` functions (45 assertions) |
| `tests/integration/test_runtime_poll_flow.sh` | Integration test: 5 scenarios with real git operations |

## Files Modified

None. All prior sprint outputs used as-is. (Note: `sync_engine.sh` and `cold_start.sh` received a hardening fix in a separate commit prior to this sprint, fixing the `se_stage_files` subshell return code bug and adding `cp` error checking to `cs_run`.)

## Tests Written

### Unit Tests (`tests/unit/core/test_runtime_poll.sh`)

**`rp_find_candidates` (5 tests):**
- New `.srm` file newer than sentinel is returned
- No new files returns empty with rc 0
- File older than sentinel not returned
- Missing `$CONTINUITY_SAVES_ROOT` returns empty with rc 0
- Non-`.srm` file not returned

**`rp_confirm_changes` (6 tests):**
- Different file printed as confirmed
- Identical file not printed
- New file (no repo copy) printed as confirmed
- Unknown system directory skipped with warning
- Empty candidates returns empty with rc 0
- Mixed candidates: only differing ones printed

**`rp_update_sentinel` (2 tests):**
- Successful update returns 0, mtime advances
- Read-only directory returns 1 (skipped when running as root)

**`rp_run` (10 tests):**
- No candidates: returns 0, no commit, sentinel unchanged
- All false positives: returns 0, no commit, sentinel updated
- One confirmed change online: commits, pushes, updates sentinel and last_known_commit
- One confirmed change offline: commits locally, push not called
- New device file: appears in repo with commit
- Missing sentinel: returns 1
- `se_commit` failure: returns 1, sentinel not updated
- Idempotency: second call produces no new commit
- Unknown system dir with valid files: returns 0, only valid file committed
- `cd_detect_changes` returns empty after copy: returns 0, no commit, sentinel updated

### Integration Test (`tests/integration/test_runtime_poll_flow.sh`)

5 scenarios using real git operations with a local bare remote:

1. **Single file change** — new bytes synced to repo and pushed to remote
2. **No-op** — immediate re-run produces no new commit
3. **New device-only save** — new file appears in repo with descriptive commit
4. **Multiple files** — two files changed in one cycle, commit says "N saves updated"
5. **FAT32 false positive** — identical bytes with newer mtime filtered out, no commit

## Deviations from Spec

1. **`rp_run` step 4 uses temp file for cp failure propagation.** The spec doesn't specify error handling for the copy loop, but consistent with the hardening pattern applied to `cold_start.sh`, a temp file is used to surface `cp` failures across the subshell boundary created by piped `while read`.

2. **`rp_update_sentinel` read-only test skipped as root.** The CI environment runs as root where `chmod 555` does not prevent writes. The test is skipped with a pass count when `id -u` is 0.

## Open Items

None. All acceptance criteria met. Ready for Sprint 0.7 (Stale Boot Recovery).
