#!/bin/sh
# Continuity — Steam Deck / RetroDeck on-device recon (Sprint 2.1)
#
# READ-ONLY: this script inspects the device and writes ONE report file
# (CONTINUITY_DECK_RECON.txt in the current directory). It never touches
# RetroDeck's config, saves, or anything else.
#
# Run on the Deck (desktop mode, Konsole):
#   sh deck_recon.sh
# then send CONTINUITY_DECK_RECON.txt back for spec confirmation.
#
# POSIX sh so the same file also runs under the test-suite interpreter;
# every probe is guarded — a missing tool or path is a finding, not a
# crash.
set -u

report="${CONTINUITY_RECON_OUT:-./CONTINUITY_DECK_RECON.txt}"

# Flatpak app-private config, as seen from the HOST side.
rd_app="${CONTINUITY_RD_APP_DIR:-$HOME/.var/app/net.retrodeck.retrodeck}"
rd_json="$rd_app/config/retrodeck/retrodeck.json"
rd_cfg_legacy="$rd_app/config/retrodeck/retrodeck.cfg"
ra_cfg="$rd_app/config/retroarch/retroarch.cfg"

out() { printf '%s\n' "$*" >>"$report"; }
section() { out ""; out "== $* =="; }

# json_path <key> — pull "key": "value" out of retrodeck.json (no jq
# dependency on the host).
json_path() {
    sed -n 's/.*"'"$1"'": *"\([^"]*\)".*/\1/p' "$rd_json" 2>/dev/null | head -1
}

# cfg_value <key> <file> — key = "value" from an ini-ish cfg.
cfg_value() {
    sed -n 's/^'"$1"' *= *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$2" 2>/dev/null | head -1
}

: >"$report"
out "Continuity Deck recon — $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
out "host user: $(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")"
out "uname: $(uname -srm 2>/dev/null || printf 'unknown')"
[ -f /etc/os-release ] && out "os-release: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"

section "RetroDeck installation"
if command -v flatpak >/dev/null 2>&1; then
    ver=$(flatpak info net.retrodeck.retrodeck 2>/dev/null | sed -n 's/^ *Version: *//p' | head -1)
    out "flatpak app: ${ver:+installed, version $ver}${ver:-NOT FOUND (flatpak info returned nothing)}"
else
    out "flatpak: command not found on host (unexpected on SteamOS)"
fi
out "config json ($rd_json): $( [ -f "$rd_json" ] && printf 'present' || printf 'MISSING')"
out "legacy cfg ($rd_cfg_legacy): $( [ -f "$rd_cfg_legacy" ] && printf 'present' || printf 'absent')"

section "RetroDeck paths (from retrodeck.json)"
if [ -f "$rd_json" ]; then
    for key in rd_home_path roms_path saves_path states_path bios_path sdcard; do
        val=$(json_path "$key")
        if [ -n "$val" ]; then
            if [ -d "$val" ]; then exists="exists"; else exists="PATH MISSING"; fi
            out "$key = $val ($exists)"
        else
            out "$key = (not found in json)"
        fi
    done
elif [ -f "$rd_cfg_legacy" ]; then
    out "json missing — legacy cfg values:"
    for key in rdhome roms_folder saves_folder states_folder; do
        out "$key = $(cfg_value "$key" "$rd_cfg_legacy")"
    done
else
    out "NO RetroDeck config found — has RetroDeck been launched once?"
fi

section "RetroArch save settings (live retroarch.cfg)"
if [ -f "$ra_cfg" ]; then
    for key in savefile_directory savestate_directory save_file_compression \
               savestate_file_compression sort_savefiles_enable \
               sort_savefiles_by_content_enable sort_savestates_enable \
               sort_savestates_by_content_enable savefiles_in_content_dir; do
        out "$key = $(cfg_value "$key" "$ra_cfg")"
    done
else
    out "retroarch.cfg not found at $ra_cfg"
fi

section "Saves tree (real filenames + container sniff)"
saves_root=$(json_path saves_path)
[ -z "$saves_root" ] && [ -f "$rd_cfg_legacy" ] && saves_root=$(cfg_value saves_folder "$rd_cfg_legacy")
if [ -n "$saves_root" ] && [ -d "$saves_root" ]; then
    out "saves root: $saves_root"
    out "-- per-directory file counts --"
    find "$saves_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r d; do
        n=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
        out "  ${d##*/}: $n files"
    done
    out "-- sample save filenames (up to 25) --"
    find "$saves_root" -type f \( -name '*.srm' -o -name '*.sav' -o -name '*.rtc' \) 2>/dev/null | head -25 | while IFS= read -r f; do
        out "  ${f#"$saves_root"/}"
    done
    # Same 8-byte hex sniff as core pm_container_class (#RZIPv\x01# —
    # byte 7 is raw 0x01; see tools/rzip/rzip.c RZIP_MAGIC).
    out "-- container sniff (.srm/.sav: RZIP magic vs raw) --"
    find "$saves_root" -type f \( -name '*.srm' -o -name '*.sav' \) 2>/dev/null | head -200 | {
        rz=0; raw=0
        while IFS= read -r f; do
            magic=$(dd if="$f" bs=1 count=8 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
            if [ "$magic" = "23525a4950760123" ]; then
                rz=$((rz + 1)); out "  COMPRESSED: ${f#"$saves_root"/}"
            else
                raw=$((raw + 1))
            fi
        done
        out "  raw: $raw, rzip-compressed: $rz (of first 200 scanned)"
    }
else
    out "saves root not found (${saves_root:-unset})"
fi

section "ROMs tree (top-level system dirs)"
roms_root=$(json_path roms_path)
[ -z "$roms_root" ] && [ -f "$rd_cfg_legacy" ] && roms_root=$(cfg_value roms_folder "$rd_cfg_legacy")
if [ -n "$roms_root" ] && [ -d "$roms_root" ]; then
    out "roms root: $roms_root"
    find "$roms_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | while IFS= read -r d; do
        n=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
        [ "$n" -gt 0 ] && out "  ${d##*/}: $n files"
    done
    out "-- nested ROM dirs (would break content-dir save sorting) --"
    nested=$(find "$roms_root" -mindepth 3 -type f 2>/dev/null | head -5)
    if [ -n "$nested" ]; then
        out "$nested"
    else
        out "  none found (flat roms/<system>/ layout — good)"
    fi
else
    out "roms root not found (${roms_root:-unset})"
fi

section "Host tooling (daemon prerequisites)"
for tool in git systemctl inotifywait curl ping jq bash; do
    if command -v "$tool" >/dev/null 2>&1; then
        out "$tool: $(command -v "$tool") ($("$tool" --version 2>/dev/null | head -1 || printf 'version unknown'))"
    else
        out "$tool: NOT FOUND"
    fi
done
if command -v systemctl >/dev/null 2>&1; then
    out "systemd --user reachable: $(systemctl --user is-system-running 2>/dev/null || printf 'NO (check from a desktop-mode terminal)')"
fi

section "Network"
if ping -c 1 -W 3 github.com >/dev/null 2>&1; then
    out "github.com reachable via ping"
elif command -v curl >/dev/null 2>&1 && curl -sI -m 5 https://github.com >/dev/null 2>&1; then
    out "github.com reachable via curl (ICMP blocked?)"
else
    out "github.com NOT reachable (offline is fine for recon)"
fi

out ""
out "Recon complete. Send this file back: $report"
printf 'Wrote %s\n' "$report"
cat "$report"
