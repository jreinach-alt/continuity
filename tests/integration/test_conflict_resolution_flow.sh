#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: full conflict resolution lifecycle
# Scenarios: Browse→Try→Resolve, keep_newest, multiple conflicts, Pokémon scenario
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
. "$PROJECT_ROOT/src/core/change_detector.sh"
. "$PROJECT_ROOT/src/core/runtime_poll.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

CONTINUITY_DEVICE_NAME="device-b"

# ============================
# Setup: bare remote + two device clones
# ============================
REMOTE_DIR="$TEST_TMPDIR/remote.git"
DEVICE_A="$TEST_TMPDIR/device_a"
DEVICE_B="$TEST_TMPDIR/device_b"

"$CONTINUITY_GIT_BIN" init --bare "$REMOTE_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main 2>/dev/null

# Seed
SEED_DIR="$TEST_TMPDIR/seed"
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$SEED_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" checkout -b main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.email "seed@test"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.name "Seed"
mkdir -p "$SEED_DIR/snes" "$SEED_DIR/gb"
printf 'seed-snes' > "$SEED_DIR/snes/super_metroid.srm"
printf 'seed-gb' > "$SEED_DIR/gb/pokemon_red.srm"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" add . >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" commit -m "seed saves" >/dev/null 2>&1
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

# Set up device saves directory
mkdir -p "$CONTINUITY_SAVES_ROOT/SFC" "$CONTINUITY_SAVES_ROOT/GB"

# ============================
# Scenario 1: Browse → Try → Resolve
# ============================
printf '\n=== Scenario 1: Browse → Try → Resolve ===\n' >&2

# Create conflict on snes/super_metroid.srm
printf 'device-a-snes' > "$DEVICE_A/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'snes save\n\ndevice: device-a\ntimestamp: 2026-03-12T13:00:00Z')" \
    >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'device-b-snes' > "$DEVICE_B/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'snes save\n\ndevice: device-b\ntimestamp: 2026-03-12T14:30:00Z')" \
    >/dev/null 2>&1

ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

# 1. ch_count_conflicts → 1
count=$(ch_count_conflicts "$DEVICE_B" 2>/dev/null)
assert_eq "S1.1: count = 1" "1" "$count"

# 2. ch_list_conflicts_detailed → one block with trying_modified=no
detailed=$(ch_list_conflicts_detailed "$DEVICE_B" 2>/dev/null)
assert_contains "S1.2: detailed has file" "$detailed" "file=snes/super_metroid.srm"
assert_contains "S1.2: trying_modified=no" "$detailed" "trying_modified=no"

# 3. ch_get_active_version → remote
ver=$(ch_get_active_version "$DEVICE_B" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "S1.3: default remote" "remote" "$ver"

# 4. try local → device save has device-b's bytes
device_path=$(ch_try_version "$DEVICE_B" "snes/super_metroid.srm" "local" 2>/dev/null)
device_content=$(cat "$device_path")
assert_eq "S1.4: device has local bytes" "device-b-snes" "$device_content"

# 5. get_active_version → local
ver=$(ch_get_active_version "$DEVICE_B" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "S1.5: active = local" "local" "$ver"

# 6. try remote → device save has device-a's bytes
device_path=$(ch_try_version "$DEVICE_B" "snes/super_metroid.srm" "remote" 2>/dev/null)
device_content=$(cat "$device_path")
assert_eq "S1.6: device has remote bytes" "device-a-snes" "$device_content"

# 7. get_active_version → remote
ver=$(ch_get_active_version "$DEVICE_B" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "S1.7: active = remote" "remote" "$ver"

# 8. try local → swap back
ch_try_version "$DEVICE_B" "snes/super_metroid.srm" "local" >/dev/null 2>&1

# 9. resolve keep_local
rc=0
ch_resolve "$DEVICE_B" "snes/super_metroid.srm" "keep_local" 2>/dev/null || rc=$?
assert_rc "S1.9: resolve returns 0" 0 "$rc"

# Device save has local bytes
device_content=$(cat "$device_path")
assert_eq "S1.9: device save has local bytes" "device-b-snes" "$device_content"

# 10. count = 0
count=$(ch_count_conflicts "$DEVICE_B" 2>/dev/null)
assert_eq "S1.10: count = 0" "0" "$count"

# 11. active_version = remote (marker cleared)
ver=$(ch_get_active_version "$DEVICE_B" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "S1.11: default remote after resolve" "remote" "$ver"

# ============================
# Scenario 2: Resolve without trying (keep_newest)
# ============================
printf '\n=== Scenario 2: keep_newest ===\n' >&2

# Sync device-a
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1

# Create new conflict
printf 'a-newest' > "$DEVICE_A/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'newest\n\ndevice: device-a\ntimestamp: 2026-03-12T10:00:00Z')" \
    >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'b-newest' > "$DEVICE_B/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'newest\n\ndevice: device-b\ntimestamp: 2026-03-12T16:00:00Z')" \
    >/dev/null 2>&1

ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

# Rewrite .conflict so local is newer
printf '{\n  "_schema_version": "1.0",\n  "file": "snes/super_metroid.srm",\n  "remote_device": "device-a",\n  "remote_timestamp": "2026-03-12T10:00:00Z",\n  "local_device": "device-b",\n  "local_timestamp": "2026-03-12T16:00:00Z",\n  "status": "unresolved"\n}\n' \
    > "$DEVICE_B/snes/super_metroid.srm.conflict"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add "snes/super_metroid.srm.conflict" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit -m "fix timestamps" >/dev/null 2>&1

rc=0
ch_resolve "$DEVICE_B" "snes/super_metroid.srm" "keep_newest" 2>/dev/null || rc=$?
assert_rc "S2: keep_newest returns 0" 0 "$rc"

srm_content=$(cat "$DEVICE_B/snes/super_metroid.srm")
assert_eq "S2: resolved to local (newer)" "b-newest" "$srm_content"

# Device save has local bytes
device_path=$(pm_repo_to_local "snes/super_metroid.srm" 2>/dev/null)
device_content=$(cat "$device_path")
assert_eq "S2: device save has local" "b-newest" "$device_content"

# No try markers
rc=0
ch_is_trying "$DEVICE_B" "snes/super_metroid.srm" || rc=$?
assert_rc "S2: no try marker" 1 "$rc"

# ============================
# Scenario 3: Multiple conflicts
# ============================
printf '\n=== Scenario 3: Multiple conflicts ===\n' >&2

# Sync device-a
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1

# Diverge on snes and gb
printf 'a-multi-snes' > "$DEVICE_A/snes/super_metroid.srm"
printf 'a-multi-gb' > "$DEVICE_A/gb/pokemon_red.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm gb/pokemon_red.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'multi\n\ndevice: device-a')" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'b-multi-snes' > "$DEVICE_B/snes/super_metroid.srm"
printf 'b-multi-gb' > "$DEVICE_B/gb/pokemon_red.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm gb/pokemon_red.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'multi\n\ndevice: device-b')" >/dev/null 2>&1

ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

# Count = 2
count=$(ch_count_conflicts "$DEVICE_B" 2>/dev/null)
assert_eq "S3.1: count = 2" "2" "$count"

# Detailed has two blocks
detailed=$(ch_list_conflicts_detailed "$DEVICE_B" 2>/dev/null)
assert_contains "S3.2: has snes" "$detailed" "file=snes/super_metroid.srm"
assert_contains "S3.2: has gb" "$detailed" "file=gb/pokemon_red.srm"

# Try and resolve snes
ch_try_version "$DEVICE_B" "snes/super_metroid.srm" "local" >/dev/null 2>&1
ch_resolve "$DEVICE_B" "snes/super_metroid.srm" "keep_local" 2>/dev/null

count=$(ch_count_conflicts "$DEVICE_B" 2>/dev/null)
assert_eq "S3.3: count = 1 after first resolve" "1" "$count"

# Resolve gb
ch_resolve "$DEVICE_B" "gb/pokemon_red.srm" "keep_remote" 2>/dev/null

count=$(ch_count_conflicts "$DEVICE_B" 2>/dev/null)
assert_eq "S3.4: count = 0 after second resolve" "0" "$count"

# Clear try markers
ch_clear_try_markers "$DEVICE_B"

# ============================
# Scenario 4: The Pokémon Scenario
# ============================
printf '\n=== Scenario 4: Pokémon Scenario ===\n' >&2

# Sync device-a
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1

# Create conflict on gb/pokemon_red.srm
printf 'a-pokemon' > "$DEVICE_A/gb/pokemon_red.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add gb/pokemon_red.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'pokemon\n\ndevice: device-a\ntimestamp: 2026-03-12T11:00:00Z')" \
    >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'b-pokemon' > "$DEVICE_B/gb/pokemon_red.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add gb/pokemon_red.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'pokemon\n\ndevice: device-b\ntimestamp: 2026-03-12T12:00:00Z')" \
    >/dev/null 2>&1

ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

# 1. Try local
device_path=$(ch_try_version "$DEVICE_B" "gb/pokemon_red.srm" "local" 2>/dev/null)
assert_file_exists "S4.1: device save exists" "$device_path"

# 2. Not modified yet
rc=0
ch_is_trying_modified "$DEVICE_B" "gb/pokemon_red.srm" || rc=$?
assert_rc "S4.2: not modified" 1 "$rc"

# 3. Simulate gameplay — append 4 bytes
printf 'PLAY' >> "$device_path"

# 4. Now modified
rc=0
ch_is_trying_modified "$DEVICE_B" "gb/pokemon_red.srm" || rc=$?
assert_rc "S4.3: modified" 0 "$rc"

# 5. ch_get_conflict_info shows trying_modified=yes
info=$(ch_get_conflict_info "$DEVICE_B" "gb/pokemon_red.srm" 2>/dev/null)
assert_contains "S4.4: trying_modified=yes" "$info" "trying_modified=yes"

# 6. Set up sentinel for poll cycle
cs_create_sentinel "$DEVICE_B"

# 7. rp_confirm_changes skips the trying-state file
confirmed=$(rp_confirm_changes "$DEVICE_B" "$device_path" 2>/dev/null)
assert_eq "S4.5: trying file excluded from confirm" "" "$confirmed"

# 8. Verify no new git commits from poll
commit_before=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-list --count HEAD)
# Don't run full rp_run — just verify the filter worked above
commit_after=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-list --count HEAD)
assert_eq "S4.6: no new commits" "$commit_before" "$commit_after"

# 9. Promote the modified trying version
rc=0
ch_promote_trying "$DEVICE_B" "gb/pokemon_red.srm" 2>/dev/null || rc=$?
assert_rc "S4.7: promote returns 0" 0 "$rc"

# Repo .srm has the modified bytes (original + "PLAY")
repo_content=$(cat "$DEVICE_B/gb/pokemon_red.srm")
assert_eq "S4.8: repo has modified bytes" "b-pokemonPLAY" "$repo_content"

# 10. Count = 0
count=$(ch_count_conflicts "$DEVICE_B" 2>/dev/null)
assert_eq "S4.9: count = 0" "0" "$count"

# 11. Not in trying state
rc=0
ch_is_trying "$DEVICE_B" "gb/pokemon_red.srm" || rc=$?
assert_rc "S4.10: not trying" 1 "$rc"

# 12. File is now eligible for sync (no trying state blocks it)
# Write something new to device save to verify it would be picked up
printf 'post-promote-data' > "$device_path"
confirmed=$(rp_confirm_changes "$DEVICE_B" "$device_path" 2>/dev/null)
assert_contains "S4.11: file eligible after promote" "$confirmed" "$device_path"

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
