#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests — RetroDeck PAL (src/platforms/retrodeck/pal_retrodeck.sh)
# Path derivation from retrodeck.json / legacy .cfg, env-override
# precedence, named failure modes, pal_validate integration.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
PAL="$PROJECT_ROOT/src/platforms/retrodeck/pal_retrodeck.sh"

passed=0
failed=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected rc: %s  actual rc: %s\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text lacks: %s\n  text: %s\n' "$desc" "$pattern" "$text" >&2; failed=$((failed + 1)) ;;
    esac
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# make_rd_json <dir> — write a real-shaped retrodeck.json (paths with
# spaces included) pointing into <dir>.
make_rd_json() {
    local root="$1"
    mkdir -p "$root/rd home/saves" "$root/rd home/states" "$root/rd home/roms" "$root/conf"
    cat > "$root/conf/retrodeck.json" <<EOF
{
 "version": "0.10.9b",
 "paths": {
  "rd_home_path": "$root/rd home",
  "roms_path": "$root/rd home/roms",
  "saves_path": "$root/rd home/saves",
  "states_path": "$root/rd home/states",
  "bios_path": "$root/rd home/bios"
 }
}
EOF
}

# Each case sources the PAL in a subshell with a scrubbed environment so
# source-time derivation runs fresh every time.

# --- 1. Derivation from retrodeck.json ---
d="$TEST_TMPDIR/case1"
make_rd_json "$d"
out=$(
    CONTINUITY_SAVES_ROOT='' CONTINUITY_STATES_ROOT='' CONTINUITY_ROMS_ROOT=''
    unset CONTINUITY_SAVES_ROOT CONTINUITY_STATES_ROOT CONTINUITY_ROMS_ROOT
    CONTINUITY_RD_CONF="$d/conf/retrodeck.json"
    export CONTINUITY_RD_CONF
    . "$PAL"
    printf '%s|%s|%s' "$CONTINUITY_SAVES_ROOT" "$CONTINUITY_STATES_ROOT" "$CONTINUITY_ROMS_ROOT"
)
assert_eq "json derivation (spaces in rdhome)" \
    "$d/rd home/saves|$d/rd home/states|$d/rd home/roms" "$out"

# --- 2. Pre-set env wins over the config ---
out=$(
    CONTINUITY_SAVES_ROOT="/custom/saves"
    export CONTINUITY_SAVES_ROOT
    CONTINUITY_RD_CONF="$d/conf/retrodeck.json"
    export CONTINUITY_RD_CONF
    . "$PAL"
    printf '%s' "$CONTINUITY_SAVES_ROOT"
)
assert_eq "env override wins" "/custom/saves" "$out"

# --- 3. Legacy retrodeck.cfg fallback ---
d2="$TEST_TMPDIR/case3"
mkdir -p "$d2/rdh/saves" "$d2/rdh/roms" "$d2/conf"
cat > "$d2/conf/retrodeck.cfg" <<EOF
version=0.9.4b
rdhome=$d2/rdh
saves_folder="$d2/rdh/saves"
roms_folder=$d2/rdh/roms
EOF
out=$(
    unset CONTINUITY_SAVES_ROOT CONTINUITY_ROMS_ROOT 2>/dev/null || true
    CONTINUITY_RD_CONF="$d2/conf/retrodeck.json"
    CONTINUITY_RD_CONF_LEGACY="$d2/conf/retrodeck.cfg"
    export CONTINUITY_RD_CONF CONTINUITY_RD_CONF_LEGACY
    . "$PAL"
    printf '%s|%s' "$CONTINUITY_SAVES_ROOT" "$CONTINUITY_ROMS_ROOT"
)
assert_eq "legacy cfg fallback (quoted + bare values)" \
    "$d2/rdh/saves|$d2/rdh/roms" "$out"

# --- 4. Missing config -> pal_init fails NAMED ---
d3="$TEST_TMPDIR/case4"
mkdir -p "$d3"
rc=0
err=$(
    unset CONTINUITY_SAVES_ROOT 2>/dev/null || true
    CONTINUITY_RD_CONF="$d3/nope/retrodeck.json"
    export CONTINUITY_RD_CONF
    . "$PAL"
    pal_init 2>&1 >/dev/null
) || rc=$?
assert_rc "missing config: pal_init fails" 1 "$rc"
assert_contains "missing config: named error" "$err" "RetroDeck config not found"

# --- 5. Config present but saves path gone -> named error ---
d4="$TEST_TMPDIR/case5"
make_rd_json "$d4"
rm -rf "$d4/rd home/saves"
rc=0
err=$(
    unset CONTINUITY_SAVES_ROOT 2>/dev/null || true
    CONTINUITY_RD_CONF="$d4/conf/retrodeck.json"
    export CONTINUITY_RD_CONF
    . "$PAL"
    pal_init 2>&1 >/dev/null
) || rc=$?
assert_rc "dead saves path: pal_init fails" 1 "$rc"
assert_contains "dead saves path: named error" "$err" "saves path does not exist"

# --- 6. Missing git -> named error ---
rc=0
err=$(
    unset CONTINUITY_SAVES_ROOT 2>/dev/null || true
    CONTINUITY_RD_CONF="$d/conf/retrodeck.json"
    CONTINUITY_GIT_BIN="/nonexistent/git-binary"
    export CONTINUITY_RD_CONF CONTINUITY_GIT_BIN
    . "$PAL"
    pal_init 2>&1 >/dev/null
) || rc=$?
assert_rc "missing git: pal_init fails" 1 "$rc"
assert_contains "missing git: named error" "$err" "git not found"

# --- 7. Not enrolled (no device_name) -> named error ---
rc=0
err=$(
    unset CONTINUITY_SAVES_ROOT 2>/dev/null || true
    CONTINUITY_RD_CONF="$d/conf/retrodeck.json"
    CONTINUITY_REPO_DIR="$TEST_TMPDIR/case7-repo"
    export CONTINUITY_RD_CONF CONTINUITY_REPO_DIR
    . "$PAL"
    pal_init 2>&1 >/dev/null
) || rc=$?
assert_rc "not enrolled: pal_init fails" 1 "$rc"
assert_contains "not enrolled: named error" "$err" "enrollment incomplete"

# --- 8. Fully enrolled sandbox -> pal_init + pal_validate pass ---
d5="$TEST_TMPDIR/case8"
make_rd_json "$d5"
mkdir -p "$d5/repo/.continuity"
printf 'deck-test' > "$d5/repo/.continuity/device_name"
out=$(
    unset CONTINUITY_SAVES_ROOT 2>/dev/null || true
    CONTINUITY_RD_CONF="$d5/conf/retrodeck.json"
    CONTINUITY_REPO_DIR="$d5/repo"
    export CONTINUITY_RD_CONF CONTINUITY_REPO_DIR
    . "$PAL"
    . "$PROJECT_ROOT/src/core/pal.sh"
    pal_init 2>/dev/null || { printf 'INIT_FAIL'; exit 1; }
    pal_validate 2>/dev/null || { printf 'VALIDATE_FAIL'; exit 1; }
    printf '%s|%s' "$CONTINUITY_DEVICE_NAME" "$CONTINUITY_PLATFORM"
)
assert_eq "enrolled: init+validate pass, device name read" "deck-test|retrodeck" "$out"

# --- 9. pal_is_online honors CONTINUITY_FORCE_ONLINE ---
rc=1
(
    CONTINUITY_RD_CONF="$d/conf/retrodeck.json"
    export CONTINUITY_RD_CONF
    . "$PAL"
    CONTINUITY_FORCE_ONLINE=1
    pal_is_online
) && rc=0
assert_rc "pal_is_online force override" 0 "$rc"

# --- 10. pal_get_platform_map uses CONTINUITY_APP_DIR ---
out=$(
    CONTINUITY_RD_CONF="$d/conf/retrodeck.json"
    CONTINUITY_APP_DIR="/opt/app"
    export CONTINUITY_RD_CONF CONTINUITY_APP_DIR
    . "$PAL"
    pal_get_platform_map
)
assert_eq "platform map path" "/opt/app/config/platform_maps/retrodeck.json" "$out"

printf '\ntest_pal_retrodeck: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
