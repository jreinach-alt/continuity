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

# --- Sprint 2.0: .rtc save-class sibling + full state-shape coverage ---

# .rtc is enumerated as a save (device + repo scanners)
printf 'clock' > "$CONTINUITY_SAVES_ROOT/SFC/pokemon.gbc.rtc"
output=$(cd_list_device_saves)
assert_contains "cd_list_device_saves finds .rtc" "$output" "$CONTINUITY_SAVES_ROOT/SFC/pokemon.gbc.rtc"
mkdir -p "$REPO/gb"
printf 'clock' > "$REPO/gb/pokemon.rtc"
output=$(cd_list_repo_saves "$REPO")
assert_contains "cd_list_repo_saves finds .rtc" "$output" "gb/pokemon.rtc"

# cd_detect_changes matches .rtc and every new state shape in a git tree
mkdir -p "$GIT_REPO/gb" "$GIT_REPO/states/GBC-gambatte"
printf 'clock' > "$GIT_REPO/gb/pokemon.rtc"
for st in "S.st0" "S.state" "S.state1" "S.state.0" "S.state.auto"; do
    printf 'st' > "$GIT_REPO/states/GBC-gambatte/$st"
done
output=$(cd_detect_changes "$GIT_REPO")
assert_contains "cd_detect_changes finds .rtc" "$output" "gb/pokemon.rtc"
for st in "st0" "state" "state1" "state.0" "state.auto"; do
    assert_contains "cd_detect_changes finds state .$st" "$output" "GBC-gambatte/S.$st"
done

# cd_list_device_states finds all FIVE state name-shapes (4 of 5 were
# silently never backed up before Sprint 2.0 — matrix §6)
STATES="$CONTINUITY_STATES_ROOT"
mkdir -p "$STATES/SFC-snes9x"
for st in "Game.st0" "Game.state" "Game.state2" "Game.state.0" "Game.state.auto" \
          "Game.state10" "Game.state10.png"; do
    printf 'state-bytes' > "$STATES/SFC-snes9x/$st"
done
output=$(cd_list_device_states 2>/dev/null)
state_count=$(printf '%s\n' "$output" | grep -c '.')
assert_eq "cd_list_device_states finds all 7 shapes (multi-digit + png)" "7" "$state_count"

# unrecognized shapes self-document once per run (the .state10 lesson)
export CONTINUITY_STATE_WARN_CACHE="$TEST_TMPDIR/unrec_ledger"
printf 'x' > "$STATES/SFC-snes9x/weird.snapshot"
w1=$(cd_list_device_states 2>&1 >/dev/null)
w2=$(cd_list_device_states 2>&1 >/dev/null)
case "$w1" in
    *"Unrecognized file shape"*"weird.snapshot"*) passed=$((passed + 1)) ;;
    *) printf 'FAIL: unrecognized shape must log, got [%s]\n' "$w1" >&2; failed=$((failed + 1)) ;;
esac
assert_eq "unrecognized-shape log is once per run" "" "$w2"
out_clean=$(cd_list_device_states 2>/dev/null | grep -c "weird.snapshot") || true
assert_eq "unrecognized shape never listed for archive" "0" "$out_clean"
rm -f "$STATES/SFC-snes9x/weird.snapshot"
unset CONTINUITY_STATE_WARN_CACHE

# --- State size gate: 64 MB default, warn-once-per-run ledger ---

# default cap is 64 MB now: a 9 MB state (over the OLD 8 MB default)
# must pass — pins the owner's 2026-07-09 raise.
unset CONTINUITY_STATE_MAX_KB
dd if=/dev/zero of="$STATES/SFC-snes9x/big9mb.state" bs=1024 count=9216 2>/dev/null
if cd_state_size_ok "$STATES/SFC-snes9x/big9mb.state" 2>/dev/null; then
    passed=$((passed + 1))
else
    printf 'FAIL: 9MB state must pass the 64MB default cap\n' >&2
    failed=$((failed + 1))
fi
rm -f "$STATES/SFC-snes9x/big9mb.state"

# warn-once: an oversized state warns on first sight, silent after,
# still skipped every time (field defect: 9 identical warns per poll).
export CONTINUITY_STATE_MAX_KB=2
export CONTINUITY_STATE_WARN_CACHE="$TEST_TMPDIR/warn_ledger"
printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' > "$STATES/SFC-snes9x/huge.state"
dd if=/dev/zero of="$STATES/SFC-snes9x/huge.state" bs=1024 count=3 2>/dev/null
rc1=0; w1=$(cd_state_size_ok "$STATES/SFC-snes9x/huge.state" 2>&1) || rc1=$?
rc2=0; w2=$(cd_state_size_ok "$STATES/SFC-snes9x/huge.state" 2>&1) || rc2=$?
assert_eq "oversized state skipped (rc 1) first time" "1" "$rc1"
assert_eq "oversized state skipped (rc 1) second time" "1" "$rc2"
case "$w1" in
    *"State too large"*) passed=$((passed + 1)) ;;
    *) printf 'FAIL: first sight must warn, got [%s]\n' "$w1" >&2; failed=$((failed + 1)) ;;
esac
assert_eq "second sight is silent" "" "$w2"
# a DIFFERENT oversized file still gets its own first warn
dd if=/dev/zero of="$STATES/SFC-snes9x/huge2.state" bs=1024 count=3 2>/dev/null
w3=$(cd_state_size_ok "$STATES/SFC-snes9x/huge2.state" 2>&1) || true
case "$w3" in
    *"State too large"*) passed=$((passed + 1)) ;;
    *) printf 'FAIL: new oversized file must warn, got [%s]\n' "$w3" >&2; failed=$((failed + 1)) ;;
esac
rm -f "$STATES/SFC-snes9x/huge.state" "$STATES/SFC-snes9x/huge2.state"
unset CONTINUITY_STATE_MAX_KB CONTINUITY_STATE_WARN_CACHE

# --- Summary ---
printf '\ntest_change_detector: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
