#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: full runtime poll cycle with real git operations
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
            printf 'FAIL: %s\n  text does not contain: [%s]\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
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
export TEST_TMPDIR
pal_init

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/path_mapper.sh"
. "$PROJECT_ROOT/src/core/change_detector.sh"
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/runtime_poll.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# --- Create enrolled environment via et_setup ---
. "$TESTS_DIR/fixtures/enroll_test.sh"
et_setup "$TEST_TMPDIR" >/dev/null 2>&1

# Simulate post-boot-pull state: sentinel + last_known_commit
cs_create_sentinel "$ET_REPO_DIR"
head_hash=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" rev-parse HEAD)
cs_store_commit "$ET_REPO_DIR" "$head_hash"

# Device saves mirror repo (identical after cold start)
mkdir -p "$CONTINUITY_SAVES_ROOT/SFC" "$CONTINUITY_SAVES_ROOT/GBA" "$CONTINUITY_SAVES_ROOT/GB"
cp "$ET_REPO_DIR/snes/super_metroid.srm" "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
cp "$ET_REPO_DIR/gba/minish_cap.srm" "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm"
cp "$ET_REPO_DIR/gb/links_awakening.srm" "$CONTINUITY_SAVES_ROOT/GB/links_awakening.srm"

# ============================
# Scenario 1: Single file change syncs correctly
# ============================
sleep 1
printf 'new_metroid_bytes' > "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"

rc=0; rp_run "$ET_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "S1: rp_run returns 0" 0 "$rc"

repo_content=$(cat "$ET_REPO_DIR/snes/super_metroid.srm")
assert_eq "S1: repo has new bytes" "new_metroid_bytes" "$repo_content"

# Verify push reached remote
remote_content=$("$CONTINUITY_GIT_BIN" -C "$ET_REMOTE_DIR" show HEAD:snes/super_metroid.srm 2>/dev/null)
assert_eq "S1: pushed to remote" "new_metroid_bytes" "$remote_content"

# Verify last_known_commit updated
head_hash=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" rev-parse HEAD)
stored_hash=$(tr -d '[:space:]' < "$ET_REPO_DIR/.continuity/last_known_commit")
assert_eq "S1: last_known_commit matches HEAD" "$head_hash" "$stored_hash"

# ============================
# Scenario 2: No-op when files unchanged
# ============================
head_before=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" rev-parse HEAD)

rc=0; rp_run "$ET_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "S2: rp_run returns 0" 0 "$rc"

head_after=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" rev-parse HEAD)
assert_eq "S2: no new commit" "$head_before" "$head_after"

# ============================
# Scenario 3: New device-only save synced to repo
# ============================
sleep 1
mkdir -p "$CONTINUITY_SAVES_ROOT/GBC"
printf 'pokemon_red_data' > "$CONTINUITY_SAVES_ROOT/GBC/pokemon_red.srm"

rc=0; rp_run "$ET_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "S3: rp_run returns 0" 0 "$rc"
assert_file_exists "S3: pokemon_red in repo" "$ET_REPO_DIR/gbc/pokemon_red.srm"

repo_content=$(cat "$ET_REPO_DIR/gbc/pokemon_red.srm")
assert_eq "S3: correct content" "pokemon_red_data" "$repo_content"

commit_msg=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" log -1 --format='%s')
assert_contains "S3: commit mentions file" "$commit_msg" "pokemon_red.srm"

# ============================
# Scenario 4: Multiple files changed in one cycle
# ============================
sleep 1
printf 'multi_metroid' > "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
printf 'multi_minish' > "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm"

rc=0; rp_run "$ET_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "S4: rp_run returns 0" 0 "$rc"

repo_metroid=$(cat "$ET_REPO_DIR/snes/super_metroid.srm")
repo_minish=$(cat "$ET_REPO_DIR/gba/minish_cap.srm")
assert_eq "S4: metroid updated" "multi_metroid" "$repo_metroid"
assert_eq "S4: minish updated" "multi_minish" "$repo_minish"

commit_msg=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" log -1 --format='%s')
assert_contains "S4: commit says N saves" "$commit_msg" "saves updated"

# ============================
# Scenario 5: FAT32 false positive (identical bytes, different mtime)
# ============================
sleep 1
# Read current repo content and write identical bytes to device
repo_bytes=$(cat "$ET_REPO_DIR/snes/super_metroid.srm")
printf '%s' "$repo_bytes" > "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
# Touch to ensure mtime is newer than sentinel
touch "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"

head_before=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" rev-parse HEAD)

rc=0; rp_run "$ET_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "S5: rp_run returns 0" 0 "$rc"

head_after=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" rev-parse HEAD)
assert_eq "S5: no new commit (false positive filtered)" "$head_before" "$head_after"

# --- Summary ---
printf '\ntest_runtime_poll_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
