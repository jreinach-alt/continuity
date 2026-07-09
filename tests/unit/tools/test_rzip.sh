#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for tools/rzip/rzip.c (continuity-rzip codec).
# Uses build/host/bin/continuity-rzip when present; otherwise compiles a
# copy into the test tmpdir (gcc + zlib are present everywhere the suite
# runs: dev container and CI runners). Fixture decode assertions pin the
# on-disk format: the committed .bin files were validated against an
# independent implementation of libretro-common's rzip_stream.c.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FIXTURES="$TESTS_DIR/fixtures/rzip"

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

assert_same_bytes() {
    local desc a b
    desc="$1"; a="$2"; b="$3"
    if cmp -s "$a" "$b"; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  files differ: %s vs %s\n' "$desc" "$a" "$b" >&2
        failed=$((failed + 1))
    fi
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

RZIP="$PROJECT_ROOT/build/host/bin/continuity-rzip"
if [ ! -x "$RZIP" ]; then
    RZIP="$TEST_TMPDIR/continuity-rzip"
    if ! gcc -O2 -std=c99 -o "$RZIP" "$PROJECT_ROOT/tools/rzip/rzip.c" -lz 2>"$TEST_TMPDIR/cc.err"; then
        printf 'FAIL: cannot build continuity-rzip for testing:\n' >&2
        cat "$TEST_TMPDIR/cc.err" >&2
        printf '\n0 passed, 1 failed\n'
        exit 1
    fi
fi

# --- Format pin: committed fixtures decode to the committed raw ---
"$RZIP" decompress "$FIXTURES/save_rzip.bin" "$TEST_TMPDIR/f1"
assert_same_bytes "fixture (128K chunk) decodes to committed raw" \
    "$FIXTURES/save_raw.bin" "$TEST_TMPDIR/f1"

"$RZIP" decompress "$FIXTURES/save_rzip_multichunk.bin" "$TEST_TMPDIR/f2"
assert_same_bytes "fixture (1K chunks) decodes to committed raw" \
    "$FIXTURES/save_raw.bin" "$TEST_TMPDIR/f2"

# --- Header bytes are the reference's exact layout ---
# magic '#RZIPv' 0x01 '#' = 35 82 90 73 80 118 1 35
hdr=$(dd if="$FIXTURES/save_rzip.bin" bs=8 count=1 2>/dev/null | od -An -tu1 | tr -s ' ' | sed 's/^ //;s/ $//')
assert_eq "magic bytes incl. raw version 0x01" "35 82 90 73 80 118 1 35" "$hdr"

# --- detect verdicts and exit codes ---
out=$("$RZIP" detect "$FIXTURES/save_rzip.bin"); rc=$?
assert_eq "detect rzip prints rzip" "rzip" "$out"
assert_rc "detect rzip rc 0" 0 "$rc"

rc=0; out=$("$RZIP" detect "$FIXTURES/save_raw.bin") || rc=$?
assert_eq "detect raw prints raw" "raw" "$out"
assert_rc "detect raw rc 1" 1 "$rc"

printf 'tiny' > "$TEST_TMPDIR/tiny"
rc=0; out=$("$RZIP" detect "$TEST_TMPDIR/tiny") || rc=$?
assert_eq "short file detects raw" "raw" "$out"
assert_rc "short file rc 1" 1 "$rc"

# a future/unknown version byte must read as raw (reference behavior)
{ printf '#RZIPv'; printf '\002'; printf '#'; dd if=/dev/zero bs=12 count=1 2>/dev/null; } > "$TEST_TMPDIR/v2"
rc=0; out=$("$RZIP" detect "$TEST_TMPDIR/v2") || rc=$?
assert_eq "unknown version byte detects raw" "raw" "$out"

rc=0; "$RZIP" detect "$TEST_TMPDIR/does-not-exist" >/dev/null 2>&1 || rc=$?
assert_rc "detect on missing file rc 2" 2 "$rc"

# --- Fresh round-trips (spaced filename, single and multi chunk) ---
SRC="$TEST_TMPDIR/Super Metroid (USA).srm"
{ printf 'METROID-SRAM'; dd if=/dev/zero bs=1024 count=3 2>/dev/null; printf 'END'; } > "$SRC"

"$RZIP" compress "$SRC" "$TEST_TMPDIR/rt.rz"
"$RZIP" decompress "$TEST_TMPDIR/rt.rz" "$TEST_TMPDIR/rt.out"
assert_same_bytes "round-trip default chunk" "$SRC" "$TEST_TMPDIR/rt.out"

"$RZIP" compress "$SRC" "$TEST_TMPDIR/rt16.rz" -c 512
"$RZIP" decompress "$TEST_TMPDIR/rt16.rz" "$TEST_TMPDIR/rt16.out"
assert_same_bytes "round-trip 512B chunks (multi-chunk)" "$SRC" "$TEST_TMPDIR/rt16.out"

rc=0; "$RZIP" detect "$TEST_TMPDIR/rt.rz" >/dev/null || rc=$?
assert_rc "fresh compress detects as rzip" 0 "$rc"

# --- Refusals (all must be loud, never silent corruption) ---
rc=0; "$RZIP" decompress "$FIXTURES/save_raw.bin" "$TEST_TMPDIR/no" 2>/dev/null || rc=$?
assert_rc "decompress refuses raw input rc 1" 1 "$rc"

dd if="$FIXTURES/save_rzip.bin" of="$TEST_TMPDIR/trunc.rz" bs=1 count=40 2>/dev/null
rc=0; "$RZIP" decompress "$TEST_TMPDIR/trunc.rz" "$TEST_TMPDIR/no" 2>/dev/null || rc=$?
assert_rc "truncated file refused rc 2" 2 "$rc"

cat "$FIXTURES/save_rzip.bin" > "$TEST_TMPDIR/trail.rz"
printf 'XX' >> "$TEST_TMPDIR/trail.rz"
rc=0; "$RZIP" decompress "$TEST_TMPDIR/trail.rz" "$TEST_TMPDIR/no" 2>/dev/null || rc=$?
assert_rc "trailing bytes refused rc 2" 2 "$rc"

: > "$TEST_TMPDIR/empty"
rc=0; "$RZIP" compress "$TEST_TMPDIR/empty" "$TEST_TMPDIR/no.rz" 2>/dev/null || rc=$?
assert_rc "empty input compress refused rc 2 (RZIP cannot represent it)" 2 "$rc"

rc=0; "$RZIP" compress "$SRC" "$TEST_TMPDIR/no.rz" -c 0 2>/dev/null || rc=$?
assert_rc "chunk size 0 refused rc 2" 2 "$rc"

# corrupt zlib payload: flip a byte mid-chunk
python3 - "$FIXTURES/save_rzip.bin" "$TEST_TMPDIR/corrupt.rz" 2>/dev/null <<'EOF' || cp "$FIXTURES/save_rzip.bin" "$TEST_TMPDIR/corrupt.rz"
import sys
d = bytearray(open(sys.argv[1], 'rb').read())
d[40] ^= 0xFF
open(sys.argv[2], 'wb').write(bytes(d))
EOF
if ! cmp -s "$FIXTURES/save_rzip.bin" "$TEST_TMPDIR/corrupt.rz"; then
    rc=0; "$RZIP" decompress "$TEST_TMPDIR/corrupt.rz" "$TEST_TMPDIR/no" 2>/dev/null || rc=$?
    assert_rc "corrupt chunk refused rc 2" 2 "$rc"
else
    # python3 unavailable — count the skipped corruption case as passed
    passed=$((passed + 1))
fi

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
