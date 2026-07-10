#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# PAL implementation for muOS (Anbernic RG40XX V and H700 siblings).
# BusyBox ash compatible. exFAT user partition (no symlinks). No system
# git — the app dir bundles the static aarch64 git, as on the Brick.
#
# Version Support Policy (Sprint 3.1, owner requirement): fleet muOS
# versions are unknown and devices misreport their own version, so
# NOTHING here branches on a version string. Every muOS-provided path
# resolves by existence probe with a fallback chain, and pal_init logs
# each resolution so the diagnostic always shows what an older/newer
# layout resolved to. Pre-set environment always wins (test sandboxes).

# muos_resolve_path <candidate>... — first existing directory wins;
# falls back to the LAST candidate when none exists yet (so paths are
# still well-formed on a fresh device before RetroArch created them).
muos_resolve_path() {
    local last
    for last in "$@"; do
        if [ -d "$last" ]; then
            printf '%s\n' "$last"
            return 0
        fi
    done
    printf '%s\n' "$last"
}

# The user-visible exFAT partition (what a PC card reader sees).
CONTINUITY_SD_ROOT="${CONTINUITY_SD_ROOT:-/mnt/mmc}"

# muOS system mount roots — env-defaulted so layout-variant fixtures can
# relocate them (unprivileged tests cannot create /run/muos).
CONTINUITY_MUOS_RUNROOT="${CONTINUITY_MUOS_RUNROOT:-/run/muos}"
CONTINUITY_MUOS_UNION="${CONTINUITY_MUOS_UNION:-/mnt/union}"

# Saves root: prefer muOS's stable storage indirection, fall back to the
# direct SD1 path (layout variants across releases).
CONTINUITY_SAVES_ROOT="${CONTINUITY_SAVES_ROOT:-$(muos_resolve_path \
    "$CONTINUITY_MUOS_RUNROOT/storage/save/file" "$CONTINUITY_SD_ROOT/MUOS/save/file")}"

# Save states (opaque one-way backup; empty disables)
CONTINUITY_STATES_ROOT="${CONTINUITY_STATES_ROOT:-$(muos_resolve_path \
    "$CONTINUITY_MUOS_RUNROOT/storage/save/state" "$CONTINUITY_SD_ROOT/MUOS/save/state")}"

# ROM root (ROM-anchored identity): the unionfs merge of SD1+SD2 when
# present, else SD1's ROMS directly.
CONTINUITY_ROMS_ROOT="${CONTINUITY_ROMS_ROOT:-$(muos_resolve_path \
    "$CONTINUITY_MUOS_UNION/ROMS" "$CONTINUITY_SD_ROOT/ROMS")}"

CONTINUITY_REPO_DIR="${CONTINUITY_REPO_DIR:-$CONTINUITY_SD_ROOT/.continuity/repo}"
CONTINUITY_PLATFORM="muos"

# The app's on-card location (analogue of the NextUI PAK dir). The
# daemon exports CONTINUITY_APP_DIR from its own script path; fall back
# to the standard install location when sourced outside the daemon.
CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$CONTINUITY_SD_ROOT/.continuity/app}"
CONTINUITY_GIT_BIN="${CONTINUITY_GIT_BIN:-$CONTINUITY_APP_DIR/bin/git}"

# The cross-compiled git has build-container paths baked in for its
# helper programs (git-remote-https), templates, and CA bundle. Point
# all three at the app's own copies — guarded on existence, and
# pre-set environment wins so test sandboxes running the system git
# keep its real exec path.
if [ -d "$CONTINUITY_APP_DIR/libexec/git-core" ]; then
    GIT_EXEC_PATH="${GIT_EXEC_PATH:-$CONTINUITY_APP_DIR/libexec/git-core}"
    export GIT_EXEC_PATH
fi
if [ -f "$CONTINUITY_APP_DIR/share/ca-bundle.crt" ]; then
    GIT_SSL_CAINFO="${GIT_SSL_CAINFO:-$CONTINUITY_APP_DIR/share/ca-bundle.crt}"
    export GIT_SSL_CAINFO
fi
if [ -d "$CONTINUITY_APP_DIR/share/templates" ]; then
    GIT_TEMPLATE_DIR="${GIT_TEMPLATE_DIR:-$CONTINUITY_APP_DIR/share/templates}"
    export GIT_TEMPLATE_DIR
fi
# Belt: git re-invokes ITSELF (`git remote-https ...`) to spawn transport
# helpers; make sure a `git` is findable by name even if exec-path
# resolution misbehaves. Guarded on the real binary so test sandboxes
# (which have no bin/git) keep their system git.
if [ -x "$CONTINUITY_APP_DIR/bin/git" ]; then
    PATH="$CONTINUITY_APP_DIR/bin:$PATH"
    export PATH
fi

# pal_init — read device name from enrollment config, verify git binary,
# and log every Version-Support-Policy path resolution (the choices are
# invisible failures otherwise: a wrong root just scans nothing).
pal_init() {
    local config_file
    config_file="$CONTINUITY_REPO_DIR/.continuity/device_name"
    if [ -f "$config_file" ]; then
        CONTINUITY_DEVICE_NAME=$(cat "$config_file")
    else
        pal_log "error" "No device name found — enrollment incomplete?"
        return 1
    fi

    # Verify git binary exists
    if [ ! -x "$CONTINUITY_GIT_BIN" ]; then
        pal_log "error" "Git binary not found at $CONTINUITY_GIT_BIN"
        return 1
    fi

    pal_log "info" "muOS path resolution: saves=$CONTINUITY_SAVES_ROOT states=$CONTINUITY_STATES_ROOT roms=$CONTINUITY_ROMS_ROOT"
    return 0
}

# pal_is_online — check network reachability to GitHub
# Tries ping first, falls back to wget if ping unavailable.
# CONTINUITY_FORCE_ONLINE=1 short-circuits to online (test sandboxes and
# on-device debugging behind ICMP-blocking networks).
pal_is_online() {
    if [ -n "$CONTINUITY_FORCE_ONLINE" ]; then
        return 0
    fi
    ping -c 1 -W 3 github.com >/dev/null 2>&1 ||
    wget --spider -q -T 3 https://github.com 2>/dev/null
}

# pal_log — log a message at the given level to stderr
# Usage: pal_log <level> <message>
pal_log() {
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

# pal_get_platform_map — print the absolute path to the muOS platform map
pal_get_platform_map() {
    printf '%s\n' "$CONTINUITY_APP_DIR/config/platform_maps/muos.json"
}
