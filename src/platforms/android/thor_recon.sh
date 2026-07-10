#!/bin/sh
# Continuity — Ayn Thor / RetroArch-Android on-device recon (Sprint 3.2a)
#
# READ-ONLY: this script inspects the device over adb and writes ONE
# report file (CONTINUITY_THOR_RECON.txt in the current directory). It
# never touches RetroArch's config, saves, or anything else.
#
# Run on a PC with adb, Thor connected with USB debugging enabled:
#   sh thor_recon.sh
# then send CONTINUITY_THOR_RECON.txt back for spec confirmation.
#
# Enabling USB debugging on the Thor (stock Android flow; menu names
# can vary slightly by firmware):
#   1. Settings -> About device (or About phone) -> tap "Build number"
#      7 times, until "You are now a developer!" appears.
#   2. Settings -> System -> Developer options -> enable "USB debugging".
#   3. Connect a USB-C DATA cable to the PC; on the Thor accept the
#      "Allow USB debugging?" prompt (tick "Always allow from this
#      computer").
#   4. Verify on the PC: `adb devices` lists the Thor as "device".
#      - listed as "unauthorized": the on-screen prompt is still
#        waiting (or: Developer options -> Revoke USB debugging
#        authorizations, then replug and re-accept).
#      - not listed at all: try another cable/port, set the device's
#        USB mode to "File transfer/MTP"; Windows may need the Google
#        USB driver.
#
# ROM roots on the SD card are probed automatically (every /storage
# volume). Unusual locations can be force-probed with
#   CONTINUITY_ROM_ROOTS=/abs/path1:/abs/path2 sh thor_recon.sh
#
# Windows / WSL note: WSL cannot see USB devices, so a Linux adb
# installed inside Ubuntu-on-Windows finds no device. Either:
#   a) run WITHOUT a PC — Termux local mode (above): install Termux
#      (F-Droid build), then
#        termux-setup-storage && pkg install curl
#        curl -LO <raw URL of this file>
#        CONTINUITY_RECON_LOCAL=1 sh thor_recon.sh
#        cp CONTINUITY_THOR_RECON.txt ~/storage/shared/
#      and copy the report off over plain MTP file transfer. (Termux is
#      subject to package-visibility filtering — the RetroArch package
#      section may be empty; manual checklist M5 covers it.)
#   b) use the WINDOWS adb from WSL: unzip Google platform-tools on the
#      Windows side, then
#        sudo ln -s /mnt/c/platform-tools/adb.exe /usr/local/bin/adb
#      USB handling stays on Windows; this script already strips the
#      CRs that adb.exe emits.
#
# Alternative (no PC): run directly on the device in Termux with
#   CONTINUITY_RECON_LOCAL=1 sh thor_recon.sh
# (local mode runs the same probes through the device shell; Termux can
# read shared storage after `termux-setup-storage`).
#
# Modern Android restricts /sdcard/Android/data/<other-app> even for the
# adb shell user — a denied probe is a FINDING (it means the Continuity
# app could not read that path either), not a crash. Everything is
# guarded; the report says what it could not see, and the manual
# checklist at the end covers exactly those gaps.
#
# POSIX sh so the same file parses under the test-suite interpreter.
set -u

report="${CONTINUITY_RECON_OUT:-./CONTINUITY_THOR_RECON.txt}"
local_mode="${CONTINUITY_RECON_LOCAL:-0}"

out() { printf '%s\n' "$*" >>"$report"; }
section() { out ""; out "== $* =="; }

# run_dev <command string> — run a shell command on the device.
# adb mode: via `adb shell`; local mode: via the device's own sh.
# Old adb/device combos emit \r\n — strip CRs defensively.
# stdin is redirected from /dev/null: adb inherits and SLURPS the
# caller's stdin, which silently empties any `while read` loop that
# invokes it per line (field-found: the first Thor report's directory
# censuses and container sniff were truncated to one entry each).
run_dev() {
    if [ "$local_mode" = "1" ]; then
        sh -c "$1" </dev/null 2>/dev/null | tr -d '\r'
    else
        adb shell "$1" </dev/null 2>/dev/null | tr -d '\r'
    fi
}

# run_dev_raw <command string> — binary-safe device command (no CR strip).
run_dev_raw() {
    if [ "$local_mode" = "1" ]; then
        sh -c "$1" </dev/null 2>/dev/null
    else
        adb exec-out "$1" </dev/null 2>/dev/null
    fi
}

# dev_test <test-expr> — evaluate a test on the device; echoes yes/no/denied.
# A path that exists but is unreadable (scoped storage) reports "denied".
dev_test_dir() {
    _p="$1"
    if [ "$(run_dev "[ -d \"$_p\" ] && echo yes")" = "yes" ]; then
        # Existing dir — can we actually list it?
        if run_dev "ls \"$_p\"" >/dev/null 2>&1 && \
           [ "$(run_dev "ls \"$_p\" >/dev/null 2>&1 && echo ok || echo deny")" = "ok" ]; then
            printf 'yes'
        else
            printf 'denied'
        fi
    else
        printf 'no'
    fi
}

dev_test_file() {
    _p="$1"
    if [ "$(run_dev "[ -f \"$_p\" ] && echo yes")" = "yes" ]; then
        if [ "$(run_dev "[ -r \"$_p\" ] && head -c 1 \"$_p\" >/dev/null 2>&1 && echo ok")" = "ok" ]; then
            printf 'yes'
        else
            printf 'denied'
        fi
    else
        printf 'no'
    fi
}

# cfg_value <key> <cfg-file-on-device> — key = "value" from retroarch.cfg.
cfg_value() {
    run_dev "cat \"$2\"" | sed -n 's/^'"$1"' *= *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -1
}

# reachability <path> — MANAGE_EXTERNAL_STORAGE can NOT read another
# app's Android/data or Android/obb. Anything there is unreachable for
# the Continuity companion app, regardless of what adb can see.
reachability() {
    case "$1" in
        */Android/data/*|*/Android/obb/*)
            printf 'UNREACHABLE for Continuity (Android/data — All Files Access does not cover it)' ;;
        /storage/*|/sdcard/*|/mnt/sdcard/*)
            printf 'reachable (shared storage)' ;;
        :*)
            printf 'UNREACHABLE for Continuity (app-relative default -> Android/data/<pkg>/files)' ;;
        *)
            printf 'unknown — confirm manually' ;;
    esac
}

: >"$report"
out "Continuity Thor recon — $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
out "mode: $( [ "$local_mode" = "1" ] && printf 'on-device (local)' || printf 'adb from PC')"

# --- Connectivity / device identity ---------------------------------
section "Device"
if [ "$local_mode" != "1" ]; then
    if ! command -v adb >/dev/null 2>&1; then
        out "adb: NOT FOUND on this PC — install platform-tools, or run on-device with CONTINUITY_RECON_LOCAL=1"
        printf 'Wrote %s (adb missing — nothing probed)\n' "$report"
        cat "$report"
        exit 0
    fi
    state=$(adb get-state 2>/dev/null | tr -d '\r')
    out "adb state: ${state:-no device (enable USB debugging, accept the RSA prompt)}"
    if [ "${state:-}" != "device" ]; then
        printf 'Wrote %s (no device — connect the Thor and re-run)\n' "$report"
        cat "$report"
        exit 0
    fi
fi
out "model: $(run_dev 'getprop ro.product.model') ($(run_dev 'getprop ro.product.device'))"
out "android: $(run_dev 'getprop ro.build.version.release') (SDK $(run_dev 'getprop ro.build.version.sdk'))"
out "build: $(run_dev 'getprop ro.build.display.id')"
out "abi: $(run_dev 'getprop ro.product.cpu.abi')"

section "Storage volumes"
out "/storage contents (SD card shows as a volume ID like 1234-ABCD):"
run_dev 'ls /storage' | while IFS= read -r v; do
    [ -n "$v" ] && out "  /storage/$v"
done
out "top-level shared storage dirs (/storage/emulated/0):"
run_dev 'ls /storage/emulated/0' | while IFS= read -r d; do
    [ -n "$d" ] && out "  $d"
done

# --- RetroArch installs ----------------------------------------------
section "RetroArch packages"
pkgs=$(run_dev 'pm list packages' | sed -n 's/^package://p' | grep -i retroarch || true)
if [ -n "$pkgs" ]; then
    printf '%s\n' "$pkgs" | while IFS= read -r p; do
        [ -z "$p" ] && continue
        ver=$(run_dev "dumpsys package $p" | sed -n 's/^ *versionName=//p' | head -1)
        out "$p (versionName ${ver:-unknown})"
    done
else
    out "NO RetroArch package found (pm list) — is RetroArch installed? Which frontend does the Thor use?"
fi

# --- Config discovery ------------------------------------------------
# Buildbot/legacy installs keep retroarch.cfg on shared storage; Play
# Store builds keep it app-private under Android/data (adb may be denied
# there on Android 11+ — that denial is itself the storage finding).
section "retroarch.cfg discovery"
found_cfg=""
candidate_cfgs=""
for p in $pkgs; do
    candidate_cfgs="$candidate_cfgs
/storage/emulated/0/Android/data/$p/files/retroarch.cfg"
done
candidate_cfgs="$candidate_cfgs
/storage/emulated/0/RetroArch/retroarch.cfg
/storage/emulated/0/RetroArch/config/retroarch.cfg"
[ -n "${CONTINUITY_RA_CFG:-}" ] && candidate_cfgs="${CONTINUITY_RA_CFG}
$candidate_cfgs"

printf '%s\n' "$candidate_cfgs" | while IFS= read -r c; do
    [ -z "$c" ] && continue
    st=$(dev_test_file "$c")
    out "$c: $st"
done
# pick the first readable one (re-scan; the while above ran in a subshell)
found_cfg=$(printf '%s\n' "$candidate_cfgs" | while IFS= read -r c; do
    [ -z "$c" ] && continue
    [ "$(dev_test_file "$c")" = "yes" ] && printf '%s\n' "$c" && break
done)

section "RetroArch save settings"
if [ -n "$found_cfg" ]; then
    out "(from $found_cfg)"
    for key in savefile_directory savestate_directory save_file_compression \
               savestate_file_compression sort_savefiles_enable \
               sort_savefiles_by_content_enable sort_savestates_enable \
               sort_savestates_by_content_enable savefiles_in_content_dir \
               savestates_in_content_dir rgui_browser_directory; do
        out "$key = $(cfg_value "$key" "$found_cfg")"
    done
else
    out "no readable retroarch.cfg — fill in the MANUAL CHECKLIST section below from the RetroArch UI"
fi

# --- Saves tree -------------------------------------------------------
section "Saves tree (real filenames + container sniff)"
saves_root=""
if [ -n "$found_cfg" ]; then
    saves_root=$(cfg_value savefile_directory "$found_cfg")
fi
out "savefile_directory (verbatim): ${saves_root:-<unknown>}"
if [ -n "$saves_root" ]; then
    out "reachability: $(reachability "$saves_root")"
fi
# Resolve RetroArch's ':' app-relative prefix for probing purposes.
case "$saves_root" in
    :*)
        first_pkg=$(printf '%s\n' "$pkgs" | head -1)
        [ -n "$first_pkg" ] && saves_root="/storage/emulated/0/Android/data/$first_pkg/files${saves_root#:}"
        out "resolved app-relative path: ${saves_root:-<no package>}"
        ;;
esac
# Fall back to probing well-known roots if cfg was unreadable.
if [ -z "$saves_root" ]; then
    for cand in "/storage/emulated/0/RetroArch/saves" \
                "/storage/emulated/0/RetroArch/save"; do
        if [ "$(dev_test_dir "$cand")" = "yes" ]; then
            saves_root="$cand"
            out "probed fallback saves root: $cand"
            break
        fi
    done
fi

if [ -n "$saves_root" ] && [ "$(dev_test_dir "$saves_root")" = "yes" ]; then
    out "-- immediate subdirectories (save sorting shape) --"
    subdirs=$(run_dev "ls -p \"$saves_root\"" | grep '/$' || true)
    if [ -n "$subdirs" ]; then
        printf '%s\n' "$subdirs" | while IFS= read -r d; do
            [ -z "$d" ] && continue
            n=$(run_dev "find \"$saves_root/${d%/}\" -type f 2>/dev/null" | grep -c . || true)
            out "  ${d%/}: ${n:-0} files"
        done
    else
        out "  (none — saves are FLAT in the root: no sorting, see spec contingency C3)"
    fi
    out "-- sample save filenames (up to 25) --"
    save_list=$(run_dev "find \"$saves_root\" -type f \\( -name '*.srm' -o -name '*.sav' -o -name '*.rtc' \\) 2>/dev/null" | head -25)
    if [ -n "$save_list" ]; then
        printf '%s\n' "$save_list" | while IFS= read -r f; do
            [ -z "$f" ] && continue
            out "  ${f#"$saves_root"/}"
        done
    else
        out "  (no .srm/.sav/.rtc files found under $saves_root)"
    fi
    # Same 8-byte hex sniff as core pm_container_class (#RZIPv\x01# —
    # byte 7 is raw 0x01; see tools/rzip/rzip.c RZIP_MAGIC).
    out "-- container sniff (.srm/.sav: RZIP magic vs raw, first 50) --"
    rz=0; raw=0
    sniff_tmp="${TMPDIR:-/tmp}/continuity_thor_sniff.$$"
    printf '%s\n' "$save_list" | head -50 >"$sniff_tmp"
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in *.rtc) continue ;; esac
        magic=$(run_dev_raw "dd if=\"$f\" bs=8 count=1 2>/dev/null" | od -An -tx1 2>/dev/null | tr -d ' \n')
        if [ "$magic" = "23525a4950760123" ]; then
            rz=$((rz + 1)); out "  COMPRESSED: ${f#"$saves_root"/}"
        else
            raw=$((raw + 1))
        fi
    done <"$sniff_tmp"
    rm -f "$sniff_tmp"
    out "  raw: $raw, rzip-compressed: $rz"
else
    out "saves root not listable (${saves_root:-unset}) — Continuity would hit the same wall; see reachability above and the manual checklist"
fi

# --- States tree (archive-only class) --------------------------------
section "States tree"
states_root=""
[ -n "$found_cfg" ] && states_root=$(cfg_value savestate_directory "$found_cfg")
out "savestate_directory (verbatim): ${states_root:-<unknown>}"
[ -n "$states_root" ] && out "reachability: $(reachability "$states_root")"
if [ -n "$states_root" ] && [ "$(dev_test_dir "$states_root")" = "yes" ]; then
    out "-- sample state filenames (up to 10) --"
    run_dev "find \"$states_root\" -type f \\( -name '*.state' -o -name '*.state[0-9]*' -o -name '*.state.auto' \\) 2>/dev/null" | head -10 | while IFS= read -r f; do
        [ -z "$f" ] && continue
        out "  ${f#"$states_root"/}"
    done
fi

# --- ROMs -------------------------------------------------------------
# Probes internal storage AND every non-emulated /storage volume (SD
# cards) for common ROM-root names, and lists each SD volume's top-level
# dirs so an unusually-named root still shows up in the report. Extra
# roots: CONTINUITY_ROM_ROOTS=/abs/path1:/abs/path2 (colon-separated).

# probe_rom_root <abs-dir> — report a ROM root: per-system file counts
# plus the nested-layout check. Silent when the dir does not exist.
probe_rom_root() {
    _cand="$1"
    _st=$(dev_test_dir "$_cand")
    [ "$_st" = "no" ] && return 0
    out "$_cand: $_st"
    [ "$_st" = "yes" ] || return 0
    run_dev "ls -p \"$_cand\"" | grep '/$' | head -25 | while IFS= read -r d; do
        [ -z "$d" ] && continue
        n=$(run_dev "find \"$_cand/${d%/}\" -maxdepth 1 -type f 2>/dev/null" | grep -c . || true)
        out "  ${d%/}: ${n:-0} files"
    done
    out "  -- nested ROM dirs (files deeper than <root>/<system>/) --"
    nested=$(run_dev "find \"$_cand\" -mindepth 3 -type f 2>/dev/null" | head -3)
    if [ -n "$nested" ]; then
        printf '%s\n' "$nested" | while IFS= read -r nf; do out "  $nf"; done
    else
        out "  none found (flat layout — good)"
    fi
}

# probe_rom_names <volume-root> — try the common ROM-root names there.
probe_rom_names() {
    for _name in Roms ROMs roms Games RetroArch/roms; do
        probe_rom_root "$1/$_name"
    done
}

section "ROM roots (internal + SD volumes)"
if [ -n "${CONTINUITY_ROM_ROOTS:-}" ]; then
    out "-- owner-specified roots (CONTINUITY_ROM_ROOTS) --"
    printf '%s\n' "$CONTINUITY_ROM_ROOTS" | tr ':' '\n' | while IFS= read -r r; do
        [ -n "$r" ] && probe_rom_root "$r"
    done
fi

out "-- internal storage (/storage/emulated/0) --"
probe_rom_names "/storage/emulated/0"

vols=$(run_dev 'ls /storage' | grep -v '^emulated$' | grep -v '^self$' || true)
if [ -n "$vols" ]; then
    printf '%s\n' "$vols" | while IFS= read -r v; do
        [ -z "$v" ] && continue
        out "-- SD/removable volume /storage/$v --"
        out "  top-level dirs:"
        run_dev "ls -p \"/storage/$v\"" | grep '/$' | head -25 | while IFS= read -r d; do
            [ -z "$d" ] && continue
            out "    ${d%/}"
        done
        probe_rom_names "/storage/$v"
    done
else
    out "-- no SD/removable volume detected under /storage --"
fi
out "(if the real ROM root is none of the probed names, re-run with CONTINUITY_ROM_ROOTS=/abs/path — the volume listings above show the candidates)"

# --- Frontends (mapping-seed evidence for issue #14) ------------------
# The frontend is where the user already declared folder->system->core;
# ES-DE keeps its config on shared storage (passively readable),
# Daijisho keeps it app-private (needs the user's export gesture, M8).

# probe_esde <volume-root> — report an ES-DE config dir if present.
probe_esde() {
    _es="$1/ES-DE"
    [ "$(dev_test_dir "$_es")" = "no" ] && return 0
    out "$_es: $(dev_test_dir "$_es")"
    for _f in "$_es/settings/es_settings.xml" "$_es/es_settings.xml"; do
        if [ "$(dev_test_file "$_f")" = "yes" ]; then
            out "  es_settings.xml: $_f"
            _romdir=$(run_dev "cat \"$_f\"" | sed -n 's/.*name="ROMDirectory" *value="\([^"]*\)".*/\1/p' | head -1)
            [ -n "$_romdir" ] && out "  ROMDirectory = $_romdir"
        fi
    done
    out "  custom_systems/es_systems.xml: $(dev_test_file "$_es/custom_systems/es_systems.xml")"
    if [ "$(dev_test_dir "$_es/gamelists")" = "yes" ]; then
        out "  gamelists (active systems):"
        run_dev "ls -p \"$_es/gamelists\"" | grep '/$' | head -40 | while IFS= read -r d; do
            [ -z "$d" ] && continue
            out "    ${d%/}"
        done
    fi
}

section "Frontends (system/core/ROM-path config sources)"
probe_esde "/storage/emulated/0"
if [ -n "$vols" ]; then
    printf '%s\n' "$vols" | while IFS= read -r v; do
        [ -z "$v" ] && continue
        probe_esde "/storage/$v"
    done
fi
dj_pkg=$(run_dev 'pm list packages' | sed -n 's/^package://p' | grep -i daijishou | head -1 || true)
if [ -n "$dj_pkg" ]; then
    out "Daijisho package: $dj_pkg"
    out "Daijisho live config: Android/data/$dj_pkg (app-private, listing: $(dev_test_dir "/storage/emulated/0/Android/data/$dj_pkg")) — use the export flow (checklist M8)"
else
    out "Daijisho package: not found (note: package-visibility filtering can hide it in Termux/local mode — M8 still applies if installed)"
fi

# --- Network (sanity only) -------------------------------------------
section "Network"
if [ "$(run_dev 'ping -c 1 -W 3 github.com >/dev/null 2>&1 && echo ok')" = "ok" ]; then
    out "github.com reachable from device"
else
    out "github.com NOT reachable from device shell (may be ICMP-blocked; fine for recon)"
fi

# --- Manual checklist -------------------------------------------------
section "MANUAL CHECKLIST (fill in whatever the probes above could not see)"
out "In RetroArch on the Thor, note the following and add the answers here:"
out "  M1. Settings -> Saving -> 'SaveRAM Compression': ON or OFF?"
out "  M2. Settings -> Saving -> 'Sort Saves into Folders by Core Name': ON or OFF?"
out "  M3. Settings -> Saving -> 'Sort Saves into Folders by Content Directory Name': ON or OFF?"
out "  M4. Settings -> Directory -> 'Saves' and 'Save States': the exact paths shown."
out "  M5. Which RetroArch build is actually used to play (Play Store / buildbot APK / 32-bit)?"
out "  M6. Where do ROMs live (exact folder), and is the layout one folder per system?"
out "  M7. Any other emulators whose saves should sync eventually (standalone cores, Dolphin, Drastic...)? (Out of 3.2a scope — inventory only.)"
out "  M8. If Daijisho is (or was) the frontend: Settings -> export/backup the platform configuration to a file on shared storage and send it back with this report (mapping-seed fixture for issue #14)."

out ""
out "Recon complete. Send this file back: $report"
printf 'Wrote %s\n' "$report"
cat "$report"
