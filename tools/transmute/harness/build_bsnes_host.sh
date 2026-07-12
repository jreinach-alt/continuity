#!/bin/sh
# build_bsnes_host.sh — compile the Spike T2.0 headless bsnes runner.
#
# Builds two things into tools/transmute/build/ (gitignored):
#   1. the pinned bsnes libretro core (if not already built), via the
#      vendored tree's own GNUmakefile — the headless emulation boundary;
#   2. bsnes_host, our libretro driver (bsnes_host.cpp) that boots a ROM
#      and reads/writes byte-compatible .bst save states.
#
# Idempotent: skips a step whose output already exists. Desktop-tier
# x86_64 tooling; needs g++ (C++17) and the vendored bsnes tree
# (tools/transmute/fetch_refs.sh). Never shipped to a device.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
TRANSMUTE="$(cd "$HERE/.." && pwd)"
VENDOR_BSNES="$TRANSMUTE/vendor/bsnes/bsnes"
BUILD_DIR="$TRANSMUTE/build"
CORE_OUT="$VENDOR_BSNES/out/bsnes_libretro.so"
HOST_OUT="$BUILD_DIR/bsnes_host"
CORE_LINK="$BUILD_DIR/bsnes_libretro.so"

if [ ! -d "$VENDOR_BSNES" ]; then
    printf 'error: vendored bsnes tree missing (%s)\n' "$VENDOR_BSNES" >&2
    printf 'run: sh tools/transmute/fetch_refs.sh\n' >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

# 1. libretro core (the slow step; ~2-4 min). local=false keeps the .so
#    portable (no -march=native) so a CI host can reuse a built artifact.
if [ ! -f "$CORE_OUT" ]; then
    printf 'building bsnes libretro core (this takes a few minutes)...\n'
    ( cd "$VENDOR_BSNES" && make target=libretro platform=linux local=false \
        -j"$(nproc 2>/dev/null || echo 2)" )
else
    printf 'bsnes libretro core already built: %s\n' "$CORE_OUT"
fi

# Stable path to the core inside build/ so the runner has one place to look.
ln -sf "$CORE_OUT" "$CORE_LINK"

# 2. the host driver.
printf 'compiling bsnes_host...\n'
g++ -std=c++17 -O2 -Wall -I"$VENDOR_BSNES/target-libretro" \
    "$HERE/bsnes_host.cpp" -ldl -o "$HOST_OUT"

printf 'ok:\n  core: %s\n  host: %s\n' "$CORE_LINK" "$HOST_OUT"
