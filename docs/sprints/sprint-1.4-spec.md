# Sprint 1.4 — WiFi Recovery, Notifications, Log Management

**Status:** Draft
**Date:** 2026-03-16
**Dependencies:** Sprint 1.3 (poll loop + shutdown), Sprint 0.10 (sync notifications)

---

## Goal

Make the daemon resilient and visible.

**WiFi recovery:** When the Brick loses WiFi mid-session, saves are committed locally (the core already handles this — `rp_run` commits and fires a yellow notification). But those commits stay local until something pushes them. This sprint adds a WiFi recovery check at the top of each poll cycle: if we're back online and have unpushed commits, push them. The user re-enters WiFi range, and within 30 seconds their queued saves are pushed. No manual intervention.

**Notifications:** The core's `ss_notify` calls `pal_on_sync_result` if it exists. Until now, the NextUI PAL didn't implement it — notifications fired into the void. This sprint adds `pal_on_sync_result` to the NextUI PAL, displaying colored dots on the Brick's screen via `show2.elf`. Green dot = pushed. Yellow dot = queued offline. Red dot = action required (conflict, error).

**Log management:** The daemon has been writing to a log file since Sprint 1.1. Without rotation, the log grows unbounded. This sprint adds a size check at the end of each poll cycle: if the log exceeds 256 KB, rotate it. Keep one backup. Max disk usage: ~512 KB.

---

## Reference Specs

- `docs/sprints/sprint-1.3-spec.md` — Poll loop structure
- `docs/design/pal.md` — `pal_on_sync_result` hook contract, notification behavior
- `src/core/sync_status.sh` — `ss_notify()` (Sprint 0.10)
- `src/core/sync_engine.sh` — `se_push()`, `se_has_unpushed_commits()` (Sprint 0.3)

---

## Design

### WiFi Recovery — Why at Poll-Loop Top

Instead of a separate connectivity watcher (thread, inotify on network state file, etc.), we check at the start of each poll cycle. Advantages:

- **No concurrency.** BusyBox ash has no threads. A separate watcher would be a separate process with its own git operations, creating race conditions on the repo.
- **No event source.** The Brick doesn't expose network state changes via inotify or dbus. We'd have to poll anyway.
- **Worst-case latency: 30 seconds.** WiFi returns, and within one poll cycle the queued commits are pushed. Acceptable.

### Notifications — `show2.elf`

`show2.elf` is a NextUI utility that renders small images or colored rectangles on the framebuffer as overlays. The exact command-line interface depends on the version. The implementation should:

- Render a small colored dot (e.g., 8x8 or 12x12 pixels) in the bottom-right corner.
- Avoid overlap with the battery/WiFi indicators.
- For green/yellow: show briefly, then clear (background subshell with sleep + clear).
- For red: show and leave visible (the daemon re-fires red each poll cycle per the 0.10 contract; the platform maintains visibility).

**Graceful degradation:** If `show2.elf` doesn't exist, the function logs the notification and returns 0. No crash, no error. The daemon works identically — just without visual feedback.

**On-device verification required.** The `show2.elf` command-line interface must be verified against the actual binary on the Brick. The implementation in this sprint is a best-effort based on documented usage. If the interface doesn't match, the function degrades to log-only and we adjust in a follow-up.

### Log Rotation — Simple and Predictable

```
cd_check_log_rotation():
    if log file doesn't exist → return
    size = wc -c < log_file
    if size > 262144:
        mv log_file log_file.1
        # stderr is already redirected via exec 2>>
        # New writes create a fresh log_file automatically
```

**Why `wc -c` and not `stat`:** BusyBox `stat` output format varies across builds. `wc -c < file` is universally portable.

**Why `mv` and not `cp + truncate`:** Atomic rename is simpler and race-free. After `mv`, the next `pal_log` call writes to a new file at the old path (stderr is still open to the moved fd, but `exec 2>>` needs to be refreshed). Actually — this is a subtlety.

**The fd issue:** After `exec 2>>"$log_file"`, stderr fd 2 points to the file's inode. After `mv`, the inode is renamed to `.1`, but fd 2 still points to the same inode. New writes go to `.1`, not the new `$log_file`. We need to re-open stderr after rotation:

```sh
mv "$CONTINUITY_LOG_FILE" "${CONTINUITY_LOG_FILE}.1"
exec 2>>"$CONTINUITY_LOG_FILE"
```

This is safe — `exec 2>>` creates the new file and redirects fd 2 to it.

---

## Scope

### Part 1: WiFi Recovery

#### `cd_wifi_recovery` — Push queued commits when connectivity returns

**Signature:** `cd_wifi_recovery(repo_dir)`

**Parameters:**
- `repo_dir` — absolute path to local clone

**Behavior:**
1. If `pal_is_online` returns non-zero → return 0 (still offline, nothing to do).
2. Check `se_has_unpushed_commits "$repo_dir"`:
   - If returns 1 (nothing to push) → return 0.
   - If returns 0 (unpushed commits exist) → proceed.
3. Push: `se_push "$repo_dir"`.
4. If push succeeds (rc=0):
   - `ss_notify "$repo_dir" "green" "Pushed queued saves"`.
   - Log: `"WiFi recovery: pushed queued commits"`.
5. If push fails (rc=1, persistent):
   - `ss_notify "$repo_dir" "red" "Push failed — check credentials"`.
   - Log: `"WiFi recovery: push failed"`.
6. If push fails (rc=2, network — went offline again):
   - Log: `"WiFi recovery: went offline during push — will retry"`.
   - No notification (transient — will retry next cycle).

**Returns:** 0 always. WiFi recovery is best-effort; failure doesn't interrupt the poll loop.

---

### Part 2: Log Rotation

#### `cd_check_log_rotation` — Rotate log if too large

**Signature:** `cd_check_log_rotation()`

No parameters. Uses `CONTINUITY_LOG_FILE` variable.

**Behavior:**
1. If `$CONTINUITY_LOG_FILE` doesn't exist → return 0.
2. Get file size: `log_size=$(wc -c < "$CONTINUITY_LOG_FILE")`.
3. If `log_size` > 262144 (256 KB):
   - `mv "$CONTINUITY_LOG_FILE" "${CONTINUITY_LOG_FILE}.1"`.
   - Re-open stderr: `exec 2>>"$CONTINUITY_LOG_FILE"`.
   - Log: `"Log rotated"` (this goes to the new file).
4. Return 0.

**Constants:**
- `CD_LOG_MAX_SIZE=262144` — 256 KB in bytes.

---

### Part 3: `pal_on_sync_result` Implementation

#### Changes to `src/platforms/nextui/pal_nextui.sh`

Add `pal_on_sync_result` — display a colored dot on the Brick's screen.

**Signature:** `pal_on_sync_result(level, message)`

**Parameters:**
- `level` — `green`, `yellow`, `red`
- `message` — human-readable text (logged only — no text rendering via `show2.elf`)

**Behavior:**
1. Log: `pal_log "info" "sync_result: [$level] $message"`.
2. Determine `show2_bin`:
   - `show2_bin="${CONTINUITY_PAK_DIR:-}/bin/show2.elf"`
   - If not executable → return 0 (log-only fallback).
3. Map level to display:
   - `green`: show green dot, auto-dismiss after 3 seconds.
   - `yellow`: show yellow dot, auto-dismiss after 4 seconds.
   - `red`: show red dot, persistent (no auto-dismiss).
4. Implementation detail for auto-dismiss (green/yellow):
   ```sh
   (
       "$show2_bin" <render args> &
       show2_pid=$!
       sleep "$duration"
       kill "$show2_pid" 2>/dev/null
   ) &
   ```
   The subshell runs in the background so `pal_on_sync_result` returns immediately.
5. Implementation detail for persistent (red):
   ```sh
   # Kill any previous red overlay process
   if [ -f /tmp/continuity_red_pid ]; then
       kill "$(cat /tmp/continuity_red_pid)" 2>/dev/null
       rm -f /tmp/continuity_red_pid
   fi
   "$show2_bin" <render args> &
   printf '%s' "$!" > /tmp/continuity_red_pid
   ```

**Red overlay management:** The daemon re-fires `pal_on_sync_result "red" ...` each poll cycle while a red condition persists (per the Sprint 0.10 contract). Each call kills the previous `show2.elf` process and starts a new one. This prevents accumulating overlay processes.

**`show2.elf` arguments:** The exact arguments depend on the `show2.elf` binary bundled with the PAK. The implementation should document what's expected and use a variable (`CD_SHOW2_ARGS_GREEN`, etc.) so it can be adjusted without rewriting the function. If the arguments don't work on-device, the function silently fails (stderr from `show2.elf` goes to the log file).

---

### Part 4: Poll Loop Integration

#### Changes to `cd_poll_loop`

Update the poll loop from Sprint 1.3:

**Before (1.3):**
```sh
while true; do
    rp_run "$repo_dir" || pal_log "warn" "Poll cycle failed (rc=$?)"
    sleep "$CD_POLL_INTERVAL"
done
```

**After (1.4):**
```sh
while true; do
    cd_wifi_recovery "$repo_dir"
    rp_run "$repo_dir" || pal_log "warn" "Poll cycle failed (rc=$?)"
    cd_check_log_rotation
    sleep "$CD_POLL_INTERVAL"
done
```

WiFi recovery runs first (push queued commits before detecting new changes). Log rotation runs last (after any new log entries from this cycle).

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Tool PAK UI (status screen, manual sync, conflict resolution) | 1.5 |
| Notification preferences (disable, quiet hours) | post-1.0 |
| Notification sound / haptic feedback | post-1.0 |
| Configurable poll interval | post-1.0 |
| `show2.elf` procurement / build | future build sprint |
| Batching multiple notifications | post-1.0 if needed |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `tests/unit/platforms/nextui/test_daemon_resilience.sh` | Unit tests for `cd_wifi_recovery`, `cd_check_log_rotation` |
| `tests/unit/platforms/nextui/test_pal_notifications.sh` | Unit tests for `pal_on_sync_result` |
| `tests/integration/test_daemon_wifi_recovery.sh` | Integration test: offline → online transition, queued commits pushed |
| `docs/sprints/sprint-1.4-spec.md` | This spec |

### Files Modified

| File | Change |
|------|--------|
| `src/platforms/nextui/continuity_daemon.sh` | Add `cd_wifi_recovery`, `cd_check_log_rotation`, `CD_LOG_MAX_SIZE`. Update `cd_poll_loop` to call both. |
| `src/platforms/nextui/pal_nextui.sh` | Add `pal_on_sync_result` function. |

---

## Acceptance Criteria

### WiFi Recovery

1. When online and unpushed commits exist, `cd_wifi_recovery` calls `se_push`.
2. When online and no unpushed commits, `cd_wifi_recovery` is a no-op (does not call `se_push`).
3. When offline, `cd_wifi_recovery` is a no-op.
4. Successful push fires `ss_notify` with level `green` and message containing "queued".
5. Failed push (rc=1) fires `ss_notify` with level `red`.
6. Network error on push (rc=2) logs a warning but does NOT fire `ss_notify` (transient, will retry).
7. `cd_wifi_recovery` always returns 0 (never interrupts poll loop).

### Log Rotation

8. `cd_check_log_rotation` does nothing when log file is under 256 KB.
9. `cd_check_log_rotation` rotates when log exceeds 256 KB: renames to `.1`, re-opens stderr.
10. At most 1 backup log is kept (previous `.1` is overwritten on next rotation).
11. After rotation, new log entries go to a fresh log file (not the `.1` file).
12. Missing log file: `cd_check_log_rotation` returns 0, no error.
13. Total log disk usage stays under ~512 KB.

### `pal_on_sync_result`

14. `pal_on_sync_result "green" <msg>` logs the notification via `pal_log`.
15. `pal_on_sync_result "yellow" <msg>` logs the notification via `pal_log`.
16. `pal_on_sync_result "red" <msg>` logs the notification via `pal_log`.
17. If `show2.elf` is not available, function returns 0 (log-only, no error).
18. Function returns immediately (display is async via background subshell).
19. Red overlay: previous `show2.elf` process is killed before starting a new one.
20. Green/yellow overlay: auto-dismissed after 3-4 seconds.

### Poll Loop Integration

21. `cd_wifi_recovery` is called before `rp_run` in each poll cycle.
22. `cd_check_log_rotation` is called after `rp_run` in each poll cycle.

### End-to-End: Offline → Online

23. Device goes offline mid-session. Save change committed locally (yellow notification from core).
24. Device comes back online. Within one poll cycle (30s), queued commits are pushed.
25. Green notification fires after successful WiFi recovery push.

### Code Quality

26. All new code passes `shellcheck` with no errors.
27. All new code passes `busybox ash -n` syntax check.
28. No banned BusyBox ash constructs.
29. All variable expansions are quoted.
30. All new functions use `printf` for output, not `echo`.
31. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests — WiFi Recovery (`tests/unit/platforms/nextui/test_daemon_resilience.sh`)

**WiFi recovery tests (mocked):**
- Online + unpushed → push succeeds: mock `pal_is_online` (return 0), `se_has_unpushed_commits` (return 0), `se_push` (return 0). Verify push called. Verify `ss_notify` called with "green". Record via mock `ss_notify` that writes args to a temp file.
- Online + nothing to push: mock `se_has_unpushed_commits` (return 1). Verify `se_push` NOT called.
- Offline: mock `pal_is_online` (return 1). Verify `se_has_unpushed_commits` NOT called.
- Push failure (rc=1): mock `se_push` (return 1). Verify `ss_notify` called with "red".
- Push network error (rc=2): mock `se_push` (return 2). Verify `ss_notify` NOT called. Verify log contains warning.

**Log rotation tests:**
- Small log: create a 100 KB log file, call `cd_check_log_rotation`, verify file still exists at original path (not rotated).
- Large log: create a 300 KB log file, call `cd_check_log_rotation`, verify `.1` file exists with old content.
- Verify after rotation, `exec 2>>` re-opened: write to stderr after rotation, verify it goes to a new file at the original path.
- Rotation with existing `.1`: create both log and `.1`, fill log > 256 KB, rotate. Verify old `.1` overwritten.
- Missing log: call `cd_check_log_rotation` when no log file exists. Verify returns 0.

### Unit Tests — Notifications (`tests/unit/platforms/nextui/test_pal_notifications.sh`)

**`pal_on_sync_result` tests:**
- Green/yellow/red: verify `pal_log` called with correct level for each.
- No `show2.elf`: set `CONTINUITY_PAK_DIR` to a directory without `bin/show2.elf`. Call `pal_on_sync_result`. Verify returns 0, no error.
- With mock `show2.elf`: create a stub script at `$CONTINUITY_PAK_DIR/bin/show2.elf` that records its args to a temp file. Call `pal_on_sync_result "green" "test"`. Sleep briefly, verify stub was called.
- Red PID management: call `pal_on_sync_result "red" "conflict"` twice. Verify only one `show2.elf` process is running (previous was killed).

### Integration Test (`tests/integration/test_daemon_wifi_recovery.sh`)

**Setup:** Enrolled device, cold start complete, device saves directory.

**Scenario 1: Offline commit → WiFi recovery**
1. Mock `pal_is_online` to return 1 (offline).
2. Create a save change, call `rp_run` → committed locally, not pushed.
3. Verify yellow notification fired (from `rp_run`).
4. Switch mock to return 0 (online).
5. Call `cd_wifi_recovery`.
6. Verify commit pushed to remote.
7. Verify green notification fired (from `cd_wifi_recovery`).
8. Call `cd_wifi_recovery` again → no-op (nothing to push).

**Scenario 2: Multiple offline commits → single recovery push**
1. Mock offline.
2. Create save change, `rp_run` → committed.
3. Create another save change, `rp_run` → committed.
4. Switch to online.
5. Call `cd_wifi_recovery`.
6. Verify both commits pushed (remote has both).

**Scenario 3: WiFi recovery push failure**
1. Create an offline commit.
2. Switch to online but mock `se_push` to return 1.
3. Call `cd_wifi_recovery`.
4. Verify red notification fired.
5. Verify commit still local (not pushed).

### On-Device Test Checklist

| # | Test | Steps | Expected |
|---|------|-------|----------|
| D1 | Green notification | Play a game, save in-game, wait 30s | Green dot appears briefly in bottom-right corner |
| D2 | Yellow notification | Disable WiFi, save in-game, wait 30s | Yellow dot appears briefly |
| D3 | WiFi recovery | Re-enable WiFi after D2, wait up to 30s | Green dot appears. Check GitHub — save is pushed. |
| D4 | Red notification | Create a conflict from another device, boot Brick | Red dot appears and stays visible |
| D5 | No show2.elf fallback | Rename `show2.elf` in PAK, reboot, save in-game | Daemon syncs normally. No dot (expected). No crash. Log shows notification entries. |
| D6 | Log rotation | Let daemon run, or manually write >256 KB to log. Check files. | `continuity.log` is fresh, `continuity.log.1` contains old entries. Total < 512 KB. |
| D7 | Log entries useful | Read the log after a session | Entries have timestamps, levels, and enough context to debug sync issues. |

---

## Definition of Done

- [ ] `cd_wifi_recovery` pushes queued commits when online. No-op when offline or nothing to push.
- [ ] `cd_check_log_rotation` rotates log at 256 KB with 1 backup. Re-opens stderr after rotation.
- [ ] `pal_on_sync_result` implemented in `pal_nextui.sh` — calls `show2.elf` or degrades to log-only.
- [ ] Poll loop updated: WiFi recovery before `rp_run`, log rotation after.
- [ ] Green/yellow dots are transient (auto-dismiss after 3-4s).
- [ ] Red dot is persistent (killed and re-created each cycle while condition persists).
- [ ] Unit tests cover: WiFi recovery (all paths), log rotation (all paths), notification display (with/without show2.elf).
- [ ] Integration tests cover: offline → online transition, multiple queued commits, push failure.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] On-device test checklist documented.
- [ ] Sprint summary written to `docs/sprints/sprint-1.4-summary.md` on completion.

---

## Sprint 1.1 Completion

When all four sprints (1.1 through 1.4) are complete, the NextUI daemon is fully functional:

- Starts on boot via `auto.sh`
- Prevents duplicate instances via PID file
- Enrolls the device if `setup.json` is present
- Detects boot state and runs the correct sync phase
- Polls for save changes every 30 seconds
- Pushes queued commits when WiFi returns
- Shows colored status dots on screen
- Shuts down cleanly on SIGTERM
- Rotates logs to stay within disk budget

The daemon is ready for real-world use on a TrimUI Brick. Sprint 1.5 (Tool PAK UI) adds the user-facing status screen and conflict resolution interface.
