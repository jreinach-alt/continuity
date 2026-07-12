#!/bin/sh
# shellcheck shell=ash
# Spike T2.0 P1: bsnes-side harness validity controls (C1, C3) + a real
# bsnes-state cross-check of the P0 bst_dump oracle.
#
# Thin gate over the Python control driver
# (tools/transmute/harness/controls.py). The real work — building a
# byte-compatible .bst under the pinned bsnes libretro core, round-tripping
# it, and rejecting corrupted states — is Python + the compiled bsnes_host.
#
# SKIP-not-FAIL discipline: the bsnes core + host are a multi-minute C++
# build that the mainline gate host does not have (and must not trigger).
# The driver returns exit 77 when the core/host aren't built; this wrapper
# turns that into a clean skip so A6 (gate.sh full green) never regresses.
# Build them once with tools/transmute/harness/build_bsnes_host.sh to make
# these controls run.
#
# Desktop-tier tool test: writes only under $TMPDIR, never the repo tree.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
TRANSMUTE="$PROJECT_ROOT/tools/transmute"
DRIVER="$TRANSMUTE/harness/controls.py"
HOST="$TRANSMUTE/build/bsnes_host"
CORE="$TRANSMUTE/build/bsnes_libretro.so"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP: python3 not available\n'
    exit 0
fi
if [ ! -x "$HOST" ] || [ ! -e "$CORE" ]; then
    printf 'SKIP: bsnes host/core not built (run harness/build_bsnes_host.sh)\n'
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
TMPDIR="$WORK"; export TMPDIR

run_control() {
    _id="$1"
    _rc=0
    python3 "$DRIVER" "$_id" >"$WORK/$_id.out" 2>"$WORK/$_id.err" || _rc=$?
    cat "$WORK/$_id.out"
    case "$_rc" in
        0)  printf 'PASS: %s\n' "$_id" ;;
        77) printf 'SKIP: %s — bsnes core unavailable\n' "$_id" ;;
        *)  printf 'FAIL: %s (exit %s)\n' "$_id" "$_rc" >&2
            cat "$WORK/$_id.err" >&2
            return 1 ;;
    esac
    return 0
}

rc=0
run_control c1 || rc=1
run_control c3 || rc=1

# Cross-check: the P0 bst_dump oracle walks a REAL bsnes state to exactly
# zero residual (first real bsnes state the oracle has ever seen — it was
# built in P0 against synthetic fixtures because bsnes could not be built
# then). StateProbe carries 8 KiB battery SRAM, so pass -s 8192.
ROM="$TESTS_DIR/fixtures/transmute/stateprobe/stateprobe.sfc"
if command -v gcc >/dev/null 2>&1 && gcc -std=c99 -O2 -o "$WORK/bst_dump" \
        "$TRANSMUTE/bst_dump.c" -lz 2>"$WORK/cc.err"; then
    if "$HOST" save "$CORE" "$ROM" "$WORK/real.bst" --frames 550 \
            >/dev/null 2>&1 \
       && "$WORK/bst_dump" -s 8192 "$WORK/real.bst" >/dev/null 2>&1; then
        printf 'PASS: bst_dump zero-residual walk of a real bsnes state\n'
    else
        printf 'FAIL: bst_dump refused a real bsnes state\n' >&2
        rc=1
    fi
else
    printf 'SKIP: bst_dump cross-check (no cc/zlib)\n'
fi

exit "$rc"
