#!/bin/sh
# Cross-compile a static BusyBox for aarch64 (TrimUI Brick / NextUI)
#
# Dependencies: gcc-aarch64-linux-gnu, make
#
# Produces: build/aarch64/prefix/bin/busybox (static, ~2MB)
#
# Why we vendor BusyBox: the device's /bin/sh and userland are whatever
# BusyBox build the firmware (or a fork of it) shipped — version and
# feature drift across NextUI forks is real. The daemon re-execs itself
# under this pinned interpreter when it passes an on-device self-test
# (see continuity_daemon.sh); every failure falls back to the device
# shell, so this binary can never brick the launch path.
#
# Config choices (on top of defconfig):
#   CONFIG_STATIC=y                    — no shared-library dependencies
#   CONFIG_FEATURE_SH_STANDALONE=y     — ash resolves bare command names
#     to its own applets first (via /proc/self/exe; exFAT has no
#     symlinks, so an applet farm is not an option). Absolute paths
#     (our bundled git) are never shadowed. If the self-exec ever
#     fails, ash falls through to normal PATH lookup — fail-open at
#     the applet level.
#   CONFIG_FEATURE_PREFER_APPLETS=y    — NOEXEC/NOFORK applets (find,
#     cut, head, date, rm, cp, mv, mktemp, chmod, sha256sum, dd, ...)
#     run in-process with no exec edge at all.
#   CONFIG_TC=n                        — tc.c does not compile against
#     kernel headers >= 6.8 (TCA_CBQ_* removed), and we ship no
#     traffic control.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/build/aarch64"
SRC_DIR="$BUILD_ROOT/src"
PREFIX="$BUILD_ROOT/prefix"

CROSS=aarch64-linux-gnu

BUSYBOX_VERSION="1.36.1"
# busybox.net is the project's own host (github.com release downloads
# are blocked from restricted build containers).
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"

NPROC=$(nproc 2>/dev/null || echo 2)

log() {
    printf "\n=== %s ===\n\n" "$1"
}

mkdir -p "$SRC_DIR" "$PREFIX/bin"

# ── Download ─────────────────────────────────────────────────────────
TARBALL="$SRC_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2"
if [ ! -f "$TARBALL" ]; then
    log "Downloading busybox ${BUSYBOX_VERSION}"
    curl -fSL --retry 3 -o "$TARBALL" "$BUSYBOX_URL"
fi

BB_SRC="$SRC_DIR/busybox-${BUSYBOX_VERSION}"
if [ ! -d "$BB_SRC" ]; then
    log "Extracting"
    tar -xjf "$TARBALL" -C "$SRC_DIR"
fi

# ── Configure ────────────────────────────────────────────────────────
log "Configuring (defconfig + static + standalone shell)"
cd "$BB_SRC"
make defconfig >/dev/null

set_cfg() {
    # enable: set_cfg CONFIG_FOO y   disable: set_cfg CONFIG_FOO n
    if [ "$2" = "y" ]; then
        sed -i "s/^# $1 is not set/$1=y/" .config
        grep -q "^$1=y" .config || printf '%s=y\n' "$1" >> .config
    else
        sed -i "s/^$1=y/# $1 is not set/" .config
    fi
}

set_cfg CONFIG_STATIC y
set_cfg CONFIG_FEATURE_SH_STANDALONE y
set_cfg CONFIG_FEATURE_PREFER_APPLETS y
set_cfg CONFIG_TC n

# Resolve any dependent options non-interactively
yes '' | make oldconfig >/dev/null 2>&1

for opt in CONFIG_STATIC CONFIG_FEATURE_SH_STANDALONE CONFIG_FEATURE_PREFER_APPLETS; do
    if ! grep -q "^${opt}=y" .config; then
        printf 'ERROR: %s did not survive oldconfig\n' "$opt" >&2
        exit 1
    fi
done
if grep -q '^CONFIG_TC=y' .config; then
    printf 'ERROR: CONFIG_TC still enabled (breaks against kernel headers >= 6.8)\n' >&2
    exit 1
fi

# ── Build ────────────────────────────────────────────────────────────
log "Building (this takes a few minutes)"
make CROSS_COMPILE="${CROSS}-" -j"$NPROC" >/dev/null

# ── Verify & install ─────────────────────────────────────────────────
log "Verifying"
if ! file busybox | grep -q 'ARM aarch64'; then
    printf 'ERROR: produced binary is not aarch64:\n  %s\n' "$(file busybox)" >&2
    exit 1
fi
if ! file busybox | grep -q 'statically linked'; then
    printf 'ERROR: produced binary is not static:\n  %s\n' "$(file busybox)" >&2
    exit 1
fi
if command -v qemu-aarch64-static >/dev/null 2>&1; then
    qemu-aarch64-static ./busybox ash -c 'true' || {
        printf 'ERROR: qemu smoke test failed (busybox ash -c true)\n' >&2
        exit 1
    }
    printf '  qemu smoke test: ok\n'
else
    printf '  WARNING: qemu-aarch64-static not found — smoke test skipped\n'
fi

cp busybox "$PREFIX/bin/busybox"
chmod +x "$PREFIX/bin/busybox"

printf '\n=== BusyBox build complete ===\n\n'
printf '  Binary: %s\n' "$PREFIX/bin/busybox"
printf '  Size:   %s bytes\n' "$(wc -c < "$PREFIX/bin/busybox")"
printf '\n  Next: scripts/build_pak.sh bundles it as bin/busybox\n\n'
