#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test for Sprint 0.5 — Boot Pull
# Tests the full boot pull pipeline end-to-end using the test PAL,
# a local bare git remote, and real implementations of all dependencies.
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

assert_files_identical() {
    local desc file_a file_b
    desc="$1"; file_a="$2"; file_b="$3"
    if cmp -s "$file_a" "$file_b"; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  files differ: %s vs %s\n' "$desc" "$file_a" "$file_b" >&2
        failed=$((failed + 1))
    fi
}

assert_file_unchanged() {
    local desc filepath expected_content actual_content
    desc="$1"; filepath="$2"; expected_content="$3"
    actual_content=$(cat "$filepath")
    if [ "$expected_content" = "$actual_content" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file changed unexpectedly\n' "$desc" >&2
        failed=$((failed + 1))
    fi
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
. "$PROJECT_ROOT/src/core/boot_pull.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# ============================
# Setup: bare remote + local clone simulating post-cold-start state
# ============================
REMOTE_DIR="$TEST_TMPDIR/remote.git"
SEED_DIR="$TEST_TMPDIR/seed"
REPO_DIR="$CONTINUITY_REPO_DIR"

# Create bare remote
"$CONTINUITY_GIT_BIN" init --bare "$REMOTE_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main 2>/dev/null

# Clone for seeding initial state (simulates "another device")
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$SEED_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" checkout -b main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.email "seed@test"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.name "Seed"

# Initial saves
mkdir -p "$SEED_DIR/snes" "$SEED_DIR/gba"
printf 'super_metroid_v1' > "$SEED_DIR/snes/super_metroid.srm"
printf 'minish_cap_v1' > "$SEED_DIR/gba/minish_cap.srm"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" add snes/super_metroid.srm gba/minish_cap.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" commit -m "initial saves" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" push origin main >/dev/null 2>&1

# Clone for this device
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$REPO_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REPO_DIR" checkout main >/dev/null 2>&1 || true
se_init "$REPO_DIR" "$CONTINUITY_DEVICE_NAME" >/dev/null 2>&1

# Simulate post-cold-start: sentinel + stored commit
mkdir -p "$REPO_DIR/.continuity"
HEAD_HASH=$("$CONTINUITY_GIT_BIN" -C "$REPO_DIR" rev-parse HEAD)
cs_store_commit "$REPO_DIR" "$HEAD_HASH"
cs_create_sentinel "$REPO_DIR"

# Create matching device saves (as cold start would have done)
mkdir -p "$CONTINUITY_SAVES_ROOT/SFC" "$CONTINUITY_SAVES_ROOT/GBA"
cp "$REPO_DIR/snes/super_metroid.srm" "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
cp "$REPO_DIR/gba/minish_cap.srm" "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm"

printf '\n=== Integration Test 1: Changes from another device ===\n' >&2

# Another device adds a new save and updates an existing one
mkdir -p "$SEED_DIR/gb"
printf 'links_awakening_v1' > "$SEED_DIR/gb/links_awakening.srm"
printf 'super_metroid_v2' > "$SEED_DIR/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" add gb/links_awakening.srm snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" commit -m "updates from other device" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" push origin main >/dev/null 2>&1

# Save minish_cap content before bp_run for unchanged check
minish_cap_before=$(cat "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm")

rc=0
bp_run "$REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "Test 1: bp_run returns 0" 0 "$rc"

# New save exists on device
assert_file_exists "Test 1: links_awakening.srm on device" "$CONTINUITY_SAVES_ROOT/GB/links_awakening.srm"
assert_files_identical "Test 1: links_awakening content matches remote" \
    "$REPO_DIR/gb/links_awakening.srm" "$CONTINUITY_SAVES_ROOT/GB/links_awakening.srm"

# Updated save matches new remote content
assert_files_identical "Test 1: super_metroid updated on device" \
    "$REPO_DIR/snes/super_metroid.srm" "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"

# Unchanged save not modified
assert_file_unchanged "Test 1: minish_cap unchanged" "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm" "$minish_cap_before"

# Stored commit updated
new_head=$("$CONTINUITY_GIT_BIN" -C "$REPO_DIR" rev-parse HEAD)
stored=$(cs_read_commit "$REPO_DIR")
assert_eq "Test 1: stored commit equals HEAD" "$new_head" "$stored"

# Sentinel touched
assert_file_exists "Test 1: sentinel exists" "$REPO_DIR/.continuity/sentinel"

# ============================
printf '\n=== Integration Test 2: No remote changes ===\n' >&2

old_stored=$(cs_read_commit "$REPO_DIR")
old_sentinel_mtime=$(stat -c '%Y' "$REPO_DIR/.continuity/sentinel" 2>/dev/null || stat -f '%m' "$REPO_DIR/.continuity/sentinel" 2>/dev/null)
sleep 1  # ensure mtime changes

rc=0
bp_run "$REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "Test 2: bp_run no-op returns 0" 0 "$rc"

new_stored=$(cs_read_commit "$REPO_DIR")
assert_eq "Test 2: stored commit unchanged" "$old_stored" "$new_stored"

new_sentinel_mtime=$(stat -c '%Y' "$REPO_DIR/.continuity/sentinel" 2>/dev/null || stat -f '%m' "$REPO_DIR/.continuity/sentinel" 2>/dev/null)
if [ "$new_sentinel_mtime" -gt "$old_sentinel_mtime" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: Test 2: sentinel mtime not updated\n  old: %s new: %s\n' "$old_sentinel_mtime" "$new_sentinel_mtime" >&2
    failed=$((failed + 1))
fi

# ============================
printf '\n=== Integration Test 3: Offline ===\n' >&2

old_stored=$(cs_read_commit "$REPO_DIR")
old_sentinel_mtime=$(stat -c '%Y' "$REPO_DIR/.continuity/sentinel" 2>/dev/null || stat -f '%m' "$REPO_DIR/.continuity/sentinel" 2>/dev/null)

# Override pal_is_online and se_pull for offline simulation
pal_is_online() { return 1; }
se_pull() { return 2; }

rc=0
bp_run "$REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "Test 3: bp_run offline returns 2" 2 "$rc"

new_stored=$(cs_read_commit "$REPO_DIR")
assert_eq "Test 3: stored commit unchanged" "$old_stored" "$new_stored"

new_sentinel_mtime=$(stat -c '%Y' "$REPO_DIR/.continuity/sentinel" 2>/dev/null || stat -f '%m' "$REPO_DIR/.continuity/sentinel" 2>/dev/null)
assert_eq "Test 3: sentinel not touched" "$old_sentinel_mtime" "$new_sentinel_mtime"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
pal_is_online() { return 0; }

# ============================
# Teardown
# ============================
printf '\n=== Integration Test Teardown ===\n' >&2
rm -rf "$TEST_TMPDIR"
if [ ! -d "$TEST_TMPDIR" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: Teardown: TEST_TMPDIR still exists\n' >&2
    failed=$((failed + 1))
fi

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
