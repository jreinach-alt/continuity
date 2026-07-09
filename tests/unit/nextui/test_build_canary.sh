#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for scripts/build_canary.sh
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

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# --- Test 1: build produces the canary PAK in the override location ---

rc=0
CANARY_OUT_ROOT="$TEST_TMPDIR/out" sh "$PROJECT_ROOT/scripts/build_canary.sh" \
    >/dev/null 2>&1 || rc=$?
assert_eq "build_canary.sh exits 0" "0" "$rc"

PAK="$TEST_TMPDIR/out/Continuity.pak"
assert_file_exists "canary PAK dir created" "$PAK"
assert_file_exists "launch.sh present" "$PAK/launch.sh"

if [ -x "$PAK/launch.sh" ]; then
    assert_eq "launch.sh is executable" "yes" "yes"
else
    assert_eq "launch.sh is executable" "yes" "no"
fi

# --- Test 2: PAK contains ONLY launch.sh (minimal by design) ---

file_count=$(find "$PAK" -type f | wc -l)
assert_eq "canary PAK contains exactly one file" "1" "$file_count"

# --- Test 3: built launch.sh is byte-identical to source, LF-clean ---

if cmp -s "$PROJECT_ROOT/src/platforms/nextui/canary_launch.sh" "$PAK/launch.sh"; then
    assert_eq "built launch.sh matches source" "same" "same"
else
    assert_eq "built launch.sh matches source" "same" "different"
fi

cr=$(printf '\r')
if grep -q "$cr" "$PAK/launch.sh"; then
    assert_eq "built launch.sh has no CRLF" "clean" "has-crlf"
else
    assert_eq "built launch.sh has no CRLF" "clean" "clean"
fi

# --- Test 4: build rejects CRLF-corrupted source ---
# Run against a copy of the project scripts with a corrupted canary source,
# using a fake project layout so the real source is untouched.

FAKE_ROOT="$TEST_TMPDIR/fake_project"
mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/src/platforms/nextui"
cp "$PROJECT_ROOT/scripts/build_canary.sh" "$FAKE_ROOT/scripts/"
sed 's/$/\r/' "$PROJECT_ROOT/src/platforms/nextui/canary_launch.sh" \
    > "$FAKE_ROOT/src/platforms/nextui/canary_launch.sh"

rc=0
CANARY_OUT_ROOT="$TEST_TMPDIR/out_crlf" sh "$FAKE_ROOT/scripts/build_canary.sh" \
    >/dev/null 2>&1 || rc=$?
assert_eq "build fails on CRLF source" "1" "$rc"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
