#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Path Mapper — translates between device save paths and canonical repo paths
# Requires the PAL to be loaded and validated before this file is sourced.
# Uses pal_get_platform_map() to locate its configuration.

# Module-level variables (set by pm_load_platform_map)
_pm_forward_map=""   # local_dir=canonical (one per line)
_pm_reverse_map=""   # canonical=local_dir (one per line)
_pm_loaded=""        # non-empty if map is loaded

# pm_load_platform_map — parse the platform map JSON at the given path
# Sets module-internal lookup structures for system path translation.
# Must be called before any other pm_* function.
# Usage: pm_load_platform_map <platform_map_file>
# Returns 0 on success, 1 on error.
pm_load_platform_map() {
    local map_file
    map_file="$1"

    if [ ! -f "$map_file" ]; then
        pal_log "error" "Platform map not found: $map_file"
        return 1
    fi

    _pm_forward_map=""
    _pm_reverse_map=""

    # Extract system_paths block and parse key=value pairs
    local in_block
    in_block=0
    while IFS= read -r line; do
        case "$line" in
            *\"system_paths\"*)
                in_block=1
                continue
                ;;
        esac
        if [ "$in_block" -eq 1 ]; then
            # End of block
            case "$line" in
                *"}"*)
                    in_block=0
                    continue
                    ;;
            esac
            # Parse "canonical": "local_dir" lines
            # Extract canonical name (first quoted value)
            local canonical
            canonical=$(printf '%s' "$line" | sed -n 's/.*"\([^"]*\)" *: *"\([^"]*\)".*/\1/p')
            local local_dir
            local_dir=$(printf '%s' "$line" | sed -n 's/.*"\([^"]*\)" *: *"\([^"]*\)".*/\2/p')
            if [ -n "$canonical" ] && [ -n "$local_dir" ]; then
                # Forward: local_dir -> canonical
                _pm_forward_map="$_pm_forward_map
$local_dir=$canonical"
                # Reverse: canonical -> local_dir
                _pm_reverse_map="$_pm_reverse_map
$canonical=$local_dir"
            fi
        fi
    done < "$map_file"

    # Trim leading newline
    _pm_forward_map=$(printf '%s' "$_pm_forward_map" | sed '/^$/d')
    _pm_reverse_map=$(printf '%s' "$_pm_reverse_map" | sed '/^$/d')

    if [ -z "$_pm_forward_map" ]; then
        pal_log "error" "No system_paths found in platform map: $map_file"
        return 1
    fi

    _pm_loaded="1"
    return 0
}

# pm_local_to_repo — convert a local device path to a repo-relative path
# Usage: pm_local_to_repo <local_path>
# Example: /mnt/SDCARD/Saves/SFC/super_metroid.srm -> snes/super_metroid.srm
# Returns 0 on success, 1 if system directory not in platform map.
pm_local_to_repo() {
    local local_path
    local_path="$1"

    # Strip saves root prefix to get system_dir/filename
    local rel_path
    rel_path=$(printf '%s' "$local_path" | sed "s|^$CONTINUITY_SAVES_ROOT/||")

    if [ "$rel_path" = "$local_path" ]; then
        pal_log "warn" "Path not under saves root: $local_path"
        return 1
    fi

    # Split into system dir and filename
    local filename
    filename=$(printf '%s' "$rel_path" | sed 's|.*/||')
    local system_dir
    system_dir=$(printf '%s' "$rel_path" | sed 's|/[^/]*$||')

    if [ "$system_dir" = "$filename" ]; then
        pal_log "warn" "No system directory in path: $local_path"
        return 1
    fi

    # Look up canonical name from forward map
    local canonical
    canonical=$(printf '%s\n' "$_pm_forward_map" | grep "^${system_dir}=" | sed 's/^[^=]*=//')

    if [ -z "$canonical" ]; then
        pal_log "warn" "Unknown system directory: $system_dir"
        return 1
    fi

    printf '%s/%s\n' "$canonical" "$filename"
    return 0
}

# pm_repo_to_local — convert a repo-relative path to an absolute local path
# Usage: pm_repo_to_local <repo_path>
# Example: snes/super_metroid.srm -> /mnt/SDCARD/Saves/SFC/super_metroid.srm
# Returns 0 on success, 1 if canonical system name not in platform map.
pm_repo_to_local() {
    local repo_path
    repo_path="$1"

    # Split into canonical name and filename
    local canonical
    canonical=$(printf '%s' "$repo_path" | sed 's|/.*||')
    local filename
    filename=$(printf '%s' "$repo_path" | sed 's|[^/]*/||')

    if [ "$canonical" = "$filename" ] || [ -z "$canonical" ] || [ -z "$filename" ]; then
        pal_log "warn" "Invalid repo path format: $repo_path"
        return 1
    fi

    # Look up local dir from reverse map
    local local_dir
    local_dir=$(printf '%s\n' "$_pm_reverse_map" | grep "^${canonical}=" | sed 's/^[^=]*=//')

    if [ -z "$local_dir" ]; then
        pal_log "warn" "Unknown canonical system: $canonical"
        return 1
    fi

    printf '%s/%s/%s\n' "$CONTINUITY_SAVES_ROOT" "$local_dir" "$filename"
    return 0
}

# pm_list_watched_dirs — list every local save directory to monitor
# Prints one absolute path per line, constructed from CONTINUITY_SAVES_ROOT
# and each platform-specific system directory. Does not check existence.
pm_list_watched_dirs() {
    printf '%s\n' "$_pm_reverse_map" | while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local local_dir
        local_dir=$(printf '%s' "$entry" | sed 's/^[^=]*=//')
        printf '%s/%s\n' "$CONTINUITY_SAVES_ROOT" "$local_dir"
    done
}

# ── Save states (opaque backup) ──────────────────────────────────────
# Save states are emulator-core-specific blobs backed up one-way,
# device → repo, under states/<dir>/<file>. No canonical translation:
# a state only means anything to the exact core (and often core version)
# that wrote it. CONTINUITY_STATES_ROOT is set by the platform PAL
# (NextUI: /mnt/SDCARD/.userdata/shared); empty disables state backup.

# pm_state_to_repo — map an absolute state path to its repo path.
# Usage: pm_state_to_repo <local_path>
# Prints e.g. states/SFC-snes9x/Game (USA).st0
pm_state_to_repo() {
    local local_path rel_path
    local_path="$1"
    [ -n "$CONTINUITY_STATES_ROOT" ] || return 1
    rel_path=$(printf '%s' "$local_path" | sed "s|^$CONTINUITY_STATES_ROOT/||")
    if [ "$rel_path" = "$local_path" ]; then
        pal_log "warn" "State path not under states root: $local_path"
        return 1
    fi
    printf 'states/%s\n' "$rel_path"
}
