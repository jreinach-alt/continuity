#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Cold Start — first bidirectional sync after enrollment
# Merges device saves with repo saves, resolves conflicts (repo wins),
# creates sentinel and commit hash for subsequent incremental syncs.
# Requires PAL, path mapper, sync engine, and change detector to be loaded.

# cs_is_cold_start — check if cold start is needed
# Usage: cs_is_cold_start <repo_dir>
# Returns: 0 if cold start needed (no sentinel), 1 if sentinel present
cs_is_cold_start() {
    local repo_dir
    repo_dir="$1"
    [ ! -f "$repo_dir/.continuity/sentinel" ]
}

# cs_store_commit — write commit hash to last_known_commit
# Usage: cs_store_commit <repo_dir> <commit_hash>
# Returns: 0 on success, 1 on error
cs_store_commit() {
    local repo_dir commit_hash
    repo_dir="$1"
    commit_hash="$2"
    if ! mkdir -p "$repo_dir/.continuity"; then
        return 1
    fi
    if ! printf '%s\n' "$commit_hash" > "$repo_dir/.continuity/last_known_commit"; then
        return 1
    fi
    return 0
}

# cs_read_commit — read stored commit hash
# Usage: cs_read_commit <repo_dir>
# Prints commit hash to stdout. Returns: 0 on success, 1 if not found/empty
cs_read_commit() {
    local repo_dir commit_file hash
    repo_dir="$1"
    commit_file="$repo_dir/.continuity/last_known_commit"
    [ -f "$commit_file" ] || return 1
    hash=$(cat "$commit_file")
    hash=$(printf '%s' "$hash" | tr -d '[:space:]')
    [ -n "$hash" ] || return 1
    printf '%s' "$hash"
    return 0
}

# cs_create_sentinel — create sentinel file with timestamp
# Usage: cs_create_sentinel <repo_dir>
# Returns: 0 on success, 1 on error
cs_create_sentinel() {
    local repo_dir
    repo_dir="$1"
    if ! mkdir -p "$repo_dir/.continuity"; then
        return 1
    fi
    if ! date '+%Y-%m-%dT%H:%M:%S' > "$repo_dir/.continuity/sentinel"; then
        return 1
    fi
    return 0
}

# cs_run — execute the full cold start sync flow
# Usage: cs_run <repo_dir>
# Returns: 0 on success, 1 on error
cs_run() {
    local repo_dir was_offline pull_rc
    repo_dir="$1"
    was_offline=""

    # Step 1: Pull latest from remote
    if pal_is_online; then
        pull_rc=0
        se_pull "$repo_dir" || pull_rc=$?
        if [ "$pull_rc" -eq 1 ]; then
            pal_log "error" "Cold start: pull failed (diverged)"
            return 1
        elif [ "$pull_rc" -eq 2 ]; then
            pal_log "warn" "Cold start: pull network error — working with local clone only"
            was_offline=true
        fi
    else
        pal_log "warn" "Cold start: offline — working with local clone only"
        was_offline=true
    fi

    # Step 2: Enumerate repo saves
    local repo_saves
    repo_saves=$(cd_list_repo_saves "$repo_dir")

    # Step 3: Enumerate device saves
    local device_saves
    device_saves=$(cd_list_device_saves)

    # Temp files for subshell-safe accumulation
    local conflict_tmp cp_fail_tmp
    conflict_tmp=$(mktemp)
    cp_fail_tmp=$(mktemp)
    printf '' > "$conflict_tmp"
    printf '' > "$cp_fail_tmp"

    # Step 4: For each repo save, sync to device
    if [ -n "$repo_saves" ]; then
        printf '%s\n' "$repo_saves" | while IFS= read -r repo_path; do
            [ -z "$repo_path" ] && continue

            local local_path rc_map
            rc_map=0
            local_path=$(pm_canonical_to_device "$repo_path" 2>/dev/null) || rc_map=$?
            if [ "$rc_map" -eq 2 ]; then
                # No matching ROM on this device — sparse sync, not an error.
                pal_log "info" "Cold start: no ROM for $repo_path — not materialized"
                continue
            fi
            if [ "$rc_map" -ne 0 ] || [ -z "$local_path" ]; then
                pal_log "warn" "Cold start: unknown system in repo path: $repo_path"
                continue
            fi

            local repo_file
            repo_file="$repo_dir/$repo_path"

            if [ ! -f "$local_path" ]; then
                # Repo-only: copy to device
                mkdir -p "$(dirname "$local_path")"
                if ! cp "$repo_file" "$local_path"; then
                    pal_log "error" "Cold start: failed to copy $repo_path to device"
                    printf 'fail\n' > "$cp_fail_tmp"
                    break
                fi
                pal_log "info" "Cold start: pulled $repo_path to device"
            elif ! cmp -s "$repo_file" "$local_path"; then
                # Conflict: repo wins, preserve device version
                local conflict_name
                conflict_name="$repo_path.$CONTINUITY_DEVICE_NAME.local"
                if ! cp "$local_path" "$repo_dir/$conflict_name"; then
                    pal_log "error" "Cold start: failed to preserve device version of $repo_path"
                    printf 'fail\n' > "$cp_fail_tmp"
                    break
                fi
                if ! cp "$repo_file" "$local_path"; then
                    pal_log "error" "Cold start: failed to copy $repo_path to device"
                    printf 'fail\n' > "$cp_fail_tmp"
                    break
                fi

                # Write .conflict metadata (schema v2, design §3). Cold-start
                # preservation has no remote counterpart device, so remote_*
                # is nullable (unknown/empty) — keep_newest already refuses to
                # guess on a missing timestamp. identity groups a game's
                # .srm/.sav + .rtc; class is the save class (rtc, else srm).
                local timestamp cs_identity cs_class
                timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')
                cs_identity=$(printf '%s' "$repo_path" | sed 's/\.srm$//; s/\.sav$//; s/\.rtc$//')
                case "$repo_path" in
                    *.rtc) cs_class="rtc" ;;
                    *)     cs_class="srm" ;;
                esac
                printf '{\n  "_schema_version": "2.0",\n  "file": "%s",\n  "identity": "%s",\n  "class": "%s",\n  "remote_device": "unknown",\n  "remote_timestamp": "",\n  "local_device": "%s",\n  "local_timestamp": "%s",\n  "source": "cold_start",\n  "status": "unresolved"\n}\n' \
                    "$repo_path" "$cs_identity" "$cs_class" "$CONTINUITY_DEVICE_NAME" "$timestamp" > "$repo_dir/$repo_path.conflict"

                # Accumulate conflict artifact paths
                printf '%s\n%s\n' "$conflict_name" "$repo_path.conflict" >> "$conflict_tmp"

                pal_log "warn" "Cold start: conflict on $repo_path — device version preserved as $conflict_name"

                # Optional hook
                if command -v pal_on_conflict >/dev/null 2>&1; then
                    pal_on_conflict "$repo_path"
                fi
            fi
            # Else: identical — no-op
        done
    fi

    # Check for copy failures in step 4
    local step4_failure
    step4_failure=$(cat "$cp_fail_tmp")
    if [ -n "$step4_failure" ]; then
        rm -f "$conflict_tmp" "$cp_fail_tmp"
        return 1
    fi

    # Step 5: For each device save, sync to repo
    printf '' > "$cp_fail_tmp"
    if [ -n "$device_saves" ]; then
        printf '%s\n' "$device_saves" | while IFS= read -r local_path; do
            [ -z "$local_path" ] && continue

            local repo_path rc_map
            rc_map=0
            repo_path=$(pm_device_to_canonical "$local_path" 2>/dev/null) || rc_map=$?
            if [ "$rc_map" -eq 3 ]; then
                # Compressed save quarantined (mapper logged the named line).
                continue
            fi
            if [ "$rc_map" -ne 0 ] || [ -z "$repo_path" ]; then
                pal_log "warn" "Cold start: unknown system dir for device path: $local_path"
                continue
            fi

            local repo_file
            repo_file="$repo_dir/$repo_path"

            if [ ! -f "$repo_file" ]; then
                # Device-only: copy to repo
                mkdir -p "$(dirname "$repo_file")"
                if ! cp "$local_path" "$repo_file"; then
                    pal_log "error" "Cold start: failed to copy $local_path to repo"
                    printf 'fail\n' > "$cp_fail_tmp"
                    break
                fi
                pal_log "info" "Cold start: pushed $repo_path from device"
            fi
            # Else: already handled in step 4
        done
    fi

    # Step 5b: Save states — opaque one-way backup (device → repo only)
    local device_states
    device_states=$(cd_list_device_states 2>/dev/null)
    if [ -n "$device_states" ]; then
        printf '%s\n' "$device_states" | while IFS= read -r local_path; do
            [ -z "$local_path" ] && continue
            local repo_path
            repo_path=$(pm_state_to_repo "$local_path" 2>/dev/null)
            [ -n "$repo_path" ] || continue
            local repo_file
            repo_file="$repo_dir/$repo_path"
            if [ ! -f "$repo_file" ] || ! cmp -s "$local_path" "$repo_file"; then
                mkdir -p "$(dirname "$repo_file")"
                cp "$local_path" "$repo_file" && \
                    pal_log "info" "Cold start: backed up state $repo_path"
            fi
        done
    fi

    # Scan diagnostics: a silently-blind scanner must name itself
    pal_log "info" "Cold start scan: $(printf '%s\n' "$device_saves" | grep -c .) saves, $(printf '%s\n' "$device_states" | grep -c .) states (watched dirs: $(pm_list_watched_dirs | grep -c .))"

    # Check for copy failures in step 5
    local step5_failure
    step5_failure=$(cat "$cp_fail_tmp")
    rm -f "$cp_fail_tmp"
    if [ -n "$step5_failure" ]; then
        rm -f "$conflict_tmp"
        return 1
    fi

    # Step 6: Detect and stage all changes
    local changed conflict_files
    changed=$(cd_detect_changes "$repo_dir")
    conflict_files=$(cat "$conflict_tmp")
    rm -f "$conflict_tmp"

    if [ -n "$conflict_files" ]; then
        if [ -n "$changed" ]; then
            changed="$changed
$conflict_files"
        else
            changed="$conflict_files"
        fi
    fi

    # Step 7: Commit and push if changes exist
    if [ -n "$changed" ]; then
        if ! se_stage_files "$repo_dir" "$changed"; then
            pal_log "error" "Cold start: failed to stage files"
            return 1
        fi

        if ! se_commit "$repo_dir" "$changed"; then
            pal_log "error" "Cold start: failed to commit"
            return 1
        fi

        if pal_is_online; then
            local push_rc
            push_rc=0
            se_push "$repo_dir" || push_rc=$?
            if [ "$push_rc" -eq 2 ]; then
                pal_log "info" "Cold start: push deferred (offline)"
                was_offline=true
            elif [ "$push_rc" -eq 1 ]; then
                pal_log "error" "Cold start: push failed"
                if command -v ss_notify >/dev/null 2>&1; then
                    ss_notify "$repo_dir" "red" "Push failed — check credentials"
                fi
                return 1
            fi
        else
            was_offline=true
        fi
    else
        pal_log "info" "Cold start: nothing to commit"
    fi

    # Steps 8-9: Store commit hash and create sentinel (only if online)
    if [ "$was_offline" != "true" ]; then
        local head_hash
        head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
        if ! cs_store_commit "$repo_dir" "$head_hash"; then
            pal_log "error" "Cold start: failed to store commit hash"
            return 1
        fi
        if ! cs_create_sentinel "$repo_dir"; then
            pal_log "error" "Cold start: failed to create sentinel"
            return 1
        fi
    else
        pal_log "info" "Cold start: offline — sentinel deferred until next boot with connectivity"
        if command -v ss_notify >/dev/null 2>&1; then
            ss_notify "$repo_dir" "yellow" "Initial sync — push pending"
        fi
    fi

    # Step 10: Done
    pal_log "info" "Cold start complete"
    if [ "$was_offline" != "true" ]; then
        if command -v ss_notify >/dev/null 2>&1; then
            ss_notify "$repo_dir" "green" "Initial sync complete"
        fi
    fi
    return 0
}
