#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Path Mapper — translates between device save paths and canonical repo paths
# Requires the PAL to be loaded and validated before this file is sourced.
# Uses pal_get_platform_map() to locate its configuration.

# Module-level variables (set by pm_load_platform_map)
_pm_forward_map=""   # local_dir=canonical (one per line)
_pm_reverse_map=""   # canonical=local_dir (one per line)
_pm_rom_map=""       # canonical=rom_dir (one per line; v2.1 rom_paths)
_pm_loaded=""        # non-empty if map is loaded
_pm_name_style=""    # save_name_style: minui | retroarch | generic (v2 maps)
_pm_container=""     # save_container: raw | rzip (v2 maps)

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
    _pm_rom_map=""
    _pm_name_style=""
    _pm_container=""

    # Extract system_paths (and optional v2.1 rom_paths) blocks and parse
    # their "canonical": "dir" pairs. rom_paths exists for platforms whose
    # ROM folder names differ from their save folder names (muOS: saves
    # per-CORE, ROMs per-system) — absent, pm_rom_dir falls back to the
    # system_paths value exactly as before.
    local in_block
    in_block=""
    while IFS= read -r line; do
        case "$line" in
            *\"system_paths\"*)
                in_block="sys"
                continue
                ;;
            *\"rom_paths\"*)
                in_block="rom"
                continue
                ;;
        esac
        if [ -n "$in_block" ]; then
            # End of block
            case "$line" in
                *"}"*)
                    in_block=""
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
                if [ "$in_block" = "rom" ]; then
                    # canonical -> ROM directory name
                    _pm_rom_map="$_pm_rom_map
$canonical=$local_dir"
                else
                    # Forward: local_dir -> canonical
                    _pm_forward_map="$_pm_forward_map
$local_dir=$canonical"
                    # Reverse: canonical -> local_dir
                    _pm_reverse_map="$_pm_reverse_map
$canonical=$local_dir"
                fi
            fi
        fi
    done < "$map_file"

    # Trim leading newline
    _pm_forward_map=$(printf '%s' "$_pm_forward_map" | sed '/^$/d')
    _pm_reverse_map=$(printf '%s' "$_pm_reverse_map" | sed '/^$/d')
    _pm_rom_map=$(printf '%s' "$_pm_rom_map" | sed '/^$/d')

    if [ -z "$_pm_forward_map" ]; then
        pal_log "error" "No system_paths found in platform map: $map_file"
        return 1
    fi

    # v2 canonicalization keys (optional — absent on schema 1.0 maps, which
    # keep the legacy passthrough behavior). Simple top-level string values.
    _pm_name_style=$(sed -n 's/.*"save_name_style" *: *"\([^"]*\)".*/\1/p' "$map_file" | head -1)
    _pm_container=$(sed -n 's/.*"save_container" *: *"\([^"]*\)".*/\1/p' "$map_file" | head -1)

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

    # Look up canonical name from forward map. A save dir shared by
    # several systems (muOS per-core dirs: gb+gbc under Gambatte) has
    # multiple forward entries — deterministically take the FIRST listed;
    # pm_device_to_canonical refines the choice by ROM anchoring.
    local canonical
    canonical=$(printf '%s\n' "$_pm_forward_map" | grep "^${system_dir}=" | head -1 | sed 's/^[^=]*=//')

    if [ -z "$canonical" ]; then
        pal_log "warn" "Unknown system directory: $system_dir"
        return 1
    fi

    printf '%s/%s\n' "$canonical" "$filename"
    return 0
}

# pm_canonicals_for_dir <local_dir> — every canonical system mapped to a
# local save directory, one per line, in map order. Usually one; more
# when a platform's save layout is coarser than system identity (muOS
# per-core dirs).
pm_canonicals_for_dir() {
    printf '%s\n' "$_pm_forward_map" | grep "^${1}=" | sed 's/^[^=]*=//'
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
# Deduplicated preserving map order: a shared save dir (muOS per-core
# layout) must not be scanned twice.
pm_list_watched_dirs() {
    printf '%s\n' "$_pm_reverse_map" | while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        local local_dir
        local_dir=$(printf '%s' "$entry" | sed 's/^[^=]*=//')
        printf '%s/%s\n' "$CONTINUITY_SAVES_ROOT" "$local_dir"
    done | awk '!seen[$0]++'
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

# ── Shared save/state pattern definitions (single source of truth) ────
# Every scanner, filter, and pathspec that enumerates save/state files
# derives its patterns from here so the set can never drift across the
# codebase again (matrix §6: "every list that enumerates save extensions
# must be updated together"). .rtc is a save-class sibling — it carries a
# game's clock state and must travel WITH that game's SRAM identity. The
# state set covers all five NextUI state name-shapes (matrix §4) plus the
# RA/-ish auto slot. The tools/saves-repo/ digest classifier mirrors these
# by hand (it deploys into the user's repo and cannot source core).

# pm_save_grep_re — BRE matching a save-class path suffix (.srm/.sav/.rtc)
pm_save_grep_re() { printf '%s' '\.\(srm\|sav\|rtc\)$'; }

# pm_state_grep_re — BRE matching any state name-shape path suffix
pm_state_grep_re() { printf '%s' '\.\(st[0-9]\|state\|state[0-9]\|state\.[0-9]\|state\.auto\)$'; }

# pm_save_or_state_grep_re — union of the two (working-tree change filter)
pm_save_or_state_grep_re() {
    printf '%s' '\.\(srm\|sav\|rtc\|st[0-9]\|state\|state[0-9]\|state\.[0-9]\|state\.auto\)$'
}

# pm_find_saves <dir> [extra find predicates...] — save-class files under dir
pm_find_saves() {
    local dir
    dir="$1"
    shift
    find "$dir" \( -name '*.srm' -o -name '*.sav' -o -name '*.rtc' \) "$@" 2>/dev/null
}

# pm_find_states <dir> [extra find predicates...] — every state shape under dir
pm_find_states() {
    local dir
    dir="$1"
    shift
    find "$dir" \
        \( -name '*.st[0-9]' -o -name '*.state' -o -name '*.state[0-9]' \
           -o -name '*.state.[0-9]' -o -name '*.state.auto' \) "$@" 2>/dev/null
}

# ── Canonical save-format mapping (Sprint 2.0) ────────────────────────
# ONE canonical repo representation per save + per-device materialization.
# Canonicalization engages ONLY when the loaded map declares
# save_name_style AND the PAL exposes an existing CONTINUITY_ROMS_ROOT.
# Absent either signal, pm_device_to_canonical/pm_canonical_to_device
# delegate to the legacy directory primitives (byte-for-byte passthrough),
# so maps/tests without the v2 signals behave exactly as before.

# pm_canon_enabled — is name-style canonicalization active?
pm_canon_enabled() {
    [ -n "$_pm_name_style" ] && \
    [ -n "$CONTINUITY_ROMS_ROOT" ] && \
    [ -d "$CONTINUITY_ROMS_ROOT" ]
}

# pm_rom_ext_strip — remove a trailing 2–4 char ROM extension (matrix §2).
# The repo-side fallback when no ROM list resolves identity. Names with no
# such extension (spaced/parenthesized titles) pass through unchanged.
pm_rom_ext_strip() {
    printf '%s' "$1" | sed 's/\.[A-Za-z0-9]\{2,4\}$//'
}

# pm_container_class <file> — sniff the 8-byte container magic.
# Prints "rzip" for RetroArch's RZIP container (#RZIPv\x01#), else "raw".
# Nonexistent/short files and the snes9x #!s9xsnp state magic all read raw.
pm_container_class() {
    local f magic
    f="$1"
    if [ ! -f "$f" ]; then
        printf 'raw\n'
        return 0
    fi
    magic=$(dd if="$f" bs=1 count=8 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    if [ "$magic" = "23525a4950760123" ]; then
        printf 'rzip\n'
    else
        printf 'raw\n'
    fi
    return 0
}

# pm_rom_dir <canonical_system> — absolute ROM directory for a system.
# A v2.1 rom_paths entry wins (platforms whose ROM folders are not named
# like their save folders — muOS); otherwise tries
# CONTINUITY_ROMS_ROOT/<local_dir> then the NextUI long-folder form
# CONTINUITY_ROMS_ROOT/*(<local_dir>). Returns 1 if none exists.
pm_rom_dir() {
    local canonical local_dir cand rom_dir
    canonical="$1"
    [ -n "$CONTINUITY_ROMS_ROOT" ] || return 1
    rom_dir=$(printf '%s\n' "$_pm_rom_map" | grep "^${canonical}=" | head -1 | sed 's/^[^=]*=//')
    if [ -n "$rom_dir" ] && [ -d "$CONTINUITY_ROMS_ROOT/$rom_dir" ]; then
        printf '%s\n' "$CONTINUITY_ROMS_ROOT/$rom_dir"
        return 0
    fi
    local_dir=$(printf '%s\n' "$_pm_reverse_map" | grep "^${canonical}=" | head -1 | sed 's/^[^=]*=//')
    [ -n "$local_dir" ] || return 1
    if [ -d "$CONTINUITY_ROMS_ROOT/$local_dir" ]; then
        printf '%s\n' "$CONTINUITY_ROMS_ROOT/$local_dir"
        return 0
    fi
    cand=$(find "$CONTINUITY_ROMS_ROOT" -maxdepth 1 -type d -name "*($local_dir)" 2>/dev/null | head -1)
    if [ -n "$cand" ]; then
        printf '%s\n' "$cand"
        return 0
    fi
    return 1
}

# pm_rom_match_basename <canonical_system> <stem> — ROM-anchored identity.
# A save stem (filename minus its save extension) matches a ROM either by
# full filename (MinUI style: stem == "Game.gba") or by ext-stripped name
# (RA/Generic: stem == "Game"). Prints the canonical basename (the ROM's
# ext-stripped name) on a match; empty when no ROM matches.
pm_rom_match_basename() {
    local canonical stem rom_dir
    canonical="$1"
    stem="$2"
    rom_dir=$(pm_rom_dir "$canonical") || return 0
    find "$rom_dir" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r romfile; do
        local rname rstrip
        rname=$(basename "$romfile")
        rstrip=$(pm_rom_ext_strip "$rname")
        if [ "$rname" = "$stem" ] || [ "$rstrip" = "$stem" ]; then
            printf '%s\n' "$rstrip"
            break
        fi
    done
}

# pm_rom_fullname <canonical_system> <basename> — reverse ROM lookup.
# Prints the ROM's full on-disk filename whose ext-stripped name equals
# <basename> (so MinUI materialization can re-embed the ROM extension).
# Empty when no ROM matches — the caller then skips materialization.
pm_rom_fullname() {
    local canonical base rom_dir
    canonical="$1"
    base="$2"
    rom_dir=$(pm_rom_dir "$canonical") || return 0
    find "$rom_dir" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r romfile; do
        local rname rstrip
        rname=$(basename "$romfile")
        rstrip=$(pm_rom_ext_strip "$rname")
        if [ "$rstrip" = "$base" ] || [ "$rname" = "$base" ]; then
            printf '%s\n' "$rname"
            break
        fi
    done
}

# _pm_canonicalize_filename <canonical_system> <filename> — canonical
# filename for a save (strip save ext -> ROM-anchor/heuristic basename ->
# canonical extension: .srm for SRAM classes, .rtc kept). Non-save names
# pass through unchanged. Shared by pm_device_to_canonical (device side)
# and pm_repo_canonicalize (migration, repo side).
_pm_canonicalize_filename() {
    local system filename stem canon_ext base
    system="$1"
    filename="$2"
    case "$filename" in
        *.rtc) stem=${filename%.rtc}; canon_ext=".rtc" ;;
        *.srm) stem=${filename%.srm}; canon_ext=".srm" ;;
        *.sav) stem=${filename%.sav}; canon_ext=".srm" ;;
        *)     printf '%s\n' "$filename"; return 0 ;;
    esac
    base=$(pm_rom_match_basename "$system" "$stem")
    [ -n "$base" ] || base=$(pm_rom_ext_strip "$stem")
    printf '%s%s\n' "$base" "$canon_ext"
}

# pm_device_to_canonical <device_path> — device save path -> canonical repo
# path (<system>/<basename>.srm, raw). Sniffs the container first: real
# RZIP magic quarantines (rc 3, nothing stored). Legacy passthrough when
# canonicalization is disabled.
#   0 -> prints canonical repo path
#   1 -> unknown system directory
#   3 -> compressed save quarantined (prints nothing)
pm_device_to_canonical() {
    local device_path repo_dirpath system filename
    device_path="$1"

    repo_dirpath=$(pm_local_to_repo "$device_path") || return 1
    system=$(printf '%s' "$repo_dirpath" | sed 's|/.*||')
    filename=$(printf '%s' "$repo_dirpath" | sed 's|[^/]*/||')

    # Container sniff — only real RZIP bytes trigger it, in any mode.
    if [ "$(pm_container_class "$device_path")" = "rzip" ]; then
        pal_log "warn" "Compressed save skipped — set save format to uncompressed: $repo_dirpath"
        return 3
    fi

    if ! pm_canon_enabled; then
        printf '%s\n' "$repo_dirpath"
        return 0
    fi

    # Shared save dir (several canonicals map to it — muOS per-core
    # layout): resolve the true system by ROM anchor. The candidate whose
    # ROM directory contains a matching game wins; no match anywhere
    # falls through to the first-listed candidate (already in $system)
    # with the ext-strip heuristic, exactly like the single-system case.
    local system_dir candidates n stem cand base
    system_dir=$(printf '%s' "$device_path" | sed "s|^$CONTINUITY_SAVES_ROOT/||" | sed 's|/[^/]*$||')
    candidates=$(pm_canonicals_for_dir "$system_dir")
    n=$(printf '%s\n' "$candidates" | grep -c .)
    if [ "$n" -gt 1 ]; then
        case "$filename" in
            *.rtc) stem=${filename%.rtc} ;;
            *.srm) stem=${filename%.srm} ;;
            *.sav) stem=${filename%.sav} ;;
            *)     stem="" ;;
        esac
        if [ -n "$stem" ]; then
            # Canonical names are snake_case (no whitespace) — plain
            # word-splitting iteration is safe.
            for cand in $candidates; do
                base=$(pm_rom_match_basename "$cand" "$stem")
                if [ -n "$base" ]; then
                    system="$cand"
                    break
                fi
            done
        fi
    fi

    printf '%s/%s\n' "$system" "$(_pm_canonicalize_filename "$system" "$filename")"
    return 0
}

# pm_repo_canonicalize <repo_relative_path> — canonical repo path for a
# device-natively-named repo file. Used by migrate_repo.sh: the file is
# already under its canonical system directory, so only the basename is
# rewritten. ROM-anchored when CONTINUITY_ROMS_ROOT is available, else the
# 2-4 char heuristic. Always canonicalizes (migration intent) — it does
# not consult pm_canon_enabled. An already-canonical path is returned
# unchanged (idempotent). Container sniffing is the caller's job.
pm_repo_canonicalize() {
    local repo_path system filename
    repo_path="$1"
    system=$(printf '%s' "$repo_path" | sed 's|/.*||')
    filename=$(printf '%s' "$repo_path" | sed 's|.*/||')
    printf '%s/%s\n' "$system" "$(_pm_canonicalize_filename "$system" "$filename")"
    return 0
}

# pm_canonical_to_device <canonical_repo_path> — canonical repo path ->
# device path with the platform's native filename, ROM-gated. Legacy
# passthrough when canonicalization is disabled.
#   0 -> prints device path
#   1 -> unknown canonical system
#   2 -> no matching ROM on this device (sparse skip; prints nothing)
pm_canonical_to_device() {
    local repo_path device_legacy system filename base canon_ext rom_full local_dir dev_name
    repo_path="$1"

    device_legacy=$(pm_repo_to_local "$repo_path") || return 1

    if ! pm_canon_enabled; then
        printf '%s\n' "$device_legacy"
        return 0
    fi

    system=$(printf '%s' "$repo_path" | sed 's|/.*||')
    filename=$(printf '%s' "$repo_path" | sed 's|[^/]*/||')
    case "$filename" in
        *.rtc) base=${filename%.rtc}; canon_ext=".rtc" ;;
        *.srm) base=${filename%.srm}; canon_ext=".srm" ;;
        *.sav) base=${filename%.sav}; canon_ext=".srm" ;;
        *)     printf '%s\n' "$device_legacy"; return 0 ;;
    esac

    rom_full=$(pm_rom_fullname "$system" "$base")
    [ -n "$rom_full" ] || return 2

    local_dir=$(printf '%s\n' "$_pm_reverse_map" | grep "^${system}=" | sed 's/^[^=]*=//')

    case "$_pm_name_style" in
        minui)
            if [ "$canon_ext" = ".rtc" ]; then
                dev_name="$rom_full.rtc"
            else
                dev_name="$rom_full.sav"
            fi
            ;;
        generic)
            if [ "$canon_ext" = ".rtc" ]; then
                dev_name="$base.rtc"
            else
                dev_name="$base.sav"
            fi
            ;;
        *)  # retroarch (and any unrecognized style): keep the canonical name
            dev_name="$base$canon_ext"
            ;;
    esac

    printf '%s/%s/%s\n' "$CONTINUITY_SAVES_ROOT" "$local_dir" "$dev_name"
    return 0
}
