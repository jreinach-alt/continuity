# Sprint 0.3 — Enrollment

**Status:** Approved
**Date:** 2026-03-13
**Dependencies:** Sprint 0.2 (PAL framework, path mapper)

## Goal

Implement the enrollment flow that transforms a blank device into a Continuity-enabled device: clone the user's save repo, store the PAT as a git credential, register the device in the repo, and persist the device name for the PAL to read on subsequent boots. Sprint 0.3 also delivers the NextUI SD card enrollment trigger and a test enrollment helper that enables all future integration tests to run without a network connection or physical SD card.

---

## Reference Specs

- `docs/design/architecture.md` — enrollment flow section, `.continuity/` directory layout, device JSON schema
- `docs/design/pal.md` — PAL variables used by enrollment, device name lifecycle, `pal_init()` and device name file convention
- `docs/design/security.md` — credential storage per platform, token storage locations, FAT32 security reality

---

## Scope

### 1. Sync Engine (`src/core/sync_engine.sh`)

The sync engine is a prerequisite for enrollment: `enroll_run` needs `se_clone` for the initial repo clone and `se_push` to register the device. Sprint 0.2 scoped `sync_engine.sh` for cold start; Sprint 0.3 completes and delivers it. If Sprint 0.2 has already produced a `sync_engine.sh`, this sprint integrates and tests it against enrollment. If Sprint 0.2 has not been implemented yet, this sprint delivers `sync_engine.sh` from scratch.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `se_init` | `(repo_dir, device_name)` | void | Set module-level device name (`_SE_DEVICE_NAME`). Configure `user.email` and `user.name` in the repo's local git config if not already set. Must be called before `se_commit` (which needs the device name for commit trailers). Does NOT need to be called before `se_pull`, `se_push`, etc. |
| `se_clone` | `(repo_url, target_dir)` | 0 success, 1 failure | `git clone <repo_url> <target_dir>`. Used only during enrollment. Runs `$CONTINUITY_GIT_BIN clone`. |
| `se_pull` | `(repo_dir)` | 0 success, 1 diverged, 2 network error | `git -C "$repo_dir" pull --ff-only origin main`. Returns 1 if fast-forward is not possible (diverged history), 2 on network failure. |
| `se_stage_files` | `(repo_dir, file_list)` | 0 success, 1 failure | `git -C "$repo_dir" add` each path in the newline-delimited `file_list`. Paths are relative to the repo working tree. |
| `se_commit` | `(repo_dir, file_list, [subject_override])` | 0 success, 1 failure | Commit staged files with auto-generated message. Subject line: `<system>/<filename> updated` (1 file) or `N saves updated` (multiple). Trailer lines: `device: <name>` and `timestamp: <ISO 8601>`. Uses `_SE_DEVICE_NAME` set by `se_init`. The optional `subject_override` argument replaces the auto-generated subject line (used by enrollment for `"enroll: register <device_name>"`). |
| `se_push` | `(repo_dir)` | 0 success, 1 persistent failure, 2 offline/deferred | `git -C "$repo_dir" push origin main`. Retries on network error with exponential backoff (2s, 4s, 8s, 16s). Returns 1 after all retries exhausted. Returns 2 if `pal_is_online` returns 1 at time of call (caller asked to push but device is offline — commit is queued locally). |
| `se_has_staged_changes` | `(repo_dir)` | 0 staged changes exist, 1 index clean | Check `git -C "$repo_dir" diff --cached --quiet`. |
| `se_has_unpushed_commits` | `(repo_dir)` | 0 local is ahead, 1 up to date | Check `git -C "$repo_dir" log @{u}..HEAD`. |
| `se_get_head_commit` | `(repo_dir)` | prints hash to stdout | Print the current HEAD commit hash via `git -C "$repo_dir" rev-parse HEAD`. |

**Implementation notes:**

- All git invocations use `$CONTINUITY_GIT_BIN` (from PAL) — never the literal string `git`.
- All git commands specify the repo explicitly using `-C "$repo_dir"` — never depend on the current working directory. The `repo_dir` parameter is passed to every function that touches git.
- Module-level state is limited to `_SE_DEVICE_NAME` (prefixed with `_SE_` to signal private module state). There is no `_SE_REPO_DIR` — the repo directory is always passed explicitly.
- `se_clone` does not call `se_init`. The caller is responsible for calling `se_init` after a successful clone.
- `se_push` captures stderr into a temp file to distinguish network errors (containing `unable to connect`, `failed to connect`, `could not resolve`, `timeout`, `SSL`) from other errors (auth failure, force-push rejection — these should not be retried).
- `se_push` checks `pal_is_online` before attempting a push. If offline, it returns 2 immediately without retrying. This allows callers to distinguish "tried and failed" (return 1) from "didn't try because offline" (return 2).
- The optional third argument to `se_commit` allows callers (like enrollment) to specify a custom commit subject line. When provided, it replaces the auto-generated `<system>/<filename> updated` or `N saves updated` subject. The trailer lines (`device:` and `timestamp:`) are always appended regardless.
- Commit message format:
  ```
  snes/super_metroid.srm updated

  device: my-brick
  timestamp: 2026-03-12T14:30:00Z
  ```
  Timestamp uses `date -u '+%Y-%m-%dT%H:%M:%SZ'`. If the platform's `date` does not support `-u`, fall back to `date '+%Y-%m-%dT%H:%M:%SZ'` (local time with Z suffix is acceptable for constrained devices).
- `se_stage_files` accepts a newline-delimited list because BusyBox ash has no arrays. The caller constructs the list with newlines:
  ```sh
  file_list="snes/super_metroid.srm
  gba/minish_cap.srm"
  se_stage_files "$repo_dir" "$file_list"
  ```
- **Important:** `se_stage_files` must use `git add <path>` (not `git add -u`). Using `-u` would skip untracked files, which breaks Sprint 0.8's conflict handler (`.local` and `.conflict` artifacts are new untracked files that must be staged). Coding agents must verify this during implementation.
- Git configuration for the repo (user.email, user.name) is set to minimal values during `se_init` if not already set. This prevents git commit from failing on devices with no global git config:
  ```sh
  $CONTINUITY_GIT_BIN -C "$repo_dir" config user.email "continuity@device"
  $CONTINUITY_GIT_BIN -C "$repo_dir" config user.name "Continuity"
  ```

---

### 2. Core Enrollment (`src/core/enrollment.sh`)

Platform-agnostic enrollment logic. Called by platform enrollment triggers (SD card, web form, CLI). Has no knowledge of how credentials arrived or what platform is running — that is the platform trigger's concern.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `enroll_run` | `(repo_url, device_name, pat)` | 0 success, 1 failure | Full enrollment flow. In order: configure git auth, clone repo, write device name, write device JSON, commit and push device registration, create `.continuity/` gitignore. Calls `pal_log` at each step. |
| `enroll_is_enrolled` | `()` | 0 enrolled, 1 not enrolled | Returns 0 if `$CONTINUITY_REPO_DIR` exists, is a valid git repo, and the device name file exists at `$CONTINUITY_REPO_DIR/.continuity/device_name`. |
| `enroll_write_device_json` | `(device_name, platform)` | 0 success, 1 failure | Write `.continuity/devices/<device_name>.json` inside the cloned repo. This file is committed. |
| `enroll_store_credential` | `(pat)` | 0 success, 1 failure | Write the PAT to `$CONTINUITY_REPO_DIR/.continuity/credentials`. Set mode 0600 on systems that support it. |
| `enroll_configure_git_auth` | `(repo_dir)` | 0 success, 1 failure | Configure the repo's git credential helper to read the stored PAT file. Sets `credential.helper` in the repo's local git config to a shell script that outputs the PAT. |

**`enroll_run` flow in detail:**

```
enroll_run(repo_url, device_name, pat)
  1. Validate: repo_url non-empty, device_name non-empty, pat non-empty.
     Validate device_name format: must match [a-z0-9-], must not be empty,
     must not start or end with a hyphen, must not exceed 32 characters.
     Return 1 with descriptive error if validation fails.
  2. enroll_store_credential(pat)            # Write PAT to .continuity/credentials
                                             # (temp location pre-clone — see note below)
  2.5. Configure temporary git credential helper for the clone operation:
       Write a temporary credential helper script that reads from the temp PAT location.
       Set GIT_ASKPASS or configure git credential.helper globally for this process.
  3. se_clone(repo_url, CONTINUITY_REPO_DIR) # git clone
  3.5. Verify default branch is main:
       branch=$("$CONTINUITY_GIT_BIN" -C "$CONTINUITY_REPO_DIR" branch --show-current)
       If branch != "main": pal_log "error" "Repo default branch is '$branch', expected 'main'"; return 1
  4. se_init(CONTINUITY_REPO_DIR, device_name)
  5. enroll_configure_git_auth(CONTINUITY_REPO_DIR)  # Configure credential helper
  6. enroll_write_device_json(device_name, CONTINUITY_PLATFORM)
  7. Write device_name to .continuity/device_name     # Local-only, gitignored
  8. Ensure .continuity/.gitignore exists with:
       credentials
       git_credential_helper.sh
       device_name
       sentinel
       last_known_commit
       clean_shutdown
  9. se_stage_files "$CONTINUITY_REPO_DIR" ".continuity/devices/<device_name>.json\n.continuity/.gitignore"
  10. se_commit "$CONTINUITY_REPO_DIR" ".continuity/devices/<device_name>.json\n.continuity/.gitignore" "enroll: register <device_name>"
  11. se_push "$CONTINUITY_REPO_DIR"
  12. pal_log "info" "Enrollment complete: <device_name>"
  Return 0
```

**Pre-clone credential storage note:**

The PAT must be stored before `se_clone` so the credential helper is available to authenticate the clone itself. The enrollment trigger (or `pal_init`) is responsible for ensuring `$(dirname $CONTINUITY_REPO_DIR)` exists before calling `enroll_run`. `enroll_store_credential` writes the PAT to a temporary location under that parent directory:

- Pre-clone: `$(dirname $CONTINUITY_REPO_DIR)/.continuity_credentials_tmp`
- Post-clone: `$CONTINUITY_REPO_DIR/.continuity/credentials`

After the clone, `enroll_run` moves the tmp file to its final location and re-runs `enroll_configure_git_auth`. This is transparent to callers. The important invariant is that the credential file is at `$CONTINUITY_REPO_DIR/.continuity/credentials` after `enroll_run` succeeds.

**`enroll_configure_git_auth` details:**

Git credential helpers on constrained devices cannot use the standard `store` or `osxkeychain` helpers. Instead, use a per-repo credential helper that is a shell script printing the PAT:

```sh
# Written to $CONTINUITY_REPO_DIR/.continuity/git_credential_helper.sh
#!/bin/sh
printf 'username=x-token\npassword=%s\n' "$(cat "$CREDENTIALS_FILE")"
```

The repo config entry:
```
[credential]
    helper = /path/to/.continuity/git_credential_helper.sh
```

This shell-script credential helper works on BusyBox ash without any credential helper binaries. The `username` is `x-token` (GitHub PAT convention — the username is irrelevant when using a token).

**Device JSON format:**

```json
{
  "_schema_version": "1.0",
  "device_name": "my-brick",
  "platform": "nextui",
  "enrolled_at": "2026-03-12T14:30:00Z",
  "last_sync": null,
  "last_push": null
}
```

Fields `last_sync` and `last_push` are `null` at enrollment time; updated by the daemon in later sprints.

**`.continuity/.gitignore` format:**

```
credentials
git_credential_helper.sh
device_name
sentinel
last_known_commit
clean_shutdown
```

These are all local-only device state files. The `.continuity/devices/` directory and `.continuity/config.json` are committed and synced.

**`enroll_is_enrolled` check:**

Checks in order:
1. `$CONTINUITY_REPO_DIR` is a directory
2. `$CONTINUITY_REPO_DIR/.git` is a directory (valid git repo)
3. `$CONTINUITY_REPO_DIR/.continuity/device_name` is a non-empty file

Returns 0 only if all three pass.

**Error handling:**

`enroll_run` is atomic from the caller's perspective: if any step fails, it calls `pal_log "error"` with a clear message and returns 1. It does not attempt partial cleanup (the caller or a future uninstall routine handles that). Critically, if `se_clone` fails (bad URL, bad token, no network), the failure is logged and returned immediately — no subsequent steps run.

---

### 3. NextUI SD Card Enrollment Trigger (`src/platforms/nextui/enroll_sd_card.sh`)

Detects and imports enrollment credentials from an SD card file. This is the primary enrollment method for TrimUI Brick.

**The SD card setup file:**

The user creates `setup.json` at the root of the SD card:
```json
{
  "repo_url": "https://github.com/alice/my-saves.git",
  "pat": "github_pat_...",
  "device_name": "my-brick"
}
```

The user copies this file to the SD card root from their PC, inserts the SD card, and powers on the device. The enrollment trigger detects and processes this file.

**Detection path:**

The file is detected at `$CONTINUITY_SD_ROOT/setup.json`. On NextUI, `CONTINUITY_SD_ROOT` is `/mnt/SDCARD`. The enrollment trigger looks for `$CONTINUITY_SD_ROOT/setup.json`. `CONTINUITY_SD_ROOT` is an optional PAL variable — see `docs/design/pal.md`.

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `esd_detect_setup_file` | `()` | 0 found, 1 not found | Check if `$CONTINUITY_SD_ROOT/setup.json` exists. |
| `esd_parse_setup_file` | `(setup_file)` | 0 success, 1 parse error | Parse `setup.json`, set module-level variables `_ESD_REPO_URL`, `_ESD_PAT`, `_ESD_DEVICE_NAME`. Validates all three fields are present and non-empty. |
| `esd_import` | `()` | 0 success, 1 failure | Full SD card import: detect file, parse, call `enroll_run`, delete `setup.json` on success. |

**`esd_import` flow:**

```
esd_import()
  1. esd_detect_setup_file() — if not found, return 0 (no-op, not an error)
  2. esd_parse_setup_file(setup_file) — if parse fails, log error, return 1
                                        (leave setup.json intact so user can fix it)
  3. Verify not already enrolled: enroll_is_enrolled() — if already enrolled,
     log warning "already enrolled, skipping setup.json", delete setup.json, return 0
  4. enroll_run(repo_url, device_name, pat) — if fails, log error, return 1
                                              (leave setup.json intact for retry)
  5. Delete setup.json — plaintext PAT must not persist after successful enrollment
  6. pal_log "info" "SD card enrollment complete: <device_name>"
  7. Return 0
```

**JSON parsing (BusyBox ash, no jq):**

```sh
_ESD_REPO_URL=$(sed -n 's/^[[:space:]]*"repo_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$setup_file")
_ESD_PAT=$(sed -n 's/^[[:space:]]*"pat"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$setup_file")
_ESD_DEVICE_NAME=$(sed -n 's/^[[:space:]]*"device_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$setup_file")
```

Each `sed` pattern anchors the key match to the start of the line (after optional whitespace), preventing false matches against key substrings appearing in values. The `setup.json` format is controlled by us. This parse strategy is sufficient for well-formed input. Malformed JSON (e.g. missing closing quote) will produce an empty variable, which is caught by the non-empty validation in `esd_parse_setup_file`.

**Security:**

- `setup.json` is deleted immediately after successful enrollment. A failed enrollment leaves the file intact to allow retry — this is intentional but documented: the user should be aware the file is still on the SD card.
- `esd_import` is intended to be called once at boot (before the daemon enters its main loop). Once enrollment is complete, `enroll_is_enrolled` will return 0 and `esd_import` skips processing.

---

### 4. Test Enrollment Helper (`tests/fixtures/enroll_test.sh`)

A scripted helper for CI integration tests. Creates a complete enrollment environment without a network connection, real GitHub repo, or physical SD card.

**What it provides:**

1. A bare git repo on the local filesystem acting as the "remote."
2. A pre-seeded set of `.srm` save files in the fake remote.
3. Calls `enroll_run` using the test PAL and the local bare repo URL (`file:///...`).
4. After running, the test's working directory is a fully enrolled device (repo cloned, device JSON committed, device name file written).

**Functions:**

| Function | Signature | Returns | Description |
|----------|-----------|---------|-------------|
| `et_setup` | `(test_tmpdir)` | 0 success, 1 failure | Create bare remote repo, seed with initial `.srm` files, run enrollment using test PAL. Sets `ET_REMOTE_DIR`, `ET_REPO_DIR` variables for tests to use. |
| `et_add_remote_save` | `(system, filename, content)` | 0 success, 1 failure | Add a `.srm` file to the bare remote (simulates a save from another device). Commits directly to the bare remote. |
| `et_teardown` | `()` | void | Remove all temp directories created by `et_setup`. Should be called in test EXIT trap. |

**Usage pattern in integration tests:**

```sh
#!/bin/sh
set -e
TEST_TMPDIR=$(mktemp -d)
trap 'et_teardown' EXIT

. "$TESTS_DIR/fixtures/pal_test.sh"
. "$TESTS_DIR/fixtures/enroll_test.sh"

et_setup "$TEST_TMPDIR"

# Test body: ET_REMOTE_DIR is the bare remote, ET_REPO_DIR is the enrolled clone
# ... assertions ...
```

**Pre-seeded saves in the bare remote:**

`et_setup` seeds the bare remote with three saves to enable cold start and boot pull tests:
- `snes/super_metroid.srm` (8 bytes of test data)
- `gba/minish_cap.srm` (8 bytes of test data)
- `gb/links_awakening.srm` (8 bytes of test data)

These files exist in the remote before enrollment, so the enrolled device can test pulling them.

**No real GitHub interaction:**

`et_setup` uses a `file:///` URL as the remote. All git operations (clone, push, pull) operate on the local filesystem. No network access is required. The test PAL's `pal_is_online()` returns 0 (always online), which is correct since "online" for test purposes means the local filesystem remote is reachable.

---

## Out of Scope

| Item | Sprint |
|------|--------|
| Cold start sync (scanning saves after enrollment) | 0.4 |
| Boot pull (syncing on subsequent boots) | 0.5 |
| Runtime poll (detecting save changes during play) | 0.6 |
| Conflict handler | 0.8 |
| NextUI daemon (boot hook, PID management, poll loop) | 1.1 |
| NextUI Tool PAK (UI for sync status and conflict resolution) | 1.2 |
| Local web form enrollment (BusyBox httpd) | 1.2 |
| RetroDeck PAL and CLI enrollment | 2.1 |
| Onion OS enrollment trigger | 3.1 |
| Android enrollment UI | 3.2 |
| PAT expiry tracking and rotation warnings | 4.2 |
| Token revocation / device unlink flow | 1.2 |
| Onion OS PAL implementation | 3.1 |
| `config.json` creation in repo (default sync settings) | 1.1 |

---

## File Table

### Files Created

| File | Purpose |
|------|---------|
| `src/core/sync_engine.sh` | Git operations layer: clone, add, commit, push, pull, status queries |
| `src/core/enrollment.sh` | Platform-agnostic enrollment: clone, credential storage, device registration, git auth config |
| `src/platforms/nextui/enroll_sd_card.sh` | NextUI SD card enrollment trigger: detect, parse, import `setup.json` |
| `tests/fixtures/enroll_test.sh` | Test enrollment helper: bare remote creation, seeded saves, scripted enrollment for CI |
| `tests/unit/core/test_sync_engine.sh` | Unit tests for sync engine |
| `tests/unit/core/test_enrollment.sh` | Unit tests for core enrollment logic |
| `tests/unit/nextui/test_enroll_sd_card.sh` | Unit tests for SD card import parsing and trigger logic |
| `tests/integration/test_enrollment_flow.sh` | Integration test: full enrollment using test PAL and local bare remote |

### Files Modified

| File | Change |
|------|--------|
| `docs/roadmap.md` | Update Sprint 0.3 status to Complete after implementation; update Sprint 0.4 dependencies note if needed |

### Directories Created (if not already present)

| Directory | Purpose |
|-----------|---------|
| `tests/unit/nextui/` | Unit tests for NextUI platform modules |

---

## Acceptance Criteria

### Sync Engine

1. `se_clone` clones a local bare repo into a specified target directory. The target directory becomes a valid git working tree.
2. `se_init` sets the module-level device name (`_SE_DEVICE_NAME`) and configures git user identity. Subsequent calls to `se_commit` embed the correct device name in the commit trailer.
3. `se_init` sets `user.email` and `user.name` in the repo's local git config if not already set.
4. `se_stage_files` takes `repo_dir` and a file list, adds all listed files to the index. Calling `se_has_staged_changes` after a valid stage returns 0.
5. `se_commit` with one file produces a commit with subject `<system>/<filename> updated`.
6. `se_commit` with three files produces a commit with subject `3 saves updated`.
7. `se_commit` embeds `device: <device_name>` and `timestamp: <ISO 8601>` in the commit body.
8. `se_push` takes `repo_dir`, pushes to the remote and returns 0 on success.
9. `se_push` retries up to four times on network error (verify via stderr mock that simulates `unable to connect`), with delays of approximately 2s, 4s, 8s, 16s.
10. `se_push` returns 1 after all retries are exhausted without success.
11. `se_push` returns 2 when `pal_is_online` returns 1 (device is offline at time of push attempt).
12. `se_pull` returns 0 on a clean fast-forward pull.
13. `se_pull` returns 1 when the remote has diverged and fast-forward is not possible.
14. `se_pull` returns 2 when the network is unreachable (simulated via an invalid remote URL).
15. `se_has_unpushed_commits` returns 0 after a commit that has not been pushed; returns 1 after a successful push.
16. `se_get_head_commit` returns the correct 40-character SHA after a commit.
17. All git commands use `$CONTINUITY_GIT_BIN` — no hard-coded `git` invocations in `sync_engine.sh`.

### Core Enrollment

18. `enroll_is_enrolled` returns 1 when `$CONTINUITY_REPO_DIR` does not exist.
19. `enroll_is_enrolled` returns 1 when the repo directory exists but `.continuity/device_name` is missing.
20. `enroll_is_enrolled` returns 0 after a successful `enroll_run`.
21. `enroll_run` clones the repo to `$CONTINUITY_REPO_DIR`.
22. `enroll_run` writes the PAT to `$CONTINUITY_REPO_DIR/.continuity/credentials`.
23. `enroll_run` writes `.continuity/device_name` with the device name string.
24. `enroll_run` writes a valid `.continuity/devices/<device_name>.json` with all required fields (`_schema_version`, `device_name`, `platform`, `enrolled_at`, `last_sync`, `last_push`).
25. `enroll_run` commits `.continuity/devices/<device_name>.json` and `.continuity/.gitignore` to the repo.
26. `enroll_run` pushes the device registration commit to the remote.
27. After `enroll_run`, the device JSON commit is visible in the remote bare repo.
28. `enroll_write_device_json` produces valid JSON (parseable by `python3 -m json.tool` or equivalent; in BusyBox environments, manual structure check suffices).
29. `.continuity/.gitignore` lists at minimum: `credentials`, `git_credential_helper.sh`, `device_name`, `sentinel`, `last_known_commit`, `clean_shutdown`.
30. `credentials` and `device_name` files are not tracked by git (confirmed via `git ls-files`).
31. `enroll_run` returns 1 and logs an error if `repo_url` is unreachable — no partial state is left that causes `enroll_is_enrolled` to return 0.
32. `enroll_configure_git_auth` configures the repo so subsequent `git push` and `git pull` authenticate without interactive prompts.
33. After `se_clone`, `enroll_run` verifies the default branch is `main` (via `$CONTINUITY_GIT_BIN -C "$CONTINUITY_REPO_DIR" branch --show-current`). If the branch is not `main`, `enroll_run` logs an error (`"Repo default branch is '<branch>', expected 'main'"`) and returns 1. All downstream sync modules hardcode `main` as the branch name.

### NextUI SD Card Trigger

34. `esd_detect_setup_file` returns 1 when no `setup.json` is present.
35. `esd_detect_setup_file` returns 0 when `setup.json` is present.
36. `esd_parse_setup_file` correctly extracts `repo_url`, `pat`, and `device_name` from a well-formed `setup.json`.
37. `esd_parse_setup_file` returns 1 and logs an error when any required field is missing.
38. `esd_parse_setup_file` returns 1 and logs an error when any required field is empty.
39. `esd_import` deletes `setup.json` after a successful enrollment.
40. `esd_import` does NOT delete `setup.json` if `enroll_run` fails (to allow retry).
41. `esd_import` returns 0 (no-op, no error) when `setup.json` is absent.
42. `esd_import` logs a warning and deletes `setup.json` if the device is already enrolled.
43. `esd_import` returns 1 if `esd_parse_setup_file` fails.

### Test Enrollment Helper

44. `et_setup` creates a bare git repo at `$ET_REMOTE_DIR` with the three pre-seeded `.srm` files committed.
45. After `et_setup`, `ET_REPO_DIR` is a valid enrolled clone: contains `.continuity/device_name`, `.continuity/credentials`, `.continuity/devices/test-device.json`.
46. After `et_setup`, `enroll_is_enrolled` returns 0 when called with the test PAL.
47. `et_add_remote_save` commits a new `.srm` file to the bare remote, making it available for a subsequent `se_pull`.
48. `et_teardown` removes all directories under `TEST_TMPDIR`.

### Integration

49. End-to-end: `et_setup` followed by `enroll_is_enrolled` returns 0.
50. End-to-end: After `et_setup`, a `se_pull` produces no error (repo is already up to date).
51. End-to-end: After `et_add_remote_save` adds a new save, `se_pull` returns 0 and the new save appears in the working tree.
52. All tests pass under `busybox ash`.
53. `shellcheck` reports no errors on all `.sh` files created in this sprint.

---

## Testing Strategy

### Unit Tests

All unit tests are self-contained: they create temp directories, do all work inside them, and remove them on EXIT via `trap`. They use the test PAL (`tests/fixtures/pal_test.sh`) with `TEST_TMPDIR` set to a fresh temp directory per test run.

**`tests/unit/core/test_sync_engine.sh`:**
- Set up a bare repo + working clone using local filesystem only.
- Test `se_clone`: verify target dir is a git repo after clone.
- Test `se_init`: verify `user.email` and `user.name` appear in repo config.
- Test `se_stage_files` + `se_has_staged_changes`.
- Test `se_commit` single file: verify commit message subject and trailer lines.
- Test `se_commit` multiple files: verify subject uses count.
- Test `se_push`: push to bare remote, verify commit appears in remote log.
- Test `se_has_unpushed_commits`: true after commit, false after push.
- Test `se_get_head_commit`: returns 40-char SHA.
- Test `se_pull`: fast-forward pull. Add a commit to bare remote, then pull — verify the commit appears in working clone.
- Test `se_pull` diverged: commit to both bare remote and working clone (independently, so they diverge), verify `se_pull` returns 1.
- Test `se_pull` network error: set remote to an invalid `file:///nonexistent` URL, verify returns 2.
- Test `se_push` retry mock: replace `$CONTINUITY_GIT_BIN` with a wrapper that fails the first two invocations (writing to stderr: `unable to connect`), succeeds on third — verify `se_push` returns 0 and logs retries.

**`tests/unit/core/test_enrollment.sh`:**
- Set up a bare repo + test PAL.
- Test `enroll_is_enrolled` before enrollment: returns 1.
- Test `enroll_store_credential`: verify file written with correct content.
- Test `enroll_write_device_json`: verify file exists with all required fields.
- Test `enroll_configure_git_auth`: verify repo config contains `credential.helper` entry; verify helper script file exists and is executable.
- Test `enroll_run` full flow (happy path): verify all postconditions (criteria 19–29).
- Test `enroll_run` with bad repo URL: verify returns 1, `enroll_is_enrolled` still returns 1.
- Test `enroll_is_enrolled` after enrollment: returns 0.

**`tests/unit/nextui/test_enroll_sd_card.sh`:**
- Create a temp dir simulating SD card root. Set `CONTINUITY_SD_ROOT` to this dir.
- Test `esd_detect_setup_file`: returns 1 when absent, 0 when present.
- Test `esd_parse_setup_file` valid input: all three variables set correctly.
- Test `esd_parse_setup_file` missing `device_name` field: returns 1.
- Test `esd_parse_setup_file` empty `pat` field: returns 1.
- Test `esd_import` no setup file: returns 0, no side effects.
- Test `esd_import` valid setup file + successful enrollment (using a local bare repo): setup.json deleted.
- Test `esd_import` parse failure: returns 1, setup.json not deleted.
- Test `esd_import` already enrolled: logs warning, setup.json deleted, returns 0.

### Integration Test

**`tests/integration/test_enrollment_flow.sh`:**

1. Create `TEST_TMPDIR`. Source test PAL with `TEST_TMPDIR` set.
2. Call `et_setup "$TEST_TMPDIR"`. Verify exits 0.
3. Assert `ET_REPO_DIR/.git` exists.
4. Assert `ET_REPO_DIR/.continuity/device_name` exists and contains `test-device`.
5. Assert `ET_REPO_DIR/.continuity/credentials` exists.
6. Assert `ET_REPO_DIR/.continuity/devices/test-device.json` exists.
7. Assert `enroll_is_enrolled` returns 0.
8. Assert `.continuity/credentials` is not tracked: `$CONTINUITY_GIT_BIN -C $ET_REPO_DIR ls-files .continuity/credentials` returns empty.
9. Assert `.continuity/device_name` is not tracked: same check.
10. Assert device registration commit exists in remote: `$CONTINUITY_GIT_BIN -C $ET_REMOTE_DIR log --oneline` contains `enroll: register test-device`.
11. Call `et_add_remote_save "snes" "zelda_lttp.srm" "testdata"`.
12. Run `se_pull`. Assert returns 0.
13. Assert `$ET_REPO_DIR/snes/zelda_lttp.srm` exists.
14. Call `et_teardown`. Assert `$TEST_TMPDIR` no longer exists.

---

## Definition of Done

- [ ] `src/core/sync_engine.sh` implemented and passes all unit tests under `busybox ash`.
- [ ] `src/core/enrollment.sh` implemented and passes all unit tests under `busybox ash`.
- [ ] `src/platforms/nextui/enroll_sd_card.sh` implemented and passes all unit tests under `busybox ash`.
- [ ] `tests/fixtures/enroll_test.sh` implemented and usable by integration tests.
- [ ] Integration test `tests/integration/test_enrollment_flow.sh` passes under `busybox ash`.
- [ ] `shellcheck` passes with no errors on all `.sh` files created in this sprint.
- [ ] All functions in all `.sh` files have a brief usage comment at the top of each file.
- [ ] Sprint summary written to `docs/sprints/sprint-0.3-summary.md`.

---

## Resolved Questions

1. **SD card root path abstraction:** **Resolved — yes.** `CONTINUITY_SD_ROOT` is an optional PAL variable. Set to `/mnt/SDCARD` in NextUI PAL, `$TEST_TMPDIR/sdcard` in test PAL. Added to `docs/design/pal.md` optional variables table. `enroll_sd_card.sh` uses `$CONTINUITY_SD_ROOT` instead of hardcoding `/mnt/SDCARD`.

2. **`se_push` retry sleep on constrained devices:** **Resolved — approved as-is.** 2s/4s/8s/16s delays are acceptable. Total worst-case 30s, runs in background on handhelds. BusyBox `sleep` takes integers, which these are.

3. **Pre-clone credential storage path:** **Resolved — require parent dir to exist.** The enrollment trigger (or `pal_init`) must ensure `$(dirname $CONTINUITY_REPO_DIR)` exists before calling `enroll_run`. Credentials are written to `$(dirname $CONTINUITY_REPO_DIR)/.continuity_credentials_tmp` before clone, moved to final location after clone. Single approach, no alternatives.

4. **Branch name validation:** **Resolved — hardcode `main`, validate during enrollment.** `enroll_run` verifies the cloned repo's default branch is `main` after `se_clone`. If not `main`, enrollment fails with a clear error. All downstream sync modules use `main` as the branch name. Configurable branch names deferred to a future sprint.
