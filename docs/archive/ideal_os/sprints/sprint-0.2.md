# Sprint 0.2 — Shared Data Contracts

## Phase

Phase 0 — Foundation

## Approved

<!-- The orchestrator or user sets this date when the spec is approved. -->
<!-- Agents MUST NOT begin implementation until this field contains a date. -->
2026-03-11

## Status

`complete`

Status definitions:
- `not-started` — Spec is being drafted or under review. No implementation allowed.
- `approved` — Spec is locked and approved for implementation. Set the Approved date above.
- `in-progress` — Actively implementing.
- `validation` — Implementation complete. Running acceptance criteria checks.
- `complete` — All acceptance criteria met, validated, merged.

## Goal

Implement the three shared infrastructure modules (`game_identity.sh`, `event_bus.sh`, `atomic_write.sh`) that every downstream subsystem depends on. After this sprint, any module can parse game IDs, emit and read events, and write files atomically.

## Reference Specs

- `CLAUDE.md` — Architecture Reference (lines 226–270), Coding Standards, BusyBox Ash Compatibility
- `docs/architecture/ideal_os_session_manager_technical_architecture_spec.md` — Game ID usage in session records, atomic write requirements (lines 322–341, 548–567)
- `docs/architecture/ideal_os_cloud_sync_and_cross_device_continuity_spec.md` — Artifact ID format, event types emitted by sync (lines 186–203)
- `docs/architecture/ideal_os_background_services_and_task_scheduler_spec.md` — Event subscription model, Class A critical writes (lines 146–162)

## Scope

### In Scope

- [ ] Implement `src/common/game_identity.sh` — game ID parsing, validation, system taxonomy, ROM/save path helpers, hash generation
- [ ] Implement `src/common/event_bus.sh` — file-based event log: emit, read, validate events
- [ ] Implement `src/common/atomic_write.sh` — write-to-temp → fsync → rename-into-place helper
- [ ] Create event schema fixture file for test reference
- [ ] Unit tests for all three modules
- [ ] All code passes `busybox ash -n` syntax check and `shellcheck`

### Out of Scope

- Session Manager implementation (Phase 1)
- Cloud Sync, Task Scheduler, or any subsystem that *uses* these modules
- Log rotation or event archival (future sprint)
- Runtime configuration files for subsystems
- System taxonomy sourced from external data (hardcoded list is sufficient for now)
- `config/emulators/systems/session-support.json` (belongs to Session Manager sprint)

## Files to Create or Modify

| Action | Path | Description |
|--------|------|-------------|
| Create | `tests/unit/common/` | Test directory for common module unit tests |
| Create | `src/common/game_identity.sh` | Game ID model: parse, validate, path helpers, hash |
| Create | `src/common/event_bus.sh` | File-based event bus: emit, read, validate |
| Create | `src/common/atomic_write.sh` | Atomic file write helper |
| Create | `tests/unit/common/test_game_identity.sh` | Unit tests for game identity |
| Create | `tests/unit/common/test_event_bus.sh` | Unit tests for event bus |
| Create | `tests/unit/common/test_atomic_write.sh` | Unit tests for atomic write |
| Create | `tests/fixtures/event_samples.jsonl` | Sample events for test validation |
| Modify | `docs/roadmap.md` | Update Sprint 0.2 status to `in-progress` |

---

## Module Specifications

### `src/common/game_identity.sh`

Sourced by other scripts (`. src/common/game_identity.sh`), not executed directly.

#### Constants

```sh
# Supported systems — extend as needed
SUPPORTED_SYSTEMS="snes gba gb gbc nes n64 nds psx psp md sms gg tg16 pce a26 arcade mame fbneo"
```

The taxonomy is a flat newline-delimited string (no arrays — BusyBox ash).

#### Functions

| Function | Signature | Returns/Prints | Description |
|----------|-----------|----------------|-------------|
| `game_id_parse_system` | `game_id_parse_system <game_id>` | Prints system portion to stdout | Extract system from `system:game_name` |
| `game_id_parse_name` | `game_id_parse_name <game_id>` | Prints game name to stdout | Extract name from `system:game_name` |
| `game_id_validate` | `game_id_validate <game_id>` | Returns 0 valid, 1 invalid | Validates format: exactly one colon, non-empty parts, system in taxonomy |
| `game_id_create` | `game_id_create <system> <game_name>` | Prints `system:game_name` to stdout | Construct a game_id from parts |
| `game_id_rom_dir` | `game_id_rom_dir <game_id>` | Prints ROM directory path | Returns `/Roms/<SYSTEM_UPPER>` |
| `game_id_save_dir` | `game_id_save_dir <game_id>` | Prints save directory path | Returns `/userdata/saves/<system>` |
| `game_id_hash` | `game_id_hash <file_path>` | Prints SHA-256 hash to stdout | SHA-256 of the file at the given path |
| `game_id_short_hash` | `game_id_short_hash <file_path>` | Prints first 8 chars of SHA-256 | Truncated hash for session IDs |
| `game_id_system_supported` | `game_id_system_supported <system>` | Returns 0 if supported, 1 otherwise | Check system against taxonomy |

#### Design Notes

- System names are always lowercase in game IDs (`snes`, not `SNES`).
- ROM directory uses uppercase system name (NextUI convention: `/Roms/SNES/`).
- `game_id_hash` uses `sha256sum` (coreutils) or `busybox sha256sum`. Falls back with error if neither is available.
- Game names may contain any characters except colons (validated by `game_id_validate`). No character whitelist — ROM-derived names will have spaces, dots, parentheses, etc.

---

### `src/common/event_bus.sh`

Sourced by other scripts. Provides a file-based append-only event log.

#### Configuration

```sh
# Default event log path — can be overridden before sourcing
EVENT_LOG_DIR="${EVENT_LOG_DIR:-/tmp/ideal_os/events}"
EVENT_LOG_FILE="${EVENT_LOG_DIR}/system-events.log"
```

For tests, `EVENT_LOG_DIR` is overridden to a temp directory.

#### Event Schema

Every event is a single JSON line (JSONL format):

```json
{"_schema_version":"1.0","timestamp":"2026-03-10T21:14:55Z","source":"session","event_type":"session_created","payload":{"session_id":"snes-a13fd98c-20260310T211455Z"}}
```

Required fields:
- `_schema_version` — Always `"1.0"`
- `timestamp` — ISO 8601 UTC (`date -u '+%Y-%m-%dT%H:%M:%SZ'`)
- `source` — Module name (e.g., `session`, `sync`, `tasks`, `notifications`)
- `event_type` — Machine-readable event identifier, `snake_case`
- `payload` — JSON object (may be empty `{}`)

#### Functions

| Function | Signature | Returns/Prints | Description |
|----------|-----------|----------------|-------------|
| `event_bus_init` | `event_bus_init` | Returns 0 on success | Create event log directory and file if missing |
| `event_bus_emit` | `event_bus_emit <source> <event_type> [payload_json]` | Returns 0 on success | Append event to log. Payload defaults to `{}` |
| `event_bus_read` | `event_bus_read [--source <s>] [--type <t>] [--after <line>]` | Prints matching events to stdout | Read/filter events. `--after N` skips first N lines |
| `event_bus_count` | `event_bus_count` | Prints line count | Total events in log |
| `event_bus_validate` | `event_bus_validate <json_line>` | Returns 0 valid, 1 invalid | Check required fields present |

#### Design Notes

- `event_bus_emit` generates the timestamp internally — callers do not supply it.
- Append uses `atomic_write.sh` approach: write to temp, then `cat >> log`. For append-only logs, a simple `printf >> file` with error checking is acceptable since partial appends are detectable (incomplete JSON line).
- No `jq` dependency. JSON is constructed with `printf` and parsed with `grep`/`sed` for filtering. This is intentionally simple — the event bus is plumbing, not a query engine.
- `event_bus_init` is idempotent and must be called before first use.

---

### `src/common/atomic_write.sh`

Sourced by other scripts. Provides crash-safe file writes.

#### Functions

| Function | Signature | Returns/Prints | Description |
|----------|-----------|----------------|-------------|
| `atomic_write` | `atomic_write <dest_path> <content>` | Returns 0 on success | Write content to temp → fsync → rename to dest |
| `atomic_write_file` | `atomic_write_file <dest_path> <source_path>` | Returns 0 on success | Copy source to temp → fsync → rename to dest |
| `atomic_write_stdin` | `atomic_write_stdin <dest_path>` | Returns 0 on success | Read stdin to temp → fsync → rename to dest |

#### Implementation Details

1. Create temp file in the **same directory** as `dest_path` (required for atomic rename on same filesystem): `mktemp "${dest_dir}/.tmp.XXXXXX"`
2. Write content to temp file.
3. Call `sync` on the temp file. Use `fsync` BusyBox applet if available, fall back to `sync` (full filesystem sync — less efficient but safe).
4. Rename temp file to destination: `mv -f "$tmp" "$dest"` (atomic on POSIX).
5. On failure at any step: remove temp file, return non-zero, print error to stderr.

#### Design Notes

- Temp file is in the same directory as destination to guarantee same-filesystem rename.
- `fsync` availability: BusyBox may or may not include the `fsync` applet. The helper checks at runtime and falls back to `sync`. A warning is printed to stderr on first fallback.
- Content is passed as a string argument for `atomic_write`, which limits size to shell argument limits (~128KB on Linux). For larger data, use `atomic_write_stdin` with a pipe.
- Parent directory of `dest_path` must exist — the helper does not create directories.

---

## Acceptance Criteria

All must pass for the sprint to be considered complete.

### Game Identity (AC 1–6)

1. **Parse system:** `game_id_parse_system "snes:super_metroid"` prints `snes`.
2. **Parse name:** `game_id_parse_name "snes:super_metroid"` prints `super_metroid`.
3. **Validate rejects bad IDs:** `game_id_validate "nocolon"` returns 1. `game_id_validate "bad:name:extra"` returns 1. `game_id_validate ""` returns 1.
4. **Validate accepts good IDs:** `game_id_validate "snes:super_metroid"` returns 0 for all systems in the taxonomy.
5. **Path helpers correct:** `game_id_rom_dir "snes:super_metroid"` prints `/Roms/SNES`. `game_id_save_dir "snes:super_metroid"` prints `/userdata/saves/snes`.
6. **Hash generation works:** `game_id_hash` on a known file produces the correct SHA-256. `game_id_short_hash` returns first 8 characters.

### Event Bus (AC 7–12)

7. **Init creates log:** After `event_bus_init`, the log directory and file exist.
8. **Emit appends event:** `event_bus_emit "session" "session_created" '{"id":"test"}'` adds exactly one line to the log file.
9. **Emitted event has all fields:** The appended line contains `_schema_version`, `timestamp`, `source`, `event_type`, and `payload`.
10. **Read filters by source:** `event_bus_read --source session` returns only session events when mixed events exist.
11. **Read filters by type:** `event_bus_read --type session_created` returns only matching events.
12. **Validate rejects incomplete events:** `event_bus_validate '{"source":"x"}'` (missing required fields) returns 1.

### Atomic Write (AC 13–16)

13. **Basic write works:** `atomic_write "/tmp/test_dest.json" '{"key":"value"}'` creates the file with correct content.
14. **Atomic property:** No partial content is visible at `dest_path` — the file either has old content or new content, never a half-write. (Tested by checking file content after write.)
15. **Stdin variant works:** `printf '{"key":"value"}' | atomic_write_stdin "/tmp/test_dest.json"` produces correct file.
16. **Failure cleanup:** If the destination directory doesn't exist, `atomic_write` returns non-zero, prints to stderr, and leaves no temp files behind.

### Cross-Cutting (AC 17–19)

17. **BusyBox syntax clean:** `busybox ash -n` passes on all three modules and all three test files (6 files total).
18. **All tests pass:** `busybox ash scripts/test.sh` runs all unit tests and exits 0.
19. **No external dependencies:** Modules require only POSIX utilities and BusyBox applets. No `jq`, `python`, or compiled tools.

## Test Plan

### Automated Tests

| Test | Type | Location | Validates |
|------|------|----------|-----------|
| `test_game_identity` | unit | `tests/unit/common/test_game_identity.sh` | AC 1–6 |
| `test_event_bus` | unit | `tests/unit/common/test_event_bus.sh` | AC 7–12 |
| `test_atomic_write` | unit | `tests/unit/common/test_atomic_write.sh` | AC 13–16 |

### Test Structure

Each test file follows the pattern established in Sprint 0.1:

```sh
#!/bin/sh
set -e

# Setup
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source module under test
. "$REPO_ROOT/src/common/game_identity.sh"

# Test cases
test_parse_system() { ... }
test_parse_name() { ... }
test_validate_good() { ... }
test_validate_bad() { ... }
# ...

# Run all tests
test_parse_system
test_parse_name
# ...

printf "All game_identity tests passed\n"
```

Tests must create their own temp directories, clean up after themselves, and run under `busybox ash`.

### Manual Validation

- [ ] `busybox ash -n src/common/game_identity.sh` — no errors
- [ ] `busybox ash -n src/common/event_bus.sh` — no errors
- [ ] `busybox ash -n src/common/atomic_write.sh` — no errors
- [ ] `busybox ash -n tests/unit/common/test_game_identity.sh` — no errors
- [ ] `busybox ash -n tests/unit/common/test_event_bus.sh` — no errors
- [ ] `busybox ash -n tests/unit/common/test_atomic_write.sh` — no errors
- [ ] `busybox ash scripts/test.sh` — all tests pass, exit 0
- [ ] Visually inspect an emitted event in the log file — confirm it's valid JSON with all required fields

## Dependencies

- Sprint 0.1 (complete) — repo structure and test runner exist
- `busybox ash` installed in dev environment
- `sha256sum` available (coreutils or BusyBox applet)

## Review Checklist

Since no separate QA agent is used for this sprint, the implementer must self-validate against this checklist before marking the sprint complete.

### Code Quality

- [ ] All `.sh` files start with `#!/bin/sh` and `set -e`
- [ ] All variable expansions are quoted: `"$var"`
- [ ] No bashisms: no `[[ ]]`, no arrays, no `${var//}`, no `<<<`, no `function` keyword
- [ ] `printf` used instead of `echo` for all output
- [ ] `snake_case` for all function and variable names
- [ ] `readonly` used for constants
- [ ] Error messages go to stderr (`>&2`)
- [ ] `local var; var=$(cmd)` pattern used (not `local var=$(cmd)`)

### BusyBox Compatibility

- [ ] `busybox ash -n` passes on all 6 `.sh` files
- [ ] No use of `set -o pipefail`, `trap ERR`, process substitution, or here-strings
- [ ] `mktemp` uses `/tmp/prefix.XXXXXX` format (no `--tmpdir`)
- [ ] Tested by actually running under `busybox ash`, not just `sh` or `bash`

### Functional Correctness

- [ ] `game_id_validate` rejects: empty string, no colon, multiple colons, unknown system, empty system, empty name
- [ ] `game_id_validate` accepts: all systems in taxonomy with valid names
- [ ] `game_id_hash` produces correct SHA-256 for a known input
- [ ] `event_bus_emit` creates valid JSONL (one complete JSON object per line)
- [ ] `event_bus_read` filtering returns correct subset
- [ ] `atomic_write` destination file has correct content and permissions
- [ ] `atomic_write` leaves no temp files on success or failure
- [ ] Concurrent reads during `atomic_write` never see partial content

### Test Coverage

- [ ] Every public function has at least one positive and one negative test
- [ ] Edge cases tested: empty strings, special characters in game names, missing files for hash
- [ ] Tests are self-contained — create temp dirs, clean up on exit (including on failure via trap)
- [ ] Tests pass when run individually and as part of the full suite
- [ ] Tests run under `busybox ash`, not just `bash`

### Sprint Hygiene

- [ ] No files created outside the Files table
- [ ] No unrelated changes
- [ ] Commit messages follow `<type>(<scope>): <description>` format
- [ ] Sprint summary written to `docs/sprints/sprint-0.2-summary.md`
- [ ] Roadmap updated to reflect completion

## Notes

- **No jq:** The target device may not have `jq`. All JSON construction and parsing uses `printf`, `grep`, and `sed`. This is a deliberate trade-off — correctness for simple schemas over generality.
- **System taxonomy is a starting point.** The list of supported systems will grow. New systems are added by appending to `SUPPORTED_SYSTEMS` in `game_identity.sh`. No config file indirection needed at this stage.
- **Event bus is intentionally simple.** It's a structured append-only log, not a message broker. The complexity lives in the consumers (Task Scheduler, Notification System), not the bus itself.
- **fsync fallback.** On devices where the BusyBox `fsync` applet is unavailable, `atomic_write.sh` falls back to `sync` (full filesystem sync). This is slower but safe. A warning is printed once to stderr.
