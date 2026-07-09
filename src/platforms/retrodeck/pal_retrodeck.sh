#!/bin/sh
# shellcheck shell=ash  # POSIX sh — parses under busybox ash for the test suite
# shellcheck disable=SC3043,SC2034
# PAL implementation for RetroDeck (Steam Deck, host side).
#
# RetroDeck is a Flatpak, but the daemon runs on the HOST as a
# systemd --user service (Sprint 2.1 decision): the manifest grants
# --filesystem=host, so RetroDeck's content lives at plain host paths
# under rdhome, and the sandbox has no flatpak-spawn host access anyway.
#
# rdhome is USER-RELOCATABLE (SD-card installs), so saves/states/roms
# roots are read from RetroDeck's own live config — never hardcoded.
# Pre-set CONTINUITY_* environment always wins (PAL addendum: test
# sandboxes redirect everything).

# RetroDeck's app-private config, as seen from the host.
CONTINUITY_RD_CONF="${CONTINUITY_RD_CONF:-$HOME/.var/app/net.retrodeck.retrodeck/config/retrodeck/retrodeck.json}"
# Pre-0.10 installs used a shell-var cfg next to today's json.
CONTINUITY_RD_CONF_LEGACY="${CONTINUITY_RD_CONF_LEGACY:-${CONTINUITY_RD_CONF%.json}.cfg}"

# _pal_rd_json_value <key> — "key": "value" out of retrodeck.json
# (host has no guaranteed jq; RetroDeck's own functions do the same).
_pal_rd_json_value() {
    sed -n 's/.*"'"$1"'": *"\([^"]*\)".*/\1/p' "$CONTINUITY_RD_CONF" 2>/dev/null | head -1
}

# _pal_rd_cfg_value <key> — key=value out of the legacy retrodeck.cfg.
_pal_rd_cfg_value() {
    sed -n 's/^'"$1"'="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONTINUITY_RD_CONF_LEGACY" 2>/dev/null | head -1
}

# _pal_rd_path <json_key> <legacy_key> — derive one RetroDeck path,
# preferring the current json config, falling back to the legacy cfg.
_pal_rd_path() {
    if [ -f "$CONTINUITY_RD_CONF" ]; then
        _pal_rd_json_value "$1"
    elif [ -f "$CONTINUITY_RD_CONF_LEGACY" ]; then
        _pal_rd_cfg_value "$2"
    fi
}

CONTINUITY_SAVES_ROOT="${CONTINUITY_SAVES_ROOT:-$(_pal_rd_path saves_path saves_folder)}"
CONTINUITY_STATES_ROOT="${CONTINUITY_STATES_ROOT:-$(_pal_rd_path states_path states_folder)}"
CONTINUITY_ROMS_ROOT="${CONTINUITY_ROMS_ROOT:-$(_pal_rd_path roms_path roms_folder)}"

CONTINUITY_REPO_DIR="${CONTINUITY_REPO_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/continuity/repo}"
CONTINUITY_PLATFORM="retrodeck"
CONTINUITY_GIT_BIN="${CONTINUITY_GIT_BIN:-git}"
# CONTINUITY_DEVICE_NAME is read from enrollment config by pal_init.

# Installed checkout root. Entry points (daemon, enrollment) export it
# from their own location; the default covers sourcing from elsewhere.
CONTINUITY_APP_DIR="${CONTINUITY_APP_DIR:-$HOME/.local/share/continuity/app}"

# pal_init — validate the RetroDeck-derived paths, git, and enrollment.
# Returns 0 on success, 1 if anything is missing (every failure names
# itself — observability rule).
pal_init() {
    if [ -z "$CONTINUITY_SAVES_ROOT" ]; then
        pal_log "error" "RetroDeck config not found (looked for $CONTINUITY_RD_CONF and legacy .cfg) — launch RetroDeck once, then retry"
        return 1
    fi
    if [ ! -d "$CONTINUITY_SAVES_ROOT" ]; then
        pal_log "error" "RetroDeck saves path does not exist: $CONTINUITY_SAVES_ROOT (from $CONTINUITY_RD_CONF)"
        return 1
    fi

    if ! command -v "$CONTINUITY_GIT_BIN" >/dev/null 2>&1; then
        pal_log "error" "git not found ($CONTINUITY_GIT_BIN) — see Sprint 2.1 spec contingency R5"
        return 1
    fi

    local config_file
    config_file="$CONTINUITY_REPO_DIR/.continuity/device_name"
    if [ -f "$config_file" ]; then
        CONTINUITY_DEVICE_NAME=$(cat "$config_file")
    else
        pal_log "error" "No device name found — enrollment incomplete?"
        return 1
    fi
    return 0
}

# pal_is_online — GitHub reachability. ICMP may be filtered on some
# networks, so fall back to an HTTPS probe (curl ships with SteamOS).
# CONTINUITY_FORCE_ONLINE=1 short-circuits (tests, debugging).
pal_is_online() {
    if [ -n "${CONTINUITY_FORCE_ONLINE:-}" ]; then
        return 0
    fi
    ping -c 1 -W 3 github.com >/dev/null 2>&1 ||
    curl -sI -m 5 https://github.com >/dev/null 2>&1
}

# pal_log — stderr only (PAL addendum); systemd/journald owns capture.
pal_log() {
    printf '[%s] %s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >&2
}

# pal_get_platform_map — platform map inside the installed checkout.
pal_get_platform_map() {
    printf '%s\n' "$CONTINUITY_APP_DIR/config/platform_maps/retrodeck.json"
}
