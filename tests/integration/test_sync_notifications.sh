#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: sync pipeline notifications
# Scenarios: happy path, silent on no-change, offline, conflict, Pokémon scenario
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
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/change_detector.sh"
. "$PROJECT_ROOT/src/core/boot_pull.sh"
. "$PROJECT_ROOT/src/core/runtime_poll.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"
. "$PROJECT_ROOT/src/core/sync_status.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

CONTINUITY_DEVICE_NAME="device-b"

# Hook recorder
HOOK_LOG="$TEST_TMPDIR/hook_log"
printf '' > "$HOOK_LOG"
pal_on_sync_result() {
    printf '%s|%s\n' "$1" "$2" >> "$HOOK_LOG"
}

_reset_hook_log() {
    printf '' > "$HOOK_LOG"
}

_hook_was_called() {
    [ -s "$HOOK_LOG" ]
}

_hook_last_level() {
    tail -1 "$HOOK_LOG" | cut -d'|' -f1
}

_hook_last_message() {
    tail -1 "$HOOK_LOG" | cut -d'|' -f2
}

# ============================
# Setup: bare remote + clone
# ============================
REMOTE_DIR="$TEST_TMPDIR/remote.git"
DEVICE_B="$TEST_TMPDIR/device_b"
DEVICE_A="$TEST_TMPDIR/device_a"

"$CONTINUITY_GIT_BIN" init --bare "$REMOTE_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main 2>/dev/null

# Seed
SEED_DIR="$TEST_TMPDIR/seed"
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$SEED_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" checkout -b main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.email "seed@test"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.name "Seed"
mkdir -p "$SEED_DIR/snes"
printf 'seed-save' > "$SEED_DIR/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" add . >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" commit -m "seed" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" push origin main >/dev/null 2>&1

# Clone device-a
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$DEVICE_A" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" checkout main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config user.email "continuity@device-a"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config user.name "Continuity"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config commit.gpgsign false

# Clone device-b
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$DEVICE_B" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" checkout main >/dev/null 2>&1 || true
se_init "$DEVICE_B" "device-b" >/dev/null 2>&1

mkdir -p "$DEVICE_B/.continuity"
head_hash=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
cs_store_commit "$DEVICE_B" "$head_hash"
cs_create_sentinel "$DEVICE_B"

# Set up device saves
mkdir -p "$CONTINUITY_SAVES_ROOT/SFC"
cp "$DEVICE_B/snes/super_metroid.srm" "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"

# ============================
# Scenario 1: Happy path — change detected, pushed → green
# ============================
printf '\n=== Scenario 1: Happy path → green ===\n' >&2
_reset_hook_log

# Modify device save
printf 'new-progress' > "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
# Touch to be newer than sentinel
sleep 1
touch "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"

rc=0
rp_run "$DEVICE_B" >/dev/null 2>&1 || rc=$?
assert_rc "S1: rp_run returns 0" 0 "$rc"

# Hook was called with green
assert_eq "S1: hook level is green" "green" "$(_hook_last_level)"
assert_contains "S1: message has save count" "$(_hook_last_message)" "save(s)"

# last_status file updated
status=$(ss_get_last_status "$DEVICE_B")
assert_contains "S1: last_status level=green" "$status" "level=green"

# ============================
# Scenario 2: No changes — silent
# ============================
printf '\n=== Scenario 2: No changes → silent ===\n' >&2
_reset_hook_log

# Update sentinel to now (no new changes)
rp_update_sentinel "$DEVICE_B"

rc=0
rp_run "$DEVICE_B" >/dev/null 2>&1 || rc=$?
assert_rc "S2: rp_run returns 0" 0 "$rc"

# Hook should NOT be called
if _hook_was_called; then
    printf 'FAIL: S2: hook should not be called on no-change\n' >&2
    failed=$((failed + 1))
else
    passed=$((passed + 1))
fi

# last_status unchanged from S1
status=$(ss_get_last_status "$DEVICE_B")
assert_contains "S2: last_status still green" "$status" "level=green"

# ============================
# Scenario 3: Offline push → yellow
# ============================
printf '\n=== Scenario 3: Offline push → yellow ===\n' >&2
_reset_hook_log

# Override pal_is_online
pal_is_online() { return 1; }

# Modify device save
printf 'offline-progress' > "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
sleep 1
touch "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"

rc=0
rp_run "$DEVICE_B" >/dev/null 2>&1 || rc=$?
assert_rc "S3: rp_run returns 0" 0 "$rc"

assert_eq "S3: hook level is yellow" "yellow" "$(_hook_last_level)"
assert_contains "S3: message has offline" "$(_hook_last_message)" "offline"

status=$(ss_get_last_status "$DEVICE_B")
assert_contains "S3: last_status level=yellow" "$status" "level=yellow"

# Restore
pal_is_online() { return 0; }

# Push the offline commit so the repo is in sync
se_push "$DEVICE_B" >/dev/null 2>&1 || true
head_hash=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
cs_store_commit "$DEVICE_B" "$head_hash"

# ============================
# Scenario 4: Conflict on boot pull → red
# ============================
printf '\n=== Scenario 4: Conflict → red ===\n' >&2
_reset_hook_log

# Sync device-a
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1

# Diverge
printf 'a-conflict' > "$DEVICE_A/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'a-save\n\ndevice: device-a\ntimestamp: 2026-03-12T13:00:00Z')" \
    >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'b-conflict' > "$DEVICE_B/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'b-save\n\ndevice: device-b\ntimestamp: 2026-03-12T14:00:00Z')" \
    >/dev/null 2>&1

rc=0
bp_run "$DEVICE_B" >/dev/null 2>&1 || rc=$?
assert_rc "S4: bp_run returns 0" 0 "$rc"

assert_eq "S4: hook level is red" "red" "$(_hook_last_level)"
assert_contains "S4: message has conflict" "$(_hook_last_message)" "conflict"
assert_contains "S4: message has action required" "$(_hook_last_message)" "action required"

status=$(ss_get_last_status "$DEVICE_B")
assert_contains "S4: last_status level=red" "$status" "level=red"

# ============================
# Scenario 5: Pokémon scenario — save modified during try → red
# ============================
printf '\n=== Scenario 5: Pokémon scenario → red ===\n' >&2
_reset_hook_log

# We have an active conflict from S4. Try local.
device_path=$(ch_try_version "$DEVICE_B" "snes/super_metroid.srm" "local" 2>/dev/null)

# Modify the save (simulate gameplay)
printf 'new-gameplay' >> "$device_path"

# Make device save newer than sentinel
sleep 1
touch "$device_path"

# Reset hook log to check if red fires during poll
_reset_hook_log

# Run rp_run — should detect trying-modified and fire red
rc=0
rp_run "$DEVICE_B" >/dev/null 2>&1 || rc=$?
# rp_run returns 0 (no candidates or all filtered)
assert_rc "S5: rp_run returns 0" 0 "$rc"

# Hook was called with red for trying-modified
hook_output=$(cat "$HOOK_LOG")
assert_contains "S5: red fired for trying-modified" "$hook_output" "red|"
assert_contains "S5: message has action required" "$hook_output" "action required"

# Verify save was NOT committed (trying-state file excluded)
latest_msg=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" log -1 --format="%s")
assert_not_contains "S5: no poll commit" "$latest_msg" "Pushed"

status=$(ss_get_last_status "$DEVICE_B")
assert_contains "S5: last_status level=red" "$status" "level=red"

# Clean up conflict for next scenarios
ch_resolve "$DEVICE_B" "snes/super_metroid.srm" "keep_local" 2>/dev/null || true
ch_clear_try_markers "$DEVICE_B"

# ============================
# Scenario 6: ss_get_last_status defaults
# ============================
printf '\n=== Scenario 6: ss_get_last_status defaults ===\n' >&2

repo_dir="$TEST_TMPDIR/fresh_repo"
mkdir -p "$repo_dir/.continuity"
output=$(ss_get_last_status "$repo_dir")
assert_contains "S6: default level=green" "$output" "level=green"
assert_contains "S6: default message=Ready" "$output" "message=Ready"
assert_contains "S6: default timestamp=never" "$output" "timestamp=never"

# ============================
# Scenario 7: .continuity/.gitignore created on first notify
# ============================
printf '\n=== Scenario 7: .gitignore creation ===\n' >&2

repo_dir="$TEST_TMPDIR/gi_repo"
mkdir -p "$repo_dir"
ss_notify "$repo_dir" "green" "first call" 2>/dev/null
assert_file_exists "S7: .gitignore created" "$repo_dir/.continuity/.gitignore"

gi_content=$(cat "$repo_dir/.continuity/.gitignore")
assert_contains "S7: has sentinel" "$gi_content" "sentinel"
assert_contains "S7: has last_known_commit" "$gi_content" "last_known_commit"
assert_contains "S7: has last_status" "$gi_content" "last_status"

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
