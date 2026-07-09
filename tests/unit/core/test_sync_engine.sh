#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/core/sync_engine.sh
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

# Disable commit signing globally for this test process
GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

. "$TESTS_DIR/fixtures/pal_test.sh"
pal_init

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_engine.sh"

pal_validate

# Create a bare remote for tests
BARE_REMOTE="$TEST_TMPDIR/bare_remote.git"
"$CONTINUITY_GIT_BIN" init --bare "$BARE_REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$BARE_REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null

# --- Test se_clone ---
CLONE_DIR="$TEST_TMPDIR/clone1"
rc=0; se_clone "file://$BARE_REMOTE" "$CLONE_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "se_clone returns 0" 0 "$rc"
assert_file_exists "se_clone creates .git dir" "$CLONE_DIR/.git"

# --- Test se_init ---
"$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" checkout -b main 2>/dev/null || true
se_init "$CLONE_DIR" "test-device"

email=$("$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" config --local --get user.email)
assert_eq "se_init sets user.email" "continuity@device" "$email"

uname_val=$("$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" config --local --get user.name)
assert_eq "se_init sets user.name" "Continuity" "$uname_val"

assert_eq "se_init sets _SE_DEVICE_NAME" "test-device" "$_SE_DEVICE_NAME"

# Calling se_init again should not overwrite existing config
"$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" config user.email "custom@user"
se_init "$CLONE_DIR" "test-device"
email=$("$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" config --local --get user.email)
assert_eq "se_init preserves existing email" "custom@user" "$email"

# Reset for subsequent tests
"$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" config user.email "continuity@device"

# --- Test se_stage_files + se_has_staged_changes ---
mkdir -p "$CLONE_DIR/snes"
printf 'testdata' > "$CLONE_DIR/snes/super_metroid.srm"
se_stage_files "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1

rc=0; se_has_staged_changes "$CLONE_DIR" || rc=$?
assert_rc "se_has_staged_changes after stage" 0 "$rc"

# --- Test se_commit single file ---
se_commit "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1
log_msg=$("$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" log -1 --format=%B)
assert_contains "se_commit single file subject" "$log_msg" "snes/super_metroid.srm updated"
assert_contains "se_commit device trailer" "$log_msg" "device: test-device"
assert_contains "se_commit timestamp trailer" "$log_msg" "timestamp: "

# --- Test se_commit multiple files ---
mkdir -p "$CLONE_DIR/gba" "$CLONE_DIR/gb"
printf 'test2' > "$CLONE_DIR/gba/minish_cap.srm"
printf 'test3' > "$CLONE_DIR/gb/links_awakening.srm"
printf 'test4' > "$CLONE_DIR/snes/super_metroid.srm"

file_list="gba/minish_cap.srm
gb/links_awakening.srm
snes/super_metroid.srm"
se_stage_files "$CLONE_DIR" "$file_list" >/dev/null 2>&1
se_commit "$CLONE_DIR" "$file_list" >/dev/null 2>&1
log_msg=$("$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" log -1 --format=%B)
assert_contains "se_commit multi-file subject" "$log_msg" "3 saves updated"

# --- Test se_commit with subject override ---
printf 'test5' > "$CLONE_DIR/snes/super_metroid.srm"
se_stage_files "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1
se_commit "$CLONE_DIR" "snes/super_metroid.srm" "enroll: register my-brick" >/dev/null 2>&1
log_msg=$("$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" log -1 --format=%B)
assert_contains "se_commit custom subject" "$log_msg" "enroll: register my-brick"
assert_contains "se_commit custom subject still has trailer" "$log_msg" "device: test-device"

# --- Test se_push ---
rc=0; se_push "$CLONE_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "se_push returns 0" 0 "$rc"

# Verify commit appears in remote
remote_log=$("$CONTINUITY_GIT_BIN" -C "$BARE_REMOTE" log --oneline 2>/dev/null)
assert_contains "se_push commit visible in remote" "$remote_log" "enroll: register my-brick"

# --- Test se_has_unpushed_commits ---
rc=0; se_has_unpushed_commits "$CLONE_DIR" || rc=$?
assert_rc "se_has_unpushed_commits after push (up to date)" 1 "$rc"

# Create a new commit and check again
printf 'test6' > "$CLONE_DIR/snes/super_metroid.srm"
se_stage_files "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1
se_commit "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1
rc=0; se_has_unpushed_commits "$CLONE_DIR" || rc=$?
assert_rc "se_has_unpushed_commits after commit (ahead)" 0 "$rc"

# Push it
se_push "$CLONE_DIR" >/dev/null 2>&1
rc=0; se_has_unpushed_commits "$CLONE_DIR" || rc=$?
assert_rc "se_has_unpushed_commits after push again" 1 "$rc"

# --- Test se_get_head_commit ---
head_sha=$(se_get_head_commit "$CLONE_DIR")
sha_len=$(printf '%s' "$head_sha" | wc -c | tr -d ' ')
assert_eq "se_get_head_commit returns 40-char SHA" "40" "$sha_len"

# --- Test se_pull (fast-forward) ---
# Add a commit to bare remote via a second clone
CLONE2_DIR="$TEST_TMPDIR/clone2"
"$CONTINUITY_GIT_BIN" clone "file://$BARE_REMOTE" "$CLONE2_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" config user.email "other@device" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" config user.name "Other" >/dev/null 2>&1
mkdir -p "$CLONE2_DIR/nes"
printf 'zelda' > "$CLONE2_DIR/nes/zelda.srm"
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" add nes/zelda.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" commit -m "remote add zelda" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" push origin main >/dev/null 2>&1

rc=0; se_pull "$CLONE_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "se_pull fast-forward returns 0" 0 "$rc"
assert_file_exists "se_pull brings new file" "$CLONE_DIR/nes/zelda.srm"

# --- Test se_pull diverged ---
# Commit on both sides without syncing
printf 'local-change' > "$CLONE_DIR/snes/super_metroid.srm"
se_stage_files "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1
se_commit "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1

printf 'remote-change' > "$CLONE2_DIR/snes/super_metroid.srm"
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" add snes/super_metroid.srm >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" commit -m "remote diverge" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE2_DIR" push origin main >/dev/null 2>&1

rc=0; se_pull "$CLONE_DIR" 2>/dev/null || rc=$?
assert_rc "se_pull diverged returns 1" 1 "$rc"

# --- Test se_pull network error ---
CLONE3_DIR="$TEST_TMPDIR/clone3"
"$CONTINUITY_GIT_BIN" clone "file://$BARE_REMOTE" "$CLONE3_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE3_DIR" remote set-url origin "file:///nonexistent_repo_path" >/dev/null 2>&1
rc=0; se_pull "$CLONE3_DIR" 2>/dev/null || rc=$?
# file:// to nonexistent path — git treats this as a non-network error (returns 1)
# but our stderr check will categorize based on the error message
# On most systems this is "does not appear to be a git repository" which is non-network
# Accept either 1 or 2 here since the error message varies
if [ "$rc" -eq 1 ] || [ "$rc" -eq 2 ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: se_pull bad remote returns 1 or 2\n  actual rc: %s\n' "$rc" >&2
    failed=$((failed + 1))
fi

# --- Test se_push offline ---
pal_is_online() { return 1; }
rc=0; se_push "$CLONE_DIR" 2>/dev/null || rc=$?
assert_rc "se_push offline returns 2" 2 "$rc"
# Restore online
pal_is_online() { return 0; }

# --- Test se_push retry mock ---
# Create a wrapper that fails first 2 attempts with network error, succeeds on 3rd
# First, reset the diverged state by force-pushing
"$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" fetch origin main >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$CLONE_DIR" reset --hard origin/main >/dev/null 2>&1
printf 'retry-test' > "$CLONE_DIR/snes/super_metroid.srm"
se_stage_files "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1
se_commit "$CLONE_DIR" "snes/super_metroid.srm" >/dev/null 2>&1

REAL_GIT_BIN="$CONTINUITY_GIT_BIN"
RETRY_COUNT_FILE="$TEST_TMPDIR/retry_count"
printf '0' > "$RETRY_COUNT_FILE"

# Write a wrapper script
FAKE_GIT="$TEST_TMPDIR/fake_git.sh"
printf '#!/bin/sh\n' > "$FAKE_GIT"
printf 'count=$(cat "%s")\n' "$RETRY_COUNT_FILE" >> "$FAKE_GIT"
printf 'case "$*" in\n' >> "$FAKE_GIT"
printf '  *push*)\n' >> "$FAKE_GIT"
printf '    count=$((count + 1))\n' >> "$FAKE_GIT"
printf '    printf "%%s" "$count" > "%s"\n' "$RETRY_COUNT_FILE" >> "$FAKE_GIT"
printf '    if [ "$count" -le 2 ]; then\n' >> "$FAKE_GIT"
printf '      printf "unable to connect\\n" >&2\n' >> "$FAKE_GIT"
printf '      exit 1\n' >> "$FAKE_GIT"
printf '    fi\n' >> "$FAKE_GIT"
printf '    ;;\n' >> "$FAKE_GIT"
printf 'esac\n' >> "$FAKE_GIT"
printf '"%s" "$@"\n' "$REAL_GIT_BIN" >> "$FAKE_GIT"
chmod +x "$FAKE_GIT"

CONTINUITY_GIT_BIN="$FAKE_GIT"
rc=0; se_push "$CLONE_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "se_push retry succeeds on 3rd attempt" 0 "$rc"

retry_count=$(cat "$RETRY_COUNT_FILE")
assert_eq "se_push retried correct number of times" "3" "$retry_count"

CONTINUITY_GIT_BIN="$REAL_GIT_BIN"

# --- Summary ---
printf '\ntest_sync_engine: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
