#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: scripts/migrate_repo.sh
#
# Proves the one-time canonicalization migration: dry-run writes nothing,
# --apply renames to canonical basenames byte-identically as git renames,
# conflict artifacts travel with their save, RZIP saves quarantine, states
# are left alone, collisions are skipped, and a re-run is a no-op.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
MIGRATE="$PROJECT_ROOT/scripts/migrate_repo.sh"

passed=0
failed=0

assert_eq() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_file_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ -e "$filepath" ]; then passed=$((passed + 1)); else
        printf 'FAIL: %s\n  missing: %s\n' "$desc" "$filepath" >&2; failed=$((failed + 1)); fi
}

assert_absent() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ ! -e "$filepath" ]; then passed=$((passed + 1)); else
        printf 'FAIL: %s\n  unexpectedly present: %s\n' "$desc" "$filepath" >&2; failed=$((failed + 1)); fi
}

assert_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  output lacks: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
    esac
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export TEST_TMPDIR

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# v2 (minui) platform map for the test PAL
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$TEST_TMPDIR/platform_map.json"

# ROM tree (minui embeds ROM ext -> anchoring resolves the basename)
ROMS="$TEST_TMPDIR/roms"
mkdir -p "$ROMS/SFC" "$ROMS/GB"
: > "$ROMS/SFC/Super Metroid (USA).sfc"
: > "$ROMS/GB/Link's Awakening.gb"
: > "$ROMS/GB/Zelda.gb"
export CONTINUITY_ROMS_ROOT="$ROMS"

# Repo with device-native names, artifacts, a state, an rzip save, and a
# collision pair.
REPO="$TEST_TMPDIR/repo"
mkdir -p "$REPO/snes" "$REPO/gb" "$REPO/states/SFC-snes9x"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name t
printf 'metroid-sram'  > "$REPO/snes/Super Metroid (USA).sfc.sav"
printf 'metroid-clock' > "$REPO/snes/Super Metroid (USA).sfc.rtc"
printf 'zelda-local'   > "$REPO/gb/Link's Awakening.gb.sav.deck-b.local"
printf '{"x":1}'       > "$REPO/gb/Link's Awakening.gb.sav.conflict"
printf 'zelda-sram'    > "$REPO/gb/Link's Awakening.gb.sav"
printf 'state-bytes'   > "$REPO/states/SFC-snes9x/Super Metroid (USA).sfc.st0"
printf '#RZIPv\001#____________zzzz' > "$REPO/snes/Compressed.sfc.srm"
# collision: both canonicalize to gb/Zelda.srm
printf 'zelda-native'  > "$REPO/gb/Zelda.gb.sav"
printf 'zelda-already' > "$REPO/gb/Zelda.srm"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm seed

run_migrate() {  # args passed through to migrate_repo.sh
    TEST_TMPDIR="$TEST_TMPDIR" CONTINUITY_ROMS_ROOT="$ROMS" \
        busybox ash "$MIGRATE" "$@" --pal "$TESTS_DIR/fixtures/pal_test.sh" "$REPO" 2>&1
}

# --- Dry-run ---
dry=$(run_migrate)
assert_contains "dry-run announces DRY-RUN" "$dry" "DRY-RUN"
assert_contains "dry-run plans metroid rename" "$dry" "snes/Super Metroid (USA).sfc.sav -> snes/Super Metroid (USA).srm"
assert_contains "dry-run plans rtc rename" "$dry" "snes/Super Metroid (USA).sfc.rtc -> snes/Super Metroid (USA).rtc"
assert_contains "dry-run carries .local artifact" "$dry" "Link's Awakening.gb.sav.deck-b.local -> gb/Link's Awakening.srm.deck-b.local"
assert_contains "dry-run carries .conflict artifact" "$dry" "Link's Awakening.gb.sav.conflict -> gb/Link's Awakening.srm.conflict"
assert_contains "dry-run quarantines rzip" "$dry" "snes/Compressed.sfc.srm"
assert_contains "dry-run reports collision" "$dry" "gb/Zelda.gb.sav -> gb/Zelda.srm"

# dry-run wrote nothing
dirty=$(git -C "$REPO" status --porcelain)
assert_eq "dry-run left repo clean" "" "$dirty"
assert_file_exists "device-native save still present after dry-run" "$REPO/snes/Super Metroid (USA).sfc.sav"

# --- Apply ---
metroid_before=$(cat "$REPO/snes/Super Metroid (USA).sfc.sav")
apply=$(run_migrate --apply)
assert_contains "apply reports completion" "$apply" "Migration complete"

# renamed to canonical, byte-identical
assert_file_exists "metroid canonical present" "$REPO/snes/Super Metroid (USA).srm"
assert_absent "metroid device-native gone" "$REPO/snes/Super Metroid (USA).sfc.sav"
assert_eq "metroid bytes preserved" "$metroid_before" "$(cat "$REPO/snes/Super Metroid (USA).srm")"
assert_file_exists "rtc canonical present" "$REPO/snes/Super Metroid (USA).rtc"
# artifacts carried
assert_file_exists ".local carried to canonical base" "$REPO/gb/Link's Awakening.srm.deck-b.local"
assert_file_exists ".conflict carried to canonical base" "$REPO/gb/Link's Awakening.srm.conflict"
# quarantined rzip left untouched
assert_file_exists "rzip save left in place" "$REPO/snes/Compressed.sfc.srm"
# state left untouched
assert_file_exists "state left in place" "$REPO/states/SFC-snes9x/Super Metroid (USA).sfc.st0"
# collision: pre-existing canonical untouched, device-native NOT clobbered
assert_eq "collision target kept its bytes" "zelda-already" "$(cat "$REPO/gb/Zelda.srm")"
assert_file_exists "collision source left for manual fix" "$REPO/gb/Zelda.gb.sav"

# git tracks the moves as renames
git -C "$REPO" commit -qm migrate
renames=$(git -C "$REPO" show --name-status --oneline HEAD | grep -c '^R')
if [ "$renames" -ge 3 ]; then passed=$((passed+1)); else
    printf 'FAIL: expected >=3 git renames, got %s\n' "$renames" >&2; failed=$((failed+1)); fi

# --- Idempotent re-run ---
again=$(run_migrate --apply)
assert_contains "re-run is a no-op" "$again" "already canonical"

printf '\ntest_migrate_repo: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
