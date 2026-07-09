#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/core/conflict_handler.sh
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
. "$PROJECT_ROOT/src/core/conflict_handler.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# ============================
# Helper: create bare remote + two clones (device-a and device-b)
# device-b is the primary working clone ($CONTINUITY_REPO_DIR equivalent)
# Returns: remote_dir device_a_dir device_b_dir (space separated)
# ============================
setup_conflict_env() {
    local test_id remote_dir seed_dir device_a_dir device_b_dir
    test_id="$1"
    remote_dir="$TEST_TMPDIR/${test_id}_remote.git"
    seed_dir="$TEST_TMPDIR/${test_id}_seed"
    device_a_dir="$TEST_TMPDIR/${test_id}_device_a"
    device_b_dir="$TEST_TMPDIR/${test_id}_device_b"

    # Create bare remote
    "$CONTINUITY_GIT_BIN" init --bare "$remote_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$remote_dir" symbolic-ref HEAD refs/heads/main 2>/dev/null

    # Seed repo with initial commit
    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$seed_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" checkout -b main >/dev/null 2>&1 || true
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.email "seed@test"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.name "Seed"

    mkdir -p "$seed_dir/snes"
    printf 'initial_save_data' > "$seed_dir/snes/super_metroid.srm"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" add . >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" commit -m "initial save" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" push origin main >/dev/null 2>&1

    # Clone for device-a
    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$device_a_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$device_a_dir" checkout main >/dev/null 2>&1 || true
    "$CONTINUITY_GIT_BIN" -C "$device_a_dir" config user.email "continuity@device-a"
    "$CONTINUITY_GIT_BIN" -C "$device_a_dir" config user.name "Continuity"
    "$CONTINUITY_GIT_BIN" -C "$device_a_dir" config commit.gpgsign false

    # Clone for device-b (our device under test)
    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$device_b_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$device_b_dir" checkout main >/dev/null 2>&1 || true
    se_init "$device_b_dir" "device-b" >/dev/null 2>&1

    # Set up .continuity state
    mkdir -p "$device_b_dir/.continuity"
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)
    cs_store_commit "$device_b_dir" "$head_hash"

    printf '%s %s %s' "$remote_dir" "$device_a_dir" "$device_b_dir"
}

# Helper: create a diverged state between device-a and device-b
# device-a pushes first, device-b commits locally (diverged)
create_diverged_state() {
    local device_a_dir device_b_dir repo_path content_a content_b
    device_a_dir="$1"
    device_b_dir="$2"
    repo_path="$3"
    content_a="$4"
    content_b="$5"

    local dir_part
    dir_part=$(dirname "$repo_path")

    # device-a: commit and push
    mkdir -p "$device_a_dir/$dir_part"
    printf '%s' "$content_a" > "$device_a_dir/$repo_path"
    "$CONTINUITY_GIT_BIN" -C "$device_a_dir" add "$repo_path" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit \
        -m "$(printf '%s updated\n\ndevice: device-a\ntimestamp: 2026-03-12T13:00:00Z' "$repo_path")" \
        >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1

    # device-b: commit locally (do NOT push — creates divergence)
    mkdir -p "$device_b_dir/$dir_part"
    printf '%s' "$content_b" > "$device_b_dir/$repo_path"
    "$CONTINUITY_GIT_BIN" -C "$device_b_dir" add "$repo_path" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit \
        -m "$(printf '%s updated\n\ndevice: device-b\ntimestamp: 2026-03-12T14:30:00Z' "$repo_path")" \
        >/dev/null 2>&1
}

# ============================
# Tests for ch_preserve_conflict
# ============================
printf '\n=== ch_preserve_conflict tests ===\n' >&2

CONTINUITY_DEVICE_NAME="my-brick"

# Test 1: basic preservation — .local file created with correct bytes
env_out=$(setup_conflict_env "pc1")
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Push from device-a to create origin/main history
printf 'device-a-bytes' > "$device_a_dir/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit \
    -m "$(printf 'snes/super_metroid.srm updated\n\ndevice: my-deck\ntimestamp: 2026-03-12T13:00:00Z')" \
    >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1

# Write local version in device-b
printf 'device-b-bytes' > "$device_b_dir/snes/super_metroid.srm"

# Fetch origin so git log on origin/main works
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" fetch origin >/dev/null 2>&1

# Save expected bytes
printf 'device-b-bytes' > "$TEST_TMPDIR/pc1_expected_local"

commit_before=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)

rc=0
ch_preserve_conflict "$device_b_dir" "snes/super_metroid.srm" "my-brick" 2>/dev/null || rc=$?
assert_rc "ch_preserve_conflict returns 0" 0 "$rc"

# AC 1: .local file has same bytes
assert_file_exists "ch_preserve_conflict creates .local" \
    "$device_b_dir/snes/super_metroid.srm.my-brick.local"
assert_files_identical "ch_preserve_conflict .local bytes match" \
    "$TEST_TMPDIR/pc1_expected_local" \
    "$device_b_dir/snes/super_metroid.srm.my-brick.local"

# AC 2: .conflict file exists with valid JSON fields
assert_file_exists "ch_preserve_conflict creates .conflict" \
    "$device_b_dir/snes/super_metroid.srm.conflict"

conflict_json=$(cat "$device_b_dir/snes/super_metroid.srm.conflict")
assert_contains "ch_preserve_conflict .conflict has _schema_version" "$conflict_json" '"_schema_version": "2.0"'
assert_contains "ch_preserve_conflict .conflict has file" "$conflict_json" '"file": "snes/super_metroid.srm"'
assert_contains "ch_preserve_conflict .conflict has identity" "$conflict_json" '"identity": "snes/super_metroid"'
assert_contains "ch_preserve_conflict .conflict has class" "$conflict_json" '"class": "srm"'
assert_contains "ch_preserve_conflict .conflict has source" "$conflict_json" '"source": "pull"'
assert_contains "ch_preserve_conflict .conflict has status" "$conflict_json" '"status": "unresolved"'

# AC 3: local_device matches device_name
assert_contains "ch_preserve_conflict .conflict has local_device" "$conflict_json" '"local_device": "my-brick"'

# AC 4: file field is canonical path
assert_contains "ch_preserve_conflict .conflict file is canonical" "$conflict_json" '"file": "snes/super_metroid.srm"'
assert_not_contains "ch_preserve_conflict .conflict file not .local" "$conflict_json" '"file": "snes/super_metroid.srm.my-brick.local"'

# AC 7: remote_device parsed from commit trailer
assert_contains "ch_preserve_conflict .conflict has remote_device" "$conflict_json" '"remote_device": "my-deck"'

# AC 6: no commit made
commit_after=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)
assert_eq "ch_preserve_conflict does not commit" "$commit_before" "$commit_after"

# Test 2: remote_device defaults to "unknown" when no trailer
env_out=$(setup_conflict_env "pc2")
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

printf 'device-a-bytes' > "$device_a_dir/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit -m "no trailer commit" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1

printf 'local-bytes' > "$device_b_dir/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" fetch origin >/dev/null 2>&1

rc=0
ch_preserve_conflict "$device_b_dir" "snes/super_metroid.srm" "my-brick" 2>/dev/null || rc=$?
assert_rc "ch_preserve_conflict no-trailer returns 0" 0 "$rc"

conflict_json=$(cat "$device_b_dir/snes/super_metroid.srm.conflict")
assert_contains "ch_preserve_conflict no-trailer defaults to unknown" "$conflict_json" '"remote_device": "unknown"'

# ============================
# Tests for ch_list_conflicts
# ============================
printf '\n=== ch_list_conflicts tests ===\n' >&2

# Test: two .conflict files found
env_out=$(setup_conflict_env "lc1")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

mkdir -p "$device_b_dir/snes" "$device_b_dir/gb"
printf '{}' > "$device_b_dir/snes/super_metroid.srm.conflict"
printf '{}' > "$device_b_dir/gb/links_awakening.srm.conflict"

output=$(ch_list_conflicts "$device_b_dir")
assert_contains "ch_list_conflicts finds snes conflict" "$output" "snes/super_metroid.srm.conflict"
assert_contains "ch_list_conflicts finds gb conflict" "$output" "gb/links_awakening.srm.conflict"

# Test: no .conflict files → empty output, rc=0
env_out=$(setup_conflict_env "lc2")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

output=$(ch_list_conflicts "$device_b_dir")
rc=$?
assert_rc "ch_list_conflicts empty returns 0" 0 "$rc"
assert_eq "ch_list_conflicts empty output" "" "$output"

# Test: only .conflict returned, not .local
env_out=$(setup_conflict_env "lc3")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

printf '{}' > "$device_b_dir/snes/super_metroid.srm.conflict"
printf 'bytes' > "$device_b_dir/snes/super_metroid.srm.my-brick.local"

output=$(ch_list_conflicts "$device_b_dir")
assert_contains "ch_list_conflicts includes .conflict" "$output" "snes/super_metroid.srm.conflict"
assert_not_contains "ch_list_conflicts excludes .local" "$output" ".local"

# Test: .conflict inside .git/ excluded
env_out=$(setup_conflict_env "lc4")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

mkdir -p "$device_b_dir/.git/refs"
printf '{}' > "$device_b_dir/.git/refs/test.conflict"
printf '{}' > "$device_b_dir/snes/super_metroid.srm.conflict"

output=$(ch_list_conflicts "$device_b_dir")
assert_contains "ch_list_conflicts includes repo conflict" "$output" "snes/super_metroid.srm.conflict"
assert_not_contains "ch_list_conflicts excludes .git conflict" "$output" "refs/test.conflict"

# ============================
# Tests for ch_list_local_files
# ============================
printf '\n=== ch_list_local_files tests ===\n' >&2

# Test: single .local file parsed correctly
env_out=$(setup_conflict_env "llf1")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

mkdir -p "$device_b_dir/snes"
printf 'bytes' > "$device_b_dir/snes/super_metroid.srm.my-brick.local"

output=$(ch_list_local_files "$device_b_dir")
assert_contains "ch_list_local_files has canonical path" "$output" "snes/super_metroid.srm"
assert_contains "ch_list_local_files has device name" "$output" "my-brick"
assert_eq "ch_list_local_files format" "snes/super_metroid.srm my-brick" "$output"

# Test: multiple .local files
env_out=$(setup_conflict_env "llf2")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

mkdir -p "$device_b_dir/snes" "$device_b_dir/gb"
printf 'bytes1' > "$device_b_dir/snes/super_metroid.srm.my-brick.local"
printf 'bytes2' > "$device_b_dir/gb/links_awakening.srm.my-deck.local"

output=$(ch_list_local_files "$device_b_dir")
assert_contains "ch_list_local_files multi: has snes" "$output" "snes/super_metroid.srm my-brick"
assert_contains "ch_list_local_files multi: has gb" "$output" "gb/links_awakening.srm my-deck"

# Test: no .local files → empty, rc=0
env_out=$(setup_conflict_env "llf3")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

output=$(ch_list_local_files "$device_b_dir")
rc=$?
assert_rc "ch_list_local_files empty returns 0" 0 "$rc"
assert_eq "ch_list_local_files empty output" "" "$output"

# Test: .local inside .git excluded
env_out=$(setup_conflict_env "llf4")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

mkdir -p "$device_b_dir/.git/refs"
printf 'bytes' > "$device_b_dir/.git/refs/test.srm.fake.local"
mkdir -p "$device_b_dir/gb"
printf 'bytes' > "$device_b_dir/gb/links_awakening.srm.my-deck.local"

output=$(ch_list_local_files "$device_b_dir")
assert_contains "ch_list_local_files includes repo local" "$output" "gb/links_awakening.srm my-deck"
assert_not_contains "ch_list_local_files excludes .git local" "$output" "refs/"

# ============================
# Tests for ch_handle_pull_conflict
# ============================
printf '\n=== ch_handle_pull_conflict tests ===\n' >&2

CONTINUITY_DEVICE_NAME="device-b"

# Test: basic conflict — remote wins, .local preserved
env_out=$(setup_conflict_env "hpc1")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

create_diverged_state "$device_a_dir" "$device_b_dir" \
    "snes/super_metroid.srm" "device-a-progress" "device-b-progress"

rc=0
ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1 || rc=$?

# AC 17, 18: returns 0, canonical has remote bytes
assert_rc "ch_handle_pull_conflict returns 0" 0 "$rc"

srm_content=$(cat "$device_b_dir/snes/super_metroid.srm")
assert_eq "ch_handle_pull_conflict: canonical has remote bytes" "device-a-progress" "$srm_content"

# AC 19: .local has local bytes
assert_file_exists "ch_handle_pull_conflict: .local exists" \
    "$device_b_dir/snes/super_metroid.srm.device-b.local"
local_content=$(cat "$device_b_dir/snes/super_metroid.srm.device-b.local")
assert_eq "ch_handle_pull_conflict: .local has local bytes" "device-b-progress" "$local_content"

# AC 20: .conflict exists
assert_file_exists "ch_handle_pull_conflict: .conflict exists" \
    "$device_b_dir/snes/super_metroid.srm.conflict"

# AC 21: artifacts in single commit
conflict_commit=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" log -1 --format="%H")
commit_files=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" show --name-only --format="" "$conflict_commit")
assert_contains "ch_handle_pull_conflict: commit has .local" "$commit_files" "snes/super_metroid.srm.device-b.local"
assert_contains "ch_handle_pull_conflict: commit has .conflict" "$commit_files" "snes/super_metroid.srm.conflict"

# AC 22: last_known_commit updated
head_hash=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)
stored=$(cs_read_commit "$device_b_dir")
assert_eq "ch_handle_pull_conflict: last_known_commit updated" "$head_hash" "$stored"

# Check .conflict JSON content
conflict_json=$(cat "$device_b_dir/snes/super_metroid.srm.conflict")
assert_contains "ch_handle_pull_conflict: remote_device is device-a" "$conflict_json" '"remote_device": "device-a"'
assert_contains "ch_handle_pull_conflict: local_device is device-b" "$conflict_json" '"local_device": "device-b"'
assert_contains "ch_handle_pull_conflict: status unresolved" "$conflict_json" '"status": "unresolved"'

# Test: multiple conflicted files in single commit
env_out=$(setup_conflict_env "hpc2")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Create gb dir in seed and push
mkdir -p "$device_a_dir/gb"
printf 'gb-seed' > "$device_a_dir/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" add gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit -m "seed gb" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" pull origin main >/dev/null 2>&1

# Now diverge on both files
# device-a pushes both changes
printf 'a-snes' > "$device_a_dir/snes/super_metroid.srm"
printf 'a-gb' > "$device_a_dir/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" add . >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit \
    -m "$(printf 'multi update\n\ndevice: device-a')" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1

# device-b commits locally (add specific files, NOT git add .)
printf 'b-snes' > "$device_b_dir/snes/super_metroid.srm"
printf 'b-gb' > "$device_b_dir/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" add snes/super_metroid.srm gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit \
    -m "$(printf 'multi update\n\ndevice: device-b')" >/dev/null 2>&1

rc=0
ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1 || rc=$?
assert_rc "ch_handle_pull_conflict multi returns 0" 0 "$rc"

assert_file_exists "ch_handle_pull_conflict multi: snes .local" \
    "$device_b_dir/snes/super_metroid.srm.device-b.local"
assert_file_exists "ch_handle_pull_conflict multi: gb .local" \
    "$device_b_dir/gb/links_awakening.srm.device-b.local"
assert_file_exists "ch_handle_pull_conflict multi: snes .conflict" \
    "$device_b_dir/snes/super_metroid.srm.conflict"
assert_file_exists "ch_handle_pull_conflict multi: gb .conflict" \
    "$device_b_dir/gb/links_awakening.srm.conflict"

snes_content=$(cat "$device_b_dir/snes/super_metroid.srm")
gb_content=$(cat "$device_b_dir/gb/links_awakening.srm")
assert_eq "ch_handle_pull_conflict multi: snes canonical has remote" "a-snes" "$snes_content"
assert_eq "ch_handle_pull_conflict multi: gb canonical has remote" "a-gb" "$gb_content"

snes_local=$(cat "$device_b_dir/snes/super_metroid.srm.device-b.local")
gb_local=$(cat "$device_b_dir/gb/links_awakening.srm.device-b.local")
assert_eq "ch_handle_pull_conflict multi: snes .local has device-b" "b-snes" "$snes_local"
assert_eq "ch_handle_pull_conflict multi: gb .local has device-b" "b-gb" "$gb_local"

# Test: no .srm diff — only non-save files diverged (AC 25)
env_out=$(setup_conflict_env "hpc3")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# device-a: push a non-.srm file
mkdir -p "$device_a_dir/.continuity/devices"
printf '{"device": "device-a"}' > "$device_a_dir/.continuity/devices/device-a.json"
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" add .continuity/devices/device-a.json >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit -m "register device-a" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1

# device-b: commit a different non-.srm file locally
mkdir -p "$device_b_dir/.continuity/devices"
printf '{"device": "device-b"}' > "$device_b_dir/.continuity/devices/device-b.json"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" add .continuity/devices/device-b.json >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit -m "register device-b" >/dev/null 2>&1

rc=0
ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1 || rc=$?
assert_rc "ch_handle_pull_conflict no-srm returns 0" 0 "$rc"

# No conflict artifacts should be created
conflict_count=$(find "$device_b_dir" ! -path "*/.git/*" -name "*.conflict" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "ch_handle_pull_conflict no-srm: no .conflict files" "0" "$conflict_count"

local_count=$(find "$device_b_dir" ! -path "*/.git/*" -name "*.local" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "ch_handle_pull_conflict no-srm: no .local files" "0" "$local_count"

# Test: fetch failure returns 1 (AC 24)
env_out=$(setup_conflict_env "hpc4")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Break the remote URL
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" remote set-url origin "file:///nonexistent/repo.git" >/dev/null 2>&1

rc=0
ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1 || rc=$?
assert_rc "ch_handle_pull_conflict fetch failure returns 1" 1 "$rc"

# Test: pal_on_conflict called when defined (AC 23)
env_out=$(setup_conflict_env "hpc5")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

create_diverged_state "$device_a_dir" "$device_b_dir" \
    "snes/super_metroid.srm" "a-progress" "b-progress"

# Define a recording stub
_ch_hook_log="$TEST_TMPDIR/hpc5_hook_log"
printf '' > "$_ch_hook_log"
pal_on_conflict() {
    printf '%s\n' "$1" >> "$_ch_hook_log"
}

rc=0
ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1 || rc=$?
assert_rc "ch_handle_pull_conflict with hook returns 0" 0 "$rc"

hook_output=$(cat "$_ch_hook_log")
assert_contains "pal_on_conflict called with repo_path" "$hook_output" "snes/super_metroid.srm"

# Clean up hook
unset -f pal_on_conflict

# Test: pal_on_conflict not defined — no error (AC 23)
env_out=$(setup_conflict_env "hpc6")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

create_diverged_state "$device_a_dir" "$device_b_dir" \
    "snes/super_metroid.srm" "a-bytes" "b-bytes"

rc=0
ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1 || rc=$?
assert_rc "ch_handle_pull_conflict no hook returns 0" 0 "$rc"

# Test: se_push offline returns 0 (AC 26)
env_out=$(setup_conflict_env "hpc7")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

create_diverged_state "$device_a_dir" "$device_b_dir" \
    "snes/super_metroid.srm" "a-bytes" "b-bytes"

# Override pal_is_online to simulate offline
pal_is_online() { return 1; }

rc=0
ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1 || rc=$?
assert_rc "ch_handle_pull_conflict offline returns 0" 0 "$rc"

# Restore
pal_is_online() { return 0; }

# ============================
# Tests for ch_resolve
# ============================
printf '\n=== ch_resolve tests ===\n' >&2

# Helper: set up a committed conflict state for resolution tests
setup_committed_conflict() {
    local test_id
    test_id="$1"
    local env_out remote_dir device_a_dir device_b_dir
    env_out=$(setup_conflict_env "$test_id")
    remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
    device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
    device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

    create_diverged_state "$device_a_dir" "$device_b_dir" \
        "snes/super_metroid.srm" "remote-bytes" "local-bytes"

    ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1

    printf '%s %s %s' "$remote_dir" "$device_a_dir" "$device_b_dir"
}

# Test: keep_remote (AC 27–31)
env_out=$(setup_committed_conflict "res1")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

commit_before=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_remote" 2>/dev/null || rc=$?
assert_rc "ch_resolve keep_remote returns 0" 0 "$rc"

# AC 27: canonical retains remote bytes
srm_content=$(cat "$device_b_dir/snes/super_metroid.srm")
assert_eq "ch_resolve keep_remote: canonical has remote" "remote-bytes" "$srm_content"

# AC 28: .local removed
assert_file_not_exists "ch_resolve keep_remote: .local removed" \
    "$device_b_dir/snes/super_metroid.srm.device-b.local"

# AC 29: .conflict removed
assert_file_not_exists "ch_resolve keep_remote: .conflict removed" \
    "$device_b_dir/snes/super_metroid.srm.conflict"

# AC 30: new commit
commit_after=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)
if [ "$commit_before" != "$commit_after" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: ch_resolve keep_remote: no new commit\n' >&2
    failed=$((failed + 1))
fi

# AC 31: last_known_commit updated
stored=$(cs_read_commit "$device_b_dir")
assert_eq "ch_resolve keep_remote: last_known_commit" "$commit_after" "$stored"

# Verify .local and .conflict removed from git index
index_local=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" ls-files -- 'snes/super_metroid.srm.*.local' 2>/dev/null)
index_conflict=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" ls-files -- 'snes/super_metroid.srm.conflict' 2>/dev/null)
assert_eq "ch_resolve keep_remote: .local not in index" "" "$index_local"
assert_eq "ch_resolve keep_remote: .conflict not in index" "" "$index_conflict"

# Test: keep_local (AC 32–36)
env_out=$(setup_committed_conflict "res2")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

commit_before=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_local" 2>/dev/null || rc=$?
assert_rc "ch_resolve keep_local returns 0" 0 "$rc"

# AC 32: canonical has local bytes
srm_content=$(cat "$device_b_dir/snes/super_metroid.srm")
assert_eq "ch_resolve keep_local: canonical has local" "local-bytes" "$srm_content"

# AC 33: .local removed
assert_file_not_exists "ch_resolve keep_local: .local removed" \
    "$device_b_dir/snes/super_metroid.srm.device-b.local"

# AC 34: .conflict removed
assert_file_not_exists "ch_resolve keep_local: .conflict removed" \
    "$device_b_dir/snes/super_metroid.srm.conflict"

# AC 35: new commit
commit_after=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)
if [ "$commit_before" != "$commit_after" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: ch_resolve keep_local: no new commit\n' >&2
    failed=$((failed + 1))
fi

# AC 36: last_known_commit updated
stored=$(cs_read_commit "$device_b_dir")
assert_eq "ch_resolve keep_local: last_known_commit" "$commit_after" "$stored"

# Verify index cleaned up
index_local=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" ls-files -- 'snes/super_metroid.srm.*.local' 2>/dev/null)
index_conflict=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" ls-files -- 'snes/super_metroid.srm.conflict' 2>/dev/null)
assert_eq "ch_resolve keep_local: .local not in index" "" "$index_local"
assert_eq "ch_resolve keep_local: .conflict not in index" "" "$index_conflict"

# Test: keep_newest — local is newer (AC 37)
env_out=$(setup_committed_conflict "res3")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Rewrite .conflict with local_timestamp > remote_timestamp
printf '{\n  "_schema_version": "2.0",\n  "file": "snes/super_metroid.srm",\n  "identity": "snes/super_metroid",\n  "class": "srm",\n  "remote_device": "device-a",\n  "remote_timestamp": "2026-03-12T13:00:00Z",\n  "local_device": "device-b",\n  "local_timestamp": "2026-03-12T15:00:00Z",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
    > "$device_b_dir/snes/super_metroid.srm.conflict"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" add "snes/super_metroid.srm.conflict" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit -m "fix conflict timestamps" >/dev/null 2>&1

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_newest" 2>/dev/null || rc=$?
assert_rc "ch_resolve keep_newest local-newer returns 0" 0 "$rc"

# Local newer → should resolve as keep_local
srm_content=$(cat "$device_b_dir/snes/super_metroid.srm")
assert_eq "ch_resolve keep_newest local-newer: canonical has local" "local-bytes" "$srm_content"

assert_file_not_exists "ch_resolve keep_newest local-newer: .local removed" \
    "$device_b_dir/snes/super_metroid.srm.device-b.local"
assert_file_not_exists "ch_resolve keep_newest local-newer: .conflict removed" \
    "$device_b_dir/snes/super_metroid.srm.conflict"

# Test: keep_newest — remote is newer (AC 38)
env_out=$(setup_committed_conflict "res4")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Rewrite .conflict with remote_timestamp > local_timestamp
printf '{\n  "_schema_version": "2.0",\n  "file": "snes/super_metroid.srm",\n  "identity": "snes/super_metroid",\n  "class": "srm",\n  "remote_device": "device-a",\n  "remote_timestamp": "2026-03-12T15:00:00Z",\n  "local_device": "device-b",\n  "local_timestamp": "2026-03-12T13:00:00Z",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
    > "$device_b_dir/snes/super_metroid.srm.conflict"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" add "snes/super_metroid.srm.conflict" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit -m "fix conflict timestamps" >/dev/null 2>&1

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_newest" 2>/dev/null || rc=$?
assert_rc "ch_resolve keep_newest remote-newer returns 0" 0 "$rc"

srm_content=$(cat "$device_b_dir/snes/super_metroid.srm")
assert_eq "ch_resolve keep_newest remote-newer: canonical has remote" "remote-bytes" "$srm_content"

# Test: keep_newest — equal timestamps → remote wins (AC 38)
env_out=$(setup_committed_conflict "res5")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

printf '{\n  "_schema_version": "2.0",\n  "file": "snes/super_metroid.srm",\n  "identity": "snes/super_metroid",\n  "class": "srm",\n  "remote_device": "device-a",\n  "remote_timestamp": "2026-03-12T13:00:00Z",\n  "local_device": "device-b",\n  "local_timestamp": "2026-03-12T13:00:00Z",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
    > "$device_b_dir/snes/super_metroid.srm.conflict"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" add "snes/super_metroid.srm.conflict" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit -m "fix conflict timestamps" >/dev/null 2>&1

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_newest" 2>/dev/null || rc=$?
assert_rc "ch_resolve keep_newest equal returns 0" 0 "$rc"

srm_content=$(cat "$device_b_dir/snes/super_metroid.srm")
assert_eq "ch_resolve keep_newest equal: canonical has remote (tie)" "remote-bytes" "$srm_content"

# Test: keep_newest — missing timestamp refuses to guess (gap review)
env_out=$(setup_committed_conflict "res5b")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

printf '{\n  "_schema_version": "2.0",\n  "file": "snes/super_metroid.srm",\n  "identity": "snes/super_metroid",\n  "class": "srm",\n  "remote_device": "device-a",\n  "remote_timestamp": "",\n  "local_device": "device-b",\n  "local_timestamp": "2026-03-12T13:00:00Z",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
    > "$device_b_dir/snes/super_metroid.srm.conflict"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" add "snes/super_metroid.srm.conflict" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit -m "missing remote timestamp" >/dev/null 2>&1

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_newest" 2>/dev/null || rc=$?
assert_rc "ch_resolve keep_newest missing timestamp returns 1" 1 "$rc"
assert_file_exists "keep_newest missing-ts: artifacts untouched (.local intact)" \
    "$device_b_dir/snes/super_metroid.srm.device-b.local"
assert_file_exists "keep_newest missing-ts: .conflict intact for manual resolve" \
    "$device_b_dir/snes/super_metroid.srm.conflict"

# Test: prompt — no changes (AC 40, 41)
env_out=$(setup_committed_conflict "res6")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

commit_before=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "prompt" 2>/dev/null || rc=$?
assert_rc "ch_resolve prompt returns 0" 0 "$rc"

commit_after=$("$CONTINUITY_GIT_BIN" -C "$device_b_dir" rev-parse HEAD)
assert_eq "ch_resolve prompt: no new commit" "$commit_before" "$commit_after"

assert_file_exists "ch_resolve prompt: .local still exists" \
    "$device_b_dir/snes/super_metroid.srm.device-b.local"
assert_file_exists "ch_resolve prompt: .conflict still exists" \
    "$device_b_dir/snes/super_metroid.srm.conflict"

# Test: unknown resolution returns 1 (AC 44)
env_out=$(setup_committed_conflict "res7")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_bogus" 2>/dev/null || rc=$?
assert_rc "ch_resolve unknown resolution returns 1" 1 "$rc"

# Test: missing .local file returns 1 (AC 42)
env_out=$(setup_committed_conflict "res8")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Remove the .local file
rm -f "$device_b_dir/snes/super_metroid.srm.device-b.local"

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_remote" 2>/dev/null || rc=$?
assert_rc "ch_resolve missing .local returns 1" 1 "$rc"

# Test: missing .conflict file returns 1 (AC 43)
env_out=$(setup_committed_conflict "res9")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Remove the .conflict file
rm -f "$device_b_dir/snes/super_metroid.srm.conflict"

rc=0
ch_resolve "$device_b_dir" "snes/super_metroid.srm" "keep_remote" 2>/dev/null || rc=$?
assert_rc "ch_resolve missing .conflict returns 1" 1 "$rc"

# ============================
# Tests for ch_resolve_all
# ============================
printf '\n=== ch_resolve_all tests ===\n' >&2

# Test: two conflicts, keep_remote (AC 45, 46)
env_out=$(setup_conflict_env "ra1")
remote_dir=$(printf '%s' "$env_out" | cut -d' ' -f1)
device_a_dir=$(printf '%s' "$env_out" | cut -d' ' -f2)
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Seed gb in both clones
mkdir -p "$device_a_dir/gb"
printf 'gb-seed' > "$device_a_dir/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" add gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit -m "seed gb" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" pull origin main >/dev/null 2>&1

# Diverge on both
printf 'a-snes' > "$device_a_dir/snes/super_metroid.srm"
printf 'a-gb' > "$device_a_dir/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" add snes/super_metroid.srm gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" commit \
    -m "$(printf 'saves\n\ndevice: device-a')" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_a_dir" push origin main >/dev/null 2>&1

printf 'b-snes' > "$device_b_dir/snes/super_metroid.srm"
printf 'b-gb' > "$device_b_dir/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" add snes/super_metroid.srm gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$device_b_dir" commit \
    -m "$(printf 'saves\n\ndevice: device-b')" >/dev/null 2>&1

ch_handle_pull_conflict "$device_b_dir" >/dev/null 2>&1

# Verify two conflicts exist
conflicts=$(ch_list_conflicts "$device_b_dir")
conflict_count=$(printf '%s\n' "$conflicts" | grep -c '.')
assert_eq "ch_resolve_all setup: two conflicts" "2" "$conflict_count"

# Resolve all
rc=0
ch_resolve_all "$device_b_dir" "keep_remote" 2>/dev/null || rc=$?
assert_rc "ch_resolve_all keep_remote returns 0" 0 "$rc"

# Verify all resolved
remaining=$(ch_list_conflicts "$device_b_dir")
assert_eq "ch_resolve_all: no conflicts remain" "" "$remaining"

remaining_local=$(ch_list_local_files "$device_b_dir")
assert_eq "ch_resolve_all: no .local files remain" "" "$remaining_local"

# Test: ch_resolve_all returns 1 if any fail (AC 47)
env_out=$(setup_committed_conflict "ra2")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

# Stub ch_resolve to fail
_ch_resolve_real=$(command -v ch_resolve)
ch_resolve() { return 1; }

rc=0
ch_resolve_all "$device_b_dir" "keep_remote" 2>/dev/null || rc=$?
assert_rc "ch_resolve_all with failure returns 1" 1 "$rc"

# Restore
. "$PROJECT_ROOT/src/core/conflict_handler.sh"

# Test: no conflicts → returns 0 (AC 48)
env_out=$(setup_conflict_env "ra3")
device_b_dir=$(printf '%s' "$env_out" | cut -d' ' -f3)

rc=0
ch_resolve_all "$device_b_dir" "keep_remote" 2>/dev/null || rc=$?
assert_rc "ch_resolve_all no conflicts returns 0" 0 "$rc"

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
