#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/nextui/enroll_ui.sh (enrollment supervisor)
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

assert_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s does not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

assert_not_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if ! grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s should not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# js_event writer: 8 bytes = u32 time, s16 value, u8 type, u8 number.
# Args: <file> <value> <type> <number>  (time fixed at 0, little-endian)
write_js_event() {
    local file value type number vlo vhi
    file="$1"; value="$2"; type="$3"; number="$4"
    vlo=$((value % 256))
    vhi=$((value / 256))
    # shellcheck disable=SC2059
    printf "$(printf '\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o' \
        0 0 0 0 "$vlo" "$vhi" "$type" "$number")" >> "$file"
}

pal_log() { printf '%s: %s\n' "$1" "$2" >> "$TEST_TMPDIR/pal_log.txt"; }
CONTINUITY_GIT_BIN=""   # disable killall path in eui_kill_enrollment

# Fast test timings; FIFO is a regular file capturing TEXT: writes
EUI_TICK="0.1"
EUI_TIMEOUT_TICKS=200
EUI_REPLAY_DELAY="0.05"
EUI_FIFO="$TEST_TMPDIR/fifo_capture.txt"
EUI_JS_DEV="$TEST_TMPDIR/js0"
: > "$EUI_FIFO"
: > "$EUI_JS_DEV"

. "$PROJECT_ROOT/src/platforms/nextui/enroll_ui.sh"

# ═══ Test 1: js_event decoding — presses kept, noise dropped ═══

BTN_FILE="$TEST_TMPDIR/buttons.txt"
write_js_event "$EUI_JS_DEV" 1 129 0      # init-flag button event → ignore
write_js_event "$EUI_JS_DEV" 1 1 0        # B press → keep
write_js_event "$EUI_JS_DEV" 0 1 0        # B release → ignore
write_js_event "$EUI_JS_DEV" 12000 2 1    # axis motion → ignore
write_js_event "$EUI_JS_DEV" 1 1 3        # X press → keep
write_js_event "$EUI_JS_DEV" 1 1 9        # L3 press (unmapped) → keep as number

eui_btn_listener_start "$BTN_FILE"
tries=20
while [ "$(wc -l < "$BTN_FILE")" -lt 3 ] && [ "$tries" -gt 0 ]; do
    sleep 0.1; tries=$((tries - 1))
done
eui_btn_listener_stop

assert_eq "decoder kept exactly the 3 presses" "3" "$(wc -l < "$BTN_FILE")"
assert_eq "press sequence decoded in order" "0 3 9" "$(tr '\n' ' ' < "$BTN_FILE" | tr -s ' ' | sed 's/ $//')"

btn=$(eui_next_button); assert_eq "next_button returns B first" "0" "$btn"
btn=$(eui_next_button); assert_eq "next_button returns X second" "3" "$btn"
btn=$(eui_next_button); assert_eq "next_button returns unmapped 9 third" "9" "$btn"
rc=0; eui_next_button >/dev/null || rc=$?
assert_eq "next_button exhausts to rc=1" "1" "$rc"

# ═══ Test 2: happy path — success rc, live log mirrored to screen ═══

esd_import() {
    pal_log() { printf '[2026-07-06 12:00:00] %s: %s\n' "$1" "$2"; }
    pal_log "info" "Cloning saves repository"
    sleep 0.3
    pal_log "info" "Device registered"
    return 0
}
: > "$EUI_JS_DEV"
: > "$EUI_FIFO"
LOG2="$TEST_TMPDIR/enroll2.log"
rc=0; eui_run_enrollment "$LOG2" || rc=$?
assert_eq "successful enrollment returns 0" "0" "$rc"
assert_contains "log has clone line" "$LOG2" "Cloning saves repository"
assert_contains "log records final rc" "$LOG2" "=== enrollment finished rc=0 ==="
assert_contains "screen showed live log line" "$EUI_FIFO" "TEXT:info: Cloning saves repository"
assert_not_contains "timestamp stripped for display" "$EUI_FIFO" "TEXT:[2026-07-06"

# ═══ Test 3: B button cancels a stuck enrollment ═══

esd_import() { sleep 60; return 0; }
: > "$EUI_JS_DEV"
write_js_event "$EUI_JS_DEV" 1 1 0   # B press queued before start
: > "$EUI_FIFO"
LOG3="$TEST_TMPDIR/enroll3.log"
start_s=$(date +%s)
rc=0; eui_run_enrollment "$LOG3" || rc=$?
elapsed=$(( $(date +%s) - start_s ))
assert_eq "cancelled enrollment returns 2" "2" "$rc"
assert_contains "cancel recorded in log" "$LOG3" "cancelled via B button"
if [ "$elapsed" -lt 10 ]; then
    assert_eq "cancel is prompt (not blocked on child)" "fast" "fast"
else
    assert_eq "cancel is prompt (not blocked on child)" "fast" "took ${elapsed}s"
fi

# ═══ Test 4: watchdog timeout kills a hung enrollment ═══

esd_import() { sleep 60; return 0; }
: > "$EUI_JS_DEV"
: > "$EUI_FIFO"
LOG4="$TEST_TMPDIR/enroll4.log"
rc=0; EUI_TIMEOUT_TICKS=3 eui_run_enrollment "$LOG4" || rc=$?
assert_eq "timed-out enrollment returns 3" "3" "$rc"
assert_contains "watchdog recorded in log" "$LOG4" "watchdog: enrollment timed out"

# ═══ Test 5: X button replays the log on screen ═══

esd_import() { sleep 1.5; return 0; }
: > "$EUI_JS_DEV"
write_js_event "$EUI_JS_DEV" 1 1 3   # X press
: > "$EUI_FIFO"
LOG5="$TEST_TMPDIR/enroll5.log"
printf 'earlier line one\nearlier line two\n' > "$LOG5"
rc=0; eui_run_enrollment "$LOG5" || rc=$?
assert_eq "enrollment still succeeds after replay" "0" "$rc"
assert_contains "replay walked old log lines" "$EUI_FIFO" "TEXT:earlier line one"
assert_contains "replay shows end marker" "$EUI_FIFO" "TEXT:— end of log —"

# ═══ Test 6: failure rc normalized to 1, unmapped button logged ═══

esd_import() { sleep 0.5; return 7; }
: > "$EUI_JS_DEV"
write_js_event "$EUI_JS_DEV" 1 1 9   # unmapped button during run
: > "$EUI_FIFO"
LOG6="$TEST_TMPDIR/enroll6.log"
rc=0; eui_run_enrollment "$LOG6" || rc=$?
assert_eq "failure rc normalized to 1" "1" "$rc"
assert_contains "unmapped button number logged for probe" "$LOG6" "unmapped button number 9"

# ═══ Test 7: display truncation for the 1024px screen ═══

: > "$EUI_FIFO"
eui_show_line "[2026-07-06 12:00:00] info: $(printf 'x%.0s' $(seq 1 100))"
shown=$(sed 's/^TEXT://' "$EUI_FIFO" | head -1)
if [ "${#shown}" -le 64 ]; then
    assert_eq "shown line fits 64-char budget" "fits" "fits"
else
    assert_eq "shown line fits 64-char budget" "fits" "${#shown} chars"
fi

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
