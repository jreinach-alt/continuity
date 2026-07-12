#!/bin/sh
# shellcheck shell=ash
# Spike T2.0 P1: Mesen2-side harness validity controls (C2, later C4).
#
# Thin gate over the Python control driver
# (tools/transmute/harness/controls.py). The real work — booting the
# StateProbe ROM under MesenCore.so, saving a .mss, reloading it, and
# verifying the self-audit still passes with the beacon epoch rewound —
# is Python (the Mesen2 harness is Python; spec toolchain note exempts
# the spike from the BusyBox constraint).
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

rc=0
python3 "$DRIVER" c2 --frames 600 >"$WORK/c2.out" 2>"$WORK/c2.err" || rc=$?

cat "$WORK/c2.out"
case "$rc" in
    0)
        printf 'PASS: C2 Mesen2 native round-trip\n'
        exit 0
        ;;
    77)
        printf 'SKIP: C2 — Mesen2 core unavailable (%s)\n' \
            "$(tail -n1 "$WORK/c2.err" 2>/dev/null || echo 'no core')"
        exit 0
        ;;
    *)
        printf 'FAIL: C2 Mesen2 native round-trip (exit %s)\n' "$rc" >&2
        cat "$WORK/c2.err" >&2
        exit 1
        ;;
esac
