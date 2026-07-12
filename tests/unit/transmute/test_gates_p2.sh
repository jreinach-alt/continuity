#!/bin/sh
# shellcheck shell=ash
# Spike T2.0 P2: donor-encode gates G2/G3 (tools/transmute/harness/gates_p2.py)
# + the transmute_snes.c shipping-pipeline formalization.
#
# The real work — a power-on bsnes donor .bst, overwriting its architectural +
# register-file domains from the committed StateProbe beacon capture, and
# re-loading the rebuilt state under the pinned bsnes core — is Python + the
# compiled bsnes_host + mss_dump/bst_dump oracles.
#
# GATED (Session 5): G2 (the rebuilt cross-emulator state LOADS; a byte-mangled
# one is rejected) AND G3 (the live bsnes re-audit ADVANCES the beacon epoch
# past the injected value AND reaches the full StateProbe pass bitmap 0x3F8F).
# The register-file transforms (PPU, CPU-I/O timing, structured OAM, SMP/SPC700
# incl. the mailbox port crosswalk, DMA, DSP blob) close the loop; gates_p2.py
# returns non-zero unless BOTH the epoch advanced (not a tautology) and every
# audited domain passed the fresh re-audit.
#
# Also asserts transmute_snes.c (the standalone C pipeline) builds and emits a
# BYTE-IDENTICAL .bst to the Python oracle encoder — the C tool is the shipping
# path; the Python encoder is the oracle-driven reference.
#
# SKIP-not-FAIL discipline: the bsnes core + host are a multi-minute C++ build
# the mainline gate host does not have. gates_p2.py returns 77 when the
# core/host aren't built; this wrapper turns that into a clean skip so A6
# (gate.sh full green) never regresses. Build once with
# tools/transmute/harness/build_bsnes_host.sh to make this run.
#
# Desktop-tier tool test: writes only under $TMPDIR, never the repo tree.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
TRANSMUTE="$PROJECT_ROOT/tools/transmute"
DRIVER="$TRANSMUTE/harness/gates_p2.py"
HOST="$TRANSMUTE/build/bsnes_host"
CORE="$TRANSMUTE/build/bsnes_libretro.so"
FIXTURE="$PROJECT_ROOT/tests/fixtures/transmute/stateprobe"
MSS="$FIXTURE/beacon_gen2.mss"
ROM="$FIXTURE/stateprobe.sfc"

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

# --- G2/G3 gate (epoch-advance + full pass bitmap, or SKIP on missing deps) ---
rc=0
python3 "$DRIVER" >"$WORK/g.out" 2>"$WORK/g.err" || rc=$?
cat "$WORK/g.out"
case "$rc" in
    0)  printf 'PASS: G2 + G3 met (live re-audit advanced, pass bitmap 0x3F8F)\n' ;;
    77) printf 'SKIP: G2/G3 — bsnes core unavailable\n'; exit 0 ;;
    *)  printf 'FAIL: G2/G3 gate (exit %s)\n' "$rc" >&2
        cat "$WORK/g.err" >&2
        exit "$rc" ;;
esac

# --- transmute_snes.c: builds + byte-identical to the Python oracle encoder ---
CC=$(command -v gcc || command -v cc || true)
if [ -z "$CC" ]; then
    printf 'SKIP: no C compiler for transmute_snes.c\n'
    exit 0
fi
TS="$WORK/transmute_snes"
if ! "$CC" -std=c99 -O2 -o "$TS" "$TRANSMUTE/transmute_snes.c" -lz 2>"$WORK/cc.err"; then
    printf 'FAIL: transmute_snes.c did not build\n' >&2
    cat "$WORK/cc.err" >&2
    exit 1
fi

MSS_DUMP="$TRANSMUTE/build/mss_dump"
BST_DUMP="$TRANSMUTE/build/bst_dump"
DONOR="$WORK/donor.bst"
"$HOST" save "$CORE" "$ROM" "$DONOR" --frames 0 >/dev/null 2>&1

"$TS" "$MSS" "$DONOR" "$WORK/out_c.bst" 8192 >/dev/null 2>"$WORK/ts.err" || {
    printf 'FAIL: transmute_snes run failed\n' >&2; cat "$WORK/ts.err" >&2; exit 1; }

PYTHONPATH="$TRANSMUTE/harness" python3 -c "
import sys, encode_bsnes as E
E.encode('$MSS', '$DONOR', '$WORK/out_py.bst', '$MSS_DUMP', '$BST_DUMP', 8192)
" 2>"$WORK/py.err" || {
    printf 'FAIL: python oracle encode failed\n' >&2; cat "$WORK/py.err" >&2; exit 1; }

C_SUM=$(md5sum <"$WORK/out_c.bst" | cut -d' ' -f1)
PY_SUM=$(md5sum <"$WORK/out_py.bst" | cut -d' ' -f1)
if [ "$C_SUM" = "$PY_SUM" ]; then
    printf 'PASS: transmute_snes.c byte-identical to Python oracle (%s)\n' "$C_SUM"
else
    printf 'FAIL: transmute_snes.c (%s) != Python oracle (%s)\n' "$C_SUM" "$PY_SUM" >&2
    exit 1
fi

exit 0
