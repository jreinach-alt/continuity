#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Interop test: continuity-rzip vs the OS's OWN container code.
#
# tools/rzip/reference/ vendors libretro-common's rzip_stream.c (and
# its trans_stream backends) VERBATIM — the same code NextUI's minarch
# and RetroArch compile — behind a stdio shim that touches file I/O
# only. This test compiles that real code into an oracle (ref-rzip)
# and requires byte-exact interop in BOTH directions, plus the
# real-world raw shapes seen in the live saves repo (raw SRAM; snes9x
# native '#!s9xsnp' states, which LOOK like a container magic but are
# not one).
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
REFDIR="$PROJECT_ROOT/tools/rzip/reference"

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

# --- Setup: build both binaries ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

RZIP="$PROJECT_ROOT/build/host/bin/continuity-rzip"
if [ ! -x "$RZIP" ]; then
    RZIP="$TEST_TMPDIR/continuity-rzip"
    gcc -O2 -std=c99 -o "$RZIP" "$PROJECT_ROOT/tools/rzip/rzip.c" -lz
fi

REF="$TEST_TMPDIR/ref-rzip"
# HAVE_ZLIB gates the zlib trans backend inside trans_stream.c — real
# builds define it; without it the reference silently has no codec.
if ! gcc -O2 -std=c99 -DHAVE_ZLIB=1 \
        -I "$REFDIR/include" -I "$REFDIR/shim" \
        -o "$REF" \
        "$REFDIR/ref_main.c" "$REFDIR/rzip_stream.c" \
        "$REFDIR/trans_stream.c" "$REFDIR/trans_stream_zlib.c" \
        "$REFDIR/trans_stream_pipe.c" "$REFDIR/shim/file_stream_stdio.c" \
        -lz 2>"$TEST_TMPDIR/cc.err"; then
    printf 'FAIL: cannot build reference harness:\n' >&2
    cat "$TEST_TMPDIR/cc.err" >&2
    printf '\n0 passed, 1 failed\n'
    exit 1
fi

# --- Payloads: fixture + real-world shapes ---
cd "$TEST_TMPDIR"
cp "$TESTS_DIR/fixtures/rzip/save_raw.bin" sram_like.bin

# snes9x native state shape (the real .st0/.st9 files on the live
# repo): '#!s9xsnp' header + opaque body. NOT a container format.
{ printf '#!s9xsnp:0011'; dd if=/dev/zero bs=1024 count=12 2>/dev/null; printf 'END'; } \
    > "s9x state (USA).st0"

# multi-chunk exerciser: bigger than the 128 KiB default chunk
dd if=/dev/urandom of=big.bin bs=1024 count=200 2>/dev/null

# --- Bidirectional byte-exact interop on every payload ---
for p in sram_like.bin "s9x state (USA).st0" big.bin; do
    "$REF" compress "$p" "$p.ref.rz"
    "$RZIP" decompress "$p.ref.rz" "$p.ref2us"
    assert_same_bytes "OS-code encode -> our decode: $p" "$p" "$p.ref2us"

    "$RZIP" compress "$p" "$p.us.rz"
    "$REF" decompress "$p.us.rz" "$p.us2ref"
    assert_same_bytes "our encode -> OS-code decode: $p" "$p" "$p.us2ref"
done

# --- detect agrees with the reference reader's classifications ---
out=$("$RZIP" detect sram_like.bin.ref.rz); rc=$?
assert_eq "OS-code output detects as rzip" "rzip" "$out"

rc=0; out=$("$RZIP" detect "s9x state (USA).st0") || rc=$?
assert_eq "real-shape snes9x state detects raw ('#!s9xsnp' is NOT a container)" \
    "raw" "$out"
assert_eq "snes9x-shape detect rc 1" "1" "$rc"

# The reference reader passes raw files through unchanged — so must
# any pipeline built on detect: raw in, identical bytes out.
"$REF" decompress "s9x state (USA).st0" rawpass.bin
assert_same_bytes "OS-code raw passthrough matches (spaced name too)" \
    "s9x state (USA).st0" rawpass.bin

# --- The committed primary fixture is REFERENCE-generated ---
"$RZIP" decompress "$TESTS_DIR/fixtures/rzip/save_rzip.bin" fix.out
assert_same_bytes "committed reference-encoded fixture decodes" \
    "$TESTS_DIR/fixtures/rzip/save_raw.bin" fix.out

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
