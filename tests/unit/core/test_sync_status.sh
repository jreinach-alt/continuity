#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/core/sync_status.sh
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

passed=0
failed=0

assert_eq() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_rc() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected rc: %s\n  actual rc:   %s\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_file_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_file_not_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ ! -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file should not exist: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: %s\n  text does not contain: %s\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
            ;;
    esac
}

assert_not_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*)
            printf 'FAIL: %s\n  text should not contain: %s\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
            ;;
        *)
            passed=$((passed + 1))
            ;;
    esac
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

. "$TESTS_DIR/fixtures/pal_test.sh"
pal_init

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_status.sh"

pal_validate

# ============================
# Tests for ss_notify
# ============================
printf '\n=== ss_notify tests ===\n' >&2

# Test 1: ss_notify returns 0
repo_dir="$TEST_TMPDIR/t1_repo"
mkdir -p "$repo_dir/.continuity"
rc=0
ss_notify "$repo_dir" "green" "Pushed 1 save(s)" 2>/dev/null || rc=$?
assert_rc "ss_notify returns 0" 0 "$rc"

# Test 2: last-status file written with correct fields
assert_file_exists "last_status file exists" "$repo_dir/.continuity/last_status"
status_content=$(cat "$repo_dir/.continuity/last_status")
assert_contains "last_status has level=green" "$status_content" "level=green"
assert_contains "last_status has message" "$status_content" "message=Pushed 1 save(s)"
assert_contains "last_status has timestamp" "$status_content" "timestamp="

# Verify 3 lines
line_count=$(cat "$repo_dir/.continuity/last_status" | wc -l | tr -d ' ')
assert_eq "last_status has 3 lines" "3" "$line_count"

# Test 3: last-status file overwritten on subsequent calls
ss_notify "$repo_dir" "yellow" "1 save(s) queued — offline" 2>/dev/null
status_content=$(cat "$repo_dir/.continuity/last_status")
assert_contains "overwritten: level=yellow" "$status_content" "level=yellow"
assert_contains "overwritten: message" "$status_content" "message=1 save(s) queued — offline"
assert_not_contains "overwritten: no green" "$status_content" "level=green"

# Test 4: red level
ss_notify "$repo_dir" "red" "2 conflict(s) — action required" 2>/dev/null
status_content=$(cat "$repo_dir/.continuity/last_status")
assert_contains "red level" "$status_content" "level=red"
assert_contains "red message" "$status_content" "message=2 conflict(s) — action required"

# Test 5: pal_on_sync_result called when defined
_hook_log="$TEST_TMPDIR/hook_log"
printf '' > "$_hook_log"
pal_on_sync_result() {
    printf '%s|%s\n' "$1" "$2" >> "$_hook_log"
}

ss_notify "$repo_dir" "green" "test hook" 2>/dev/null
hook_output=$(cat "$_hook_log")
assert_contains "hook called with level" "$hook_output" "green|test hook"

# Test 6: pal_on_sync_result receives correct args for each level
printf '' > "$_hook_log"
ss_notify "$repo_dir" "yellow" "offline msg" 2>/dev/null
ss_notify "$repo_dir" "red" "error msg" 2>/dev/null
hook_output=$(cat "$_hook_log")
assert_contains "hook yellow" "$hook_output" "yellow|offline msg"
assert_contains "hook red" "$hook_output" "red|error msg"

# Clean up hook
unset -f pal_on_sync_result

# Test 7: no error when pal_on_sync_result is not defined
rc=0
ss_notify "$repo_dir" "green" "no hook" 2>/dev/null || rc=$?
assert_rc "no hook: returns 0" 0 "$rc"

# Test 8: pal_log is called (verify via stderr capture)
log_output=$(ss_notify "$repo_dir" "green" "log test" 2>&1)
assert_contains "pal_log called" "$log_output" "sync_status: [green] log test"

# Test 9: .continuity/.gitignore created (PF-4)
repo_dir="$TEST_TMPDIR/t9_repo"
mkdir -p "$repo_dir/.continuity"
assert_file_not_exists "t9: no .gitignore before" "$repo_dir/.continuity/.gitignore"
ss_notify "$repo_dir" "green" "test" 2>/dev/null
assert_file_exists "t9: .gitignore created" "$repo_dir/.continuity/.gitignore"

gi_content=$(cat "$repo_dir/.continuity/.gitignore")
assert_contains "t9: .gitignore has sentinel" "$gi_content" "sentinel"
assert_contains "t9: .gitignore has last_known_commit" "$gi_content" "last_known_commit"
assert_contains "t9: .gitignore has last_status" "$gi_content" "last_status"

# Test 10: .gitignore not overwritten on subsequent calls
printf 'custom_entry\n' >> "$repo_dir/.continuity/.gitignore"
ss_notify "$repo_dir" "yellow" "second call" 2>/dev/null
gi_content=$(cat "$repo_dir/.continuity/.gitignore")
assert_contains "t10: custom_entry preserved" "$gi_content" "custom_entry"

# Test 11: atomic write — no partial files
repo_dir="$TEST_TMPDIR/t11_repo"
mkdir -p "$repo_dir/.continuity"
ss_notify "$repo_dir" "green" "atomic test" 2>/dev/null
# Verify no .tmp files left
tmp_count=$(find "$repo_dir/.continuity" -name "last_status.tmp.*" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no tmp files left" "0" "$tmp_count"

# Test 12: .continuity dir created if missing
repo_dir="$TEST_TMPDIR/t12_repo"
rc=0
ss_notify "$repo_dir" "green" "create dir" 2>/dev/null || rc=$?
assert_rc "create dir: returns 0" 0 "$rc"
assert_file_exists "t12: .continuity created" "$repo_dir/.continuity"
assert_file_exists "t12: last_status created" "$repo_dir/.continuity/last_status"

# ============================
# Tests for ss_get_last_status
# ============================
printf '\n=== ss_get_last_status tests ===\n' >&2

# Test 1: returns file contents when file exists
repo_dir="$TEST_TMPDIR/gls1_repo"
mkdir -p "$repo_dir/.continuity"
ss_notify "$repo_dir" "yellow" "queued" 2>/dev/null
output=$(ss_get_last_status "$repo_dir")
rc=$?
assert_rc "gls1: returns 0" 0 "$rc"
assert_contains "gls1: has level" "$output" "level=yellow"
assert_contains "gls1: has message" "$output" "message=queued"
assert_contains "gls1: has timestamp" "$output" "timestamp="

# Test 2: returns defaults when file doesn't exist
repo_dir="$TEST_TMPDIR/gls2_repo"
mkdir -p "$repo_dir/.continuity"
output=$(ss_get_last_status "$repo_dir")
rc=$?
assert_rc "gls2: returns 0" 0 "$rc"
assert_contains "gls2: default level=green" "$output" "level=green"
assert_contains "gls2: default message=Ready" "$output" "message=Ready"
assert_contains "gls2: default timestamp=never" "$output" "timestamp=never"

# Test 3: output is valid 3-line key-value format
repo_dir="$TEST_TMPDIR/gls3_repo"
mkdir -p "$repo_dir/.continuity"
ss_notify "$repo_dir" "red" "action needed" 2>/dev/null
output=$(ss_get_last_status "$repo_dir")
line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
assert_eq "gls3: 3 lines" "3" "$line_count"

# Test 4: defaults are also 3 lines
repo_dir="$TEST_TMPDIR/gls4_repo"
output=$(ss_get_last_status "$repo_dir")
line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
assert_eq "gls4: defaults 3 lines" "3" "$line_count"

# Test 5: returns latest after multiple ss_notify calls
repo_dir="$TEST_TMPDIR/gls5_repo"
mkdir -p "$repo_dir/.continuity"
ss_notify "$repo_dir" "green" "first" 2>/dev/null
ss_notify "$repo_dir" "red" "second" 2>/dev/null
output=$(ss_get_last_status "$repo_dir")
assert_contains "gls5: latest level" "$output" "level=red"
assert_contains "gls5: latest message" "$output" "message=second"
assert_not_contains "gls5: no first" "$output" "message=first"

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
