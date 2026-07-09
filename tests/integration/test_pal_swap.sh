#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2317
set -e

# Integration test: proves path_mapper.sh is PAL-agnostic
# Loads the mapper with two different PALs (test PAL and simulated NextUI PAL)
# and asserts both produce identical translations for the same platform map.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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

# Copy NextUI platform map for both subshells
cp "$REPO_ROOT/config/platform_maps/nextui.json" "$TEST_TMPDIR/platform_map.json"

# =====================================================================
# Subshell A: Test PAL
# =====================================================================

(
    export TEST_TMPDIR
    . "$REPO_ROOT/tests/fixtures/pal_test.sh"
    . "$REPO_ROOT/src/core/pal.sh"
    . "$REPO_ROOT/src/core/path_mapper.sh"

    pal_init 2>/dev/null
    pal_validate 2>/dev/null || { printf 'VALIDATE_FAIL\n'; exit 1; }

    CONTINUITY_SAVES_ROOT="/mnt/SDCARD/Saves"
    pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

    # Translate 5 representative paths
    pm_local_to_repo "/mnt/SDCARD/Saves/SFC/super_metroid.srm" 2>/dev/null
    pm_local_to_repo "/mnt/SDCARD/Saves/GB/links_awakening.srm" 2>/dev/null
    pm_local_to_repo "/mnt/SDCARD/Saves/GBA/minish_cap.srm" 2>/dev/null
    pm_repo_to_local "genesis/sonic.srm" 2>/dev/null
    pm_repo_to_local "ps1/ff7.srm" 2>/dev/null

    # Unknown system (should produce nothing to stdout, return 1)
    pm_local_to_repo "/mnt/SDCARD/Saves/UNKNOWN/game.srm" 2>/dev/null || true
) > "$TEST_TMPDIR/output_a"

# =====================================================================
# Subshell B: Simulated NextUI PAL
# =====================================================================

(
    # Set up a simulated NextUI PAL without sourcing pal_nextui.sh
    # (which points to hardware paths)
    CONTINUITY_SAVES_ROOT="/mnt/SDCARD/Saves"
    CONTINUITY_REPO_DIR="$TEST_TMPDIR/repo"
    CONTINUITY_PLATFORM="nextui"
    CONTINUITY_GIT_BIN="git"
    CONTINUITY_DEVICE_NAME="nextui-sim"

    mkdir -p "$CONTINUITY_REPO_DIR/.continuity"
    printf '%s' "$CONTINUITY_DEVICE_NAME" > "$CONTINUITY_REPO_DIR/.continuity/device_name"

    pal_init() { return 0; }
    pal_is_online() { return 0; }
    pal_log() { printf '[%s] %s\n' "$1" "$2" >&2; }
    pal_get_platform_map() { printf '%s\n' "$TEST_TMPDIR/platform_map.json"; }

    . "$REPO_ROOT/src/core/pal.sh"
    . "$REPO_ROOT/src/core/path_mapper.sh"

    pal_validate 2>/dev/null || { printf 'VALIDATE_FAIL\n'; exit 1; }

    pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

    # Same 5 translations
    pm_local_to_repo "/mnt/SDCARD/Saves/SFC/super_metroid.srm" 2>/dev/null
    pm_local_to_repo "/mnt/SDCARD/Saves/GB/links_awakening.srm" 2>/dev/null
    pm_local_to_repo "/mnt/SDCARD/Saves/GBA/minish_cap.srm" 2>/dev/null
    pm_repo_to_local "genesis/sonic.srm" 2>/dev/null
    pm_repo_to_local "ps1/ff7.srm" 2>/dev/null

    # Unknown system
    pm_local_to_repo "/mnt/SDCARD/Saves/UNKNOWN/game.srm" 2>/dev/null || true
) > "$TEST_TMPDIR/output_b"

# =====================================================================
# Compare results
# =====================================================================

output_a=$(cat "$TEST_TMPDIR/output_a")
output_b=$(cat "$TEST_TMPDIR/output_b")

# Check neither reported validation failure
case "$output_a" in
    *VALIDATE_FAIL*) printf 'FAIL: Test PAL validation failed\n' >&2; failed=$((failed + 1)) ;;
    *) passed=$((passed + 1)) ;;
esac

case "$output_b" in
    *VALIDATE_FAIL*) printf 'FAIL: NextUI sim PAL validation failed\n' >&2; failed=$((failed + 1)) ;;
    *) passed=$((passed + 1)) ;;
esac

# Outputs must be identical
assert_eq "test PAL and NextUI sim produce identical output" "$output_a" "$output_b"

# Verify expected translations are present
assert_eq "output contains snes translation" "snes/super_metroid.srm" "$(printf '%s\n' "$output_a" | sed -n '1p')"
assert_eq "output contains gb translation" "gb/links_awakening.srm" "$(printf '%s\n' "$output_a" | sed -n '2p')"
assert_eq "output contains gba translation" "gba/minish_cap.srm" "$(printf '%s\n' "$output_a" | sed -n '3p')"
assert_eq "output contains genesis reverse" "/mnt/SDCARD/Saves/MD/sonic.srm" "$(printf '%s\n' "$output_a" | sed -n '4p')"
assert_eq "output contains ps1 reverse" "/mnt/SDCARD/Saves/PS/ff7.srm" "$(printf '%s\n' "$output_a" | sed -n '5p')"

# Unknown system should produce no 6th line
line6=$(printf '%s\n' "$output_a" | sed -n '6p')
assert_eq "unknown system produces no stdout" "" "$line6"

printf '\ntest_pal_swap: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
