#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# NextUI SD Card Enrollment Trigger — detect, parse, and import setup.json
# Requires the PAL, sync_engine, and enrollment to be loaded before sourcing.

# Module-level variables (set by esd_parse_setup_file)
_ESD_REPO_URL=""
_ESD_PAT=""
_ESD_DEVICE_NAME=""

# esd_detect_setup_file — check if setup.json exists on SD card
# Returns: 0 found, 1 not found
esd_detect_setup_file() {
    [ -f "$CONTINUITY_SD_ROOT/setup.json" ]
}

# esd_parse_setup_file — parse setup.json and set module variables
# Usage: esd_parse_setup_file <setup_file>
# Returns: 0 success, 1 parse error
esd_parse_setup_file() {
    local setup_file
    setup_file="$1"

    _ESD_REPO_URL=$(sed -n 's/^[[:space:]]*"repo_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$setup_file")
    _ESD_PAT=$(sed -n 's/^[[:space:]]*"pat"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$setup_file")
    _ESD_DEVICE_NAME=$(sed -n 's/^[[:space:]]*"device_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$setup_file")

    if [ -z "$_ESD_REPO_URL" ]; then
        pal_log "error" "setup.json: missing or empty repo_url"
        return 1
    fi
    if [ -z "$_ESD_PAT" ]; then
        pal_log "error" "setup.json: missing or empty pat"
        return 1
    fi
    if [ -z "$_ESD_DEVICE_NAME" ]; then
        pal_log "error" "setup.json: missing or empty device_name"
        return 1
    fi

    return 0
}

# esd_import — full SD card enrollment import
# Returns: 0 success (or no-op), 1 failure
# esd_lock_acquire / esd_lock_release — serialize enrollment.
# The boot daemon and the Tool PAK's interactive enrollment can run
# CONCURRENTLY (field-found: the daemon saw device_name mid-enrollment
# and raced into cold start against a half-pushed remote). mkdir is the
# atomic primitive; a started_at epoch inside detects stale locks from
# crashed enrollments.
# Test hooks: ESD_LOCK_WAIT_TICKS (default 60 × 2s), ESD_LOCK_STALE_SECONDS.
esd_lock_acquire() {
    local lock ticks started now
    lock="$CONTINUITY_SD_ROOT/.continuity/.enroll_lock"
    ticks="${ESD_LOCK_WAIT_TICKS:-60}"
    mkdir -p "$CONTINUITY_SD_ROOT/.continuity"

    while ! mkdir "$lock" 2>/dev/null; do
        started=$(cat "$lock/started_at" 2>/dev/null)
        now=$(date +%s)
        if [ -n "$started" ] && \
           [ $((now - started)) -gt "${ESD_LOCK_STALE_SECONDS:-600}" ]; then
            pal_log "warn" "Stealing stale enrollment lock (held ${started})"
            rm -rf "$lock"
            continue
        fi
        ticks=$((ticks - 1))
        if [ "$ticks" -le 0 ]; then
            pal_log "error" "Enrollment lock held by another process — giving up"
            return 1
        fi
        sleep 2
    done
    date +%s > "$lock/started_at"
    return 0
}

esd_lock_release() {
    rm -rf "$CONTINUITY_SD_ROOT/.continuity/.enroll_lock"
    return 0
}

# esd_import — serialize against a concurrent enrollment from the other
# entry point (boot daemon vs Tool PAK tap), then run the real import.
# Wrapper guarantees the lock is released on every return path.
esd_import() {
    local rc
    if ! esd_lock_acquire; then
        return 1
    fi
    rc=0
    _esd_import_locked || rc=$?
    esd_lock_release
    return "$rc"
}

_esd_import_locked() {
    # Hang-proof git for headless enrollment: never prompt for credentials
    # on a tty (a failed credential helper otherwise blocks forever on
    # /dev/tty — no keyboard exists on this device), and abort transfers
    # that stall below 1 KB/s for 30s (dead WiFi mid-clone).
    GIT_TERMINAL_PROMPT=0
    GIT_HTTP_LOW_SPEED_LIMIT=1000
    GIT_HTTP_LOW_SPEED_TIME=30
    export GIT_TERMINAL_PROMPT GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME

    # Belt against PAL wiring failures: the bundled git's helper and CA
    # paths are baked to the build container; re-default them here so
    # every enrollment git call can find its https machinery.
    if [ -d "$CONTINUITY_PAK_DIR/libexec/git-core" ]; then
        GIT_EXEC_PATH="${GIT_EXEC_PATH:-$CONTINUITY_PAK_DIR/libexec/git-core}"
        export GIT_EXEC_PATH
    fi
    if [ -f "$CONTINUITY_PAK_DIR/share/ca-bundle.crt" ]; then
        GIT_SSL_CAINFO="${GIT_SSL_CAINFO:-$CONTINUITY_PAK_DIR/share/ca-bundle.crt}"
        export GIT_SSL_CAINFO
    fi

    # Step 1: Detect setup file
    if ! esd_detect_setup_file; then
        return 0
    fi

    local setup_file
    setup_file="$CONTINUITY_SD_ROOT/setup.json"

    # Step 2: Parse setup file
    if ! esd_parse_setup_file "$setup_file"; then
        pal_log "error" "Failed to parse setup.json"
        return 1
    fi

    # Step 3: Check if already enrolled
    if enroll_is_enrolled; then
        pal_log "warn" "already enrolled, skipping setup.json"
        rm -f "$setup_file"
        return 0
    fi

    # Step 3b: Clear a stale partial clone. A crash or power-off mid-clone
    # leaves a repo dir without a device_name; git clone refuses to reuse
    # a non-empty target, which would poison every retry. Pre-enrollment,
    # the local clone holds nothing of value — the remote is the source
    # of truth — so removal is safe.
    if [ -n "$CONTINUITY_REPO_DIR" ] && [ -d "$CONTINUITY_REPO_DIR" ]; then
        pal_log "warn" "Removing stale partial clone at $CONTINUITY_REPO_DIR"
        rm -rf "$CONTINUITY_REPO_DIR"
    fi

    # Step 4: Run enrollment
    if ! enroll_run "$_ESD_REPO_URL" "$_ESD_DEVICE_NAME" "$_ESD_PAT"; then
        pal_log "error" "SD card enrollment failed"
        return 1
    fi

    # Step 5: Delete setup.json (PAT must not persist)
    rm -f "$setup_file"

    # Step 6: Log success
    pal_log "info" "SD card enrollment complete: $_ESD_DEVICE_NAME"
    return 0
}
