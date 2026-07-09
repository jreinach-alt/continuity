# Sprint 0.9 Summary — Conflict Resolution Operations

**Date:** 2026-03-15
**Status:** Complete

---

## Files Created

| File | Purpose |
|------|---------|
| `tests/unit/core/test_conflict_ops.sh` | 80 unit tests for all new `ch_*` functions |
| `tests/integration/test_conflict_resolution_flow.sh` | 32 integration tests: Browse→Try→Resolve, keep_newest, multiple conflicts, Pokémon scenario |

## Files Modified

| File | Change |
|------|--------|
| `src/core/conflict_handler.sh` | Added 9 new functions (`ch_get_conflict_info`, `ch_list_conflicts_detailed`, `ch_count_conflicts`, `ch_try_version`, `ch_get_active_version`, `ch_clear_try_markers`, `ch_is_trying`, `ch_is_trying_modified`, `ch_promote_trying`) plus 3 internal helpers (`_ch_marker_name`, `_ch_marker_path`). Modified `ch_resolve` to update device save and clean try markers post-resolution. |
| `src/core/runtime_poll.sh` | Added trying-state check in `rp_confirm_changes` to skip files in trying state. Added `conflict_handler: ch_is_trying()` to module dependency comment. Uses `command -v` guard for backward compatibility. |
| `docs/design/architecture.md` | Added "Interactive Resolution Operations" subsection under Conflict Resolution Strategy, documenting try markers, key-value output format, and sync pipeline safety. |
| `docs/sprints/sprint-0.9-spec.md` | Resolved all open questions and preflight blockers (cksum→md5sum, .local discovery, trying_modified optimization). |

## Tests Written

- **Unit tests:** 80 tests covering all new functions, validation, idempotency, error cases
- **Integration tests:** 32 tests covering 4 full scenarios including the Pokémon scenario
- **Regression:** All existing tests pass (96 conflict_handler + 45 runtime_poll + 30 conflict_flow)

## Deviations from Spec

1. **`.gitignore` content:** Spec said `*` only. Implementation uses `*\n!.gitignore` so the `.gitignore` itself can be committed (a `.gitignore` containing only `*` ignores itself, preventing `git add`).

2. **`rp_confirm_changes` guard:** Added `command -v ch_is_trying` check before calling `ch_is_trying`, so `runtime_poll.sh` doesn't break if loaded without `conflict_handler.sh` sourced (backward compatibility with tests that don't source all modules).

3. **`md5sum` instead of `cksum`:** Per preflight finding — `cksum` is not available as a BusyBox applet. `md5sum` is available in both BusyBox and coreutils with identical output format. Marker stores 32-char hex digest instead of CRC+size.

## Open Items

None. All acceptance criteria met.
