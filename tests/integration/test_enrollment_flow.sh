#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Integration test: full enrollment flow using test PAL and local bare remote
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'et_teardown' EXIT

# Disable commit signing globally for this test process
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

. "$TESTS_DIR/fixtures/pal_test.sh"
. "$TESTS_DIR/fixtures/enroll_test.sh"

# Step 1: Run et_setup
rc=0; et_setup "$TEST_TMPDIR" >/dev/null 2>&1 || rc=$?
assert_rc "et_setup returns 0" 0 "$rc"

# Step 2: Verify .git exists
assert_file_exists "ET_REPO_DIR has .git" "$ET_REPO_DIR/.git"

# Step 3: Verify device_name
assert_file_exists "device_name file exists" "$ET_REPO_DIR/.continuity/device_name"
dn=$(cat "$ET_REPO_DIR/.continuity/device_name")
assert_eq "device_name content" "test-device" "$dn"

# Step 4: Verify credentials
assert_file_exists "credentials file exists" "$ET_REPO_DIR/.continuity/credentials"

# Step 5: Verify device JSON
assert_file_exists "device JSON exists" "$ET_REPO_DIR/.continuity/devices/test-device.json"

# Step 6: Verify enrolled
rc=0; enroll_is_enrolled || rc=$?
assert_rc "enroll_is_enrolled returns 0" 0 "$rc"

# Step 7: Verify credentials NOT tracked
tracked=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" ls-files .continuity/credentials)
assert_eq "credentials not tracked" "" "$tracked"

# Step 8: Verify device_name NOT tracked
tracked=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" ls-files .continuity/device_name)
assert_eq "device_name not tracked" "" "$tracked"

# Step 9: Verify enrollment commit in remote
remote_log=$("$CONTINUITY_GIT_BIN" -C "$ET_REMOTE_DIR" log --oneline 2>/dev/null)
assert_contains "enrollment commit in remote" "$remote_log" "enroll: register test-device"

# Step 10: Verify pre-seeded saves exist in remote
remote_files=$("$CONTINUITY_GIT_BIN" -C "$ET_REMOTE_DIR" ls-tree -r --name-only HEAD 2>/dev/null)
assert_contains "remote has super_metroid.srm" "$remote_files" "snes/super_metroid.srm"
assert_contains "remote has minish_cap.srm" "$remote_files" "gba/minish_cap.srm"
assert_contains "remote has links_awakening.srm" "$remote_files" "gb/links_awakening.srm"

# Step 11: se_pull when up to date
. "$PROJECT_ROOT/src/core/sync_engine.sh"
se_init "$ET_REPO_DIR" "test-device"
rc=0; se_pull "$ET_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "se_pull up to date returns 0" 0 "$rc"

# Step 12: Add a remote save and pull it
rc=0; et_add_remote_save "snes" "zelda_lttp.srm" "testdata" >/dev/null 2>&1 || rc=$?
assert_rc "et_add_remote_save returns 0" 0 "$rc"

rc=0; se_pull "$ET_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "se_pull after remote add returns 0" 0 "$rc"
assert_file_exists "pulled save exists" "$ET_REPO_DIR/snes/zelda_lttp.srm"

pulled_content=$(cat "$ET_REPO_DIR/snes/zelda_lttp.srm")
assert_eq "pulled save content" "testdata" "$pulled_content"

# Step 13: Teardown
et_teardown
if [ ! -d "$TEST_TMPDIR" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: et_teardown did not remove TEST_TMPDIR\n' >&2
    failed=$((failed + 1))
fi

# --- Summary ---
printf '\ntest_enrollment_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
