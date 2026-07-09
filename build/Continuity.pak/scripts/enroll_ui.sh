#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity — interactive enrollment supervisor for the Tool PAK.
#
# Runs esd_import in the background and supervises it in the foreground:
#   - mirrors the latest enrollment log line to the screen (show2 daemon
#     FIFO — the display shows one line at a time)
#   - B button cancels enrollment
#   - X or Y button replays the last log lines on screen, one at a time
#   - a watchdog timeout kills a stuck enrollment
#
# Buttons are read from the kernel joystick interface (8-byte js_event
# records). On tg5040, face buttons have fixed numbers: B=0, A=1, Y=2,
# X=3 (upstream platform.h JOY_* table). Unknown button numbers are
# logged, so if a device maps differently the log tells us the real
# numbers after one press. If the joystick device is missing, buttons
# are disabled but the watchdog still prevents a hang.
#
# Overridable for testing (defaults are the device paths):
#   EUI_JS_DEV        joystick device (default /dev/input/js0)
#   EUI_FIFO          show2 daemon FIFO (default /tmp/show2.fifo)
#   EUI_TICK          supervisor tick in seconds (default 0.5)
#   EUI_TIMEOUT_TICKS ticks before watchdog fires (default 360 = ~3 min)
#   EUI_REPLAY_DELAY  seconds each replayed log line stays up (default 1.5)

EUI_JS_DEV="${EUI_JS_DEV:-/dev/input/js0}"
EUI_FIFO="${EUI_FIFO:-/tmp/show2.fifo}"
EUI_TICK="${EUI_TICK:-0.5}"
EUI_TIMEOUT_TICKS="${EUI_TIMEOUT_TICKS:-360}"
EUI_REPLAY_DELAY="${EUI_REPLAY_DELAY:-1.5}"

readonly EUI_BTN_B=0
readonly EUI_BTN_Y=2
readonly EUI_BTN_X=3

_eui_btn_file=""
_eui_btn_pid=""

# eui_show_line — put one line of text on screen via the show2 daemon.
# Strips the pal_log timestamp prefix and truncates to fit the display
# (1024 px wide at fontsize 28 fits ~64 chars comfortably).
eui_show_line() {
    local msg
    msg=$(printf '%s' "$1" | sed 's/^\[[^]]*\] //' | cut -c1-64)
    [ -p "$EUI_FIFO" ] || [ -f "$EUI_FIFO" ] || return 0
    # Append: identical to a plain write on a real FIFO, and preserves the
    # full message sequence when tests capture to a regular file.
    printf 'TEXT:%s\n' "$msg" >> "$EUI_FIFO"
}

# eui_btn_listener_start — decode js_event records to button numbers.
# Appends one line per face-button press to $_eui_btn_file.
# js_event is 8 bytes: u32 time, s16 value, u8 type, u8 number.
# A press is type==1 (button, no init bit) with value==1.
eui_btn_listener_start() {
    _eui_btn_file="$1"
    : > "$_eui_btn_file"
    : > "$_eui_btn_file.seen"

    if [ ! -r "$EUI_JS_DEV" ]; then
        pal_log "warn" "No joystick device at $EUI_JS_DEV — buttons disabled"
        return 0
    fi

    # One persistent open for the whole loop: joydev replays init events on
    # every open and only delivers presses to already-open descriptors, so
    # open-per-event would both spam init records and drop real presses.
    (
        while true; do
            ev=$(dd bs=8 count=1 2>/dev/null | od -An -tu1 | tr -s ' ')
            if [ -z "${ev# }" ]; then
                # EOF (regular file in tests) or read error — idle, don't spin
                sleep "$EUI_TICK"
                continue
            fi
            # Fields: b1-b4 time, b5-b6 value (LE), b7 type, b8 number
            # shellcheck disable=SC2086
            set -- $ev
            if [ "${7:-0}" -eq 1 ] && [ "${5:-0}" -eq 1 ] && [ "${6:-0}" -eq 0 ]; then
                printf '%s\n' "$8" >> "$_eui_btn_file"
            fi
        done < "$EUI_JS_DEV"
    ) &
    _eui_btn_pid=$!
}

# eui_btn_listener_stop — kill the background reader.
eui_btn_listener_stop() {
    if [ -n "$_eui_btn_pid" ]; then
        kill "$_eui_btn_pid" 2>/dev/null || true
        wait "$_eui_btn_pid" 2>/dev/null || true
        _eui_btn_pid=""
    fi
}

# eui_next_button — print the next unconsumed button number, if any.
# Returns 0 and prints the number, or returns 1 when no new press.
# The consumed count lives in a file, not a shell variable: callers invoke
# this via command substitution (a subshell), where variable writes are lost.
eui_next_button() {
    local total seen
    [ -f "$_eui_btn_file" ] || return 1
    total=$(wc -l < "$_eui_btn_file")
    seen=$(cat "$_eui_btn_file.seen" 2>/dev/null)
    seen="${seen:-0}"
    [ "$total" -gt "$seen" ] || return 1
    seen=$((seen + 1))
    printf '%s' "$seen" > "$_eui_btn_file.seen"
    sed -n "${seen}p" "$_eui_btn_file"
    return 0
}

# eui_prompt_button — wait (bounded) for one of the accepted buttons.
# Usage: eui_prompt_button <timeout_ticks> <accepted_number>...
# Prints the pressed number and returns 0, or returns 1 on timeout.
eui_prompt_button() {
    local ticks btn a
    ticks="$1"; shift
    # Per-process default path: a FIXED shared name collides across
    # users (a root-owned leftover is untruncatable by others) and
    # across concurrent runs. TMPDIR is respected for sandboxed tests;
    # devices without TMPDIR keep using /tmp (tmpfs).
    local _eui_prompt_file
    _eui_prompt_file="${EUI_BTN_PROMPT_FILE:-${TMPDIR:-/tmp}/continuity_prompt.$$.buttons}"
    eui_btn_listener_start "$_eui_prompt_file"
    while [ "$ticks" -gt 0 ]; do
        if btn=$(eui_next_button); then
            for a in "$@"; do
                if [ "$btn" = "$a" ]; then
                    eui_btn_listener_stop
                    rm -f "$_eui_prompt_file" "$_eui_prompt_file.seen" 2>/dev/null || true
                    printf '%s\n' "$btn"
                    return 0
                fi
            done
        fi
        sleep "$EUI_TICK"
        ticks=$((ticks - 1))
    done
    eui_btn_listener_stop
    rm -f "$_eui_prompt_file" "$_eui_prompt_file.seen" 2>/dev/null || true
    return 1
}

# eui_log_replay — step through the last 12 log lines on screen.
eui_log_replay() {
    local log_file line
    log_file="$1"
    if [ ! -s "$log_file" ]; then
        eui_show_line "Log is empty so far."
        sleep "$EUI_REPLAY_DELAY"
        return 0
    fi
    tail -n 12 "$log_file" | while IFS= read -r line; do
        eui_show_line "$line"
        sleep "$EUI_REPLAY_DELAY"
    done
    eui_show_line "— end of log —"
    sleep "$EUI_REPLAY_DELAY"
    return 0
}

# eui_kill_enrollment — stop the enrollment child and its git subprocess.
eui_kill_enrollment() {
    local pid
    pid="$1"
    kill "$pid" 2>/dev/null || true
    # git clone may be mid-transfer as a grandchild; the bundled binary is
    # the only git that can be running before enrollment completes.
    if [ -n "$CONTINUITY_GIT_BIN" ]; then
        killall "$(basename "$CONTINUITY_GIT_BIN")" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    return 0
}

# eui_run_enrollment — supervise esd_import with screen + buttons.
# Usage: eui_run_enrollment <enroll_log_file>
# Returns: 0 enrolled, 1 failed, 2 cancelled (B), 3 watchdog timeout
eui_run_enrollment() {
    local enroll_log child_pid rc ticks last_shown current btn
    enroll_log="$1"

    mkdir -p "$(dirname "$enroll_log")"
    printf '=== enrollment started %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$enroll_log"

    eui_btn_listener_start "${enroll_log%.log}.buttons"

    # Enrollment child: fully detached from the tty, everything logged.
    ( exec </dev/null >>"$enroll_log" 2>&1; esd_import ) &
    child_pid=$!

    rc=""
    ticks=0
    last_shown=""

    while true; do
        # Child finished?
        if ! kill -0 "$child_pid" 2>/dev/null; then
            rc=0
            wait "$child_pid" || rc=$?
            break
        fi

        # Watchdog
        ticks=$((ticks + 1))
        if [ "$ticks" -gt "$EUI_TIMEOUT_TICKS" ]; then
            printf 'watchdog: enrollment timed out, killing\n' >> "$enroll_log"
            eui_kill_enrollment "$child_pid"
            rc=3
            break
        fi

        # Buttons
        if btn=$(eui_next_button); then
            case "$btn" in
                "$EUI_BTN_B")
                    printf 'user: cancelled via B button\n' >> "$enroll_log"
                    eui_kill_enrollment "$child_pid"
                    rc=2
                    break
                    ;;
                "$EUI_BTN_X"|"$EUI_BTN_Y")
                    eui_log_replay "$enroll_log"
                    ;;
                *)
                    printf 'input: unmapped button number %s pressed\n' "$btn" >> "$enroll_log"
                    ;;
            esac
        fi

        # Mirror the latest log line to the screen
        current=$(tail -n 1 "$enroll_log" 2>/dev/null)
        if [ -n "$current" ] && [ "$current" != "$last_shown" ]; then
            eui_show_line "$current"
            last_shown="$current"
        fi

        sleep "$EUI_TICK"
    done

    eui_btn_listener_stop

    # Normalize esd_import's failure to rc=1
    if [ "$rc" != 0 ] && [ "$rc" != 2 ] && [ "$rc" != 3 ]; then
        rc=1
    fi
    printf '=== enrollment finished rc=%s ===\n' "$rc" >> "$enroll_log"
    return "$rc"
}
