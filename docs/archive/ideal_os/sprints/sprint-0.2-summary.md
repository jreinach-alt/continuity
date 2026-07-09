# Sprint 0.2 — Implementation Summary

## Files Created
| Path | Purpose |
|------|---------|
| `tests/unit/common/` | Test directory for common module unit tests |
| `src/common/atomic_write.sh` | Atomic file write helper (write → fsync → rename) |
| `src/common/game_identity.sh` | Game ID model: parse, validate, taxonomy, path helpers, SHA-256 hash |
| `src/common/event_bus.sh` | File-based JSONL event bus: init, emit, read (filtered), count, validate |
| `tests/unit/common/test_atomic_write.sh` | 10 tests covering AC 13–16 |
| `tests/unit/common/test_game_identity.sh` | 30 tests covering AC 1–6 |
| `tests/unit/common/test_event_bus.sh` | 28 tests covering AC 7–12 plus fixture validation |
| `tests/fixtures/event_samples.jsonl` | 7 sample events from session, sync, tasks, notifications |

## Files Modified
| Path | What Changed |
|------|--------------|
| `docs/roadmap.md` | Sprint 0.2 status updated to In Progress, removed "(outline)" and "(tentative)" |
| `docs/sprints/sprint-0.2.md` | Status changed from `approved` to `in-progress` |

## Tests Written
| Test | Location | What It Validates |
|------|----------|-------------------|
| `test_atomic_write` | `tests/unit/common/test_atomic_write.sh` | Basic write, overwrite, stdin, file copy, failure cleanup, missing dir/dest/source |
| `test_game_identity` | `tests/unit/common/test_game_identity.sh` | Parse system/name, validate good/bad IDs, path helpers, SHA-256 hash, taxonomy, create |
| `test_event_bus` | `tests/unit/common/test_event_bus.sh` | Init, emit, field presence, source/type/combined filtering, after-offset, count, validate, fixture file |

## Deviations from Spec
| Deviation | Rationale |
|-----------|-----------|
| (None) | Spec was followed exactly. |

## Open Items
- Source guard pattern simplified from `return 0 2>/dev/null || true` (with SC2317 disable) to plain `return 0`. These are library files only ever sourced, so the `|| true` fallback for direct execution was unnecessary and triggered ShellCheck SC2317.
- `busybox fsync` is not available in the dev environment. The `atomic_write.sh` fallback to `sync` is exercised in all tests. On-device testing will verify the `fsync` path.
