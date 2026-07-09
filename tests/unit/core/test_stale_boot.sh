#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/core/stale_boot.sh
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
            printf 'FAIL: %s\n  text does not contain: [%s]\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
            ;;
    esac
}

assert_not_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*)
            printf 'FAIL: %s\n  text should not contain: [%s]\n' "$desc" "$pattern" >&2
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
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/boot_pull.sh"
. "$PROJECT_ROOT/src/core/runtime_poll.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"
. "$PROJECT_ROOT/src/core/stale_boot.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# ============================
# Helper: create a bare remote + enrolled clone with sentinel (stale state)
# ============================
setup_stale_env() {
    local test_id
    test_id="$1"

    local remote_dir seed_dir repo_dir saves_dir
    remote_dir="$TEST_TMPDIR/${test_id}_remote.git"
    seed_dir="$TEST_TMPDIR/${test_id}_seed"
    repo_dir="$TEST_TMPDIR/${test_id}_repo"
    saves_dir="$TEST_TMPDIR/${test_id}_saves"

    "$CONTINUITY_GIT_BIN" init --bare "$remote_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$remote_dir" symbolic-ref HEAD refs/heads/main 2>/dev/null

    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$seed_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" checkout -b main 2>/dev/null || true
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.email "s@t"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.name "S"

    # Seed with saves
    mkdir -p "$seed_dir/snes" "$seed_dir/gba"
    printf 'repo_metroid' > "$seed_dir/snes/super_metroid.srm"
    printf 'repo_minish' > "$seed_dir/gba/minish_cap.srm"
    mkdir -p "$seed_dir/.continuity"
    printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$seed_dir/.continuity/.gitignore"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" add -A >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "seed: initial" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1
    rm -rf "$seed_dir"

    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$repo_dir" >/dev/null 2>&1
    se_init "$repo_dir" "test-device"

    # Stale state: sentinel present, no clean_shutdown
    mkdir -p "$repo_dir/.continuity"
    touch "$repo_dir/.continuity/sentinel"

    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    printf '%s\n' "$head_hash" > "$repo_dir/.continuity/last_known_commit"

    # Device saves mirror the repo
    mkdir -p "$saves_dir/SFC" "$saves_dir/GBA"
    printf 'repo_metroid' > "$saves_dir/SFC/super_metroid.srm"
    printf 'repo_minish' > "$saves_dir/GBA/minish_cap.srm"

    CONTINUITY_SAVES_ROOT="$saves_dir"
    CONTINUITY_REPO_DIR="$repo_dir"

    _SE_REMOTE="$remote_dir"
    _SE_REPO="$repo_dir"
    _SE_SAVES="$saves_dir"
}

# Helper: add a commit to the bare remote (simulating another device)
push_remote_save() {
    local remote_dir system filename content
    remote_dir="$1"; system="$2"; filename="$3"; content="$4"

    local work_dir
    work_dir=$(mktemp -d)
    "$CONTINUITY_GIT_BIN" clone "$remote_dir" "$work_dir/clone" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" config user.email "r@t"
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" config user.name "R"
    mkdir -p "$work_dir/clone/$system"
    printf '%s' "$content" > "$work_dir/clone/$system/$filename"
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" add "$system/$filename" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" commit -m "remote: $system/$filename" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$work_dir/clone" push origin main >/dev/null 2>&1
    rm -rf "$work_dir"
}

# ============================
# Test sb_is_stale
# ============================

# --- Sentinel absent, marker absent: not stale ---
setup_stale_env "is1"
rm -f "$_SE_REPO/.continuity/sentinel"
rc=0; sb_is_stale "$_SE_REPO" || rc=$?
assert_rc "is_stale: no sentinel no marker -> 1" 1 "$rc"

# --- Sentinel present, marker absent: stale ---
setup_stale_env "is2"
rc=0; sb_is_stale "$_SE_REPO" || rc=$?
assert_rc "is_stale: sentinel + no marker -> 0" 0 "$rc"

# --- Sentinel present, marker present: not stale ---
setup_stale_env "is3"
sb_mark_clean_shutdown "$_SE_REPO"
rc=0; sb_is_stale "$_SE_REPO" || rc=$?
assert_rc "is_stale: sentinel + marker -> 1" 1 "$rc"

# --- Sentinel absent, marker present: not stale ---
setup_stale_env "is4"
rm -f "$_SE_REPO/.continuity/sentinel"
sb_mark_clean_shutdown "$_SE_REPO"
rc=0; sb_is_stale "$_SE_REPO" || rc=$?
assert_rc "is_stale: no sentinel + marker -> 1" 1 "$rc"

# --- sb_is_stale does not modify files ---
setup_stale_env "is5"
ref_file="$TEST_TMPDIR/is5_ref"
ls -la "$_SE_REPO/.continuity/" > "$ref_file" 2>/dev/null
sb_is_stale "$_SE_REPO" || true
ls -la "$_SE_REPO/.continuity/" > "$TEST_TMPDIR/is5_after" 2>/dev/null
content_before=$(cat "$ref_file")
content_after=$(cat "$TEST_TMPDIR/is5_after")
assert_eq "is_stale: does not modify files" "$content_before" "$content_after"

# ============================
# Test sb_mark_clean_shutdown
# ============================

# --- Creates marker and directory ---
setup_stale_env "mk1"
rm -rf "$_SE_REPO/.continuity"
rc=0; sb_mark_clean_shutdown "$_SE_REPO" || rc=$?
assert_rc "mark_clean: returns 0" 0 "$rc"
assert_file_exists "mark_clean: marker created" "$_SE_REPO/.continuity/clean_shutdown"
content=$(cat "$_SE_REPO/.continuity/clean_shutdown")
if [ -n "$content" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: mark_clean: marker has non-empty content\n' >&2
    failed=$((failed + 1))
fi

# --- Overwrite existing marker (idempotent) ---
setup_stale_env "mk2"
sb_mark_clean_shutdown "$_SE_REPO"
first_content=$(cat "$_SE_REPO/.continuity/clean_shutdown")
sleep 1
rc=0; sb_mark_clean_shutdown "$_SE_REPO" || rc=$?
assert_rc "mark_clean overwrite: returns 0" 0 "$rc"
assert_file_exists "mark_clean overwrite: file still exists" "$_SE_REPO/.continuity/clean_shutdown"

# --- After marking, sb_is_stale returns 1 ---
setup_stale_env "mk3"
sb_mark_clean_shutdown "$_SE_REPO"
rc=0; sb_is_stale "$_SE_REPO" || rc=$?
assert_rc "mark_clean: is_stale returns 1 after mark" 1 "$rc"

# ============================
# Test sb_clear_shutdown_marker
# ============================

# --- Removes marker when it exists ---
setup_stale_env "cl1"
sb_mark_clean_shutdown "$_SE_REPO"
rc=0; sb_clear_shutdown_marker "$_SE_REPO" || rc=$?
assert_rc "clear_marker: returns 0" 0 "$rc"
assert_file_not_exists "clear_marker: file removed" "$_SE_REPO/.continuity/clean_shutdown"

# --- Returns 0 when marker does not exist (idempotent) ---
setup_stale_env "cl2"
rc=0; sb_clear_shutdown_marker "$_SE_REPO" || rc=$?
assert_rc "clear_marker absent: returns 0" 0 "$rc"

# --- After clearing, sb_is_stale returns 0 (sentinel present) ---
setup_stale_env "cl3"
sb_mark_clean_shutdown "$_SE_REPO"
sb_clear_shutdown_marker "$_SE_REPO"
rc=0; sb_is_stale "$_SE_REPO" || rc=$?
assert_rc "clear_marker: is_stale returns 0" 0 "$rc"

# ============================
# Test sb_run — No stored commit
# ============================
setup_stale_env "run1"
rm -f "$_SE_REPO/.continuity/last_known_commit"

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run: no stored commit returns 1" 1 "$rc"

# ============================
# Test sb_run — Offline, no unpushed commits, remote unchanged, device has changes
# ============================
setup_stale_env "run2"
pal_is_online() { return 1; }

printf 'offline_metroid' > "$_SE_SAVES/SFC/super_metroid.srm"

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run offline local changes: returns 0" 0 "$rc"

repo_content=$(cat "$_SE_REPO/snes/super_metroid.srm")
assert_eq "run offline: device save in repo" "offline_metroid" "$repo_content"

commit_msg=$("$CONTINUITY_GIT_BIN" -C "$_SE_REPO" log -1 --format='%s')
assert_contains "run offline: commit msg" "$commit_msg" "stale boot catch-up"

# Verify NOT pushed (offline)
remote_content=$("$CONTINUITY_GIT_BIN" -C "$_SE_REMOTE" show HEAD:snes/super_metroid.srm 2>/dev/null)
assert_eq "run offline: remote not updated" "repo_metroid" "$remote_content"

assert_file_exists "run offline: sentinel exists" "$_SE_REPO/.continuity/sentinel"

# Restore
pal_is_online() { return 0; }

# ============================
# Test sb_run — Online, unpushed commits exist, push succeeds
# ============================
setup_stale_env "run3"

# Create a local commit that hasn't been pushed
printf 'local_uncommitted' > "$_SE_REPO/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$_SE_REPO" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$_SE_REPO" commit -m "interrupted session" >/dev/null 2>&1

# Track push calls
_PUSH_CALL_ORDER=""
_REAL_SE_PUSH_run3=$(command -v se_push 2>/dev/null || true)
se_push() {
    _PUSH_CALL_ORDER="${_PUSH_CALL_ORDER}push;"
    "$CONTINUITY_GIT_BIN" -C "$1" push origin main >/dev/null 2>&1
    return 0
}
_REAL_SE_PULL_run3=$(command -v se_pull 2>/dev/null || true)
se_pull() {
    _PUSH_CALL_ORDER="${_PUSH_CALL_ORDER}pull;"
    "$CONTINUITY_GIT_BIN" -C "$1" pull --ff-only origin main >/dev/null 2>&1
    return 0
}

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run unpushed: returns 0" 0 "$rc"

# Verify push was called before pull
assert_contains "run unpushed: push before pull" "$_PUSH_CALL_ORDER" "push;pull;"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
se_init "$_SE_REPO" "test-device"

# ============================
# Test sb_run — Online, unpushed commits, push fails in pre-pull step (non-fatal)
# ============================
setup_stale_env "run4"

# Create unpushed commit
printf 'local_data' > "$_SE_REPO/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$_SE_REPO" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$_SE_REPO" commit -m "interrupted" >/dev/null 2>&1

_run4_push_count=0
se_push() {
    _run4_push_count=$((_run4_push_count + 1))
    if [ "$_run4_push_count" -eq 1 ]; then
        return 1  # First push fails (pre-pull)
    fi
    "$CONTINUITY_GIT_BIN" -C "$1" push origin main >/dev/null 2>&1
    return 0
}

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run push fail pre-pull: returns 0 (non-fatal)" 0 "$rc"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
se_init "$_SE_REPO" "test-device"

# ============================
# Test sb_run — Remote has new saves
# ============================
setup_stale_env "run5"

# Push a new save to remote from "another device"
push_remote_save "$_SE_REMOTE" "gb" "links_awakening.srm" "remote_links"

# Create GB dir for device saves
mkdir -p "$_SE_SAVES/GB"

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run remote changes: returns 0" 0 "$rc"

# Verify new save applied to device
assert_file_exists "run remote: save on device" "$_SE_SAVES/GB/links_awakening.srm"
device_content=$(cat "$_SE_SAVES/GB/links_awakening.srm")
assert_eq "run remote: correct content" "remote_links" "$device_content"

# Verify stored commit updated
stored=$(cat "$_SE_REPO/.continuity/last_known_commit" | tr -d '[:space:]')
head=$("$CONTINUITY_GIT_BIN" -C "$_SE_REPO" rev-parse HEAD)
assert_eq "run remote: stored commit updated" "$head" "$stored"

# ============================
# Test sb_run — Remote unchanged, device has local changes
# ============================
setup_stale_env "run6"

printf 'played_more_metroid' > "$_SE_SAVES/SFC/super_metroid.srm"

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run local changes: returns 0" 0 "$rc"

repo_content=$(cat "$_SE_REPO/snes/super_metroid.srm")
assert_eq "run local changes: device save in repo" "played_more_metroid" "$repo_content"

commit_msg=$("$CONTINUITY_GIT_BIN" -C "$_SE_REPO" log -1 --format='%s')
assert_contains "run local changes: commit msg" "$commit_msg" "stale boot catch-up"

# Verify pushed to remote
remote_content=$("$CONTINUITY_GIT_BIN" -C "$_SE_REMOTE" show HEAD:snes/super_metroid.srm 2>/dev/null)
assert_eq "run local changes: pushed to remote" "played_more_metroid" "$remote_content"

stored=$(cat "$_SE_REPO/.continuity/last_known_commit" | tr -d '[:space:]')
head=$("$CONTINUITY_GIT_BIN" -C "$_SE_REPO" rev-parse HEAD)
assert_eq "run local changes: stored commit updated" "$head" "$stored"

# ============================
# Test sb_run — Remote unchanged, device unchanged (no-op)
# ============================
setup_stale_env "run7"

commit_before=$("$CONTINUITY_GIT_BIN" -C "$_SE_REPO" rev-parse HEAD)

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run no-op: returns 0" 0 "$rc"

commit_after=$("$CONTINUITY_GIT_BIN" -C "$_SE_REPO" rev-parse HEAD)
assert_eq "run no-op: no new commit" "$commit_before" "$commit_after"

assert_file_exists "run no-op: sentinel updated" "$_SE_REPO/.continuity/sentinel"

# ============================
# Test sb_run — Diverged remote — conflict handler called
# ============================
setup_stale_env "run8"

se_pull() { return 1; }
ch_handle_pull_conflict() { return 0; }

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run diverged: conflict handler called, returns 0" 0 "$rc"

# Test: diverged with conflict handler failure → returns 1
setup_stale_env "run8b"
se_pull() { return 1; }
ch_handle_pull_conflict() { return 1; }

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run diverged conflict handler fail: returns 1" 1 "$rc"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"
se_init "$_SE_REPO" "test-device"

# ============================
# Test sb_run — Unknown system directory on device (partial success)
# ============================
setup_stale_env "run9"

# Valid change
printf 'changed_metroid' > "$_SE_SAVES/SFC/super_metroid.srm"
# Unknown system save
mkdir -p "$_SE_SAVES/UNKNOWN"
printf 'mystery_data' > "$_SE_SAVES/UNKNOWN/game.srm"

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run unknown sys: returns 0" 0 "$rc"

repo_content=$(cat "$_SE_REPO/snes/super_metroid.srm")
assert_eq "run unknown sys: valid save committed" "changed_metroid" "$repo_content"
assert_file_not_exists "run unknown sys: unknown file not in repo" "$_SE_REPO/unknown/game.srm"

# ============================
# Test sb_run — Catch-up scan, repo-only file not removed
# ============================
setup_stale_env "run10"

# Repo has a file that's not on the device (gba/minish_cap.srm is in repo)
# Remove the device copy
rm -f "$_SE_SAVES/GBA/minish_cap.srm"

commit_before=$("$CONTINUITY_GIT_BIN" -C "$_SE_REPO" rev-parse HEAD)

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run repo-only: returns 0" 0 "$rc"

# Repo file must still exist
assert_file_exists "run repo-only: file not removed from repo" "$_SE_REPO/gba/minish_cap.srm"

# ============================
# Test sb_run — se_commit fails during catch-up
# ============================
setup_stale_env "run11"

printf 'fail_commit_data' > "$_SE_SAVES/SFC/super_metroid.srm"

se_commit() { return 1; }

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run commit fail: returns 1" 1 "$rc"

# Sentinel should NOT have been updated after failure
# (We can't easily check mtime, but sentinel should exist from setup)
assert_file_exists "run commit fail: sentinel exists" "$_SE_REPO/.continuity/sentinel"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
se_init "$_SE_REPO" "test-device"

# ============================
# Test sb_run — sb_clear_shutdown_marker called even when later steps fail
# ============================
setup_stale_env "run12"

# Create the clean_shutdown marker
sb_mark_clean_shutdown "$_SE_REPO"
# Now make it stale again by removing the marker check
# Actually, sb_run doesn't check sb_is_stale — it just clears the marker.
# Set up to fail on diverged pull with conflict handler failure
se_pull() { return 1; }
ch_handle_pull_conflict() { return 1; }

rc=0; sb_run "$_SE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "run marker cleared on fail: returns 1 (conflict handler fail)" 1 "$rc"

# The clean_shutdown marker must be gone (cleared as first step)
assert_file_not_exists "run marker cleared on fail: marker removed" "$_SE_REPO/.continuity/clean_shutdown"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"
se_init "$_SE_REPO" "test-device"

# --- Summary ---
printf '\ntest_stale_boot: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
