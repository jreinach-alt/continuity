#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# PAL interface validator
# Checks that all required PAL variables and functions are defined.
# Does NOT source or load any PAL — only validates one has been sourced.

# pal_validate — check that the PAL interface is complete
# Verifies all 5 required variables are set and all 4 required functions
# are defined. Accumulates all missing items and prints them in a single
# error message to stderr. Returns 0 if valid, 1 if anything is missing.
pal_validate() {
    local missing
    missing=""

    # Check required variables
    [ -z "$CONTINUITY_SAVES_ROOT" ] && missing="$missing CONTINUITY_SAVES_ROOT"
    [ -z "$CONTINUITY_REPO_DIR" ] && missing="$missing CONTINUITY_REPO_DIR"
    [ -z "$CONTINUITY_DEVICE_NAME" ] && missing="$missing CONTINUITY_DEVICE_NAME"
    [ -z "$CONTINUITY_PLATFORM" ] && missing="$missing CONTINUITY_PLATFORM"
    [ -z "$CONTINUITY_GIT_BIN" ] && missing="$missing CONTINUITY_GIT_BIN"

    # Check required functions
    command -v pal_init >/dev/null 2>&1 || missing="$missing pal_init()"
    command -v pal_is_online >/dev/null 2>&1 || missing="$missing pal_is_online()"
    command -v pal_log >/dev/null 2>&1 || missing="$missing pal_log()"
    command -v pal_get_platform_map >/dev/null 2>&1 || missing="$missing pal_get_platform_map()"

    if [ -n "$missing" ]; then
        printf 'PAL validation failed. Missing:%s\n' "$missing" >&2
        return 1
    fi
    return 0
}
