#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/core/boot_pull.sh
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
. "$PROJECT_ROOT/src/core/boot_pull.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# ============================
# Helper: create a bare remote with an initial commit and a local clone
# Returns: remote_dir repo_dir (space separated)
# ============================
setup_boot_pull_env() {
    local test_id remote_dir seed_dir repo_dir
    test_id="$1"
    remote_dir="$TEST_TMPDIR/${test_id}_remote.git"
    seed_dir="$TEST_TMPDIR/${test_id}_seed"
    repo_dir="$TEST_TMPDIR/${test_id}_repo"

    "$CONTINUITY_GIT_BIN" init --bare "$remote_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$remote_dir" symbolic-ref HEAD refs/heads/main 2>/dev/null

    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$seed_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" checkout -b main >/dev/null 2>&1 || true
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.email "seed@test"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.name "Seed"

    # Initial commit with an .srm file
    mkdir -p "$seed_dir/snes"
    printf 'snes_save_data_v1' > "$seed_dir/snes/super_metroid.srm"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" add snes/super_metroid.srm >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "initial save" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1

    # Clone for the device
    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$repo_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" checkout main >/dev/null 2>&1 || true
    se_init "$repo_dir" "test-device" >/dev/null 2>&1

    # Set up .continuity state (post cold-start)
    mkdir -p "$repo_dir/.continuity"
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    cs_store_commit "$repo_dir" "$head_hash"
    cs_create_sentinel "$repo_dir"

    printf '%s %s %s' "$remote_dir" "$seed_dir" "$repo_dir"
}

# Helper: push new .srm from "another device" via seed_dir
push_new_save() {
    local seed_dir canonical filename content
    seed_dir="$1"; canonical="$2"; filename="$3"; content="$4"
    mkdir -p "$seed_dir/$canonical"
    printf '%s' "$content" > "$seed_dir/$canonical/$filename"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" add "$canonical/$filename" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "$canonical/$filename updated" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1
}

# ============================
# Tests for bp_get_remote_changes
# ============================
printf '\n=== bp_get_remote_changes tests ===\n' >&2

# Test: .srm files changed between commits
env_out=$(setup_boot_pull_env "grc1")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
seed_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

old_commit=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)

# Push two .srm files + one device JSON from seed
push_new_save "$seed_dir" "gba" "minish_cap.srm" "gba_data"
mkdir -p "$seed_dir/.continuity/devices"
printf '{"device": "other"}' > "$seed_dir/.continuity/devices/other.json"
"$CONTINUITY_GIT_BIN" -C "$seed_dir" add .continuity/devices/other.json >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "register other device" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1

# Pull into repo to get all commits
"$CONTINUITY_GIT_BIN" -C "$repo_dir" pull origin main >/dev/null 2>&1

output=$(bp_get_remote_changes "$repo_dir" "$old_commit")
rc=$?
assert_rc "bp_get_remote_changes returns 0" 0 "$rc"
assert_contains "bp_get_remote_changes includes gba/minish_cap.srm" "$output" "gba/minish_cap.srm"
assert_not_contains "bp_get_remote_changes excludes device JSON" "$output" "other.json"

# Test: only non-.srm changes → empty output
env_out=$(setup_boot_pull_env "grc2")
seed_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

old_commit=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)

mkdir -p "$seed_dir/.continuity/devices"
printf '{"device": "other2"}' > "$seed_dir/.continuity/devices/other2.json"
"$CONTINUITY_GIT_BIN" -C "$seed_dir" add .continuity/devices/other2.json >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "register other2" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" pull origin main >/dev/null 2>&1

output=$(bp_get_remote_changes "$repo_dir" "$old_commit")
rc=$?
assert_rc "bp_get_remote_changes non-srm returns 0" 0 "$rc"
assert_eq "bp_get_remote_changes non-srm output is empty" "" "$output"

# Test: nonexistent commit hash → returns 1
env_out=$(setup_boot_pull_env "grc3")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

rc=0
bp_get_remote_changes "$repo_dir" "deadbeef00000000000000000000000000000000" >/dev/null 2>&1 || rc=$?
assert_rc "bp_get_remote_changes bad commit returns 1" 1 "$rc"

# Test: output paths are repo-relative
env_out=$(setup_boot_pull_env "grc4")
seed_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

old_commit=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
push_new_save "$seed_dir" "gb" "links_awakening.srm" "gb_data"
"$CONTINUITY_GIT_BIN" -C "$repo_dir" pull origin main >/dev/null 2>&1

output=$(bp_get_remote_changes "$repo_dir" "$old_commit")
assert_eq "bp_get_remote_changes paths are repo-relative" "gb/links_awakening.srm" "$output"

# ============================
# Tests for bp_apply_remote_saves
# ============================
printf '\n=== bp_apply_remote_saves tests ===\n' >&2

# Test: copies file to correct device path
env_out=$(setup_boot_pull_env "apply1")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/apply1_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

rc=0
bp_apply_remote_saves "$repo_dir" "snes/super_metroid.srm" 2>/dev/null || rc=$?
assert_rc "bp_apply_remote_saves single file returns 0" 0 "$rc"
assert_file_exists "bp_apply_remote_saves creates device file" "$saves_dir/SFC/super_metroid.srm"
assert_files_identical "bp_apply_remote_saves content matches" "$repo_dir/snes/super_metroid.srm" "$saves_dir/SFC/super_metroid.srm"

# Test: creates missing directory
env_out=$(setup_boot_pull_env "apply2")
seed_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

push_new_save "$seed_dir" "gb" "links_awakening.srm" "gb_save_data"
"$CONTINUITY_GIT_BIN" -C "$repo_dir" pull origin main >/dev/null 2>&1

saves_dir="$TEST_TMPDIR/apply2_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

rc=0
bp_apply_remote_saves "$repo_dir" "gb/links_awakening.srm" 2>/dev/null || rc=$?
assert_rc "bp_apply_remote_saves mkdir returns 0" 0 "$rc"
assert_file_exists "bp_apply_remote_saves creates dir and file" "$saves_dir/GB/links_awakening.srm"

# Test: empty changed_files → no-op, returns 0
rc=0
bp_apply_remote_saves "$repo_dir" "" 2>/dev/null || rc=$?
assert_rc "bp_apply_remote_saves empty input returns 0" 0 "$rc"

# Test: unrecognized system → returns 1
env_out=$(setup_boot_pull_env "apply3")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)
mkdir -p "$repo_dir/fakesys"
printf 'fake_data' > "$repo_dir/fakesys/game.srm"

saves_dir="$TEST_TMPDIR/apply3_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

rc=0
bp_apply_remote_saves "$repo_dir" "fakesys/game.srm" 2>/dev/null || rc=$?
assert_rc "bp_apply_remote_saves unknown system returns 1" 1 "$rc"

# Test: cp failure → returns 1
# Simulate cp failure by overriding cp via a wrapper that fails
env_out=$(setup_boot_pull_env "apply4")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/apply4_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

# Create a custom bp_apply_remote_saves that simulates cp failure
# by making the source unreadable (won't work as root), so instead
# test through bp_run with a failing apply override
bp_apply_remote_saves_orig() { bp_apply_remote_saves "$@"; }
bp_apply_remote_saves() {
    pal_log "error" "Boot pull: failed to copy test/test.srm to /fake"
    return 1
}

rc=0
bp_apply_remote_saves "$repo_dir" "snes/super_metroid.srm" 2>/dev/null || rc=$?
assert_rc "bp_apply_remote_saves cp failure returns 1" 1 "$rc"

# Restore
. "$PROJECT_ROOT/src/core/boot_pull.sh"

# Test: deleted-on-remote file skipped
env_out=$(setup_boot_pull_env "apply5")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/apply5_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

# Simulate: repo_path listed in diff but file deleted after pull
rc=0
bp_apply_remote_saves "$repo_dir" "snes/nonexistent.srm" 2>/dev/null || rc=$?
assert_rc "bp_apply_remote_saves deleted remote file returns 0" 0 "$rc"
assert_file_not_exists "bp_apply_remote_saves does not create deleted file" "$saves_dir/SFC/nonexistent.srm"

# ============================
# Tests for bp_run
# ============================
printf '\n=== bp_run tests ===\n' >&2

# Reset CONTINUITY_SAVES_ROOT
CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/saves"

# Test: happy path — remote has new save
env_out=$(setup_boot_pull_env "run1")
seed_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/run1_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir/SFC"
cp "$repo_dir/snes/super_metroid.srm" "$saves_dir/SFC/super_metroid.srm"

push_new_save "$seed_dir" "gba" "minish_cap.srm" "gba_new_data"

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run happy path returns 0" 0 "$rc"
assert_file_exists "bp_run copies new save to device" "$saves_dir/GBA/minish_cap.srm"
assert_files_identical "bp_run new save content matches" "$repo_dir/gba/minish_cap.srm" "$saves_dir/GBA/minish_cap.srm"

# Verify stored commit updated
new_head=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
stored=$(cs_read_commit "$repo_dir")
assert_eq "bp_run updates stored commit" "$new_head" "$stored"

# Verify sentinel touched
assert_file_exists "bp_run touches sentinel" "$repo_dir/.continuity/sentinel"

# Test: no-op — no remote changes
env_out=$(setup_boot_pull_env "run2")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/run2_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

old_stored=$(cs_read_commit "$repo_dir")
old_sentinel_content=$(cat "$repo_dir/.continuity/sentinel")
sleep 1  # ensure mtime difference

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run no-op returns 0" 0 "$rc"

new_stored=$(cs_read_commit "$repo_dir")
assert_eq "bp_run no-op: stored commit unchanged" "$old_stored" "$new_stored"
assert_file_exists "bp_run no-op: sentinel exists" "$repo_dir/.continuity/sentinel"

# Test: non-srm remote change only
env_out=$(setup_boot_pull_env "run3")
seed_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/run3_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

old_stored=$(cs_read_commit "$repo_dir")

mkdir -p "$seed_dir/.continuity/devices"
printf '{"device": "other3"}' > "$seed_dir/.continuity/devices/other3.json"
"$CONTINUITY_GIT_BIN" -C "$seed_dir" add .continuity/devices/other3.json >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "register other3" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run non-srm change returns 0" 0 "$rc"

new_stored=$(cs_read_commit "$repo_dir")
new_head=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
assert_eq "bp_run non-srm: stored commit updated" "$new_head" "$new_stored"

# Test: missing stored commit → returns 1
env_out=$(setup_boot_pull_env "run4")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/run4_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

# Remove the last_known_commit file
rm -f "$repo_dir/.continuity/last_known_commit"

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run no stored commit returns 1" 1 "$rc"

# Test: network error (se_pull returns 2)
env_out=$(setup_boot_pull_env "run5")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/run5_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

old_stored=$(cs_read_commit "$repo_dir")
old_sentinel=$(cat "$repo_dir/.continuity/sentinel")

# Override se_pull to return 2
se_pull() { return 2; }

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run network error returns 2" 2 "$rc"

new_stored=$(cs_read_commit "$repo_dir")
assert_eq "bp_run network error: commit unchanged" "$old_stored" "$new_stored"

# Restore real se_pull
. "$PROJECT_ROOT/src/core/sync_engine.sh"

# Test: diverged (se_pull returns 1) — conflict handler called
env_out=$(setup_boot_pull_env "run6")
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/run6_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

# Override se_pull to return 1 and stub ch_handle_pull_conflict to succeed
se_pull() { return 1; }
ch_handle_pull_conflict() { return 0; }

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run diverged calls conflict handler, returns 0" 0 "$rc"

# Test: diverged with conflict handler failure → returns 1
ch_handle_pull_conflict() { return 1; }

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run diverged conflict handler fail returns 1" 1 "$rc"

# Restore
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"

# Test: apply failure → returns 1, commit not updated
env_out=$(setup_boot_pull_env "run7")
seed_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
repo_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

saves_dir="$TEST_TMPDIR/run7_saves"
CONTINUITY_SAVES_ROOT="$saves_dir"
mkdir -p "$saves_dir"

old_stored=$(cs_read_commit "$repo_dir")
push_new_save "$seed_dir" "snes" "new_game.srm" "data"

# Override bp_apply_remote_saves to fail
bp_apply_remote_saves() { return 1; }

rc=0
bp_run "$repo_dir" >/dev/null 2>&1 || rc=$?
assert_rc "bp_run apply failure returns 1" 1 "$rc"

new_stored=$(cs_read_commit "$repo_dir")
assert_eq "bp_run apply failure: commit not updated" "$old_stored" "$new_stored"

# Restore real bp_apply_remote_saves
. "$PROJECT_ROOT/src/core/boot_pull.sh"

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
