#!/bin/sh
# Continuity Tool PAK — launch.sh
#
# State-driven entry point for the Continuity tool:
#   - always: ensure the daemon boot hook is installed in auto.sh
#   - not enrolled + setup.json present: run supervised enrollment
#     (B cancels, X/Y replays the log on screen)
#   - not enrolled, no setup.json: tell the user what to stage
#   - enrolled: honest status — is the daemon actually running, last
#     sync line if any, last error if it died
#
# Set CONTINUITY_DEBUG=1 in the calling environment to capture an xtrace
# log to ./launch_debug.log inside the PAK directory.
#
# CONTINUITY_HOME, CONTINUITY_SD_ROOT, and CONTINUITY_PID_FILE are
# overridable for off-device testing; on the device they default to the
# SD card / tmpfs paths.

cd "$(dirname "$0")" || exit 1

# Build stamp: which PAK build is actually executing. Ends the "which
# version is on the card?" ambiguity — it appears in every breadcrumb
# line and on the problem-state screens.
PAK_VERSION=$(cat ./version.txt 2>/dev/null)
PAK_VERSION="${PAK_VERSION:-unknown}"

# One-line breadcrumb on every launch, before anything can fail — a launch
# that produces no visible output must never be invisible in the logs too.
printf '%s launch.sh started (build %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PAK_VERSION" >> ./launch.log

if [ -n "$CONTINUITY_DEBUG" ]; then
    exec 2>>./launch_debug.log
    set -x
fi

LOGO="/mnt/SDCARD/.system/res/logo.png"
SD_ROOT="${CONTINUITY_SD_ROOT:-/mnt/SDCARD}"
CONTINUITY_HOME="${CONTINUITY_HOME:-/mnt/SDCARD/.continuity}"
HOOK_MARKER="$CONTINUITY_HOME/.hook_installed"
FIFO="${CONTINUITY_SHOW2_FIFO:-/tmp/show2.fifo}"
SHOW_PID=""

# ── show2.elf helpers ───────────────────────────────────────────────
# show2.elf lives on $PATH (NextUI exports $SYSTEM_PATH/bin via PATH),
# so we invoke it unqualified — portable across tg5040 and tg5050.

# show_simple — display a static message for $2 seconds, then return.
show_simple() {
    show2.elf --mode=simple --image="$LOGO" --bgcolor=0x000000 \
        --text="$1" --fontsize=28 --timeout="$2"
}

# show_daemon_start — start show2 in daemon mode in the background.
# Sets $SHOW_PID. Caller must invoke show_daemon_stop before exit.
show_daemon_start() {
    show2.elf --mode=daemon --image="$LOGO" --bgcolor=0x000000 \
        --text="$1" --fontsize=28 &
    SHOW_PID=$!
    # Brief pause so show2 has time to mkfifo before we write to it.
    sleep 1
}

# show_daemon_text — push a new text line into the running daemon.
# Append is identical to a plain write on a real FIFO, and preserves the
# full message sequence when tests capture to a regular file.
show_daemon_text() {
    [ -p "$FIFO" ] || [ -f "$FIFO" ] || return 0
    printf 'TEXT:%s\n' "$1" >> "$FIFO"
}

# show_daemon_stop — gracefully tear down the daemon and wait for exit.
show_daemon_stop() {
    [ -n "$SHOW_PID" ] || return 0
    if [ -p "$FIFO" ] || [ -f "$FIFO" ]; then
        printf 'QUIT\n' >> "$FIFO"
    fi
    wait "$SHOW_PID" 2>/dev/null
    SHOW_PID=""
}

# ── Module loading (needed for enrollment state + actions) ──────────

CONTINUITY_PAK_DIR="$(pwd)"
export CONTINUITY_PAK_DIR

# check_module — exists and has clean (LF) line endings. CRLF makes ash
# parse garbage and surfaces only as a cryptic ": not found" — the exact
# on-device failure this guard converts into a visible, named error.
cr=$(printf '\r')
check_module() {
    if [ ! -f "./$1" ]; then
        show_simple "Continuity install corrupt: missing $1" 5
        exit 1
    fi
    if grep -q "$cr" "./$1" 2>/dev/null; then
        show_simple "Corrupt line endings in $1 — re-copy the PAK" 6
        exit 1
    fi
}

for f in scripts/pal_nextui.sh scripts/core/pal.sh scripts/core/enrollment.sh; do
    check_module "$f"
done
. ./scripts/pal_nextui.sh
. ./scripts/core/pal.sh
. ./scripts/core/enrollment.sh

# ── Boot hook install (idempotent, every launch) ────────────────────
# The daemon is fully detached from the boot shell's stdio: it manages
# its own log file, and a daemon holding the boot console open is the
# kind of thing that hangs a boot sequence.

USERDATA_PATH="${USERDATA_PATH:-/mnt/SDCARD/.userdata/tg5040}"
AUTO_SH="$USERDATA_PATH/auto.sh"

if ! grep -qF "continuity_daemon.sh" "$AUTO_SH" 2>/dev/null; then
    mkdir -p "$USERDATA_PATH" "$CONTINUITY_HOME"
    hook_line="\"$CONTINUITY_PAK_DIR/scripts/continuity_daemon.sh\" </dev/null >/dev/null 2>&1 &"
    if [ -f "$AUTO_SH" ]; then
        printf '\n# Continuity save sync daemon\n%s\n' "$hook_line" >> "$AUTO_SH"
    else
        printf '#!/bin/sh\n# Continuity save sync daemon\n%s\n' "$hook_line" > "$AUTO_SH"
        chmod +x "$AUTO_SH"
    fi
    touch "$HOOK_MARKER"
fi

# ── Not enrolled: enroll now (if possible) ──────────────────────────

if ! enroll_is_enrolled; then
    if [ -f "$SD_ROOT/setup.json" ]; then
        # Full module set for enrollment, presence- and CRLF-checked first.
        for f in scripts/core/path_mapper.sh scripts/core/sync_engine.sh \
                 scripts/enroll_sd_card.sh scripts/enroll_ui.sh \
                 scripts/preflight.sh; do
            check_module "$f"
        done
        . ./scripts/core/path_mapper.sh
        . ./scripts/core/sync_engine.sh
        . ./scripts/enroll_sd_card.sh
        . ./scripts/enroll_ui.sh
        . ./scripts/preflight.sh

        mkdir -p "$CONTINUITY_HOME"
        ENROLL_LOG="$CONTINUITY_HOME/enroll.log"
        DIAG_FILE="$SD_ROOT/CONTINUITY_DIAGNOSTIC.txt"

        # Preflight doctor: every environment fact in one pass, written
        # to a visible report at the SD root, so a failed attempt never
        # costs more than one card round-trip of information.
        show_daemon_start "Preflight checks (device, git, network)..."
        pf_rc=0
        pf_run "$DIAG_FILE" || pf_rc=$?
        cat "$DIAG_FILE" >> "$ENROLL_LOG" 2>/dev/null

        if [ "$pf_rc" -ne 0 ]; then
            show_daemon_text "$(printf '%s' "${_pf_first_fail:-preflight failed}" | cut -c1-64)"
            sleep 6
            show_daemon_text "Full report: SD card/CONTINUITY_DIAGNOSTIC.txt"
            sleep 4
            show_daemon_stop
            exit 0
        fi

        show_daemon_text "Enrolling device...  (B cancels, X/Y shows log)"

        # Supervised enrollment: live log line on screen, B cancels,
        # X/Y replays the log, watchdog kills a stuck run. Everything is
        # logged to .continuity/enroll.log regardless of outcome.
        rc=0
        eui_run_enrollment "$ENROLL_LOG" || rc=$?

        case "$rc" in
            0)  show_daemon_text "Enrolled! Reboot to start syncing." ;;
            2)  show_daemon_text "Enrollment cancelled. Launch again to retry." ;;
            3)  show_daemon_text "Enrollment timed out. Log: SD/.continuity/enroll.log" ;;
            *)  last_err=$(grep -i "error" "$ENROLL_LOG" 2>/dev/null | tail -1 | cut -c1-64)
                show_daemon_text "${last_err:-Enrollment failed.}"
                sleep 4
                show_daemon_text "Full log: SD card/.continuity/enroll.log" ;;
        esac

        sleep 3
        show_daemon_stop
    else
        show_simple "Not enrolled (build $PAK_VERSION). Put setup.json on SD root, relaunch." 4
    fi

    exit 0
fi

# ── Enrolled: honest daemon status ──────────────────────────────────

PID_FILE="${CONTINUITY_PID_FILE:-/tmp/continuity.pid}"
LOG_FILE="$CONTINUITY_HOME/continuity.log"

daemon_alive=""
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    case "$pid" in
        ''|*[!0-9]*) ;;
        *) kill -0 "$pid" 2>/dev/null && daemon_alive="yes" ;;
    esac
fi

if [ -n "$daemon_alive" ]; then
    last_sync=$(grep -E "(Sync complete|Push complete|Pull complete|Enrollment complete)" \
                     "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/^\[[^]]*\] //' | cut -c1-64)
    show_simple "${last_sync:-Daemon running — no syncs yet.}" 3
else
    show_simple "Daemon NOT running (build $PAK_VERSION). Reboot to start it." 3
    last_err=$(grep -i "error" "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/^\[[^]]*\] //' | cut -c1-64)
    if [ -n "$last_err" ]; then
        show_simple "Last error: $last_err" 4
    fi
fi

# ── Scan self-test ───────────────────────────────────────────────────
# What does THIS device's userland actually see? Settles "the file is
# right there but nothing syncs" in one tap: counts on screen, full
# paths in a visible report at the SD root.

check_module "scripts/core/path_mapper.sh"
check_module "scripts/core/change_detector.sh"
. ./scripts/core/path_mapper.sh
. ./scripts/core/change_detector.sh
pm_load_platform_map "$(pal_get_platform_map)" >/dev/null 2>&1
scan_watched=$(pm_list_watched_dirs 2>/dev/null | grep -c .)
scan_found=$(cd_list_device_saves 2>/dev/null | grep -c .)
scan_states=$(cd_list_device_states 2>/dev/null | grep -c .)
scan_raw=$(find "${CONTINUITY_SAVES_ROOT:-/mnt/SDCARD/Saves}" \
    \( -name "*.srm" -o -name "*.sav" \) 2>/dev/null | grep -c .)
{
    printf '=== Continuity scan report %s (build %s) ===\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$PAK_VERSION"
    printf -- '--- watched dirs (%s) ---\n' "$scan_watched"
    pm_list_watched_dirs 2>/dev/null
    printf -- '--- saves seen by scanner (%s; raw find: %s) ---\n' "$scan_found" "$scan_raw"
    cd_list_device_saves 2>/dev/null
    printf -- '--- states seen by scanner (%s) ---\n' "$scan_states"
    cd_list_device_states 2>/dev/null
} > "$SD_ROOT/CONTINUITY_SCAN_REPORT.txt" 2>&1
sync
show_simple "Scan: $scan_watched dirs, $scan_found saves (raw $scan_raw), $scan_states states" 4

# ── OTA update check (X installs, B/timeout skips) ──────────────────
# Card swaps are for binaries and emergencies only: every script fix
# flows through here, over the same git+TLS stack enrollment proved.
# CONTINUITY_OTA=0 disables.

if [ "$CONTINUITY_OTA" != "0" ]; then
    check_module "scripts/update.sh"
    check_module "scripts/enroll_ui.sh"
    . ./scripts/update.sh
    . ./scripts/enroll_ui.sh

    show_daemon_start "Checking for updates (build $PAK_VERSION)..."
    ota_rc=0
    ota_info=$(ota_check 2>/dev/null) || ota_rc=$?
    if [ "$ota_rc" -eq 0 ] && [ -n "$ota_info" ]; then
        ota_ver="${ota_info% *}"
        ota_commit="${ota_info##* }"
        show_daemon_text "Update available: $ota_ver — X installs, B skips"
        if btn=$(eui_prompt_button 40 "$EUI_BTN_X" "$EUI_BTN_B") && [ "$btn" = "$EUI_BTN_X" ]; then
            show_daemon_text "Updating... (do not power off)"
            if ota_apply "$ota_commit"; then
                show_daemon_text "Updated to $(cat ./version.txt 2>/dev/null). Reboot when ready."
            else
                show_daemon_text "Update failed — see .continuity/update.log"
            fi
            sleep 4
        fi
    else
        show_daemon_text "Up to date ($PAK_VERSION)"
        sleep 2
    fi
    show_daemon_stop
fi
