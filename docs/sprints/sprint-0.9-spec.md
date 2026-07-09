# Sprint 0.9 — Conflict Resolution Operations

**Status:** Approved
**Date:** 2026-03-15
**Dependencies:** Sprint 0.8 (conflict handler), Sprint 0.6 (runtime poll), Sprint 0.5 (sync engine)

---

## Goal

Build the platform-agnostic operations layer that any conflict resolution UI calls into, **and protect the sync pipeline from the "trying" state.**

Sprint 0.8 gave us the conflict *infrastructure* — detection, preservation, and resolution. But between "here are some `.conflict` files" and "resolve this one," there are two gaps:

**Gap 1 — Interactive resolution workflow.** A user resolving a conflict needs to:
1. **Browse** — see all conflicts with meaningful context (system, game, device names, timestamps), not raw file paths
2. **Try** — non-destructively swap a version into the device's active save slot so they can test it in-game
3. **Track** — know which version is currently active (what did I last try?)
4. **Resolve** — commit a decision with structured feedback

**Gap 2 — Sync engine safety.** When a user "tries" a save version, the file in the device's save directory is a *test copy*, not an authoritative save. But `rp_run()` in the runtime poll doesn't know that. It will detect the file as changed, copy it to the repo, stage it, commit it, and push it — destroying the conflict metadata and promoting a test version to canonical. Worse: if the user plays the game during the try (the "Pokémon scenario"), their new progress gets silently committed without ever being explicitly chosen as the resolution.

**The Pokémon Scenario:**
1. User has a conflict on `gb/pokemon_red.srm`
2. They `ch_try_version ... local` — local bytes copied to device save slot
3. They launch Pokémon Red to check if this is the right save
4. They get absorbed, play for 20 minutes, save in-game
5. The daemon's poll cycle fires, sees the modified `.srm`
6. Without protection: stages, commits, pushes — franken-save promoted, conflict metadata orphaned
7. With Sprint 0.9: poll detects trying state, skips the file, flags it as "trying_modified"

This sprint solves both gaps. All `src/core/`, all platform-agnostic.

---

## Reference Specs

- `docs/design/pal.md` — PAL interface, `CONTINUITY_SAVES_ROOT`, `CONTINUITY_DEVICE_NAME`, `pm_repo_to_local()`
- `docs/design/architecture.md` — Conflict Resolution Strategy section
- `src/core/conflict_handler.sh` — Existing Sprint 0.8 API
- `src/core/path_mapper.sh` — `pm_repo_to_local`, `pm_local_to_repo` (Sprint 0.2 output)
- `src/core/runtime_poll.sh` — `rp_run()`, `rp_confirm_changes()` (Sprint 0.6 output)
- `src/core/change_detector.sh` — `cd_detect_changes()` (Sprint 0.5 output)

---

## Scope

### Part 1: Interactive Resolution Operations

New functions added to `src/core/conflict_handler.sh`, following the existing `ch_*` naming convention and BusyBox ash conventions.

---

#### `ch_get_conflict_info` — Parse one conflict's metadata

**Signature:** `ch_get_conflict_info <repo_dir> <repo_path>`

**Parameters:**
- `repo_dir` — absolute path to the repo working copy
- `repo_path` — canonical repo-relative `.srm` path (e.g., `snes/super_metroid.srm`)

**Output:** Key-value pairs to stdout, one per line:

```
file=snes/super_metroid.srm
system=snes
game=super_metroid
remote_device=my-deck
remote_timestamp=2026-03-12T13:00:00Z
local_device=my-brick
local_timestamp=2026-03-12T14:30:00Z
status=unresolved
active_version=remote
trying_modified=no
```

**Implementation:**
1. Read `$repo_dir/$repo_path.conflict` — parse each JSON field with `grep` + `sed` (same pattern used by `ch_resolve`'s `keep_newest` branch).
2. Derive `system` from path: everything before the first `/`.
3. Derive `game` from path: filename without `.srm` extension.
4. Determine `active_version` by reading the try marker (see `ch_try_version`). Default is `remote`.
5. Determine `trying_modified`: first check `ch_is_trying` — if no try marker exists, output `no` without calling `ch_is_trying_modified` (avoids unnecessary work). Only call `ch_is_trying_modified` when a try marker exists.
6. Output `status` from the `.conflict` JSON (currently always `unresolved` for active conflicts).

**Returns:** 0 on success, 1 if `.conflict` file doesn't exist or is unparseable.

**Output format rationale:** Key-value lines are trivially parseable in any language:
- Shell: `value=$(echo "$output" | grep '^key=' | sed 's/^key=//')`
- C: `sscanf(line, "key=%s", value)` or `strtok`
- Java/Kotlin: `line.split("=", 2)`
- No JSON production needed (avoids fragile shell JSON generation without `jq`)

---

#### `ch_list_conflicts_detailed` — List all conflicts with full metadata

**Signature:** `ch_list_conflicts_detailed <repo_dir>`

**Output:** Multiple `ch_get_conflict_info` blocks separated by blank lines:

```
file=snes/super_metroid.srm
system=snes
game=super_metroid
remote_device=my-deck
remote_timestamp=2026-03-12T13:00:00Z
local_device=my-brick
local_timestamp=2026-03-12T14:30:00Z
status=unresolved
active_version=remote
trying_modified=no

file=gb/pokemon_red.srm
system=gb
game=pokemon_red
remote_device=my-deck
remote_timestamp=2026-03-12T11:00:00Z
local_device=my-brick
local_timestamp=2026-03-12T12:00:00Z
status=unresolved
active_version=local
trying_modified=yes
```

**Implementation:**
1. Call `ch_list_conflicts "$repo_dir"` to get `.conflict` file paths.
2. For each, strip `.conflict` suffix to get `repo_path`.
3. Call `ch_get_conflict_info "$repo_dir" "$repo_path"`.
4. Print a blank line between entries.

**Returns:** 0 always. Empty output if no conflicts.

---

#### `ch_count_conflicts` — Count unresolved conflicts

**Signature:** `ch_count_conflicts <repo_dir>`

**Output:** A single integer to stdout (e.g., `3`). Prints `0` if no conflicts.

**Implementation:** Count lines from `ch_list_conflicts`.

**Returns:** 0 always.

---

#### `ch_try_version` — Swap a save version into the device's active slot

**Signature:** `ch_try_version <repo_dir> <repo_path> <version>`

**Parameters:**
- `repo_dir` — absolute path to the repo working copy
- `repo_path` — canonical repo-relative `.srm` path
- `version` — `remote` or `local`

**Behavior:**
1. Validate that a `.conflict` file exists for `repo_path`. Return 1 if not.
2. Validate that `version` is `remote` or `local`. Return 1 if not.
3. Determine the device save path via `pm_repo_to_local "$repo_path"`. Return 1 if path mapping fails.
4. If `version` is `remote`:
   - Source file: `$repo_dir/$repo_path` (the canonical `.srm`)
   - Copy to device save path.
5. If `version` is `local`:
   - Construct the `.local` file path directly: `$repo_dir/$repo_path.$CONTINUITY_DEVICE_NAME.local`. The device name is always available via the PAL environment variable, and the `.local` file was created by `ch_preserve_conflict` on this device. If the direct path doesn't exist (e.g., resolving a conflict originally detected on a different device), fall back to finding the first `.local` file matching `$repo_dir/$repo_path.*.local`.
   - Copy to device save path.
6. Compute a checksum of the copied file at the device save path using `md5sum` (available in BusyBox and coreutils with identical output format). Store only the hash (strip the filename): `md5sum "$device_path" | cut -d' ' -f1`.
7. Write a marker file at `$repo_dir/.continuity/trying/$marker_name` in key-value format:
   ```
   version=local
   checksum=53ff1d8d5aad6a5c521853a254ba9697
   device_path=/mnt/SDCARD/Saves/GB/pokemon_red.srm
   ```
   The marker name is derived from the repo path: replace `/` with `_` (e.g., `gb/pokemon_red.srm` → `gb_pokemon_red.srm`).
8. Log via `pal_log "info"`.

**Output:** Prints the device save path to stdout.

**Returns:** 0 on success, 1 on error.

**Safety:**
- Only copies files to the device save directory — no repo modifications, no commits, no git operations.
- The canonical `.srm` and `.local` file in the repo are never touched.
- The user can swap back and forth freely — each try just overwrites the device save file and re-checksums.

**Marker directory:** `$repo_dir/.continuity/trying/` is created on first use with a `.gitignore` containing `*` (self-contained — prevents markers from being committed without modifying the repo-level `.gitignore`). Different devices can independently try different versions without interfering.

---

#### `ch_get_active_version` — Check which version is in the device's active slot

**Signature:** `ch_get_active_version <repo_dir> <repo_path>`

**Output:** Prints `remote` or `local` to stdout.

**Implementation:**
1. Compute the marker name (same derivation as `ch_try_version`).
2. Read `$repo_dir/.continuity/trying/$marker_name`.
3. If marker exists, extract the `version=` line and print the value.
4. If no marker exists, print `remote` (the default state after conflict detection — the canonical file holds the remote version).

**Returns:** 0 always.

---

#### `ch_clear_try_markers` — Clean up all try markers

**Signature:** `ch_clear_try_markers <repo_dir>`

**Behavior:** Remove all files in `$repo_dir/.continuity/trying/` except `.gitignore`. Called after all conflicts are resolved, or when the UI exits.

**Returns:** 0 always.

---

### Part 2: Sync Engine Safety — Trying-State Awareness

These functions make the trying state visible to the sync pipeline, preventing accidental commits of test copies.

---

#### `ch_is_trying` — Check if a save file is in trying state

**Signature:** `ch_is_trying <repo_dir> <repo_path>`

**Returns:** 0 if the file is in trying state (marker exists), 1 if not.

No output to stdout. This is a predicate function for use in conditionals:
```sh
if ch_is_trying "$repo_dir" "$repo_path"; then
    # skip this file in the sync pipeline
fi
```

**Implementation:** Check for the existence of the try marker file.

---

#### `ch_is_trying_modified` — Detect the Pokémon scenario

**Signature:** `ch_is_trying_modified <repo_dir> <repo_path>`

**Returns:** 0 if the file is in trying state AND has been modified since the try (checksum mismatch), 1 otherwise.

**Implementation:**
1. Read the try marker for `repo_path`. If no marker, return 1.
2. Extract `checksum` and `device_path` from the marker.
3. Compute `md5sum "$device_path" | cut -d' ' -f1` for the current file.
4. If the checksums differ, the file was modified during the try. Return 0.
5. If checksums match, the file is unmodified. Return 1.

**Why this matters:** This is the signal that the user played the game during a try. Their progress is on the device but not in the repo. A UI or status overlay uses this to display "action required."

---

#### `ch_promote_trying` — Accept the modified trying version as the resolution

**Signature:** `ch_promote_trying <repo_dir> <repo_path>`

**Behavior:**

This is the escape hatch for the Pokémon scenario. The user played during a try and now wants to keep their new progress as the authoritative save.

1. Validate that `ch_is_trying_modified` returns 0. If not, return 1 (nothing to promote).
2. Read the `device_path` from the try marker.
3. Copy the current device save (with the user's new progress) over the canonical `.srm` in the repo: `cp "$device_path" "$repo_dir/$repo_path"`.
4. Remove the `.local` file(s) and `.conflict` metadata (same cleanup as `ch_resolve`).
5. Stage, commit: `"resolve: promote modified trying version of $repo_path"`.
6. Push if online.
7. Update `last_known_commit`.
8. Remove the try marker.

**Returns:** 0 on success, 1 on error.

**Why a separate function instead of extending `ch_resolve`:** The semantics are different. `ch_resolve` picks between existing versions (remote or local). `ch_promote_trying` accepts a *new* version that didn't exist when the conflict was detected — the bytes the user generated by playing during the try. It's a distinct operation with a distinct commit message and audit trail.

---

### Part 3: Sync Pipeline Integration

#### Changes to `src/core/runtime_poll.sh`

**`rp_confirm_changes` — Skip trying-state files**

The existing function at lines 34–60 filters candidates by `cmp -s`. Add a trying-state check before the comparison:

```sh
# After pm_local_to_repo succeeds and repo_path is known:
if ch_is_trying "$repo_dir" "$repo_path"; then
    pal_log "info" "Poll confirm: skipping trying-state file: $repo_path"
    continue
fi
```

This is the critical safety gate. Files in trying state are excluded from the entire copy → stage → commit → push pipeline.

**Why here and not in `rp_run`:** Filtering at the earliest point (confirmation) means trying-state files never reach the copy step. This is simpler, safer, and matches the existing filtering pattern (unknown system dirs are already skipped here).

**What about trying-modified files?** `rp_confirm_changes` skips ALL trying-state files, whether modified or not. The trying-modified detection (`ch_is_trying_modified`) is for the *status layer* to surface to the user — the sync pipeline's job is simply to not touch them.

#### Module dependency update

Add `conflict_handler` to the "Required modules" header comment in `runtime_poll.sh`:
```
#   conflict_handler: ch_is_trying()
```

---

### Part 4: Changes to Existing Functions

#### `ch_resolve` — Add device save update + try marker cleanup

Currently, `ch_resolve` resolves the conflict in the repo but does NOT update the device save file. The device might still have a stale "try" version in its save slot.

**Change:** After successful resolution, copy the winning canonical `.srm` to the device save path via `pm_repo_to_local`. Also remove the try marker for this save.

```sh
# After successful commit (in keep_remote and keep_local branches):
local device_path
device_path=$(pm_repo_to_local "$repo_path" 2>/dev/null) || true
if [ -n "$device_path" ] && [ -d "$(dirname "$device_path")" ]; then
    cp "$repo_dir/$repo_path" "$device_path"
fi

# Clean up try marker
local marker_name
marker_name=$(printf '%s' "$repo_path" | sed 's|/|_|g')
rm -f "$repo_dir/.continuity/trying/$marker_name"
```

**Why conditional:** `pm_repo_to_local` may fail if the platform map isn't loaded (e.g., in a test environment). The device save update is best-effort — the resolution itself (repo commit) is the critical path.

---

## Try Marker Format Specification

The try marker is a key-value file (consistent with the output format used elsewhere in this sprint).

**Location:** `$repo_dir/.continuity/trying/$marker_name`

**Marker name derivation:** `repo_path` with `/` replaced by `_`. E.g., `gb/pokemon_red.srm` → `gb_pokemon_red.srm`.

**Contents:**
```
version=local
checksum=53ff1d8d5aad6a5c521853a254ba9697
device_path=/mnt/SDCARD/Saves/GB/pokemon_red.srm
```

| Key | Description |
|-----|-------------|
| `version` | `remote` or `local` — which conflict version was copied |
| `checksum` | MD5 hex digest of the file at copy time (32 hex chars) |
| `device_path` | Absolute path where the file was copied to on the device |

**Why `md5sum`:** Available in both BusyBox and coreutils with identical output format (`<hash>  <filename>`). Not cryptographic for modern security purposes, but we're detecting accidental modification (game saves), not adversarial tampering. A 128-bit hash reliably detects any save file change. Simpler than `cksum` (single value vs CRC+size), and — critically — `cksum` is not available as a BusyBox applet on our target devices.

---

## Output Format Specification

The key-value output format is a contract that platform UIs depend on. It must be stable.

**Rules:**
1. One key-value pair per line, format `key=value`.
2. Keys are `snake_case`, ASCII only.
3. Values are UTF-8, may contain any character except newline.
4. No quoting of values (no `key="value"`) — the first `=` is the delimiter.
5. Blocks are separated by exactly one blank line.
6. Unknown keys should be ignored by consumers (forward compatibility).

**Defined keys for `ch_get_conflict_info`:**

| Key | Type | Description |
|-----|------|-------------|
| `file` | string | Canonical repo-relative `.srm` path |
| `system` | string | Canonical system name (derived from path) |
| `game` | string | Game name without extension (derived from path) |
| `remote_device` | string | Device name that pushed the remote version |
| `remote_timestamp` | ISO-8601 | When the remote version was saved |
| `local_device` | string | Device name that has the local version |
| `local_timestamp` | ISO-8601 | When the local version was saved |
| `status` | enum | `unresolved` (only value for active conflicts) |
| `active_version` | enum | `remote` or `local` — which is in the device save slot |
| `trying_modified` | enum | `yes` or `no` — whether the trying version was modified on device |

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Sync status overlay (green/yellow/red) | 0.10 |
| NextUI SDL2 conflict resolution binary | 1.2 |
| RetroDeck conflict resolution UI | 2.2 |
| Android conflict resolution UI | 3.2 |
| Daemon auto-launch of conflict UI on boot | 1.1 |
| `show2.elf` notification for conflicts | 1.1 |
| Multi-device `.local` selection (3+ device conflicts) | 1.2 |
| Save file preview / hex dump | post-1.0 |
| JSON output format (alternative to key-value) | future, if needed |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `tests/unit/core/test_conflict_ops.sh` | Unit tests for all new `ch_*` functions |
| `tests/integration/test_conflict_resolution_flow.sh` | Integration test: full try → test → resolve lifecycle including Pokémon scenario |

### Files Modified

| File | Change |
|------|--------|
| `src/core/conflict_handler.sh` | Add `ch_get_conflict_info`, `ch_list_conflicts_detailed`, `ch_count_conflicts`, `ch_try_version`, `ch_get_active_version`, `ch_clear_try_markers`, `ch_is_trying`, `ch_is_trying_modified`, `ch_promote_trying`. Modify `ch_resolve` to update device save and clean try marker. |
| `src/core/runtime_poll.sh` | Add trying-state check in `rp_confirm_changes` to skip trying-state files. Update module dependency comment. |
| `docs/design/architecture.md` | Add Conflict Resolution Operations section describing the interactive workflow, trying-state safety, and output format. |

### Directories Created

| Directory | Purpose |
|-----------|---------|
| (none — `$repo_dir/.continuity/trying/` is created at runtime by `ch_try_version`) | |

---

## Acceptance Criteria

### `ch_get_conflict_info`

1. Given a valid `.conflict` file, prints all 10 key-value fields to stdout.
2. `system` is correctly derived from the path (e.g., `snes/super_metroid.srm` → `system=snes`).
3. `game` is correctly derived from the path (e.g., `snes/super_metroid.srm` → `game=super_metroid`).
4. `active_version` defaults to `remote` when no try marker exists.
5. `active_version` returns `local` after `ch_try_version` swaps to local.
6. `trying_modified` returns `no` when file hasn't been modified since try.
7. `trying_modified` returns `yes` when file has been modified since try.
8. Returns 1 if no `.conflict` file exists for the given `repo_path`.
9. Returns 1 if the `.conflict` file is missing required fields.

### `ch_list_conflicts_detailed`

10. Returns empty output (no lines) when no conflicts exist.
11. Returns one block per conflict, separated by blank lines.
12. Each block contains all 10 key-value fields.
13. Multiple conflicts are all present in the output.

### `ch_count_conflicts`

14. Prints `0` when no conflicts exist.
15. Prints the correct count when conflicts exist (tested with 1, 2, and 3 conflicts).

### `ch_try_version` — remote

16. Copies the canonical `.srm` (remote version) to the device save path.
17. After try, device save file byte-matches the repo's canonical `.srm` (verified via `cmp -s`).
18. Writes a try marker with `version=remote`, a `checksum=`, and `device_path=` lines.
19. Prints the device save path to stdout.
20. Does NOT modify the repo — no new git commits after the operation.

### `ch_try_version` — local

21. Copies the `.local` file to the device save path.
22. After try, device save file byte-matches the `.local` file (verified via `cmp -s`).
23. Writes a try marker with `version=local`, a `checksum=`, and `device_path=` lines.
24. Prints the device save path to stdout.
25. Does NOT modify the repo — no new git commits after the operation.

### `ch_try_version` — validation

26. Returns 1 if no `.conflict` file exists for the given `repo_path`.
27. Returns 1 if `version` is not `remote` or `local`.
28. Returns 1 if `pm_repo_to_local` fails (unknown system in platform map).

### `ch_try_version` — idempotency

29. Calling `ch_try_version` twice with `local` produces the same result — device save has local bytes.
30. Swapping from `local` to `remote` and back to `local` leaves device save with local bytes.

### `ch_get_active_version`

31. Returns `remote` when no try marker exists (default state).
32. Returns `local` after `ch_try_version ... local`.
33. Returns `remote` after `ch_try_version ... remote`.

### `ch_is_trying`

34. Returns 0 (true) when a try marker exists for the given `repo_path`.
35. Returns 1 (false) when no try marker exists.
36. Works with both `remote` and `local` try markers.

### `ch_is_trying_modified` — the Pokémon scenario

37. Returns 1 (false) immediately after `ch_try_version` — file hasn't been modified yet.
38. Returns 0 (true) after the device save file is modified (simulated by appending bytes).
39. Returns 1 (false) when no try marker exists.
40. After a new `ch_try_version` call (re-try), returns 1 again — checksum is refreshed.

### `ch_promote_trying`

41. After promoting a modified trying version: canonical `.srm` in the repo matches the device save bytes.
42. `.local` and `.conflict` files are removed.
43. A git commit is created with "promote" in the message.
44. Try marker is removed after promotion.
45. Returns 1 if `ch_is_trying_modified` returns 1 (nothing to promote).
46. `ch_count_conflicts` returns one less after promotion.

### `ch_clear_try_markers`

47. Removes all files in `$repo_dir/.continuity/trying/` except `.gitignore`.
48. Returns 0 even if no markers exist (idempotent).
49. After clearing, `ch_get_active_version` returns `remote` for all conflicts.

### `ch_resolve` — device save update (modified behavior)

50. After `ch_resolve ... keep_remote`: device save file contains the remote version's bytes.
51. After `ch_resolve ... keep_local`: device save file contains the local version's bytes.
52. After `ch_resolve ... keep_newest`: device save file contains the winning version's bytes.
53. After resolution, the try marker for the resolved save is removed.
54. If `pm_repo_to_local` fails (e.g., platform map not loaded), resolution still succeeds — device save update is best-effort.

### Sync pipeline safety (`rp_confirm_changes`)

55. During a poll cycle, files in trying state are NOT included in the confirmed changes list.
56. A trying-state file that has been modified on device is still NOT synced (safety first — user must explicitly promote or resolve).
57. Non-trying-state files in the same poll cycle are still synced normally.
58. After resolution or promotion clears the trying state, the file is eligible for sync in the next poll cycle.

### `.gitignore`

59. `ch_try_version` creates `.continuity/trying/` directory if it doesn't exist.
60. `ch_try_version` creates `.continuity/trying/.gitignore` containing `*` if it doesn't exist.
61. Try markers are never committed to git (verified: `git status` doesn't show them as untracked).

### Code Quality

62. All new code passes `shellcheck` with no errors.
63. All new code passes `busybox ash -n` syntax check.
64. No banned BusyBox ash constructs (see CLAUDE.md table).
65. All variable expansions are quoted.
66. All new functions use `printf` for output, not `echo`.
67. All tests pass under `busybox ash`.
68. Test files pass `shellcheck` and `busybox ash -n`.

---

## Testing Strategy

### Unit Tests (`tests/unit/core/test_conflict_ops.sh`)

Each test creates a fresh `TEST_TMPDIR` with a minimal repo containing conflict artifacts (`.conflict` JSON + `.local` file + canonical `.srm`) and a mock device saves directory.

**Test setup helper** (shared across tests):
```
create_test_conflict <repo_dir> <repo_path> <local_device> <remote_device>
```
Creates the canonical `.srm`, a `.local` file with different bytes, and a `.conflict` JSON.

**`ch_get_conflict_info` tests:**

- Parse valid `.conflict` file → verify all 10 fields present and correct.
- Verify `system` and `game` derivation for multi-segment paths (e.g., `snes/super_metroid.srm`).
- Missing `.conflict` file → returns 1.
- `active_version` is `remote` with no try marker.
- `active_version` is `local` after writing a try marker.
- `trying_modified` is `no` with unmodified file.
- `trying_modified` is `yes` after modifying device save.

**`ch_list_conflicts_detailed` tests:**

- No conflicts → empty output.
- One conflict → one block with all fields.
- Two conflicts → two blocks separated by blank line.
- Verify field values match the underlying `.conflict` files.

**`ch_count_conflicts` tests:**

- No conflicts → prints `0`.
- One conflict → prints `1`.
- Three conflicts → prints `3`.

**`ch_try_version` tests:**

- Try `remote`: device save byte-matches canonical `.srm`.
- Try `local`: device save byte-matches `.local` file.
- Try with nonexistent conflict → returns 1.
- Try with invalid version → returns 1.
- Try with unmapped system → returns 1.
- No git commits after try (count commits before and after).
- Try marker written with all three fields (version, checksum, device_path).
- Swap local → remote → local: final device save matches `.local` bytes.

**`ch_is_trying` tests:**

- No marker → returns 1.
- After try → returns 0.
- After clear → returns 1.

**`ch_is_trying_modified` tests:**

- Immediately after try → returns 1 (not modified).
- After modifying device save → returns 0 (modified).
- After re-try → returns 1 (checksum refreshed).
- No marker → returns 1.

**`ch_promote_trying` tests:**

- Promote modified trying version → repo .srm matches device bytes.
- Conflict artifacts (.local, .conflict) removed.
- Git commit created.
- Try marker removed.
- Non-modified trying version → returns 1 (nothing to promote).

**`ch_get_active_version` tests:**

- No marker → prints `remote`.
- After try local → prints `local`.
- After try remote → prints `remote`.

**`ch_clear_try_markers` tests:**

- Clear with markers → directory empty (except .gitignore).
- Clear with no markers → returns 0.
- After clear, `ch_get_active_version` returns `remote`.

**`ch_resolve` device save update tests:**

- Resolve `keep_remote` → device save has remote bytes, try marker removed.
- Resolve `keep_local` → device save has local bytes, try marker removed.
- Resolve with no platform map loaded → resolution still succeeds (device save update skipped).

**Sync pipeline safety tests (in `rp_confirm_changes`):**

- Trying-state file is excluded from confirmed changes.
- Non-trying-state file in same batch is still included.

### Integration Test (`tests/integration/test_conflict_resolution_flow.sh`)

Full lifecycle test simulating the user experience across the operations layer.

**Setup:**
1. Create bare remote, two working clones (device-a, device-b).
2. Both devices modify the same `.srm` file with different bytes.
3. Device-a pushes first. Device-b pulls → `se_pull` returns 1 (diverged).
4. `ch_handle_pull_conflict` preserves both versions.
5. Create mock device saves directory with platform map loaded.

**Scenario 1: Browse → Try → Resolve**

1. `ch_count_conflicts` → prints `1`.
2. `ch_list_conflicts_detailed` → one block with correct metadata, `trying_modified=no`.
3. `ch_get_active_version` → `remote` (default).
4. `ch_try_version ... local` → device save has device-b's bytes.
5. `ch_get_active_version` → `local`.
6. `ch_try_version ... remote` → device save has device-a's bytes.
7. `ch_get_active_version` → `remote`.
8. `ch_try_version ... local` → swap back.
9. `ch_resolve ... keep_local` → conflict resolved, device save has local bytes.
10. `ch_count_conflicts` → prints `0`.
11. `ch_get_active_version` → `remote` (marker cleared, default state).

**Scenario 2: Resolve without trying (keep_newest)**

1. Set up a new conflict where local timestamp is newer.
2. `ch_resolve ... keep_newest` → resolves to local version.
3. Device save has local bytes.
4. No try markers left behind.

**Scenario 3: Multiple conflicts**

1. Set up two conflicts (`snes/zelda.srm` and `gb/links_awakening.srm`).
2. `ch_count_conflicts` → `2`.
3. `ch_list_conflicts_detailed` → two blocks.
4. Try one conflict, resolve it. `ch_count_conflicts` → `1`.
5. Resolve the other. `ch_count_conflicts` → `0`.
6. `ch_clear_try_markers` → clean exit.

**Scenario 4: The Pokémon Scenario**

The critical path — user plays during a try, sync engine must not commit the modified save.

1. Set up a conflict on `gb/pokemon_red.srm`.
2. `ch_try_version ... local` → local bytes on device.
3. `ch_is_trying_modified` → returns 1 (not modified yet).
4. Simulate gameplay: append 4 bytes to the device save file.
5. `ch_is_trying_modified` → returns 0 (modified!).
6. `ch_get_conflict_info` → `trying_modified=yes`.
7. Run `rp_confirm_changes` with the modified device path in the candidate list → the file is NOT in the output (skipped due to trying state).
8. Verify: no new git commits were created.
9. User decides to keep the new progress: `ch_promote_trying` → repo .srm now has the modified bytes.
10. `ch_count_conflicts` → `0`.
11. `ch_is_trying` → returns 1 (marker cleared).
12. Run another poll cycle — now the file IS eligible for sync (no longer in trying state).

---

## Definition of Done

- [ ] `ch_get_conflict_info` implemented and tested — parses `.conflict` JSON, outputs key-value format with `trying_modified` field.
- [ ] `ch_list_conflicts_detailed` implemented and tested — aggregates info for all conflicts.
- [ ] `ch_count_conflicts` implemented and tested.
- [ ] `ch_try_version` implemented and tested — swaps save version to device, writes marker with checksum, no repo changes.
- [ ] `ch_get_active_version` implemented and tested — reads try marker.
- [ ] `ch_is_trying` implemented and tested — predicate for sync pipeline.
- [ ] `ch_is_trying_modified` implemented and tested — Pokémon scenario detection.
- [ ] `ch_promote_trying` implemented and tested — escape hatch for modified trying saves.
- [ ] `ch_clear_try_markers` implemented and tested.
- [ ] `ch_resolve` modified — updates device save and cleans try marker after resolution.
- [ ] `rp_confirm_changes` modified — skips trying-state files.
- [ ] `.continuity/trying/.gitignore` created by `ch_try_version`.
- [ ] Try marker format documented (version, checksum, device_path).
- [ ] Key-value output format documented in architecture.md.
- [ ] All shell code passes `shellcheck` and `busybox ash -n`.
- [ ] No banned BusyBox ash constructs.
- [ ] All unit tests pass under `busybox ash`.
- [ ] Integration test passes under `busybox ash` — including Pokémon scenario.
- [ ] Sprint summary written to `docs/sprints/sprint-0.9-summary.md` on completion.

---

## Open Questions — Resolved

1. **Marker filename derivation.** ✅ **Decided: keep the simple `sed 's|/|_|g'` approach.** Collision between `a/b.srm` and `a_b.srm` is astronomically unlikely for game saves. Simple and readable for debugging.

2. **`pm_repo_to_local` dependency in `ch_try_version`.** ✅ **Decided: unit tests load a real platform map** (copy `config/platform_maps/nextui.json` to the test temp dir and call `pm_load_platform_map`). This is consistent with the existing test pattern used in `test_conflict_handler.sh` and `test_runtime_poll.sh`. Integration tests also load a real platform map.

3. **Checksum tool.** ✅ **Decided: use `md5sum` instead of `cksum`.** BusyBox does not include `cksum` as an applet. `md5sum` is available in both BusyBox and coreutils with identical output format (`<32-char-hex>  <filename>`). The marker stores only the hash: `md5sum "$path" | cut -d' ' -f1`. Simpler (single value) and more reliable (128-bit hash vs 32-bit CRC).

4. **Should `ch_promote_trying` also work for unmodified trying saves?** ✅ **Decided: no — keep the restriction.** If the file is unmodified, use `ch_resolve` instead. `ch_promote_trying` is specifically for the "new progress during try" case (the Pokémon scenario). Distinct semantics deserve a distinct function with a distinct commit message.
