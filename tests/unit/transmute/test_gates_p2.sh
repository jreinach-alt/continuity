#!/bin/sh
# shellcheck shell=ash
# Spike T2.0 P2: donor-encode gates G2/G3 (tools/transmute/harness/gates_p2.py).
#
# Thin gate over the Python P2 driver. The real work — a power-on bsnes donor
# .bst, overwriting its architectural domains from the committed StateProbe
# beacon capture, and re-loading the rebuilt state under the pinned bsnes core
# — is Python + the compiled bsnes_host + mss_dump/bst_dump oracles.
#
# What is GATED here is G2 (the rebuilt cross-emulator state LOADS, and a
# byte-mangled one is rejected). G3 (all-domain live re-audit) is REPORTED,
# advance-gated by the beacon epoch — it is partial-by-design this pass
# (PPU/APU/OAM register-file transforms deferred), so the driver returns 0 on
# G2-met regardless of G3, and prints the honest G3 attribution.
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

rc=0
python3 "$DRIVER" >"$WORK/g.out" 2>"$WORK/g.err" || rc=$?
cat "$WORK/g.out"
case "$rc" in
    0)  printf 'PASS: G2 met (G3 reported)\n' ;;
    77) printf 'SKIP: G2/G3 — bsnes core unavailable\n'; rc=0 ;;
    *)  printf 'FAIL: G2 not met (exit %s)\n' "$rc" >&2
        cat "$WORK/g.err" >&2 ;;
esac

exit "$rc"
