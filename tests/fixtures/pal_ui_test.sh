#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Scripted-queue test PAL for the pal_ui_* rendering contract (design §6).
#
# Source this AFTER tests/fixtures/pal_test.sh (it reuses $TEST_TMPDIR).
# The whole conflict_ui.sh controller is headless-testable through it: user
# DECISIONS are pre-seeded in a queue file and consumed in order; every
# rendered screen is appended to a capture file for assertions. No hardware,
# no show2/js0 — exactly like the sync phases' test PAL.
#
# Contract implemented (each returns via stdout where a value is expected):
#   pal_ui_menu <title> <item>...  -> chosen 0-based index, or "cancel"
#   pal_ui_message <text>          -> render + return 0 (no decision)
#   pal_ui_confirm <text>          -> "yes" / "no"
#   pal_ui_handoff <text>          -> render + return 0 (yields; no decision)
#
# menu and confirm consume one queue response each; message and handoff are
# informational and consume nothing. An exhausted queue yields the safe
# default ("cancel" for menu, "no" for confirm) so a mis-seeded test fails
# loudly rather than hanging.
#
# Env (defaulted under $TEST_TMPDIR):
#   PAL_UI_QUEUE   decision responses, one per line
#   PAL_UI_RENDER  captured render log (one line per screen/item)

PAL_UI_QUEUE="${PAL_UI_QUEUE:-$TEST_TMPDIR/pal_ui_queue}"
PAL_UI_RENDER="${PAL_UI_RENDER:-$TEST_TMPDIR/pal_ui_render}"

# pal_ui_seed — (re)initialize the queue with the given responses (one per
# arg) and clear the render capture + consumed counter.
pal_ui_seed() {
    : > "$PAL_UI_QUEUE"
    : > "$PAL_UI_QUEUE.seen"
    : > "$PAL_UI_RENDER"
    local _r
    for _r in "$@"; do
        printf '%s\n' "$_r" >> "$PAL_UI_QUEUE"
    done
    return 0
}

# _pal_ui_pop — print the next unconsumed queue response, advancing a
# consumed counter kept in a FILE so the advance survives the command-
# substitution subshell the controller invokes us from (variable writes
# there would be lost — same idiom as eui_next_button). Returns 1 and
# prints nothing when the queue is exhausted.
_pal_ui_pop() {
    local total seen
    [ -f "$PAL_UI_QUEUE" ] || return 1
    total=$(wc -l < "$PAL_UI_QUEUE")
    seen=$(cat "$PAL_UI_QUEUE.seen" 2>/dev/null)
    seen="${seen:-0}"
    [ "$total" -gt "$seen" ] || return 1
    seen=$((seen + 1))
    printf '%s' "$seen" > "$PAL_UI_QUEUE.seen"
    sed -n "${seen}p" "$PAL_UI_QUEUE"
    return 0
}

# _pal_ui_render — append one screen line to the capture file.
_pal_ui_render() {
    [ -n "$PAL_UI_RENDER" ] || return 0
    printf '%s\n' "$1" >> "$PAL_UI_RENDER"
}

pal_ui_menu() {
    local title choice i item
    title="$1"; shift
    _pal_ui_render "MENU: $title"
    i=0
    for item in "$@"; do
        _pal_ui_render "  [$i] $item"
        i=$((i + 1))
    done
    choice=$(_pal_ui_pop) || choice="cancel"
    [ -z "$choice" ] && choice="cancel"
    _pal_ui_render "  -> $choice"
    printf '%s\n' "$choice"
    return 0
}

pal_ui_message() {
    _pal_ui_render "MSG: $1"
    return 0
}

pal_ui_confirm() {
    local ans
    _pal_ui_render "CONFIRM: $1"
    ans=$(_pal_ui_pop) || ans="no"
    [ -z "$ans" ] && ans="no"
    _pal_ui_render "  -> $ans"
    printf '%s\n' "$ans"
    return 0
}

pal_ui_handoff() {
    _pal_ui_render "HANDOFF: $1"
    return 0
}
