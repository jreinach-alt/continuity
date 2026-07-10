#!/bin/sh
# shellcheck shell=ash  # POSIX sh — parses under busybox ash for the test suite
# shellcheck disable=SC3043
# RetroDeck implementation of the pal_ui_* rendering contract (design §6
# of docs/design/conflict-resolution-experience.md, under the
# ui-design-system Tier 1/2 framing).
#
# Desktop dialogs when a display is up — kdialog first (SteamOS desktop
# mode is KDE Plasma), zenity second — and a numbered-prompt CLI when
# run from a terminal. The shared conflict_ui.sh controller owns ALL
# flow logic; these four functions only render and return. stdout
# carries ONLY contract return values (menu index / "cancel",
# "yes"/"no"); every human-facing render goes to the dialog tool or to
# stderr.
#
# Desktop dialogs block until acted on — that is normal desktop
# behavior, not a wedge: this surface is user-launched (unlike the
# Brick's bounded button waits inside a boot-launched tool).
#
# Backend resolution happens once at source time:
#   CONTINUITY_UI_BACKEND = auto|kdialog|zenity|cli   (default auto)
# auto prefers kdialog, then zenity (each needs $DISPLAY or
# $WAYLAND_DISPLAY), then cli when stdin is a terminal, else "none" —
# rdui_backend_ok lets the entry point refuse to start with a named
# error instead of a user silently losing a flow mid-way.

CONTINUITY_UI_BACKEND="${CONTINUITY_UI_BACKEND:-auto}"

_rdui_has_display() {
    [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

# rdui_resolve_backend — set RDUI_BACKEND per the precedence above.
rdui_resolve_backend() {
    case "$CONTINUITY_UI_BACKEND" in
        kdialog|zenity|cli)
            RDUI_BACKEND="$CONTINUITY_UI_BACKEND"
            return 0
            ;;
        auto) ;;
        *)
            printf 'continuity: unknown CONTINUITY_UI_BACKEND "%s" — using auto\n' \
                "$CONTINUITY_UI_BACKEND" >&2
            ;;
    esac
    if _rdui_has_display && command -v kdialog >/dev/null 2>&1; then
        RDUI_BACKEND="kdialog"
    elif _rdui_has_display && command -v zenity >/dev/null 2>&1; then
        RDUI_BACKEND="zenity"
    elif [ -t 0 ]; then
        RDUI_BACKEND="cli"
    else
        RDUI_BACKEND="none"
    fi
    return 0
}
rdui_resolve_backend

# rdui_backend_ok — 0 when the resolved backend can actually run;
# otherwise a named stderr line and 1 (observability rule).
rdui_backend_ok() {
    case "$RDUI_BACKEND" in
        kdialog|zenity)
            if command -v "$RDUI_BACKEND" >/dev/null 2>&1; then
                return 0
            fi
            printf 'continuity: UI backend "%s" selected but not installed\n' \
                "$RDUI_BACKEND" >&2
            return 1
            ;;
        cli)
            return 0
            ;;
        *)
            printf 'continuity: no dialog tool (kdialog/zenity) and no terminal — install kdialog or run from Konsole\n' >&2
            return 1
            ;;
    esac
}

# _rdui_menu_kdialog <title> <item>... — kdialog --menu with 0-based
# numeric tags; kdialog prints the chosen tag, rc 1 on cancel.
_rdui_menu_kdialog() {
    local title n sel
    title="$1"
    shift
    # Append tag/item pairs after the items, then drop the items —
    # "$@" is expanded once when the for-loop starts, so appending
    # inside the body is safe.
    n=0
    local item
    for item in "$@"; do
        set -- "$@" "$n" "$item"
        n=$((n + 1))
    done
    shift "$n"
    if sel=$(kdialog --title "Continuity" --menu "$title" "$@" 2>/dev/null); then
        printf '%s\n' "$sel"
    else
        printf 'cancel\n'
    fi
    return 0
}

# _rdui_menu_zenity <title> <item>... — zenity --list with a hidden
# 0-based index column printed back; rc 1 on cancel.
_rdui_menu_zenity() {
    local title n sel
    title="$1"
    shift
    n=0
    local item
    for item in "$@"; do
        set -- "$@" "$n" "$item"
        n=$((n + 1))
    done
    shift "$n"
    if sel=$(zenity --list --title "Continuity" --text "$title" \
        --column "#" --column "Choice" \
        --hide-column=1 --print-column=1 --hide-header "$@" 2>/dev/null); then
        if [ -n "$sel" ]; then
            printf '%s\n' "$sel"
        else
            printf 'cancel\n'
        fi
    else
        printf 'cancel\n'
    fi
    return 0
}

# _rdui_menu_cli <title> <item>... — numbered list on stderr, choice
# read from stdin (1-based display, 0-based return). Invalid input
# re-prompts; empty line / q / EOF cancels.
_rdui_menu_cli() {
    local title n i line
    title="$1"
    shift
    n=$#
    printf '\n%s\n' "$title" >&2
    i=0
    local item
    for item in "$@"; do
        printf '  %d) %s\n' $((i + 1)) "$item" >&2
        i=$((i + 1))
    done
    while true; do
        printf 'Choose [1-%d, q=back]: ' "$n" >&2
        if ! IFS= read -r line; then
            printf 'cancel\n'
            return 0
        fi
        case "$line" in
            ''|q|Q)
                printf 'cancel\n'
                return 0
                ;;
            *[!0-9]*)
                printf 'Not a number.\n' >&2
                ;;
            *)
                if [ "$line" -ge 1 ] && [ "$line" -le "$n" ]; then
                    printf '%s\n' $((line - 1))
                    return 0
                fi
                printf 'Out of range.\n' >&2
                ;;
        esac
    done
}

# pal_ui_menu <title> <item>... — prints the chosen 0-based index, or
# "cancel".
pal_ui_menu() {
    local title
    title="$1"
    shift
    if [ $# -eq 0 ]; then
        printf 'cancel\n'
        return 0
    fi
    case "$RDUI_BACKEND" in
        kdialog) _rdui_menu_kdialog "$title" "$@" ;;
        zenity)  _rdui_menu_zenity "$title" "$@" ;;
        cli)     _rdui_menu_cli "$title" "$@" ;;
        *)       printf 'cancel\n' ;;
    esac
    return 0
}

# pal_ui_confirm <text> — prints "yes"/"no". EOF, cancel, and anything
# but an explicit yes answer are "no" (the safe non-destructive default).
pal_ui_confirm() {
    local line
    case "$RDUI_BACKEND" in
        kdialog)
            if kdialog --title "Continuity" --yesno "$1" 2>/dev/null; then
                printf 'yes\n'
            else
                printf 'no\n'
            fi
            ;;
        zenity)
            if zenity --question --title "Continuity" --text "$1" 2>/dev/null; then
                printf 'yes\n'
            else
                printf 'no\n'
            fi
            ;;
        cli)
            printf '\n%s [y/N]: ' "$1" >&2
            if IFS= read -r line && { [ "$line" = "y" ] || [ "$line" = "Y" ]; }; then
                printf 'yes\n'
            else
                printf 'no\n'
            fi
            ;;
        *)
            printf 'no\n'
            ;;
    esac
    return 0
}

# pal_ui_message <text> — show and wait for acknowledge.
pal_ui_message() {
    local _rdui_ack
    case "$RDUI_BACKEND" in
        kdialog) kdialog --title "Continuity" --msgbox "$1" 2>/dev/null || true ;;
        zenity)  zenity --info --title "Continuity" --text "$1" 2>/dev/null || true ;;
        cli)
            printf '\n%s\n[Enter to continue] ' "$1" >&2
            IFS= read -r _rdui_ack || true
            ;;
        *) printf 'continuity: %s\n' "$1" >&2 ;;
    esac
    return 0
}

# pal_ui_handoff <text> — show the "go play, come back" message and
# yield. Desktop: the user closes the dialog and leaves; CLI: print and
# return (the list reappears; the user backs out to go play).
pal_ui_handoff() {
    case "$RDUI_BACKEND" in
        kdialog) kdialog --title "Continuity" --msgbox "$1" 2>/dev/null || true ;;
        zenity)  zenity --info --title "Continuity" --text "$1" 2>/dev/null || true ;;
        cli)     printf '\n%s\n' "$1" >&2 ;;
        *)       printf 'continuity: %s\n' "$1" >&2 ;;
    esac
    return 0
}
