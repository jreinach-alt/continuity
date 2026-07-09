# Sprint 0.10 — Sync Notifications

**Status:** Approved
**Date:** 2026-03-15
**Dependencies:** Sprint 0.9 (conflict ops), Sprint 0.6 (runtime poll), Sprint 0.5 (boot pull), Sprint 0.4 (cold start)

---

## Goal

When the sync pipeline does something, tell the user what happened. Immediately, briefly, while they're playing.

On the Brick, you save in Pokémon Red. A few seconds later, a small green dot appears near the bottom-right corner of the screen and fades away. Your save was pushed. You keep playing.

Later, you're on a road trip. No WiFi. You save again. A yellow dot appears — your save was committed locally, but couldn't reach the remote. Still safe, just not synced yet. You keep playing.

You get home, boot up. A red dot appears and stays. There's a conflict from your other device, or you played during a try and need to decide what to do. The red stays until you deal with it.

**This sprint defines the notification contract in core. It does not implement any display.** The core says "here's what happened" by calling a PAL hook. The PAL implementation on each platform decides how to show it — colored dot via `show2.elf` on NextUI, desktop notification on RetroDeck, toast on Android. That's Phase 1/2/3 work.

### Design Principle: Listener, Not Poller

The sync pipeline already knows what happened at every decision point. It doesn't need a separate module to come along later and figure it out by reading files and querying state. It just needs to announce the result.

The core contribution is:
1. A new PAL hook: `pal_on_sync_result`
2. Call sites in `rp_run`, `bp_run`, `cs_run` where outcomes are already known
3. A small last-status file for boot-time queries (Tool PAK, status screens)
4. A notification behavior contract that platforms implement

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, existing hooks (`pal_on_conflict`)
- `src/core/runtime_poll.sh` — `rp_run()` (Sprint 0.6)
- `src/core/boot_pull.sh` — `bp_run()` (Sprint 0.5)
- `src/core/cold_start.sh` — `cs_run()` (Sprint 0.4)
- `src/core/conflict_handler.sh` — `ch_count_conflicts()`, `ch_is_trying_modified()` (Sprint 0.9)

---

## Design

### The Hook

```sh
pal_on_sync_result <level> <message>
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `level` | enum | `green`, `yellow`, `red` |
| `message` | string | Short human-readable description of what happened |

Called by core modules when a sync operation completes with a meaningful outcome. **Not called when nothing happened** — a poll cycle that detects no changes is silent.

The PAL implementation decides what to do with this. The core doesn't care. It could show a dot, write to a log, send a push notification, play a sound, or do nothing.

### When Each Level Fires

#### Green — Pushed Successfully

The user's save reached the remote. Everything is good. This is the common happy path.

**Fired when:**
- `rp_run` detects changes, commits, and pushes successfully
- `cs_run` completes initial sync with successful push

**Message examples:**
- `"Pushed 1 save"` / `"Pushed 3 saves"`
- `"Initial sync complete"`

**Display behavior (platform contract):**
- Transient — appear briefly, fade after 2-3 seconds
- Non-intrusive — small indicator, doesn't interrupt gameplay

#### Yellow — Committed but Not Pushed

The save is committed locally (safe — won't be lost), but couldn't reach the remote. Usually means offline.

**Fired when:**
- `rp_run` detects changes and commits, but push fails with offline/network error (return code 2)
- `rp_run` detects changes and commits, but `pal_is_online` returns 1 (skip push)
- `cs_run` completes initial commit but can't push

**Message examples:**
- `"Saved locally — offline"` / `"1 save queued — offline"`

**Display behavior (platform contract):**
- Transient — appear briefly, fade after 3-4 seconds (slightly longer than green)
- Non-intrusive — same position as green, different color

#### Red — Action Required

Something needs the user's attention. They need to stop playing and go click on things.

**Fired when:**
- `bp_run` pull detects diverged history (conflicts created via `ch_handle_pull_conflict`)
- `ch_is_trying_modified` returns 0 during a poll cycle (Pokémon scenario — save modified during try)
- `rp_run` fails with a non-network error (return code 1)
- `se_push` fails with a persistent error (return code 1 — auth failure, repo gone)

**Message examples:**
- `"Conflict on pokemon_red — action required"`
- `"Save modified during try — action required"`
- `"Sync error — check logs"`
- `"Push failed — check credentials"`

**Display behavior (platform contract):**
- **Persistent** — stays on screen until the condition is resolved or the user explicitly dismisses
- More prominent than green/yellow — the user needs to notice this even mid-gameplay

### When NOT to Fire

**No notification when:**
- Poll cycle runs and detects no changes (the common case — most polls find nothing)
- Poll cycle runs and changes match repo (touched but not actually different, filtered by `cmp -s`)
- Boot pull succeeds with no new changes (fast-forward to same commit)
- Device is idle

This is critical. The user should NOT see a constant stream of green dots confirming "yep, still nothing." Silence means normal. A notification means something happened.

---

## Scope

### PAL Contract Addition

Add `pal_on_sync_result` to the PAL interface definition in `docs/design/pal.md`.

**Required:** No — optional hook, like `pal_on_conflict`. If the platform doesn't implement it, nothing happens. Core calls it only if the function exists:

```sh
if command -v pal_on_sync_result >/dev/null 2>&1; then
    pal_on_sync_result "$level" "$message"
fi
```

**Stub in PAL validator:** `pal_on_sync_result` is listed as an optional hook. The PAL validator does not fail if it's missing.

### Notification Helper: `ss_notify`

A small helper in `src/core/sync_status.sh` that wraps the hook call, writes the last-status file, and centralizes the "should we notify?" logic.

**Signature:** `ss_notify <repo_dir> <level> <message>`

**Behavior:**
1. Write the last-status file (see below).
2. Call `pal_on_sync_result "$level" "$message"` if the function exists.
3. Log via `pal_log "info" "sync_status: [$level] $message"`.

**Returns:** 0 always.

This is the only function the sync pipeline calls. It's the single point of notification. Platform hooks, logging, and state recording all flow through here.

### Last-Status File

**Location:** `$repo_dir/.continuity/last_status`

**Format:** Key-value, three fields:

```
level=green
message=Pushed 1 save
timestamp=2026-03-15T14:30:00Z
```

**Purpose:** Lets any process query "what was the last notification?" without being present when it fired. Used by:
- Tool PAK status screen (Sprint 1.5): "Last sync: Pushed 1 save, 2 minutes ago"
- Boot-time display: show last status on startup
- `ss_get_last_status` function (see below)

**Written by:** `ss_notify` — every notification overwrites this file atomically.

**Gitignored:** Yes. Local device state. Different devices have different sync histories.

### Query Function: `ss_get_last_status`

**Signature:** `ss_get_last_status <repo_dir>`

**Output:** Prints the contents of the last-status file to stdout. If the file doesn't exist, prints:
```
level=green
message=Ready
timestamp=never
```

**Returns:** 0 always.

This is the only query function. It reads what was already written — no computation, no live state checks, no network probes. Fast, trivial, suitable for constrained devices.

### Call Sites

Every call site already knows the level and can construct the message from context. No status computation needed.

#### `src/core/runtime_poll.sh` — `rp_run()`

**After successful push (Step 7, push_rc = 0):**
```sh
# Count the saves that were synced
local save_count
save_count=$(printf '%s\n' "$changed_in_repo" | grep -c '.')
ss_notify "$repo_dir" "green" "Pushed $save_count save(s)"
```

**After offline/deferred push (Step 7, pal_is_online returns 1 or push_rc = 2):**
```sh
local save_count
save_count=$(printf '%s\n' "$changed_in_repo" | grep -c '.')
ss_notify "$repo_dir" "yellow" "$save_count save(s) queued — offline"
```

**After push error (Step 7, push_rc = 1):**
```sh
ss_notify "$repo_dir" "red" "Push failed — check credentials"
```

**After post-copy error returns (Steps 4, 6 — per PF-1):**
```sh
ss_notify "$repo_dir" "red" "Sync error — check logs"
```

Note: only errors after Step 4 fire red. Step 1 (sentinel missing) and Steps 8-9 (store commit/sentinel) do NOT fire red — see PF-1 for rationale.

**NOT called when:**
- No candidates found (Step 2 early return) — silent
- No confirmed changes (Step 3 early return) — silent
- No git changes after copy (Step 5 early return) — silent

#### `src/core/boot_pull.sh` — `bp_run()`

**After diverged pull (conflict handler succeeds):**
```sh
local conflict_count
conflict_count=$(ch_count_conflicts "$repo_dir")
ss_notify "$repo_dir" "red" "$conflict_count conflict(s) — action required"
```

**After diverged pull (conflict handler fails):**
```sh
ss_notify "$repo_dir" "red" "Sync error — conflict handler failed"
```

**NOT called when:**
- Pull succeeds with no new changes — silent
- Pull succeeds with new changes (fast-forward) — silent (the user didn't do anything; the saves just appeared)

#### `src/core/cold_start.sh` — `cs_run()`

**After successful initial sync + push:**
```sh
ss_notify "$repo_dir" "green" "Initial sync complete"
```

**After initial sync, push offline:**
```sh
ss_notify "$repo_dir" "yellow" "Initial sync — push pending"
```

**After initial sync, push failure:**
```sh
ss_notify "$repo_dir" "red" "Push failed — check credentials"
```

#### `src/core/conflict_handler.sh` — `ch_handle_pull_conflict()` (Sprint 0.8, modified by 0.9)

**After conflict preservation completes (existing Step 9):**

This is already covered by `bp_run` calling `ss_notify` after `ch_handle_pull_conflict` returns. No additional call site needed inside the conflict handler itself — the caller is responsible for notification.

#### Trying-Modified Detection

The Pokémon scenario notification fires from the runtime poll, not from the conflict handler:

**In `rp_confirm_changes()` (Sprint 0.9 addition), when a trying-state file is skipped:**

Sprint 0.9 already adds the trying-state skip. The notification integrates here:

```sh
if ch_is_trying "$repo_dir" "$repo_path"; then
    if ch_is_trying_modified "$repo_dir" "$repo_path"; then
        ss_notify "$repo_dir" "red" "Save modified during try — action required"
    fi
    # Skip this file regardless
    continue
fi
```

This fires at most once per poll cycle for any given trying-modified file. Subsequent polls will re-detect and re-notify (red is persistent by contract, so the platform display maintains it).

---

## Notification Behavior Contract

Platforms implement `pal_on_sync_result` according to these rules:

| Level | Appearance | Duration | Dismissal |
|-------|-----------|----------|-----------|
| `green` | Small, subtle | 2-3 seconds, then fade | Auto-dismiss |
| `yellow` | Small, noticeable | 3-4 seconds, then fade | Auto-dismiss |
| `red` | Prominent | Persistent | User must resolve the condition or explicitly dismiss |

**Platform-specific examples (not implemented in this sprint):**

| Platform | Green | Yellow | Red |
|----------|-------|--------|-----|
| NextUI (Brick) | Small green dot, bottom-right, fades | Small yellow dot, bottom-right, fades | Red dot, bottom-right, stays until dismissed |
| RetroDeck | Desktop notification, auto-close | Desktop notification, auto-close | Desktop notification, stays in notification center |
| Android | Toast message | Toast message | Persistent notification |

**Red persistence detail:** "Persistent" means the platform should ensure the user sees it. Implementation varies:
- On NextUI: red dot stays on screen across game launches until the user opens the Continuity PAK and resolves the issue. The daemon re-fires `pal_on_sync_result "red" ...` on each poll cycle where the condition persists.
- On RetroDeck: notification stays in the notification center.
- On Android: persistent notification in the notification bar.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| NextUI `pal_on_sync_result` implementation (show2.elf dot) | 1.4 |
| RetroDeck `pal_on_sync_result` implementation (D-Bus notification) | 2.1 |
| Android `pal_on_sync_result` implementation (toast/notification) | 3.1 |
| Notification preferences (disable notifications, quiet hours) | post-1.0 |
| Notification sound / haptic | post-1.0 |
| Historical notification log | post-1.0 |
| Batching multiple notifications (e.g., 3 conflicts → 1 notification) | 1.1 if needed |
| Status query beyond last-status file (e.g., full health check) | future, if needed |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/sync_status.sh` | `ss_notify` helper + `ss_get_last_status` query |
| `tests/unit/core/test_sync_status.sh` | Unit tests for `ss_notify`, `ss_get_last_status`, last-status file |
| `tests/integration/test_sync_notifications.sh` | Integration test: sync → notification fired, no-change → silent, conflict → red |

### Files Modified

| File | Change |
|------|--------|
| `src/core/runtime_poll.sh` | Add `ss_notify` calls after push success, offline, and error (post-Step-4 errors only, per PF-1). Compute `save_count` before push block (PF-2). Add trying-modified sub-check + red notification in `rp_confirm_changes` (PF-5). |
| `src/core/boot_pull.sh` | Add `ss_notify` red after both conflict handler success and failure paths (PF-3). |
| `src/core/cold_start.sh` | Add `ss_notify` calls after initial sync outcomes: green on success, yellow on offline, red on push failure (PF-6). Silent on nothing-to-commit. |
| `docs/design/pal.md` | Add `pal_on_sync_result` to PAL interface as optional hook. Document notification behavior contract. |
| `docs/design/architecture.md` | Add Sync Notifications section. |

### Files Created at Runtime (in user's save repo)

| File | Created by | Purpose |
|------|-----------|---------|
| `$repo_dir/.continuity/.gitignore` | `ss_notify` (if absent) | Ignores `sentinel`, `last_known_commit`, `last_status` from git (PF-4). Committed to repo so it propagates to all clones. |
| `$repo_dir/.continuity/last_status` | `ss_notify` | Last notification level/message/timestamp. Gitignored. |

---

## Acceptance Criteria

### `ss_notify`

1. Calls `pal_on_sync_result` with the correct level and message when the function exists.
2. Does NOT call `pal_on_sync_result` when the function is not defined (no error).
3. Writes last-status file with `level`, `message`, and `timestamp` fields.
4. Last-status file is written atomically (write to temp, `mv` into place).
5. Logs the notification via `pal_log`.

### `ss_get_last_status`

6. Returns last-status file contents when it exists.
7. Returns defaults (`level=green`, `message=Ready`, `timestamp=never`) when no file exists.
8. Output is valid key-value format (parseable by the same rules as Sprint 0.9 output).

### Call Sites — `rp_run`

9. After detecting changes and pushing successfully: `pal_on_sync_result` called with `green` and a message containing the save count.
10. After detecting changes but push offline: `pal_on_sync_result` called with `yellow`.
11. After push error: `pal_on_sync_result` called with `red`.
12. After sync error: `pal_on_sync_result` called with `red`.
13. When no changes detected: `pal_on_sync_result` is NOT called.
14. When changes detected but all filtered by `cmp -s`: `pal_on_sync_result` is NOT called.

### Call Sites — Trying-Modified

15. When a trying-modified file is detected during `rp_confirm_changes`: `pal_on_sync_result` called with `red` and message containing "action required".
16. When a trying-state file is NOT modified: `pal_on_sync_result` is NOT called for that file.

### Call Sites — `bp_run`

17. After diverged pull (conflicts created, handler succeeds): `pal_on_sync_result` called with `red` and message containing conflict count.
17a. After diverged pull (conflict handler fails): `pal_on_sync_result` called with `red` and error message.
18. After successful fast-forward pull: `pal_on_sync_result` is NOT called.

### Call Sites — `cs_run`

19. After initial sync + push: `pal_on_sync_result` called with `green`.
20. After initial sync, push offline: `pal_on_sync_result` called with `yellow`.
20a. After initial sync, push failure: `pal_on_sync_result` called with `red`.

### PAL Contract

21. `pal_on_sync_result` is documented as optional in `pal.md`.
22. PAL validator does not fail when `pal_on_sync_result` is not defined.
23. The notification behavior contract (transient vs persistent by level) is documented in `pal.md`.

### `.gitignore`

24. Last-status file (`last_status`) is not committed to git.
24a. `ss_notify` creates `$repo_dir/.continuity/.gitignore` (ignoring `sentinel`, `last_known_commit`, `last_status`) if it doesn't exist.
24b. The `.gitignore` itself IS committed (so it propagates to all clones).

### Code Quality

25. All new code passes `shellcheck` with no errors.
26. All new code passes `busybox ash -n` syntax check.
27. No banned BusyBox ash constructs.
28. All variable expansions are quoted.
29. All new functions use `printf` for output, not `echo`.
30. All tests pass under `busybox ash`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_sync_status.sh`)

**`ss_notify` tests:**

- With `pal_on_sync_result` defined: verify it's called with correct args.
- Without `pal_on_sync_result` defined: verify no error.
- Verify last-status file written with correct level, message, timestamp.
- Verify last-status file is overwritten on subsequent calls.
- Verify `pal_log` is called.

**`ss_get_last_status` tests:**

- File exists: returns contents.
- File missing: returns defaults.
- Verify output format matches key-value spec.

### Integration Test (`tests/integration/test_sync_notifications.sh`)

**Setup:** Create bare remote, local clone, device saves directory, platform map. Define a mock `pal_on_sync_result` that records calls to a temp file for assertion.

**Scenario 1: Happy path — change detected, pushed**
1. Create a save file on "device."
2. Run `rp_run` → sync cycle completes, push succeeds.
3. Verify `pal_on_sync_result` was called with `green`.
4. Verify last-status file shows `level=green`.

**Scenario 2: No changes — silent**
1. Run `rp_run` with no save changes.
2. Verify `pal_on_sync_result` was NOT called.
3. Last-status file is unchanged from Scenario 1.

**Scenario 3: Offline push**
1. Mock `pal_is_online` to return 1.
2. Create a save change, run `rp_run`.
3. Verify `pal_on_sync_result` called with `yellow`.
4. Last-status file shows `level=yellow`.

**Scenario 4: Conflict on boot pull**
1. Create diverged history (second clone pushes different save).
2. Run `bp_run` on first clone.
3. Verify `pal_on_sync_result` called with `red`, message mentions conflict count.
4. Last-status file shows `level=red`.

**Scenario 5: Pokémon scenario**
1. Set up a conflict, `ch_try_version ... local`.
2. Modify the device save file.
3. Run `rp_run` (which calls `rp_confirm_changes`).
4. Verify `pal_on_sync_result` called with `red`, message contains "action required".
5. Verify the modified save was NOT committed.

---

## Definition of Done

- [ ] `pal_on_sync_result` hook defined in PAL interface docs as optional.
- [ ] Notification behavior contract documented (transient vs persistent by level).
- [ ] `ss_notify` implemented — calls hook, writes last-status, logs.
- [ ] `ss_get_last_status` implemented — reads last-status file or returns defaults.
- [ ] `rp_run` modified — `ss_notify` at push success, offline, and error. Silent on no-change.
- [ ] `rp_confirm_changes` modified — `ss_notify` red on trying-modified detection.
- [ ] `bp_run` modified — `ss_notify` red on diverged pull.
- [ ] `cs_run` modified — `ss_notify` on initial sync outcomes.
- [ ] Last-status file gitignored via `$repo_dir/.continuity/.gitignore`.
- [ ] `.continuity/.gitignore` also covers `sentinel` and `last_known_commit`.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration test passes — including silent-on-no-change verification.
- [ ] Sprint summary written to `docs/sprints/sprint-0.10-summary.md` on completion.

---

## Resolved Design Decisions

1. **Re-fire red on every poll cycle.** Yes. When a trying-modified condition or unresolved conflict persists, every poll cycle re-calls `pal_on_sync_result "red" ...`. The core's contract is "this is what's happening right now." It's the platform's job to debounce if needed — a dumb overlay that just shows what it's told will keep showing red, which is correct.

2. **Message is opaque display text.** Platforms must NOT parse the message string. Branch only on `level` (green/yellow/red). The message is for the user to read. If platforms need structured data (e.g., conflict count), they call Sprint 0.9's `ch_count_conflicts` directly.

3. **No device JSON updates.** This module is a listener, not a state manager. It does not update `last_sync`/`last_push` in the device JSON. Those fields are the responsibility of whatever module owns device registration state. The last-status file is the only persistent artifact this sprint writes, and it exists solely so the Tool PAK can answer "what was the last notification?" at query time.

---

## Preflight Resolutions

These findings were identified during the Sprint 0.10 preflight check and resolved here.

### PF-1: Red notifications on `rp_run` error paths — which ones?

The spec says "After any error return (existing `return 1` paths)" should call `ss_notify`. But `rp_run` has several early-exit `return 1` paths:

- **Step 1 (line 93):** Sentinel missing — cold start incomplete. This is a pre-condition failure, not a sync error. The user hasn't done anything yet.
- **Step 4 (line 142):** Copy failed — a file couldn't be written to the repo working tree.
- **Step 6 (lines 157, 162):** Stage or commit failed — git operations failed after files were copied.
- **Step 7 (line 172):** Push failed — auth error or repo gone.
- **Step 8 (line 185):** Store commit hash failed — can't write to `.continuity/last_known_commit`.
- **Step 9 (line 191):** Update sentinel failed — can't touch sentinel file.

**Resolution:** Only fire `ss_notify "red"` for errors after Step 5 (post-copy, where the user's data is involved). Specifically:

| Path | Notify? | Rationale |
|------|---------|-----------|
| Sentinel missing (Step 1) | No | Pre-condition. User needs cold start, not sync notification. |
| Copy failed (Step 4) | Yes | User's save couldn't be synced. |
| Stage/commit failed (Step 6) | Yes | Git is broken. |
| Push failed (Step 7) | Yes | Already handled — `ss_notify "red" "Push failed"`. |
| Store commit / sentinel (Steps 8-9) | No | Post-push bookkeeping. Save is already safe on remote. |

### PF-2: Two yellow notification locations in `rp_run`

The spec's yellow notifications cover two code paths that need separate `ss_notify` calls:

1. **`pal_is_online` returns false (line 176-177):** Push was never attempted. Message: `"$save_count save(s) queued — offline"`.
2. **`push_rc=2` (line 173-174):** Push was attempted but got a network error. Message: `"$save_count save(s) queued — offline"`.

Both use the same level and similar messages. The `save_count` variable must be computed before Step 7 (the push block) so it's available in both branches.

**Resolution:** Compute `save_count` before the push block. Both paths call `ss_notify "$repo_dir" "yellow" "$save_count save(s) queued — offline"`.

### PF-3: `bp_run` notification placement and failure path

The spec says notification after "diverged pull (conflict handler invoked)." In `bp_run`, `se_pull` returns 1 when diverged (line 107), then `ch_handle_pull_conflict` is called (line 112). Two outcomes:

1. `ch_handle_pull_conflict` succeeds → `return 0` (line 116). **Insert `ss_notify "red"` here.**
2. `ch_handle_pull_conflict` fails → `return 1` (line 114). Should this also notify?

**Resolution:** Yes, both paths get red. On success: `"$conflict_count conflict(s) — action required"`. On failure: `"Sync error — conflict handler failed"`. The failure path is arguably more urgent — the user has conflicts AND the handler couldn't process them.

### PF-4: `.continuity/.gitignore` for `last_status`

The `last_status` file lives at `$repo_dir/.continuity/last_status`. Currently, there is NO `.gitignore` in the `.continuity/` directory. The existing `sentinel` and `last_known_commit` files are also not gitignored — they avoid being committed because the sync engine only stages files via `se_stage_files` with explicit paths (never `git add .`), so `.continuity/` contents are untracked but not ignored.

**Resolution:** Create `$repo_dir/.continuity/.gitignore` in `ss_notify` (if it doesn't exist) to ignore local-only state files:

```
sentinel
last_known_commit
last_status
```

This is the right fix — even though the current code avoids committing these by never running `git add .`, an explicit `.gitignore` is a safety net. The `.gitignore` itself IS committed (so it propagates to all clones). `ss_notify` creates it on first call if missing.

**Commit path:** `ss_notify` is called mid-flow (after `cd_detect_changes` in `rp_run`), so the newly created `.gitignore` won't be detected in the current sync cycle. It gets picked up by `cd_detect_changes` on the *next* cycle, staged, and committed alongside any save changes. This is acceptable — the `.gitignore` is a safety net, not urgent. First-cycle timing: on cold start, `cs_run` calls `ss_notify` at the end, so the `.gitignore` is committed on the first `rp_run` cycle.

Add to the file table: `$repo_dir/.continuity/.gitignore` is created by `ss_notify` if absent.

### PF-5: `rp_confirm_changes` trying-modified sub-check

The spec (lines 269-276) shows `ch_is_trying_modified` being called inside `rp_confirm_changes`. The current code (Sprint 0.9) only calls `ch_is_trying` — it does not differentiate between trying-modified and trying-not-modified.

**Resolution:** Sprint 0.10 expands the existing `ch_is_trying` branch in `rp_confirm_changes` to add the `ch_is_trying_modified` sub-check and fire `ss_notify "red"`. The file is still skipped regardless of modification state. The notification is only for the modified case.

### PF-6: `cs_run` notification placement

`cs_run` has three outcome paths after the commit:

1. **Push succeeds** (line 238-248, `push_rc` not 1 or 2): green.
2. **Push offline** (`was_offline=true`, line 249-250 or line 243-244): yellow.
3. **Push fails** (`push_rc=1`, line 246-247): returns 1 — red.
4. **Nothing to commit** (line 253): silent.

**Resolution:**
- Green: after Step 10 "Cold start complete" (line 273), only when `was_offline != true`.
- Yellow: after "offline — sentinel deferred" (line 269).
- Red: before `return 1` on push failure (line 247). But note: `cs_run` returns 1 here, and the caller should handle this. Since the cold start is the first-ever run, a push failure here means the user's save repo can't be reached — that's a setup error. Still fire red for consistency.
- Silent: nothing to commit path (line 253).
