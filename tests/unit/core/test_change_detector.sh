#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/core/change_detector.sh
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

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

. "$TESTS_DIR/fixtures/pal_test.sh"
pal_init

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/path_mapper.sh"
. "$PROJECT_ROOT/src/core/change_detector.sh"

pal_validate

# Load platform map for device saves tests
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# --- Test cd_list_repo_saves with .srm files ---
REPO="$TEST_TMPDIR/repo_test"
mkdir -p "$REPO/snes" "$REPO/gba" "$REPO/.git/refs" "$REPO/.continuity"
printf 'data' > "$REPO/snes/super_metroid.srm"
printf 'data' > "$REPO/gba/minish_cap.srm"
printf 'data' > "$REPO/.git/refs/test.srm"
printf 'data' > "$REPO/.continuity/test.srm"

output=$(cd_list_repo_saves "$REPO")
assert_contains "cd_list_repo_saves finds snes save" "$output" "snes/super_metroid.srm"
assert_contains "cd_list_repo_saves finds gba save" "$output" "gba/minish_cap.srm"
assert_not_contains "cd_list_repo_saves excludes .git" "$output" ".git"
assert_not_contains "cd_list_repo_saves excludes .continuity" "$output" ".continuity"

# --- Test cd_list_repo_saves with empty repo ---
EMPTY_REPO="$TEST_TMPDIR/empty_repo"
mkdir -p "$EMPTY_REPO"
output=$(cd_list_repo_saves "$EMPTY_REPO")
rc=$?
assert_rc "cd_list_repo_saves empty returns 0" 0 "$rc"
assert_eq "cd_list_repo_saves empty produces no output" "" "$output"

# --- Test cd_list_device_saves with saves ---
mkdir -p "$CONTINUITY_SAVES_ROOT/SFC" "$CONTINUITY_SAVES_ROOT/GBA"
printf 'data' > "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
printf 'data' > "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm"

output=$(cd_list_device_saves)
assert_contains "cd_list_device_saves finds SFC save" "$output" "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
assert_contains "cd_list_device_saves finds GBA save" "$output" "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm"

# --- Test cd_list_device_saves with nonexistent dir ---
# Some dirs in the platform map won't exist — should not fail
output=$(cd_list_device_saves)
rc=$?
assert_rc "cd_list_device_saves with missing dirs returns 0" 0 "$rc"

# --- Test cd_list_device_saves with no saves ---
rm -f "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm" "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm"
output=$(cd_list_device_saves)
rc=$?
assert_rc "cd_list_device_saves no saves returns 0" 0 "$rc"
assert_eq "cd_list_device_saves no saves empty output" "" "$output"

# --- Test cd_detect_changes with untracked .srm ---
GIT_REPO="$TEST_TMPDIR/git_repo"
"$CONTINUITY_GIT_BIN" init "$GIT_REPO" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$GIT_REPO" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$GIT_REPO" config user.email "test@test"
"$CONTINUITY_GIT_BIN" -C "$GIT_REPO" config user.name "Test"

mkdir -p "$GIT_REPO/snes"
printf 'data' > "$GIT_REPO/snes/super_metroid.srm"

output=$(cd_detect_changes "$GIT_REPO")
assert_contains "cd_detect_changes finds untracked .srm" "$output" "snes/super_metroid.srm"

# --- Test cd_detect_changes with modified .srm ---
"$CONTINUITY_GIT_BIN" -C "$GIT_REPO" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$GIT_REPO" commit -m "add" >/dev/null 2>&1
printf 'modified' > "$GIT_REPO/snes/super_metroid.srm"
output=$(cd_detect_changes "$GIT_REPO")
assert_contains "cd_detect_changes finds modified .srm" "$output" "snes/super_metroid.srm"

# --- Test cd_detect_changes excludes non-.srm files ---
printf 'notes' > "$GIT_REPO/readme.txt"
output=$(cd_detect_changes "$GIT_REPO")
assert_not_contains "cd_detect_changes excludes .txt" "$output" "readme.txt"
assert_contains "cd_detect_changes still includes .srm" "$output" "snes/super_metroid.srm"

# --- Test cd_detect_changes with no changes ---
"$CONTINUITY_GIT_BIN" -C "$GIT_REPO" add -A >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$GIT_REPO" commit -m "all" >/dev/null 2>&1
output=$(cd_detect_changes "$GIT_REPO")
rc=$?
assert_rc "cd_detect_changes no changes returns 0" 0 "$rc"
assert_eq "cd_detect_changes no changes empty output" "" "$output"

# --- Summary ---
printf '\ntest_change_detector: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
