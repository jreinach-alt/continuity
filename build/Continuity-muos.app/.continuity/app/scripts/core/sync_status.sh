#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Sync Status — notification helper and last-status file management
#
# Provides ss_notify (centralized notification dispatch) and
# ss_get_last_status (query the last notification).
#
# Required modules (must be sourced by caller):
#   PAL: pal_log()
#   cold_start: (for $repo_dir/.continuity directory)

# ss_notify — fire a notification, write last-status file, log
# Usage: ss_notify <repo_dir> <level> <message>
# level: green, yellow, red
# Returns: 0 always
ss_notify() {
    local repo_dir level message
    repo_dir="$1"
    level="$2"
    message="$3"

    # Ensure .continuity dir exists
    mkdir -p "$repo_dir/.continuity"

    # Create .continuity/.gitignore if absent (PF-4)
    local gi_file
    gi_file="$repo_dir/.continuity/.gitignore"
    if [ ! -f "$gi_file" ]; then
        printf 'sentinel\nlast_known_commit\nlast_status\n' > "$gi_file"
    fi

    # Write last-status file atomically (write to temp, mv into place)
    local timestamp tmp_file
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
    tmp_file="$repo_dir/.continuity/last_status.tmp.$$"
    printf 'level=%s\nmessage=%s\ntimestamp=%s\n' "$level" "$message" "$timestamp" \
        > "$tmp_file"
    mv "$tmp_file" "$repo_dir/.continuity/last_status"

    # Call PAL hook if defined
    if command -v pal_on_sync_result >/dev/null 2>&1; then
        pal_on_sync_result "$level" "$message"
    fi

    # Log
    pal_log "info" "sync_status: [$level] $message"

    return 0
}

# ss_get_last_status — read the last notification
# Usage: ss_get_last_status <repo_dir>
# Prints key-value pairs to stdout. Returns: 0 always.
ss_get_last_status() {
    local repo_dir status_file
    repo_dir="$1"
    status_file="$repo_dir/.continuity/last_status"

    if [ -f "$status_file" ]; then
        cat "$status_file"
    else
        printf 'level=green\nmessage=Ready\ntimestamp=never\n'
    fi

    return 0
}
