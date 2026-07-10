#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Core Enrollment — platform-agnostic enrollment logic for Continuity
# Handles clone, credential storage, device registration, and git auth config.
# Requires the PAL and sync_engine to be loaded before this file is sourced.

# enroll_is_enrolled — check if device is enrolled
# Returns: 0 if enrolled, 1 if not enrolled
enroll_is_enrolled() {
    [ -d "$CONTINUITY_REPO_DIR" ] || return 1
    [ -d "$CONTINUITY_REPO_DIR/.git" ] || return 1
    [ -s "$CONTINUITY_REPO_DIR/.continuity/device_name" ] || return 1
    return 0
}

# enroll_store_credential — write PAT to credentials file
# Usage: enroll_store_credential <pat>
# Pre-clone: writes to temp location under parent of CONTINUITY_REPO_DIR
# Post-clone: writes to $CONTINUITY_REPO_DIR/.continuity/credentials
# Returns: 0 success, 1 failure
enroll_store_credential() {
    local pat target_dir target_file
    pat="$1"

    if [ -d "$CONTINUITY_REPO_DIR/.git" ]; then
        # Post-clone: write to final location
        target_dir="$CONTINUITY_REPO_DIR/.continuity"
        target_file="$target_dir/credentials"
    else
        # Pre-clone: write to temp location
        target_dir="$(dirname "$CONTINUITY_REPO_DIR")"
        target_file="$target_dir/.continuity_credentials_tmp"
    fi

    mkdir -p "$target_dir"
    printf '%s' "$pat" > "$target_file"
    chmod 0600 "$target_file" 2>/dev/null || true
    return 0
}

# enroll_configure_git_auth — configure git credential helper for the repo
# Usage: enroll_configure_git_auth <repo_dir>
# Returns: 0 success, 1 failure
enroll_configure_git_auth() {
    local repo_dir helper_script cred_file
    repo_dir="$1"
    helper_script="$repo_dir/.continuity/git_credential_helper.sh"
    cred_file="$repo_dir/.continuity/credentials"

    mkdir -p "$repo_dir/.continuity"

    printf '#!/bin/sh\nprintf '"'"'username=x-token\\npassword=%%s\\n'"'"' "$(cat "%s")"\n' "$cred_file" > "$helper_script"
    chmod +x "$helper_script"

    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config credential.helper "$helper_script"
    return 0
}

# enroll_write_device_json — write device registration JSON
# Usage: enroll_write_device_json <device_name> <platform>
# Returns: 0 success, 1 failure
enroll_write_device_json() {
    local device_name platform device_dir device_file timestamp
    device_name="$1"
    platform="$2"
    device_dir="$CONTINUITY_REPO_DIR/.continuity/devices"
    device_file="$device_dir/$device_name.json"

    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || timestamp=$(date '+%Y-%m-%dT%H:%M:%SZ')

    mkdir -p "$device_dir"
    printf '{\n  "_schema_version": "1.0",\n  "device_name": "%s",\n  "platform": "%s",\n  "enrolled_at": "%s",\n  "last_sync": null,\n  "last_push": null\n}\n' \
        "$device_name" "$platform" "$timestamp" > "$device_file"
    return 0
}

# _enroll_validate_device_name — validate device name format
# Usage: _enroll_validate_device_name <device_name>
# Returns: 0 valid, 1 invalid (logs error)
_enroll_validate_device_name() {
    local name
    name="$1"

    if [ -z "$name" ]; then
        pal_log "error" "Device name is empty"
        return 1
    fi

    # Check length (max 32)
    if [ "${#name}" -gt 32 ]; then
        pal_log "error" "Device name exceeds 32 characters: $name"
        return 1
    fi

    # Must match [a-z0-9-] only
    local cleaned
    cleaned=$(printf '%s' "$name" | sed 's/[a-z0-9-]//g')
    if [ -n "$cleaned" ]; then
        pal_log "error" "Device name contains invalid characters: $name"
        return 1
    fi

    # Must not start or end with hyphen
    case "$name" in
        -*|*-)
            pal_log "error" "Device name must not start or end with a hyphen: $name"
            return 1
            ;;
    esac

    return 0
}

# enroll_run — full enrollment flow
# Usage: enroll_run <repo_url> <device_name> <pat>
# Returns: 0 success, 1 failure
enroll_run() {
    local repo_url device_name pat
    repo_url="$1"
    device_name="$2"
    pat="$3"

    # Step 1: Validate inputs
    if [ -z "$repo_url" ]; then
        pal_log "error" "Enrollment failed: repo_url is empty"
        return 1
    fi
    if ! _enroll_validate_device_name "$device_name"; then
        return 1
    fi
    if [ -z "$pat" ]; then
        pal_log "error" "Enrollment failed: pat is empty"
        return 1
    fi

    # Step 2: Store credential pre-clone
    pal_log "info" "Storing credentials"
    if ! enroll_store_credential "$pat"; then
        pal_log "error" "Failed to store credentials"
        return 1
    fi

    # Step 2.5: Configure temporary credential helper for clone
    local tmp_cred_file tmp_helper parent_dir
    parent_dir="$(dirname "$CONTINUITY_REPO_DIR")"
    tmp_cred_file="$parent_dir/.continuity_credentials_tmp"
    tmp_helper="$parent_dir/.continuity_tmp_helper.sh"

    printf '#!/bin/sh\nprintf '"'"'username=x-token\\npassword=%%s\\n'"'"' "$(cat "%s")"\n' "$tmp_cred_file" > "$tmp_helper"
    chmod +x "$tmp_helper"

    # Export credential helper for the clone
    GIT_ASKPASS="$tmp_helper"
    export GIT_ASKPASS

    # Step 3: Clone
    # Log the URL with any embedded userinfo stripped — a user who
    # pastes https://x:TOKEN@host/... must not have the token land in
    # enroll.log (the PAT belongs in the pat field, never the URL).
    local log_url
    log_url=$(printf '%s' "$repo_url" | sed 's|://[^/@]*@|://|')
    pal_log "info" "Cloning repo: $log_url"
    if ! se_clone "$repo_url" "$CONTINUITY_REPO_DIR"; then
        pal_log "error" "Clone failed"
        unset GIT_ASKPASS
        rm -f "$tmp_helper"
        return 1
    fi

    unset GIT_ASKPASS
    rm -f "$tmp_helper"

    # Step 3.5: Verify default branch is main
    local branch
    branch=$("$CONTINUITY_GIT_BIN" -C "$CONTINUITY_REPO_DIR" branch --show-current 2>/dev/null)
    if [ -z "$branch" ]; then
        # Empty repo — no branch yet; create main branch with initial commit
        branch="main"
        "$CONTINUITY_GIT_BIN" -C "$CONTINUITY_REPO_DIR" checkout -b main 2>/dev/null || true
    fi
    if [ "$branch" != "main" ]; then
        pal_log "error" "Repo default branch is '$branch', expected 'main'"
        return 1
    fi

    # Step 4: Initialize sync engine
    se_init "$CONTINUITY_REPO_DIR" "$device_name"

    # Step 5: Move credentials to final location and configure git auth
    mkdir -p "$CONTINUITY_REPO_DIR/.continuity"
    if [ -f "$tmp_cred_file" ]; then
        mv "$tmp_cred_file" "$CONTINUITY_REPO_DIR/.continuity/credentials"
        chmod 0600 "$CONTINUITY_REPO_DIR/.continuity/credentials" 2>/dev/null || true
    fi
    enroll_configure_git_auth "$CONTINUITY_REPO_DIR"

    # Step 6: Write device JSON
    pal_log "info" "Writing device registration"
    if ! enroll_write_device_json "$device_name" "$CONTINUITY_PLATFORM"; then
        pal_log "error" "Failed to write device JSON"
        return 1
    fi

    # Step 7: Write device_name file (local-only, gitignored)
    printf '%s' "$device_name" > "$CONTINUITY_REPO_DIR/.continuity/device_name"

    # Step 8: Ensure .continuity/.gitignore exists
    printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$CONTINUITY_REPO_DIR/.continuity/.gitignore"

    # Step 9: Stage files
    local file_list
    file_list=".continuity/devices/$device_name.json
.continuity/.gitignore"
    if ! se_stage_files "$CONTINUITY_REPO_DIR" "$file_list"; then
        pal_log "error" "Failed to stage enrollment files"
        return 1
    fi

    # Step 10: Commit
    if ! se_commit "$CONTINUITY_REPO_DIR" "$file_list" "enroll: register $device_name"; then
        pal_log "error" "Failed to commit enrollment"
        return 1
    fi

    # Step 11: Push
    local push_rc
    push_rc=0
    se_push "$CONTINUITY_REPO_DIR" || push_rc=$?
    if [ "$push_rc" -eq 1 ]; then
        pal_log "error" "Failed to push enrollment"
        return 1
    fi

    # Step 12: Done
    pal_log "info" "Enrollment complete: $device_name"
    return 0
}
