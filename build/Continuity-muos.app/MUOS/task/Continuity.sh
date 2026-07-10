#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity — muOS Task Toolkit entry ("Continuity.sh" in MUOS/task/).
# The user-facing tap: preflight doctor -> enrollment (when setup.json
# is staged) -> daemon start/status. This is the day-one manual start;
# the muOS boot-hook wiring lands after the first validation round
# (the preflight's boot-hook lines capture what init offers).
#
# The bootstrap/recovery path stays device-native by design: this
# script NEVER uses the vendored busybox (fail-open invariant — same
# rule as NextUI's launch.sh).
#
# Test hooks:
#   CONTINUITY_SD_ROOT   — SD1 root (default: derived from script path,
#                          MUOS/task/ is two levels below the SD root)
#   CONTINUITY_APP_DIR   — app dir (default: <SD>/.continuity/app)
#   TC_NO_MAIN=1         — source-only (unit tests call functions)
set -e

# tc_say — one line to the task console AND the launch log. muOS task
# consoles vary across releases; the log line is the reliable record.
tc_say() {
    printf '%s\n' "$*"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$TC_LOG" 2>/dev/null || true
}

tc_source_modules() {
    local scripts_dir core_dir f
    scripts_dir="$CONTINUITY_APP_DIR/scripts"
    core_dir="$scripts_dir/core"
    for f in "$scripts_dir/pal_muos.sh" "$core_dir/pal.sh" \
             "$core_dir/path_mapper.sh" "$core_dir/sync_engine.sh" \
             "$core_dir/enrollment.sh" "$scripts_dir/enroll_sd_card.sh" \
             "$scripts_dir/preflight.sh"; do
        if [ ! -f "$f" ]; then
            tc_say "ERROR: module missing: $f — incomplete install, re-copy the app folder"
            return 1
        fi
        # shellcheck disable=SC1090
        . "$f"
    done
    return 0
}

# tc_daemon_running — PID-file liveness (same semantics as the daemon)
tc_daemon_running() {
    local pid
    [ -f "$CONTINUITY_PID_FILE" ] || return 1
    pid=$(cat "$CONTINUITY_PID_FILE" 2>/dev/null)
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    kill -0 "$pid" 2>/dev/null
}

tc_start_daemon() {
    local daemon ticks
    daemon="$CONTINUITY_APP_DIR/scripts/continuity_daemon.sh"
    if [ ! -f "$daemon" ]; then
        tc_say "ERROR: daemon script missing: $daemon"
        return 1
    fi
    tc_say "Starting Continuity daemon..."
    # muOS's task runner kills the task's process group when the task
    # exits — a plain backgrounded child dies with it (field-found on
    # the RG40XX V, build 0.1.0-muos-20260709-2236: enrollment worked,
    # the daemon silently died, the cold-start push never happened).
    # setsid detaches the daemon into its own session and process
    # group; nohup is the fallback shield on a userland without it.
    if command -v setsid >/dev/null 2>&1; then
        setsid sh "$daemon" </dev/null >/dev/null 2>&1 &
    elif command -v nohup >/dev/null 2>&1; then
        nohup sh "$daemon" </dev/null >/dev/null 2>&1 &
    else
        sh "$daemon" </dev/null >/dev/null 2>&1 &
    fi
    # Trust nothing: the daemon writes its PID file within a couple of
    # seconds of a healthy start. Verify and report the truth — a
    # daemon that dies on task exit must never be silent again.
    ticks="${TC_START_WAIT_TICKS:-6}"
    while [ "$ticks" -gt 0 ]; do
        if tc_daemon_running; then
            tc_say "Daemon confirmed alive (PID $(cat "$CONTINUITY_PID_FILE" 2>/dev/null))"
            return 0
        fi
        sleep 1
        ticks=$((ticks - 1))
    done
    tc_say "Daemon did NOT stay up after start — see .continuity/continuity.log"
    return 1
}

tc_status() {
    local last_sync last_err
    if tc_daemon_running; then
        tc_say "Daemon: running (PID $(cat "$CONTINUITY_PID_FILE"))"
    else
        tc_say "Daemon: NOT running"
    fi
    if [ -f "$CONTINUITY_LOG_FILE" ]; then
        last_sync=$(grep 'Push\|push\|Committed\|sync' "$CONTINUITY_LOG_FILE" 2>/dev/null | tail -1 | cut -c1-120)
        last_err=$(grep 'error' "$CONTINUITY_LOG_FILE" 2>/dev/null | tail -1 | cut -c1-120)
        [ -n "$last_sync" ] && tc_say "Last sync activity: $last_sync"
        [ -n "$last_err" ] && tc_say "Last error: $last_err"
    fi
    return 0
}

tc_main() {
    # SD root: this script lives at <SD>/MUOS/task/Continuity.sh
    CONTINUITY_SD_ROOT="${CONTINUITY_SD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
    export CONTINUITY_SD_ROOT
    CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$CONTINUITY_SD_ROOT/.continuity/app}"
    export CONTINUITY_APP_DIR
    CONTINUITY_PID_FILE="${CONTINUITY_PID_FILE:-/tmp/continuity.pid}"
    CONTINUITY_LOG_FILE="${CONTINUITY_LOG_FILE:-$CONTINUITY_SD_ROOT/.continuity/continuity.log}"

    # Unconditional breadcrumb — a failed launch must never be invisible
    # (NextUI defect #8; the rule carries over verbatim).
    mkdir -p "$CONTINUITY_SD_ROOT/.continuity" 2>/dev/null || true
    TC_LOG="$CONTINUITY_SD_ROOT/.continuity/launch.log"
    printf '[%s] task launch, app=%s version=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$CONTINUITY_APP_DIR" \
        "$(cat "$CONTINUITY_APP_DIR/version.txt" 2>/dev/null || printf 'unknown')" \
        >> "$TC_LOG" 2>/dev/null || true

    if [ ! -d "$CONTINUITY_APP_DIR" ]; then
        tc_say "Continuity app not installed at $CONTINUITY_APP_DIR — copy the app folder to the card first"
        exit 1
    fi

    if ! tc_source_modules; then
        exit 1
    fi

    # Preflight doctor — full report at the SD root, first failure named
    # on the console (observability protocol).
    if pf_run "$CONTINUITY_SD_ROOT/CONTINUITY_DIAGNOSTIC.txt"; then
        tc_say "Preflight: all checks passed"
    else
        tc_say "Preflight: FAILED — $_pf_first_fail"
        tc_say "Full report: CONTINUITY_DIAGNOSTIC.txt at the card root"
        # Enrollment/status can still proceed for non-fatal cases the
        # doctor calls FAIL but the flow can survive (e.g. offline
        # status check); the daemon makes its own calls.
    fi

    if enroll_is_enrolled; then
        if tc_daemon_running; then
            tc_say "Continuity is enrolled and running."
        else
            tc_start_daemon || true
        fi
        tc_status
        exit 0
    fi

    # Not enrolled
    if ! esd_detect_setup_file; then
        tc_say "Not enrolled. Stage setup.json at the card root (see docs) and run this task again."
        exit 0
    fi

    tc_say "setup.json found — enrolling (log: .continuity/enroll.log)..."
    rc=0
    esd_import >> "$CONTINUITY_SD_ROOT/.continuity/enroll.log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ] && enroll_is_enrolled; then
        tc_say "Enrollment complete: $(cat "$CONTINUITY_REPO_DIR/.continuity/device_name" 2>/dev/null)"
        tc_start_daemon || true
        tc_status
        exit 0
    fi
    tc_say "Enrollment FAILED — last log line: $(tail -1 "$CONTINUITY_SD_ROOT/.continuity/enroll.log" 2>/dev/null | cut -c1-120)"
    tc_say "setup.json is preserved for retry. Full log: .continuity/enroll.log"
    exit 1
}

if [ -z "${TC_NO_MAIN:-}" ]; then
    tc_main "$@"
fi
