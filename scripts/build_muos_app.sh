#!/bin/sh
# Assemble the muOS app zip (Sprint 3.1) from source files and the
# ALREADY-VALIDATED binaries shipped in build/Continuity.pak — the
# approved binary strategy is to port the Brick's static aarch64
# git/busybox (same SoC family), rebuilding only on demonstrated
# mismatch. The staging tree mirrors the card root, so installing is
# "Extract All onto the card":
#
#   <card>/.continuity/app/...        (scripts, binaries, config)
#   <card>/MUOS/task/Continuity.sh    (Task Toolkit entry)
#   <card>/MUOS/task/Continuity Recon.sh
#   <card>/MUOS/init/continuity.sh    (boot hook — needs "User Init
#                                      Scripts" enabled in muOS
#                                      Advanced Settings)
#
# Output: build/muos-app/ staging + build/Continuity-muos-<ver>.zip.
# Staging and zip live under build/ and are NOT committed (only
# build/Continuity.pak is a committed artifact, per CLAUDE.md).
#
# Test hooks:
#   MUOS_APP_OUT_DIR  — staging root (default: build/muos-app)
#   MUOS_APP_ZIP_DIR  — zip destination (default: build/)
#   MUOS_APP_SRC_PAK  — source of validated binaries
#                       (default: build/Continuity.pak)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_PAK="${MUOS_APP_SRC_PAK:-$PROJECT_ROOT/build/Continuity.pak}"
OUT_DIR="${MUOS_APP_OUT_DIR:-$PROJECT_ROOT/build/muos-app}"
ZIP_DIR="${MUOS_APP_ZIP_DIR:-$PROJECT_ROOT/build}"
PLATFORM_DIR="$PROJECT_ROOT/src/platforms/muos"
CORE_DIR="$PROJECT_ROOT/src/core"
CONFIG_DIR="$PROJECT_ROOT/config"
APP_DIR="$OUT_DIR/.continuity/app"
TASK_DIR="$OUT_DIR/MUOS/task"
INIT_DIR="$OUT_DIR/MUOS/init"

# The binaries must come from a VERIFIED tree: the shipped PAK carries
# its own checksums manifest, gate-verified on every full run.
for f in bin/git libexec/git-core/git libexec/git-core/git-remote-https \
         libexec/git-core/git-remote-http share/ca-bundle.crt; do
    if [ ! -f "$SRC_PAK/$f" ]; then
        printf 'ERROR: %s missing from %s — need the validated PAK binaries\n' \
            "$f" "$SRC_PAK" >&2
        exit 1
    fi
done
if [ ! -f "$SRC_PAK/bin/busybox" ]; then
    printf 'WARNING: no vendored busybox in %s — daemon will use device sh (fail-open)\n' \
        "$SRC_PAK" >&2
fi

# Clean and create the card-mirroring structure
rm -rf "$OUT_DIR"
mkdir -p "$APP_DIR/bin" "$APP_DIR/libexec/git-core" \
         "$APP_DIR/share/templates" "$APP_DIR/scripts/core" \
         "$APP_DIR/config/platform_maps" "$TASK_DIR" "$INIT_DIR"

# ── Binaries (verified copies from the shipped PAK) ──────────────────

cp "$SRC_PAK/bin/git" "$APP_DIR/bin/git"
cp "$SRC_PAK/libexec/git-core/git" "$APP_DIR/libexec/git-core/git"
cp "$SRC_PAK/libexec/git-core/git-remote-https" "$APP_DIR/libexec/git-core/git-remote-https"
cp "$SRC_PAK/libexec/git-core/git-remote-http" "$APP_DIR/libexec/git-core/git-remote-http"
cp "$SRC_PAK/share/ca-bundle.crt" "$APP_DIR/share/ca-bundle.crt"
if [ -f "$SRC_PAK/bin/busybox" ]; then
    cp "$SRC_PAK/bin/busybox" "$APP_DIR/bin/busybox"
fi
printf 'intentionally empty — silences git template warnings\n' \
    > "$APP_DIR/share/templates/.keep"

# ── Scripts ──────────────────────────────────────────────────────────

cp "$PLATFORM_DIR/continuity_daemon.sh" "$APP_DIR/scripts/"
cp "$PLATFORM_DIR/pal_muos.sh" "$APP_DIR/scripts/"
cp "$PLATFORM_DIR/enroll_sd_card.sh" "$APP_DIR/scripts/"
cp "$PLATFORM_DIR/preflight.sh" "$APP_DIR/scripts/"
cp "$PLATFORM_DIR/recon_device.sh" "$APP_DIR/scripts/"
for f in "$CORE_DIR"/*.sh; do
    [ -f "$f" ] && cp "$f" "$APP_DIR/scripts/core/"
done

# Task Toolkit entries — the on-device UI
cp "$PLATFORM_DIR/task_continuity.sh" "$TASK_DIR/Continuity.sh"
cp "$PLATFORM_DIR/recon_device.sh" "$TASK_DIR/Continuity Recon.sh"

# Boot hook — muOS runs MUOS/init/*.sh at boot when "User Init Scripts"
# is enabled (Advanced Settings); documented in the muxtweakadv module.
cp "$PLATFORM_DIR/init_continuity.sh" "$INIT_DIR/continuity.sh"

# ── Config ───────────────────────────────────────────────────────────

cp "$CONFIG_DIR/platform_maps/muos.json" "$APP_DIR/config/platform_maps/"
cp "$CONFIG_DIR/system_taxonomy.json" "$APP_DIR/config/"

# ── Version stamp (minute-granular: same-day builds must be
#    distinguishable on-device or "which build ran?" costs a card trip)

VERSION="0.1.0-muos-$(date '+%Y%m%d-%H%M')"
printf '%s\n' "$VERSION" > "$APP_DIR/version.txt"

# ── Checksums: preflight byte-verifies these on the device, so a
#    truncated card copy names itself instead of surfacing as git's
#    misleading "unable to find remote helper".

: > "$APP_DIR/checksums.txt"
for f in bin/git bin/busybox libexec/git-core/git \
         libexec/git-core/git-remote-https libexec/git-core/git-remote-http \
         share/ca-bundle.crt; do
    [ -f "$APP_DIR/$f" ] || continue
    printf '%s %s %s\n' \
        "$(sha256sum "$APP_DIR/$f" | cut -d' ' -f1)" \
        "$(wc -c < "$APP_DIR/$f")" \
        "$f" >> "$APP_DIR/checksums.txt"
done

# ── Permissions ──────────────────────────────────────────────────────

find "$OUT_DIR" -name "*.sh" -exec chmod +x {} +
chmod +x "$TASK_DIR/Continuity.sh" "$TASK_DIR/Continuity Recon.sh" \
         "$INIT_DIR/continuity.sh" \
         "$APP_DIR/bin/git" "$APP_DIR/libexec/git-core/git" \
         "$APP_DIR/libexec/git-core/git-remote-https" \
         "$APP_DIR/libexec/git-core/git-remote-http"
[ -f "$APP_DIR/bin/busybox" ] && chmod +x "$APP_DIR/bin/busybox"

# ── Line-ending sanity: CRLF in a script makes the kernel exec fail
#    with a cryptic error on-device; catch at build time.

cr=$(printf '\r')
crlf_files=$(find "$OUT_DIR" \( -name '*.sh' -o -name '*.json' -o -name '*.txt' \) \
                 -exec grep -l "$cr" {} + 2>/dev/null || true)
if [ -n "$crlf_files" ]; then
    printf 'ERROR: CRLF line endings detected:\n%s\n' "$crlf_files" >&2
    exit 1
fi

# ── Zip (the deliverable) — built from the staging root so extraction
#    onto the card root installs both .continuity/ and MUOS/ in place.

ZIP_FILE="$ZIP_DIR/Continuity-muos-$VERSION.zip"
rm -f "$ZIP_FILE"
if command -v zip >/dev/null 2>&1; then
    (cd "$OUT_DIR" && zip -qr "$ZIP_FILE" .)
elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, sys, zipfile
out, root = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for base, _, names in os.walk(root):
        for n in names:
            p = os.path.join(base, n)
            z.write(p, os.path.relpath(p, root))
' "$ZIP_FILE" "$OUT_DIR"
else
    printf 'ERROR: neither zip nor python3 available to build the archive\n' >&2
    exit 1
fi

# ── Summary ──────────────────────────────────────────────────────────

printf '\n=== Continuity muOS app assembled ===\n\n'
printf '  Version:  %s\n' "$VERSION"
printf '  Staging:  %s\n' "$OUT_DIR"
printf '  Zip:      %s (%s)\n' "$ZIP_FILE" "$(du -h "$ZIP_FILE" | cut -f1)"
printf '\n  Install: extract the zip onto the SD1 card ROOT (the card with\n'
printf '  the MUOS folder), then run Applications > Task Toolkit > Continuity.\n\n'
