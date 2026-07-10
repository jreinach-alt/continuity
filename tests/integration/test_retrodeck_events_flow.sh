#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC1090,SC1091
# Integration test — Sprint 2.2: the RetroDeck daemon as a real process
# with EVENT-DRIVEN change detection.
#
#   Phase 1 — a staged inotify event (stub watcher) wakes the daemon and
#             the changed save reaches the remote — no timer involved
#             (all intervals are set far above the assertion bound)
#   Phase 2 — SIGTERM while blocked in the event wait: prompt exit,
#             waiter reaped, clean-shutdown marker written
#   Phase 3 — a watcher that always fails: three named strikes, permanent
#             poll fallback, and the save still syncs
#   Phase 4 — the REAL inotifywait (when installed): an actual filesystem
#             event drives the sync while the housekeeping timer is far
#             away; self-skips named when the tool is absent
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DAEMON="$PROJECT_ROOT/src/platforms/retrodeck/continuity_daemon.sh"

passed=0
failed=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text lacks: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
    esac
}

assert_file_exists() {
    local desc="$1" filepath="$2"
    if [ -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

# --- Sandbox (same rdhome shape as test_retrodeck_flow.sh) -----------

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"; [ -n "${daemon_pid:-}" ] && kill "$daemon_pid" 2>/dev/null || true' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

RDHOME="$TEST_TMPDIR/rd home"
RD_CONF_DIR="$TEST_TMPDIR/rdconf"
mkdir -p "$RDHOME/saves/gba" "$RDHOME/states" "$RDHOME/roms/gba" "$RD_CONF_DIR"
cat > "$RD_CONF_DIR/retrodeck.json" <<EOF
{
 "version": "0.10.9b",
 "paths": {
  "rd_home_path": "$RDHOME",
  "roms_path": "$RDHOME/roms",
  "saves_path": "$RDHOME/saves",
  "states_path": "$RDHOME/states"
 }
}
EOF

REMOTE="$TEST_TMPDIR/remote.git"
git init --bare "$REMOTE" >/dev/null 2>&1
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
SEED="$TEST_TMPDIR/seed"
git clone "$REMOTE" "$SEED" >/dev/null 2>&1
git -C "$SEED" checkout -b main >/dev/null 2>&1 || true
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
printf 'continuity saves repo\n' > "$SEED/README.md"
git -C "$SEED" add README.md >/dev/null 2>&1
git -C "$SEED" commit -m seed >/dev/null 2>&1
git -C "$SEED" push -q origin main

SANDBOX_HOME="$TEST_TMPDIR/home"
mkdir -p "$SANDBOX_HOME"
CONTINUITY_RD_CONF="$RD_CONF_DIR/retrodeck.json"
CONTINUITY_REPO_DIR="$SANDBOX_HOME/.local/share/continuity/repo"
export CONTINUITY_RD_CONF CONTINUITY_REPO_DIR

SAVE_DEV="$RDHOME/saves/gba/Zelda Minish Cap (USA).srm"
SAVE_REPO="gba/Zelda Minish Cap (USA).srm"
printf 'zelda-v1' > "$SAVE_DEV"
: > "$RDHOME/roms/gba/Zelda Minish Cap (USA).gba"

PAT_FILE="$TEST_TMPDIR/pat"
printf 'file-remote-needs-no-pat' > "$PAT_FILE"
rc=0
HOME="$SANDBOX_HOME" sh "$PROJECT_ROOT/src/platforms/retrodeck/enroll_retrodeck.sh" \
    --repo-url "file://$REMOTE" --device-name deck-events \
    --pat-file "$PAT_FILE" --no-service >/dev/null 2>&1 || rc=$?
assert_eq "enrollment ok" "0" "$rc"

# Gated stub watcher: blocks until $STUB_FIRE appears (consumes it, exits
# 0 = event) or ~60s pass (exits 2 = timeout). $STUB_FORCE_RC overrides
# unconditionally (Phase 3's always-failing watcher).
STUB="$TEST_TMPDIR/inotifywait_stub"
cat > "$STUB" <<'EOF'
#!/bin/sh
if [ -n "${STUB_FORCE_RC:-}" ]; then exit "$STUB_FORCE_RC"; fi
n=0
while [ ! -f "$STUB_FIRE" ]; do
    sleep 1
    n=$((n + 1))
    [ "$n" -gt 60 ] && exit 2
done
rm -f "$STUB_FIRE"
exit 0
EOF
chmod +x "$STUB"

STUB_FIRE="$TEST_TMPDIR/fire"
export STUB_FIRE

# start_daemon <log> <extra env as VAR=val args...>
start_daemon() {
    local log="$1"
    shift
    env HOME="$SANDBOX_HOME" \
        CONTINUITY_RD_CONF="$CONTINUITY_RD_CONF" \
        CONTINUITY_REPO_DIR="$CONTINUITY_REPO_DIR" \
        CONTINUITY_APP_DIR="$PROJECT_ROOT" \
        CONTINUITY_FORCE_ONLINE=1 \
        "$@" \
        sh "$DAEMON" >/dev/null 2>"$log" &
    daemon_pid=$!
}

# wait_for_line <log> <pattern> <seconds> — bounded wait for a log line.
wait_for_line() {
    local log="$1" pattern="$2" bound="$3" i=0
    while [ "$i" -lt "$bound" ]; do
        grep -q "$pattern" "$log" 2>/dev/null && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# remote_bytes — the save's bytes at the remote tip ('' when absent).
remote_bytes() {
    git -C "$REMOTE" show "main:$SAVE_REPO" 2>/dev/null || printf ''
}

# wait_for_remote <bytes> <seconds>
wait_for_remote() {
    local want="$1" bound="$2" i=0
    while [ "$i" -lt "$bound" ]; do
        [ "$(remote_bytes)" = "$want" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# =====================================================================
# Phase 1 — staged event wakes the daemon; no timer can explain it
# =====================================================================
printf '=== Phase 1: event wake ===\n' >&2

log1="$TEST_TMPDIR/daemon1.log"
start_daemon "$log1" \
    CONTINUITY_DETECT_MODE=inotify \
    CONTINUITY_INOTIFY_BIN="$STUB" \
    STUB_FIRE="$STUB_FIRE" \
    CONTINUITY_POLL_INTERVAL=120 \
    CONTINUITY_EVENT_IDLE_INTERVAL=120 \
    CONTINUITY_EVENT_SETTLE=0

rc=0; wait_for_line "$log1" "Entering event loop" 30 || rc=$?
assert_eq "P1: daemon entered event loop" "0" "$rc"
assert_contains "P1: mode named at startup" "$(cat "$log1")" "event-driven"

# Boot dispatch (cold start) pushed v1.
rc=0; wait_for_remote "zelda-v1" 30 || rc=$?
assert_eq "P1: cold start pushed v1" "0" "$rc"

# New bytes + staged event → synced long before any 120s timer.
printf 'zelda-v2-event' > "$SAVE_DEV"
touch "$STUB_FIRE"
rc=0; wait_for_remote "zelda-v2-event" 20 || rc=$?
assert_eq "P1: event-driven sync reached the remote" "0" "$rc"

# =====================================================================
# Phase 2 — SIGTERM while blocked in the event wait
# =====================================================================
printf '=== Phase 2: SIGTERM during wait ===\n' >&2

kill -TERM "$daemon_pid" 2>/dev/null
i=0
while [ "$i" -lt 10 ] && kill -0 "$daemon_pid" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
done
rc=0; kill -0 "$daemon_pid" 2>/dev/null && rc=1
assert_eq "P2: daemon exited promptly on SIGTERM" "0" "$rc"
daemon_pid=""
assert_file_exists "P2: clean shutdown marker written" \
    "$CONTINUITY_REPO_DIR/.continuity/clean_shutdown"
assert_contains "P2: shutdown named in log" "$(cat "$log1")" "Shutdown: complete"

# =====================================================================
# Phase 3 — always-failing watcher: 3 named strikes, poll still syncs
# =====================================================================
printf '=== Phase 3: degradation to poll ===\n' >&2

log3="$TEST_TMPDIR/daemon3.log"
start_daemon "$log3" \
    CONTINUITY_DETECT_MODE=inotify \
    CONTINUITY_INOTIFY_BIN="$STUB" \
    STUB_FORCE_RC=1 \
    CONTINUITY_POLL_INTERVAL=1 \
    CONTINUITY_EVENT_IDLE_INTERVAL=120 \
    CONTINUITY_EVENT_SETTLE=0

rc=0; wait_for_line "$log3" "switching to" 30 || rc=$?
assert_eq "P3: named flip to polling" "0" "$rc"

printf 'zelda-v3-pollback' > "$SAVE_DEV"
rc=0; wait_for_remote "zelda-v3-pollback" 30 || rc=$?
assert_eq "P3: poll fallback still syncs" "0" "$rc"
assert_contains "P3: strikes named" "$(cat "$log3")" "strike 3/3"

kill -TERM "$daemon_pid" 2>/dev/null
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=""

# =====================================================================
# Phase 4 — the real inotifywait, when installed
# =====================================================================
if command -v inotifywait >/dev/null 2>&1; then
    printf '=== Phase 4: real inotifywait ===\n' >&2

    log4="$TEST_TMPDIR/daemon4.log"
    start_daemon "$log4" \
        CONTINUITY_DETECT_MODE=auto \
        CONTINUITY_POLL_INTERVAL=120 \
        CONTINUITY_EVENT_IDLE_INTERVAL=120 \
        CONTINUITY_EVENT_SETTLE=1

    rc=0; wait_for_line "$log4" "Entering event loop" 30 || rc=$?
    assert_eq "P4: auto picked inotify" "0" "$rc"

    # Two writes a second apart: even if the first lands in the blind
    # window while the first cycle runs, the second is a fresh event.
    sleep 2
    printf 'zelda-v4-real' > "$SAVE_DEV"
    sleep 1
    printf 'zelda-v5-real' > "$SAVE_DEV"
    rc=0; wait_for_remote "zelda-v5-real" 25 || rc=$?
    assert_eq "P4: real filesystem event drove the sync" "0" "$rc"

    kill -TERM "$daemon_pid" 2>/dev/null
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=""
else
    printf 'SKIP: Phase 4 (inotifywait not installed — stub phases cover the contract)\n' >&2
fi

printf '\ntest_retrodeck_events_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
