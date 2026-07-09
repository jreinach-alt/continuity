#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Change Detector — file enumeration helpers for Continuity sync flows
# Provides functions to list .srm files in the repo, on the device, and
# to detect changes in the repo working tree via git status.
# Requires the PAL and path mapper to be loaded before this file is sourced.

# cd_detect_changes — list .srm files changed in the repo working tree
# Usage: cd_detect_changes <repo_dir>
# Prints repo-relative paths of changed .srm files, one per line.
# Returns 0 always (empty output means no changes).
cd_detect_changes() {
    local repo_dir
    repo_dir="$1"

    # -z (NUL-delimited): git C-quotes paths containing spaces, quotes,
    # or non-ASCII in the default porcelain format — i.e. virtually every
    # real ROM name — and a trailing quote defeats the extension match.
    # The NUL format is never quoted. (Field-found: spaced saves were
    # copied into the repo tree but silently never staged, in every phase.)
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" status --porcelain -z -uall 2>/dev/null | \
        tr '\0' '\n' | \
        sed 's/^...//' | \
        grep '\.\(srm\|sav\|st[0-9]\)$' || true
    return 0
}

# cd_list_repo_saves — list all .srm files in the repo working tree
# Usage: cd_list_repo_saves <repo_dir>
# Prints repo-relative paths, one per line. Excludes .git/ and .continuity/.
# Returns 0 always (empty output means no .srm files).
cd_list_repo_saves() {
    local repo_dir
    repo_dir="$1"

    find "$repo_dir" \( -name "*.srm" -o -name "*.sav" \) \
        ! -path "*/.git/*" \
        ! -path "*/.continuity/*" 2>/dev/null | \
    while IFS= read -r abs_path; do
        printf '%s\n' "$abs_path" | sed "s|^$repo_dir/||"
    done
    return 0
}

# cd_list_device_saves — list all .srm files on the device
# Usage: cd_list_device_saves
# Prints absolute paths, one per line. Silently skips nonexistent dirs.
# Returns 0 always (empty output means no .srm files).
cd_list_device_saves() {
    pm_list_watched_dirs | while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        [ -d "$dir" ] || continue
        find "$dir" \( -name "*.srm" -o -name "*.sav" \) 2>/dev/null
    done
    return 0
}

# cd_list_device_states — list savestate files (.st0-.st9) on the device.
# Prints absolute paths, one per line. Empty when CONTINUITY_STATES_ROOT
# is unset (platform without state backup) or the dir is absent.
# Oversized states (>CONTINUITY_STATE_MAX_KB, default 8192) are skipped
# with a log line — some cores write 100MB+ snapshots that don't belong
# in a save repo.
# cd_state_size_ok — shared size gate for state files (default 8 MB;
# some cores write 100MB+ snapshots that don't belong in a save repo).
cd_state_size_ok() {
    local max_kb
    max_kb="${CONTINUITY_STATE_MAX_KB:-8192}"
    if [ "$(cat "$1" 2>/dev/null | wc -c)" -gt $((max_kb * 1024)) ]; then
        pal_log "warn" "State too large, skipping: $1"
        return 1
    fi
    return 0
}

cd_list_device_states() {
    [ -n "$CONTINUITY_STATES_ROOT" ] || return 0
    [ -d "$CONTINUITY_STATES_ROOT" ] || return 0
    find "$CONTINUITY_STATES_ROOT" -name "*.st[0-9]" 2>/dev/null | \
    while IFS= read -r f; do
        cd_state_size_ok "$f" || continue
        printf '%s\n' "$f"
    done
    return 0
}
