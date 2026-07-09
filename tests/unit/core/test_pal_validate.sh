#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2317
set -e

# Unit tests for pal_validate (src/core/pal.sh)
# Self-contained: creates temp dirs, runs assertions, cleans up on EXIT.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

passed=0
failed=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$desc" "$needle" "$haystack" >&2
            failed=$((failed + 1))
            ;;
    esac
}

# Helper: set up a complete PAL environment
setup_full_pal() {
    CONTINUITY_SAVES_ROOT="/tmp/saves"
    CONTINUITY_REPO_DIR="/tmp/repo"
    CONTINUITY_DEVICE_NAME="test-device"
    CONTINUITY_PLATFORM="nextui"
    CONTINUITY_GIT_BIN="git"
    pal_init() { return 0; }
    pal_is_online() { return 0; }
    pal_log() { printf '[%s] %s\n' "$1" "$2" >&2; }
    pal_get_platform_map() { printf '/tmp/map.json\n'; }
}

# Source the module under test
. "$REPO_ROOT/src/core/pal.sh"

# --- Test: all present -> returns 0 ---
setup_full_pal
result=0
pal_validate 2>/dev/null || result=$?
assert_eq "all present returns 0" "0" "$result"

# --- Test: missing each variable individually ---
for var in CONTINUITY_SAVES_ROOT CONTINUITY_REPO_DIR CONTINUITY_DEVICE_NAME CONTINUITY_PLATFORM CONTINUITY_GIT_BIN; do
    (
        setup_full_pal
        eval "$var=''"
        result=0
        pal_validate 2>"$TEST_TMPDIR/stderr_tmp" || result=$?
        stderr=$(cat "$TEST_TMPDIR/stderr_tmp")
        assert_eq "missing $var returns 1" "1" "$result"
        assert_contains "missing $var named in error" "$var" "$stderr"
        printf '%d %d\n' "$passed" "$failed"
    ) > "$TEST_TMPDIR/t_$var"
    read -r p f < "$TEST_TMPDIR/t_$var"
    passed=$((passed + p)); failed=$((failed + f))
done

# --- Test: missing each function individually ---
for fn in pal_init pal_is_online pal_log pal_get_platform_map; do
    (
        setup_full_pal
        unset -f "$fn"
        result=0
        pal_validate 2>"$TEST_TMPDIR/stderr_tmp" || result=$?
        stderr=$(cat "$TEST_TMPDIR/stderr_tmp")
        assert_eq "missing $fn returns 1" "1" "$result"
        assert_contains "missing $fn named in error" "${fn}()" "$stderr"
        printf '%d %d\n' "$passed" "$failed"
    ) > "$TEST_TMPDIR/t_$fn"
    read -r p f < "$TEST_TMPDIR/t_$fn"
    passed=$((passed + p)); failed=$((failed + f))
done

# --- Test: multiple items missing at once ---
(
    setup_full_pal
    CONTINUITY_SAVES_ROOT=""
    CONTINUITY_PLATFORM=""
    unset -f pal_log
    result=0
    pal_validate 2>"$TEST_TMPDIR/stderr_tmp" || result=$?
    stderr=$(cat "$TEST_TMPDIR/stderr_tmp")
    assert_eq "multiple missing returns 1" "1" "$result"
    assert_contains "lists CONTINUITY_SAVES_ROOT" "CONTINUITY_SAVES_ROOT" "$stderr"
    assert_contains "lists CONTINUITY_PLATFORM" "CONTINUITY_PLATFORM" "$stderr"
    assert_contains "lists pal_log()" "pal_log()" "$stderr"
    printf '%d %d\n' "$passed" "$failed"
) > "$TEST_TMPDIR/t_multi"
read -r p f < "$TEST_TMPDIR/t_multi"
passed=$((passed + p)); failed=$((failed + f))

# --- Test: pal_validate does not call pal_init ---
setup_full_pal
init_called=""
pal_init() { init_called="yes"; return 0; }
result=0
pal_validate 2>/dev/null || result=$?
assert_eq "pal_validate does not call pal_init" "" "$init_called"

printf '\ntest_pal_validate: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
