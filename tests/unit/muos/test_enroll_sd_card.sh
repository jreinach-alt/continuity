#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/platforms/muos/enroll_sd_card.sh
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
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
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

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Fast enrollment-lock timing for every esd_import call in this file
ESD_LOCK_WAIT_TICKS=2
ESD_LOCK_STALE_SECONDS=600

# Disable commit signing globally for this test process
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

. "$TESTS_DIR/fixtures/pal_test.sh"
pal_init

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/enrollment.sh"
. "$PROJECT_ROOT/src/platforms/muos/enroll_sd_card.sh"

pal_validate

# Create SD card root
mkdir -p "$CONTINUITY_SD_ROOT"

# --- Test esd_detect_setup_file absent ---
rc=0; esd_detect_setup_file || rc=$?
assert_rc "esd_detect_setup_file absent" 1 "$rc"

# --- Test esd_detect_setup_file present ---
printf '{}' > "$CONTINUITY_SD_ROOT/setup.json"
rc=0; esd_detect_setup_file || rc=$?
assert_rc "esd_detect_setup_file present" 0 "$rc"
rm -f "$CONTINUITY_SD_ROOT/setup.json"

# --- Test esd_parse_setup_file valid ---
cat > "$CONTINUITY_SD_ROOT/setup.json" <<'TESTJSON'
{
  "repo_url": "https://github.com/alice/saves.git",
  "pat": "github_pat_abc123",
  "device_name": "my-brick"
}
TESTJSON

rc=0; esd_parse_setup_file "$CONTINUITY_SD_ROOT/setup.json" 2>/dev/null || rc=$?
assert_rc "esd_parse_setup_file valid returns 0" 0 "$rc"
assert_eq "parsed repo_url" "https://github.com/alice/saves.git" "$_ESD_REPO_URL"
assert_eq "parsed pat" "github_pat_abc123" "$_ESD_PAT"
assert_eq "parsed device_name" "my-brick" "$_ESD_DEVICE_NAME"

# --- Test esd_parse_setup_file missing device_name ---
cat > "$CONTINUITY_SD_ROOT/setup.json" <<'TESTJSON'
{
  "repo_url": "https://github.com/alice/saves.git",
  "pat": "github_pat_abc123"
}
TESTJSON

rc=0; esd_parse_setup_file "$CONTINUITY_SD_ROOT/setup.json" 2>/dev/null || rc=$?
assert_rc "esd_parse_setup_file missing device_name returns 1" 1 "$rc"

# --- Test esd_parse_setup_file empty pat ---
cat > "$CONTINUITY_SD_ROOT/setup.json" <<'TESTJSON'
{
  "repo_url": "https://github.com/alice/saves.git",
  "pat": "",
  "device_name": "my-brick"
}
TESTJSON

rc=0; esd_parse_setup_file "$CONTINUITY_SD_ROOT/setup.json" 2>/dev/null || rc=$?
assert_rc "esd_parse_setup_file empty pat returns 1" 1 "$rc"

# --- Test esd_import no setup file ---
rm -f "$CONTINUITY_SD_ROOT/setup.json"
rc=0; esd_import 2>/dev/null || rc=$?
assert_rc "esd_import no setup file returns 0" 0 "$rc"

# --- Test esd_import valid setup + successful enrollment ---
# Create a bare remote for this test
BARE_REMOTE="$TEST_TMPDIR/sd_bare.git"
"$CONTINUITY_GIT_BIN" init --bare "$BARE_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$BARE_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null
SEED="$TEST_TMPDIR/sd_seed"
"$CONTINUITY_GIT_BIN" clone "file://$BARE_REMOTE" "$SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$SEED" config user.email "s@t" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED" config user.name "S" >/dev/null 2>&1
printf 'x' > "$SEED/.gitkeep"
"$CONTINUITY_GIT_BIN" -C "$SEED" add .gitkeep >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED" commit -m "init" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED" push origin main >/dev/null 2>&1
rm -rf "$SEED"

cat > "$CONTINUITY_SD_ROOT/setup.json" <<TESTJSON
{
  "repo_url": "file://$BARE_REMOTE",
  "pat": "test-pat-123",
  "device_name": "test-device"
}
TESTJSON

rc=0; esd_import >/dev/null 2>&1 || rc=$?
assert_rc "esd_import valid returns 0" 0 "$rc"
assert_file_not_exists "esd_import deletes setup.json on success" "$CONTINUITY_SD_ROOT/setup.json"
assert_file_exists "esd_import enrolls device" "$CONTINUITY_REPO_DIR/.continuity/device_name"

# --- Test esd_import parse failure ---
# Use a different repo dir to avoid destroying enrolled state
ORIG_REPO_DIR="$CONTINUITY_REPO_DIR"
CONTINUITY_REPO_DIR="$TEST_TMPDIR/repo2"
mkdir -p "$(dirname "$CONTINUITY_REPO_DIR")"

cat > "$CONTINUITY_SD_ROOT/setup.json" <<'TESTJSON'
{
  "repo_url": "https://example.com/repo.git"
}
TESTJSON

rc=0; esd_import >/dev/null 2>&1 || rc=$?
assert_rc "esd_import parse failure returns 1" 1 "$rc"
assert_file_exists "esd_import keeps setup.json on parse failure" "$CONTINUITY_SD_ROOT/setup.json"

# --- Test esd_import already enrolled ---
# Restore to the enrolled state
CONTINUITY_REPO_DIR="$ORIG_REPO_DIR"

cat > "$CONTINUITY_SD_ROOT/setup.json" <<TESTJSON
{
  "repo_url": "file://$BARE_REMOTE",
  "pat": "test-pat-123",
  "device_name": "test-device"
}
TESTJSON

rc=0; esd_import >/dev/null 2>&1 || rc=$?
assert_rc "esd_import already enrolled returns 0" 0 "$rc"
assert_file_not_exists "esd_import deletes setup.json when already enrolled" "$CONTINUITY_SD_ROOT/setup.json"

# --- Enrollment lock: mutual exclusion between entry points ---

LOCK_DIR="$CONTINUITY_SD_ROOT/.continuity/.enroll_lock"

# Held fresh lock → esd_import gives up after the wait window (rc 1)
mkdir -p "$LOCK_DIR"
date +%s > "$LOCK_DIR/started_at"
cat > "$CONTINUITY_SD_ROOT/setup.json" <<TESTJSON2
{
  "repo_url": "file://$BARE_REMOTE",
  "pat": "test-pat-123",
  "device_name": "test-device"
}
TESTJSON2
rc=0; esd_import >/dev/null 2>&1 || rc=$?
assert_rc "esd_import blocked by fresh lock returns 1" 1 "$rc"
assert_file_exists "setup.json untouched while locked" "$CONTINUITY_SD_ROOT/setup.json"

# Stale lock (ancient started_at) → stolen, import proceeds
printf '1000000\n' > "$LOCK_DIR/started_at"
rc=0; esd_import >/dev/null 2>&1 || rc=$?
assert_rc "stale lock stolen, import proceeds" 0 "$rc"
assert_file_not_exists "lock released after import" "$LOCK_DIR"
rm -f "$CONTINUITY_SD_ROOT/setup.json"

# --- Summary ---
printf '\ntest_enroll_sd_card: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
