#!/bin/sh
# shellcheck shell=ash  # POSIX sh — parses under busybox ash for the test suite
# shellcheck disable=SC3043,SC1090,SC1091
# Continuity — RetroDeck conflict-resolution entry point.
#
# Opens the SHARED resolution controller (src/core/conflict_ui.sh — the
# §4/§5 state machine of docs/design/conflict-resolution-experience.md)
# through the Deck's pal_ui_* shims: kdialog/zenity dialogs in desktop
# mode, a numbered CLI prompt in a terminal. Launched from the installed
# "Continuity — Resolve save conflicts" desktop entry, from the red
# notification's hint, or by hand:
#
#   resolve_conflicts.sh [--backend kdialog|zenity|cli]
#
# The daemon and this tool share the repo clone (same shipped precedent
# as the NextUI PAK + daemon): engine operations are short, and a rare
# git index.lock collision logs and self-heals on the next cycle.
# Resolutions chosen offline queue locally and push on recovery (engine
# + daemon behavior, already covered by the core suites).
set -e

while [ $# -gt 0 ]; do
    case "$1" in
        --backend)
            CONTINUITY_UI_BACKEND="${2:?--backend needs a value}"
            export CONTINUITY_UI_BACKEND
            shift 2
            ;;
        --help|-h)
            printf 'Usage: resolve_conflicts.sh [--backend kdialog|zenity|cli]\n'
            exit 0
            ;;
        *)
            printf 'Error: unknown argument: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

# Script lives at <app>/src/platforms/retrodeck/resolve_conflicts.sh
CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
export CONTINUITY_APP_DIR

. "$CONTINUITY_APP_DIR/src/platforms/retrodeck/pal_retrodeck.sh"
. "$CONTINUITY_APP_DIR/src/core/pal.sh"
. "$CONTINUITY_APP_DIR/src/core/path_mapper.sh"
. "$CONTINUITY_APP_DIR/src/core/sync_engine.sh"
. "$CONTINUITY_APP_DIR/src/core/enrollment.sh"
. "$CONTINUITY_APP_DIR/src/core/change_detector.sh"
. "$CONTINUITY_APP_DIR/src/core/conflict_handler.sh"
. "$CONTINUITY_APP_DIR/src/core/conflict_ui.sh"
. "$CONTINUITY_APP_DIR/src/platforms/retrodeck/pal_ui_retrodeck.sh"

# Name every blocker before opening anything (observability rule).
if ! rdui_backend_ok; then
    exit 1
fi
if ! enroll_is_enrolled; then
    printf 'continuity: not enrolled — run enroll_retrodeck.sh first\n' >&2
    exit 78
fi
pal_init || { pal_log "error" "PAL init failed"; exit 78; }
pal_validate || { pal_log "error" "PAL validation failed"; exit 78; }
se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" || {
    pal_log "error" "Sync engine init failed"
    exit 1
}
pm_load_platform_map "$(pal_get_platform_map)" || {
    pal_log "error" "Failed to load platform map"
    exit 78
}

# The controller renders everything from here: the conflict list, the
# per-game detail, try/keep/promote, and the empty "No conflicts.
# Everything's in sync." state.
cu_run "$CONTINUITY_REPO_DIR"
exit 0
