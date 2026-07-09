# Sprint 1.3 — Poll Loop + Graceful Shutdown

**Status:** Complete — merged to main (PR #3, 2026-07-07)
**Date:** 2026-03-16 (QA'd 2026-07-06)
**Dependencies:** Sprint 1.2 (boot dispatch), Sprint 0.6 (runtime poll)

> **QA note (2026-07-06):** implemented with `CONTINUITY_POLL_INTERVAL`
> (env-overridable for tests, default 30) rather than `CD_POLL_INTERVAL`.
> The conditional clean-shutdown-marker rule ("push first; only mark clean
> when nothing unpushed remains") is implemented and pinned by unit tests,
> including the push-failure and offline paths. The WiFi-recovery push at
> the top of the poll loop (a Sprint 1.4 item) is already present. See
> `docs/sprints/sprint-1.1-1.3-summary.md`.

---

## Goal

Turn the daemon from a "boot and exit" script into a long-running background process.

After boot dispatch completes, the daemon enters a poll loop: every 30 seconds, it calls `rp_run` to check for save changes, commit them, and push if online. When the user powers off the Brick, NextUI sends SIGTERM to all processes. The daemon catches it, does a final push of any queued commits, writes a clean shutdown marker (so the next boot knows the previous session ended cleanly), removes the PID file, and exits.

After this sprint, the daemon is fully functional for the happy path: boot → sync → play → save → synced within 30s → power off → clean shutdown. WiFi recovery and notifications are in 1.4.

---

## Reference Specs

- `docs/sprints/sprint-1.1-spec.md` — Daemon skeleton, PID management
- `docs/sprints/sprint-1.2-spec.md` — Boot dispatch
- `src/core/runtime_poll.sh` — `rp_run()` (Sprint 0.6)
- `src/core/stale_boot.sh` — `sb_mark_clean_shutdown()` (Sprint 0.7)
- `src/core/sync_engine.sh` — `se_push()`, `se_has_unpushed_commits()` (Sprint 0.3)

---

## Design

### Why 30 Seconds

The poll interval is a tradeoff:
- **Too fast (5s):** Hammers the SD card with `find` scans. Burns battery. Most polls find nothing.
- **Too slow (5m):** User saves, switches games, and doesn't see their save synced before they power off.
- **30s:** The user saves Pokémon, keeps playing for 30 seconds (they were going to anyway), and their save is pushed. If they power off within 30s, the shutdown handler catches it.

The interval is a constant (`CD_POLL_INTERVAL=30`), not configurable. Simplicity for v0.1.

### Shutdown Ordering

```
SIGTERM received
  1. Log "Shutdown: SIGTERM received"
  2. Push queued commits (if online + unpushed)
  3. Mark clean shutdown (sb_mark_clean_shutdown)
  4. Remove PID file
  5. Log "Shutdown: complete"
  6. exit 0
```

**Why push before marking clean shutdown:** If we mark clean shutdown first and then push fails, the next boot will think the previous session was clean and skip stale recovery. But there may be unpushed commits. By pushing first, we maximize the chance of a truly clean state. If push fails, we still mark clean shutdown — the unpushed commits will be caught by stale boot's `se_has_unpushed_commits` check, which runs early in `sb_run`.

Wait — that's wrong. If push fails and we mark clean, the next boot sees clean_shutdown marker, runs `bp_run` (not `sb_run`), and `bp_run` doesn't push pending commits. The unpushed commits would sit until the next `rp_run` pushes them. That's acceptable: the commits are safe locally, and the next poll cycle handles them. The alternative — not marking clean shutdown after push failure — means every post-failure boot goes through stale recovery, which is heavier. Clean shutdown + unpushed commits is a lighter recovery path.

**Actually, let's reconsider.** If push fails, we should NOT mark clean shutdown. This way, the next boot runs stale recovery, which explicitly pushes pending commits in Step 2 before doing anything else. This is the correct behavior:

```
SIGTERM received
  1. Log "Shutdown: SIGTERM received"
  2. Push queued commits (if online + unpushed)
  3. If push succeeded or nothing to push:
     → sb_mark_clean_shutdown
  4. If push failed or offline with unpushed:
     → do NOT mark clean (next boot = stale recovery)
  5. Remove PID file
  6. Log "Shutdown: complete"
  7. exit 0
```

This ensures unpushed commits are never silently forgotten.

### Signal Handling in BusyBox ash

`trap` in BusyBox ash works with signal names (`TERM`, `INT`, `HUP`) and numbers. `sleep` is interruptible by signals — when SIGTERM arrives during `sleep 30`, the signal is delivered after the current foreground command (`sleep`) is interrupted. The trap handler fires immediately.

**Important:** The trap is set AFTER boot dispatch completes. If SIGTERM arrives during boot dispatch, we want the boot phase to finish (or fail) naturally, not be interrupted by the shutdown handler writing a clean shutdown marker mid-boot.

---

## Scope

### Part 1: Poll Loop

#### `cd_poll_loop` — Main runtime poll loop

**Signature:** `cd_poll_loop(repo_dir)`

**Parameters:**
- `repo_dir` — absolute path to local clone

**Behavior:**
```sh
while true; do
    rp_run "$repo_dir" || pal_log "warn" "Poll cycle failed (rc=$?)"
    sleep "$CD_POLL_INTERVAL"
done
```

**Constants:**
- `CD_POLL_INTERVAL=30` — seconds between poll cycles.

**Error handling:** If `rp_run` returns non-zero, log the error and continue. The poll loop never exits on its own. Only SIGTERM (or SIGKILL) stops it.

**Note:** WiFi recovery and log rotation are added to the loop body in Sprint 1.4. For now, the loop is just `rp_run` + `sleep`.

---

### Part 2: Graceful Shutdown

#### `cd_shutdown` — SIGTERM handler

**Signature:** `cd_shutdown()` (called by `trap`)

Uses `_CD_REPO_DIR` (set by `cd_main` before entering the poll loop, since trap handlers can't take parameters).

**Behavior:**
1. Log: `"Shutdown: SIGTERM received, starting graceful shutdown"`.
2. Check for unpushed commits:
   - `se_has_unpushed_commits "$_CD_REPO_DIR"` → if returns 1 (nothing to push), skip to step 4.
3. If unpushed commits exist:
   - If `pal_is_online`:
     - `se_push "$_CD_REPO_DIR"` → capture exit code.
     - If rc=0: log `"Shutdown: pushed queued commits"`. Set `_cd_push_clean=true`.
     - If rc=1: log `"Shutdown: push failed"`. Set `_cd_push_clean=false`.
     - If rc=2: log `"Shutdown: offline — commits queued for next boot"`. Set `_cd_push_clean=false`.
   - If not online:
     - Log `"Shutdown: offline — commits queued for next boot"`.
     - Set `_cd_push_clean=false`.
4. Mark clean shutdown (conditional):
   - If no unpushed commits existed, OR push succeeded (`_cd_push_clean=true`):
     - `sb_mark_clean_shutdown "$_CD_REPO_DIR"`.
     - Log: `"Shutdown: marked clean"`.
   - If unpushed commits exist and push failed/skipped:
     - Do NOT mark clean. Log: `"Shutdown: skipping clean marker — unpushed commits remain"`.
5. Remove PID file: `cd_remove_pid`.
6. Log: `"Shutdown: complete"`.
7. `exit 0`.

**Returns:** Does not return (calls `exit 0`).

### Trap Setup in `cd_main`

**Wiring:** After boot dispatch, before entering the poll loop:

```sh
_CD_REPO_DIR="$CONTINUITY_REPO_DIR"
trap cd_shutdown TERM
```

`_CD_REPO_DIR` is a module-level variable so the trap handler can access the repo dir.

### Changes to `cd_main`

Update `cd_main` from Sprint 1.2:

**Before (1.2):**
```
14. Log: "Boot dispatch complete"
15. cd_remove_pid; exit 0
```

**After (1.3):**
```
14. Log: "Boot dispatch complete, entering poll loop"
15. Set _CD_REPO_DIR="$CONTINUITY_REPO_DIR"
16. Set trap: trap cd_shutdown TERM
17. cd_poll_loop "$CONTINUITY_REPO_DIR"
    # poll_loop never returns — exits via trap or signal
```

---

## Out of Scope

| Item | Sprint |
|------|--------|
| WiFi recovery (push queued commits in poll loop) | 1.4 |
| Log rotation | 1.4 |
| Notifications (pal_on_sync_result) | 1.4 |
| Tool PAK UI | 1.5 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `tests/unit/platforms/nextui/test_daemon_poll.sh` | Unit tests for `cd_poll_loop` behavior (mocked) and `cd_shutdown` |
| `tests/integration/test_daemon_runtime.sh` | Integration test: boot → poll → detect change → sync → shutdown |
| `docs/sprints/sprint-1.3-spec.md` | This spec |

### Files Modified

| File | Change |
|------|--------|
| `src/platforms/nextui/continuity_daemon.sh` | Add `cd_poll_loop`, `cd_shutdown`, `CD_POLL_INTERVAL`. Update `cd_main` to set trap and enter poll loop instead of exiting. |

---

## Acceptance Criteria

### Poll Loop

1. `cd_poll_loop` calls `rp_run` on each iteration.
2. Loop sleeps `CD_POLL_INTERVAL` (30) seconds between cycles.
3. If `rp_run` returns non-zero, loop logs the error and continues to next cycle.
4. Poll loop runs indefinitely until interrupted by signal.

### Graceful Shutdown — SIGTERM

5. SIGTERM triggers `cd_shutdown` handler.
6. SIGTERM during `sleep` interrupts sleep immediately (handler fires, no waiting for remaining interval).
7. Shutdown handler logs that SIGTERM was received.

### Graceful Shutdown — Final Push

8. If online and unpushed commits exist, shutdown handler calls `se_push`.
9. If push succeeds, shutdown handler logs success.
10. If push fails (rc=1), shutdown handler logs failure.
11. If offline or push gets network error (rc=2), shutdown handler logs that commits are queued.
12. If no unpushed commits, push step is skipped.

### Graceful Shutdown — Clean Shutdown Marker

13. If no unpushed commits existed, clean shutdown marker is written.
14. If push succeeded, clean shutdown marker is written.
15. If push failed or was skipped (offline with unpushed), clean shutdown marker is NOT written.
16. When clean shutdown marker is not written, the next boot detects stale state.

### Graceful Shutdown — Cleanup

17. Shutdown handler removes PID file.
18. Shutdown handler exits with code 0.

### Trap Timing

19. SIGTERM trap is set AFTER boot dispatch completes.
20. SIGTERM during boot dispatch does NOT trigger the shutdown handler (boot phase completes or fails naturally).

### Integration — Full Lifecycle

21. After boot dispatch, daemon enters poll loop.
22. Save file change on device is detected and synced within one poll cycle.
23. After SIGTERM, daemon exits cleanly within a few seconds.
24. After clean shutdown + reboot, boot dispatch selects boot pull (not stale boot).
25. After unclean shutdown (SIGKILL) + reboot, boot dispatch selects stale boot.

### Code Quality

26. All new code passes `shellcheck` with no errors.
27. All new code passes `busybox ash -n` syntax check.
28. No banned BusyBox ash constructs.
29. All variable expansions are quoted.
30. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests (`tests/unit/platforms/nextui/test_daemon_poll.sh`)

**Poll loop tests (mocked):**

Testing an infinite loop requires a trick: override `rp_run` to count invocations and exit after N calls.

- Loop calls `rp_run`: mock `rp_run` to increment a counter and call `exit 0` after 3 calls. Verify counter = 3.
- Loop survives `rp_run` error: mock `rp_run` to return 1 on first call, 0 on second, `exit 0` on third. Verify all three calls happened (error didn't break the loop).
- Poll interval: mock `sleep` to record its argument. Verify it's called with `30`.

**Shutdown tests:**

- Final push — happy path: set `_CD_REPO_DIR` to a test repo with unpushed commits. Mock `pal_is_online` (return 0), `se_push` (return 0). Call `cd_shutdown` in a subshell (to capture exit). Verify push was called, clean shutdown marker exists, PID file removed.
- Final push — offline: mock `pal_is_online` (return 1). Call `cd_shutdown`. Verify push NOT called, clean shutdown marker does NOT exist (unpushed commits remain), PID file removed.
- Final push — push failure: mock `se_push` (return 1). Call `cd_shutdown`. Verify clean shutdown marker does NOT exist.
- Nothing to push: mock `se_has_unpushed_commits` (return 1). Call `cd_shutdown`. Verify push NOT called, clean shutdown marker written.

### Integration Tests (`tests/integration/test_daemon_runtime.sh`)

**Setup:** Enrolled device with completed cold start (sentinel exists, commit hash stored). Create clean shutdown marker so boot dispatch selects boot pull.

**Scenario 1: Poll detects and syncs a save change**
1. Set up enrolled device with sentinel (post-cold-start state).
2. Create clean shutdown marker.
3. Run boot dispatch (boot pull, no remote changes — no-op).
4. Create a new save file on "device."
5. Call `rp_run "$repo_dir"` directly (not the full loop — testing one cycle).
6. Verify save committed and pushed to remote.

**Scenario 2: Clean shutdown after poll**
1. After Scenario 1, set `_CD_REPO_DIR`.
2. Call `cd_shutdown` (in subshell to capture exit).
3. Verify clean shutdown marker exists.
4. Verify PID file removed.
5. Set up new boot: call `cd_boot_dispatch`.
6. Verify boot pull selected (not stale boot).

**Scenario 3: Unclean shutdown — no marker**
1. After Scenario 1, do NOT call `cd_shutdown`. (Simulate crash.)
2. Verify clean_shutdown marker does not exist.
3. Call `cd_boot_dispatch`.
4. Verify stale boot selected.

**Scenario 4: Shutdown with unpushed commits (offline)**
1. Mock `pal_is_online` to return 1 (offline).
2. Create a save change, run `rp_run` → committed locally.
3. Call `cd_shutdown` (in subshell).
4. Verify clean shutdown marker does NOT exist (unpushed commits).
5. Switch mock to online.
6. Call `cd_boot_dispatch`.
7. Verify stale boot selected → pushes the queued commits.

**Scenario 5: Full signal-based shutdown (if testable)**

This tests actual SIGTERM delivery. May be fragile in CI but worth having:
1. Start `cd_poll_loop` in a background subshell (`cd_poll_loop "$repo_dir" &`).
2. Record its PID.
3. Sleep 1 second (let it start).
4. `kill -TERM $pid`.
5. Wait for process to exit.
6. Verify clean shutdown marker exists.
7. Verify PID file removed.

### On-Device Test Checklist

| # | Test | Steps | Expected |
|---|------|-------|----------|
| D1 | Runtime sync | Enroll + boot (Sprints 1.1/1.2). Play a game, save in-game. Wait 30s. | Check GitHub repo — save file appears in a new commit. |
| D2 | Graceful shutdown | Power off Brick normally. | Log shows "Shutdown: SIGTERM received" and "Shutdown: complete." Clean shutdown marker exists. |
| D3 | Clean boot after shutdown | Power on after D2. | Log shows "Boot: normal" (not stale). |
| D4 | Stale boot after crash | SSH in, `kill -9 $(cat /tmp/continuity.pid)`. Reboot. | Log shows "Boot: stale." Any pending changes recovered. |
| D5 | Multiple saves in session | Play game, save three times over ~2 minutes. | Each save results in a commit pushed to repo (check `git log`). |
| D6 | Daemon stays running | Check `ps` output several minutes after boot. | `continuity_daemon.sh` process still alive. |

---

## Definition of Done

- [ ] `cd_poll_loop` implemented: calls `rp_run` every 30 seconds indefinitely.
- [ ] `cd_shutdown` implemented: final push, conditional clean shutdown marker, PID cleanup, exit 0.
- [ ] SIGTERM trap set after boot dispatch, before poll loop.
- [ ] Clean shutdown marker written only when no unpushed commits remain.
- [ ] Poll loop errors are logged but don't stop the loop.
- [ ] Unit tests cover: poll loop behavior, shutdown with/without unpushed commits.
- [ ] Integration tests cover: save sync, clean shutdown → clean boot, unclean shutdown → stale boot, offline shutdown with unpushed.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] On-device test checklist documented.
- [ ] Sprint summary written to `docs/sprints/sprint-1.3-summary.md` on completion.
