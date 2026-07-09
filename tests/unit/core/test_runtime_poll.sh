#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/core/runtime_poll.sh
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
. "$PROJECT_ROOT/src/core/runtime_poll.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# ============================
# Helper: create a bare remote + enrolled clone with sentinel
# ============================
setup_poll_env() {
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

    # Seed with one save so repo is not empty
    mkdir -p "$seed_dir/snes"
    printf 'repo_metroid' > "$seed_dir/snes/super_metroid.srm"
    mkdir -p "$seed_dir/.continuity"
    printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$seed_dir/.continuity/.gitignore"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" add -A >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "seed: initial" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1
    rm -rf "$seed_dir"

    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$repo_dir" >/dev/null 2>&1
    se_init "$repo_dir" "test-device"

    # Create sentinel + last_known_commit (simulating post-cold-start state)
    mkdir -p "$repo_dir/.continuity"
    touch "$repo_dir/.continuity/sentinel"

    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    printf '%s\n' "$head_hash" > "$repo_dir/.continuity/last_known_commit"

    # Device saves — mirror the repo
    mkdir -p "$saves_dir/SFC"
    printf 'repo_metroid' > "$saves_dir/SFC/super_metroid.srm"

    CONTINUITY_SAVES_ROOT="$saves_dir"
    CONTINUITY_REPO_DIR="$repo_dir"

    # Export for tests to use
    _PE_REMOTE="$remote_dir"
    _PE_REPO="$repo_dir"
    _PE_SAVES="$saves_dir"
}

# ============================
# Test rp_find_candidates
# ============================

# --- New .srm file newer than sentinel ---
setup_poll_env "fc1"
sleep 1
printf 'new_data' > "$_PE_SAVES/SFC/new_save.srm"

output=$(rp_find_candidates "$_PE_REPO")
assert_contains "find_candidates: new .srm found" "$output" "SFC/new_save.srm"

# --- No new files ---
setup_poll_env "fc2"
output=$(rp_find_candidates "$_PE_REPO")
rc=$?
assert_rc "find_candidates: returns 0 with no new files" 0 "$rc"
assert_eq "find_candidates: empty output when no candidates" "" "$output"

# --- File older than sentinel ---
setup_poll_env "fc3"
printf 'old_data' > "$_PE_SAVES/SFC/old_save.srm"
# Touch sentinel AFTER the file to ensure file is older
sleep 1
touch "$_PE_REPO/.continuity/sentinel"

output=$(rp_find_candidates "$_PE_REPO")
assert_eq "find_candidates: old file not returned" "" "$output"

# --- CONTINUITY_SAVES_ROOT does not exist ---
setup_poll_env "fc4"
CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/nonexistent_saves"
output=$(rp_find_candidates "$_PE_REPO" 2>/dev/null)
rc=$?
assert_rc "find_candidates: returns 0 when saves dir missing" 0 "$rc"
assert_eq "find_candidates: empty when saves dir missing" "" "$output"
CONTINUITY_SAVES_ROOT="$_PE_SAVES"

# --- Non-.srm file newer than sentinel ---
setup_poll_env "fc5"
sleep 1
printf 'not_srm' > "$_PE_SAVES/SFC/screenshot.png"

output=$(rp_find_candidates "$_PE_REPO")
assert_not_contains "find_candidates: non-.srm not returned" "$output" "screenshot.png"

# ============================
# Test rp_confirm_changes
# ============================

# --- Device file differs from repo copy ---
setup_poll_env "cc1"
printf 'different_data' > "$_PE_SAVES/SFC/super_metroid.srm"
output=$(rp_confirm_changes "$_PE_REPO" "$_PE_SAVES/SFC/super_metroid.srm")
assert_contains "confirm_changes: different file printed" "$output" "SFC/super_metroid.srm"

# --- Device file identical to repo copy ---
setup_poll_env "cc2"
# Already identical from setup
output=$(rp_confirm_changes "$_PE_REPO" "$_PE_SAVES/SFC/super_metroid.srm")
assert_eq "confirm_changes: identical file not printed" "" "$output"

# --- No corresponding repo copy (new file) ---
setup_poll_env "cc3"
mkdir -p "$_PE_SAVES/GBC"
printf 'new_save' > "$_PE_SAVES/GBC/pokemon_red.srm"
output=$(rp_confirm_changes "$_PE_REPO" "$_PE_SAVES/GBC/pokemon_red.srm")
assert_contains "confirm_changes: new file printed" "$output" "GBC/pokemon_red.srm"

# --- Unknown system directory ---
setup_poll_env "cc4"
mkdir -p "$_PE_SAVES/UNKNOWN"
printf 'mystery' > "$_PE_SAVES/UNKNOWN/game.srm"
output=$(rp_confirm_changes "$_PE_REPO" "$_PE_SAVES/UNKNOWN/game.srm" 2>/dev/null)
assert_eq "confirm_changes: unknown system not printed" "" "$output"

# --- Empty candidates ---
setup_poll_env "cc5"
output=$(rp_confirm_changes "$_PE_REPO" "")
rc=$?
assert_rc "confirm_changes: returns 0 on empty" 0 "$rc"
assert_eq "confirm_changes: empty output on empty input" "" "$output"

# --- Mixed candidates ---
setup_poll_env "cc6"
printf 'changed_metroid' > "$_PE_SAVES/SFC/super_metroid.srm"
mkdir -p "$_PE_SAVES/GBA"
printf 'repo_data' > "$_PE_SAVES/GBA/minish_cap.srm"
# Put identical data in repo for GBA
mkdir -p "$_PE_REPO/gba"
printf 'repo_data' > "$_PE_REPO/gba/minish_cap.srm"
"$CONTINUITY_GIT_BIN" -C "$_PE_REPO" add gba/minish_cap.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$_PE_REPO" commit -m "add gba" >/dev/null 2>&1

candidates=$(printf '%s\n%s' "$_PE_SAVES/SFC/super_metroid.srm" "$_PE_SAVES/GBA/minish_cap.srm")
output=$(rp_confirm_changes "$_PE_REPO" "$candidates")
assert_contains "confirm_changes mixed: changed file printed" "$output" "SFC/super_metroid.srm"
assert_not_contains "confirm_changes mixed: identical not printed" "$output" "GBA/minish_cap.srm"

# ============================
# Test rp_update_sentinel
# ============================

# --- Successful update ---
setup_poll_env "us1"
# Record a reference file before updating
ref_file="$TEST_TMPDIR/us1_ref"
touch "$ref_file"
sleep 1

rc=0; rp_update_sentinel "$_PE_REPO" || rc=$?
assert_rc "update_sentinel: returns 0" 0 "$rc"

# Sentinel should now be newer than ref_file
newer=$(find "$_PE_REPO/.continuity" -name "sentinel" -newer "$ref_file" 2>/dev/null)
if [ -n "$newer" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: update_sentinel: sentinel mtime not updated\n' >&2
    failed=$((failed + 1))
fi

# --- Read-only directory causes failure ---
# Skip if running as root (chmod 555 does not prevent writes for root)
if [ "$(id -u)" -ne 0 ]; then
    setup_poll_env "us2"
    # touch on an EXISTING file succeeds for its owner regardless of a
    # read-only parent (utimensat ownership rule) — remove the sentinel
    # so touch must CREATE through the 555 directory to fail.
    # (Latent for the repo's whole pre-CI life: this branch only runs
    # unprivileged, and local sessions were always root.)
    rm -f "$_PE_REPO/.continuity/sentinel"
    chmod 555 "$_PE_REPO/.continuity"
    rc=0; rp_update_sentinel "$_PE_REPO" 2>/dev/null || rc=$?
    assert_rc "update_sentinel: returns 1 on read-only" 1 "$rc"
    chmod 755 "$_PE_REPO/.continuity"
else
    # Root can always write — skip and count as pass
    passed=$((passed + 1))
fi

# ============================
# Test rp_run
# ============================

# --- No candidates: returns 0, no commit, sentinel unchanged ---
setup_poll_env "run1"
commit_before=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
sentinel_ref="$TEST_TMPDIR/run1_sref"
cp "$_PE_REPO/.continuity/sentinel" "$sentinel_ref"

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
commit_after=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
assert_rc "rp_run no candidates: returns 0" 0 "$rc"
assert_eq "rp_run no candidates: no new commit" "$commit_before" "$commit_after"

# Sentinel should not have been updated (no candidates path)
newer_check=$(find "$_PE_REPO/.continuity" -name "sentinel" -newer "$sentinel_ref" 2>/dev/null)
assert_eq "rp_run no candidates: sentinel not updated" "" "$newer_check"

# --- Candidates all false positives ---
setup_poll_env "run2"
# Touch device file after sentinel but keep identical content
sleep 1
touch "$_PE_SAVES/SFC/super_metroid.srm"
commit_before=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
commit_after=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
assert_rc "rp_run false positives: returns 0" 0 "$rc"
assert_eq "rp_run false positives: no new commit" "$commit_before" "$commit_after"

# --- One confirmed change, online ---
setup_poll_env "run3"
sleep 1
printf 'new_metroid_data' > "$_PE_SAVES/SFC/super_metroid.srm"

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "rp_run one change online: returns 0" 0 "$rc"

repo_content=$(cat "$_PE_REPO/snes/super_metroid.srm")
assert_eq "rp_run one change: repo has new content" "new_metroid_data" "$repo_content"

head_hash=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
stored_hash=$(tr -d '[:space:]' < "$_PE_REPO/.continuity/last_known_commit")
assert_eq "rp_run one change: last_known_commit matches HEAD" "$head_hash" "$stored_hash"

# Verify push reached remote
remote_content=$("$CONTINUITY_GIT_BIN" -C "$_PE_REMOTE" show HEAD:snes/super_metroid.srm 2>/dev/null)
assert_eq "rp_run one change: pushed to remote" "new_metroid_data" "$remote_content"

# --- One confirmed change, offline ---
setup_poll_env "run4"
sleep 1
printf 'offline_metroid' > "$_PE_SAVES/SFC/super_metroid.srm"

# Record push calls
PUSH_CALLS=0
se_push() { PUSH_CALLS=$((PUSH_CALLS + 1)); return 2; }
pal_is_online() { return 1; }

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "rp_run offline: returns 0" 0 "$rc"
assert_eq "rp_run offline: push not called" "0" "$PUSH_CALLS"

repo_content=$(cat "$_PE_REPO/snes/super_metroid.srm")
assert_eq "rp_run offline: repo has new content" "offline_metroid" "$repo_content"

# Restore
pal_is_online() { return 0; }
. "$PROJECT_ROOT/src/core/sync_engine.sh"
se_init "$_PE_REPO" "test-device"

# --- New file on device, no repo copy ---
setup_poll_env "run5"
sleep 1
mkdir -p "$_PE_SAVES/GBC"
printf 'pokemon_data' > "$_PE_SAVES/GBC/pokemon_red.srm"

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "rp_run new file: returns 0" 0 "$rc"
assert_file_exists "rp_run new file: appears in repo" "$_PE_REPO/gbc/pokemon_red.srm"

repo_content=$(cat "$_PE_REPO/gbc/pokemon_red.srm")
assert_eq "rp_run new file: correct content" "pokemon_data" "$repo_content"

# --- Missing sentinel ---
setup_poll_env "run6"
rm -f "$_PE_REPO/.continuity/sentinel"
commit_before=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
commit_after=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
assert_rc "rp_run missing sentinel: returns 1" 1 "$rc"
assert_eq "rp_run missing sentinel: no new commit" "$commit_before" "$commit_after"

# --- se_commit fails ---
setup_poll_env "run7"
sleep 1
printf 'fail_commit_data' > "$_PE_SAVES/SFC/super_metroid.srm"

se_commit() { return 1; }

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "rp_run commit fail: returns 1" 1 "$rc"

# Sentinel should not have been updated
assert_file_exists "rp_run commit fail: sentinel still exists" "$_PE_REPO/.continuity/sentinel"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
se_init "$_PE_REPO" "test-device"

# --- Idempotency ---
setup_poll_env "run8"
sleep 1
printf 'idempotent_data' > "$_PE_SAVES/SFC/super_metroid.srm"

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "rp_run idempotency first: returns 0" 0 "$rc"
head_after_first=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "rp_run idempotency second: returns 0" 0 "$rc"
head_after_second=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
assert_eq "rp_run idempotency: no second commit" "$head_after_first" "$head_after_second"

# --- Unknown system dir in changed files (partial success) ---
setup_poll_env "run9"
sleep 1

# Create a valid changed file
printf 'changed_metroid' > "$_PE_SAVES/SFC/super_metroid.srm"
# Create an unknown system file
mkdir -p "$_PE_SAVES/UNKNOWN"
printf 'mystery_data' > "$_PE_SAVES/UNKNOWN/game.srm"

rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "rp_run unknown sys: returns 0" 0 "$rc"

repo_content=$(cat "$_PE_REPO/snes/super_metroid.srm")
assert_eq "rp_run unknown sys: valid file committed" "changed_metroid" "$repo_content"
assert_file_not_exists "rp_run unknown sys: unknown file not in repo" "$_PE_REPO/unknown/game.srm"

# --- cmp false positive after copy (git edge case) ---
setup_poll_env "run10"
sleep 1
printf 'edge_case_data' > "$_PE_SAVES/SFC/super_metroid.srm"

# Override cd_detect_changes to return empty (simulating git sees no change)
cd_detect_changes() { printf ''; return 0; }

commit_before=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
rc=0; rp_run "$_PE_REPO" >/dev/null 2>&1 || rc=$?
commit_after=$("$CONTINUITY_GIT_BIN" -C "$_PE_REPO" rev-parse HEAD)
assert_rc "rp_run git edge case: returns 0" 0 "$rc"
assert_eq "rp_run git edge case: no commit" "$commit_before" "$commit_after"

# Restore
. "$PROJECT_ROOT/src/core/change_detector.sh"

# --- Summary ---
printf '\ntest_runtime_poll: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
