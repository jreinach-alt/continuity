#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity Tool PAK — extensible main-menu shell.
#
# The durable home the PAK opens into when enrolled. It renders a top-level
# menu through the pal_ui_* contract and dispatches the chosen row to its
# handler. The entry list is DATA-DRIVEN (mu_build_menu): adding a PAK
# feature is one line there + a small handler, needing no new input plumbing
# — the shell owns paging/selection/back via pal_ui_menu.
#
# This sprint wires ONLY the conflict row ("Conflicts (N)" -> cu_run). The
# other roadmap-1.5 items (Status / Sync now / Unlink) are a tracked fast
# follow-up (Sprint 1.5b); the commented rows below mark exactly where they
# slot in. Nothing here is conflict-specific beyond that one wired handler.
#
# Written against the contract + core (ch_*/cu_*) only, so it is portable if
# ever promoted to core; it lives under the platform because WHICH rows exist
# is a PAK/feature decision.
#
# Prerequisites (sourced by launch.sh before calling mu_run):
#   - a pal_ui_* implementation (pal_ui_nextui.sh) + its deps (enroll_ui.sh)
#   - src/core/conflict_handler.sh (ch_count_conflicts)
#   - src/core/conflict_ui.sh (cu_run)

# mu_build_menu <repo_dir> — the menu entry table, one row per line as
# "<handler>|<label>". ADD A ROW HERE (one line) to add a PAK feature; the
# handler is called as `<handler> <repo_dir>`.
mu_build_menu() {
    local repo_dir n
    repo_dir="$1"
    n=$(ch_count_conflicts "$repo_dir" 2>/dev/null)
    [ -z "$n" ] && n=0
    printf 'mu_open_conflicts|Conflicts (%s)\n' "$n"
    # --- Sprint 1.5b follow-up (add one line each) ---
    # printf 'mu_open_status|Status\n'
    # printf 'mu_sync_now|Sync now\n'
    # printf 'mu_unlink|Unlink this device\n'
}

# mu_open_conflicts <repo_dir> — the wired conflict handler: hand off to the
# shared resolution controller.
mu_open_conflicts() {
    cu_run "$1"
}

# mu_run <repo_dir> — open the main menu; dispatch until the user exits.
# Returns 0 always.
mu_run() {
    local repo_dir
    repo_dir="$1"

    while true; do
        local entries
        entries=$(mu_build_menu "$repo_dir")
        [ -z "$entries" ] && return 0

        # Load "handler|label" rows into the positional params (newline IFS +
        # noglob so a label's characters aren't glob-expanded), then append
        # each row's LABEL and shift the raw rows off — leaving labels in $@,
        # in the same order as `entries` for index -> row mapping.
        local old_ifs n row
        old_ifs=$IFS
        IFS='
'
        set -f
        # shellcheck disable=SC2086
        set -- $entries
        set +f
        IFS=$old_ifs

        n=$#
        for row in "$@"; do
            set -- "$@" "${row#*|}"
        done
        shift "$n"   # drop the raw rows; $@ is now the labels

        local choice
        choice=$(pal_ui_menu "Continuity" "$@")

        case "$choice" in
            ''|cancel)
                return 0
                ;;
            *[!0-9]*)
                return 0
                ;;
            *)
                local entry handler
                entry=$(printf '%s\n' "$entries" | sed -n "$((choice + 1))p")
                [ -z "$entry" ] && return 0
                handler="${entry%%|*}"
                "$handler" "$repo_dir"
                ;;
        esac
    done
}
