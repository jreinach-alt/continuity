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
        grep "$(pm_save_or_state_grep_re)" || true
    return 0
}

# cd_list_repo_saves — list all save-class files in the repo working tree
# Usage: cd_list_repo_saves <repo_dir>
# Prints repo-relative paths, one per line. Excludes .git/ and .continuity/.
# Save class = .srm/.sav/.rtc (pm_find_saves). Returns 0 always.
cd_list_repo_saves() {
    local repo_dir
    repo_dir="$1"

    pm_find_saves "$repo_dir" \
        ! -path "*/.git/*" \
        ! -path "*/.continuity/*" | \
    while IFS= read -r abs_path; do
        printf '%s\n' "$abs_path" | sed "s|^$repo_dir/||"
    done
    return 0
}

# cd_list_device_saves — list all save-class files on the device
# Usage: cd_list_device_saves
# Prints absolute paths, one per line. Silently skips nonexistent dirs.
# Save class = .srm/.sav/.rtc (pm_find_saves). Returns 0 always.
cd_list_device_saves() {
    pm_list_watched_dirs | while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        [ -d "$dir" ] || continue
        pm_find_saves "$dir"
    done
    return 0
}

# cd_list_device_states — list savestate files on the device across ALL
# five NextUI state name-shapes (matrix §4): .st[0-9], .state, .state[0-9],
# .state.[0-9], .state.auto (pm_find_states). Four of the five were never
# backed up before Sprint 2.0.
# Prints absolute paths, one per line. Empty when CONTINUITY_STATES_ROOT
# is unset (platform without state backup) or the dir is absent.
# Oversized states (>CONTINUITY_STATE_MAX_KB, default 65536 = 64 MB)
# are skipped with a log line — the gate exists so a pathological
# snapshot can't bloat the save repo. 64 MB clears every fleet core
# today (snes9x ~800 KB, mGBA ~400 KB, Mupen64 ~16-25 MB, Flycast
# ~30 MB) while staying under GitHub's 100 MB hard limit; owner-raised
# from 8 MB (2026-07-09) when the RG40XX V's N64/Dreamcast states all
# hit the old default.
# cd_state_size_ok — shared size gate for state files.
# A skipped state never reaches the repo, so it re-candidates on EVERY
# scan — warn once per file per daemon run (field defect on the
# RG40XX V: 9 identical warnings per 30s poll, unbounded log). The
# warned-ledger is a per-process temp file because scans run in
# pipeline subshells where shell variables don't persist.
cd_state_size_ok() {
    local max_kb ledger
    max_kb="${CONTINUITY_STATE_MAX_KB:-65536}"
    if [ "$(cat "$1" 2>/dev/null | wc -c)" -gt $((max_kb * 1024)) ]; then
        ledger="${CONTINUITY_STATE_WARN_CACHE:-${TMPDIR:-/tmp}/continuity_state_warned.$$}"
        if ! grep -qxF -e "$1" "$ledger" 2>/dev/null; then
            pal_log "warn" "State too large (>${max_kb} KB), skipping: $1"
            printf '%s\n' "$1" >> "$ledger" 2>/dev/null || true
        fi
        return 1
    fi
    return 0
}

cd_list_device_states() {
    [ -n "$CONTINUITY_STATES_ROOT" ] || return 0
    [ -d "$CONTINUITY_STATES_ROOT" ] || return 0
    pm_find_states "$CONTINUITY_STATES_ROOT" | \
    while IFS= read -r f; do
        cd_state_size_ok "$f" || continue
        printf '%s\n' "$f"
    done
    return 0
}
