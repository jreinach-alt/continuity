#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# NextUI implementation of the pal_ui_* rendering contract (design §6).
#
# The Tier-0 floor: show2.elf renders ONE text line; input is /dev/input/js0
# (B=0, A=1, Y=2, X=3 per the field notes). Every screen is a single line
# plus a button legend; multi-item menus PAGE with Y (ui-design-system §5).
# This is a thin shim — the conflict_ui.sh controller owns all the logic; we
# only render and read buttons.
#
# Built on the hard-won enroll-UI primitives (same platform, so we reuse
# rather than re-derive the 8-byte js_event decode, the single persistent
# joydev open, and the seen-counter that survives command substitution):
#   - eui_show_line <text>                 (one line to the show2 FIFO)
#   - eui_btn_listener_start/stop, eui_next_button
#   - eui_prompt_button <ticks> <accepted>...
# The caller MUST have sourced scripts/enroll_ui.sh first (launch.sh does).
#
# Testability mirrors enroll_ui.sh exactly: EUI_FIFO is the show2 FIFO (a
# plain file in tests, captured for assertions) and EUI_JS_DEV is the
# joystick (a file of synthesized js_event records in tests). No hardware.

# tg5040 face-button numbers (field notes). enroll_ui.sh makes B/Y/X
# readonly; we add A and keep our own plain copies to avoid re-declaring
# readonlies.
PUI_BTN_B=0
PUI_BTN_A=1
PUI_BTN_Y=2

# Bounded waits so a walk-away never wedges the tool. ~10 min at the default
# 0.5s tick; overridable for tests.
PUI_TIMEOUT_TICKS="${PUI_TIMEOUT_TICKS:-1200}"

# _pui_nth — print the Nth (0-based) of the remaining args.
# Usage: _pui_nth <n> <item>...
_pui_nth() {
    local n
    n="$1"
    shift
    # Guard: never shift past the end.
    [ "$n" -ge 0 ] || { printf ''; return 0; }
    shift "$n" 2>/dev/null || { printf ''; return 0; }
    printf '%s' "$1"
}

# _pui_render_item — draw one menu item line: "<item>  <i+1>/<n>  <legend>".
# The item labels the controller passes are self-describing (e.g. "Try
# my-deck's copy", "Keep my-deck's Pokemon Crystal", "Back to list"), so the
# single line carries meaning without the menu title; Y is only offered when
# there is more than one item to page through. The pager is NOT led with a
# "[..]" bracket — eui_show_line strips a leading bracketed prefix (the
# pal_log timestamp), which would swallow it.
_pui_render_item() {
    local i n item legend
    i="$1"; n="$2"; item="$3"
    if [ "$n" -gt 1 ]; then
        legend="A=pick  Y=next  B=back"
    else
        legend="A=pick  B=back"
    fi
    eui_show_line "$item   $((i + 1))/$n   $legend"
}

# pal_ui_menu <title> <item>... — page items with Y, pick with A, cancel with
# B. Prints the chosen 0-based index, or "cancel". One persistent joydev open
# for the whole menu (so paging advances through real presses instead of
# replaying init events).
pal_ui_menu() {
    local title n i btn ticks btnfile
    title="$1"
    shift
    n=$#
    if [ "$n" -eq 0 ]; then
        printf 'cancel\n'
        return 0
    fi

    # Per-process button file (respect TMPDIR; never a fixed shared name).
    btnfile="${PUI_BTN_FILE:-${TMPDIR:-/tmp}/continuity_pui.$$.buttons}"
    eui_btn_listener_start "$btnfile"

    i=0
    _pui_render_item "$i" "$n" "$(_pui_nth "$i" "$@")"
    ticks="$PUI_TIMEOUT_TICKS"
    while [ "$ticks" -gt 0 ]; do
        if btn=$(eui_next_button); then
            case "$btn" in
                "$PUI_BTN_A")
                    eui_btn_listener_stop
                    rm -f "$btnfile" "$btnfile.seen" 2>/dev/null || true
                    printf '%s\n' "$i"
                    return 0
                    ;;
                "$PUI_BTN_Y")
                    i=$(( (i + 1) % n ))
                    _pui_render_item "$i" "$n" "$(_pui_nth "$i" "$@")"
                    ;;
                "$PUI_BTN_B")
                    eui_btn_listener_stop
                    rm -f "$btnfile" "$btnfile.seen" 2>/dev/null || true
                    printf 'cancel\n'
                    return 0
                    ;;
                *)
                    : # unmapped button — ignore (enroll_ui logs new numbers)
                    ;;
            esac
        fi
        sleep "$EUI_TICK"
        ticks=$((ticks - 1))
    done

    eui_btn_listener_stop
    rm -f "$btnfile" "$btnfile.seen" 2>/dev/null || true
    printf 'cancel\n'
    return 0
}

# pal_ui_message <text> — show and wait for acknowledge (A or B). Returns 0.
pal_ui_message() {
    eui_show_line "$1   A=OK"
    eui_prompt_button "$PUI_TIMEOUT_TICKS" "$PUI_BTN_A" "$PUI_BTN_B" >/dev/null 2>&1 || true
    return 0
}

# pal_ui_confirm <text> — A=yes, B=no. Prints "yes"/"no". A timeout is
# treated as "no" (the safe non-destructive default).
pal_ui_confirm() {
    local btn
    eui_show_line "$1   A=yes  B=no"
    if btn=$(eui_prompt_button "$PUI_TIMEOUT_TICKS" "$PUI_BTN_A" "$PUI_BTN_B"); then
        if [ "$btn" = "$PUI_BTN_A" ]; then
            printf 'yes\n'
            return 0
        fi
    fi
    printf 'no\n'
    return 0
}

# pal_ui_handoff <text> — show the "go play, come back" message and yield.
# The user leaves the tool to play; the launch flow exits afterward and the
# line stays on screen. We show and return (optionally waiting briefly for an
# acknowledge so the message is definitely seen).
pal_ui_handoff() {
    eui_show_line "$1"
    eui_prompt_button "$PUI_HANDOFF_TICKS" "$PUI_BTN_A" "$PUI_BTN_B" >/dev/null 2>&1 || true
    return 0
}

# Short default acknowledge window for the handoff (the user is about to
# leave anyway); overridable for tests.
PUI_HANDOFF_TICKS="${PUI_HANDOFF_TICKS:-20}"
