#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: two-device conflict scenario end-to-end
# Uses real git operations with local bare remotes.
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
            printf 'FAIL: %s\n  text does not contain: %s\n' "$desc" "$pattern" >&2
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

CONTINUITY_DEVICE_NAME="device-b"

# ============================
# Setup: bare remote + two device clones
# ============================
REMOTE_DIR="$TEST_TMPDIR/remote.git"
DEVICE_A="$TEST_TMPDIR/device_a"
DEVICE_B="$TEST_TMPDIR/device_b"

"$CONTINUITY_GIT_BIN" init --bare "$REMOTE_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main 2>/dev/null

# Seed with initial commit
SEED_DIR="$TEST_TMPDIR/seed"
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$SEED_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" checkout -b main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.email "seed@test"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.name "Seed"
mkdir -p "$SEED_DIR/snes"
printf 'seed-save-data' > "$SEED_DIR/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" add . >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" commit -m "initial save" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" push origin main >/dev/null 2>&1

# Clone for device-a
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$DEVICE_A" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" checkout main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config user.email "continuity@device-a"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config user.name "Continuity"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config commit.gpgsign false

# Clone for device-b
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$DEVICE_B" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" checkout main >/dev/null 2>&1 || true
se_init "$DEVICE_B" "device-b" >/dev/null 2>&1

# Set up .continuity
mkdir -p "$DEVICE_B/.continuity"
head_hash=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
cs_store_commit "$DEVICE_B" "$head_hash"

# ============================
# Scenario 1: Two-device conflict — full flow
# ============================
printf '\n=== Scenario 1: Two-device conflict ===\n' >&2

# device-a: push new save
printf 'device-a-progress' > "$DEVICE_A/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'snes/super_metroid.srm updated\n\ndevice: device-a\ntimestamp: 2026-03-12T13:00:00Z')" \
    >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

# device-b: commit locally (diverged)
printf 'device-b-progress' > "$DEVICE_B/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'snes/super_metroid.srm updated\n\ndevice: device-b\ntimestamp: 2026-03-12T14:30:00Z')" \
    >/dev/null 2>&1

# Store current HEAD as last_known_commit
head_hash=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
cs_store_commit "$DEVICE_B" "$head_hash"

# Run conflict handler
rc=0
ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1 || rc=$?

# Assert returns 0
assert_rc "S1: ch_handle_pull_conflict returns 0" 0 "$rc"

# Assert canonical has remote bytes
srm_content=$(cat "$DEVICE_B/snes/super_metroid.srm")
assert_eq "S1: canonical has remote bytes" "device-a-progress" "$srm_content"

# Assert .local has local bytes
assert_file_exists "S1: .local exists" "$DEVICE_B/snes/super_metroid.srm.device-b.local"
local_content=$(cat "$DEVICE_B/snes/super_metroid.srm.device-b.local")
assert_eq "S1: .local has local bytes" "device-b-progress" "$local_content"

# Assert .conflict exists
assert_file_exists "S1: .conflict exists" "$DEVICE_B/snes/super_metroid.srm.conflict"

# Read .conflict JSON
conflict_json=$(cat "$DEVICE_B/snes/super_metroid.srm.conflict")
assert_contains "S1: remote_device is device-a" "$conflict_json" '"remote_device": "device-a"'
assert_contains "S1: local_device is device-b" "$conflict_json" '"local_device": "device-b"'
assert_contains "S1: status is unresolved" "$conflict_json" '"status": "unresolved"'

# Assert remote has the artifacts (push succeeded)
remote_local=$("$CONTINUITY_GIT_BIN" --git-dir="$REMOTE_DIR" show HEAD:snes/super_metroid.srm.device-b.local 2>/dev/null) || true
assert_eq "S1: remote has .local" "device-b-progress" "$remote_local"
remote_conflict=$("$CONTINUITY_GIT_BIN" --git-dir="$REMOTE_DIR" show HEAD:snes/super_metroid.srm.conflict 2>/dev/null) || true
assert_contains "S1: remote has .conflict" "$remote_conflict" '"remote_device": "device-a"'

# Assert last_known_commit equals HEAD
head_hash=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
stored=$(cs_read_commit "$DEVICE_B")
assert_eq "S1: last_known_commit equals HEAD" "$head_hash" "$stored"

# ============================
# Scenario 2: Resolve with keep_local
# ============================
printf '\n=== Scenario 2: Resolve with keep_local ===\n' >&2

rc=0
ch_resolve "$DEVICE_B" "snes/super_metroid.srm" "keep_local" 2>/dev/null || rc=$?
assert_rc "S2: ch_resolve keep_local returns 0" 0 "$rc"

# Assert canonical has device-b's bytes
srm_content=$(cat "$DEVICE_B/snes/super_metroid.srm")
assert_eq "S2: canonical has local bytes" "device-b-progress" "$srm_content"

# Assert artifacts gone
assert_file_not_exists "S2: .local removed" "$DEVICE_B/snes/super_metroid.srm.device-b.local"
assert_file_not_exists "S2: .conflict removed" "$DEVICE_B/snes/super_metroid.srm.conflict"

# Assert resolution commit
latest_msg=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" log -1 --format="%s")
assert_contains "S2: resolution commit message" "$latest_msg" "resolve: keep local"

# Assert remote updated (push happened)
remote_srm=$("$CONTINUITY_GIT_BIN" --git-dir="$REMOTE_DIR" show HEAD:snes/super_metroid.srm 2>/dev/null)
assert_eq "S2: remote has resolved canonical" "device-b-progress" "$remote_srm"

# ============================
# Scenario 3: Resolve with keep_newest
# ============================
printf '\n=== Scenario 3: Resolve with keep_newest ===\n' >&2

# Create a fresh conflict
# First, sync device-a with remote
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1

# Diverge again
printf 'a-fresh' > "$DEVICE_A/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'fresh a\n\ndevice: device-a')" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'b-fresh' > "$DEVICE_B/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'fresh b\n\ndevice: device-b')" >/dev/null 2>&1

ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

# Rewrite .conflict with remote_timestamp newer
printf '{\n  "_schema_version": "1.0",\n  "file": "snes/super_metroid.srm",\n  "remote_device": "device-a",\n  "remote_timestamp": "2026-03-12T16:00:00Z",\n  "local_device": "device-b",\n  "local_timestamp": "2026-03-12T14:00:00Z",\n  "status": "unresolved"\n}\n' \
    > "$DEVICE_B/snes/super_metroid.srm.conflict"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add "snes/super_metroid.srm.conflict" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit -m "update timestamps" >/dev/null 2>&1

rc=0
ch_resolve "$DEVICE_B" "snes/super_metroid.srm" "keep_newest" 2>/dev/null || rc=$?
assert_rc "S3: ch_resolve keep_newest returns 0" 0 "$rc"

# Remote is newer → keep_remote
srm_content=$(cat "$DEVICE_B/snes/super_metroid.srm")
assert_eq "S3: keep_newest resolves to remote" "a-fresh" "$srm_content"

assert_file_not_exists "S3: .local removed" "$DEVICE_B/snes/super_metroid.srm.device-b.local"
assert_file_not_exists "S3: .conflict removed" "$DEVICE_B/snes/super_metroid.srm.conflict"

# ============================
# Scenario 4: ch_resolve_all with multiple conflicts
# ============================
printf '\n=== Scenario 4: ch_resolve_all ===\n' >&2

# Sync device-a
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1

# Add gb save to both
mkdir -p "$DEVICE_A/gb"
printf 'gb-seed' > "$DEVICE_A/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit -m "seed gb" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" pull origin main >/dev/null 2>&1

# Diverge on both saves
printf 'a-snes-final' > "$DEVICE_A/snes/super_metroid.srm"
printf 'a-gb-final' > "$DEVICE_A/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'both saves\n\ndevice: device-a')" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'b-snes-final' > "$DEVICE_B/snes/super_metroid.srm"
printf 'b-gb-final' > "$DEVICE_B/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm gb/links_awakening.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'both saves\n\ndevice: device-b')" >/dev/null 2>&1

ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

# Verify two conflicts
conflicts=$(ch_list_conflicts "$DEVICE_B")
conflict_count=$(printf '%s\n' "$conflicts" | grep -c '.')
assert_eq "S4: two conflicts created" "2" "$conflict_count"

# Resolve all with keep_remote
rc=0
ch_resolve_all "$DEVICE_B" "keep_remote" 2>/dev/null || rc=$?
assert_rc "S4: ch_resolve_all returns 0" 0 "$rc"

remaining=$(ch_list_conflicts "$DEVICE_B")
assert_eq "S4: no conflicts remain" "" "$remaining"

remaining_local=$(ch_list_local_files "$DEVICE_B")
assert_eq "S4: no .local files remain" "" "$remaining_local"

# ============================
# Scenario 5: boot_pull.sh integration
# ============================
printf '\n=== Scenario 5: boot_pull.sh integration ===\n' >&2

# Sync device-a
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1

# Set up saves dir for bp_run
SAVES_DIR="$TEST_TMPDIR/s5_saves"
CONTINUITY_SAVES_ROOT="$SAVES_DIR"
mkdir -p "$SAVES_DIR/SFC"
cp "$DEVICE_B/snes/super_metroid.srm" "$SAVES_DIR/SFC/super_metroid.srm"

# Update stored commit
head_hash=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
cs_store_commit "$DEVICE_B" "$head_hash"
cs_create_sentinel "$DEVICE_B"

# Diverge
printf 'a-bp-test' > "$DEVICE_A/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
    -m "$(printf 'bp test\n\ndevice: device-a')" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1

printf 'b-bp-test' > "$DEVICE_B/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit \
    -m "$(printf 'bp test\n\ndevice: device-b')" >/dev/null 2>&1

# Override se_pull to return 1 (simulate diverged pull)
se_pull() { return 1; }

rc=0
bp_run "$DEVICE_B" >/dev/null 2>&1 || rc=$?
assert_rc "S5: bp_run with diverged pull returns 0" 0 "$rc"

# Assert conflict artifacts are present
assert_file_exists "S5: .local exists after bp_run" \
    "$DEVICE_B/snes/super_metroid.srm.device-b.local"
assert_file_exists "S5: .conflict exists after bp_run" \
    "$DEVICE_B/snes/super_metroid.srm.conflict"

# Canonical has remote bytes
srm_content=$(cat "$DEVICE_B/snes/super_metroid.srm")
assert_eq "S5: canonical has remote after bp_run" "a-bp-test" "$srm_content"

# local has device-b bytes
local_content=$(cat "$DEVICE_B/snes/super_metroid.srm.device-b.local")
assert_eq "S5: .local has device-b bytes after bp_run" "b-bp-test" "$local_content"

# Restore se_pull
. "$PROJECT_ROOT/src/core/sync_engine.sh"
se_init "$DEVICE_B" "device-b" >/dev/null 2>&1

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
