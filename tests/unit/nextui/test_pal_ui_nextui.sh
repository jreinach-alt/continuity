#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/nextui/pal_ui_nextui.sh — the Tier-0 shim.
#
# Drives the pal_ui_* primitives against synthesized 8-byte js_event records
# (B=0, A=1, Y=2, X=3) and a captured show2 FIFO file, exactly like the
# enroll-UI button tests. Proves menu paging/selection, confirm yes/no, and
# message/handoff acknowledge — no hardware.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

passed=0
failed=0

assert_eq() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then passed=$((passed + 1)); else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}
assert_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text does not contain: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
    esac
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

# press <button_number> — queue one face-button press (value=1, type=1).
press() { write_js_event "$EUI_JS_DEV" 1 1 "$1"; }

pal_log() { printf '%s: %s\n' "$1" "$2" >> "$TEST_TMPDIR/pal_log.txt"; }

EUI_TICK="0.05"
EUI_FIFO="$TEST_TMPDIR/fifo.txt"
EUI_JS_DEV="$TEST_TMPDIR/js0"
# Bound the waits low so a mis-seeded test fails fast instead of hanging.
PUI_TIMEOUT_TICKS=80
PUI_HANDOFF_TICKS=20
: > "$EUI_FIFO"
: > "$EUI_JS_DEV"

. "$PROJECT_ROOT/src/platforms/nextui/enroll_ui.sh"
. "$PROJECT_ROOT/src/platforms/nextui/pal_ui_nextui.sh"

reset_io() { : > "$EUI_FIFO"; : > "$EUI_JS_DEV"; }

B=0; A=1; Y=2

# ═══ menu: page with Y twice, select with A -> index 2 ═══
reset_io
press "$Y"; press "$Y"; press "$A"
choice=$(pal_ui_menu "Pick" "one" "two" "three")
assert_eq "menu: Y,Y,A selects index 2" "2" "$choice"
fifo=$(cat "$EUI_FIFO")
assert_contains "menu: rendered first item" "$fifo" "one"
assert_contains "menu: rendered third item" "$fifo" "three"
assert_contains "menu: shows pager" "$fifo" "3/3"
assert_contains "menu: multi-item legend has Y=next" "$fifo" "Y=next"

# ═══ menu: A immediately selects index 0 ═══
reset_io
press "$A"
choice=$(pal_ui_menu "Pick" "alpha" "beta")
assert_eq "menu: A selects index 0" "0" "$choice"

# ═══ menu: B cancels ═══
reset_io
press "$B"
choice=$(pal_ui_menu "Pick" "alpha" "beta")
assert_eq "menu: B cancels" "cancel" "$choice"

# ═══ menu: single item shows no Y=next ═══
reset_io
press "$A"
choice=$(pal_ui_menu "Only" "solo")
assert_eq "menu: single-item selects 0" "0" "$choice"
fifo=$(cat "$EUI_FIFO")
assert_contains "menu: single-item legend omits Y" "$fifo" "A=pick  B=back"

# ═══ confirm: A -> yes ═══
reset_io
press "$A"
ans=$(pal_ui_confirm "Keep this?")
assert_eq "confirm: A -> yes" "yes" "$ans"
fifo=$(cat "$EUI_FIFO")
assert_contains "confirm: rendered prompt + legend" "$fifo" "Keep this?   A=yes  B=no"

# ═══ confirm: B -> no ═══
reset_io
press "$B"
ans=$(pal_ui_confirm "Delete?")
assert_eq "confirm: B -> no" "no" "$ans"

# ═══ message: A acknowledges, returns 0, renders text ═══
reset_io
press "$A"
rc=0; pal_ui_message "All done." || rc=$?
assert_eq "message: returns 0" "0" "$rc"
fifo=$(cat "$EUI_FIFO")
assert_contains "message: rendered text" "$fifo" "All done."

# ═══ handoff: renders the go-play text, returns 0 ═══
reset_io
press "$A"
rc=0; pal_ui_handoff "Loaded save. Go play." || rc=$?
assert_eq "handoff: returns 0" "0" "$rc"
fifo=$(cat "$EUI_FIFO")
assert_contains "handoff: rendered text" "$fifo" "Loaded save. Go play."

# --- Results ---
printf '\n=== pal_ui_nextui: %s passed, %s failed ===\n' "$passed" "$failed" >&2
[ "$failed" -eq 0 ]
