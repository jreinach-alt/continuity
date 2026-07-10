#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC1090
# Unit tests — Sprint 2.2 event-driven change detection in the RetroDeck
# daemon (src/platforms/retrodeck/continuity_daemon.sh, sourced NO_MAIN).
#
# Everything runs against a STUB inotifywait (argv recorded, exit code
# staged per invocation) so mode detection, the wait semantics, the
# adaptive timeout, and the 3-strike poll fallback are deterministic —
# no wall-clock assertions. The real tool is exercised by the
# integration flow when installed.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
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
        *) printf 'FAIL: %s\n  text lacks: %s\n  text: %s\n' "$desc" "$pattern" "$text" >&2; failed=$((failed + 1)) ;;
    esac
}

assert_not_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) printf 'FAIL: %s\n  text unexpectedly contains: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
        *) passed=$((passed + 1)) ;;
    esac
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# --- Stub inotifywait ------------------------------------------------
# Records argv (one arg per line, '---' terminator) to $STUB_LOG; exits
# with line N of $STUB_RC_SEQ for invocation N (last line repeats;
# default 2 = timeout).
STUB_DIR="$TEST_TMPDIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/inotifywait" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_LOG"; done
printf -- '---\n' >> "$STUB_LOG"
n=$(grep -c -- '^---$' "$STUB_LOG")
rc=2
if [ -n "${STUB_RC_SEQ:-}" ] && [ -f "$STUB_RC_SEQ" ]; then
    total=$(grep -c '.' "$STUB_RC_SEQ")
    [ "$n" -gt "$total" ] && n=$total
    rc=$(sed -n "${n}p" "$STUB_RC_SEQ")
fi
exit "$rc"
EOF
chmod +x "$STUB_DIR/inotifywait"

SAVES_DIR="$TEST_TMPDIR/saves"
STATES_DIR="$TEST_TMPDIR/states"
mkdir -p "$SAVES_DIR" "$STATES_DIR"

# load_daemon — source the daemon function surface with quiet stubs for
# everything the wait path touches. Call inside a per-case subshell.
load_daemon() {
    CONTINUITY_DAEMON_NO_MAIN=1
    CONTINUITY_APP_DIR="$PROJECT_ROOT"
    CONTINUITY_REPO_DIR="$TEST_TMPDIR/repo"
    CONTINUITY_SAVES_ROOT="$SAVES_DIR"
    . "$DAEMON"
    pal_log() { printf '%s: %s\n' "$1" "$2" >> "$CASE_LOG"; }
    # Idle + synced by default; cases override.
    cs_is_cold_start() { return 1; }
    se_has_unpushed_commits() { return 1; }
}

# --- 1. Mode detection: forced poll ---
CASE_LOG="$TEST_TMPDIR/log1"; : > "$CASE_LOG"
out=$(
    CONTINUITY_DETECT_MODE=poll
    load_daemon
    rdd_detect_watch_mode
    printf '%s' "$_RDD_WATCH_MODE"
)
assert_eq "forced poll: mode" "poll" "$out"
assert_contains "forced poll: named log" "$(cat "$CASE_LOG")" "forced"

# --- 2. Mode detection: auto without the binary ---
CASE_LOG="$TEST_TMPDIR/log2"; : > "$CASE_LOG"
out=$(
    CONTINUITY_DETECT_MODE=auto
    CONTINUITY_INOTIFY_BIN="$TEST_TMPDIR/no-such-inotifywait"
    load_daemon
    rdd_detect_watch_mode
    printf '%s' "$_RDD_WATCH_MODE"
)
assert_eq "auto, no binary: mode" "poll" "$out"
assert_contains "auto, no binary: named fallback" "$(cat "$CASE_LOG")" "inotifywait not found"

# --- 3. Mode detection: auto with the stub present ---
CASE_LOG="$TEST_TMPDIR/log3"; : > "$CASE_LOG"
out=$(
    CONTINUITY_DETECT_MODE=auto
    CONTINUITY_INOTIFY_BIN="$STUB_DIR/inotifywait"
    load_daemon
    rdd_detect_watch_mode
    printf '%s' "$_RDD_WATCH_MODE"
)
assert_eq "auto with binary: mode" "inotify" "$out"
assert_contains "auto with binary: named log" "$(cat "$CASE_LOG")" "event-driven"

# --- 4. Mode detection: unknown value degrades named ---
CASE_LOG="$TEST_TMPDIR/log4"; : > "$CASE_LOG"
out=$(
    CONTINUITY_DETECT_MODE=bogus
    load_daemon
    rdd_detect_watch_mode
    printf '%s' "$_RDD_WATCH_MODE"
)
assert_eq "unknown mode value: poll" "poll" "$out"
assert_contains "unknown mode value: named" "$(cat "$CASE_LOG")" "Unknown CONTINUITY_DETECT_MODE"

# --- 5. Adaptive timeout: pending work vs idle ---
CASE_LOG="$TEST_TMPDIR/log5"; : > "$CASE_LOG"
out=$(
    CONTINUITY_POLL_INTERVAL=7
    CONTINUITY_EVENT_IDLE_INTERVAL=99
    load_daemon
    cs_is_cold_start() { return 0; }          # deferred cold start
    t1=$(_rdd_wait_timeout)
    cs_is_cold_start() { return 1; }
    se_has_unpushed_commits() { return 0; }   # queued commits
    t2=$(_rdd_wait_timeout)
    se_has_unpushed_commits() { return 1; }   # idle + synced
    t3=$(_rdd_wait_timeout)
    printf '%s|%s|%s' "$t1" "$t2" "$t3"
)
assert_eq "timeout: cold-start 7 / unpushed 7 / idle 99" "7|7|99" "$out"

# --- 6. Event wake: argv recorded, settle honored, rc 0 handled ---
CASE_LOG="$TEST_TMPDIR/log6"; : > "$CASE_LOG"
STUB_LOG="$TEST_TMPDIR/stublog6"; : > "$STUB_LOG"
STUB_RC_SEQ="$TEST_TMPDIR/rcseq6"; printf '0\n' > "$STUB_RC_SEQ"
export STUB_LOG STUB_RC_SEQ
rc=0
(
    CONTINUITY_POLL_INTERVAL=7
    CONTINUITY_EVENT_IDLE_INTERVAL=99
    CONTINUITY_EVENT_SETTLE=0
    CONTINUITY_INOTIFY_BIN="$STUB_DIR/inotifywait"
    load_daemon
    _RDD_WATCH_MODE="inotify"
    rdd_wait_for_change
) || rc=$?
assert_eq "event wake: rc 0" "0" "$rc"
stub_args=$(cat "$STUB_LOG")
assert_contains "event wake: recursive watch" "$stub_args" "-r"
assert_contains "event wake: close_write watched" "$stub_args" "close_write"
assert_contains "event wake: moved_to watched" "$stub_args" "moved_to"
assert_contains "event wake: saves root watched" "$stub_args" "$SAVES_DIR"
assert_contains "event wake: idle timeout used" "$stub_args" "99"
assert_not_contains "event wake: no failure log" "$(cat "$CASE_LOG")" "strike"

# --- 7. States root rides along only when present ---
CASE_LOG="$TEST_TMPDIR/log7"; : > "$CASE_LOG"
STUB_LOG="$TEST_TMPDIR/stublog7"; : > "$STUB_LOG"
STUB_RC_SEQ="$TEST_TMPDIR/rcseq7"; printf '2\n' > "$STUB_RC_SEQ"
(
    CONTINUITY_EVENT_SETTLE=0
    CONTINUITY_INOTIFY_BIN="$STUB_DIR/inotifywait"
    load_daemon
    CONTINUITY_STATES_ROOT="$STATES_DIR"
    _RDD_WATCH_MODE="inotify"
    rdd_wait_for_change
)
assert_contains "states root watched when set" "$(cat "$STUB_LOG")" "$STATES_DIR"

STUB_LOG="$TEST_TMPDIR/stublog7b"; : > "$STUB_LOG"
(
    CONTINUITY_EVENT_SETTLE=0
    CONTINUITY_INOTIFY_BIN="$STUB_DIR/inotifywait"
    load_daemon
    CONTINUITY_STATES_ROOT="$TEST_TMPDIR/absent-states"
    _RDD_WATCH_MODE="inotify"
    rdd_wait_for_change
)
assert_not_contains "absent states root not watched" "$(cat "$STUB_LOG")" "absent-states"

# --- 8. Three strikes flip to poll, no further stub calls ---
CASE_LOG="$TEST_TMPDIR/log8"; : > "$CASE_LOG"
STUB_LOG="$TEST_TMPDIR/stublog8"; : > "$STUB_LOG"
STUB_RC_SEQ="$TEST_TMPDIR/rcseq8"; printf '1\n1\n1\n' > "$STUB_RC_SEQ"
out=$(
    CONTINUITY_POLL_INTERVAL=0
    CONTINUITY_EVENT_SETTLE=0
    CONTINUITY_INOTIFY_BIN="$STUB_DIR/inotifywait"
    load_daemon
    _RDD_WATCH_MODE="inotify"
    rdd_wait_for_change
    rdd_wait_for_change
    rdd_wait_for_change
    # Mode has flipped; this one must take the sleep path, not the stub.
    rdd_wait_for_change
    printf '%s' "$_RDD_WATCH_MODE"
)
assert_eq "3 strikes: mode flipped to poll" "poll" "$out"
assert_eq "3 strikes: stub invoked exactly 3 times" "3" "$(grep -c -- '^---$' "$STUB_LOG")"
case_log=$(cat "$CASE_LOG")
assert_contains "3 strikes: strike log" "$case_log" "strike 3/3"
assert_contains "3 strikes: named flip" "$case_log" "switching to"

# --- 9. rc 2 (timeout) resets the failure counter ---
CASE_LOG="$TEST_TMPDIR/log9"; : > "$CASE_LOG"
STUB_LOG="$TEST_TMPDIR/stublog9"; : > "$STUB_LOG"
STUB_RC_SEQ="$TEST_TMPDIR/rcseq9"; printf '1\n1\n2\n1\n1\n' > "$STUB_RC_SEQ"
out=$(
    CONTINUITY_POLL_INTERVAL=0
    CONTINUITY_EVENT_SETTLE=0
    CONTINUITY_INOTIFY_BIN="$STUB_DIR/inotifywait"
    load_daemon
    _RDD_WATCH_MODE="inotify"
    rdd_wait_for_change   # strike 1
    rdd_wait_for_change   # strike 2
    rdd_wait_for_change   # timeout — resets
    rdd_wait_for_change   # strike 1 again
    rdd_wait_for_change   # strike 2 again — still inotify
    printf '%s' "$_RDD_WATCH_MODE"
)
assert_eq "reset: still inotify after 2+2 strikes around a timeout" "inotify" "$out"
assert_not_contains "reset: never flipped" "$(cat "$CASE_LOG")" "switching to"

# --- 10. Poll mode never invokes the watcher ---
STUB_LOG="$TEST_TMPDIR/stublog10"; : > "$STUB_LOG"
CASE_LOG="$TEST_TMPDIR/log10"; : > "$CASE_LOG"
(
    CONTINUITY_POLL_INTERVAL=0
    CONTINUITY_INOTIFY_BIN="$STUB_DIR/inotifywait"
    load_daemon
    _RDD_WATCH_MODE="poll"
    rdd_wait_for_change
)
assert_eq "poll mode: watcher untouched" "0" "$(grep -c -- '^---$' "$STUB_LOG" || true)"

# --- 11. Shutdown kills the backgrounded waiter ---
# Asserted via a recording kill wrapper, NOT `kill -0` liveness: under
# the full suite the PID space churns fast enough that a reused PID
# makes a dead waiter look alive (observed flake). The end-to-end reap
# of a real process is covered by the events integration test's
# SIGTERM phase.
CASE_LOG="$TEST_TMPDIR/log11"; : > "$CASE_LOG"
KILL_LOG="$TEST_TMPDIR/kill11"; : > "$KILL_LOG"
WAITER_PID_FILE="$TEST_TMPDIR/waiter.pid"
(
    load_daemon
    pal_is_online() { return 0; }
    rp_run() { return 0; }
    sb_mark_clean_shutdown() { return 0; }
    kill() {
        printf '%s\n' "$*" >> "$KILL_LOG"
        command kill "$@" 2>/dev/null
    }
    sleep 30 &
    _RDD_WAIT_PID=$!
    printf '%s' "$_RDD_WAIT_PID" > "$WAITER_PID_FILE"
    rdd_shutdown
) || true
waiter_pid=$(cat "$WAITER_PID_FILE")
assert_contains "shutdown: waiter kill issued" "$(cat "$KILL_LOG")" "$waiter_pid"
assert_contains "shutdown: clean marker path reached" "$(cat "$CASE_LOG")" "clean shutdown marker written"

printf '\ntest_retrodeck_daemon_events: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
