#!/bin/sh
# Build continuity-rzip — the standalone RZIP save-container codec
# (see tools/rzip/rzip.c for the format contract).
#
# Produces:
#   build/host/bin/continuity-rzip           (host, for tests/repo-side use)
#   build/aarch64/prefix/bin/continuity-rzip (static, for on-device Phase 3)
#
# The aarch64 build links the static zlib produced by build_git.sh
# (build/aarch64/prefix). If the cross toolchain or that zlib is
# missing, the aarch64 build is skipped with a warning — the host
# build (which the test suite exercises) always runs.
#
# NOT yet shipped in the PAK: the canonicalization spec quarantines
# compressed saves in Phase 2; Phase 3 adds this binary to
# build_pak.sh + checksums when the shell integration lands.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$PROJECT_ROOT/tools/rzip/rzip.c"
HOST_OUT="$PROJECT_ROOT/build/host/bin/continuity-rzip"
CROSS=aarch64-linux-gnu
CROSS_PREFIX="$PROJECT_ROOT/build/aarch64/prefix"
CROSS_OUT="$CROSS_PREFIX/bin/continuity-rzip"

CFLAGS="-O2 -Wall -Wextra -Werror -std=c99"

printf '=== continuity-rzip: host build ===\n'
mkdir -p "$(dirname "$HOST_OUT")"
# shellcheck disable=SC2086
gcc $CFLAGS -o "$HOST_OUT" "$SRC" -lz
"$HOST_OUT" --version

if command -v "${CROSS}-gcc" >/dev/null 2>&1 && [ -f "$CROSS_PREFIX/lib/libz.a" ]; then
    printf '=== continuity-rzip: aarch64 static build ===\n'
    mkdir -p "$(dirname "$CROSS_OUT")"
    # shellcheck disable=SC2086
    "${CROSS}-gcc" $CFLAGS -static \
        -I"$CROSS_PREFIX/include" -L"$CROSS_PREFIX/lib" \
        -o "$CROSS_OUT" "$SRC" -lz
    "${CROSS}-strip" "$CROSS_OUT"

    if ! file "$CROSS_OUT" | grep -q 'ARM aarch64'; then
        printf 'ERROR: aarch64 build is not aarch64:\n  %s\n' "$(file "$CROSS_OUT")" >&2
        exit 1
    fi
    if command -v qemu-aarch64-static >/dev/null 2>&1; then
        qemu-aarch64-static "$CROSS_OUT" --version
        # qemu round-trip smoke against the host build
        smoke=$(mktemp -d)
        trap 'rm -rf "$smoke"' EXIT
        printf 'rzip-smoke-payload-1234567890' > "$smoke/raw"
        qemu-aarch64-static "$CROSS_OUT" compress "$smoke/raw" "$smoke/rz"
        "$HOST_OUT" decompress "$smoke/rz" "$smoke/back"
        if ! cmp -s "$smoke/raw" "$smoke/back"; then
            printf 'ERROR: qemu<->host round-trip mismatch\n' >&2
            exit 1
        fi
        printf '  qemu round-trip vs host build: ok\n'
    else
        printf '  WARNING: qemu-aarch64-static not found - smoke test skipped\n'
    fi
    printf '  aarch64: %s (%s bytes)\n' "$CROSS_OUT" "$(wc -c < "$CROSS_OUT")"
else
    printf 'WARNING: cross toolchain or static zlib missing - aarch64 build skipped\n' >&2
    printf '         (run scripts/build_git.sh once to produce the static zlib)\n' >&2
fi

printf '\n=== continuity-rzip build complete ===\n'
