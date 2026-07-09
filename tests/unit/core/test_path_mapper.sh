#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
set -e

# Unit tests for path_mapper.sh (src/core/path_mapper.sh)
# Self-contained: creates temp dirs, installs fixtures, cleans up on EXIT.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TEST_TMPDIR=$(mktemp -d)
export TEST_TMPDIR
trap 'rm -rf "$TEST_TMPDIR"' EXIT

passed=0
failed=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected empty, got: %s\n' "$desc" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_contains_line() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s\n' "$haystack" | grep -qF "$needle"; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected line: %s\n  in output:\n%s\n' "$desc" "$needle" "$haystack" >&2
        failed=$((failed + 1))
    fi
}

# Source test PAL and core modules
. "$REPO_ROOT/tests/fixtures/pal_test.sh"
. "$REPO_ROOT/src/core/pal.sh"
. "$REPO_ROOT/src/core/path_mapper.sh"
pal_init

# =====================================================================
# Test each platform map loads without error
# =====================================================================

for platform in nextui onion retrodeck retroarch_android; do
    cp "$REPO_ROOT/config/platform_maps/${platform}.json" "$TEST_TMPDIR/platform_map.json"
    pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null
    result=$?
    assert_eq "pm_load_platform_map loads $platform" "0" "$result"
done

# =====================================================================
# NextUI map tests
# =====================================================================

cp "$REPO_ROOT/config/platform_maps/nextui.json" "$TEST_TMPDIR/platform_map.json"
CONTINUITY_SAVES_ROOT="/mnt/SDCARD/Saves"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# local_to_repo
result=$(pm_local_to_repo "/mnt/SDCARD/Saves/SFC/super_metroid.srm" 2>/dev/null)
assert_eq "nextui local_to_repo SFC->snes" "snes/super_metroid.srm" "$result"

result=$(pm_local_to_repo "/mnt/SDCARD/Saves/GB/links_awakening.srm" 2>/dev/null)
assert_eq "nextui local_to_repo GB->gb" "gb/links_awakening.srm" "$result"

result=$(pm_local_to_repo "/mnt/SDCARD/Saves/FC/mario.srm" 2>/dev/null)
assert_eq "nextui local_to_repo FC->nes" "nes/mario.srm" "$result"

# repo_to_local
result=$(pm_repo_to_local "snes/super_metroid.srm" 2>/dev/null)
assert_eq "nextui repo_to_local snes->SFC" "/mnt/SDCARD/Saves/SFC/super_metroid.srm" "$result"

result=$(pm_repo_to_local "gb/links_awakening.srm" 2>/dev/null)
assert_eq "nextui repo_to_local gb->GB" "/mnt/SDCARD/Saves/GB/links_awakening.srm" "$result"

result=$(pm_repo_to_local "nes/mario.srm" 2>/dev/null)
assert_eq "nextui repo_to_local nes->FC" "/mnt/SDCARD/Saves/FC/mario.srm" "$result"

# Round-trip NextUI
for sys_pair in "SFC:snes" "GB:gb" "GBA:gba" "FC:nes" "MD:genesis" "PS:ps1"; do
    local_dir=$(printf '%s' "$sys_pair" | sed 's/:.*//')
    canonical=$(printf '%s' "$sys_pair" | sed 's/.*://')
    orig="/mnt/SDCARD/Saves/${local_dir}/game.srm"
    repo=$(pm_local_to_repo "$orig" 2>/dev/null)
    roundtrip=$(pm_repo_to_local "$repo" 2>/dev/null)
    assert_eq "nextui round-trip $local_dir" "$orig" "$roundtrip"
done

# pm_list_watched_dirs NextUI
watched=$(pm_list_watched_dirs 2>/dev/null)
count=$(printf '%s\n' "$watched" | grep -c '.')
assert_eq "nextui watched dirs count" "14" "$count"
assert_contains_line "nextui watched dirs has SFC" "/mnt/SDCARD/Saves/SFC" "$watched"

# =====================================================================
# Onion OS map tests
# =====================================================================

cp "$REPO_ROOT/config/platform_maps/onion.json" "$TEST_TMPDIR/platform_map.json"
CONTINUITY_SAVES_ROOT="/mnt/SDCARD/Saves"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

result=$(pm_local_to_repo "/mnt/SDCARD/Saves/SFC/chrono.srm" 2>/dev/null)
assert_eq "onion local_to_repo SFC->snes" "snes/chrono.srm" "$result"

result=$(pm_repo_to_local "gba/minish.srm" 2>/dev/null)
assert_eq "onion repo_to_local gba->GBA" "/mnt/SDCARD/Saves/GBA/minish.srm" "$result"

orig="/mnt/SDCARD/Saves/GBC/pokemon.srm"
roundtrip=$(pm_repo_to_local "$(pm_local_to_repo "$orig" 2>/dev/null)" 2>/dev/null)
assert_eq "onion round-trip GBC" "$orig" "$roundtrip"

# =====================================================================
# RetroDeck map tests
# =====================================================================

cp "$REPO_ROOT/config/platform_maps/retrodeck.json" "$TEST_TMPDIR/platform_map.json"
CONTINUITY_SAVES_ROOT="/home/user/.var/app/net.retrodeck.retrodeck/data/saves"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

result=$(pm_local_to_repo "/home/user/.var/app/net.retrodeck.retrodeck/data/saves/snes/super_metroid.srm" 2>/dev/null)
assert_eq "retrodeck local_to_repo snes" "snes/super_metroid.srm" "$result"

result=$(pm_local_to_repo "/home/user/.var/app/net.retrodeck.retrodeck/data/saves/megadrive/sonic.srm" 2>/dev/null)
assert_eq "retrodeck local_to_repo megadrive->genesis" "genesis/sonic.srm" "$result"

result=$(pm_repo_to_local "genesis/sonic.srm" 2>/dev/null)
assert_eq "retrodeck repo_to_local genesis->megadrive" "/home/user/.var/app/net.retrodeck.retrodeck/data/saves/megadrive/sonic.srm" "$result"

orig="/home/user/.var/app/net.retrodeck.retrodeck/data/saves/psx/ff7.srm"
roundtrip=$(pm_repo_to_local "$(pm_local_to_repo "$orig" 2>/dev/null)" 2>/dev/null)
assert_eq "retrodeck round-trip psx" "$orig" "$roundtrip"

watched=$(pm_list_watched_dirs 2>/dev/null)
count=$(printf '%s\n' "$watched" | grep -c '.')
assert_eq "retrodeck watched dirs count" "14" "$count"

# =====================================================================
# RetroArch Android map tests (paths with spaces)
# =====================================================================

cp "$REPO_ROOT/config/platform_maps/retroarch_android.json" "$TEST_TMPDIR/platform_map.json"
CONTINUITY_SAVES_ROOT="/storage/emulated/0/RetroArch/saves"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# Paths with spaces
result=$(pm_local_to_repo "/storage/emulated/0/RetroArch/saves/Nintendo - Game Boy/links_awakening.srm" 2>/dev/null)
assert_eq "android local_to_repo Game Boy->gb" "gb/links_awakening.srm" "$result"

result=$(pm_local_to_repo "/storage/emulated/0/RetroArch/saves/Nintendo - Super Nintendo Entertainment System/super_metroid.srm" 2>/dev/null)
assert_eq "android local_to_repo SNES->snes" "snes/super_metroid.srm" "$result"

result=$(pm_local_to_repo "/storage/emulated/0/RetroArch/saves/Sega - Mega Drive - Genesis/sonic.srm" 2>/dev/null)
assert_eq "android local_to_repo Genesis->genesis" "genesis/sonic.srm" "$result"

result=$(pm_repo_to_local "gb/links_awakening.srm" 2>/dev/null)
assert_eq "android repo_to_local gb->Game Boy" "/storage/emulated/0/RetroArch/saves/Nintendo - Game Boy/links_awakening.srm" "$result"

result=$(pm_repo_to_local "snes/super_metroid.srm" 2>/dev/null)
assert_eq "android repo_to_local snes->SNES" "/storage/emulated/0/RetroArch/saves/Nintendo - Super Nintendo Entertainment System/super_metroid.srm" "$result"

# Round-trip with spaces
orig="/storage/emulated/0/RetroArch/saves/Nintendo - Game Boy/links_awakening.srm"
roundtrip=$(pm_repo_to_local "$(pm_local_to_repo "$orig" 2>/dev/null)" 2>/dev/null)
assert_eq "android round-trip Game Boy" "$orig" "$roundtrip"

orig="/storage/emulated/0/RetroArch/saves/NEC - PC Engine - TurboGrafx 16/game.srm"
roundtrip=$(pm_repo_to_local "$(pm_local_to_repo "$orig" 2>/dev/null)" 2>/dev/null)
assert_eq "android round-trip PCE" "$orig" "$roundtrip"

# pm_list_watched_dirs with spaces
watched=$(pm_list_watched_dirs 2>/dev/null)
count=$(printf '%s\n' "$watched" | grep -c '.')
assert_eq "android watched dirs count" "14" "$count"
assert_contains_line "android watched has Game Boy" "/storage/emulated/0/RetroArch/saves/Nintendo - Game Boy" "$watched"

# =====================================================================
# Unknown system directory tests (using NextUI map)
# =====================================================================

cp "$REPO_ROOT/config/platform_maps/nextui.json" "$TEST_TMPDIR/platform_map.json"
CONTINUITY_SAVES_ROOT="/mnt/SDCARD/Saves"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# Unknown local dir
stdout=$(pm_local_to_repo "/mnt/SDCARD/Saves/UNKNOWN/game.srm" 2>/dev/null || true)
assert_empty "unknown local dir prints nothing to stdout" "$stdout"

pm_local_to_repo "/mnt/SDCARD/Saves/UNKNOWN/game.srm" >/dev/null 2>"$TEST_TMPDIR/stderr_local" || true
stderr_content=$(cat "$TEST_TMPDIR/stderr_local")
assert_contains_line "unknown local dir logs to stderr" "UNKNOWN" "$stderr_content"

result=0
pm_local_to_repo "/mnt/SDCARD/Saves/UNKNOWN/game.srm" >/dev/null 2>/dev/null || result=$?
assert_eq "unknown local dir returns 1" "1" "$result"

# Unknown canonical name
stdout=$(pm_repo_to_local "unknownsys/game.srm" 2>/dev/null || true)
assert_empty "unknown canonical prints nothing to stdout" "$stdout"

pm_repo_to_local "unknownsys/game.srm" >/dev/null 2>"$TEST_TMPDIR/stderr_repo" || true
stderr_content=$(cat "$TEST_TMPDIR/stderr_repo")
assert_contains_line "unknown canonical logs to stderr" "unknownsys" "$stderr_content"

result=0
pm_repo_to_local "unknownsys/game.srm" >/dev/null 2>/dev/null || result=$?
assert_eq "unknown canonical returns 1" "1" "$result"

# =====================================================================
# Results
# =====================================================================

printf '\ntest_path_mapper: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
