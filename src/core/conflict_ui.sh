#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Conflict UI — shared, platform-agnostic resolution controller
#
# The §4/§5 state machine of docs/design/conflict-resolution-experience.md,
# driving the finished conflict ENGINE (src/core/conflict_handler.sh, ch_*)
# through the pal_ui_* rendering contract. Contains ZERO platform I/O: every
# user interaction goes through pal_ui_menu / pal_ui_message / pal_ui_confirm
# / pal_ui_handoff, which each platform (and the test PAL) implements. This
# is what makes the whole flow headless-testable, exactly like the sync
# phases.
#
# Design invariants honored here (normative, design §2/§4):
#   - Never lose either version before an explicit confirm — "resolve"
#     chooses which side is canonical; the loser stays as .local until the
#     user confirms (the engine guarantees this; the UI never offers a path
#     that violates it).
#   - Group by GAME identity, not by file: a game's SRAM (.srm/.sav) and its
#     .rtc share one identity and resolve to the SAME side — never a
#     Frankenstein (device-A .srm + device-B .rtc).
#   - Try is a first-class verb: load a version, go play, come back and
#     decide. A version played-on becomes a NEW third version that must
#     never be silently discarded (the "Pokémon scenario").
#   - keep_newest is offered but clock-guarded: when a timestamp is
#     missing/implausible the engine refuses, and the UI presents that as a
#     fall-back to manual choice, never an error dead-end.
#
# Prerequisites (sourced by the caller — daemon / launch / test harness):
#   - PAL: pal_log()
#   - src/core/conflict_handler.sh (ch_* API)
#   - a pal_ui_* implementation (NextUI shim, or the test PAL)
#
# Public functions:
#   cu_run, cu_list_groups, cu_group_members, cu_group_info, cu_group_label,
#   cu_try_group, cu_resolve_group, cu_promote_group, cu_clear_group_try

# _cu_identity_of — the game-group identity for a canonical repo path:
# the path with its save-class extension (.srm/.sav/.rtc) stripped. Mirrors
# the v2 .conflict "identity" field so grouping is consistent whether we
# read it or derive it.
_cu_identity_of() {
    printf '%s' "$1" | sed 's/\.srm$//; s/\.sav$//; s/\.rtc$//'
}

# cu_list_groups — the distinct game-identity groups with an unresolved
# conflict, one per line, deterministically ordered.
# Usage: cu_list_groups <repo_dir>
cu_list_groups() {
    local repo_dir
    repo_dir="$1"
    ch_list_conflicts "$repo_dir" | while IFS= read -r conflict_path; do
        [ -z "$conflict_path" ] && continue
        local repo_path identity
        repo_path=$(printf '%s' "$conflict_path" | sed 's/\.conflict$//')
        identity=$(_cu_identity_of "$repo_path")
        printf '%s\n' "$identity"
    done | sort -u
    return 0
}

# cu_group_members — the conflicted canonical repo paths (files) belonging to
# one game-identity group, one per line. These are what group operations
# apply to as a unit (e.g. gb/Pokemon Crystal.srm AND gb/Pokemon Crystal.rtc).
# Usage: cu_group_members <repo_dir> <identity>
cu_group_members() {
    local repo_dir identity
    repo_dir="$1"
    identity="$2"
    ch_list_conflicts "$repo_dir" | while IFS= read -r conflict_path; do
        [ -z "$conflict_path" ] && continue
        local repo_path member_identity
        repo_path=$(printf '%s' "$conflict_path" | sed 's/\.conflict$//')
        member_identity=$(_cu_identity_of "$repo_path")
        [ "$member_identity" = "$identity" ] && printf '%s\n' "$repo_path"
    done
    return 0
}

# cu_group_info — aggregate metadata for one group, as key=value lines:
#   game, remote_device, local_device, remote_timestamp, local_timestamp,
#   trying (yes/no), trying_modified (yes/no), active_version (remote/local),
#   member_count
# Devices/timestamps come from the group's first member (same game → same
# attribution); trying state is aggregated across ALL members.
# Usage: cu_group_info <repo_dir> <identity>
# Returns 1 if the group has no members (already resolved).
cu_group_info() {
    local repo_dir identity members first info
    repo_dir="$1"
    identity="$2"

    members=$(cu_group_members "$repo_dir" "$identity")
    [ -z "$members" ] && return 1

    first=$(printf '%s\n' "$members" | head -1)
    info=$(ch_get_conflict_info "$repo_dir" "$first") || return 1

    local game remote_device local_device remote_ts local_ts
    game=$(printf '%s\n' "$info" | grep '^game=' | sed 's/^game=//')
    remote_device=$(printf '%s\n' "$info" | grep '^remote_device=' | sed 's/^remote_device=//')
    local_device=$(printf '%s\n' "$info" | grep '^local_device=' | sed 's/^local_device=//')
    remote_ts=$(printf '%s\n' "$info" | grep '^remote_timestamp=' | sed 's/^remote_timestamp=//')
    local_ts=$(printf '%s\n' "$info" | grep '^local_timestamp=' | sed 's/^local_timestamp=//')

    # Aggregate trying state across members via capturing subshells (a
    # while-read pipe runs in a subshell, so we surface the answer on stdout
    # rather than in a variable). A group is "trying" if ANY member is, and
    # since a group try loads every member to the same side, the first
    # trying member's version is the group's active version.
    local trying trying_modified active_version member_count
    trying=$(printf '%s\n' "$members" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ch_is_trying "$repo_dir" "$m"; then printf 'yes'; break; fi
    done)
    [ "$trying" = "yes" ] || trying="no"

    trying_modified=$(printf '%s\n' "$members" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ch_is_trying_modified "$repo_dir" "$m"; then printf 'yes'; break; fi
    done)
    [ "$trying_modified" = "yes" ] || trying_modified="no"

    active_version=$(printf '%s\n' "$members" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ch_is_trying "$repo_dir" "$m"; then ch_get_active_version "$repo_dir" "$m"; break; fi
    done)
    [ -z "$active_version" ] && active_version="remote"

    member_count=$(printf '%s\n' "$members" | grep -c '.')

    printf 'game=%s\n' "$game"
    printf 'remote_device=%s\n' "$remote_device"
    printf 'local_device=%s\n' "$local_device"
    printf 'remote_timestamp=%s\n' "$remote_ts"
    printf 'local_timestamp=%s\n' "$local_ts"
    printf 'trying=%s\n' "$trying"
    printf 'trying_modified=%s\n' "$trying_modified"
    printf 'active_version=%s\n' "$active_version"
    printf 'member_count=%s\n' "$member_count"
    return 0
}

# cu_group_label — one-line list label for a group: "<game> — <rd> vs <ld>".
# Usage: cu_group_label <repo_dir> <identity>
cu_group_label() {
    local repo_dir identity info game rd ld
    repo_dir="$1"
    identity="$2"
    info=$(cu_group_info "$repo_dir" "$identity") || { printf '%s' "$identity"; return 0; }
    game=$(printf '%s\n' "$info" | grep '^game=' | sed 's/^game=//')
    rd=$(printf '%s\n' "$info" | grep '^remote_device=' | sed 's/^remote_device=//')
    ld=$(printf '%s\n' "$info" | grep '^local_device=' | sed 's/^local_device=//')
    printf '%s — %s vs %s' "$game" "$rd" "$ld"
    return 0
}

# cu_try_group — load <version> (remote|local) of EVERY member into the
# device's live slot, so the whole game group is tried as a unit.
# Usage: cu_try_group <repo_dir> <identity> <remote|local>
# Returns 0 on success, 1 if any member fails.
cu_try_group() {
    local repo_dir identity version members
    repo_dir="$1"
    identity="$2"
    version="$3"

    members=$(cu_group_members "$repo_dir" "$identity")
    [ -z "$members" ] && return 1

    printf '%s\n' "$members" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ! ch_try_version "$repo_dir" "$m" "$version" >/dev/null; then
            pal_log "error" "cu_try_group: try failed for $m"
            return 1
        fi
    done || return 1
    return 0
}

# cu_resolve_group — commit a resolution for EVERY member of the group with
# the same side, so .srm and .rtc are never split.
# Usage: cu_resolve_group <repo_dir> <identity> <keep_remote|keep_local|keep_newest>
# Returns 0 on success, 1 if any member fails (e.g. keep_newest refused on a
# missing timestamp — the caller falls back to manual choice).
cu_resolve_group() {
    local repo_dir identity resolution members
    repo_dir="$1"
    identity="$2"
    resolution="$3"

    members=$(cu_group_members "$repo_dir" "$identity")
    [ -z "$members" ] && return 1

    printf '%s\n' "$members" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ! ch_resolve "$repo_dir" "$m" "$resolution"; then
            pal_log "warn" "cu_resolve_group: $resolution failed for $m"
            return 1
        fi
    done || return 1
    return 0
}

# cu_promote_group — accept the tried-and-played side as the group's
# resolution. A member played-on since the try (a NEW third version) is
# promoted from the live slot (ch_promote_trying); a member merely tried but
# not modified is resolved to the tried side (keep_<active>), so the whole
# group lands on one consistent side.
# Usage: cu_promote_group <repo_dir> <identity>
# Returns 0 on success, 1 on error.
cu_promote_group() {
    local repo_dir identity members
    repo_dir="$1"
    identity="$2"

    members=$(cu_group_members "$repo_dir" "$identity")
    [ -z "$members" ] && return 1

    printf '%s\n' "$members" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        if ch_is_trying_modified "$repo_dir" "$m"; then
            if ! ch_promote_trying "$repo_dir" "$m"; then
                pal_log "error" "cu_promote_group: promote failed for $m"
                return 1
            fi
        elif ch_is_trying "$repo_dir" "$m"; then
            local av
            av=$(ch_get_active_version "$repo_dir" "$m")
            if ! ch_resolve "$repo_dir" "$m" "keep_$av"; then
                pal_log "error" "cu_promote_group: keep_$av failed for $m"
                return 1
            fi
        else
            pal_log "warn" "cu_promote_group: $m not in a tried state — left unresolved"
        fi
    done || return 1
    return 0
}

# cu_clear_group_try — abandon an in-progress try for one group by removing
# its members' try markers. Operates on the documented on-repo artifact
# (.continuity/trying/<repo_path with / -> _>, design §3), so it needs no
# private engine internals and never touches OTHER groups' markers (unlike
# ch_clear_try_markers, which clears the whole trying dir).
# Usage: cu_clear_group_try <repo_dir> <identity>
cu_clear_group_try() {
    local repo_dir identity members
    repo_dir="$1"
    identity="$2"
    members=$(cu_group_members "$repo_dir" "$identity")
    printf '%s\n' "$members" | while IFS= read -r m; do
        [ -z "$m" ] && continue
        local marker_name
        marker_name=$(printf '%s' "$m" | sed 's|/|_|g')
        rm -f "$repo_dir/.continuity/trying/$marker_name"
    done
    return 0
}

# _cu_other — the opposite side.
_cu_other() {
    if [ "$1" = "remote" ]; then printf 'local'; else printf 'remote'; fi
}

# cu_detail — drive one group through its state (design §4/§5) until the user
# resolves it or returns to the list. Zero platform I/O; all through pal_ui_*.
# Usage: cu_detail <repo_dir> <identity>
cu_detail() {
    local repo_dir identity
    repo_dir="$1"
    identity="$2"

    while true; do
        local info
        info=$(cu_group_info "$repo_dir" "$identity") || return 0  # resolved/gone

        local game rd ld rts lts trying trying_modified active
        game=$(printf '%s\n' "$info" | grep '^game=' | sed 's/^game=//')
        rd=$(printf '%s\n' "$info" | grep '^remote_device=' | sed 's/^remote_device=//')
        ld=$(printf '%s\n' "$info" | grep '^local_device=' | sed 's/^local_device=//')
        rts=$(printf '%s\n' "$info" | grep '^remote_timestamp=' | sed 's/^remote_timestamp=//')
        lts=$(printf '%s\n' "$info" | grep '^local_timestamp=' | sed 's/^local_timestamp=//')
        trying=$(printf '%s\n' "$info" | grep '^trying=' | sed 's/^trying=//')
        trying_modified=$(printf '%s\n' "$info" | grep '^trying_modified=' | sed 's/^trying_modified=//')
        active=$(printf '%s\n' "$info" | grep '^active_version=' | sed 's/^active_version=//')

        local active_dev
        if [ "$active" = "remote" ]; then active_dev="$rd"; else active_dev="$ld"; fi

        if [ "$trying_modified" = "yes" ]; then
            # TRYING-MODIFIED: a third version exists. §4 guard — it must
            # never be silently discarded; any keep-other path only after an
            # explicit "discard your progress?" confirm.
            local sel
            sel=$(pal_ui_menu "You played $active_dev's $game — keep that progress?" \
                "Keep your progress" \
                "Discard it and pick again" \
                "Back to list")
            case "$sel" in
                0)
                    if cu_promote_group "$repo_dir" "$identity"; then
                        pal_ui_message "Kept your progress on $game. $active_dev's version is now canonical."
                    else
                        pal_ui_message "Could not keep progress on $game — see the log."
                    fi
                    return 0
                    ;;
                1)
                    if [ "$(pal_ui_confirm "Discard your progress on $game and pick again?")" = "yes" ]; then
                        cu_clear_group_try "$repo_dir" "$identity"
                    fi
                    continue
                    ;;
                *)
                    return 0
                    ;;
            esac

        elif [ "$trying" = "yes" ]; then
            # TRYING (not played-on): keep the tried side, switch sides, or
            # abandon the try.
            local other sel
            other=$(_cu_other "$active")
            sel=$(pal_ui_menu "$game: trying $active_dev's copy" \
                "Keep $active_dev's copy" \
                "Try the other side" \
                "Discard try (pick again)" \
                "Back to list")
            case "$sel" in
                0)
                    if [ "$(pal_ui_confirm "Keep $active_dev's $game? The other version stays recoverable.")" = "yes" ]; then
                        if cu_resolve_group "$repo_dir" "$identity" "keep_$active"; then
                            pal_ui_message "Kept $active_dev's $game."
                        else
                            pal_ui_message "Could not resolve $game — see the log."
                        fi
                        return 0
                    fi
                    continue
                    ;;
                1)
                    if cu_try_group "$repo_dir" "$identity" "$other"; then
                        pal_ui_handoff "Loaded the other copy of $game. Play, then reopen Continuity to decide."
                    else
                        pal_ui_message "Could not load the other copy of $game — see the log."
                    fi
                    return 0
                    ;;
                2)
                    cu_clear_group_try "$repo_dir" "$identity"
                    continue
                    ;;
                *)
                    return 0
                    ;;
            esac

        else
            # UNRESOLVED: the fresh two-sided detail. Fixed item order so the
            # index map is stable; keep_newest is always listed (clearly
            # guarded) and refuses to a manual fall-back when clocks are
            # missing (§4 guard), rather than being hidden or dead-ending.
            local sel
            sel=$(pal_ui_menu "$game: $rd $rts | $ld $lts" \
                "Try $rd's copy" \
                "Try $ld's copy" \
                "Keep $rd's copy" \
                "Keep $ld's copy" \
                "Keep newest (by device clock — may be wrong)" \
                "Back to list")
            case "$sel" in
                0)
                    if cu_try_group "$repo_dir" "$identity" "remote"; then
                        pal_ui_handoff "Loaded $rd's $game. Play, then reopen Continuity to decide."
                    else
                        pal_ui_message "Could not load $rd's $game — see the log."
                    fi
                    return 0
                    ;;
                1)
                    if cu_try_group "$repo_dir" "$identity" "local"; then
                        pal_ui_handoff "Loaded $ld's $game. Play, then reopen Continuity to decide."
                    else
                        pal_ui_message "Could not load $ld's $game — see the log."
                    fi
                    return 0
                    ;;
                2)
                    if [ "$(pal_ui_confirm "Keep $rd's $game? $ld's stays recoverable.")" = "yes" ]; then
                        if cu_resolve_group "$repo_dir" "$identity" "keep_remote"; then
                            pal_ui_message "Kept $rd's $game."
                        else
                            pal_ui_message "Could not resolve $game — see the log."
                        fi
                        return 0
                    fi
                    continue
                    ;;
                3)
                    if [ "$(pal_ui_confirm "Keep $ld's $game? $rd's stays recoverable.")" = "yes" ]; then
                        if cu_resolve_group "$repo_dir" "$identity" "keep_local"; then
                            pal_ui_message "Kept $ld's $game."
                        else
                            pal_ui_message "Could not resolve $game — see the log."
                        fi
                        return 0
                    fi
                    continue
                    ;;
                4)
                    if [ -z "$rts" ] || [ -z "$lts" ]; then
                        pal_ui_message "Can't tell which is newer — device clocks aren't reliable. Choose Keep $rd's or Keep $ld's."
                        continue
                    fi
                    if [ "$(pal_ui_confirm "Keep the newest by device clock? This may be wrong.")" = "yes" ]; then
                        if cu_resolve_group "$repo_dir" "$identity" "keep_newest"; then
                            pal_ui_message "Kept the newest copy of $game by device clock."
                        else
                            pal_ui_message "Couldn't compare clocks for $game — choose Keep $rd's or Keep $ld's."
                            continue
                        fi
                        return 0
                    fi
                    continue
                    ;;
                *)
                    return 0
                    ;;
            esac
        fi
    done
}

# cu_run — top-level conflict-resolution loop: list → detail → resolve, until
# the user exits or everything is resolved. The single entry point a platform
# opens from its menu/tool surface.
# Usage: cu_run <repo_dir>
# Returns 0 always.
cu_run() {
    local repo_dir
    repo_dir="$1"

    while true; do
        local groups count
        groups=$(cu_list_groups "$repo_dir")

        if [ -z "$groups" ]; then
            pal_ui_message "No conflicts. Everything's in sync."
            return 0
        fi
        count=$(printf '%s\n' "$groups" | grep -c '.')

        # Build the menu labels in group order, preserving spaces in game
        # names: load identities into the positional params (newline IFS +
        # noglob so a '*' in a name isn't expanded), append each computed
        # label, then shift the identities off — leaving labels in $@.
        local old_ifs n
        old_ifs=$IFS
        IFS='
'
        set -f
        # shellcheck disable=SC2086
        set -- $groups
        set +f
        IFS=$old_ifs

        n=$#
        local id
        for id in "$@"; do
            set -- "$@" "$(cu_group_label "$repo_dir" "$id")"
        done
        shift "$n"   # drop identities; $@ is now the labels

        local choice
        choice=$(pal_ui_menu "Conflicts ($count)" "$@")

        case "$choice" in
            ''|cancel)
                return 0
                ;;
            *[!0-9]*)
                # Not an index — treat as cancel to avoid a wedge.
                return 0
                ;;
            *)
                local identity
                identity=$(printf '%s\n' "$groups" | sed -n "$((choice + 1))p")
                [ -z "$identity" ] && return 0
                cu_detail "$repo_dir" "$identity"
                ;;
        esac
    done
}
