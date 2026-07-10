#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Runtime Poll — single poll cycle for detecting and syncing save file changes
# Finds candidate changed .srm files via find -newer sentinel, confirms genuine
# changes via cmp -s against the repo working tree, copies changed files to the
# repo, stages, commits, pushes if online, and advances the sentinel.
#
# Required modules (must be sourced by caller before calling rp_*):
#   PAL: CONTINUITY_SAVES_ROOT, CONTINUITY_GIT_BIN, pal_is_online(), pal_log()
#   path_mapper: pm_local_to_repo()
#   sync_engine: se_stage_files(), se_commit(), se_push(), se_get_head_commit()
#   change_detector: cd_detect_changes()
#   cold_start: cs_store_commit()
#   conflict_handler: ch_is_trying(), ch_is_trying_modified()
#   sync_status: ss_notify()

# rp_find_candidates — find .srm files newer than the sentinel
# Usage: rp_find_candidates <repo_dir>
# Prints absolute device paths to stdout, one per line.
# Returns 0 always. Empty output means no candidates.
rp_find_candidates() {
    local repo_dir sentinel
    repo_dir="$1"
    sentinel="$repo_dir/.continuity/sentinel"

    pm_find_saves "$CONTINUITY_SAVES_ROOT" -newer "$sentinel" || true
    # Save states (opaque one-way backup) — only when the PAL defines a
    # root; all five state name-shapes; the shared size gate applies here too.
    if [ -n "$CONTINUITY_STATES_ROOT" ] && [ -d "$CONTINUITY_STATES_ROOT" ]; then
        pm_find_states "$CONTINUITY_STATES_ROOT" -newer "$sentinel" | \
        while IFS= read -r f; do
            cd_state_size_ok "$f" || continue
            printf '%s\n' "$f"
        done
    fi
    return 0
}

# rp_map_device_path — repo path for a device file: save files map through
# the canonical mapper (name-style + container sniff; rc 3 = compressed
# save quarantined); states map to the opaque states/ namespace.
rp_map_device_path() {
    local device_path
    device_path="$1"
    case "$device_path" in
        "${CONTINUITY_STATES_ROOT:-/nonexistent}"/*) pm_state_to_repo "$device_path" ;;
        *)                           pm_device_to_canonical "$device_path" ;;
    esac
}

# rp_confirm_changes — filter candidates to only genuinely changed files
# Usage: rp_confirm_changes <repo_dir> <candidates>
# candidates is newline-delimited absolute device paths.
# Prints confirmed-changed absolute device paths to stdout.
# Returns 0 always.
rp_confirm_changes() {
    local repo_dir candidates
    repo_dir="$1"
    candidates="$2"

    [ -z "$candidates" ] && return 0

    printf '%s\n' "$candidates" | while IFS= read -r device_path; do
        [ -z "$device_path" ] && continue

        local repo_path rc_map
        rc_map=0
        repo_path=$(rp_map_device_path "$device_path" 2>/dev/null) || rc_map=$?
        if [ "$rc_map" -ne 0 ] || [ -z "$repo_path" ]; then
            pal_log "warn" "Poll confirm: unknown system dir, skipping: $device_path"
            continue
        fi

        # Skip files in trying state (Sprint 0.9 safety gate)
        if command -v ch_is_trying >/dev/null 2>&1 && ch_is_trying "$repo_dir" "$repo_path"; then
            if command -v ch_is_trying_modified >/dev/null 2>&1 && ch_is_trying_modified "$repo_dir" "$repo_path"; then
                if command -v ss_notify >/dev/null 2>&1; then
                    ss_notify "$repo_dir" "red" "Save modified during try — action required"
                fi
            fi
            pal_log "info" "Poll confirm: skipping trying-state file: $repo_path"
            continue
        fi

        local repo_file
        repo_file="$repo_dir/$repo_path"

        if ! cmp -s "$device_path" "$repo_file"; then
            printf '%s\n' "$device_path"
        fi
    done
    return 0
}

# rp_update_sentinel — advance sentinel mtime to now
# Usage: rp_update_sentinel <repo_dir>
# Returns: 0 on success, 1 on failure
rp_update_sentinel() {
    local repo_dir
    repo_dir="$1"

    if ! touch "$repo_dir/.continuity/sentinel"; then
        return 1
    fi
    return 0
}

# rp_run — execute one complete poll cycle
# Usage: rp_run <repo_dir>
# Returns: 0 nothing to do or sync succeeded, 1 error
rp_run() {
    local repo_dir sentinel
    repo_dir="$1"
    sentinel="$repo_dir/.continuity/sentinel"

    # Step 1: Verify sentinel exists
    if [ ! -f "$sentinel" ]; then
        pal_log "error" "Sentinel missing — cold start not complete?"
        return 1
    fi

    # Step 2: Find candidates
    local candidates
    candidates=$(rp_find_candidates "$repo_dir")
    if [ -z "$candidates" ]; then
        return 0
    fi

    # Step 3: Confirm changes via cmp -s
    local changed
    changed=$(rp_confirm_changes "$repo_dir" "$candidates")
    if [ -z "$changed" ]; then
        rp_update_sentinel "$repo_dir"
        return 0
    fi

    # Step 4: Copy changed files to repo working tree
    local cp_fail_tmp
    cp_fail_tmp=$(mktemp)
    printf '' > "$cp_fail_tmp"

    printf '%s\n' "$changed" | while IFS= read -r device_path; do
        [ -z "$device_path" ] && continue

        local repo_path rc_map
        rc_map=0
        repo_path=$(rp_map_device_path "$device_path" 2>/dev/null) || rc_map=$?
        if [ "$rc_map" -ne 0 ] || [ -z "$repo_path" ]; then
            pal_log "warn" "Unknown system dir, skipping: $device_path"
            continue
        fi

        local repo_file
        repo_file="$repo_dir/$repo_path"
        mkdir -p "$(dirname "$repo_file")"
        if ! cp "$device_path" "$repo_file"; then
            pal_log "error" "Poll: failed to copy $device_path -> $repo_path"
            printf 'fail\n' > "$cp_fail_tmp"
            break
        fi
        pal_log "info" "Poll: copied $device_path -> $repo_path"
    done

    local cp_failure
    cp_failure=$(cat "$cp_fail_tmp")
    rm -f "$cp_fail_tmp"
    if [ -n "$cp_failure" ]; then
        if command -v ss_notify >/dev/null 2>&1; then
            ss_notify "$repo_dir" "red" "Sync error — check logs"
        fi
        return 1
    fi

    # Step 5: Detect git-level changes
    local changed_in_repo
    changed_in_repo=$(cd_detect_changes "$repo_dir")
    if [ -z "$changed_in_repo" ]; then
        pal_log "info" "Poll: no git changes after copy — skipping commit"
        rp_update_sentinel "$repo_dir"
        return 0
    fi

    # Step 6: Stage and commit
    if ! se_stage_files "$repo_dir" "$changed_in_repo"; then
        pal_log "error" "Poll: failed to stage files"
        if command -v ss_notify >/dev/null 2>&1; then
            ss_notify "$repo_dir" "red" "Sync error — check logs"
        fi
        return 1
    fi

    if ! se_commit "$repo_dir" "$changed_in_repo"; then
        pal_log "error" "Poll: failed to commit"
        if command -v ss_notify >/dev/null 2>&1; then
            ss_notify "$repo_dir" "red" "Sync error — check logs"
        fi
        return 1
    fi

    # Compute save count before push block (PF-2)
    local save_count
    save_count=$(printf '%s\n' "$changed_in_repo" | grep -c '.')

    # Step 7: Push if online
    if pal_is_online; then
        local push_rc
        push_rc=0
        se_push "$repo_dir" || push_rc=$?
        if [ "$push_rc" -eq 1 ]; then
            # Most common cause is divergence (another device synced),
            # which the daemon reconciles next tick — not credentials.
            # The precise git stderr is already in the log via se_push.
            pal_log "error" "Poll: push failed"
            if command -v ss_notify >/dev/null 2>&1; then
                ss_notify "$repo_dir" "red" "Push rejected — will reconcile"
            fi
            return 1
        elif [ "$push_rc" -eq 2 ]; then
            pal_log "warn" "Poll: push deferred unexpectedly"
            if command -v ss_notify >/dev/null 2>&1; then
                ss_notify "$repo_dir" "yellow" "$save_count save(s) queued — offline"
            fi
        else
            if command -v ss_notify >/dev/null 2>&1; then
                ss_notify "$repo_dir" "green" "Pushed $save_count save(s)"
            fi
        fi
    else
        pal_log "info" "Poll: offline — commit queued locally"
        if command -v ss_notify >/dev/null 2>&1; then
            ss_notify "$repo_dir" "yellow" "$save_count save(s) queued — offline"
        fi
    fi

    # Step 8: Store commit hash
    local head_hash
    head_hash=$(se_get_head_commit "$repo_dir")
    if ! cs_store_commit "$repo_dir" "$head_hash"; then
        pal_log "error" "Poll: failed to store commit hash"
        return 1
    fi

    # Step 9: Update sentinel
    if ! rp_update_sentinel "$repo_dir"; then
        pal_log "error" "Poll: failed to update sentinel"
        return 1
    fi

    # Step 10: Done
    pal_log "info" "Poll: sync complete"
    return 0
}
