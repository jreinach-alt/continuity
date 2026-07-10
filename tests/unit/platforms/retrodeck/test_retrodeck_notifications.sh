#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC1090
# Unit tests — Sprint 2.2 pal_on_sync_result in the RetroDeck PAL
# (notify-send mapping per the pal.md behavior contract, red debounce,
# log-only degrade). All against a stub notify-send that records argv
# and exits with a staged rc.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
PAL="$PROJECT_ROOT/src/platforms/retrodeck/pal_retrodeck.sh"

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

# Stub notify-send: one arg per line + '---' terminator into $STUB_LOG;
# exits $STUB_RC (default 0).
STUB="$TEST_TMPDIR/notify-send-stub"
cat > "$STUB" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_LOG"; done
printf -- '---\n' >> "$STUB_LOG"
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB"

RD_STATE="$TEST_TMPDIR/red_state"

# run_notify <level> <message> — invoke the hook in a fresh subshell
# under set -e (the daemon's world), with the stub + state file staged.
# Prints the hook's rc.
run_notify() {
    local rc
    rc=0
    (
        set -e
        CONTINUITY_NOTIFY_BIN="$STUB"
        CONTINUITY_NOTIFY_STATE="$RD_STATE"
        export CONTINUITY_NOTIFY_BIN CONTINUITY_NOTIFY_STATE STUB_LOG STUB_RC
        . "$PAL"
        pal_on_sync_result "$1" "$2"
    ) || rc=$?
    printf '%s' "$rc"
}

invocations() {
    # grep -c prints the 0 itself on no-match (rc 1) — only guard rc.
    [ -f "$STUB_LOG" ] || { printf '0'; return 0; }
    grep -c -- '^---$' "$STUB_LOG" || true
}

# --- 1. green: transient, worded, 3s expiry ---
STUB_LOG="$TEST_TMPDIR/log1"; : > "$STUB_LOG"; STUB_RC=0
rc=$(run_notify green "Pushed 2 save(s)")
assert_eq "green: rc 0" "0" "$rc"
log=$(cat "$STUB_LOG")
assert_contains "green: Synced word" "$log" "Continuity — Synced"
assert_contains "green: 3s expiry" "$log" "3000"
assert_contains "green: message verbatim" "$log" "Pushed 2 save(s)"
assert_not_contains "green: not critical" "$log" "critical"

# --- 2. yellow: transient, worded, 4s expiry ---
STUB_LOG="$TEST_TMPDIR/log2"; : > "$STUB_LOG"
rc=$(run_notify yellow "3 save(s) queued — offline")
assert_eq "yellow: rc 0" "0" "$rc"
log=$(cat "$STUB_LOG")
assert_contains "yellow: Queued word" "$log" "Continuity — Queued"
assert_contains "yellow: 4s expiry" "$log" "4000"
assert_not_contains "yellow: not critical" "$log" "critical"

# --- 3. red: critical, persistent (no expiry), resolver hint ---
STUB_LOG="$TEST_TMPDIR/log3"; : > "$STUB_LOG"; rm -f "$RD_STATE"
rc=$(run_notify red "Conflicts recorded — resolve on device")
assert_eq "red: rc 0" "0" "$rc"
log=$(cat "$STUB_LOG")
assert_contains "red: critical urgency" "$log" "critical"
assert_contains "red: needs-you summary" "$log" "Continuity — needs you"
assert_contains "red: message verbatim" "$log" "Conflicts recorded — resolve on device"
assert_contains "red: resolver hint" "$log" "Resolve save conflicts"
assert_not_contains "red: no expiry" "$log" "3000"
assert_eq "red: recorded as sent" "Conflicts recorded — resolve on device" "$(cat "$RD_STATE")"

# --- 4. red debounce: identical re-fire suppressed ---
rc=$(run_notify red "Conflicts recorded — resolve on device")
assert_eq "red repeat: rc 0" "0" "$rc"
assert_eq "red repeat: no second notification" "1" "$(invocations)"

# --- 5. red with a CHANGED message notifies again ---
rc=$(run_notify red "Sync error — check logs")
assert_eq "red changed: rc 0" "0" "$rc"
assert_eq "red changed: second notification sent" "2" "$(invocations)"
assert_eq "red changed: state updated" "Sync error — check logs" "$(cat "$RD_STATE")"

# --- 6. green clears red suppression ---
rc=$(run_notify green "Pushed 1 save(s)")
assert_eq "green after red: rc 0" "0" "$rc"
if [ -e "$RD_STATE" ]; then
    printf 'FAIL: green did not clear the red debounce state\n' >&2
    failed=$((failed + 1))
else
    passed=$((passed + 1))
fi
rc=$(run_notify red "Sync error — check logs")
assert_eq "red after green: re-sent" "4" "$(invocations)"

# --- 7. FAILED red send is never recorded (retry on next re-fire) ---
STUB_LOG="$TEST_TMPDIR/log7"; : > "$STUB_LOG"; rm -f "$RD_STATE"
STUB_RC=1
rc=$(run_notify red "Game Mode has no notifier")
assert_eq "failed red: rc still 0" "0" "$rc"
if [ -e "$RD_STATE" ]; then
    printf 'FAIL: failed send was recorded as sent\n' >&2
    failed=$((failed + 1))
else
    passed=$((passed + 1))
fi
STUB_RC=0
rc=$(run_notify red "Game Mode has no notifier")
assert_eq "retry after failed send: delivered" "2" "$(invocations)"
assert_eq "retry: now recorded" "Game Mode has no notifier" "$(cat "$RD_STATE")"

# --- 8. notify-send absent: log-only, rc 0, sync never harmed ---
LOG_CAP="$TEST_TMPDIR/log8"
rc=0
(
    set -e
    CONTINUITY_NOTIFY_BIN="$TEST_TMPDIR/no-such-notify-send"
    export CONTINUITY_NOTIFY_BIN
    . "$PAL"
    pal_on_sync_result red "Conflicts recorded" 2>"$LOG_CAP"
) || rc=$?
assert_eq "absent binary: rc 0" "0" "$rc"
assert_contains "absent binary: named log" "$(cat "$LOG_CAP")" "notify-send unavailable"

# --- 9. unknown level: warn, rc 0 ---
LOG_CAP="$TEST_TMPDIR/log9"
STUB_LOG="$TEST_TMPDIR/stublog9"; : > "$STUB_LOG"
rc=0
(
    set -e
    CONTINUITY_NOTIFY_BIN="$STUB"
    export CONTINUITY_NOTIFY_BIN STUB_LOG
    . "$PAL"
    pal_on_sync_result purple "what even" 2>"$LOG_CAP"
) || rc=$?
assert_eq "unknown level: rc 0" "0" "$rc"
assert_contains "unknown level: named warn" "$(cat "$LOG_CAP")" "unknown level"
assert_eq "unknown level: nothing sent" "0" "$(invocations)"

printf '\ntest_retrodeck_notifications: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
