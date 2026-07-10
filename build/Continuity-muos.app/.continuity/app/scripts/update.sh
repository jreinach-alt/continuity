#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity muOS OTA update — sync the muOS app tree from the project
# repo using the app's own bundled git. No curl, no tarballs, no system
# tools beyond BusyBox: the update mechanism is the same proven git+TLS
# stack that enrollment uses.
#
# Design (mirrors the Brick's src/platforms/nextui/update.sh, adapted
# to the muOS card-mirroring layout):
#   - A persistent sparse clone lives at $CONTINUITY_HOME/ota-repo,
#     sparse-checked-out to just build/Continuity-muos.app (with a
#     partial clone filter when the server supports it), so update
#     checks and downloads are incremental — unchanged binaries are
#     never refetched.
#   - CHANNELS ARE DATA ON MAIN, NOT BRANCHES: the device holds a
#     durable channel name (stable/nightly) in
#     $CONTINUITY_HOME/ota_channel (seeded once from the build's
#     ota_channel.txt, never overwritten by installs). Each check
#     fetches main, reads release/channels.json (git show — no
#     checkout), and fetches the channel's pinned commit for the app
#     tree. Publishing/promotion/rollback are manifest commits on main
#     (scripts/publish_channel.sh). One pinned commit serves BOTH the
#     NextUI PAK and this muOS app — a publish updates the whole fleet.
#   - NO LEGACY BRANCH FALLBACK. NextUI's exists only to migrate devices
#     deployed before the manifest existed; no such muOS devices exist,
#     so an unreachable/missing manifest simply holds the device.
#   - Apply is staged: fetch → verify the fetched tree (CRLF scan +
#     checksums.txt) → copy over the live install → sync. Verification
#     runs on the fully materialized clone BEFORE any copy touches the
#     live tree, so a torn or corrupt fetch cannot half-replace the tree
#     the updater is running from. The daemon reads its scripts at boot,
#     so replacing files mid-run takes effect on the next reboot.
#
# The committed artifact build/Continuity-muos.app/ mirrors the SD card
# root: .continuity/app/** (scripts, binaries, config, manifests) plus
# MUOS/task/*.sh and MUOS/init/*.sh. Apply fans those back out to their
# live card locations.
#
# Functions are ota_-prefixed and individually testable; overridables:
#   CONTINUITY_OTA_URL   — repo URL (default: the public project repo)
#   CONTINUITY_OTA_BRANCH— channel override (default: device file, then
#                          the build's ota_channel.txt)
#   CONTINUITY_SD_ROOT   — SD card root (default: /mnt/mmc)
#   CONTINUITY_APP_DIR   — live app dir (default: <SD>/.continuity/app)
#   CONTINUITY_HOME      — state root (default: <SD>/.continuity)
#   CONTINUITY_OTA=0     — kill switch (disables all OTA activity)

OTA_SD_ROOT="${CONTINUITY_SD_ROOT:-/mnt/mmc}"
OTA_APP_DIR="${CONTINUITY_APP_DIR:-$OTA_SD_ROOT/.continuity/app}"
OTA_HOME="${CONTINUITY_HOME:-$OTA_SD_ROOT/.continuity}"
OTA_REPO="$OTA_HOME/ota-repo"
OTA_LOG="$OTA_HOME/update.log"
OTA_URL="${CONTINUITY_OTA_URL:-https://github.com/jreinach-alt/continuity}"
OTA_GIT="${CONTINUITY_GIT_BIN:-$OTA_APP_DIR/bin/git}"
# The tracked artifact path (sparse-checkout target and fetch subtree).
OTA_ARTIFACT="build/Continuity-muos.app"

ota_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$OTA_LOG" 2>/dev/null
}

# ota_disabled — the CONTINUITY_OTA=0 kill switch. Returns 0 (disabled)
# with a named log line, 1 (enabled) otherwise. Every entry point calls
# it so "disables everything" is honest.
ota_disabled() {
    if [ "${CONTINUITY_OTA:-1}" = "0" ]; then
        ota_log "OTA disabled via CONTINUITY_OTA=0"
        return 0
    fi
    return 1
}

# ota_channel — the device's durable channel identity.
# Precedence: env override → device-side file → build seed → stable.
# The device file is written ONCE (seeded from the build that first
# runs this code) and only changed deliberately via ota_set_channel —
# installing a build from another channel must not move the device.
ota_channel() {
    if [ -n "${CONTINUITY_OTA_BRANCH:-}" ]; then
        printf '%s\n' "$CONTINUITY_OTA_BRANCH"
        return 0
    fi
    if [ ! -s "$OTA_HOME/ota_channel" ] && [ -s "$OTA_APP_DIR/ota_channel.txt" ]; then
        mkdir -p "$OTA_HOME"
        cp "$OTA_APP_DIR/ota_channel.txt" "$OTA_HOME/ota_channel" 2>/dev/null || true
    fi
    if [ -s "$OTA_HOME/ota_channel" ]; then
        cat "$OTA_HOME/ota_channel"
    else
        printf 'stable\n'
    fi
}

# ota_set_channel — deliberately switch this device's channel
ota_set_channel() {
    [ -n "$1" ] || return 1
    mkdir -p "$OTA_HOME"
    printf '%s\n' "$1" > "$OTA_HOME/ota_channel"
    ota_log "Channel set to $1"
    return 0
}

# ota_current_version — the live installed muOS app version (or unknown)
ota_current_version() {
    local v
    v=$(cat "$OTA_APP_DIR/version.txt" 2>/dev/null)
    printf '%s\n' "${v:-unknown}"
}

# ota_git — run the bundled git with hang-proof transport settings
ota_git() {
    GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60 \
        "$OTA_GIT" "$@"
}

# ota_ensure_repo — create or reuse the persistent sparse OTA clone.
# Cloned from the remote's default branch — the channel is NOT a branch
# and every check fetches explicit refs anyway.
# Returns: 0 ready, 1 failure (logged)
ota_ensure_repo() {
    mkdir -p "$OTA_HOME"

    if [ -d "$OTA_REPO/.git" ]; then
        return 0
    fi

    ota_log "Setting up OTA clone"
    rm -rf "$OTA_REPO"
    mkdir -p "$OTA_REPO"

    # Partial clone keeps the first setup small (only the app's blobs are
    # fetched at checkout). Some servers (and file:// test remotes without
    # uploadpack.allowFilter) reject filters — fall back to a plain
    # shallow clone.
    if ! ota_git clone --depth 1 --no-checkout \
            --filter=blob:none "$OTA_URL" "$OTA_REPO" >>"$OTA_LOG" 2>&1; then
        ota_log "Filtered clone refused — falling back to plain shallow clone"
        rm -rf "$OTA_REPO"
        if ! ota_git clone --depth 1 --no-checkout \
                "$OTA_URL" "$OTA_REPO" >>"$OTA_LOG" 2>&1; then
            ota_log "ERROR: OTA clone failed"
            rm -rf "$OTA_REPO"
            return 1
        fi
    fi

    if ! ota_git -C "$OTA_REPO" sparse-checkout set "$OTA_ARTIFACT" >>"$OTA_LOG" 2>&1; then
        ota_log "ERROR: sparse-checkout failed"
        rm -rf "$OTA_REPO"
        return 1
    fi
    return 0
}

# ota_check — resolve the device's channel and print
# "<new_version> <commit>", returning 0 when an update is available,
# 1 when up to date / unavailable.
#
# Manifest-only (no legacy branch fallback): fetch main, read
# release/channels.json via git show (no checkout), follow the channel's
# pinned commit. Unpublished commits on main are invisible — the pin is
# the sole source of truth. An unreachable manifest or a channel absent
# from it holds the device.
ota_check() {
    local channel manifest m_commit cur_commit new_version
    ota_disabled && return 1
    channel=$(ota_channel)

    ota_ensure_repo || return 1

    manifest=""
    if ota_git -C "$OTA_REPO" fetch --depth 1 origin main >>"$OTA_LOG" 2>&1; then
        manifest=$(ota_git -C "$OTA_REPO" show FETCH_HEAD:release/channels.json 2>>"$OTA_LOG") || manifest=""
    fi
    if [ -z "$manifest" ]; then
        ota_log "ERROR: release manifest unavailable — holding (no legacy fallback on muOS)"
        return 1
    fi

    m_commit=$(printf '%s\n' "$manifest" | sed -n \
        's/.*"'"$channel"'": *{ *"commit": *"\([0-9a-f]\{40\}\)".*/\1/p' | head -1)
    if [ -z "$m_commit" ]; then
        ota_log "ERROR: channel '$channel' not in manifest — holding"
        return 1
    fi

    cur_commit=$(cat "$OTA_HOME/.ota_commit" 2>/dev/null)
    if [ "$m_commit" = "$cur_commit" ]; then
        ota_log "Up to date at $m_commit"
        return 1
    fi

    # Materialize the pinned tree (fetch the pinned commit if the local
    # object store doesn't have it yet — GitHub serves reachable SHAs).
    if ! ota_git -C "$OTA_REPO" checkout -f "$m_commit" >>"$OTA_LOG" 2>&1; then
        if ! ota_git -C "$OTA_REPO" fetch --depth 1 origin "$m_commit" >>"$OTA_LOG" 2>&1; then
            ota_log "ERROR: cannot fetch pinned commit $m_commit"
            return 1
        fi
        ota_git -C "$OTA_REPO" checkout -f "$m_commit" >>"$OTA_LOG" 2>&1 || return 1
    fi

    new_version=$(cat "$OTA_REPO/$OTA_ARTIFACT/.continuity/app/version.txt" 2>/dev/null)
    new_version="${new_version:-unknown}"

    ota_log "Update available: $new_version ($m_commit)"
    printf '%s %s\n' "$new_version" "$m_commit"
    return 0
}

# ota_verify_tree — sanity-check a fetched app tree before applying.
# CRLF scan on shipped scripts + checksum manifest verification of
# binaries. Takes the artifact tree root ($OTA_REPO/build/Continuity-muos.app).
ota_verify_tree() {
    local tree app cr bad sum size path actual
    tree="$1"
    app="$tree/.continuity/app"
    cr=$(printf '\r')

    [ -f "$app/scripts/continuity_daemon.sh" ] || {
        ota_log "ERROR: fetched tree has no daemon script"; return 1; }

    # CRLF scan over the shipped shell scripts only (app scripts + the
    # MUOS task/init entries) — never the binaries under app/bin etc.,
    # whose bytes legitimately contain CR.
    bad=$(grep -rl "$cr" "$app/scripts" "$tree/MUOS" 2>/dev/null | head -1)
    if [ -n "$bad" ]; then
        ota_log "ERROR: fetched tree has CRLF corruption: $bad"
        return 1
    fi

    if [ -f "$app/checksums.txt" ]; then
        while IFS=' ' read -r sum size path; do
            [ -n "$path" ] || continue
            actual=$(cat "$app/$path" 2>/dev/null | wc -c)
            if [ "$actual" != "$size" ]; then
                ota_log "ERROR: fetched $path size $actual != $size"
                return 1
            fi
            if command -v sha256sum >/dev/null 2>&1; then
                if [ "$(sha256sum "$app/$path" 2>/dev/null | cut -d' ' -f1)" != "$sum" ]; then
                    ota_log "ERROR: fetched $path checksum mismatch"
                    return 1
                fi
            fi
        done < "$app/checksums.txt"
    fi
    return 0
}

# ota_apply — copy the verified fetched app tree over the live install.
# The daemon picks up changes on next boot/restart. Returns 0 on success.
#
# Staged: ota_verify_tree runs on the fully materialized clone FIRST, so
# a verification failure returns before any copy touches the live tree.
ota_apply() {
    local commit tree app new_version b
    commit="$1"
    tree="$OTA_REPO/$OTA_ARTIFACT"
    app="$tree/.continuity/app"

    ota_disabled && return 1
    ota_verify_tree "$tree" || return 1

    ota_log "Applying update $commit"

    mkdir -p "$OTA_APP_DIR/scripts/core" "$OTA_APP_DIR/config/platform_maps" \
             "$OTA_APP_DIR/share/templates" "$OTA_APP_DIR/libexec/git-core" \
             "$OTA_APP_DIR/bin" "$OTA_SD_ROOT/MUOS/task" "$OTA_SD_ROOT/MUOS/init"

    # Scripts, config, manifests first; binaries after (largest last so
    # an interrupted copy is most likely to leave scripts consistent —
    # and preflight's checksum verification catches a torn binary).
    cp "$app"/scripts/*.sh "$OTA_APP_DIR/scripts/" || return 1
    cp "$app"/scripts/core/*.sh "$OTA_APP_DIR/scripts/core/" || return 1
    cp "$app"/config/platform_maps/*.json "$OTA_APP_DIR/config/platform_maps/" 2>/dev/null
    cp "$app/config/system_taxonomy.json" "$OTA_APP_DIR/config/" 2>/dev/null
    cp "$app/version.txt" "$OTA_APP_DIR/version.txt" 2>/dev/null
    cp "$app/checksums.txt" "$OTA_APP_DIR/checksums.txt" 2>/dev/null
    cp "$app/ota_channel.txt" "$OTA_APP_DIR/ota_channel.txt" 2>/dev/null

    # Task Toolkit entries and boot hook live OUTSIDE the app dir, at the
    # card root — fan them back out (filenames contain spaces; glob
    # results are not field-split in POSIX sh, so this is safe).
    cp "$tree"/MUOS/task/*.sh "$OTA_SD_ROOT/MUOS/task/" || return 1
    cp "$tree"/MUOS/init/*.sh "$OTA_SD_ROOT/MUOS/init/" 2>/dev/null

    # Binaries: only rewrite ones whose size differs (cheap change probe;
    # rewriting 20+ MB over SD for identical bytes wears the card and
    # widens the interruption window for nothing).
    for b in bin/git bin/busybox libexec/git-core/git libexec/git-core/git-remote-https \
             libexec/git-core/git-remote-http share/ca-bundle.crt; do
        if [ -f "$app/$b" ]; then
            if [ "$(cat "$app/$b" 2>/dev/null | wc -c)" != "$(cat "$OTA_APP_DIR/$b" 2>/dev/null | wc -c)" ]; then
                ota_log "Updating binary: $b"
                cp "$app/$b" "$OTA_APP_DIR/$b" || return 1
            fi
        fi
    done

    find "$OTA_APP_DIR" -name "*.sh" -exec chmod +x {} +
    chmod +x "$OTA_SD_ROOT"/MUOS/task/*.sh "$OTA_SD_ROOT"/MUOS/init/*.sh 2>/dev/null
    chmod +x "$OTA_APP_DIR"/bin/* "$OTA_APP_DIR"/libexec/git-core/* 2>/dev/null

    printf '%s\n' "$commit" > "$OTA_HOME/.ota_commit"
    sync

    new_version=$(cat "$OTA_APP_DIR/version.txt" 2>/dev/null)
    ota_log "Update applied: ${new_version:-unknown} ($commit)"
    return 0
}

# ota_run — check and apply in one call (used by scripted/manual flows).
# Returns: 0 updated, 1 no update, 2 failure.
ota_run() {
    local info commit
    ota_disabled && return 1
    mkdir -p "$OTA_HOME"
    info=$(ota_check) || return 1
    commit="${info##* }"
    ota_apply "$commit" || return 2
    return 0
}
