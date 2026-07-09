#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Stale Boot Recovery — sync phase for unclean shutdown recovery
#
# When a device boots with a sentinel present but no clean shutdown marker,
# the previous session ended abnormally (crash, battery loss, kill).
# This module recovers by: pushing any pending local commits, pulling
# remote changes, then scanning all device saves for uncommitted changes.
#
# Prerequisites:
#   - PAL loaded and validated (provides CONTINUITY_GIT_BIN, CONTINUITY_DEVICE_NAME,
#     pal_is_online(), pal_log())
#   - src/core/path_mapper.sh sourced and platform map loaded (pm_local_to_repo())
#   - src/core/sync_engine.sh sourced and initialized (se_pull, se_push,
#     se_stage_files, se_commit, se_has_unpushed_commits, se_get_head_commit)
#   - src/core/cold_start.sh sourced (cs_read_commit, cs_store_commit)
#   - src/core/boot_pull.sh sourced (bp_get_remote_changes, bp_apply_remote_saves)
#   - src/core/change_detector.sh sourced (cd_detect_changes, cd_list_device_saves)
#   - src/core/runtime_poll.sh sourced (rp_update_sentinel)
#
# Public functions: sb_run, sb_is_stale, sb_mark_clean_shutdown, sb_clear_shutdown_marker

# sb_is_stale — check if stale boot recovery is needed
# Usage: sb_is_stale <repo_dir>
# Returns: 0 if stale (sentinel present, clean shutdown marker absent)
#          1 if not stale (sentinel absent, or clean shutdown marker present)
sb_is_stale() {
    local repo_dir
    repo_dir="$1"
    [ -f "$repo_dir/.continuity/sentinel" ] && [ ! -f "$repo_dir/.continuity/clean_shutdown" ]
}

# sb_mark_clean_shutdown — create the clean shutdown marker
# Usage: sb_mark_clean_shutdown <repo_dir>
# Returns: 0 on success, 1 on error
sb_mark_clean_shutdown() {
    local repo_dir
    repo_dir="$1"
    if ! mkdir -p "$repo_dir/.continuity"; then
        return 1
    fi
    if ! date '+%Y-%m-%dT%H:%M:%S' > "$repo_dir/.continuity/clean_shutdown"; then
        return 1
    fi
    return 0
}

# sb_clear_shutdown_marker — remove the clean shutdown marker (idempotent)
# Usage: sb_clear_shutdown_marker <repo_dir>
# Returns: 0 on success (including when file did not exist), 1 if removal failed
sb_clear_shutdown_marker() {
    local repo_dir marker
    repo_dir="$1"
    marker="$repo_dir/.continuity/clean_shutdown"
    if [ -f "$marker" ]; then
        if ! rm -f "$marker"; then
            return 1
        fi
    fi
    return 0
}

# sb_run — full stale boot recovery flow
# Usage: sb_run <repo_dir>
# Returns: 0 on success/no-op, 1 on unrecoverable error
sb_run() {
    local repo_dir
    repo_dir="$1"

    # Step 1: Clear shutdown marker — we are in recovery now
    sb_clear_shutdown_marker "$repo_dir"

    # Step 2: Push any pending commits from the interrupted session
    if pal_is_online; then
        local unpushed_rc
        unpushed_rc=0
        se_has_unpushed_commits "$repo_dir" || unpushed_rc=$?
        if [ "$unpushed_rc" -eq 0 ]; then
            local push_rc
            push_rc=0
            se_push "$repo_dir" || push_rc=$?
            if [ "$push_rc" -eq 1 ]; then
                pal_log "warn" "Stale boot: push of interrupted session commits failed — continuing"
            elif [ "$push_rc" -eq 2 ]; then
                pal_log "warn" "Stale boot: went offline during push of interrupted session — continuing"
            elif [ "$push_rc" -eq 0 ]; then
                pal_log "info" "Stale boot: pushed commits from interrupted session"
            fi
        fi
    fi

    # Step 3: Inbound pull phase
    local old_commit
    old_commit=$(cs_read_commit "$repo_dir") || true
    if [ -z "$old_commit" ]; then
        pal_log "warn" "Stale boot: no stored commit — cold start may not have run"
        return 1
    fi

    local pull_rc
    pull_rc=0
    se_pull "$repo_dir" || pull_rc=$?
    if [ "$pull_rc" -eq 2 ]; then
        pal_log "warn" "Stale boot: offline — pull skipped, proceeding with local repo state"
    elif [ "$pull_rc" -eq 1 ]; then
        if ! ch_handle_pull_conflict "$repo_dir"; then
            pal_log "error" "Stale boot: conflict handler failed"
            return 1
        fi
    fi

    local new_commit
    new_commit=$(se_get_head_commit "$repo_dir")

    if [ "$old_commit" != "$new_commit" ]; then
        local changed_files rc_changes
        rc_changes=0
        changed_files=$(bp_get_remote_changes "$repo_dir" "$old_commit") || rc_changes=$?
        if [ "$rc_changes" -ne 0 ]; then
            pal_log "error" "Stale boot: failed to determine remote changes"
            return 1
        fi
        if [ -n "$changed_files" ]; then
            if ! bp_apply_remote_saves "$repo_dir" "$changed_files"; then
                pal_log "error" "Stale boot: failed to apply one or more remote saves"
                return 1
            fi
        fi
        if ! cs_store_commit "$repo_dir" "$new_commit"; then
            pal_log "error" "Stale boot: failed to store commit after pull"
            return 1
        fi
    else
        pal_log "info" "Stale boot: no remote changes since last sync"
    fi

    # Step 4: Outbound catch-up scan
    local device_saves
    device_saves=$(cd_list_device_saves)

    local _sb_tmpfile
    _sb_tmpfile=$(mktemp)
    printf '0\n' > "$_sb_tmpfile"

    if [ -n "$device_saves" ]; then
        printf '%s\n' "$device_saves" | while IFS= read -r device_path; do
            [ -z "$device_path" ] && continue

            local repo_path rc_map
            rc_map=0
            repo_path=$(pm_device_to_canonical "$device_path" 2>/dev/null) || rc_map=$?
            if [ "$rc_map" -eq 3 ]; then
                pal_log "warn" "Stale boot: compressed save skipped — set save format to uncompressed: $device_path"
                continue
            fi
            if [ "$rc_map" -ne 0 ] || [ -z "$repo_path" ]; then
                pal_log "warn" "Stale boot: unknown system dir, skipping: $device_path"
                continue
            fi

            local repo_file
            repo_file="$repo_dir/$repo_path"
            if [ ! -f "$repo_file" ] || ! cmp -s "$device_path" "$repo_file"; then
                mkdir -p "$(dirname "$repo_file")"
                cp "$device_path" "$repo_file"
                pal_log "info" "Stale boot: catch-up copied $device_path -> $repo_path"
                printf '1\n' > "$_sb_tmpfile"
            fi
        done
    fi

    # Step 4b: Save states — opaque one-way catch-up (device → repo only)
    local device_states
    device_states=$(cd_list_device_states 2>/dev/null)
    if [ -n "$device_states" ]; then
        printf '%s\n' "$device_states" | while IFS= read -r device_path; do
            [ -z "$device_path" ] && continue
            local state_repo_path
            state_repo_path=$(pm_state_to_repo "$device_path" 2>/dev/null)
            [ -n "$state_repo_path" ] || continue
            local state_repo_file
            state_repo_file="$repo_dir/$state_repo_path"
            if [ ! -f "$state_repo_file" ] || ! cmp -s "$device_path" "$state_repo_file"; then
                mkdir -p "$(dirname "$state_repo_file")"
                cp "$device_path" "$state_repo_file"
                pal_log "info" "Stale boot: catch-up backed up state $state_repo_path"
                printf '1\n' > "$_sb_tmpfile"
            fi
        done
    fi

    local _sb_changed
    _sb_changed=$(cat "$_sb_tmpfile")
    rm -f "$_sb_tmpfile"

    # Step 5: Commit and push catch-up changes.
    # git's view is authoritative, not just this run's copy flag: a file
    # copied into the repo tree by an EARLIER run that failed to stage
    # (the porcelain-quoting bug stranded exactly such files) must still
    # be committed now.
    local staged
    staged=$(cd_detect_changes "$repo_dir")
    if [ "$_sb_changed" = "1" ] || [ -n "$staged" ]; then
        if [ -n "$staged" ]; then
            if ! se_stage_files "$repo_dir" "$staged"; then
                pal_log "error" "Stale boot: failed to stage catch-up files"
                return 1
            fi
            if ! se_commit "$repo_dir" "$staged" "stale boot catch-up from $CONTINUITY_DEVICE_NAME"; then
                pal_log "error" "Stale boot: failed to commit catch-up"
                return 1
            fi
            if pal_is_online; then
                local push_rc
                push_rc=0
                se_push "$repo_dir" || push_rc=$?
                if [ "$push_rc" -eq 1 ]; then
                    pal_log "error" "Stale boot: push of catch-up commit failed"
                    return 1
                elif [ "$push_rc" -eq 2 ]; then
                    pal_log "warn" "Stale boot: offline — catch-up commit queued"
                fi
            fi
            local head_hash
            head_hash=$(se_get_head_commit "$repo_dir")
            if ! cs_store_commit "$repo_dir" "$head_hash"; then
                pal_log "error" "Stale boot: failed to store commit after catch-up"
                return 1
            fi
        else
            pal_log "info" "Stale boot: catch-up scan found file changes but git reports none"
        fi
    else
        pal_log "info" "Stale boot: catch-up scan found no local changes"
    fi

    # Step 6: Update sentinel
    if ! rp_update_sentinel "$repo_dir"; then
        pal_log "error" "Stale boot: failed to update sentinel"
        return 1
    fi

    # Step 7: Done
    pal_log "info" "Stale boot recovery complete"
    return 0
}
