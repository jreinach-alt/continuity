#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Sync Engine — git operations layer for Continuity
# Provides clone, pull, push, stage, commit, and status query functions.
# Requires the PAL to be loaded and validated before this file is sourced.
# All git commands use $CONTINUITY_GIT_BIN and explicit -C $repo_dir.

# Module-level state (set by se_init)
_SE_DEVICE_NAME=""

# se_init — set device name and configure git identity in the repo
# Usage: se_init <repo_dir> <device_name>
se_init() {
    local repo_dir device_name
    repo_dir="$1"
    device_name="$2"
    _SE_DEVICE_NAME="$device_name"

    # Configure git identity if not already set
    local existing_email
    existing_email=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" config --local --get user.email 2>/dev/null) || true
    if [ -z "$existing_email" ]; then
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.email "continuity@device"
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.name "Continuity"
    fi

    # Disable commit signing (constrained devices have no GPG/SSH signing)
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config commit.gpgsign false
}

# se_clone — clone a remote repo into target_dir
# Usage: se_clone <repo_url> <target_dir>
# Returns: 0 success, 1 failure
se_clone() {
    local repo_url target_dir
    repo_url="$1"
    target_dir="$2"

    if ! "$CONTINUITY_GIT_BIN" clone "$repo_url" "$target_dir" 2>&1; then
        pal_log "error" "Clone failed: $repo_url"
        return 1
    fi
    return 0
}

# se_pull — pull latest from remote with fast-forward only
# Usage: se_pull <repo_dir>
# Returns: 0 success, 1 diverged, 2 network error
se_pull() {
    local repo_dir stderr_file rc
    repo_dir="$1"
    stderr_file=$(mktemp)

    rc=0
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" pull --ff-only origin main 2>"$stderr_file" || rc=$?

    if [ "$rc" -eq 0 ]; then
        rm -f "$stderr_file"
        return 0
    fi

    local stderr_content
    stderr_content=$(cat "$stderr_file")
    rm -f "$stderr_file"

    # Check for network errors
    case "$stderr_content" in
        *"unable to connect"*|*"failed to connect"*|*"could not resolve"*|*"timeout"*|*"SSL"*|*"unable to access"*|*"Could not resolve"*|*"Failed to connect"*)
            pal_log "error" "Pull network error: $stderr_content"
            return 2
            ;;
    esac

    # Diverged or other error
    pal_log "warn" "Pull failed (diverged?): $stderr_content"
    return 1
}

# se_stage_files — add files to the git index
# Usage: se_stage_files <repo_dir> <file_list>
# file_list is newline-delimited, paths relative to repo root
# Returns: 0 success, 1 failure
se_stage_files() {
    local repo_dir file_list
    repo_dir="$1"
    file_list="$2"

    local fail_file
    fail_file=$(mktemp)
    printf '' > "$fail_file"

    printf '%s\n' "$file_list" | while IFS= read -r filepath; do
        [ -z "$filepath" ] && continue
        if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" add "$filepath" 2>&1; then
            pal_log "error" "Failed to stage: $filepath"
            printf 'fail\n' > "$fail_file"
            break
        fi
    done

    local had_failure
    had_failure=$(cat "$fail_file")
    rm -f "$fail_file"
    if [ -n "$had_failure" ]; then
        return 1
    fi
    return 0
}

# se_commit — commit staged files with auto-generated or custom message
# Usage: se_commit <repo_dir> <file_list> [subject_override]
# file_list is newline-delimited (used for subject generation)
# Returns: 0 success, 1 failure
se_commit() {
    local repo_dir file_list subject_override
    repo_dir="$1"
    file_list="$2"
    subject_override="${3:-}"

    local subject
    if [ -n "$subject_override" ]; then
        subject="$subject_override"
    else
        # Count files
        local count
        count=$(printf '%s\n' "$file_list" | grep -c '.')
        if [ "$count" -eq 1 ]; then
            subject="$file_list updated"
        else
            subject="$count saves updated"
        fi
    fi

    # Build timestamp
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

    # Build commit message
    local msg
    msg=$(printf '%s\n\ndevice: %s\ntimestamp: %s' "$subject" "$_SE_DEVICE_NAME" "$timestamp")

    if ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit -m "$msg" 2>&1; then
        pal_log "error" "Commit failed"
        return 1
    fi
    return 0
}

# se_push — push to remote with retry on network errors
# Usage: se_push <repo_dir>
# Returns: 0 success, 1 persistent failure, 2 offline/deferred
se_push() {
    local repo_dir
    repo_dir="$1"

    # Check if online first
    if ! pal_is_online; then
        pal_log "info" "Offline, push deferred"
        return 2
    fi

    local attempt max_attempts delay stderr_file rc
    attempt=0
    max_attempts=5
    delay=2

    while [ "$attempt" -lt "$max_attempts" ]; do
        stderr_file=$(mktemp)
        rc=0
        "$CONTINUITY_GIT_BIN" -C "$repo_dir" push origin main 2>"$stderr_file" || rc=$?

        if [ "$rc" -eq 0 ]; then
            rm -f "$stderr_file"
            return 0
        fi

        local stderr_content
        stderr_content=$(cat "$stderr_file")
        rm -f "$stderr_file"

        # Check if this is a network error (retryable)
        case "$stderr_content" in
            *"unable to connect"*|*"failed to connect"*|*"could not resolve"*|*"timeout"*|*"SSL"*|*"unable to access"*|*"Could not resolve"*|*"Failed to connect"*)
                attempt=$((attempt + 1))
                if [ "$attempt" -lt "$max_attempts" ]; then
                    pal_log "warn" "Push failed (attempt $attempt), retrying in ${delay}s"
                    sleep "$delay"
                    delay=$((delay * 2))
                fi
                ;;
            *)
                # Non-network error, don't retry
                pal_log "error" "Push failed (non-retryable): $stderr_content"
                return 1
                ;;
        esac
    done

    pal_log "error" "Push failed after $max_attempts attempts"
    return 1
}

# se_has_staged_changes — check if there are staged changes
# Usage: se_has_staged_changes <repo_dir>
# Returns: 0 if staged changes exist, 1 if index is clean
se_has_staged_changes() {
    local repo_dir
    repo_dir="$1"
    ! "$CONTINUITY_GIT_BIN" -C "$repo_dir" diff --cached --quiet 2>/dev/null
}

# se_has_unpushed_commits — check if local is ahead of remote
# Usage: se_has_unpushed_commits <repo_dir>
# Returns: 0 if local is ahead, 1 if up to date
se_has_unpushed_commits() {
    local repo_dir output
    repo_dir="$1"
    output=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" log '@{u}..HEAD' --oneline 2>/dev/null)
    [ -n "$output" ]
}

# se_get_head_commit — print the current HEAD commit hash
# Usage: se_get_head_commit <repo_dir>
se_get_head_commit() {
    local repo_dir
    repo_dir="$1"
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD
}
