# Sprint 0.1 — Repo Scaffolding and Test Harness

## Phase

Phase 0 — Foundation

## Approved

<!-- The orchestrator or user sets this date when the spec is approved. -->
<!-- Agents MUST NOT begin implementation until this field contains a date. -->
**Approved**

## Status

`complete`

Status definitions:
- `not-started` — Spec is being drafted or under review. No implementation allowed.
- `approved` — Spec is locked and approved for implementation. Set the Approved date above.
- `in-progress` — Actively implementing.
- `validation` — Implementation complete. Running acceptance criteria checks.
- `complete` — All acceptance criteria met, validated, merged.

## Goal

Create the canonical directory tree, test harness, and workflow documentation so all future sprints have a stable base to build on.

## Reference Specs

- `docs/architecture/ideal_os_repo_structure_spec.md` — Initial Folder Skeleton (lines 658-740) and all Suggested Layout sections
- `CLAUDE.md` — Coding standards, testing requirements, session startup protocol

## Scope

### In Scope

- [ ] Create the full canonical directory tree (all directories from the repo structure spec, including subdirectories from Suggested Layout sections)
- [ ] Add `.gitkeep` files in all leaf directories to preserve empty structure in git
- [ ] Create `LICENSE` (MIT license)
- [ ] Create `README.md` at repo root (project overview stub)
- [ ] Create `.gitignore` (ignore build outputs, temp files, release artifacts)
- [ ] Implement `scripts/test.sh` — POSIX sh test runner compatible with BusyBox ash
- [ ] Create a sample test that validates the directory tree exists
- [ ] Create `docs/agent-workflow.md` — concise operational quick-reference for the orchestrator/coder/QA sprint cycle
- [ ] Create `docs/testing.md` — how to write and run tests

### Out of Scope

- Source code for any subsystem module (Sprint 0.2+)
- ShellCheck integration (Sprint 0.4)
- GitHub Actions CI (Sprint 0.4)
- NextUI fork integration (Sprint 0.3)
- Any content inside module directories beyond `.gitkeep`

## Files to Create or Modify

| Action | Path | Description |
|--------|------|-------------|
| Create | `LICENSE` | MIT license |
| Create | `README.md` | Project overview stub — name, one-line description, pointer to docs/ |
| Create | `.gitignore` | Ignore release/artifacts/, tmp/, *.swp, .DS_Store |
| Create | `scripts/test.sh` | Test runner — discovers and executes tests, reports pass/fail |
| Create | `tests/unit/scaffold/test_directory_tree.sh` | Validates all canonical directories exist |
| Create | `docs/agent-workflow.md` | Sprint workflow quick-reference (points to CLAUDE.md for details) |
| Create | `docs/testing.md` | How to write tests, naming conventions, runner usage |
| Create | `.gitkeep` (multiple) | One in each empty leaf directory (~60 files) |
| Modify | `docs/roadmap.md` | Update Sprint 0.1 status to `in-progress` |

## Directory Tree — Complete List

All directories to create, including full Suggested Layout depth. Directories that already exist (`docs/`, `docs/sprints/`) are marked with ✓.

```text
docs/                          ✓ exists
docs/sprints/                  ✓ exists
docs/architecture/
docs/implementation/
docs/product/
docs/release/
upstream/
upstream/nextui/
upstream/nextui/patches/
upstream/nextui/notes/
upstream/references/
src/
src/launcher/
src/session/
src/library/
src/emulation/
src/system/
src/updater/
src/tasks/
src/sync/
src/notifications/
src/common/
config/
config/emulators/
config/emulators/systems/
config/emulators/cores/
config/emulators/hotkeys/
config/ui/
config/power/
config/portmaster/
config/updater/
config/tasks/
config/sync/
config/notifications/
assets/
assets/boot/
assets/branding/
assets/themes/
assets/icons/
assets/boxart-placeholders/
runtime/
runtime/filesystem/
runtime/filesystem/overlay/
runtime/filesystem/userdata/
runtime/filesystem/migrations/
runtime/sessions/
runtime/sessions/schema/
runtime/library/
runtime/library/schema/
runtime/updater/
runtime/updater/schema/
runtime/updater/staging/
runtime/tasks/
runtime/tasks/queues/
runtime/sync/
runtime/sync/queue/
runtime/notifications/
runtime/notifications/logs/
runtime/events/
packages/
packages/base/
packages/launcher/
packages/session-manager/
packages/library/
packages/assets/
packages/updater/
packages/task-scheduler/
packages/cloud-sync/
packages/notifications/
scripts/
scripts/setup/
scripts/build/
scripts/package/
scripts/ota/
scripts/release/
tools/
tools/dev/
tools/diagnostics/
tools/migration/
tests/
tests/unit/
tests/unit/scaffold/
tests/integration/
tests/fixtures/
tests/manual/
release/
release/manifests/
release/channels/
release/notes/
release/artifacts/
.github/
.github/workflows/
.github/ISSUE_TEMPLATE/
```

## Test Runner Specification

### `scripts/test.sh`

**Shebang:** `#!/bin/sh` (must pass `busybox ash -n` syntax check)

**Discovery:** Find all files matching `tests/unit/**/test_*.sh` and `tests/integration/**/test_*.sh`.

**Execution:** Run each test file with `busybox ash` (if available) or `sh`. A test passes if it exits 0. A test fails if it exits non-zero.

**Output format:**

```text
[PASS] tests/unit/scaffold/test_directory_tree.sh
[FAIL] tests/unit/other/test_example.sh

Results: 1 passed, 1 failed, 2 total
```

**Exit code:** 0 if all tests pass, 1 if any test fails.

**Options:**
- No arguments: run all tests
- Single argument (file path): run only that test
- `--help`: print usage

**Constraints:**
- POSIX sh compatible (no bashisms)
- Must pass `busybox ash -n scripts/test.sh`
- No external dependencies beyond standard POSIX utilities

### `tests/unit/scaffold/test_directory_tree.sh`

Reads the expected directory list (hardcoded or from a reference file) and asserts each directory exists. Reports the first missing directory on failure.

## Acceptance Criteria

All must pass for the sprint to be considered complete.

1. **Directory tree complete:** Every directory listed in the Directory Tree section above exists in the repo.
2. **Git-trackable:** Every leaf directory contains a `.gitkeep` file (or other content) so the structure is preserved in git.
3. **Test runner works:** `busybox ash scripts/test.sh` runs and exits 0 when all tests pass.
4. **Test runner reports failures:** When given a deliberately failing test, `scripts/test.sh` reports `[FAIL]`, prints the summary, and exits 1.
5. **Directory tree test passes:** `busybox ash scripts/test.sh tests/unit/scaffold/test_directory_tree.sh` exits 0.
6. **Agent workflow doc exists:** `docs/agent-workflow.md` describes the sprint lifecycle and references CLAUDE.md for standards.
7. **Testing doc exists:** `docs/testing.md` covers test naming, discovery, writing conventions, and how to run the harness.
8. **BusyBox syntax clean:** `busybox ash -n scripts/test.sh` and `busybox ash -n tests/unit/scaffold/test_directory_tree.sh` report no syntax errors.
9. **README exists:** `README.md` exists at repo root with project name and description.
10. **Gitignore exists:** `.gitignore` exists and covers at minimum `release/artifacts/` and common temp file patterns.
11. **License exists:** `LICENSE` contains the MIT license text.

## Test Plan

### Automated Tests

| Test | Type | Location | Validates |
|------|------|----------|-----------|
| `test_directory_tree` | unit | `tests/unit/scaffold/test_directory_tree.sh` | AC 1, 2 — all canonical directories exist |

### Manual Validation

- [ ] Run `busybox ash -n scripts/test.sh` — expect no output, exit 0
- [ ] Run `busybox ash scripts/test.sh` — expect `[PASS]` for directory tree test, exit 0
- [ ] Create a temp file `tests/unit/scaffold/test_deliberate_fail.sh` containing `exit 1`, run `busybox ash scripts/test.sh`, confirm it reports `[FAIL]` and exits 1. Remove temp file after.

## Dependencies

- None. This is the first sprint.

## Validation Checklist

Run after implementation to confirm the sprint is complete:

- [ ] All acceptance criteria met (AC 1-11)
- [ ] All automated tests pass under `busybox ash`
- [ ] No files created outside paths listed in the Files table and Directory Tree
- [ ] No unrelated changes included
- [ ] Commit messages follow format in CLAUDE.md
- [ ] Code follows coding standards in CLAUDE.md (POSIX sh, `set -e`, quoted variables, `printf` over `echo`)
- [ ] `busybox ash -n` passes on all `.sh` files

## Notes

- **Shell target:** BusyBox ash, not bash. The dev environment has `busybox ash` installed via `busybox-static`.
- **Directory depth:** The tree includes all subdirectories from the Suggested Layout sections in the repo structure spec, not just the top-level Initial Folder Skeleton. This was a deliberate decision from the pre-flight check — creating all subdirs now prevents future sprints from having to create parent directories.
- **agent-workflow.md boundary:** This doc is a concise operational quick-reference for how to run a sprint. It is NOT a duplicate of CLAUDE.md. It covers: the sprint lifecycle steps, who does what, handoff points, and links to CLAUDE.md for coding standards, escalation rules, and branch conventions.
- **Test discovery pattern:** Uses `find` with `-name 'test_*.sh'` rather than globbing, since BusyBox `find` is reliable and recursive globs are not portable.
