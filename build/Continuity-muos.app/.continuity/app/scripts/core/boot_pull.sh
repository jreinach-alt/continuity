#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Boot Pull — steady-state boot sync for Continuity
#
# Pulls remote changes since the last known commit, applies only
# changed .srm files to the device, updates the stored commit hash,
# and touches the sentinel so the runtime poll has a clean baseline.
#
# Prerequisites:
#   - PAL loaded and validated (provides CONTINUITY_GIT_BIN, pal_log, etc.)
#   - src/core/cold_start.sh sourced (provides cs_read_commit, cs_store_commit)
#   - src/core/sync_engine.sh sourced (provides se_pull, se_get_head_commit)
#   - src/core/path_mapper.sh sourced and platform map loaded (provides pm_repo_to_local)
#
# Public functions: bp_run, bp_get_remote_changes, bp_apply_remote_saves

# bp_get_remote_changes — list save files changed between old_commit and HEAD
# Usage: bp_get_remote_changes <repo_dir> <old_commit>
# Prints repo-relative save-class paths (.srm/.sav/.rtc), one per line.
# Returns: 0 on success, 1 if git diff fails.
bp_get_remote_changes() {
    local repo_dir old_commit _bp_tmp rc_diff
    repo_dir="$1"
    old_commit="$2"

    # -z: diff --name-only C-quotes spaced/non-ASCII paths (the
    # porcelain-quoting trap); NUL output is never quoted. Temp file
    # keeps git's exit code observable without pipefail.
    _bp_tmp=$(mktemp)
    rc_diff=0
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" diff --name-only -z "$old_commit"..HEAD \
        >"$_bp_tmp" 2>/dev/null || rc_diff=$?
    if [ "$rc_diff" -ne 0 ]; then
        rm -f "$_bp_tmp"
        return 1
    fi

    # Save class only (.srm/.sav/.rtc) — states are one-way device -> repo
    # and are never applied back to a device on boot pull.
    tr '\0' '\n' < "$_bp_tmp" | grep "$(pm_save_grep_re)" || true
    rm -f "$_bp_tmp"
    return 0
}

# bp_apply_remote_saves — copy changed .srm files from repo to device
# Usage: bp_apply_remote_saves <repo_dir> <changed_files>
# changed_files is a newline-delimited string of repo-relative paths.
# Returns: 0 on success, 1 on copy failure.
# Skips files deleted on remote (not present in repo working tree).
# Logs warning and continues on pm_repo_to_local failure; returns 1 after all files processed.
bp_apply_remote_saves() {
    local repo_dir changed_files
    repo_dir="$1"
    changed_files="$2"

    if [ -z "$changed_files" ]; then
        return 0
    fi

    local failure_file
    failure_file=$(mktemp)
    printf '' > "$failure_file"

    printf '%s\n' "$changed_files" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue

        # Skip files deleted on remote
        if [ ! -f "$repo_dir/$repo_path" ]; then
            pal_log "info" "Boot pull: $repo_path deleted on remote, skipping copy"
            continue
        fi

        local local_path rc_map
        rc_map=0
        local_path=$(pm_canonical_to_device "$repo_path" 2>/dev/null) || rc_map=$?
        if [ "$rc_map" -eq 2 ]; then
            # No matching ROM on this device — sparse sync, NOT a failure.
            pal_log "info" "Boot pull: no ROM for $repo_path — not materialized"
            continue
        fi
        if [ "$rc_map" -ne 0 ] || [ -z "$local_path" ]; then
            pal_log "warn" "Boot pull: unrecognized system in $repo_path, skipping"
            printf 'map_fail\n' >> "$failure_file"
            continue
        fi

        mkdir -p "$(dirname "$local_path")"
        if ! cp "$repo_dir/$repo_path" "$local_path"; then
            pal_log "error" "Boot pull: failed to copy $repo_path to $local_path"
            printf 'cp_fail\n' > "$failure_file"
            break
        fi
        pal_log "info" "Boot pull: applied $repo_path"
    done

    local had_failure
    had_failure=$(cat "$failure_file")
    rm -f "$failure_file"
    if [ -n "$had_failure" ]; then
        return 1
    fi
    return 0
}

# bp_run — full boot pull flow
# Usage: bp_run <repo_dir>
# Returns: 0 success/no-op, 1 unrecoverable error, 2 network error
bp_run() {
    local repo_dir old_commit
    repo_dir="$1"

    # Step 1: Read stored commit
    old_commit=$(cs_read_commit "$repo_dir") || true
    if [ -z "$old_commit" ]; then
        pal_log "warn" "No stored commit found — cold start may not have run"
        return 1
    fi

    # Step 2: Pull from remote
    local pull_rc
    pull_rc=0
    se_pull "$repo_dir" || pull_rc=$?
    if [ "$pull_rc" -eq 2 ]; then
        pal_log "warn" "Boot pull skipped — network unavailable"
        return 2
    elif [ "$pull_rc" -eq 1 ]; then
        if ! ch_handle_pull_conflict "$repo_dir"; then
            pal_log "error" "Boot pull: conflict handler failed"
            if command -v ss_notify >/dev/null 2>&1; then
                ss_notify "$repo_dir" "red" "Sync error — conflict handler failed"
            fi
            return 1
        fi
        if command -v ss_notify >/dev/null 2>&1; then
            local conflict_count
            conflict_count=$(ch_count_conflicts "$repo_dir")
            ss_notify "$repo_dir" "red" "$conflict_count conflict(s) — action required"
        fi
        return 0
    fi

    # Step 3: Get new HEAD
    local new_commit
    new_commit=$(se_get_head_commit "$repo_dir")

    # Step 4: No-op if no remote changes
    if [ "$old_commit" = "$new_commit" ]; then
        pal_log "info" "Boot pull: no remote changes since last sync"
        touch "$repo_dir/.continuity/sentinel"
        return 0
    fi

    # Step 5: Get changed .srm files
    local changed_files rc_diff
    rc_diff=0
    changed_files=$(bp_get_remote_changes "$repo_dir" "$old_commit") || rc_diff=$?
    if [ "$rc_diff" -ne 0 ]; then
        pal_log "error" "Boot pull: failed to determine changed files"
        return 1
    fi

    # Step 6: No .srm changes
    if [ -z "$changed_files" ]; then
        pal_log "info" "Boot pull: remote changes contain no .srm files"
        cs_store_commit "$repo_dir" "$new_commit"
        touch "$repo_dir/.continuity/sentinel"
        return 0
    fi

    # Step 7: Apply saves
    if ! bp_apply_remote_saves "$repo_dir" "$changed_files"; then
        pal_log "error" "Boot pull: failed to apply one or more saves"
        return 1
    fi

    # Step 8: Update stored commit
    cs_store_commit "$repo_dir" "$new_commit"

    # Step 9: Touch sentinel
    touch "$repo_dir/.continuity/sentinel"

    # Step 10: Done
    pal_log "info" "Boot pull complete"
    return 0
}
