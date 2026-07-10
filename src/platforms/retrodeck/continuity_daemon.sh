#!/bin/sh
# shellcheck shell=ash  # POSIX sh — parses under busybox ash for the test suite
# shellcheck disable=SC3043
# Continuity Daemon — RetroDeck (Steam Deck, host side).
# Runs as a systemd --user service (src/platforms/retrodeck/continuity.service).
#
# Deliberately simpler than the NextUI daemon: systemd owns single-
# instancing, restarts, and log capture (stderr → journald), and the
# host shell is a known quantity — no PID file, no vendored
# interpreter, no log-file management, no SD-card enrollment. The
# boot-dispatch and poll-cycle SEMANTICS mirror the NextUI daemon
# exactly (deferred cold start, WiFi-recovery push, throttled
# in-session reconcile); if a third platform needs this skeleton it
# should be hoisted into core (flagged in the sprint summary).
#
# Exit codes: 78 (EX_CONFIG) = not enrolled / config missing — the unit
# sets RestartPreventExitStatus=78 so systemd does not thrash on it.
#
# Change detection (Sprint 2.2): event-driven via one-shot inotifywait
# with a timeout — inotify decides WHEN a cycle runs; the sentinel scan
# in rp_run stays the single source of truth for WHAT changed, so a
# missed event can only ever delay a sync (to the next housekeeping
# wake or the shutdown final sweep), never lose one. Polling remains as
# the named fallback wherever inotifywait is absent or failing.
#
# Test hooks (production values on the device):
#   CONTINUITY_POLL_INTERVAL       — poll-mode interval; event-mode
#                                    timeout while work is pending
#   CONTINUITY_DETECT_MODE         — auto|inotify|poll (default auto)
#   CONTINUITY_EVENT_IDLE_INTERVAL — event-mode housekeeping timeout
#                                    when idle + fully synced
#   CONTINUITY_EVENT_SETTLE        — seconds to let an event burst
#                                    settle before syncing
#   CONTINUITY_INOTIFY_BIN         — watcher binary (stub / static)
#   CONTINUITY_APP_DIR             — checkout root (from $0 if unset)
#   CONTINUITY_DAEMON_NO_MAIN      — if set, source functions only
set -e

readonly CONTINUITY_VERSION="0.2.0-dev"
readonly CONTINUITY_POLL_INTERVAL="${CONTINUITY_POLL_INTERVAL:-30}"
readonly CONTINUITY_DETECT_MODE="${CONTINUITY_DETECT_MODE:-auto}"
readonly CONTINUITY_EVENT_IDLE_INTERVAL="${CONTINUITY_EVENT_IDLE_INTERVAL:-300}"
readonly CONTINUITY_EVENT_SETTLE="${CONTINUITY_EVENT_SETTLE:-2}"
readonly CONTINUITY_INOTIFY_BIN="${CONTINUITY_INOTIFY_BIN:-inotifywait}"

# ── Module Loading ───────────────────────────────────────────────────

# rdd_source_file — source a module or die with a named error.
rdd_source_file() {
    if [ ! -f "$1" ]; then
        printf '[%s] error: module not found: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
        exit 78
    fi
    # shellcheck disable=SC1090
    . "$1"
}

rdd_load_modules() {
    local core_dir
    core_dir="$CONTINUITY_APP_DIR/src/core"

    rdd_source_file "$CONTINUITY_APP_DIR/src/platforms/retrodeck/pal_retrodeck.sh"
    rdd_source_file "$core_dir/pal.sh"
    rdd_source_file "$core_dir/path_mapper.sh"
    rdd_source_file "$core_dir/sync_engine.sh"
    rdd_source_file "$core_dir/enrollment.sh"
    rdd_source_file "$core_dir/change_detector.sh"
    rdd_source_file "$core_dir/cold_start.sh"
    rdd_source_file "$core_dir/boot_pull.sh"
    rdd_source_file "$core_dir/stale_boot.sh"
    rdd_source_file "$core_dir/runtime_poll.sh"
    rdd_source_file "$core_dir/conflict_handler.sh"
    rdd_source_file "$core_dir/sync_status.sh"
}

# ── Boot Dispatch (same routing as the NextUI daemon) ────────────────

rdd_boot_dispatch() {
    local repo_dir rc
    repo_dir="$1"
    rc=0
    if cs_is_cold_start "$repo_dir"; then
        pal_log "info" "Boot: cold start — first sync"
        cs_run "$repo_dir" || rc=$?
    elif sb_is_stale "$repo_dir"; then
        pal_log "info" "Boot: stale — recovering from unclean shutdown"
        sb_run "$repo_dir" || rc=$?
    else
        pal_log "info" "Boot: normal — pulling remote changes"
        sb_clear_shutdown_marker "$repo_dir" || \
            pal_log "warn" "Could not clear clean-shutdown marker"
        bp_run "$repo_dir" || rc=$?
    fi
    return "$rc"
}

# ── Change-Detection Wait (Sprint 2.2) ───────────────────────────────

_RDD_WATCH_MODE="poll"
_RDD_WATCH_FAILURES=0
_RDD_WAIT_PID=""

# rdd_detect_watch_mode — pick inotify vs poll once at startup and say
# so (observability rule: every mode and every fallback names itself).
rdd_detect_watch_mode() {
    case "$CONTINUITY_DETECT_MODE" in
        poll)
            _RDD_WATCH_MODE="poll"
            pal_log "info" "Change detection: polling (${CONTINUITY_POLL_INTERVAL}s interval, forced)"
            ;;
        inotify|auto)
            if command -v "$CONTINUITY_INOTIFY_BIN" >/dev/null 2>&1; then
                _RDD_WATCH_MODE="inotify"
                pal_log "info" "Change detection: inotify (event-driven; idle housekeeping every ${CONTINUITY_EVENT_IDLE_INTERVAL}s)"
            else
                _RDD_WATCH_MODE="poll"
                pal_log "warn" "inotifywait not found ($CONTINUITY_INOTIFY_BIN) — falling back to ${CONTINUITY_POLL_INTERVAL}s polling"
            fi
            ;;
        *)
            _RDD_WATCH_MODE="poll"
            pal_log "warn" "Unknown CONTINUITY_DETECT_MODE '$CONTINUITY_DETECT_MODE' — using ${CONTINUITY_POLL_INTERVAL}s polling"
            ;;
    esac
    return 0
}

# _rdd_wait_timeout — housekeeping timeout for the next wait. Pending
# work (a deferred cold start, queued commits) keeps today's short
# recovery cadence — which also keeps the reconcile cooldown's
# cycle-counting at its designed ~5-minute wall-clock pace, since the
# cooldown only counts while pushes are failing. An idle, fully-synced
# Deck slows to the idle interval; events wake it instantly either way.
_rdd_wait_timeout() {
    if cs_is_cold_start "$CONTINUITY_REPO_DIR" || \
       se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        printf '%s' "$CONTINUITY_POLL_INTERVAL"
    else
        printf '%s' "$CONTINUITY_EVENT_IDLE_INTERVAL"
    fi
    return 0
}

# _rdd_sleep_interruptible <seconds> — backgrounded sleep + wait, so a
# SIGTERM during the wait runs the trap immediately instead of stalling
# `systemctl --user stop` for a full interval.
_rdd_sleep_interruptible() {
    sleep "$1" &
    _RDD_WAIT_PID=$!
    wait "$_RDD_WAIT_PID" 2>/dev/null || true
    _RDD_WAIT_PID=""
    return 0
}

# rdd_wait_for_change — block until a save/state changed (inotify event)
# or the housekeeping timeout elapsed; either way the caller runs the
# same idempotent poll cycle. One-shot inotifywait (not -m): no watcher
# process to babysit, no event parsing, no queue-overflow loss mode, and
# watches re-establish every cycle so new system dirs are covered. The
# cost is a blind window while a cycle runs — bounded by the next
# timeout wake, never a lost save (the sentinel scan is the detector).
rdd_wait_for_change() {
    if [ "$_RDD_WATCH_MODE" != "inotify" ]; then
        _rdd_sleep_interruptible "$CONTINUITY_POLL_INTERVAL"
        return 0
    fi

    local timeout rc
    timeout=$(_rdd_wait_timeout)

    # Backgrounded + wait: same SIGTERM story as the sleep. The states
    # root rides along only when the PAL defines it and it exists.
    # shellcheck disable=SC2153  # both roots are assigned by the sourced PAL
    if [ -n "${CONTINUITY_STATES_ROOT:-}" ] && [ -d "$CONTINUITY_STATES_ROOT" ]; then
        "$CONTINUITY_INOTIFY_BIN" -qq -r -t "$timeout" \
            -e close_write -e moved_to -e create \
            "$CONTINUITY_SAVES_ROOT" "$CONTINUITY_STATES_ROOT" 2>/dev/null &
    else
        "$CONTINUITY_INOTIFY_BIN" -qq -r -t "$timeout" \
            -e close_write -e moved_to -e create \
            "$CONTINUITY_SAVES_ROOT" 2>/dev/null &
    fi
    _RDD_WAIT_PID=$!
    rc=0
    wait "$_RDD_WAIT_PID" 2>/dev/null || rc=$?
    _RDD_WAIT_PID=""

    case "$rc" in
        0)
            # Event: let the burst settle (.srm + .rtc siblings,
            # RetroArch's write-then-rename) so one wake = one commit.
            _RDD_WATCH_FAILURES=0
            if [ "$CONTINUITY_EVENT_SETTLE" -gt 0 ] 2>/dev/null; then
                sleep "$CONTINUITY_EVENT_SETTLE"
            fi
            ;;
        2)
            # Timeout: the normal housekeeping wake.
            _RDD_WATCH_FAILURES=0
            ;;
        *)
            # Watch failure (watch limit, unmounted root, bad binary).
            # Wait a full poll interval so a broken watcher never
            # hot-spins, and flip to polling for good on strike three
            # (recovery to inotify = daemon restart, deliberately).
            _RDD_WATCH_FAILURES=$((_RDD_WATCH_FAILURES + 1))
            pal_log "warn" "inotify wait failed (rc $rc, strike $_RDD_WATCH_FAILURES/3)"
            if [ "$_RDD_WATCH_FAILURES" -ge 3 ]; then
                _RDD_WATCH_MODE="poll"
                pal_log "warn" "inotify failed 3x — switching to ${CONTINUITY_POLL_INTERVAL}s polling for this run"
            fi
            _rdd_sleep_interruptible "$CONTINUITY_POLL_INTERVAL"
            ;;
    esac
    return 0
}

# ── Shutdown (systemctl --user stop → SIGTERM) ───────────────────────

# Every step guarded: a trap handler under `set -e` must always reach
# exit 0, or systemd counts the stop as a failure.
rdd_shutdown() {
    pal_log "info" "Shutdown: SIGTERM received"

    # Reap the backgrounded waiter (sleep or inotifywait) — systemd's
    # cgroup kill would get it anyway; this keeps stop immediate + tidy.
    if [ -n "${_RDD_WAIT_PID:-}" ]; then
        kill "$_RDD_WAIT_PID" 2>/dev/null || true
    fi

    # Final sweep — a save flushed after the last poll cycle must ride
    # the final push (or stale-boot pushes it next start if offline).
    if ! cs_is_cold_start "$CONTINUITY_REPO_DIR"; then
        rp_run "$CONTINUITY_REPO_DIR" 2>/dev/null || \
            pal_log "warn" "Shutdown: final sweep had errors"
    fi

    if se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        if pal_is_online; then
            if se_push "$CONTINUITY_REPO_DIR"; then
                pal_log "info" "Shutdown: pushed queued commits"
            else
                pal_log "warn" "Shutdown: final push failed"
            fi
        else
            pal_log "info" "Shutdown: offline — commits queued for next start"
        fi
    fi

    # Clean marker only when nothing is left unpushed; otherwise the
    # next start must run stale recovery, which pushes first thing.
    if ! se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        if sb_mark_clean_shutdown "$CONTINUITY_REPO_DIR"; then
            pal_log "info" "Shutdown: clean shutdown marker written"
        else
            pal_log "warn" "Shutdown: failed to write clean shutdown marker"
        fi
    else
        pal_log "warn" "Shutdown: unpushed commits remain — skipping clean marker"
    fi

    pal_log "info" "Shutdown: complete"
    exit 0
}

# ── Poll Cycle (same semantics as the NextUI daemon) ─────────────────

# Throttle the in-session reconcile: on a persistent push failure one
# attempt per CONTINUITY_RECONCILE_COOLDOWN_TICKS (default 10 ≈ 5 min)
# is plenty.
_RDD_RECONCILE_COOLDOWN=0

rdd_poll_once() {
    # A cold start deferred at boot (network not up yet) must be
    # retried once the network appears, or no sentinel ever exists.
    if cs_is_cold_start "$CONTINUITY_REPO_DIR"; then
        if pal_is_online; then
            pal_log "info" "Retrying deferred cold start"
            cs_run "$CONTINUITY_REPO_DIR" || pal_log "warn" "Deferred cold start had errors"
        else
            pal_log "info" "Cold start still deferred — waiting for network"
        fi
        return 0
    fi

    # Connectivity recovery: push queued commits when the network returns.
    if pal_is_online; then
        if se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
            pal_log "info" "Network available — pushing queued commits"
            se_push "$CONTINUITY_REPO_DIR" || pal_log "warn" "Recovery push failed"
        fi
    fi

    rp_run "$CONTINUITY_REPO_DIR" || pal_log "warn" "Poll cycle had errors"

    # Commits that would not push while ONLINE mean the remote moved
    # under us — run the idempotent stale-boot reconcile inline,
    # throttled (gap-review fix, mirrored from the NextUI daemon).
    if [ "$_RDD_RECONCILE_COOLDOWN" -gt 0 ]; then
        _RDD_RECONCILE_COOLDOWN=$((_RDD_RECONCILE_COOLDOWN - 1))
    elif pal_is_online && se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        pal_log "info" "Push did not land while online — reconciling with remote"
        sb_run "$CONTINUITY_REPO_DIR" || pal_log "warn" "In-session reconcile had errors"
        _RDD_RECONCILE_COOLDOWN="${CONTINUITY_RECONCILE_COOLDOWN_TICKS:-10}"
    fi
    return 0
}

rdd_poll_loop() {
    trap rdd_shutdown TERM INT

    if [ "$_RDD_WATCH_MODE" = "inotify" ]; then
        pal_log "info" "Entering event loop"
    else
        pal_log "info" "Entering poll loop (${CONTINUITY_POLL_INTERVAL}s interval)"
    fi

    while true; do
        rdd_poll_once
        rdd_wait_for_change
    done
}

# ── Main ─────────────────────────────────────────────────────────────

rdd_main() {
    # Script lives at <app>/src/platforms/retrodeck/continuity_daemon.sh
    CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
    export CONTINUITY_APP_DIR

    printf '[%s] info: Daemon v%s starting (PID %s)\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$CONTINUITY_VERSION" "$$" >&2

    rdd_load_modules

    # Enrollment is a prerequisite here (the unit is installed BY
    # enrollment) — a not-enrolled start is a config error, named, and
    # exempted from systemd restart thrash via exit 78.
    if ! enroll_is_enrolled; then
        pal_log "error" "Not enrolled — run src/platforms/retrodeck/enroll_retrodeck.sh first"
        exit 78
    fi

    pal_init || { pal_log "error" "PAL init failed"; exit 78; }
    pal_validate || { pal_log "error" "PAL validation failed"; exit 78; }
    se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" || \
        { pal_log "error" "Sync engine init failed"; exit 1; }
    pm_load_platform_map "$(pal_get_platform_map)" || \
        { pal_log "error" "Failed to load platform map"; exit 78; }

    pal_log "info" "Bootstrap complete, enrolled as $CONTINUITY_DEVICE_NAME"

    rdd_detect_watch_mode

    # Boot dispatch errors are non-fatal — an offline boot pull must
    # not stop the poll loop (recovery push handles the rest).
    boot_rc=0
    rdd_boot_dispatch "$CONTINUITY_REPO_DIR" || boot_rc=$?
    if [ "$boot_rc" -ne 0 ]; then
        pal_log "warn" "Boot dispatch returned $boot_rc — continuing"
    fi

    rdd_poll_loop
}

# Unit tests source this file with CONTINUITY_DAEMON_NO_MAIN=1 to get
# the functions without running the daemon.
if [ -z "${CONTINUITY_DAEMON_NO_MAIN:-}" ]; then
    rdd_main "$@"
fi
