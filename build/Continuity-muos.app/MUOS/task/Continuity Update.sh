#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity — muOS OTA update task ("Continuity Update.sh" in MUOS/task/).
# Tapping this task IS the consent (muOS has no button prompt / show2):
# it fetches the device's channel pin, reports current → fetched
# version, stage-applies the verified app tree, and tells the user the
# change takes effect on the next daemon restart/boot. Failures name
# themselves with the log path; the exit code is honest (0 applied or
# already-current, non-zero on a real failure).
#
# The bootstrap/recovery path stays device-native by design: this script
# NEVER uses the vendored busybox (fail-open invariant — same rule as the
# other task entries). The bundled git IS used (via update.sh) — updates
# ride the same proven git+TLS stack as enrollment.
#
# Test hooks:
#   CONTINUITY_SD_ROOT     — SD1 root (default: probed; /mnt/mmc first —
#                            NEVER derived solely from $0, muOS bind-mount
#                            trap; see muos-field-notes.md)
#   CONTINUITY_MUOS_SD_PRIMARY — primary mount to probe (default /mnt/mmc)
#   CONTINUITY_APP_DIR     — app dir (default: <SD>/.continuity/app)
#   TCU_NO_MAIN=1          — source-only (unit tests call functions)
set -e

# tcu_say — one line to the task console AND the launch log. muOS task
# consoles vary across releases; the log line is the reliable record.
tcu_say() {
    printf '%s\n' "$*"
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$TCU_LOG" 2>/dev/null || true
}

# tcu_resolve_sd_root — the SD card root. Explicit override wins, else the
# first probed mount carrying an app install, else the primary mount.
# $0-derivation is a LAST candidate only: muOS bind-mounts MUOS/task to
# /run/muos/storage/task, so $0/../.. resolves to /run/muos (tmpfs) — a
# breadcrumb there is invisible and gone at reboot (field trap).
tcu_resolve_sd_root() {
    local cand sd
    if [ -n "${CONTINUITY_SD_ROOT:-}" ]; then
        printf '%s\n' "$CONTINUITY_SD_ROOT"
        return 0
    fi
    cand="${CONTINUITY_MUOS_SD_PRIMARY:-/mnt/mmc}
/mnt/sdcard
$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd || true)"
    sd=$(printf '%s\n' "$cand" | while IFS= read -r d; do
        [ -n "$d" ] && [ -d "$d/.continuity/app" ] && { printf '%s\n' "$d"; break; }
    done)
    [ -n "$sd" ] || sd="${CONTINUITY_MUOS_SD_PRIMARY:-/mnt/mmc}"
    printf '%s\n' "$sd"
}

tcu_main() {
    local rc info new_version commit current

    CONTINUITY_SD_ROOT=$(tcu_resolve_sd_root)
    export CONTINUITY_SD_ROOT
    CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$CONTINUITY_SD_ROOT/.continuity/app}"
    export CONTINUITY_APP_DIR

    # Unconditional breadcrumb — a failed launch must never be invisible
    # (the diagnostics rule that carries across every platform). Record
    # $0 so the field tells us where muOS runs update taps from.
    mkdir -p "$CONTINUITY_SD_ROOT/.continuity" 2>/dev/null || true
    TCU_LOG="$CONTINUITY_SD_ROOT/.continuity/launch.log"
    printf '[%s] update task: $0=%s sd=%s app=%s version=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$0" "$CONTINUITY_SD_ROOT" \
        "$CONTINUITY_APP_DIR" \
        "$(cat "$CONTINUITY_APP_DIR/version.txt" 2>/dev/null || printf 'unknown')" \
        >> "$TCU_LOG" 2>/dev/null || true

    if [ ! -f "$CONTINUITY_APP_DIR/scripts/update.sh" ]; then
        tcu_say "Continuity not installed at $CONTINUITY_APP_DIR — copy the app folder to the card first"
        exit 1
    fi

    # Bring in the OTA machinery (ota_* functions read the same
    # CONTINUITY_* env we just exported).
    # shellcheck disable=SC1090
    . "$CONTINUITY_APP_DIR/scripts/update.sh"

    if ota_disabled; then
        tcu_say "OTA is disabled (CONTINUITY_OTA=0) — nothing to do."
        exit 0
    fi

    current=$(ota_current_version)
    tcu_say "Continuity Update — current version: $current"
    tcu_say "Checking channel '$(ota_channel)' for a newer build..."

    rc=0
    info=$(ota_check) || rc=$?
    if [ "$rc" -ne 0 ]; then
        # ota_check returns 1 both for "already current" and for a hold
        # (unreachable manifest / unknown channel). The log carries the
        # exact reason.
        tcu_say "No update applied — already current or unavailable. See .continuity/update.log"
        exit 0
    fi

    new_version="${info%% *}"
    commit="${info##* }"
    tcu_say "Update available: $current -> $new_version"
    tcu_say "Applying (verified staged copy)..."

    rc=0
    ota_apply "$commit" || rc=$?
    if [ "$rc" -ne 0 ]; then
        tcu_say "Update FAILED (rc $rc) — the live install was left untouched. See .continuity/update.log"
        exit 1
    fi

    tcu_say "Updated to $new_version. Restart the daemon or reboot for it to take effect."
    exit 0
}

if [ -z "${TCU_NO_MAIN:-}" ]; then
    tcu_main "$@"
fi
