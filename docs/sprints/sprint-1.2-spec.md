# Sprint 1.2 — Boot Dispatch

**Status:** Complete — merged to main (PR #3, 2026-07-07)
**Date:** 2026-03-16 (QA'd 2026-07-06)
**Dependencies:** Sprint 1.1 (daemon bootstrap + enrollment), Sprint 0.7 (stale boot), Sprint 0.6 (runtime poll), Sprint 0.5 (boot pull), Sprint 0.4 (cold start)

> **QA note (2026-07-06):** the original implementation predating QA called
> every phase function without the `repo_dir` argument and never consumed
> the clean-shutdown marker — both fixed to match this spec; unit tests
> now pin the dispatch table, argument passing, marker consumption, and
> return-code propagation. See `docs/sprints/sprint-1.1-1.3-summary.md`.

---

## Goal

After enrollment passes, the daemon determines what kind of boot this is and runs the correct sync phase.

Three cases:
1. **Cold start** — No sentinel file. This is the first sync after enrollment. `cs_run` does a full bidirectional merge.
2. **Stale boot** — Sentinel exists but no clean shutdown marker. The previous session ended abnormally (crash, battery pull). `sb_run` pushes pending commits, pulls remote changes, and scans for uncommitted local changes.
3. **Normal boot** — Sentinel exists and clean shutdown marker is present. `bp_run` pulls any remote changes since last known commit.

After boot dispatch completes, the daemon exits. (The poll loop comes in 1.3.) This means we can test each boot scenario end-to-end on-device without worrying about long-running process management yet.

**Key principle:** Boot dispatch failures are non-fatal. If boot pull fails (e.g., offline), the daemon should still be able to proceed to the poll loop (in 1.3). We log the error and continue. Only enrollment failure is fatal.

---

## Reference Specs

- `docs/sprints/sprint-1.1-spec.md` — Daemon skeleton, module loading, enrollment
- `src/core/cold_start.sh` — `cs_run()`, `cs_is_cold_start()` (Sprint 0.4)
- `src/core/boot_pull.sh` — `bp_run()` (Sprint 0.5)
- `src/core/stale_boot.sh` — `sb_run()`, `sb_is_stale()`, `sb_mark_clean_shutdown()` (Sprint 0.7)

---

## Design

### Boot Decision Tree

```
cd_boot_dispatch(repo_dir):
    if cs_is_cold_start(repo_dir) == 0:     # no sentinel
        log "Boot: cold start"
        cs_run(repo_dir)
        return $?
    elif sb_is_stale(repo_dir) == 0:         # sentinel + no clean_shutdown
        log "Boot: stale boot recovery"
        sb_run(repo_dir)
        return $?
    else:                                     # sentinel + clean_shutdown
        log "Boot: normal — pulling remote changes"
        sb_clear_shutdown_marker(repo_dir)    # consumed
        bp_run(repo_dir)
        return $?
```

**Why `sb_clear_shutdown_marker` on normal boot:** The clean shutdown marker is a one-shot signal that the previous session ended cleanly. We consume it on boot so that if *this* session ends abnormally (no marker), the next boot correctly detects a stale state. If we didn't clear it, a crash in this session would leave the marker from the *previous* session, and the next boot would incorrectly skip stale recovery.

**Why boot dispatch is in the platform daemon, not core:** Different platforms may need different boot flows. Android might check a database, RetroDeck might integrate with systemd socket activation, Onion OS might use a different hook mechanism. The decision tree is simple (10 lines) and doesn't justify a core abstraction.

---

## Scope

### `cd_boot_dispatch` — Determine and run the correct boot phase

**Signature:** `cd_boot_dispatch(repo_dir)`

**Parameters:**
- `repo_dir` — absolute path to the local clone of the user's save repo

**Behavior:**
1. If `cs_is_cold_start "$repo_dir"` returns 0:
   - Log: `"Boot: cold start — first sync"`
   - Run `cs_run "$repo_dir"`.
   - Return its exit code.
2. Else if `sb_is_stale "$repo_dir"` returns 0:
   - Log: `"Boot: stale — recovering from unclean shutdown"`
   - Run `sb_run "$repo_dir"`.
   - Return its exit code.
3. Else (normal boot):
   - Log: `"Boot: normal — pulling remote changes"`
   - Call `sb_clear_shutdown_marker "$repo_dir"` (consume the marker).
   - Run `bp_run "$repo_dir"`.
   - Return its exit code.

**Returns:** The exit code of whichever sync phase ran (0 = success, non-zero = error).

### Changes to `cd_main`

Update the `cd_main` function from Sprint 1.1:

**Before Sprint 1.1:**
```
12. Log: "Bootstrap complete"
13. cd_remove_pid; exit 0
```

**After (1.2):**
```
12. Log: "Bootstrap complete, enrolled as $CONTINUITY_DEVICE_NAME"
13. Boot dispatch:
    boot_rc=0
    cd_boot_dispatch "$CONTINUITY_REPO_DIR" || boot_rc=$?
    if [ "$boot_rc" -ne 0 ]; then
        pal_log "warn" "Boot dispatch returned $boot_rc — continuing"
    fi
14. Log: "Boot dispatch complete"
15. cd_remove_pid; exit 0   ← (poll loop replaces this in 1.3)
```

**Error handling:** If boot dispatch returns non-zero, the daemon logs a warning but does NOT exit. This is important for 1.3: a boot pull failure (offline) shouldn't prevent the poll loop from starting. Even in this sub-sprint (where the daemon exits after boot), we establish the pattern.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Runtime poll loop | 1.3 |
| Graceful shutdown (SIGTERM handler) | 1.3 |
| WiFi recovery | 1.4 |
| Log rotation | 1.4 |
| Notifications (pal_on_sync_result) | 1.4 |
| Tool PAK UI | 1.5 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `tests/unit/platforms/nextui/test_daemon_boot.sh` | Unit tests for `cd_boot_dispatch` |
| `tests/integration/test_daemon_boot_dispatch.sh` | Integration tests: cold start, stale boot, normal boot via daemon |
| `docs/sprints/sprint-1.2-spec.md` | This spec |

### Files Modified

| File | Change |
|------|--------|
| `src/platforms/nextui/continuity_daemon.sh` | Add `cd_boot_dispatch` function. Update `cd_main` to call boot dispatch after enrollment. |

---

## Acceptance Criteria

### Boot Dispatch — Phase Selection

1. When sentinel is absent (`cs_is_cold_start` returns 0), `cd_boot_dispatch` calls `cs_run`.
2. When sentinel exists and clean shutdown marker is absent (`sb_is_stale` returns 0), `cd_boot_dispatch` calls `sb_run`.
3. When sentinel exists and clean shutdown marker is present, `cd_boot_dispatch` calls `bp_run`.
4. On normal boot, clean shutdown marker is removed before `bp_run` runs.
5. `cd_boot_dispatch` returns the exit code of the phase that ran.

### Boot Dispatch — Logging

6. `cd_boot_dispatch` logs which phase was selected before running it.
7. Log message includes one of: "cold start", "stale", "normal".

### Boot Dispatch — Error Resilience

8. If `cs_run` returns non-zero, `cd_boot_dispatch` returns that code (does not swallow it).
9. If `sb_run` returns non-zero, `cd_boot_dispatch` returns that code.
10. If `bp_run` returns non-zero, `cd_boot_dispatch` returns that code.
11. After boot dispatch returns non-zero, `cd_main` logs a warning but does NOT exit.

### Cold Start End-to-End

12. After enrollment Sprint 1.1, first boot runs cold start.
13. Cold start syncs device saves to repo and repo saves to device.
14. Sentinel file is created after cold start.
15. Commit hash is stored after cold start.

### Stale Boot End-to-End

16. After killing the daemon (simulating crash — no clean_shutdown marker), next boot detects stale state.
17. Stale boot pushes any pending commits from the interrupted session.
18. Stale boot pulls remote changes.
19. Stale boot scans for local changes missed during interrupted session.
20. Sentinel is updated after stale boot.

### Normal Boot End-to-End

21. After clean exit (clean_shutdown marker present), next boot runs boot pull.
22. Boot pull fetches and applies remote changes.
23. Clean shutdown marker is consumed (deleted) at boot.
24. If no remote changes, boot pull is a no-op.

### Code Quality

25. All new code passes `shellcheck` with no errors.
26. All new code passes `busybox ash -n` syntax check.
27. No banned BusyBox ash constructs.
28. All variable expansions are quoted.
29. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests (`tests/unit/platforms/nextui/test_daemon_boot.sh`)

Source the daemon script, mock core phase functions, verify dispatch logic.

**Phase selection tests (mocked):**
- No sentinel: mock `cs_is_cold_start` returns 0, define a flag-setting `cs_run`. Call `cd_boot_dispatch`. Verify `cs_run` flag set, `sb_run`/`bp_run` flags not set.
- Sentinel + no clean_shutdown: mock `cs_is_cold_start` returns 1, `sb_is_stale` returns 0, define flag-setting `sb_run`. Verify `sb_run` called.
- Sentinel + clean_shutdown: mock both to return 1, define flag-setting `bp_run`. Verify `bp_run` called.
- Clean shutdown marker consumed: in the normal boot case, verify the clean_shutdown file is deleted after `cd_boot_dispatch`.

**Return code propagation tests:**
- Mock `cs_run` to return 1. Verify `cd_boot_dispatch` returns 1.
- Mock `bp_run` to return 2. Verify `cd_boot_dispatch` returns 2.

### Integration Tests (`tests/integration/test_daemon_boot_dispatch.sh`)

**Setup:** Create bare remote repo, enroll a test device (via test enrollment helper), set up device saves directory.

**Scenario 1: Cold start after enrollment**
1. Enroll device (creates repo clone, no sentinel).
2. Create a device save file.
3. Call `cd_boot_dispatch "$repo_dir"`.
4. Verify `cs_run` executed: save committed and pushed to remote.
5. Verify sentinel file created.
6. Verify commit hash stored.

**Scenario 2: Normal boot pull**
1. After Scenario 1, create clean shutdown marker: `sb_mark_clean_shutdown "$repo_dir"`.
2. Push a new save from a "second device" (second clone of the same repo).
3. Call `cd_boot_dispatch "$repo_dir"`.
4. Verify `bp_run` executed: new save copied to device.
5. Verify clean shutdown marker no longer exists.

**Scenario 3: Stale boot recovery**
1. After Scenario 2, do NOT create clean shutdown marker (simulating crash).
2. Create a device save that differs from repo.
3. Call `cd_boot_dispatch "$repo_dir"`.
4. Verify `sb_run` executed: catch-up scan detects the changed save.
5. Verify changed save committed and pushed.

**Scenario 4: Boot dispatch with offline boot pull**
1. Set up for normal boot, but mock `pal_is_online` to return 1.
2. Call `cd_boot_dispatch "$repo_dir"`.
3. Verify returns non-zero (bp_run reports network error).
4. Verify daemon's error-handling code would log a warning (not exit).

### On-Device Test Checklist

| # | Test | Steps | Expected |
|---|------|-------|----------|
| D1 | Cold start on first boot | Enroll via setup.json Sprint 1.1, then power off and on | Log shows "Boot: cold start." Saves synced to repo. Sentinel exists. |
| D2 | Normal boot pull | Push a save from another device. Power on Brick. | Log shows "Boot: normal." New save appears on device. |
| D3 | Stale boot recovery | SSH in, `kill -9` the daemon PID, reboot | Log shows "Boot: stale." Pending changes caught up. |
| D4 | Boot offline resilience | Disable WiFi before boot (or boot out of WiFi range) | Log shows boot dispatch warning. Daemon doesn't crash. |

---

## Definition of Done

- [ ] `cd_boot_dispatch` implemented: correctly selects cold start, stale boot, or boot pull.
- [ ] `cd_main` updated to call boot dispatch after enrollment.
- [ ] Clean shutdown marker consumed on normal boot.
- [ ] Boot dispatch errors are logged but do not prevent daemon from continuing.
- [ ] Unit tests cover all three boot paths + error propagation.
- [ ] Integration tests cover: cold start end-to-end, normal boot pull, stale boot recovery, offline resilience.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] On-device test checklist documented.
- [ ] Sprint summary written to `docs/sprints/sprint-1.2-summary.md` on completion.
