#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# Continuity — muOS user-init boot hook (ships as MUOS/init/continuity.sh).
# muOS runs MUOS/init/*.sh during boot when "User Init Scripts" is
# enabled (Configuration > General Settings > Advanced Settings) — the
# officially documented user startup mechanism (muxtweakadv module).
#
# Rules of this file:
# - Boot must never block on us: start the daemon detached, return
#   immediately. No liveness wait here (the Task Toolkit entry does the
#   verified start when a human is watching; the daemon logs its own).
# - Device-native shell only — the bootstrap path never depends on the
#   vendored interpreter (fail-open invariant).
# - setsid: muOS kills a spawner's process group when it exits (the
#   Task Toolkit field failure) — assume boot scripts get the same
#   treatment and detach into our own session.
#
# Test hooks: CONTINUITY_SD_ROOT, CONTINUITY_APP_DIR, CONTINUITY_PID_FILE.
set -e

SD="${CONTINUITY_SD_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
APP="${CONTINUITY_APP_DIR:-$SD/.continuity/app}"
PIDF="${CONTINUITY_PID_FILE:-/tmp/continuity.pid}"

mkdir -p "$SD/.continuity" 2>/dev/null || true
printf '[%s] boot init hook, app=%s version=%s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$APP" \
    "$(cat "$APP/version.txt" 2>/dev/null || printf 'unknown')" \
    >> "$SD/.continuity/launch.log" 2>/dev/null || true

# Not installed (or half-copied) — a boot hook must fail silent, the
# breadcrumb above is the record.
[ -f "$APP/scripts/continuity_daemon.sh" ] || exit 0

# Already running (daemon PID check, same semantics as the daemon's own
# guard) — nothing to do.
pid=$(cat "$PIDF" 2>/dev/null || true)
case "$pid" in
    ''|*[!0-9]*) ;;
    *)
        if kill -0 "$pid" 2>/dev/null; then
            exit 0
        fi
        ;;
esac

if command -v setsid >/dev/null 2>&1; then
    setsid sh "$APP/scripts/continuity_daemon.sh" </dev/null >/dev/null 2>&1 &
else
    sh "$APP/scripts/continuity_daemon.sh" </dev/null >/dev/null 2>&1 &
fi
exit 0
