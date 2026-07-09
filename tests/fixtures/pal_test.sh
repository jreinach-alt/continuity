#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# PAL implementation for automated testing
# Caller must set TEST_TMPDIR to an existing writable directory before sourcing.
# All paths point to temp directories. Always online. Deterministic device name.

CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/saves"
CONTINUITY_REPO_DIR="$TEST_TMPDIR/repo"
CONTINUITY_DEVICE_NAME="test-device"
CONTINUITY_PLATFORM="nextui"
CONTINUITY_GIT_BIN="git"
CONTINUITY_SD_ROOT="$TEST_TMPDIR/sdcard"

# pal_init — create save and repo directories
# Always returns 0. No hardware dependencies.
pal_init() {
    mkdir -p "$CONTINUITY_SAVES_ROOT" "$(dirname "$CONTINUITY_REPO_DIR")"
    return 0
}

# pal_is_online — always returns 0 (online)
# Override in specific tests to simulate offline: pal_is_online() { return 1; }
pal_is_online() {
    return 0
}

# pal_log — print test log message to stderr
# Usage: pal_log <level> <message>
pal_log() {
    printf '[TEST %s] %s\n' "$1" "$2" >&2
}

# pal_get_platform_map — print path to test platform map
# Caller must place a valid JSON at this path before calling pm_load_platform_map.
pal_get_platform_map() {
    printf '%s\n' "$TEST_TMPDIR/platform_map.json"
}

CONTINUITY_STATES_ROOT="${CONTINUITY_STATES_ROOT:-$TEST_TMPDIR/states}"
