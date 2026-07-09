#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: full stale boot recovery with real git operations
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

# --- Global Setup ---
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
. "$PROJECT_ROOT/src/core/boot_pull.sh"
. "$PROJECT_ROOT/src/core/runtime_poll.sh"
. "$PROJECT_ROOT/src/core/stale_boot.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# ============================
# Helper: create a complete stale boot test environment
# ============================
setup_env() {
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

    # Seed with initial saves
    mkdir -p "$seed_dir/snes" "$seed_dir/gba" "$seed_dir/gb"
    printf 'metroid_data' > "$seed_dir/snes/super_metroid.srm"
    printf 'minish_data' > "$seed_dir/gba/minish_cap.srm"
    mkdir -p "$seed_dir/.continuity"
    printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$seed_dir/.continuity/.gitignore"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" add -A >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "seed: initial saves" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1
    rm -rf "$seed_dir"

    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$repo_dir" >/dev/null 2>&1
    se_init "$repo_dir" "test-device"

    # Post-cold-start state: sentinel + last_known_commit, NO clean_shutdown (stale)
    mkdir -p "$repo_dir/.continuity"
    cs_create_sentinel "$repo_dir"
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    cs_store_commit "$repo_dir" "$head_hash"

    # Device saves mirror the repo
    mkdir -p "$saves_dir/SFC" "$saves_dir/GBA" "$saves_dir/GB"
    printf 'metroid_data' > "$saves_dir/SFC/super_metroid.srm"
    printf 'minish_data' > "$saves_dir/GBA/minish_cap.srm"

    CONTINUITY_SAVES_ROOT="$saves_dir"
    CONTINUITY_REPO_DIR="$repo_dir"

    _IT_REMOTE="$remote_dir"
    _IT_REPO="$repo_dir"
    _IT_SAVES="$saves_dir"
}

# Helper: push a save to the bare remote from "another device"
push_remote() {
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
# Test 1 — Stale with only remote changes
# ============================
setup_env "t1"

# Another device pushes new save and updates existing one
push_remote "$_IT_REMOTE" "gb" "links_awakening.srm" "remote_links_data"
push_remote "$_IT_REMOTE" "snes" "super_metroid.srm" "remote_metroid_updated"

# Verify stale state
rc=0; sb_is_stale "$_IT_REPO" || rc=$?
assert_rc "T1: is_stale returns 0" 0 "$rc"

rc=0; sb_run "$_IT_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "T1: sb_run returns 0" 0 "$rc"

# Verify new save arrived on device
assert_file_exists "T1: links_awakening on device" "$_IT_SAVES/GB/links_awakening.srm"
device_links=$(cat "$_IT_SAVES/GB/links_awakening.srm")
assert_eq "T1: links content correct" "remote_links_data" "$device_links"

# Verify updated save applied to device
device_metroid=$(cat "$_IT_SAVES/SFC/super_metroid.srm")
assert_eq "T1: metroid content updated" "remote_metroid_updated" "$device_metroid"

# Verify minish_cap unchanged
device_minish=$(cat "$_IT_SAVES/GBA/minish_cap.srm")
assert_eq "T1: minish unchanged" "minish_data" "$device_minish"

# Verify stored commit matches remote HEAD
stored=$(tr -d '[:space:]' < "$_IT_REPO/.continuity/last_known_commit")
remote_head=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" rev-parse HEAD)
assert_eq "T1: stored commit = HEAD" "$remote_head" "$stored"

# Verify sentinel updated
assert_file_exists "T1: sentinel exists" "$_IT_REPO/.continuity/sentinel"

# Verify clean_shutdown marker absent
assert_file_not_exists "T1: no clean_shutdown" "$_IT_REPO/.continuity/clean_shutdown"

# Verify idempotency: running again produces no new commit
head_before=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" rev-parse HEAD)
rc=0; sb_run "$_IT_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "T1: idempotent sb_run returns 0" 0 "$rc"
head_after=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" rev-parse HEAD)
assert_eq "T1: idempotent — no new commit" "$head_before" "$head_after"

# ============================
# Test 2 — Stale with only local changes
# ============================
setup_env "t2"

# Simulate play after last poll (before crash)
printf 'played_more_metroid' > "$_IT_SAVES/SFC/super_metroid.srm"

rc=0; sb_run "$_IT_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "T2: sb_run returns 0" 0 "$rc"

# Verify device changes in repo
repo_content=$(cat "$_IT_REPO/snes/super_metroid.srm")
assert_eq "T2: device save in repo" "played_more_metroid" "$repo_content"

# Verify commit message
commit_msg=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" log -1 --format='%s')
assert_contains "T2: commit says stale boot" "$commit_msg" "stale boot catch-up"

# Verify pushed to remote
remote_content=$("$CONTINUITY_GIT_BIN" -C "$_IT_REMOTE" show HEAD:snes/super_metroid.srm 2>/dev/null)
assert_eq "T2: pushed to remote" "played_more_metroid" "$remote_content"

# Verify stored commit matches HEAD
stored=$(tr -d '[:space:]' < "$_IT_REPO/.continuity/last_known_commit")
head=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" rev-parse HEAD)
assert_eq "T2: stored commit updated" "$head" "$stored"

# Verify sentinel updated
assert_file_exists "T2: sentinel updated" "$_IT_REPO/.continuity/sentinel"

# ============================
# Test 3 — Stale with both remote and local changes (different files)
# ============================
setup_env "t3"

# Remote adds a new save
push_remote "$_IT_REMOTE" "gb" "links_awakening.srm" "remote_links"

# Create GB dir for device
mkdir -p "$_IT_SAVES/GB"

# Device has local change on a different file
printf 'local_minish_update' > "$_IT_SAVES/GBA/minish_cap.srm"

rc=0; sb_run "$_IT_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "T3: sb_run returns 0" 0 "$rc"

# Verify inbound: links_awakening arrived on device
assert_file_exists "T3: links on device" "$_IT_SAVES/GB/links_awakening.srm"
device_links=$(cat "$_IT_SAVES/GB/links_awakening.srm")
assert_eq "T3: links content" "remote_links" "$device_links"

# Verify outbound: minish_cap updated in repo
repo_minish=$(cat "$_IT_REPO/gba/minish_cap.srm")
assert_eq "T3: minish in repo" "local_minish_update" "$repo_minish"

# Verify commit was made
commit_msg=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" log -1 --format='%s')
assert_contains "T3: catch-up commit" "$commit_msg" "stale boot catch-up"

# Verify stored commit and sentinel
stored=$(tr -d '[:space:]' < "$_IT_REPO/.continuity/last_known_commit")
head=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" rev-parse HEAD)
assert_eq "T3: stored commit = HEAD" "$head" "$stored"
assert_file_exists "T3: sentinel" "$_IT_REPO/.continuity/sentinel"

# ============================
# Test 4 — Clean boot (marker present) — sb_run not called
# ============================
setup_env "t4"

sb_mark_clean_shutdown "$_IT_REPO"

rc=0; sb_is_stale "$_IT_REPO" || rc=$?
assert_rc "T4: is_stale returns 1 (clean)" 1 "$rc"

# ============================
# Test 5 — Offline, local changes only
# ============================
setup_env "t5"

pal_is_online() { return 1; }

printf 'offline_save_data' > "$_IT_SAVES/SFC/super_metroid.srm"

rc=0; sb_run "$_IT_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "T5: sb_run returns 0 (offline)" 0 "$rc"

# Verify commit made locally
repo_content=$(cat "$_IT_REPO/snes/super_metroid.srm")
assert_eq "T5: device save in repo" "offline_save_data" "$repo_content"

commit_msg=$("$CONTINUITY_GIT_BIN" -C "$_IT_REPO" log -1 --format='%s')
assert_contains "T5: commit msg" "$commit_msg" "stale boot catch-up"

# Verify NOT pushed to remote (offline)
remote_content=$("$CONTINUITY_GIT_BIN" -C "$_IT_REMOTE" show HEAD:snes/super_metroid.srm 2>/dev/null)
assert_eq "T5: remote not updated" "metroid_data" "$remote_content"

# Verify sentinel updated
assert_file_exists "T5: sentinel updated" "$_IT_REPO/.continuity/sentinel"

# Restore
pal_is_online() { return 0; }

# ============================
# Teardown verification
# ============================
rm -rf "$TEST_TMPDIR"
if [ ! -d "$TEST_TMPDIR" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: teardown: TEST_TMPDIR still exists\n' >&2
    failed=$((failed + 1))
fi

# --- Summary ---
printf '\ntest_stale_boot_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
