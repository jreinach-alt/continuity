#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Conflict Handler — preserves both sides of diverged-history conflicts
#
# When se_pull returns 1 (branches diverged, fast-forward not possible),
# this module preserves the local device's version alongside the remote
# (canonical) version, writes structured metadata, and provides resolution
# functions to clean up conflict artifacts.
#
# Prerequisites:
#   - PAL loaded and validated (provides CONTINUITY_GIT_BIN, CONTINUITY_DEVICE_NAME,
#     pal_log(), pal_is_online())
#   - src/core/sync_engine.sh sourced and initialized (se_stage_files, se_push,
#     se_get_head_commit)
#   - src/core/cold_start.sh sourced (cs_store_commit)
#
# Public functions: ch_handle_pull_conflict, ch_preserve_conflict,
#                   ch_list_conflicts, ch_list_local_files,
#                   ch_resolve, ch_resolve_all,
#                   ch_get_conflict_info, ch_list_conflicts_detailed,
#                   ch_count_conflicts, ch_try_version, ch_get_active_version,
#                   ch_clear_try_markers, ch_is_trying, ch_is_trying_modified,
#                   ch_promote_trying

# ch_preserve_conflict — preserve local version of a conflicted save
# Usage: ch_preserve_conflict <repo_dir> <repo_path> <device_name>
# Creates <repo_path>.<device_name>.local and <repo_path>.conflict
# Does NOT commit — caller batches and commits.
# Returns: 0 on success, 1 on error
ch_preserve_conflict() {
    local repo_dir repo_path device_name
    repo_dir="$1"
    repo_path="$2"
    device_name="$3"

    local local_file conflict_meta
    local_file="$repo_dir/$repo_path.$device_name.local"
    conflict_meta="$repo_dir/$repo_path.conflict"

    # Copy local .srm bytes to .local file
    if ! cp "$repo_dir/$repo_path" "$local_file"; then
        pal_log "error" "ch_preserve_conflict: cp failed for $repo_path"
        return 1
    fi

    # Derive remote device and timestamp from git log on origin/main
    local remote_info remote_timestamp remote_device
    remote_info=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" \
        log -1 --format="%cI%n%B" origin/main -- "$repo_path" 2>/dev/null) || true

    remote_timestamp=$(printf '%s\n' "$remote_info" | head -1)
    remote_device=$(printf '%s\n' "$remote_info" | grep '^device:' | head -1 | sed 's/^device: *//')
    [ -z "$remote_device" ] && remote_device="unknown"

    # Local timestamp — use current UTC time (BusyBox date cannot convert epoch)
    local local_timestamp
    local_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || local_timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

    # Escape double quotes in values
    local esc_file esc_remote_device esc_device_name
    esc_file=$(printf '%s' "$repo_path" | sed 's/"/\\"/g')
    esc_remote_device=$(printf '%s' "$remote_device" | sed 's/"/\\"/g')
    esc_device_name=$(printf '%s' "$device_name" | sed 's/"/\\"/g')

    # Write .conflict JSON
    if ! printf '{\n  "_schema_version": "1.0",\n  "file": "%s",\n  "remote_device": "%s",\n  "remote_timestamp": "%s",\n  "local_device": "%s",\n  "local_timestamp": "%s",\n  "status": "unresolved"\n}\n' \
        "$esc_file" "$esc_remote_device" "$remote_timestamp" "$esc_device_name" "$local_timestamp" \
        > "$conflict_meta"; then
        pal_log "error" "ch_preserve_conflict: write failed for $conflict_meta"
        return 1
    fi

    return 0
}

# ch_handle_pull_conflict — handle a diverged pull by preserving conflicts
# Usage: ch_handle_pull_conflict <repo_dir>
# Called when se_pull returns 1 (diverged). Fetches remote, identifies
# conflicted .srm files, preserves local versions, accepts remote as
# canonical, commits conflict artifacts, pushes, and calls pal_on_conflict.
# Returns: 0 on success, 1 on error
ch_handle_pull_conflict() {
    local repo_dir
    repo_dir="$1"

    # Step 1: Fetch remote
    if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" fetch origin 2>/dev/null; then
        pal_log "error" "Conflict handler: fetch failed"
        return 1
    fi

    # Step 2: Identify diverged save files — BOTH formats the scanners
    # sync (.srm and .sav; the Brick's compiled default is .sav), and
    # NUL-delimited (-z) because diff --name-only C-quotes spaced and
    # non-ASCII paths exactly like status --porcelain does (see the
    # porcelain-quoting field note).
    local diverged
    diverged=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" \
        diff --name-only -z HEAD origin/main -- '*.srm' '*.sav' 2>/dev/null | \
        tr '\0' '\n') || true

    # Classify: a CONFLICT is a save that exists on BOTH sides with
    # different bytes. One-sided adds are not conflicts — a remote-only
    # add has no local version to lose (the reset below brings it in),
    # and a local-only add is re-synced from the device by the stale
    # catch-up scan / next poll after the reset. Preserving them would
    # crash (remote-only: nothing local to copy) or litter bogus
    # artifacts (local-only: no remote counterpart).
    local conflicted _ch_cls_tmp
    _ch_cls_tmp=$(mktemp)
    : > "$_ch_cls_tmp"
    printf '%s\n' "$diverged" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" cat-file -e "HEAD:$repo_path" 2>/dev/null || continue
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" cat-file -e "origin/main:$repo_path" 2>/dev/null || continue
        printf '%s\n' "$repo_path" >> "$_ch_cls_tmp"
    done
    conflicted=$(cat "$_ch_cls_tmp")
    rm -f "$_ch_cls_tmp"

    if [ -z "$conflicted" ]; then
        # No true save conflicts — accept remote
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" reset --hard origin/main >/dev/null 2>&1
        pal_log "info" "Conflict handler: no save conflicts — reset to remote"
        return 0
    fi

    # Step 3: Preserve each conflicted file
    printf '%s\n' "$conflicted" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        if ! ch_preserve_conflict "$repo_dir" "$repo_path" "$CONTINUITY_DEVICE_NAME"; then
            pal_log "error" "Failed to preserve $repo_path"
            return 1
        fi
    done || return 1

    # Step 4: Accept remote as canonical
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" reset --hard origin/main >/dev/null 2>&1

    # Step 5: Stage all conflict artifacts
    local stage_list _ch_tmpfile
    _ch_tmpfile=$(mktemp)
    printf '' > "$_ch_tmpfile"
    printf '%s\n' "$conflicted" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        printf '%s\n%s\n' "$repo_path.$CONTINUITY_DEVICE_NAME.local" "$repo_path.conflict" \
            >> "$_ch_tmpfile"
    done
    stage_list=$(cat "$_ch_tmpfile")
    rm -f "$_ch_tmpfile"

    if ! se_stage_files "$repo_dir" "$stage_list"; then
        pal_log "error" "Conflict handler: staging failed"
        return 1
    fi

    # Step 6: Commit conflict artifacts
    local conflict_count
    conflict_count=$(printf '%s\n' "$conflicted" | grep -c '.')
    if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
        -m "conflict: $conflict_count save(s) preserved from $CONTINUITY_DEVICE_NAME" 2>/dev/null; then
        pal_log "error" "Conflict handler: commit failed"
        return 1
    fi

    # Step 7: Push
    local push_rc
    push_rc=0
    se_push "$repo_dir" || push_rc=$?
    if [ "$push_rc" -eq 1 ]; then
        pal_log "error" "Conflict handler: push failed"
        return 1
    elif [ "$push_rc" -eq 2 ]; then
        pal_log "warn" "Conflict artifacts committed locally — push pending"
    fi

    # Step 8: Update last_known_commit
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    cs_store_commit "$repo_dir" "$head_hash"

    # Step 9: Call pal_on_conflict hook for each conflicted file
    printf '%s\n' "$conflicted" | while IFS= read -r repo_path; do
        [ -z "$repo_path" ] && continue
        if command -v pal_on_conflict >/dev/null 2>&1; then
            pal_on_conflict "$repo_path"
        fi
    done

    # Step 10: Done
    pal_log "info" "Conflict handler: $conflict_count conflict(s) preserved"
    return 0
}

# ch_list_conflicts — enumerate all unresolved conflict metadata files
# Usage: ch_list_conflicts <repo_dir>
# Prints repo-relative paths of .conflict files, one per line.
# Returns: 0 always
ch_list_conflicts() {
    local repo_dir
    repo_dir="$1"
    find "$repo_dir" \
        ! -path "*/.git/*" \
        -name "*.conflict" \
        2>/dev/null \
    | sed "s|^$repo_dir/||"
    return 0
}

# ch_list_local_files — enumerate all .local files with device attribution
# Usage: ch_list_local_files <repo_dir>
# Prints "<canonical_repo_path> <device_name>" per line.
# Returns: 0 always
ch_list_local_files() {
    local repo_dir
    repo_dir="$1"
    find "$repo_dir" \
        ! -path "*/.git/*" \
        -name "*.local" \
        2>/dev/null \
    | sed "s|^$repo_dir/||" \
    | while IFS= read -r local_path; do
        local base device
        base=$(printf '%s' "$local_path" | sed 's/\.[^.]*\.local$//')
        # device token is the segment before .local, whatever the
        # save's own extension is (.srm or .sav)
        device=$(printf '%s' "$local_path" | sed 's/.*\.\([^.]*\)\.local$/\1/')
        printf '%s %s\n' "$base" "$device"
    done
    return 0
}

# ch_resolve — resolve a single conflict
# Usage: ch_resolve <repo_dir> <repo_path> <resolution>
# resolution: keep_remote, keep_local, keep_newest, prompt
# Returns: 0 on success, 1 on error
ch_resolve() {
    local repo_dir repo_path resolution
    repo_dir="$1"
    repo_path="$2"
    resolution="$3"

    # Find .local file(s) for this save
    local srm_basename srm_dir local_files local_file
    srm_basename=$(basename "$repo_path")
    srm_dir=$(dirname "$repo_path")
    local_files=$(find "$repo_dir/$srm_dir" \
        -name "$srm_basename.*.local" \
        ! -path "*/.git/*" \
        2>/dev/null)

    if [ -z "$local_files" ]; then
        pal_log "warn" "ch_resolve: no .local file for $repo_path"
        return 1
    fi

    local conflict_meta
    conflict_meta="$repo_dir/$repo_path.conflict"
    if [ ! -f "$conflict_meta" ]; then
        pal_log "warn" "ch_resolve: no .conflict metadata for $repo_path"
        return 1
    fi

    case "$resolution" in
        keep_remote)
            # Remote is already canonical — remove artifacts
            printf '%s\n' "$local_files" | while IFS= read -r lf; do
                [ -z "$lf" ] && continue
                local lf_rel
                lf_rel=$(printf '%s' "$lf" | sed "s|^$repo_dir/||")
                rm -f "$lf"
                "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$lf_rel" >/dev/null 2>&1 || true
            done
            rm -f "$conflict_meta"
            "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$repo_path.conflict" >/dev/null 2>&1 || true
            if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
                -m "resolve: keep remote $repo_path" >/dev/null 2>&1; then
                pal_log "error" "ch_resolve: commit failed for keep_remote $repo_path"
                return 1
            fi
            ;;

        keep_local)
            # Copy first .local over canonical
            local_file=$(printf '%s\n' "$local_files" | head -1)
            if ! cp "$local_file" "$repo_dir/$repo_path"; then
                pal_log "error" "ch_resolve: cp failed for keep_local $repo_path"
                return 1
            fi
            "$CONTINUITY_GIT_BIN" -C "$repo_dir" add "$repo_path" 2>/dev/null
            # Remove all .local files
            printf '%s\n' "$local_files" | while IFS= read -r lf; do
                [ -z "$lf" ] && continue
                local lf_rel
                lf_rel=$(printf '%s' "$lf" | sed "s|^$repo_dir/||")
                rm -f "$lf"
                "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$lf_rel" >/dev/null 2>&1 || true
            done
            rm -f "$conflict_meta"
            "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$repo_path.conflict" >/dev/null 2>&1 || true
            if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
                -m "resolve: keep local $repo_path" >/dev/null 2>&1; then
                pal_log "error" "ch_resolve: commit failed for keep_local $repo_path"
                return 1
            fi
            ;;

        keep_newest)
            # Compare timestamps from .conflict metadata.
            # These are DEVICE WALL CLOCKS (gap review 2026-07-07): a
            # wrong-clock device would silently pick the wrong side, so
            # refuse to guess when either side is missing — the caller
            # falls back to prompt/manual resolution.
            local remote_ts local_ts
            remote_ts=$(grep '"remote_timestamp"' "$conflict_meta" | sed 's/.*: *"\([^"]*\)".*/\1/')
            local_ts=$(grep '"local_timestamp"' "$conflict_meta" | sed 's/.*: *"\([^"]*\)".*/\1/')
            if [ -z "$remote_ts" ] || [ -z "$local_ts" ]; then
                pal_log "error" "ch_resolve: keep_newest needs both timestamps for $repo_path — resolve manually"
                return 1
            fi
            if [ "$local_ts" \> "$remote_ts" ]; then
                ch_resolve "$repo_dir" "$repo_path" "keep_local"
            else
                ch_resolve "$repo_dir" "$repo_path" "keep_remote"
            fi
            return $?
            ;;

        prompt)
            # Do nothing — leave artifacts for platform UI
            pal_log "info" "ch_resolve: $repo_path left unresolved (prompt mode)"
            return 0
            ;;

        *)
            pal_log "error" "ch_resolve: unknown resolution '$resolution'"
            return 1
            ;;
    esac

    # Post-resolution: update device save (best-effort)
    local device_path_res
    device_path_res=$(pm_repo_to_local "$repo_path" 2>/dev/null) || true
    if [ -n "$device_path_res" ] && [ -d "$(dirname "$device_path_res")" ]; then
        cp "$repo_dir/$repo_path" "$device_path_res" 2>/dev/null || true
    fi

    # Clean up try marker
    local marker_name_res
    marker_name_res=$(_ch_marker_name "$repo_path")
    rm -f "$repo_dir/.continuity/trying/$marker_name_res"

    # Update last_known_commit and push (keep_remote/keep_local only)
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    cs_store_commit "$repo_dir" "$head_hash"

    if pal_is_online; then
        local push_rc
        push_rc=0
        se_push "$repo_dir" || push_rc=$?
        if [ "$push_rc" -eq 1 ]; then
            pal_log "warn" "ch_resolve: push failed after resolving $repo_path"
        fi
    fi

    return 0
}

# ch_resolve_all — resolve all conflicts with a given resolution
# Usage: ch_resolve_all <repo_dir> <resolution>
# Returns: 0 if all resolved, 1 if any failed
ch_resolve_all() {
    local repo_dir resolution
    repo_dir="$1"
    resolution="$2"

    local conflicts
    conflicts=$(ch_list_conflicts "$repo_dir")
    [ -z "$conflicts" ] && return 0

    local fail_file
    fail_file=$(mktemp)
    printf '' > "$fail_file"

    printf '%s\n' "$conflicts" | while IFS= read -r conflict_path; do
        [ -z "$conflict_path" ] && continue
        local repo_path
        repo_path=$(printf '%s' "$conflict_path" | sed 's/\.conflict$//')
        if ! ch_resolve "$repo_dir" "$repo_path" "$resolution"; then
            printf 'fail' > "$fail_file"
        fi
    done

    local had_failure
    had_failure=$(cat "$fail_file")
    rm -f "$fail_file"
    [ -n "$had_failure" ] && return 1
    return 0
}

# --- Sprint 0.9: Interactive Resolution Operations ---

# _ch_marker_name — derive try marker filename from repo_path
# Replaces / with _ (e.g., gb/pokemon_red.srm -> gb_pokemon_red.srm)
_ch_marker_name() {
    printf '%s' "$1" | sed 's|/|_|g'
}

# _ch_marker_path — full path to try marker for a repo_path
_ch_marker_path() {
    local repo_dir repo_path
    repo_dir="$1"
    repo_path="$2"
    printf '%s/.continuity/trying/%s' "$repo_dir" "$(_ch_marker_name "$repo_path")"
}

# ch_is_trying — check if a save file is in trying state
# Usage: ch_is_trying <repo_dir> <repo_path>
# Returns: 0 if trying (marker exists), 1 if not
ch_is_trying() {
    local repo_dir repo_path
    repo_dir="$1"
    repo_path="$2"

    [ -f "$(_ch_marker_path "$repo_dir" "$repo_path")" ]
}

# ch_is_trying_modified — detect the Pokémon scenario
# Usage: ch_is_trying_modified <repo_dir> <repo_path>
# Returns: 0 if trying AND modified since try, 1 otherwise
ch_is_trying_modified() {
    local repo_dir repo_path marker_file
    repo_dir="$1"
    repo_path="$2"
    marker_file=$(_ch_marker_path "$repo_dir" "$repo_path")

    [ -f "$marker_file" ] || return 1

    local stored_checksum device_path current_checksum
    stored_checksum=$(grep '^checksum=' "$marker_file" | sed 's/^checksum=//')
    device_path=$(grep '^device_path=' "$marker_file" | sed 's/^device_path=//')

    [ -z "$stored_checksum" ] && return 1
    [ -z "$device_path" ] && return 1
    [ -f "$device_path" ] || return 1

    current_checksum=$(md5sum "$device_path" | cut -d' ' -f1)

    [ "$current_checksum" != "$stored_checksum" ]
}

# ch_get_conflict_info — parse one conflict's metadata
# Usage: ch_get_conflict_info <repo_dir> <repo_path>
# Prints key-value pairs to stdout. Returns 0 on success, 1 on error.
ch_get_conflict_info() {
    local repo_dir repo_path
    repo_dir="$1"
    repo_path="$2"

    local conflict_file
    conflict_file="$repo_dir/$repo_path.conflict"

    if [ ! -f "$conflict_file" ]; then
        pal_log "warn" "ch_get_conflict_info: no .conflict for $repo_path"
        return 1
    fi

    # Parse JSON fields
    local remote_device remote_timestamp local_device local_timestamp status
    remote_device=$(grep '"remote_device"' "$conflict_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    remote_timestamp=$(grep '"remote_timestamp"' "$conflict_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    local_device=$(grep '"local_device"' "$conflict_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    local_timestamp=$(grep '"local_timestamp"' "$conflict_file" | sed 's/.*: *"\([^"]*\)".*/\1/')
    status=$(grep '"status"' "$conflict_file" | sed 's/.*: *"\([^"]*\)".*/\1/')

    # Validate required fields
    if [ -z "$remote_device" ] || [ -z "$local_device" ] || [ -z "$status" ]; then
        pal_log "warn" "ch_get_conflict_info: missing fields in $conflict_file"
        return 1
    fi

    # Derive system and game from path
    local system game
    system=$(printf '%s' "$repo_path" | sed 's|/.*||')
    game=$(printf '%s' "$repo_path" | sed 's|.*/||; s|\.srm$||; s|\.sav$||')

    # Determine active_version and trying_modified
    local active_version trying_modified
    active_version="remote"
    trying_modified="no"

    if ch_is_trying "$repo_dir" "$repo_path"; then
        local marker_file
        marker_file=$(_ch_marker_path "$repo_dir" "$repo_path")
        active_version=$(grep '^version=' "$marker_file" | sed 's/^version=//')
        [ -z "$active_version" ] && active_version="remote"

        if ch_is_trying_modified "$repo_dir" "$repo_path"; then
            trying_modified="yes"
        fi
    fi

    printf 'file=%s\n' "$repo_path"
    printf 'system=%s\n' "$system"
    printf 'game=%s\n' "$game"
    printf 'remote_device=%s\n' "$remote_device"
    printf 'remote_timestamp=%s\n' "$remote_timestamp"
    printf 'local_device=%s\n' "$local_device"
    printf 'local_timestamp=%s\n' "$local_timestamp"
    printf 'status=%s\n' "$status"
    printf 'active_version=%s\n' "$active_version"
    printf 'trying_modified=%s\n' "$trying_modified"

    return 0
}

# ch_list_conflicts_detailed — list all conflicts with full metadata
# Usage: ch_list_conflicts_detailed <repo_dir>
# Prints multiple ch_get_conflict_info blocks separated by blank lines.
# Returns: 0 always
ch_list_conflicts_detailed() {
    local repo_dir
    repo_dir="$1"

    local conflicts
    conflicts=$(ch_list_conflicts "$repo_dir")
    [ -z "$conflicts" ] && return 0

    local first
    first=1
    printf '%s\n' "$conflicts" | while IFS= read -r conflict_path; do
        [ -z "$conflict_path" ] && continue
        local repo_path
        repo_path=$(printf '%s' "$conflict_path" | sed 's/\.conflict$//')

        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf '\n'
        fi
        ch_get_conflict_info "$repo_dir" "$repo_path" 2>/dev/null || true
    done
    return 0
}

# ch_count_conflicts — count unresolved conflicts
# Usage: ch_count_conflicts <repo_dir>
# Prints a single integer to stdout. Returns: 0 always.
ch_count_conflicts() {
    local repo_dir
    repo_dir="$1"

    local conflicts
    conflicts=$(ch_list_conflicts "$repo_dir")
    if [ -z "$conflicts" ]; then
        printf '0\n'
    else
        printf '%s\n' "$conflicts" | grep -c '.'
    fi
    return 0
}

# ch_try_version — swap a save version into the device's active slot
# Usage: ch_try_version <repo_dir> <repo_path> <version>
# version: remote or local
# Prints the device save path to stdout. Returns: 0 on success, 1 on error.
ch_try_version() {
    local repo_dir repo_path version
    repo_dir="$1"
    repo_path="$2"
    version="$3"

    # Validate conflict exists
    if [ ! -f "$repo_dir/$repo_path.conflict" ]; then
        pal_log "error" "ch_try_version: no .conflict for $repo_path"
        return 1
    fi

    # Validate version
    case "$version" in
        remote|local) ;;
        *)
            pal_log "error" "ch_try_version: invalid version '$version'"
            return 1
            ;;
    esac

    # Get device save path
    local device_path
    device_path=$(pm_repo_to_local "$repo_path" 2>/dev/null) || {
        pal_log "error" "ch_try_version: pm_repo_to_local failed for $repo_path"
        return 1
    }

    # Determine source file
    local source_file
    if [ "$version" = "remote" ]; then
        source_file="$repo_dir/$repo_path"
    else
        # Try direct path first, fall back to glob
        source_file="$repo_dir/$repo_path.$CONTINUITY_DEVICE_NAME.local"
        if [ ! -f "$source_file" ]; then
            source_file=$(find "$repo_dir/$(dirname "$repo_path")" \
                -name "$(basename "$repo_path").*.local" \
                ! -path "*/.git/*" \
                2>/dev/null | head -1)
        fi
        if [ -z "$source_file" ] || [ ! -f "$source_file" ]; then
            pal_log "error" "ch_try_version: no .local file for $repo_path"
            return 1
        fi
    fi

    # Ensure parent directory exists and copy
    mkdir -p "$(dirname "$device_path")"
    if ! cp "$source_file" "$device_path"; then
        pal_log "error" "ch_try_version: cp failed to $device_path"
        return 1
    fi

    # Compute checksum
    local checksum
    checksum=$(md5sum "$device_path" | cut -d' ' -f1)

    # Create trying directory with .gitignore
    local trying_dir
    trying_dir="$repo_dir/.continuity/trying"
    if [ ! -d "$trying_dir" ]; then
        mkdir -p "$trying_dir"
    fi
    if [ ! -f "$trying_dir/.gitignore" ]; then
        printf '*\n!.gitignore\n' > "$trying_dir/.gitignore"
    fi

    # Write marker
    local marker_file
    marker_file=$(_ch_marker_path "$repo_dir" "$repo_path")
    printf 'version=%s\nchecksum=%s\ndevice_path=%s\n' "$version" "$checksum" "$device_path" \
        > "$marker_file"

    pal_log "info" "ch_try_version: copied $version of $repo_path to $device_path"
    printf '%s\n' "$device_path"
    return 0
}

# ch_get_active_version — check which version is in the device's active slot
# Usage: ch_get_active_version <repo_dir> <repo_path>
# Prints remote or local to stdout. Returns: 0 always.
ch_get_active_version() {
    local repo_dir repo_path marker_file
    repo_dir="$1"
    repo_path="$2"
    marker_file=$(_ch_marker_path "$repo_dir" "$repo_path")

    if [ -f "$marker_file" ]; then
        local ver
        ver=$(grep '^version=' "$marker_file" | sed 's/^version=//')
        [ -n "$ver" ] && printf '%s\n' "$ver" && return 0
    fi

    printf 'remote\n'
    return 0
}

# ch_clear_try_markers — clean up all try markers
# Usage: ch_clear_try_markers <repo_dir>
# Returns: 0 always
ch_clear_try_markers() {
    local repo_dir trying_dir
    repo_dir="$1"
    trying_dir="$repo_dir/.continuity/trying"

    [ -d "$trying_dir" ] || return 0

    find "$trying_dir" -maxdepth 1 -type f ! -name '.gitignore' -exec rm -f {} + 2>/dev/null || true
    return 0
}

# ch_promote_trying — accept the modified trying version as the resolution
# Usage: ch_promote_trying <repo_dir> <repo_path>
# Returns: 0 on success, 1 on error
ch_promote_trying() {
    local repo_dir repo_path
    repo_dir="$1"
    repo_path="$2"

    # Must be trying-modified
    if ! ch_is_trying_modified "$repo_dir" "$repo_path"; then
        pal_log "warn" "ch_promote_trying: not in trying-modified state for $repo_path"
        return 1
    fi

    local marker_file device_path
    marker_file=$(_ch_marker_path "$repo_dir" "$repo_path")
    device_path=$(grep '^device_path=' "$marker_file" | sed 's/^device_path=//')

    # Copy device save over canonical .srm in repo
    if ! cp "$device_path" "$repo_dir/$repo_path"; then
        pal_log "error" "ch_promote_trying: cp failed for $repo_path"
        return 1
    fi

    # Remove .local file(s) and .conflict metadata
    local srm_basename srm_dir local_files
    srm_basename=$(basename "$repo_path")
    srm_dir=$(dirname "$repo_path")
    local_files=$(find "$repo_dir/$srm_dir" \
        -name "$srm_basename.*.local" \
        ! -path "*/.git/*" \
        2>/dev/null)

    "$CONTINUITY_GIT_BIN" -C "$repo_dir" add "$repo_path" 2>/dev/null

    printf '%s\n' "$local_files" | while IFS= read -r lf; do
        [ -z "$lf" ] && continue
        local lf_rel
        lf_rel=$(printf '%s' "$lf" | sed "s|^$repo_dir/||")
        rm -f "$lf"
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$lf_rel" >/dev/null 2>&1 || true
    done

    local conflict_meta
    conflict_meta="$repo_dir/$repo_path.conflict"
    rm -f "$conflict_meta"
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" rm --cached "$repo_path.conflict" >/dev/null 2>&1 || true

    # Commit
    if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit \
        -m "resolve: promote modified trying version of $repo_path" >/dev/null 2>&1; then
        pal_log "error" "ch_promote_trying: commit failed for $repo_path"
        return 1
    fi

    # Push if online
    if pal_is_online; then
        local push_rc
        push_rc=0
        se_push "$repo_dir" || push_rc=$?
        if [ "$push_rc" -eq 1 ]; then
            pal_log "warn" "ch_promote_trying: push failed after promoting $repo_path"
        fi
    fi

    # Update last_known_commit
    local head_hash
    head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
    cs_store_commit "$repo_dir" "$head_hash"

    # Remove try marker
    rm -f "$marker_file"

    pal_log "info" "ch_promote_trying: promoted modified trying version of $repo_path"
    return 0
}
