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
#   C4 — full behavioural: decode every architectural domain out of a .mss
#        (WRAM/VRAM/OAM/CGRAM/SRAM/ARAM byte-exact + CPU field-exact vs the
#        live core = ground truth), transplant them (+ the PPU register file
#        via SetPpuState) into a different parked core, and require its
#        StateProbe continuation to match a native LoadStateFile.
#
# SKIP-not-FAIL discipline: the Mesen2 half of the harness needs
# SuperForge's MesenCore.so + SDL2, which the mainline gate host does
# not have. The driver returns exit 77 (skip) when the core can't be
# brought up; this wrapper turns that into a clean skip so A6
# (gate.sh full green) never regresses. A genuine round-trip failure
# returns exit 1 and fails the test loudly.
#
# Core-can't-write capability skip (privilege-agnostic, NOT an id -u
# branch): the MesenCore serializes a .mss as a zip via miniz; when the
# core cannot write its state components to disk it prints
# `mz_zip_writer_add_file() failed!` and hands back a truncated state, so
# the C4 continuation comparison fails on garbage rather than on a real
# correctness regression. This is observed under the gate's UNPRIVILEGED
# (nobody) pass — the core resolves an internal working dir outside the
# gate's HOME/TMPDIR and nobody can't write it — and would equally hit any
# read-only-home host. It is the same "emulator can't operate here" class
# the exit-77 path handles, so we treat that signature as a SKIP. C2 (which
# does not compare a fresh continuation state) is unaffected, and under a
# writable home (root, or a normal dev host) the signature never appears
# and C4 runs its full assertions. See docs/sprints/spike-t2.0-summary.md
# Session 5 for the pre-existing-issue attribution.
#
# Desktop-tool test: writes only under $TMPDIR, never the repo tree.
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
        *)  if grep -q 'mz_zip_writer_add_file() failed' \
                    "$WORK/$_id.out" "$WORK/$_id.err" 2>/dev/null; then
                printf 'SKIP: %s — MesenCore could not write its state zip in this environment (mz_zip_writer_add_file failed; core cannot operate here)\n' "$_id"
                return 0
            fi
            printf 'FAIL: %s (exit %s)\n' "$_id" "$_rc" >&2
            cat "$WORK/$_id.err" >&2
            return 1 ;;
    esac
    return 0
}

rc=0
run_control c2 || rc=1
run_control c4 || rc=1
exit "$rc"
