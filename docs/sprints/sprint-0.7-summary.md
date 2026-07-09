# Sprint 0.7 Summary — Stale Boot Recovery

**Date:** 2026-03-15
**Status:** Complete

---

## Files Created

| File | Purpose |
|------|---------|
| `src/core/stale_boot.sh` | Stale boot recovery: `sb_run`, `sb_is_stale`, `sb_mark_clean_shutdown`, `sb_clear_shutdown_marker` |
| `tests/unit/core/test_stale_boot.sh` | Unit tests for all four `sb_*` functions (47 assertions) |
| `tests/integration/test_stale_boot_flow.sh` | Integration test: 5 scenarios with real git operations (31 assertions) |

## Files Modified

| File | Change |
|------|--------|
| `src/core/cold_start.sh` | Added error handling to `cs_store_commit` and `cs_create_sentinel` — both now check `mkdir -p` and file write for failure, returning 1 on error. Pre-existing defect from Sprint 0.4. |
| `docs/sprints/sprint-0.7-spec.md` | Status changed to Approved. Step 2 updated to document `se_push` return code 2 (offline race) as non-fatal. |
| `docs/roadmap.md` | Sprint 0.7 status updated to Complete. |

## Tests Written

### Unit Tests (`tests/unit/core/test_stale_boot.sh`)

**`sb_is_stale` (5 tests):**
- Sentinel absent, marker absent: returns 1 (not stale)
- Sentinel present, marker absent: returns 0 (stale)
- Sentinel present, marker present: returns 1 (not stale)
- Sentinel absent, marker present: returns 1 (not stale)
- Does not modify any files when called

**`sb_mark_clean_shutdown` (3 tests):**
- Creates `.continuity/` directory and marker file, returns 0
- Overwrites existing marker (idempotent), returns 0
- After marking, `sb_is_stale` returns 1

**`sb_clear_shutdown_marker` (3 tests):**
- Removes marker when present, returns 0
- Returns 0 when marker already absent (idempotent)
- After clearing with sentinel present, `sb_is_stale` returns 0

**`sb_run` (12 tests):**
- No stored commit: returns 1, does not call `se_pull`
- Offline, device has local changes: commits locally, does not push, sentinel updated
- Online, unpushed commits: push called before pull (order verified via stub)
- Online, unpushed commits, pre-pull push fails: logs warning, continues (non-fatal)
- Remote has new saves: applied to device, stored commit updated
- Remote unchanged, device has local changes: catch-up commit made and pushed
- Remote unchanged, device unchanged: no-op, no commit, sentinel updated
- Diverged remote (`se_pull` returns 1): returns 1, catch-up scan not executed
- Unknown system directory on device: warning logged, valid saves still processed
- Repo-only file not on device: left untouched in repo
- `se_commit` fails during catch-up: returns 1, sentinel not updated
- Marker cleared even when later steps fail (diverged pull)

### Integration Test (`tests/integration/test_stale_boot_flow.sh`)

5 scenarios using real git operations with a local bare remote:

1. **Remote changes only** — another device pushed new and updated saves; `sb_run` pulls and applies them to device, updates stored commit, verifies idempotency on re-run
2. **Local changes only** — device save modified after crash; catch-up scan detects it, commits with "stale boot catch-up" message, pushes to remote
3. **Both remote and local changes (different files)** — new remote save applied inbound, local change committed outbound, both directions succeed in one recovery run
4. **Clean boot detection** — `sb_mark_clean_shutdown` sets marker, `sb_is_stale` returns 1 (not stale, boot pull should run instead)
5. **Offline, local changes only** — commit made locally, push skipped, remote not updated, sentinel updated

## Deviations from Spec

None. On re-examination, the Step 5 `cs_store_commit` call is outside the `If pal_is_online` guard in the spec pseudocode (line 132–133, same indentation as `se_commit` on line 126). The implementation matches exactly: `cs_store_commit` runs unconditionally after the commit, regardless of whether the push happened. No deviation.

## Open Items

None. All acceptance criteria met. Ready for Sprint 0.8 (Conflict Handler).
