#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/core/cold_start.sh
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
. "$PROJECT_ROOT/src/core/change_detector.sh"
. "$PROJECT_ROOT/src/core/cold_start.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# ============================
# Helper: create a bare remote + enrolled clone for cs_run tests
# ============================
setup_test_env() {
    local test_id remote_dir seed_dir repo_dir
    test_id="$1"
    remote_dir="$TEST_TMPDIR/${test_id}_remote.git"
    seed_dir="$TEST_TMPDIR/${test_id}_seed"
    repo_dir="$TEST_TMPDIR/${test_id}_repo"

    "$CONTINUITY_GIT_BIN" init --bare "$remote_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$remote_dir" symbolic-ref HEAD refs/heads/main 2>/dev/null

    "$CONTINUITY_GIT_BIN" clone "file://$remote_dir" "$seed_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" checkout -b main 2>/dev/null || true
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.email "seed@test"
    "$CONTINUITY_GIT_BIN" -C "$seed_dir" config user.name "Seed"

    printf '%s %s' "$remote_dir" "$seed_dir"
}

# ============================
# Test cs_is_cold_start
# ============================
HELPER_REPO="$TEST_TMPDIR/helper_repo"
mkdir -p "$HELPER_REPO/.continuity"

rc=0; cs_is_cold_start "$HELPER_REPO" || rc=$?
assert_rc "cs_is_cold_start no sentinel returns 0" 0 "$rc"

printf 'timestamp' > "$HELPER_REPO/.continuity/sentinel"
rc=0; cs_is_cold_start "$HELPER_REPO" || rc=$?
assert_rc "cs_is_cold_start with sentinel returns 1" 1 "$rc"

# ============================
# Test cs_store_commit / cs_read_commit round-trip
# ============================
COMMIT_REPO="$TEST_TMPDIR/commit_repo"
mkdir -p "$COMMIT_REPO"

cs_store_commit "$COMMIT_REPO" "abc123def456abc123def456abc123def456abc1"
stored=$(cs_read_commit "$COMMIT_REPO")
rc=$?
assert_rc "cs_read_commit returns 0" 0 "$rc"
assert_eq "cs_read_commit round-trip" "abc123def456abc123def456abc123def456abc1" "$stored"

# Test cs_read_commit with missing file
MISSING_REPO="$TEST_TMPDIR/missing_repo"
mkdir -p "$MISSING_REPO"
rc=0; cs_read_commit "$MISSING_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_read_commit missing file returns 1" 1 "$rc"

# Test cs_read_commit with empty file
EMPTY_REPO="$TEST_TMPDIR/empty_commit_repo"
mkdir -p "$EMPTY_REPO/.continuity"
printf '' > "$EMPTY_REPO/.continuity/last_known_commit"
rc=0; cs_read_commit "$EMPTY_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_read_commit empty file returns 1" 1 "$rc"

# Test cs_store_commit creates .continuity/ when absent
NO_DIR_REPO="$TEST_TMPDIR/nodir_repo"
mkdir -p "$NO_DIR_REPO"
cs_store_commit "$NO_DIR_REPO" "test_hash"
assert_file_exists "cs_store_commit creates .continuity dir" "$NO_DIR_REPO/.continuity/last_known_commit"

# ============================
# Test cs_create_sentinel
# ============================
SENT_REPO="$TEST_TMPDIR/sent_repo"
mkdir -p "$SENT_REPO"
cs_create_sentinel "$SENT_REPO"
assert_file_exists "cs_create_sentinel creates file" "$SENT_REPO/.continuity/sentinel"
sent_content=$(cat "$SENT_REPO/.continuity/sentinel")
if [ -n "$sent_content" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: cs_create_sentinel content is empty\n' >&2
    failed=$((failed + 1))
fi

# cs_create_sentinel creates dir when absent
SENT_REPO2="$TEST_TMPDIR/sent_repo2"
mkdir -p "$SENT_REPO2"
cs_create_sentinel "$SENT_REPO2"
assert_file_exists "cs_create_sentinel creates .continuity dir" "$SENT_REPO2/.continuity/sentinel"

# ============================
# Test cs_run: Empty repo + device saves (AC 20)
# ============================
R1_REMOTE="$TEST_TMPDIR/r1_remote.git"
R1_SEED="$TEST_TMPDIR/r1_seed"
R1_REPO="$TEST_TMPDIR/r1_repo"
R1_SAVES="$TEST_TMPDIR/r1_saves"

"$CONTINUITY_GIT_BIN" init --bare "$R1_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R1_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null
"$CONTINUITY_GIT_BIN" clone "file://$R1_REMOTE" "$R1_SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R1_SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$R1_SEED" config user.email "s@t"
"$CONTINUITY_GIT_BIN" -C "$R1_SEED" config user.name "S"
printf 'init' > "$R1_SEED/.gitkeep"
"$CONTINUITY_GIT_BIN" -C "$R1_SEED" add .gitkeep >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R1_SEED" commit -m "init" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R1_SEED" push origin main >/dev/null 2>&1
rm -rf "$R1_SEED"

"$CONTINUITY_GIT_BIN" clone "file://$R1_REMOTE" "$R1_REPO" >/dev/null 2>&1
se_init "$R1_REPO" "test-device"

# Create .continuity/.gitignore (normally done by enrollment)
mkdir -p "$R1_REPO/.continuity"
printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$R1_REPO/.continuity/.gitignore"
"$CONTINUITY_GIT_BIN" -C "$R1_REPO" add .continuity/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R1_REPO" commit -m "gitignore" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R1_REPO" push origin main >/dev/null 2>&1

# Device saves
mkdir -p "$R1_SAVES/SFC" "$R1_SAVES/GBA"
printf 'device_metroid' > "$R1_SAVES/SFC/super_metroid.srm"
printf 'device_minish' > "$R1_SAVES/GBA/minish_cap.srm"

CONTINUITY_SAVES_ROOT="$R1_SAVES"
CONTINUITY_REPO_DIR="$R1_REPO"

rc=0; cs_run "$R1_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_run empty repo + device saves returns 0" 0 "$rc"
assert_file_exists "cs_run pushes device save to repo" "$R1_REPO/snes/super_metroid.srm"
assert_file_exists "cs_run pushes second device save" "$R1_REPO/gba/minish_cap.srm"
assert_file_exists "cs_run creates sentinel" "$R1_REPO/.continuity/sentinel"
assert_file_exists "cs_run creates last_known_commit" "$R1_REPO/.continuity/last_known_commit"
assert_file_not_exists "cs_run no .local files" "$R1_REPO/snes/super_metroid.srm.test-device.local"

# ============================
# Test cs_run: Saves in repo, empty device (AC 21)
# ============================
R2_REMOTE="$TEST_TMPDIR/r2_remote.git"
R2_SEED="$TEST_TMPDIR/r2_seed"
R2_REPO="$TEST_TMPDIR/r2_repo"
R2_SAVES="$TEST_TMPDIR/r2_saves"

"$CONTINUITY_GIT_BIN" init --bare "$R2_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R2_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null
"$CONTINUITY_GIT_BIN" clone "file://$R2_REMOTE" "$R2_SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R2_SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$R2_SEED" config user.email "s@t"
"$CONTINUITY_GIT_BIN" -C "$R2_SEED" config user.name "S"
mkdir -p "$R2_SEED/snes" "$R2_SEED/gb"
printf 'repo_metroid' > "$R2_SEED/snes/super_metroid.srm"
printf 'repo_links' > "$R2_SEED/gb/links_awakening.srm"
"$CONTINUITY_GIT_BIN" -C "$R2_SEED" add -A >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R2_SEED" commit -m "seed saves" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R2_SEED" push origin main >/dev/null 2>&1
rm -rf "$R2_SEED"

"$CONTINUITY_GIT_BIN" clone "file://$R2_REMOTE" "$R2_REPO" >/dev/null 2>&1
se_init "$R2_REPO" "test-device"
mkdir -p "$R2_REPO/.continuity"
printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$R2_REPO/.continuity/.gitignore"
"$CONTINUITY_GIT_BIN" -C "$R2_REPO" add .continuity/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R2_REPO" commit -m "gitignore" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R2_REPO" push origin main >/dev/null 2>&1

# Empty device
mkdir -p "$R2_SAVES"
CONTINUITY_SAVES_ROOT="$R2_SAVES"
CONTINUITY_REPO_DIR="$R2_REPO"

rc=0; cs_run "$R2_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_run repo saves + empty device returns 0" 0 "$rc"
assert_file_exists "cs_run pulls snes save to device" "$R2_SAVES/SFC/super_metroid.srm"
assert_file_exists "cs_run pulls gb save to device" "$R2_SAVES/GB/links_awakening.srm"
assert_file_exists "cs_run creates sentinel" "$R2_REPO/.continuity/sentinel"

# ============================
# Test cs_run: Identical saves (AC 22)
# ============================
R3_REMOTE="$TEST_TMPDIR/r3_remote.git"
R3_SEED="$TEST_TMPDIR/r3_seed"
R3_REPO="$TEST_TMPDIR/r3_repo"
R3_SAVES="$TEST_TMPDIR/r3_saves"

"$CONTINUITY_GIT_BIN" init --bare "$R3_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R3_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null
"$CONTINUITY_GIT_BIN" clone "file://$R3_REMOTE" "$R3_SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R3_SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$R3_SEED" config user.email "s@t"
"$CONTINUITY_GIT_BIN" -C "$R3_SEED" config user.name "S"
mkdir -p "$R3_SEED/snes"
printf 'identical' > "$R3_SEED/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$R3_SEED" add -A >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R3_SEED" commit -m "seed" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R3_SEED" push origin main >/dev/null 2>&1
rm -rf "$R3_SEED"

"$CONTINUITY_GIT_BIN" clone "file://$R3_REMOTE" "$R3_REPO" >/dev/null 2>&1
se_init "$R3_REPO" "test-device"
mkdir -p "$R3_REPO/.continuity"
printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$R3_REPO/.continuity/.gitignore"
"$CONTINUITY_GIT_BIN" -C "$R3_REPO" add .continuity/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R3_REPO" commit -m "gitignore" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R3_REPO" push origin main >/dev/null 2>&1

# Device has identical save
mkdir -p "$R3_SAVES/SFC"
printf 'identical' > "$R3_SAVES/SFC/super_metroid.srm"
CONTINUITY_SAVES_ROOT="$R3_SAVES"
CONTINUITY_REPO_DIR="$R3_REPO"

commit_before=$("$CONTINUITY_GIT_BIN" -C "$R3_REPO" log --oneline | wc -l | tr -d ' ')
rc=0; cs_run "$R3_REPO" >/dev/null 2>&1 || rc=$?
commit_after=$("$CONTINUITY_GIT_BIN" -C "$R3_REPO" log --oneline | wc -l | tr -d ' ')
assert_rc "cs_run identical saves returns 0" 0 "$rc"
assert_eq "cs_run identical saves no new commit" "$commit_before" "$commit_after"
assert_file_exists "cs_run identical creates sentinel" "$R3_REPO/.continuity/sentinel"

# ============================
# Test cs_run: Conflicting saves (AC 23)
# ============================
R4_REMOTE="$TEST_TMPDIR/r4_remote.git"
R4_SEED="$TEST_TMPDIR/r4_seed"
R4_REPO="$TEST_TMPDIR/r4_repo"
R4_SAVES="$TEST_TMPDIR/r4_saves"

"$CONTINUITY_GIT_BIN" init --bare "$R4_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R4_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null
"$CONTINUITY_GIT_BIN" clone "file://$R4_REMOTE" "$R4_SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R4_SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$R4_SEED" config user.email "s@t"
"$CONTINUITY_GIT_BIN" -C "$R4_SEED" config user.name "S"
mkdir -p "$R4_SEED/snes"
printf 'repo_version' > "$R4_SEED/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$R4_SEED" add -A >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R4_SEED" commit -m "seed" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R4_SEED" push origin main >/dev/null 2>&1
rm -rf "$R4_SEED"

"$CONTINUITY_GIT_BIN" clone "file://$R4_REMOTE" "$R4_REPO" >/dev/null 2>&1
se_init "$R4_REPO" "test-device"
mkdir -p "$R4_REPO/.continuity"
printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$R4_REPO/.continuity/.gitignore"
"$CONTINUITY_GIT_BIN" -C "$R4_REPO" add .continuity/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R4_REPO" commit -m "gitignore" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R4_REPO" push origin main >/dev/null 2>&1

# Device has different bytes
mkdir -p "$R4_SAVES/SFC"
printf 'device_version' > "$R4_SAVES/SFC/super_metroid.srm"
CONTINUITY_SAVES_ROOT="$R4_SAVES"
CONTINUITY_REPO_DIR="$R4_REPO"

rc=0; cs_run "$R4_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_run conflict returns 0" 0 "$rc"

# Repo wins on device
device_content=$(cat "$R4_SAVES/SFC/super_metroid.srm")
assert_eq "cs_run conflict: repo wins on device" "repo_version" "$device_content"

# .local file preserved in repo
assert_file_exists "cs_run conflict: .local exists" "$R4_REPO/snes/super_metroid.srm.test-device.local"
local_content=$(cat "$R4_REPO/snes/super_metroid.srm.test-device.local")
assert_eq "cs_run conflict: .local has device version" "device_version" "$local_content"

# .conflict metadata exists
assert_file_exists "cs_run conflict: .conflict exists" "$R4_REPO/snes/super_metroid.srm.conflict"
conflict_json=$(cat "$R4_REPO/snes/super_metroid.srm.conflict")
assert_contains "cs_run conflict: .conflict has _schema_version" "$conflict_json" '"_schema_version": "2.0"'
assert_contains "cs_run conflict: .conflict has file" "$conflict_json" '"file": "snes/super_metroid.srm"'
assert_contains "cs_run conflict: .conflict has identity" "$conflict_json" '"identity": "snes/super_metroid"'
assert_contains "cs_run conflict: .conflict has class" "$conflict_json" '"class": "srm"'
assert_contains "cs_run conflict: .conflict has device" "$conflict_json" '"local_device": "test-device"'
assert_contains "cs_run conflict: .conflict has source" "$conflict_json" '"source": "cold_start"'

# .local in git log (committed)
log=$("$CONTINUITY_GIT_BIN" -C "$R4_REPO" log --name-only --oneline 2>/dev/null)
assert_contains "cs_run conflict: .local committed" "$log" "snes/super_metroid.srm.test-device.local"

assert_file_exists "cs_run conflict: sentinel" "$R4_REPO/.continuity/sentinel"

# ============================
# Test cs_run: Device-only save (AC 24)
# ============================
# Already tested in R1 (empty repo + device saves)

# ============================
# Test cs_run: Offline (AC 26)
# ============================
R5_REMOTE="$TEST_TMPDIR/r5_remote.git"
R5_SEED="$TEST_TMPDIR/r5_seed"
R5_REPO="$TEST_TMPDIR/r5_repo"
R5_SAVES="$TEST_TMPDIR/r5_saves"

"$CONTINUITY_GIT_BIN" init --bare "$R5_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R5_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null
"$CONTINUITY_GIT_BIN" clone "file://$R5_REMOTE" "$R5_SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R5_SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$R5_SEED" config user.email "s@t"
"$CONTINUITY_GIT_BIN" -C "$R5_SEED" config user.name "S"
printf 'init' > "$R5_SEED/.gitkeep"
"$CONTINUITY_GIT_BIN" -C "$R5_SEED" add .gitkeep >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R5_SEED" commit -m "init" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R5_SEED" push origin main >/dev/null 2>&1
rm -rf "$R5_SEED"

"$CONTINUITY_GIT_BIN" clone "file://$R5_REMOTE" "$R5_REPO" >/dev/null 2>&1
se_init "$R5_REPO" "test-device"
mkdir -p "$R5_REPO/.continuity"
printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$R5_REPO/.continuity/.gitignore"
"$CONTINUITY_GIT_BIN" -C "$R5_REPO" add .continuity/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R5_REPO" commit -m "gitignore" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R5_REPO" push origin main >/dev/null 2>&1

mkdir -p "$R5_SAVES/SFC"
printf 'offline_save' > "$R5_SAVES/SFC/super_metroid.srm"
CONTINUITY_SAVES_ROOT="$R5_SAVES"
CONTINUITY_REPO_DIR="$R5_REPO"

# Override pal_is_online to simulate offline
pal_is_online() { return 1; }

rc=0; cs_run "$R5_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_run offline returns 0" 0 "$rc"
assert_file_not_exists "cs_run offline: no sentinel" "$R5_REPO/.continuity/sentinel"
assert_file_not_exists "cs_run offline: no last_known_commit" "$R5_REPO/.continuity/last_known_commit"
# But file should still be in repo
assert_file_exists "cs_run offline: save copied to repo" "$R5_REPO/snes/super_metroid.srm"

# Restore pal_is_online
pal_is_online() { return 0; }

# ============================
# Test cs_run: pal_on_conflict hook (AC 29)
# ============================
R6_REMOTE="$TEST_TMPDIR/r6_remote.git"
R6_SEED="$TEST_TMPDIR/r6_seed"
R6_REPO="$TEST_TMPDIR/r6_repo"
R6_SAVES="$TEST_TMPDIR/r6_saves"
CONFLICT_LOG="$TEST_TMPDIR/conflict_log"

"$CONTINUITY_GIT_BIN" init --bare "$R6_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R6_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null
"$CONTINUITY_GIT_BIN" clone "file://$R6_REMOTE" "$R6_SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R6_SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$R6_SEED" config user.email "s@t"
"$CONTINUITY_GIT_BIN" -C "$R6_SEED" config user.name "S"
mkdir -p "$R6_SEED/snes"
printf 'repo_v' > "$R6_SEED/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$R6_SEED" add -A >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R6_SEED" commit -m "seed" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R6_SEED" push origin main >/dev/null 2>&1
rm -rf "$R6_SEED"

"$CONTINUITY_GIT_BIN" clone "file://$R6_REMOTE" "$R6_REPO" >/dev/null 2>&1
se_init "$R6_REPO" "test-device"
mkdir -p "$R6_REPO/.continuity"
printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$R6_REPO/.continuity/.gitignore"
"$CONTINUITY_GIT_BIN" -C "$R6_REPO" add .continuity/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R6_REPO" commit -m "gitignore" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$R6_REPO" push origin main >/dev/null 2>&1

mkdir -p "$R6_SAVES/SFC"
printf 'device_v' > "$R6_SAVES/SFC/super_metroid.srm"
CONTINUITY_SAVES_ROOT="$R6_SAVES"
CONTINUITY_REPO_DIR="$R6_REPO"

# Define hook
printf '' > "$CONFLICT_LOG"
pal_on_conflict() { printf '%s\n' "$1" >> "$CONFLICT_LOG"; }

rc=0; cs_run "$R6_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_run with hook returns 0" 0 "$rc"

hook_output=$(cat "$CONFLICT_LOG")
assert_contains "pal_on_conflict called with repo path" "$hook_output" "snes/super_metroid.srm"

# Clean up hook
unset -f pal_on_conflict

# --- Summary ---
printf '\ntest_cold_start: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
