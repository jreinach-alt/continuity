#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity Daemon — muOS (Anbernic RG40XX V)
# Started from the Task Toolkit launcher (task_continuity.sh); the muOS
# boot-hook wiring is resolved in the first on-device validation round.
# Manages enrollment, sync, and lifecycle.
#
# Test hooks (all default to production values on the device):
#   CONTINUITY_PID_FILE       — PID file location
#   CONTINUITY_LOG_FILE       — log file location
#   CONTINUITY_POLL_INTERVAL  — seconds between poll cycles
#   CONTINUITY_APP_DIR        — app root (derived from script path if unset)
#   CONTINUITY_DAEMON_NO_MAIN — if set, skip cd_main (unit tests source only)
set -e

readonly CONTINUITY_PID_FILE="${CONTINUITY_PID_FILE:-/tmp/continuity.pid}"
readonly CONTINUITY_VERSION="0.1.0"

# ── PID Management ───────────────────────────────────────────────────

# cd_write_pid — write current PID to file
cd_write_pid() {
    printf '%s\n' "$$" > "$CONTINUITY_PID_FILE"
}

# cd_is_running — check if another daemon instance is alive
# Returns: 0 if running, 1 if not
cd_is_running() {
    [ -f "$CONTINUITY_PID_FILE" ] || return 1

    local pid
    pid=$(cat "$CONTINUITY_PID_FILE")

    # Non-numeric PID → stale
    case "$pid" in
        ''|*[!0-9]*) rm -f "$CONTINUITY_PID_FILE"; return 1 ;;
    esac

    # Check if process is alive
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    # Stale PID
    rm -f "$CONTINUITY_PID_FILE"
    return 1
}

# cd_remove_pid — remove PID file
cd_remove_pid() {
    rm -f "$CONTINUITY_PID_FILE"
    return 0
}

# ── Vendored Interpreter (fail-open) ─────────────────────────────────

# cd_reexec_busybox — re-exec the daemon under the app's pinned BusyBox.
# The device's /bin/sh is whatever BusyBox build the firmware shipped;
# version and applet drift across firmware builds is real. The app dir carries
# the exact BusyBox the test suite runs under (build_busybox.sh), and
# with SH_STANDALONE its ash prefers its own applets — pinning grep,
# sed, find, cmp and friends too, not just the shell dialect.
#
# FAIL-OPEN INVARIANT: every path out of this function other than a
# fully self-tested exec falls through to the device shell. A missing,
# truncated, wrong-arch, or otherwise broken vendored binary must never
# take the daemon down with it — the device shell runs the daemon today
# and remains the safety net. launch.sh never uses the vendored
# interpreter at all: the bootstrap/recovery path stays device-native.
#
# Test hooks: CONTINUITY_VENDOR_SH=0 kill switch; CONTINUITY_DAEMON_SELF
# overrides the script path used for the parse probe and re-exec.
cd_reexec_busybox() {
    # Already running under the vendored interpreter — never loop.
    [ -z "$CONTINUITY_BB_REEXEC" ] || { CONTINUITY_BB_STATUS="vendored busybox (pinned)"; return 0; }

    if [ "${CONTINUITY_VENDOR_SH:-1}" != "1" ]; then
        CONTINUITY_BB_STATUS="device sh (vendored interpreter disabled)"
        return 0
    fi

    local bb self
    bb="$CONTINUITY_APP_DIR/bin/busybox"
    self="${CONTINUITY_DAEMON_SELF:-$0}"

    if [ ! -x "$bb" ]; then
        CONTINUITY_BB_STATUS="device sh (no vendored busybox bundled)"
        return 0
    fi

    # Self-test 1: the binary executes on this hardware and its ash runs
    # a command (catches wrong-arch, truncated copy, exec format errors).
    if ! "$bb" ash -c 'true' >/dev/null 2>&1; then
        CONTINUITY_BB_STATUS="device sh (vendored busybox failed self-test)"
        return 0
    fi

    # Self-test 2: the vendored ash can parse this script.
    if ! "$bb" ash -n "$self" >/dev/null 2>&1; then
        CONTINUITY_BB_STATUS="device sh (vendored ash cannot parse daemon)"
        return 0
    fi

    CONTINUITY_BB_REEXEC=1
    export CONTINUITY_BB_REEXEC
    # Note: ash exits (127) if exec itself fails — it does not return.
    # The self-tests above just executed this exact binary twice, so a
    # failure here means the file changed in the last few milliseconds;
    # there is no shell-level way to guard that residual window while
    # keeping same-PID semantics (PID file, SIGTERM supervision).
    exec "$bb" ash "$self" "$@"
}

# ── Module Loading ───────────────────────────────────────────────────

# cd_source_file — source a file with error handling
# Usage: cd_source_file <path>
# Pre-pal_log: uses printf to stderr directly
cd_source_file() {
    local file cr
    file="$1"
    if [ ! -f "$file" ]; then
        printf '[%s] error: module not found: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$file" >&2
        cd_remove_pid
        exit 1
    fi
    # CRLF line endings make ash die mid-source with a cryptic
    # ": not found" under set -e. Name the real problem instead.
    cr=$(printf '\r')
    if grep -q "$cr" "$file" 2>/dev/null; then
        printf '[%s] error: CRLF line endings in %s — app copy is corrupt, re-copy it\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$file" >&2
        cd_remove_pid
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$file"
}

# cd_load_modules — source PAL and all core modules
cd_load_modules() {
    local scripts_dir core_dir
    scripts_dir="$CONTINUITY_APP_DIR/scripts"
    core_dir="$scripts_dir/core"

    # PAL first (provides pal_log, platform vars)
    cd_source_file "$scripts_dir/pal_muos.sh"

    # PAL validator
    cd_source_file "$core_dir/pal.sh"

    # Core modules in dependency order
    cd_source_file "$core_dir/path_mapper.sh"
    cd_source_file "$core_dir/sync_engine.sh"
    cd_source_file "$core_dir/enrollment.sh"
    cd_source_file "$core_dir/change_detector.sh"
    cd_source_file "$core_dir/cold_start.sh"
    cd_source_file "$core_dir/boot_pull.sh"
    cd_source_file "$core_dir/stale_boot.sh"
    cd_source_file "$core_dir/runtime_poll.sh"
    cd_source_file "$core_dir/conflict_handler.sh"
    cd_source_file "$core_dir/sync_status.sh"

    # Platform modules
    cd_source_file "$scripts_dir/enroll_sd_card.sh"
}

# ── Enrollment ───────────────────────────────────────────────────────

# cd_check_enrollment — verify or perform enrollment
# Returns: 0 if enrolled, 1 if not
cd_check_enrollment() {
    # Already enrolled?
    if enroll_is_enrolled; then
        pal_log "info" "Device is enrolled"
        return 0
    fi

    # Not enrolled — check for setup.json
    if ! esd_detect_setup_file; then
        pal_log "error" "Not enrolled, no setup.json found"
        return 1
    fi

    # At boot, WiFi comes up in the background around the time the boot
    # task runs us — give the network a bounded window before the clone.
    # CONTINUITY_NET_WAIT_TICKS/SLEEP are test hooks (defaults: 12 × 5s).
    local net_ticks
    net_ticks="${CONTINUITY_NET_WAIT_TICKS:-12}"
    while ! pal_is_online && [ "$net_ticks" -gt 0 ]; do
        pal_log "info" "Waiting for network before enrollment ($net_ticks tries left)"
        sleep "${CONTINUITY_NET_WAIT_SLEEP:-5}"
        net_ticks=$((net_ticks - 1))
    done
    if ! pal_is_online; then
        pal_log "error" "Not enrolled and network never came up — will retry next boot"
        return 1
    fi

    # Run enrollment
    pal_log "info" "setup.json found, running enrollment"
    if ! esd_import; then
        pal_log "error" "Enrollment failed"
        return 1
    fi

    # Full re-initialization (PAL, sync engine, platform map) happens in
    # cd_main after this returns — it is identical for the already-enrolled
    # and fresh-enrollment paths.
    pal_log "info" "Enrollment complete"
    return 0
}

# ── Boot Dispatch (Sprint 1.2) ──────────────────────────────────────

# cd_boot_dispatch — route to the correct sync phase for this boot
# Usage: cd_boot_dispatch <repo_dir>
# Returns: the exit code of whichever phase ran (caller decides severity)
cd_boot_dispatch() {
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
        # Consume the one-shot marker so a crash in THIS session is
        # correctly detected as stale on the next boot.
        sb_clear_shutdown_marker "$repo_dir" || \
            pal_log "warn" "Could not clear clean-shutdown marker"
        bp_run "$repo_dir" || rc=$?
    fi
    return "$rc"
}

# ── Poll Loop (Sprint 1.3) ──────────────────────────────────────────

readonly CONTINUITY_POLL_INTERVAL="${CONTINUITY_POLL_INTERVAL:-30}"

# cd_shutdown — SIGTERM handler
# Every step is guarded: a trap handler under `set -e` must always reach
# its cleanup and exit 0, or the PID file and log go stale.
cd_shutdown() {
    pal_log "info" "Shutdown: SIGTERM received"

    # Final sweep: "save → quit game → power off" is THE canonical
    # handheld flow, and the freshly-flushed .srm may have landed after
    # the last poll cycle. Commit it now so the push below carries it
    # (or stale-boot pushes it next time if we're offline).
    if ! cs_is_cold_start "$CONTINUITY_REPO_DIR"; then
        rp_run "$CONTINUITY_REPO_DIR" 2>/dev/null || \
            pal_log "warn" "Shutdown: final sweep had errors"
    fi

    # Final push attempt
    if se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        if pal_is_online; then
            if se_push "$CONTINUITY_REPO_DIR"; then
                pal_log "info" "Shutdown: pushed queued commits"
            else
                pal_log "warn" "Shutdown: final push failed"
            fi
        else
            pal_log "info" "Shutdown: offline — commits queued for next boot"
        fi
    fi

    # Mark clean shutdown only if no unpushed commits remain; otherwise the
    # next boot must run stale recovery, which pushes them first thing.
    if ! se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        if sb_mark_clean_shutdown "$CONTINUITY_REPO_DIR"; then
            pal_log "info" "Shutdown: clean shutdown marker written"
        else
            pal_log "warn" "Shutdown: failed to write clean shutdown marker"
        fi
    else
        pal_log "warn" "Shutdown: unpushed commits remain — skipping clean marker"
    fi

    cd_remove_pid
    pal_log "info" "Shutdown: complete"
    exit 0
}

# cd_poll_once — one poll cycle. Factored out of the loop so tests can
# drive single cycles.
#
# _CD_RECONCILE_COOLDOWN throttles the in-session reconcile: on a
# PERSISTENT push failure (e.g. revoked credentials) a reconcile per
# tick would hammer the network every 30s; one attempt per
# CONTINUITY_RECONCILE_COOLDOWN_TICKS (default 10 ≈ 5 min) is plenty.
_CD_RECONCILE_COOLDOWN=0

cd_poll_once() {
    # A cold start deferred at boot (offline WiFi race) must be retried
    # once the network appears — otherwise the sentinel never exists and
    # every poll of the whole session errors out. Field-found on the
    # first real save test.
    if cs_is_cold_start "$CONTINUITY_REPO_DIR"; then
        if pal_is_online; then
            pal_log "info" "Retrying deferred cold start"
            cs_run "$CONTINUITY_REPO_DIR" || pal_log "warn" "Deferred cold start had errors"
        else
            pal_log "info" "Cold start still deferred — waiting for network"
        fi
        return 0
    fi

    # WiFi recovery: push queued commits when connectivity returns
    if pal_is_online; then
        if se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
            pal_log "info" "WiFi available — pushing queued commits"
            se_push "$CONTINUITY_REPO_DIR" || pal_log "warn" "WiFi recovery push failed"
        fi
    fi

    # Runtime poll
    rp_run "$CONTINUITY_REPO_DIR" || pal_log "warn" "Poll cycle had errors"

    # In-session divergence reconcile (gap review 2026-07-07): commits
    # that would not push while ONLINE mean the remote moved under us
    # (another device synced or enrolled). This used to retry blindly
    # every tick until REBOOT — only boot dispatch ran the
    # pull/conflict path. The stale-boot flow is idempotent and does
    # exactly what's needed (push-first, conflict preservation, remote
    # apply, catch-up, sentinel), so run it inline, throttled.
    if [ "$_CD_RECONCILE_COOLDOWN" -gt 0 ]; then
        _CD_RECONCILE_COOLDOWN=$((_CD_RECONCILE_COOLDOWN - 1))
    elif pal_is_online && se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        pal_log "info" "Push did not land while online — reconciling with remote"
        sb_run "$CONTINUITY_REPO_DIR" || pal_log "warn" "In-session reconcile had errors"
        _CD_RECONCILE_COOLDOWN="${CONTINUITY_RECONCILE_COOLDOWN_TICKS:-10}"
    fi
    return 0
}

# cd_poll_loop — runtime sync loop
cd_poll_loop() {
    # Set trap after boot dispatch
    trap cd_shutdown TERM

    pal_log "info" "Entering poll loop (${CONTINUITY_POLL_INTERVAL}s interval)"

    while true; do
        cd_poll_once

        # Backgrounded sleep + wait: a SIGTERM during the sleep interrupts
        # `wait` immediately, so shutdown never blocks up to a full interval.
        sleep "$CONTINUITY_POLL_INTERVAL" &
        wait $!
    done
}

# ── Main ─────────────────────────────────────────────────────────────

cd_main() {
    # Determine app directory from script location
    # Script is at: .continuity/app/scripts/continuity_daemon.sh
    CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
    export CONTINUITY_APP_DIR

    # Pinned interpreter, before anything else touches state. Either
    # execs (and this function restarts under the vendored ash with
    # CONTINUITY_BB_REEXEC=1) or falls through with a reason in
    # CONTINUITY_BB_STATUS.
    cd_reexec_busybox "$@"

    # Log file setup
    CONTINUITY_LOG_FILE="${CONTINUITY_LOG_FILE:-/mnt/mmc/.continuity/continuity.log}"
    mkdir -p "$(dirname "$CONTINUITY_LOG_FILE")"
    exec 2>>"$CONTINUITY_LOG_FILE"

    pal_log_early() {
        printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
    }

    pal_log_early "info" "Daemon v${CONTINUITY_VERSION} starting (PID $$)"
    pal_log_early "info" "Interpreter: ${CONTINUITY_BB_STATUS:-device sh}"

    # PID guard
    if cd_is_running; then
        pal_log_early "info" "Another instance running, exiting"
        exit 0
    fi
    cd_write_pid

    # Load all modules
    cd_load_modules

    # Try PAL init (may fail if not yet enrolled — that's OK, enrollment
    # only needs the path variables the PAL sets at source time)
    if ! pal_init; then
        if [ -n "$CONTINUITY_REPO_DIR" ]; then
            pal_log "info" "PAL init deferred (not yet enrolled)"
        else
            pal_log "error" "PAL init failed — CONTINUITY_REPO_DIR not set"
            cd_remove_pid
            exit 1
        fi
    fi

    # Enrollment check
    if ! cd_check_enrollment; then
        cd_remove_pid
        exit 1
    fi

    # Full initialization — one path for both already-enrolled and
    # fresh-enrollment boots. Each step is fatal if it fails: a daemon
    # with a half-initialized PAL or no platform map must not sync.
    pal_init || { pal_log "error" "PAL init failed after enrollment"; cd_remove_pid; exit 1; }
    pal_validate || { pal_log "error" "PAL validation failed"; cd_remove_pid; exit 1; }
    se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" || \
        { pal_log "error" "Sync engine init failed"; cd_remove_pid; exit 1; }
    pm_load_platform_map "$(pal_get_platform_map)" || \
        { pal_log "error" "Failed to load platform map"; cd_remove_pid; exit 1; }

    pal_log "info" "Bootstrap complete, enrolled as $CONTINUITY_DEVICE_NAME"

    # Boot dispatch — errors are non-fatal: an offline boot pull must not
    # stop the poll loop from starting (WiFi recovery handles the rest)
    boot_rc=0
    cd_boot_dispatch "$CONTINUITY_REPO_DIR" || boot_rc=$?
    if [ "$boot_rc" -ne 0 ]; then
        pal_log "warn" "Boot dispatch returned $boot_rc — continuing"
    fi

    # Poll loop (blocks until SIGTERM)
    cd_poll_loop
}

# Unit tests source this file with CONTINUITY_DAEMON_NO_MAIN=1 to get the
# functions without running the daemon.
if [ -z "$CONTINUITY_DAEMON_NO_MAIN" ]; then
    cd_main "$@"
fi
