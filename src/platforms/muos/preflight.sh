#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity — preflight doctor (muOS).
#
# One run captures every environment fact that past debugging rounds each
# needed a separate SD-card round-trip to discover: build identity, device
# clock sanity (a wrong clock breaks TLS), module line endings, the git
# binary AND its https helper AND its CA bundle, network reachability, a
# real unauthenticated TLS handshake with GitHub, setup.json shape (PAT
# never logged), button device, free space.
#
# The full report is written to a caller-chosen file (launch.sh puts it at
# the SD card root as CONTINUITY_DIAGNOSTIC.txt — visible on any OS) and
# the first fatal failure is available in $_pf_first_fail for the screen.
#
# Overridables for tests:
#   PF_YEAR          — current year (default: date +%Y)
#   PF_LSREMOTE_URL  — public repo for the network probe
#                      (default: this project's public GitHub repo)

PF_LSREMOTE_URL="${PF_LSREMOTE_URL:-https://github.com/jreinach-alt/continuity}"

_pf_report=""
_pf_first_fail=""
_pf_failed=0

# pf_emit <ok|FAIL|warn|info> <check-name> <detail>
pf_emit() {
    local status name detail
    status="$1"; name="$2"; detail="$3"
    printf '%-4s %-14s %s\n' "$status" "$name" "$detail" >> "$_pf_report"
    if [ "$status" = "FAIL" ]; then
        _pf_failed=1
        if [ -z "$_pf_first_fail" ]; then
            _pf_first_fail="$name: $detail"
        fi
    fi
}

pf_check_build() {
    local v
    v=$(cat "$CONTINUITY_APP_DIR/version.txt" 2>/dev/null)
    pf_emit "info" "build" "${v:-unknown} at $CONTINUITY_APP_DIR"
}

pf_check_clock() {
    local year
    year="${PF_YEAR:-$(date '+%Y')}"
    if [ "$year" -ge 2025 ] 2>/dev/null; then
        pf_emit "ok" "clock" "$(date '+%Y-%m-%d %H:%M:%S')"
    else
        pf_emit "FAIL" "clock" "device clock shows $(date '+%Y-%m-%d') — TLS will reject certificates; connect WiFi so NTP can set the time, then retry"
    fi
}

pf_check_modules() {
    local cr bad
    cr=$(printf '\r')
    bad=$(grep -rl "$cr" "$CONTINUITY_APP_DIR/scripts" "$CONTINUITY_APP_DIR/launch.sh" 2>/dev/null | head -3)
    if [ -n "$bad" ]; then
        pf_emit "FAIL" "line-endings" "CRLF in: $(printf '%s' "$bad" | tr '\n' ' ')"
    else
        pf_emit "ok" "line-endings" "all modules LF-clean"
    fi
}

pf_check_git_binary() {
    local v resolved
    # Bare command names (test sandboxes use the system git) resolve via
    # PATH; on the device this is always the PAK's absolute path.
    case "$CONTINUITY_GIT_BIN" in
        */*) resolved="$CONTINUITY_GIT_BIN" ;;
        *)   resolved=$(command -v "$CONTINUITY_GIT_BIN" 2>/dev/null) ;;
    esac
    if [ -z "$resolved" ] || [ ! -x "$resolved" ]; then
        pf_emit "FAIL" "git-binary" "missing or not executable: $CONTINUITY_GIT_BIN"
        return 0
    fi
    v=$("$CONTINUITY_GIT_BIN" --version 2>&1 | head -1)
    if [ -n "$v" ]; then
        pf_emit "ok" "git-binary" "$v"
    else
        pf_emit "FAIL" "git-binary" "present but produced no output — wrong architecture?"
    fi
}

pf_check_https_helper() {
    # Record the env wiring too — a present helper that git can't FIND
    # (GIT_EXEC_PATH unset) looks identical to a missing one at git level.
    pf_emit "info" "git-env" "GIT_EXEC_PATH=${GIT_EXEC_PATH:-unset} GIT_SSL_CAINFO=${GIT_SSL_CAINFO:-unset}"
    local helper out rc
    helper="$CONTINUITY_APP_DIR/libexec/git-core/git-remote-https"
    if [ ! -x "$helper" ]; then
        pf_emit "FAIL" "https-helper" "git-remote-https missing — git cannot speak https (incomplete app copy: bin/ needs a libexec sibling)"
        return 0
    fi
    # Present is not enough: actually execute it. A binary the kernel
    # refuses to run (rc 126/127) looks identical to a missing one from
    # git's side — capture the real reason here instead. (rc must be
    # taken from the helper itself, not from a downstream pipeline.)
    out=$("$helper" </dev/null 2>&1)
    rc=$?
    out=$(printf '%s' "$out" | head -1)
    if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
        pf_emit "FAIL" "https-helper" "present but will not execute (rc=$rc): ${out:-no output}"
    else
        pf_emit "ok" "https-helper" "executes (rc=$rc)"
    fi
}

pf_check_ca_bundle() {
    if [ -s "$CONTINUITY_APP_DIR/share/ca-bundle.crt" ]; then
        pf_emit "ok" "ca-bundle" "share/ca-bundle.crt present"
    else
        pf_emit "FAIL" "ca-bundle" "share/ca-bundle.crt missing — TLS verification will fail"
    fi
}

pf_check_network() {
    if pal_is_online; then
        pf_emit "ok" "network" "online"
        return 0
    fi
    pf_emit "FAIL" "network" "offline — connect WiFi in muOS Configuration > WiFi, then retry"
    return 1
}

# pf_check_binaries — verify shipped binaries against build-time
# checksums. A truncated SD-card copy passes -x but fails the kernel's
# exec with an error git masks as "unable to find remote helper".
pf_check_binaries() {
    local sums line sum size path actual_size actual_sum bad
    sums="$CONTINUITY_APP_DIR/checksums.txt"
    if [ ! -f "$sums" ]; then
        pf_emit "info" "checksums" "checksums.txt absent — skipping"
        return 0
    fi
    bad=""
    while IFS=' ' read -r sum size path; do
        [ -n "$path" ] || continue
        actual_size=$(cat "$CONTINUITY_APP_DIR/$path" 2>/dev/null | wc -c)
        if [ "$actual_size" != "$size" ]; then
            bad="$path (size $actual_size, expected $size)"
            break
        fi
        if command -v sha256sum >/dev/null 2>&1; then
            actual_sum=$(sha256sum "$CONTINUITY_APP_DIR/$path" 2>/dev/null | cut -d' ' -f1)
            if [ "$actual_sum" != "$sum" ]; then
                bad="$path (checksum mismatch)"
                break
            fi
        fi
    done < "$sums"
    if [ -n "$bad" ]; then
        pf_emit "FAIL" "checksums" "corrupt on card: $bad — re-copy the PAK and EJECT the card properly"
    else
        pf_emit "ok" "checksums" "all shipped binaries intact"
    fi
}

# pf_check_busybox — the vendored interpreter, probed with the daemon's
# own self-test so this report PREDICTS the daemon's re-exec decision.
# Fail-open by design: absent/broken is never fatal — the daemon then
# runs under the device shell exactly as it did before vendoring.
pf_check_busybox() {
    local bb
    bb="$CONTINUITY_APP_DIR/bin/busybox"
    if [ "${CONTINUITY_VENDOR_SH:-1}" != "1" ]; then
        pf_emit "info" "busybox" "disabled (CONTINUITY_VENDOR_SH=0) — daemon uses device sh"
        return 0
    fi
    if [ ! -x "$bb" ]; then
        pf_emit "info" "busybox" "not bundled — daemon uses device sh"
        return 0
    fi
    if "$bb" ash -c 'true' >/dev/null 2>&1; then
        pf_emit "ok" "busybox" "vendored interpreter passes self-test — daemon will pin to it"
    else
        pf_emit "warn" "busybox" "bundled but fails self-test — daemon falls back to device sh"
    fi
}

# Real end-to-end probe: DNS + TCP + TLS + CA + clock + https helper in
# one shot, no credentials involved. Only meaningful if network is up.
# GIT_EXEC_PATH/GIT_SSL_CAINFO are re-defaulted inline as a belt against
# any failure of the PAL's export wiring.
pf_check_github_tls() {
    local out
    out=$(GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20 \
          GIT_EXEC_PATH="${GIT_EXEC_PATH:-$CONTINUITY_APP_DIR/libexec/git-core}" \
          GIT_SSL_CAINFO="${GIT_SSL_CAINFO:-$CONTINUITY_APP_DIR/share/ca-bundle.crt}" \
          "$CONTINUITY_GIT_BIN" ls-remote "$PF_LSREMOTE_URL" HEAD 2>&1 | head -2)
    case "$out" in
        *[0-9a-f]*HEAD*)
            pf_emit "ok" "github-tls" "unauthenticated ls-remote succeeded"
            ;;
        *)
            pf_emit "FAIL" "github-tls" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
            ;;
    esac
}

# pf_check_mapping — the platform map must parse ON THIS DEVICE's shell
# userland and translate a real save path. A silently-empty map blinds
# every scanner while everything else looks healthy.
pf_check_mapping() {
    local count probe
    if ! command -v pm_load_platform_map >/dev/null 2>&1; then
        pf_emit "info" "mapping" "path mapper not loaded in this context — skipped"
        return 0
    fi
    pm_load_platform_map "$(pal_get_platform_map)" >/dev/null 2>&1
    count=$(pm_list_watched_dirs 2>/dev/null | grep -c .)
    probe=$(pm_local_to_repo "$CONTINUITY_SAVES_ROOT/Snes9x/Probe Game (USA).srm" 2>/dev/null)
    if [ "$count" -gt 0 ] && [ "$probe" = "snes/Probe Game (USA).srm" ]; then
        pf_emit "ok" "mapping" "$count watched dirs; Snes9x probe translates"
    else
        pf_emit "FAIL" "mapping" "watched dirs: ${count:-0}, Snes9x probe: '${probe:-empty}' — map parse broken on this device"
    fi
}

pf_check_setup_json() {
    local f url name pat
    f="$CONTINUITY_SD_ROOT/setup.json"
    if [ ! -f "$f" ]; then
        pf_emit "info" "setup-json" "absent"
        return 0
    fi
    url=$(sed -n 's/^[[:space:]]*"repo_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f")
    name=$(sed -n 's/^[[:space:]]*"device_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f")
    pat=$(sed -n 's/^[[:space:]]*"pat"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f")
    if [ -n "$url" ] && [ -n "$name" ] && [ -n "$pat" ]; then
        # Credentials embedded in the URL end up in git's error output
        # and our logs — the pat field is the only sanctioned channel.
        case "$url" in
            *://*@*)
                pf_emit "warn" "setup-json" "repo_url embeds credentials — remove them; the pat field is used for auth"
                ;;
        esac
        pf_emit "ok" "setup-json" "repo=$(printf '%s' "$url" | sed 's|://[^/@]*@|://|') device=$name pat=present(${#pat} chars)"
    else
        pf_emit "FAIL" "setup-json" "unparseable — need repo_url, device_name, pat (url:'${url:-?}' device:'${name:-?}' pat:$([ -n "$pat" ] && printf 'present' || printf 'MISSING'))"
    fi
}

pf_check_buttons() {
    if [ -r "${EUI_JS_DEV:-/dev/input/js0}" ]; then
        pf_emit "ok" "buttons" "joystick device present"
    else
        pf_emit "warn" "buttons" "no ${EUI_JS_DEV:-/dev/input/js0} — B/X/Y disabled, watchdog still active"
    fi
}

pf_check_space() {
    local free_kb
    free_kb=$(df -k "$CONTINUITY_SD_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$free_kb" ] && [ "$free_kb" -lt 51200 ] 2>/dev/null; then
        pf_emit "warn" "space" "only $((free_kb / 1024)) MB free on SD card"
    else
        pf_emit "ok" "space" "${free_kb:-unknown} KB free"
    fi
}

# pf_check_muos_version — record BOTH version signals VERBATIM, trust
# neither (Version Support Policy: the reference device's two files
# disagree — os-release said Banana while version.txt said Pixie).
# Diagnostics only; nothing anywhere branches on these strings.
pf_check_muos_version() {
    local osr vtxt
    osr=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' "${PF_OS_RELEASE:-/etc/os-release}" 2>/dev/null | head -1)
    vtxt=$(head -1 "${PF_MUOS_VERSION_FILE:-/opt/muos/config/version.txt}" 2>/dev/null)
    pf_emit "info" "muos-version" "os-release='${osr:-absent}' version.txt='${vtxt:-absent}' (diagnostics only — never branched on)"
}

# pf_check_path_resolution — the Version Support Policy makes roots
# resolve silently by existence probe; surface what was chosen so a
# wrong resolution on an unknown layout is visible, not a silent
# nothing-syncs.
pf_check_path_resolution() {
    pf_emit "info" "paths" "saves=$CONTINUITY_SAVES_ROOT states=$CONTINUITY_STATES_ROOT roms=$CONTINUITY_ROMS_ROOT"
    if [ -d "$CONTINUITY_SAVES_ROOT" ]; then
        pf_emit "ok" "saves-root" "exists"
    else
        pf_emit "warn" "saves-root" "$CONTINUITY_SAVES_ROOT does not exist yet (fresh device or unexpected layout)"
    fi
}

# pf_check_boot_hook — boot-hook diagnostics: is the hook installed,
# did muOS EVER run it (breadcrumb), and what does the firmware config
# say about the User Init Scripts toggle. Observation only, except the
# one actionable case: hook installed but never executed -> warn with
# the toggle instruction (field case: silent no-start after reboot,
# build 20260710-0003).
pf_check_boot_hook() {
    local initd muxscript hook crumb toggle
    initd=$(ls "${PF_INITD:-/etc/init.d}" 2>/dev/null | tr '\n' ' ' | cut -c1-120)
    muxscript=$(ls "${PF_MUOS_SCRIPT_DIR:-/opt/muos/script}" 2>/dev/null | head -20 | tr '\n' ' ' | cut -c1-160)
    pf_emit "info" "boot-hook" "init.d: ${initd:-unreadable}"
    pf_emit "info" "boot-hook" "/opt/muos/script: ${muxscript:-unreadable}"

    hook="$CONTINUITY_SD_ROOT/MUOS/init/continuity.sh"
    crumb=$(grep 'boot init hook' "$CONTINUITY_SD_ROOT/.continuity/launch.log" 2>/dev/null | tail -1 | cut -c1-200)
    toggle=$(grep -ri 'user_init\|userinit' "${PF_MUOS_CONFIG_DIR:-/opt/muos/config}" 2>/dev/null | head -2 | tr '\n' ' ' | cut -c1-160)
    if [ ! -f "$hook" ]; then
        pf_emit "info" "boot-hook" "MUOS/init/continuity.sh not installed — daemon starts via Task Toolkit only"
    elif [ -n "$crumb" ]; then
        pf_emit "ok" "boot-hook" "hook has run: ${crumb}"
    else
        pf_emit "warn" "boot-hook" "hook installed but NO run breadcrumb — enable Configuration > General Settings > Advanced Settings > User Init Scripts, then reboot (if that setting does not exist on this muOS version, report it)"
    fi
    pf_emit "info" "boot-hook" "firmware config mentions: ${toggle:-nothing matching user_init}"
}

# pf_run — run every check, write the report.
# Usage: pf_run <report_file>
# Returns: 0 if no fatal check failed, 1 otherwise.
pf_run() {
    _pf_report="$1"
    _pf_first_fail=""
    _pf_failed=0

    {
        printf '=== Continuity preflight %s ===\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    } > "$_pf_report"

    pf_check_build
    pf_check_muos_version
    pf_check_path_resolution
    pf_check_clock
    pf_check_modules
    pf_check_git_binary
    pf_check_https_helper
    pf_check_binaries
    pf_check_busybox
    pf_check_ca_bundle
    pf_check_mapping
    if pf_check_network; then
        pf_check_github_tls
    else
        pf_emit "info" "github-tls" "skipped (offline)"
    fi
    pf_check_setup_json
    pf_check_boot_hook
    pf_check_buttons
    pf_check_space

    printf '=== preflight %s ===\n' "$([ "$_pf_failed" -eq 0 ] && printf 'PASSED' || printf 'FAILED')" >> "$_pf_report"
    sync
    return "$_pf_failed"
}
