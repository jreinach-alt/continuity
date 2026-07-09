#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: full daemon lifecycle as a real process.
# Boots the actual continuity_daemon.sh against an enrolled test repo:
# normal-boot dispatch → poll loop picks up a save change and pushes it →
# duplicate instance refused → SIGTERM → clean shutdown marker + PID gone.
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

assert_log_contains() {
    local desc needle
    desc="$1"; needle="$2"
    if grep -qF -e "$needle" "$DAEMON_LOG" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  daemon log does not contain: %s\n' "$desc" "$needle" >&2
        failed=$((failed + 1))
    fi
}

# wait_for <timeout_halfseconds> <command...> — poll until command succeeds
wait_for() {
    local tries
    tries="$1"; shift
    while [ "$tries" -gt 0 ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
        tries=$((tries - 1))
    done
    return 1
}

# --- Setup ---
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
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/stale_boot.sh"

# Platform map at the location the test PAL reports
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"

# Enrolled environment: bare remote + enrolled clone + seeded saves
. "$TESTS_DIR/fixtures/enroll_test.sh"
et_setup "$TEST_TMPDIR" >/dev/null 2>&1

# Post-cold-start state: sentinel + stored commit + clean shutdown marker,
# device saves mirroring the repo → next daemon start is a NORMAL boot.
cs_create_sentinel "$ET_REPO_DIR"
head_hash=$("$CONTINUITY_GIT_BIN" -C "$ET_REPO_DIR" rev-parse HEAD)
cs_store_commit "$ET_REPO_DIR" "$head_hash"
sb_mark_clean_shutdown "$ET_REPO_DIR"

mkdir -p "$CONTINUITY_SAVES_ROOT/SFC" "$CONTINUITY_SAVES_ROOT/GBA" "$CONTINUITY_SAVES_ROOT/GB"
cp "$ET_REPO_DIR/snes/super_metroid.srm" "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"
cp "$ET_REPO_DIR/gba/minish_cap.srm" "$CONTINUITY_SAVES_ROOT/GBA/minish_cap.srm"
cp "$ET_REPO_DIR/gb/links_awakening.srm" "$CONTINUITY_SAVES_ROOT/GB/links_awakening.srm"

# State size cap must be in the daemon's environment from launch
export CONTINUITY_STATE_MAX_KB=2

# Fake PAK: real daemon + real core modules, test PAL standing in for the
# NextUI PAL (same interface, temp-dir paths, always online).
FAKE_PAK="$TEST_TMPDIR/pak"
mkdir -p "$FAKE_PAK/scripts/core" "$FAKE_PAK/bin"
cp "$TESTS_DIR/fixtures/pal_test.sh" "$FAKE_PAK/scripts/pal_nextui.sh"
cp "$PROJECT_ROOT/src/platforms/nextui/enroll_sd_card.sh" "$FAKE_PAK/scripts/"
cp "$PROJECT_ROOT"/src/core/*.sh "$FAKE_PAK/scripts/core/"

# Vendored interpreter: the host's busybox stands in for the aarch64 one.
# The daemon must self-test it, re-exec under it (same PID — the SIGTERM
# and wait assertions below depend on that), and log the pinned line.
# (Under busybox ash, `command -v busybox` returns the bare applet name,
# not a path — resolve to a real file explicitly.)
HOST_BB=$(command -v busybox)
case "$HOST_BB" in
    /*) ;;
    *)  for p in /usr/bin/busybox /bin/busybox /usr/local/bin/busybox; do
            if [ -x "$p" ]; then HOST_BB="$p"; break; fi
        done ;;
esac
cp "$HOST_BB" "$FAKE_PAK/bin/busybox"
chmod +x "$FAKE_PAK/bin/busybox"

# --- Start the daemon as a real background process ---

DAEMON_PID_FILE="$TEST_TMPDIR/daemon.pid"
DAEMON_LOG="$TEST_TMPDIR/daemon.log"

CONTINUITY_PID_FILE="$DAEMON_PID_FILE" \
CONTINUITY_LOG_FILE="$DAEMON_LOG" \
CONTINUITY_POLL_INTERVAL=1 \
CONTINUITY_PAK_DIR="$FAKE_PAK" \
    busybox ash "$PROJECT_ROOT/src/platforms/nextui/continuity_daemon.sh" >/dev/null &
DPID=$!

# --- Scenario 1: normal boot + poll cycle pushes the changed save ---

# Wait for boot dispatch to finish: bp_run re-baselines the sentinel at
# boot (by design — Sprint 0.5), so a change is only "runtime" if it
# lands after the poll loop starts. That mirrors the device: the user
# saves while playing, after boot.
poll_loop_started() { grep -qF "Entering poll loop" "$DAEMON_LOG" 2>/dev/null; }
if wait_for 20 poll_loop_started; then
    assert_eq "S1: daemon reached the poll loop" "ok" "ok"
else
    assert_eq "S1: daemon reached the poll loop" "ok" "timeout"
fi

sleep 1
printf 'daemon_lifecycle_bytes' > "$CONTINUITY_SAVES_ROOT/SFC/super_metroid.srm"

# Save states: one normal (synced as opaque blob), one oversized (skipped)
mkdir -p "$CONTINUITY_STATES_ROOT/SFC-snes9x"
printf 'state_zero_bytes' > "$CONTINUITY_STATES_ROOT/SFC-snes9x/Super Metroid (USA).st0"
dd if=/dev/zero of="$CONTINUITY_STATES_ROOT/SFC-snes9x/huge.st9" bs=1024 count=3 2>/dev/null

remote_updated() {
    [ "$("$CONTINUITY_GIT_BIN" -C "$ET_REMOTE_DIR" show HEAD:snes/super_metroid.srm 2>/dev/null)" = "daemon_lifecycle_bytes" ]
}
if wait_for 20 remote_updated; then
    assert_eq "S1: changed save pushed to remote by poll loop" "ok" "ok"
else
    assert_eq "S1: changed save pushed to remote by poll loop" "ok" "timeout"
fi

state_synced() {
    [ "$("$CONTINUITY_GIT_BIN" -C "$ET_REMOTE_DIR" show "HEAD:states/SFC-snes9x/Super Metroid (USA).st0" 2>/dev/null)" = "state_zero_bytes" ]
}
if wait_for 20 state_synced; then
    assert_eq "S1: save state backed up to remote (opaque blob)" "ok" "ok"
else
    assert_eq "S1: save state backed up to remote (opaque blob)" "ok" "timeout"
fi
if "$CONTINUITY_GIT_BIN" -C "$ET_REMOTE_DIR" show "HEAD:states/SFC-snes9x/huge.st9" >/dev/null 2>&1; then
    assert_eq "S1: oversized state skipped" "skipped" "synced"
else
    assert_eq "S1: oversized state skipped" "skipped" "skipped"
fi

assert_log_contains "S1: normal boot dispatched" "Boot: normal"
assert_log_contains "S1: poll loop entered" "Entering poll loop"
assert_log_contains "S1: daemon re-execed under vendored interpreter" \
    "Interpreter: vendored busybox (pinned)"
assert_file_exists "S1: PID file present while running" "$DAEMON_PID_FILE"
assert_file_not_exists "S1: clean marker consumed at boot" \
    "$ET_REPO_DIR/.continuity/clean_shutdown"

# --- Scenario 2: duplicate instance refuses to start ---

rc=0
CONTINUITY_PID_FILE="$DAEMON_PID_FILE" \
CONTINUITY_LOG_FILE="$DAEMON_LOG" \
CONTINUITY_PAK_DIR="$FAKE_PAK" \
    busybox ash "$PROJECT_ROOT/src/platforms/nextui/continuity_daemon.sh" >/dev/null || rc=$?
assert_eq "S2: duplicate instance exits 0" "0" "$rc"
assert_log_contains "S2: duplicate instance logged" "Another instance running"
assert_file_exists "S2: original PID file untouched" "$DAEMON_PID_FILE"

# --- Scenario 3: SIGTERM → graceful shutdown ---

kill -TERM "$DPID"
rc=0
wait "$DPID" || rc=$?
assert_eq "S3: daemon exits 0 on SIGTERM" "0" "$rc"
assert_log_contains "S3: shutdown logged" "Shutdown: complete"
assert_file_not_exists "S3: PID file removed" "$DAEMON_PID_FILE"
assert_file_exists "S3: clean shutdown marker written" \
    "$ET_REPO_DIR/.continuity/clean_shutdown"

# No commits left unpushed
rc=0
se_has_unpushed_commits "$ET_REPO_DIR" 2>/dev/null || rc=$?
assert_eq "S3: no unpushed commits after shutdown" "1" "$rc"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
