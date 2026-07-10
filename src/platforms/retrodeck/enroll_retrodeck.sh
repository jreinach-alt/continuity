#!/bin/sh
# shellcheck shell=ash  # POSIX sh — parses under busybox ash for the test suite
# shellcheck disable=SC3043
# RetroDeck desktop CLI enrollment — Steam Deck (desktop mode, Konsole).
#
# Usage:
#   enroll_retrodeck.sh --repo-url <https-url> [--device-name <name>]
#                       [--pat-file <file>] [--no-service]
#
# The PAT is read from --pat-file or a hidden interactive prompt —
# NEVER from argv (visible in `ps` to every process on the host).
# After core enrollment succeeds, installs and enables the
# systemd --user unit so the daemon starts on every login.
# (Plain set -e: the sourced core modules are not `set -u`-clean.)
set -e

usage() {
    cat <<'EOF'
Continuity enrollment for RetroDeck (Steam Deck)

  --repo-url <url>      HTTPS URL of your private saves repo (required)
  --device-name <name>  lowercase letters/digits/hyphens, max 32
                        (default: steam-deck)
  --pat-file <file>     read the GitHub PAT from this file instead of
                        prompting (the file is not deleted)
  --no-service          enroll only; skip systemd unit install/enable
  --help                this text
EOF
}

repo_url=""
device_name="steam-deck"
pat_file=""
install_service=1

while [ $# -gt 0 ]; do
    case "$1" in
        --repo-url)    repo_url="${2:?--repo-url needs a value}"; shift 2 ;;
        --device-name) device_name="${2:?--device-name needs a value}"; shift 2 ;;
        --pat-file)    pat_file="${2:?--pat-file needs a value}"; shift 2 ;;
        --no-service)  install_service=0; shift ;;
        --help|-h)     usage; exit 0 ;;
        --pat)
            printf 'Error: --pat is not supported (a PAT on the command line leaks via ps). Use --pat-file or the prompt.\n' >&2
            exit 1
            ;;
        *)
            printf 'Error: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$repo_url" ]; then
    printf 'Error: --repo-url is required.\n' >&2
    usage >&2
    exit 1
fi

# Installed checkout root: this script lives at
# <app>/src/platforms/retrodeck/enroll_retrodeck.sh
CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
export CONTINUITY_APP_DIR

# shellcheck source=src/platforms/retrodeck/pal_retrodeck.sh
. "$CONTINUITY_APP_DIR/src/platforms/retrodeck/pal_retrodeck.sh"
# shellcheck source=src/core/pal.sh
. "$CONTINUITY_APP_DIR/src/core/pal.sh"
# shellcheck source=src/core/sync_engine.sh
. "$CONTINUITY_APP_DIR/src/core/sync_engine.sh"
# shellcheck source=src/core/enrollment.sh
. "$CONTINUITY_APP_DIR/src/core/enrollment.sh"

# Preflight: name every blocker before asking for a secret.
if [ -z "$CONTINUITY_SAVES_ROOT" ]; then
    pal_log "error" "RetroDeck config not found (looked for $CONTINUITY_RD_CONF) — launch RetroDeck once, then retry"
    exit 1
fi
if [ ! -d "$CONTINUITY_SAVES_ROOT" ]; then
    pal_log "error" "RetroDeck saves path does not exist: $CONTINUITY_SAVES_ROOT"
    exit 1
fi
if ! command -v "$CONTINUITY_GIT_BIN" >/dev/null 2>&1; then
    pal_log "error" "git not found on the host — see Sprint 2.1 spec contingency R5"
    exit 1
fi
if ! _enroll_validate_device_name "$device_name"; then
    exit 1
fi

if enroll_is_enrolled; then
    pal_log "info" "Already enrolled as $(cat "$CONTINUITY_REPO_DIR/.continuity/device_name") — nothing to do"
    exit 0
fi

# PAT: file, or hidden prompt (tolerate no-tty by falling back to a
# plain read so piped input still works).
pat=""
if [ -n "$pat_file" ]; then
    if [ ! -f "$pat_file" ]; then
        pal_log "error" "PAT file not found: $pat_file"
        exit 1
    fi
    pat=$(cat "$pat_file")
else
    printf 'GitHub PAT (input hidden): ' >&2
    if stty -echo 2>/dev/null; then
        read -r pat
        stty echo 2>/dev/null || true
        printf '\n' >&2
    else
        read -r pat
    fi
fi
if [ -z "$pat" ]; then
    pal_log "error" "Empty PAT"
    exit 1
fi

# Headless-git safety (PAL addendum): never block on a tty credential
# prompt; abort transfers stalled under 1 KB/s for 30s.
GIT_TERMINAL_PROMPT=0
GIT_HTTP_LOW_SPEED_LIMIT=1000
GIT_HTTP_LOW_SPEED_TIME=30
export GIT_TERMINAL_PROMPT GIT_HTTP_LOW_SPEED_LIMIT GIT_HTTP_LOW_SPEED_TIME

# A crash mid-clone leaves a repo dir git refuses to reuse; pre-enrollment
# it holds nothing of value (the remote is the source of truth).
if [ -d "$CONTINUITY_REPO_DIR" ]; then
    pal_log "warn" "Removing stale partial clone at $CONTINUITY_REPO_DIR"
    rm -rf "$CONTINUITY_REPO_DIR"
fi
mkdir -p "$(dirname "$CONTINUITY_REPO_DIR")"

if ! enroll_run "$repo_url" "$device_name" "$pat"; then
    pal_log "error" "Enrollment failed — see messages above"
    exit 1
fi
pat=""

app_dir_escaped=$(printf '%s' "$CONTINUITY_APP_DIR" | sed 's/[&|\\]/\\&/g')

# systemd --user unit: template the checkout path into the committed
# unit and enable it. Failure here is a WARNING — the device is
# enrolled; the service can be enabled by hand later.
if [ "$install_service" -eq 1 ]; then
    sysctl_bin="${CONTINUITY_SYSTEMCTL:-systemctl}"
    unit_src="$CONTINUITY_APP_DIR/src/platforms/retrodeck/continuity.service"
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    unit_dst="$unit_dir/continuity.service"

    if [ ! -f "$unit_src" ]; then
        pal_log "warn" "Unit template missing: $unit_src — skipping service install"
    else
        mkdir -p "$unit_dir"
        sed "s|@APP_DIR@|$app_dir_escaped|g" "$unit_src" > "$unit_dst"
        if command -v "$sysctl_bin" >/dev/null 2>&1 \
            && "$sysctl_bin" --user daemon-reload \
            && "$sysctl_bin" --user enable --now continuity.service; then
            pal_log "info" "Daemon service installed and started (systemctl --user status continuity)"
        else
            pal_log "warn" "Could not enable the service — run: systemctl --user enable --now continuity.service"
        fi
    fi
fi

# Desktop launcher for the conflict resolver (Sprint 2.2) — same
# best-effort contract as the unit install: failure is a warning, never
# a rollback (resolve_conflicts.sh still runs from a terminal). Not
# gated on --no-service: the launcher is UI, not the daemon.
desktop_src="$CONTINUITY_APP_DIR/src/platforms/retrodeck/continuity-resolve.desktop"
desktop_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
if [ ! -f "$desktop_src" ]; then
    pal_log "warn" "Launcher template missing: $desktop_src — run resolve_conflicts.sh directly"
elif mkdir -p "$desktop_dir" && \
     sed "s|@APP_DIR@|$app_dir_escaped|g" "$desktop_src" > "$desktop_dir/continuity-resolve.desktop"; then
    pal_log "info" "Installed the 'Continuity — Resolve save conflicts' launcher"
else
    pal_log "warn" "Could not install the resolver launcher — run resolve_conflicts.sh directly"
fi

pal_log "info" "Enrolled as $device_name. Saves under $CONTINUITY_SAVES_ROOT will sync to your repo."
exit 0
