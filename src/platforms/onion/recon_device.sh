#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Continuity — Sprint 3.1 on-device recon for the Anbernic RG40XX V.
#
# Run ON THE DEVICE (SSH or terminal app):
#     sh /mnt/SDCARD/recon_continuity.sh
# Writes a single report file (default: <SD root>/CONTINUITY_RECON.txt)
# and prints its path when done. Read-only except for that report and a
# self-cleaning probe directory; never reads WiFi credentials; masks any
# setup.json PAT to its length.
#
# Deliberate deviation from the house `set -e` rule: this is a one-shot
# diagnostic on unknown firmware — an unguarded probe failing must cost
# one report line, not the whole report (the field-notes lesson: every
# lost fact is an SD-card round-trip). All probes are individually
# guarded instead.
#
# Every probe is best-effort: a missing tool or path is reported, never
# fatal. The report answers the Sprint 3.1 spec's decision gates:
#   - Gate 0: which firmware is ACTUALLY installed (Onion has no known
#     H700 build — muOS / Knulli / ROCKNIX / stock are the candidates)
#   - arch + libc + kernel (does the Brick's static aarch64 git port?)
#   - exec semantics on the SD mount (noexec? symlinks? /proc/self/exe?)
#   - real save/state files and RetroArch config (name style, RZIP risk)
#   - boot-hook mechanism, network, clock
#
# Test/debug overrides:
#   RC_OUT         report path (default <SD>/CONTINUITY_RECON.txt)
#   RC_SD_ROOT     SD mount point (default: autodetect)
#   RC_NET=0       skip network probes
#   RC_FORCE_OD_B  force the octal od fallback (exercises minimal-od path)
#   RC_NO_MAIN=1   source-only (unit tests call functions directly)

readonly RC_VERSION="sprint3.1-recon-1"

RC_OUT="${RC_OUT:-}"
RC_SD_ROOT="${RC_SD_ROOT:-}"
RC_NET="${RC_NET:-1}"

# ---------------------------------------------------------------- emit

rc_emit() {
    printf '%s\n' "$*" >> "$RC_OUT"
}

rc_section() {
    {
        printf '\n=== %s ===\n' "$*"
    } >> "$RC_OUT"
    printf 'recon: %s\n' "$*"
}

# rc_cmd <label> <cmd> [args...] — run a command, report rc + first
# 2000 bytes of output. Never fails the script.
rc_cmd() {
    local label rc out
    label="$1"; shift
    rc=0
    out=$("$@" 2>&1) || rc=$?
    out=$(printf '%s' "$out" | head -c 2000)
    rc_emit "-- $label (rc=$rc)"
    [ -n "$out" ] && rc_emit "$out"
}

# rc_file <label> <path> [max_lines] — dump a file if readable.
rc_file() {
    local label f n
    label="$1"; f="$2"; n="${3:-30}"
    if [ -r "$f" ]; then
        rc_emit "-- $label ($f)"
        head -n "$n" "$f" 2>/dev/null | tr -d '\0' >> "$RC_OUT" || true
        rc_emit ""
    else
        rc_emit "-- $label: $f absent/unreadable"
    fi
}

# rc_marker <path> — one-line exists/absent for firmware fingerprinting.
rc_marker() {
    if [ -e "$1" ]; then
        rc_emit "marker: $1 EXISTS"
    else
        rc_emit "marker: $1 absent"
    fi
}

# ------------------------------------------------------- byte probes

# rc_bytes <file> <count> — print the first <count> bytes as decimal
# values, one space-separated line. Tries full od first; falls back to
# minimal busybox `od -b` (octal). Empty output = no usable od.
rc_bytes() {
    local f n line dec b
    f="$1"; n="$2"
    if [ -z "${RC_FORCE_OD_B:-}" ]; then
        line=$(dd if="$f" bs=1 count="$n" 2>/dev/null | od -An -v -tu1 2>/dev/null | tr '\n' ' ' | tr -s ' ') || true
        case "$line" in
            *[0-9]*) printf '%s\n' "$line"; return 0 ;;
        esac
    fi
    # Minimal od: octal bytes with an address column per line.
    line=$(dd if="$f" bs=1 count="$n" 2>/dev/null | od -b 2>/dev/null | sed 's/^[^ ]*//' | tr '\n' ' ' | tr -s ' ') || true
    dec=""
    for b in $line; do
        case "$b" in
            ''|*[!0-7]*) continue ;;
        esac
        dec="$dec $((0$b))"
    done
    printf '%s\n' "$dec"
}

# rc_elf_desc <file> — classify an executable: ELF class + machine.
# The single most important probe: does this userland match the Brick's
# aarch64 static binaries?
rc_elf_desc() {
    local f b1 b2 b3 b4 class endian m_lo m_hi mach cname ename mname
    f="$1"
    if [ ! -r "$f" ]; then
        printf 'unreadable\n'
        return 0
    fi
    # shellcheck disable=SC2046
    set -- $(rc_bytes "$f" 20)
    if [ "$#" -lt 20 ]; then
        printf 'short/unknown (od limited or tiny file)\n'
        return 0
    fi
    b1="$1"; b2="$2"; b3="$3"; b4="$4"; class="$5"; endian="$6"
    shift 18
    m_lo="$1"; m_hi="$2"
    if [ "$b1" != "127" ] || [ "$b2" != "69" ] || [ "$b3" != "76" ] || [ "$b4" != "70" ]; then
        printf 'not ELF (script or data)\n'
        return 0
    fi
    case "$class" in
        1) cname="ELF32" ;;
        2) cname="ELF64" ;;
        *) cname="ELF?" ;;
    esac
    case "$endian" in
        1) ename="LE"; mach=$((m_lo + m_hi * 256)) ;;
        2) ename="BE"; mach=$((m_hi + m_lo * 256)) ;;
        *) ename="??"; mach=$((m_lo + m_hi * 256)) ;;
    esac
    case "$mach" in
        183) mname="aarch64" ;;
        40)  mname="arm32" ;;
        62)  mname="x86_64" ;;
        3)   mname="x86" ;;
        8)   mname="mips" ;;
        243) mname="riscv" ;;
        *)   mname="machine=$mach" ;;
    esac
    printf '%s %s %s\n' "$cname" "$ename" "$mname"
}

# rc_is_rzip <file> — does the file start with the RZIP magic '#RZIPv'?
rc_is_rzip() {
    local head6
    head6=$(dd if="$1" bs=1 count=6 2>/dev/null) || true
    [ "$head6" = "#RZIPv" ]
}

# ------------------------------------------------------ SD detection

rc_detect_sd() {
    local d
    if [ -n "$RC_SD_ROOT" ] && [ -d "$RC_SD_ROOT" ]; then
        printf '%s\n' "$RC_SD_ROOT"
        return 0
    fi
    for d in /mnt/SDCARD /mnt/sdcard /mnt/mmc /storage/roms /userdata /mnt/SDCARD2 /media/sdcard; do
        if [ -d "$d" ]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    printf '%s\n' "$(pwd)"
}

# ---------------------------------------------------------- sections

rc_sec_identity() {
    rc_section "kernel / cpu"
    rc_cmd "uname -a" uname -a
    rc_cmd "uname -m" uname -m
    rc_file "/proc/version" /proc/version 2
    rc_file "/proc/cmdline" /proc/cmdline 2
    if [ -r /proc/device-tree/model ]; then
        rc_emit "-- device-tree model"
        tr -d '\0' < /proc/device-tree/model >> "$RC_OUT" 2>/dev/null || true
        rc_emit ""
    else
        rc_emit "-- device-tree model: absent"
    fi
    rc_emit "-- cpuinfo (filtered)"
    grep -i 'model\|processor\|features\|hardware\|implementer\|part' /proc/cpuinfo 2>/dev/null | head -20 >> "$RC_OUT" || true
    rc_emit "-- meminfo (head)"
    head -3 /proc/meminfo 2>/dev/null >> "$RC_OUT" || true
}

rc_sec_firmware() {
    rc_section "firmware identity (Gate 0)"
    rc_file "/etc/os-release" /etc/os-release 20
    rc_file "/etc/issue" /etc/issue 3
    rc_file "/etc/hostname" /etc/hostname 1
    rc_cmd "ls /" ls /
    rc_cmd "ls /mnt" ls /mnt
    # Firmware markers: Onion, muOS, Knulli/Batocera, ROCKNIX/JELOS, stock.
    rc_marker "$RC_SD/.tmp_update"
    rc_marker "/opt/muos"
    rc_marker "/run/muos"
    rc_marker "/usr/share/batocera"
    rc_marker "/userdata/system"
    rc_marker "/storage/.config"
    rc_marker "/etc/batocera-version"
    if [ -d "$RC_SD/.tmp_update" ]; then
        rc_cmd "ls .tmp_update" ls "$RC_SD/.tmp_update"
        find "$RC_SD/.tmp_update" -maxdepth 2 -iname '*version*' -type f 2>/dev/null | head -3 |
        while IFS= read -r vf; do
            rc_file "version file" "$vf" 3
        done
    fi
    if [ -d /opt/muos ]; then
        rc_cmd "ls /opt/muos" ls /opt/muos
        find /opt/muos -maxdepth 2 -iname '*version*' 2>/dev/null | head -3 |
        while IFS= read -r vf; do
            rc_file "muos version" "$vf" 3
        done
    fi
    command -v batocera-version >/dev/null 2>&1 && rc_cmd "batocera-version" batocera-version
}

rc_sec_userland() {
    local sh_real bb
    rc_section "shell / userland"
    rc_cmd "id" id
    rc_emit "PATH=$PATH"
    sh_real=$(readlink -f /bin/sh 2>/dev/null || printf '/bin/sh')
    rc_emit "/bin/sh -> $sh_real"
    rc_emit "sh ELF: $(rc_elf_desc "$sh_real")"
    bb=$(command -v busybox 2>/dev/null) || true
    if [ -n "$bb" ]; then
        rc_emit "busybox at $bb: $(rc_elf_desc "$bb")"
        rc_cmd "busybox banner" sh -c 'busybox 2>&1 | head -2'
        rc_cmd "applet count" sh -c 'busybox --list 2>/dev/null | wc -l'
    else
        rc_emit "busybox: not on PATH"
    fi
    rc_emit "-- libc / dynamic linker"
    # shellcheck disable=SC2012
    ls /lib /lib64 /usr/lib 2>/dev/null | grep -i 'ld-\|libc' | head -10 >> "$RC_OUT" || true
    command -v ldd >/dev/null 2>&1 && rc_cmd "ldd --version" sh -c 'ldd --version 2>&1 | head -1'
    rc_emit "-- tool inventory"
    for t in git wget curl ping ssh scp inotifywait find cmp cut sed awk grep tr od dd sha256sum md5sum date mktemp df stat readlink timeout sync retroarch; do
        rc_emit "  $t: $(command -v "$t" 2>/dev/null || printf 'absent')"
    done
}

rc_sec_git() {
    local gitbin
    rc_section "git"
    gitbin=$(command -v git 2>/dev/null) || true
    if [ -z "$gitbin" ]; then
        rc_emit "no system git on PATH (bundled git required, as on the Brick)"
        return 0
    fi
    rc_emit "git at $gitbin: $(rc_elf_desc "$gitbin")"
    rc_cmd "git --version" git --version
    rc_cmd "git --exec-path" git --exec-path
    rc_cmd "https helper present" sh -c 'ls "$(git --exec-path 2>/dev/null)" 2>/dev/null | grep remote | head -5'
}

rc_sec_storage() {
    rc_section "mounts / storage"
    rc_file "/proc/mounts" /proc/mounts 40
    rc_cmd "df -k" sh -c 'df -k 2>/dev/null | head -15'
    rc_emit "SD root chosen: $RC_SD"
    rc_cmd "ls -la SD root" sh -c "ls -la '$RC_SD' 2>/dev/null | head -50"
}

rc_sec_exec_semantics() {
    local probe src copy rc out link
    rc_section "exec semantics on SD (Fable core)"
    probe="$RC_SD/.continuity_recon.$$"
    if ! mkdir "$probe" 2>/dev/null; then
        rc_emit "SD root not writable — exec probes skipped"
        return 0
    fi
    src=$(command -v busybox 2>/dev/null) || true
    [ -n "$src" ] || src=$(readlink -f /bin/sh 2>/dev/null) || true
    if [ -n "$src" ] && [ -r "$src" ]; then
        copy="$probe/execprobe"
        if cp "$src" "$copy" 2>/dev/null && chmod +x "$copy" 2>/dev/null; then
            rc=0
            out=$("$copy" true </dev/null 2>&1) || rc=$?
            rc_emit "exec-from-SD ($src copied): rc=$rc ${out:+out=$(printf '%s' "$out" | head -c 120)}"
            case "$rc" in
                126|127) rc_emit "  ^ rc $rc suggests noexec mount or wrong loader — CRITICAL for bundled binaries" ;;
            esac
        else
            rc_emit "exec-from-SD: could not copy probe binary"
        fi
    else
        rc_emit "exec-from-SD: no source binary found to copy"
    fi
    link="$probe/symlink_test"
    if ln -s "$probe" "$link" 2>/dev/null; then
        rc_emit "symlinks on SD: SUPPORTED (unlike the Brick's exFAT)"
    else
        rc_emit "symlinks on SD: NOT supported (ship real file copies, as on the Brick)"
    fi
    rc_emit "/proc/self/exe: $(readlink /proc/self/exe 2>/dev/null || printf 'unreadable — applet self-exec tier would fail')"
    : > "$probe/mtime_test" 2>/dev/null || true
    rc_cmd "mtime stat" sh -c "stat -c '%Y %y' '$probe/mtime_test' 2>/dev/null || ls -l '$probe/mtime_test'"
    rm -rf "$probe" 2>/dev/null || true
    sync 2>/dev/null || true
}

rc_sec_saves() {
    local root f
    rc_section "saves / roms landscape"
    for root in "$RC_SD/Saves" "$RC_SD/Saves/CurrentProfile/saves" "$RC_SD/ROMS" "$RC_SD/Roms" "$RC_SD/RetroArch" "$RC_SD/MUOS" /userdata/saves /storage/roms; do
        if [ -d "$root" ]; then
            rc_emit "-- dirs under $root (depth 2)"
            find "$root" -maxdepth 2 -type d 2>/dev/null | head -30 >> "$RC_OUT" || true
        fi
    done
    rc_emit "-- save files (.srm/.sav, first 40)"
    find "$RC_SD" /userdata /storage -maxdepth 6 \
        \( -name '*.srm' -o -name '*.sav' \) -type f 2>/dev/null | head -40 |
    while IFS= read -r f; do
        rc_emit "$(ls -l "$f" 2>/dev/null || printf '%s' "$f")"
    done
    rc_emit "-- first-bytes of up to 6 saves (RZIP magic check)"
    find "$RC_SD" /userdata /storage -maxdepth 6 \
        \( -name '*.srm' -o -name '*.sav' \) -type f 2>/dev/null | head -6 |
    while IFS= read -r f; do
        if rc_is_rzip "$f"; then
            rc_emit "$f rzip: yes (#RZIPv container — quarantine path applies)"
        else
            rc_emit "$f rzip: no bytes: $(rc_bytes "$f" 12)"
        fi
    done
    rc_emit "-- save states (.state*/.st0-9, first 20)"
    find "$RC_SD" /userdata /storage -maxdepth 6 \
        \( -name '*.state' -o -name '*.state[0-9]*' -o -name '*.st[0-9]' \) -type f 2>/dev/null | head -20 |
    while IFS= read -r f; do
        rc_emit "$(ls -l "$f" 2>/dev/null || printf '%s' "$f")"
    done
    rc_emit "-- rtc files (first 10)"
    find "$RC_SD" /userdata /storage -maxdepth 6 -name '*.rtc' -type f 2>/dev/null | head -10 >> "$RC_OUT" || true
}

rc_sec_retroarch() {
    local cfg
    rc_section "retroarch config"
    find "$RC_SD" /userdata /storage /root -maxdepth 5 -name 'retroarch.cfg' -type f 2>/dev/null | head -3 |
    while IFS= read -r cfg; do
        rc_emit "-- $cfg (save-relevant keys)"
        grep -E '^(savefile_directory|savestate_directory|sort_savefiles_enable|sort_savefiles_by_content_enable|sort_savestates_enable|save_file_compression|savestate_compression|autosave_interval|block_sram_overwrite)' \
            "$cfg" 2>/dev/null | head -12 >> "$RC_OUT" || true
    done
}

rc_sec_boot_hooks() {
    rc_section "boot / autostart mechanism"
    rc_file "/etc/inittab" /etc/inittab 30
    rc_cmd "ls /etc/init.d" sh -c 'ls /etc/init.d 2>/dev/null | head -20'
    rc_marker "/userdata/system/custom.sh"
    rc_marker "/storage/.config/autostart.sh"
    rc_marker "$RC_SD/.tmp_update/updater"
    rc_emit "-- auto*/custom*/boot* scripts near SD root (depth 3)"
    find "$RC_SD" -maxdepth 3 \( -name 'auto*.sh' -o -name 'custom*.sh' -o -name 'boot*.sh' -o -name 'updater' \) 2>/dev/null | head -15 >> "$RC_OUT" || true
}

rc_sec_network() {
    rc_section "network / clock"
    rc_cmd "date" date
    if [ "$RC_NET" = "0" ]; then
        rc_emit "network probes skipped (RC_NET=0)"
        return 0
    fi
    rc_cmd "interfaces" sh -c 'ip addr 2>/dev/null | head -25 || ifconfig 2>/dev/null | head -25'
    rc_file "/etc/resolv.conf" /etc/resolv.conf 5
    if command -v timeout >/dev/null 2>&1; then
        rc_cmd "ping github.com" timeout 8 ping -c 1 -W 3 github.com
        rc_cmd "https reach" timeout 10 wget --spider -q https://github.com
    else
        rc_cmd "ping github.com" ping -c 1 -W 3 github.com
        rc_cmd "https reach" wget --spider -q -T 8 https://github.com
    fi
}

rc_sec_setup_json() {
    local f url name pat
    rc_section "setup.json (masked)"
    f="$RC_SD/setup.json"
    if [ ! -f "$f" ]; then
        rc_emit "absent"
        return 0
    fi
    url=$(sed -n 's/^[[:space:]]*"repo_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
    name=$(sed -n 's/^[[:space:]]*"device_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
    pat=$(sed -n 's/^[[:space:]]*"pat"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
    rc_emit "repo=$(printf '%s' "$url" | sed 's|://[^/@]*@|://|') device=$name pat=$([ -n "$pat" ] && printf 'present(%s chars)' "${#pat}" || printf 'MISSING')"
}

rc_sec_input_misc() {
    rc_section "input / misc"
    rc_cmd "ls /dev/input" ls /dev/input
    rc_cmd "uptime" uptime
    rc_cmd "tmp writable" sh -c 'f=$(mktemp 2>/dev/null) && rm -f "$f" && printf yes || printf no'
}

# --------------------------------------------------------------- main

rc_main() {
    RC_SD=$(rc_detect_sd)
    if [ -z "$RC_OUT" ]; then
        RC_OUT="$RC_SD/CONTINUITY_RECON.txt"
    fi
    : > "$RC_OUT" || {
        printf 'recon: cannot write %s\n' "$RC_OUT" >&2
        exit 1
    }
    rc_emit "=== Continuity device recon $RC_VERSION $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) ==="

    rc_sec_identity
    rc_sec_firmware
    rc_sec_userland
    rc_sec_git
    rc_sec_storage
    rc_sec_exec_semantics
    rc_sec_saves
    rc_sec_retroarch
    rc_sec_boot_hooks
    rc_sec_network
    rc_sec_setup_json
    rc_sec_input_misc

    rc_emit ""
    rc_emit "=== recon complete ==="
    sync 2>/dev/null || true
    printf 'recon: report written to %s\n' "$RC_OUT"
}

if [ -z "${RC_NO_MAIN:-}" ]; then
    rc_main
fi
