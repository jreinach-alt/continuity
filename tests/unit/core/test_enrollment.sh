#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/core/enrollment.sh
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
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
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
            printf 'FAIL: %s\n  text does not contain: %s\n  text: %s\n' "$desc" "$pattern" "$text" >&2
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

# Disable commit signing globally for this test process
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

. "$TESTS_DIR/fixtures/pal_test.sh"
pal_init

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/enrollment.sh"

pal_validate

# Create a bare remote
BARE_REMOTE="$TEST_TMPDIR/bare_remote.git"
"$CONTINUITY_GIT_BIN" init --bare "$BARE_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$BARE_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null

# Seed with an initial commit so we have a main branch
SEED_DIR="$TEST_TMPDIR/seed"
"$CONTINUITY_GIT_BIN" clone "file://$BARE_REMOTE" "$SEED_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.email "seed@test" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.name "Seed" >/dev/null 2>&1
printf 'init' > "$SEED_DIR/.gitkeep"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" add .gitkeep >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" commit -m "initial" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" push origin main >/dev/null 2>&1
rm -rf "$SEED_DIR"

# --- Test enroll_is_enrolled before enrollment ---
rc=0; enroll_is_enrolled || rc=$?
assert_rc "enroll_is_enrolled before enrollment returns 1" 1 "$rc"

# --- Test _enroll_validate_device_name ---
rc=0; _enroll_validate_device_name "my-brick" 2>/dev/null || rc=$?
assert_rc "validate good device name" 0 "$rc"

rc=0; _enroll_validate_device_name "" 2>/dev/null || rc=$?
assert_rc "validate empty device name" 1 "$rc"

rc=0; _enroll_validate_device_name "-bad" 2>/dev/null || rc=$?
assert_rc "validate device name starting with hyphen" 1 "$rc"

rc=0; _enroll_validate_device_name "bad-" 2>/dev/null || rc=$?
assert_rc "validate device name ending with hyphen" 1 "$rc"

rc=0; _enroll_validate_device_name "BAD" 2>/dev/null || rc=$?
assert_rc "validate device name with uppercase" 1 "$rc"

rc=0; _enroll_validate_device_name "has space" 2>/dev/null || rc=$?
assert_rc "validate device name with space" 1 "$rc"

rc=0; _enroll_validate_device_name "abcdefghijklmnopqrstuvwxyz1234567" 2>/dev/null || rc=$?
assert_rc "validate device name exceeding 32 chars" 1 "$rc"

rc=0; _enroll_validate_device_name "a" 2>/dev/null || rc=$?
assert_rc "validate single char device name" 0 "$rc"

# --- Test enroll_store_credential (pre-clone) ---
enroll_store_credential "my-secret-pat" >/dev/null 2>&1
tmp_cred="$(dirname "$CONTINUITY_REPO_DIR")/.continuity_credentials_tmp"
assert_file_exists "enroll_store_credential writes tmp file" "$tmp_cred"
cred_content=$(cat "$tmp_cred")
assert_eq "enroll_store_credential content" "my-secret-pat" "$cred_content"
rm -f "$tmp_cred"

# --- Test enroll_run full flow ---
rc=0; enroll_run "file://$BARE_REMOTE" "test-device" "test-pat" >/dev/null 2>&1 || rc=$?
assert_rc "enroll_run returns 0" 0 "$rc"

# Verify postconditions
assert_file_exists "enroll_run creates repo" "$CONTINUITY_REPO_DIR/.git"
assert_file_exists "enroll_run writes credentials" "$CONTINUITY_REPO_DIR/.continuity/credentials"
assert_file_exists "enroll_run writes device_name" "$CONTINUITY_REPO_DIR/.continuity/device_name"
assert_file_exists "enroll_run writes device JSON" "$CONTINUITY_REPO_DIR/.continuity/devices/test-device.json"
assert_file_exists "enroll_run writes .gitignore" "$CONTINUITY_REPO_DIR/.continuity/.gitignore"

# Check credentials content
cred=$(cat "$CONTINUITY_REPO_DIR/.continuity/credentials")
assert_eq "credentials content" "test-pat" "$cred"

# Check device_name content
dn=$(cat "$CONTINUITY_REPO_DIR/.continuity/device_name")
assert_eq "device_name content" "test-device" "$dn"

# Check device JSON content
device_json=$(cat "$CONTINUITY_REPO_DIR/.continuity/devices/test-device.json")
assert_contains "device JSON has schema version" "$device_json" '"_schema_version": "1.0"'
assert_contains "device JSON has device_name" "$device_json" '"device_name": "test-device"'
assert_contains "device JSON has platform" "$device_json" '"platform": "nextui"'
assert_contains "device JSON has enrolled_at" "$device_json" '"enrolled_at":'
assert_contains "device JSON has last_sync null" "$device_json" '"last_sync": null'
assert_contains "device JSON has last_push null" "$device_json" '"last_push": null'

# Check .gitignore content
gitignore=$(cat "$CONTINUITY_REPO_DIR/.continuity/.gitignore")
assert_contains "gitignore has credentials" "$gitignore" "credentials"
assert_contains "gitignore has git_credential_helper.sh" "$gitignore" "git_credential_helper.sh"
assert_contains "gitignore has device_name" "$gitignore" "device_name"
assert_contains "gitignore has sentinel" "$gitignore" "sentinel"
assert_contains "gitignore has last_known_commit" "$gitignore" "last_known_commit"
assert_contains "gitignore has clean_shutdown" "$gitignore" "clean_shutdown"

# Check credentials NOT tracked by git
tracked=$("$CONTINUITY_GIT_BIN" -C "$CONTINUITY_REPO_DIR" ls-files .continuity/credentials)
assert_eq "credentials not tracked" "" "$tracked"

# Check device_name NOT tracked by git
tracked=$("$CONTINUITY_GIT_BIN" -C "$CONTINUITY_REPO_DIR" ls-files .continuity/device_name)
assert_eq "device_name not tracked" "" "$tracked"

# Check git_credential_helper.sh NOT tracked
tracked=$("$CONTINUITY_GIT_BIN" -C "$CONTINUITY_REPO_DIR" ls-files .continuity/git_credential_helper.sh)
assert_eq "git_credential_helper.sh not tracked" "" "$tracked"

# Check credential helper is configured
helper=$("$CONTINUITY_GIT_BIN" -C "$CONTINUITY_REPO_DIR" config --get credential.helper)
assert_contains "credential helper configured" "$helper" "git_credential_helper.sh"

# Check helper script is executable
if [ -x "$CONTINUITY_REPO_DIR/.continuity/git_credential_helper.sh" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: credential helper not executable\n' >&2
    failed=$((failed + 1))
fi

# Check enrollment commit in remote
remote_log=$("$CONTINUITY_GIT_BIN" -C "$BARE_REMOTE" log --oneline 2>/dev/null)
assert_contains "enrollment commit in remote" "$remote_log" "enroll: register test-device"

# --- Test enroll_is_enrolled after enrollment ---
rc=0; enroll_is_enrolled || rc=$?
assert_rc "enroll_is_enrolled after enrollment returns 0" 0 "$rc"

# --- Test enroll_run with bad URL ---
# Reset for a fresh enrollment attempt
ORIG_REPO_DIR="$CONTINUITY_REPO_DIR"
TEST_TMPDIR2=$(mktemp -d)
CONTINUITY_REPO_DIR="$TEST_TMPDIR2/repo"
mkdir -p "$(dirname "$CONTINUITY_REPO_DIR")"

rc=0; enroll_run "file:///nonexistent_bad_url" "test-device2" "bad-pat" >/dev/null 2>&1 || rc=$?
assert_rc "enroll_run bad URL returns 1" 1 "$rc"

rc=0; enroll_is_enrolled || rc=$?
assert_rc "enroll_is_enrolled after bad URL returns 1" 1 "$rc"

# Restore original
CONTINUITY_REPO_DIR="$ORIG_REPO_DIR"
rm -rf "$TEST_TMPDIR2"

# --- Test enroll_run validation failures ---
rc=0; enroll_run "" "test-device" "pat" >/dev/null 2>&1 || rc=$?
assert_rc "enroll_run empty repo_url returns 1" 1 "$rc"

rc=0; enroll_run "file://repo" "" "pat" >/dev/null 2>&1 || rc=$?
assert_rc "enroll_run empty device_name returns 1" 1 "$rc"

rc=0; enroll_run "file://repo" "test-device" "" >/dev/null 2>&1 || rc=$?
assert_rc "enroll_run empty pat returns 1" 1 "$rc"

# --- Summary ---
printf '\ntest_enrollment: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
