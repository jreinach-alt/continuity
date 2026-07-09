#!/bin/sh
# Assemble Continuity.pak from source files and cross-compiled git binary.
# Output: build/Continuity.pak/ — ready to copy to SD card Tools/ directory.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PAK_DIR="$PROJECT_ROOT/build/Continuity.pak"
PREFIX="$PROJECT_ROOT/build/aarch64/prefix"
GIT_BIN="$PREFIX/bin/git"
GIT_HTTPS_HELPER="$PREFIX/libexec/git-core/git-remote-https"
BUSYBOX_BIN="$PREFIX/bin/busybox"
PLATFORM_DIR="$PROJECT_ROOT/src/platforms/nextui"
CORE_DIR="$PROJECT_ROOT/src/core"
CONFIG_DIR="$PROJECT_ROOT/config"

# Fall back to the previously-bundled binaries if a fresh cross-compile
# isn't available. Lets us iterate on launch.sh / scripts without rebuilding
# git from scratch. Stage them outside $PAK_DIR so the rm -rf below can't
# eat them.
if [ ! -f "$GIT_BIN" ] && [ -f "$PAK_DIR/bin/git" ]; then
    GIT_BIN="$PROJECT_ROOT/build/git.preserved"
    cp "$PAK_DIR/bin/git" "$GIT_BIN"
fi
if [ ! -f "$GIT_HTTPS_HELPER" ] && [ -f "$PAK_DIR/libexec/git-core/git-remote-https" ]; then
    GIT_HTTPS_HELPER="$PROJECT_ROOT/build/git-remote-https.preserved"
    cp "$PAK_DIR/libexec/git-core/git-remote-https" "$GIT_HTTPS_HELPER"
fi
if [ ! -f "$BUSYBOX_BIN" ] && [ -f "$PAK_DIR/bin/busybox" ]; then
    BUSYBOX_BIN="$PROJECT_ROOT/build/busybox.preserved"
    cp "$PAK_DIR/bin/busybox" "$BUSYBOX_BIN"
fi

if [ ! -f "$GIT_BIN" ]; then
    printf 'ERROR: Git binary not found at %s or %s\n' \
        "$PREFIX/bin/git" "$PAK_DIR/bin/git" >&2
    printf 'Run scripts/build_git.sh first.\n' >&2
    exit 1
fi

# HTTPS transport is a separate helper program git exec's at runtime.
# A PAK without it fails enrollment with "unable to find remote helper
# for 'https'" — the exact on-device failure this guard prevents.
if [ ! -f "$GIT_HTTPS_HELPER" ]; then
    printf 'ERROR: git-remote-https not found at %s\n' "$GIT_HTTPS_HELPER" >&2
    printf 'Run scripts/build_git.sh first (it builds the https helper).\n' >&2
    exit 1
fi

# Vendored BusyBox: the daemon's pinned interpreter (fail-open — the
# daemon self-tests it and falls back to the device shell, and launch.sh
# never depends on it). Unlike git it is not launch-critical, so a
# missing binary is a loud warning, not a build failure.
if [ ! -f "$BUSYBOX_BIN" ]; then
    printf 'WARNING: busybox not found at %s\n' "$PREFIX/bin/busybox" >&2
    printf 'Run scripts/build_busybox.sh to include the pinned interpreter.\n' >&2
    BUSYBOX_BIN=""
fi

# CA bundle for TLS verification: git's baked-in path points at the build
# container. Ship the pristine Mozilla bundle from curl.se — NOT the build
# host's system bundle, which may contain environment-specific CAs (e.g.
# a corporate or CI TLS proxy) that must never be trusted on user devices.
CA_BUNDLE="$PROJECT_ROOT/build/cacert.pem"
if [ ! -s "$CA_BUNDLE" ]; then
    printf 'Fetching Mozilla CA bundle from curl.se...\n'
    curl -fsSL -o "$CA_BUNDLE" "https://curl.se/ca/cacert.pem" || true
fi
if [ ! -s "$CA_BUNDLE" ] && [ -s "$PAK_DIR/share/ca-bundle.crt" ]; then
    CA_BUNDLE="$PROJECT_ROOT/build/ca-bundle.preserved"
    cp "$PAK_DIR/share/ca-bundle.crt" "$CA_BUNDLE"
fi
if [ ! -s "$CA_BUNDLE" ]; then
    printf 'ERROR: no CA bundle — curl.se unreachable and no preserved copy.\n' >&2
    exit 1
fi

# Clean and create PAK structure
rm -rf "$PAK_DIR"
mkdir -p "$PAK_DIR/bin"
mkdir -p "$PAK_DIR/libexec/git-core"
mkdir -p "$PAK_DIR/share/templates"
mkdir -p "$PAK_DIR/scripts/core"
mkdir -p "$PAK_DIR/config/platform_maps"

# ── Copy files ───────────────────────────────────────────────────────

# Git binary + https helper + CA bundle + empty template dir marker
cp "$GIT_BIN" "$PAK_DIR/bin/git"
cp "$GIT_HTTPS_HELPER" "$PAK_DIR/libexec/git-core/git-remote-https"
# http:// URLs use the same helper under a different name; exFAT has no
# symlinks, so ship a copy
cp "$GIT_HTTPS_HELPER" "$PAK_DIR/libexec/git-core/git-remote-http"
# git spawns remote helpers as `git remote-https ...` (transport-helper.c
# sets git_cmd=1) — the exec path must therefore contain `git` ITSELF,
# exactly like a standard install's libexec/git-core. Without this copy,
# devices with no system git fail every https operation with the
# misleading "unable to find remote helper for 'https'".
cp "$GIT_BIN" "$PAK_DIR/libexec/git-core/git"
cp "$CA_BUNDLE" "$PAK_DIR/share/ca-bundle.crt"
printf 'intentionally empty — silences git template warnings\n' \
    > "$PAK_DIR/share/templates/.keep"

# Vendored BusyBox — the daemon's pinned interpreter (see build_busybox.sh)
if [ -n "$BUSYBOX_BIN" ]; then
    cp "$BUSYBOX_BIN" "$PAK_DIR/bin/busybox"
fi

# PAK root: launch.sh (Tool menu entry point)
cp "$PLATFORM_DIR/launch.sh" "$PAK_DIR/launch.sh"

# Scripts: daemon and platform modules
cp "$PLATFORM_DIR/continuity_daemon.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/pal_nextui.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/enroll_sd_card.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/enroll_ui.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/preflight.sh" "$PAK_DIR/scripts/"
cp "$PLATFORM_DIR/update.sh" "$PAK_DIR/scripts/"

# Core modules
for f in "$CORE_DIR"/*.sh; do
    [ -f "$f" ] && cp "$f" "$PAK_DIR/scripts/core/"
done

# Config
cp "$CONFIG_DIR/platform_maps/nextui.json" "$PAK_DIR/config/platform_maps/"

# System taxonomy (needed by path_mapper)
cp "$CONFIG_DIR/system_taxonomy.json" "$PAK_DIR/config/"

# Version file
# Minute-granular stamp: same-day rebuilds must be distinguishable on
# the device screen, or "which build ran?" costs an SD-card round-trip.
printf '%s\n' "0.1.0-$(date '+%Y%m%d-%H%M')" > "$PAK_DIR/version.txt"

# OTA channel SEED: the durable channel name a fresh device adopts on
# first run (.continuity/ota_channel). Channels are entries in
# release/channels.json on main — never branch names. Card images for
# release users can be built with CONTINUITY_BUILD_CHANNEL=stable.
printf '%s\n' "${CONTINUITY_BUILD_CHANNEL:-nightly}" > "$PAK_DIR/ota_channel.txt"

# Checksums for the binaries: the preflight doctor verifies these on the
# device, so a truncated/corrupted SD-card copy names itself on screen
# instead of surfacing as git's misleading "unable to find remote helper".
# Format: <sha256> <bytes> <pak-relative-path>
: > "$PAK_DIR/checksums.txt"
for f in bin/git bin/busybox libexec/git-core/git libexec/git-core/git-remote-https \
         libexec/git-core/git-remote-http share/ca-bundle.crt; do
    [ -f "$PAK_DIR/$f" ] || continue
    printf '%s %s %s\n' \
        "$(sha256sum "$PAK_DIR/$f" | cut -d' ' -f1)" \
        "$(wc -c < "$PAK_DIR/$f")" \
        "$f" >> "$PAK_DIR/checksums.txt"
done

# ── Permissions ──────────────────────────────────────────────────────

find "$PAK_DIR" -name "*.sh" -exec chmod +x {} +
chmod +x "$PAK_DIR/bin/git" \
         "$PAK_DIR/libexec/git-core/git" \
         "$PAK_DIR/libexec/git-core/git-remote-https" \
         "$PAK_DIR/libexec/git-core/git-remote-http"
if [ -f "$PAK_DIR/bin/busybox" ]; then
    chmod +x "$PAK_DIR/bin/busybox"
fi

# ── Line-ending sanity check ─────────────────────────────────────────
# CRLF in any shell script makes the kernel exec fail silently on the
# device (it reads `#!/bin/sh\r` as the interpreter path). Catch this
# at build time, not after the user has copied the PAK to their SD card.

cr=$(printf '\r')
crlf_files=$(find "$PAK_DIR" \( -name '*.sh' -o -name '*.json' -o -name '*.txt' \) \
                 -exec grep -l "$cr" {} + 2>/dev/null || true)
if [ -n "$crlf_files" ]; then
    printf 'ERROR: CRLF line endings detected in PAK files:\n' >&2
    printf '  %s\n' $crlf_files >&2
    printf 'NextUI cannot exec scripts with CRLF; fix the source and rebuild.\n' >&2
    exit 1
fi

# ── Summary ──────────────────────────────────────────────────────────

file_count=$(find "$PAK_DIR" -type f | wc -l)
total_size=$(du -sh "$PAK_DIR" | cut -f1)

printf '\n=== Continuity.pak assembled ===\n\n'
printf '  Location: %s\n' "$PAK_DIR"
printf '  Files:    %s\n' "$file_count"
printf '  Size:     %s\n' "$total_size"
printf '\n  Structure:\n'
find "$PAK_DIR" -type f | sort | while read -r f; do
    printf '    %s\n' "${f#"$PROJECT_ROOT"/build/}"
done

printf '\n  Deploy: cp -r %s /path/to/sdcard/Tools/tg5040/\n\n' "$PAK_DIR"
