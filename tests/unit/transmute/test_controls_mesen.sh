#!/bin/sh
# shellcheck shell=ash
# Spike T2.0 P1: Mesen2-side harness validity controls (C2 + C4).
#
# Thin gate over the Python control driver
# (tools/transmute/harness/controls.py). The real work is Python (the
# Mesen2 harness is Python; spec toolchain note exempts the spike from the
# BusyBox constraint):
#   C2 — save a .mss, reload it, verify the StateProbe self-audit still
#        passes with the beacon epoch rewound.
#   C4 — decode WRAM out of a .mss (byte-identical to the live core's WRAM
#        = ground truth), then re-inject it into a different parked core.
#
# SKIP-not-FAIL discipline: the Mesen2 half of the harness needs
# SuperForge's MesenCore.so + SDL2, which the mainline gate host does
# not have. The driver returns exit 77 (skip) when the core can't be
# brought up; this wrapper turns that into a clean skip so A6
# (gate.sh full green) never regresses. A genuine round-trip failure
# returns exit 1 and fails the test loudly.
#
# Desktop-tier tool test: writes only under $TMPDIR, never the repo tree.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DRIVER="$PROJECT_ROOT/tools/transmute/harness/controls.py"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'SKIP: python3 not available\n'
    exit 0
fi
if [ ! -f "$DRIVER" ]; then
    printf 'FAIL: control driver missing: %s\n' "$DRIVER" >&2
    exit 1
fi

# Keep every artifact under $TMPDIR (mktemp honors it; per-process name).
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
        77) printf 'SKIP: %s — Mesen2 harness unavailable (%s)\n' "$_id" \
                "$(tail -n1 "$WORK/$_id.err" 2>/dev/null || echo 'no core')" ;;
        *)  printf 'FAIL: %s (exit %s)\n' "$_id" "$_rc" >&2
            cat "$WORK/$_id.err" >&2
            return 1 ;;
    esac
    return 0
}

rc=0
run_control c2 || rc=1
run_control c4 || rc=1
exit "$rc"
