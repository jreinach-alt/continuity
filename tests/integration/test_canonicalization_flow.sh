#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: Sprint 2.0 canonicalization across two styles.
#
# Drives real sync phases against a file:// remote:
#   Part 1 — a MinUI device pushes device-native saves; the repo carries
#            ONE canonical representation; a RetroArch device materializes
#            them under its OWN native names. .rtc travels with its game;
#            a save whose ROM is absent on device B is NOT materialized
#            (per-device sparse sync).
#   Part 2 — a two-device .rtc divergence is preserved exactly like an
#            .srm conflict (.local + .conflict).
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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

assert_rc() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected rc: %s  actual rc: %s\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_file_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_absent() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ ! -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file unexpectedly present: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text lacks: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
    esac
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export TEST_TMPDIR

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# shellcheck source=tests/fixtures/pal_test.sh
. "$TESTS_DIR/fixtures/pal_test.sh"
pal_init
# shellcheck source=src/core/pal.sh
. "$PROJECT_ROOT/src/core/pal.sh"
# shellcheck source=src/core/sync_engine.sh
. "$PROJECT_ROOT/src/core/sync_engine.sh"
# shellcheck source=src/core/path_mapper.sh
. "$PROJECT_ROOT/src/core/path_mapper.sh"
# shellcheck source=src/core/change_detector.sh
. "$PROJECT_ROOT/src/core/change_detector.sh"
# shellcheck source=src/core/cold_start.sh
. "$PROJECT_ROOT/src/core/cold_start.sh"
# shellcheck source=src/core/boot_pull.sh
. "$PROJECT_ROOT/src/core/boot_pull.sh"
# shellcheck source=src/core/conflict_handler.sh
. "$PROJECT_ROOT/src/core/conflict_handler.sh"

GIT="$CONTINUITY_GIT_BIN"

enroll_gitignore() {
    local repo="$1"
    mkdir -p "$repo/.continuity"
    printf 'credentials\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' \
        > "$repo/.continuity/.gitignore"
    "$GIT" -C "$repo" add .continuity/.gitignore >/dev/null 2>&1
    "$GIT" -C "$repo" commit -m "enroll: gitignore" >/dev/null 2>&1
    "$GIT" -C "$repo" push origin main >/dev/null 2>&1
}

# use_device — point the PAL globals + platform map at one simulated device
use_device() {
    CONTINUITY_DEVICE_NAME="$1"
    CONTINUITY_REPO_DIR="$2"
    CONTINUITY_SAVES_ROOT="$3"
    CONTINUITY_ROMS_ROOT="$4"
    cp "$PROJECT_ROOT/config/platform_maps/$5.json" "$(pal_get_platform_map)"
    pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null
}

# =====================================================================
# Part 1 — cross-style push -> canonical repo -> native materialization
# =====================================================================

REMOTE="$TEST_TMPDIR/remote.git"
"$GIT" init --bare "$REMOTE" >/dev/null 2>&1
"$GIT" -C "$REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null

# --- Device A: MinUI (nextui map, SFC dirs) ---
REPO_A="$TEST_TMPDIR/repo_a"; SAVES_A="$TEST_TMPDIR/saves_a"; ROMS_A="$TEST_TMPDIR/roms_a"
"$GIT" clone "file://$REMOTE" "$REPO_A" >/dev/null 2>&1
"$GIT" -C "$REPO_A" checkout -b main >/dev/null 2>&1 || true
se_init "$REPO_A" "brick-a" >/dev/null 2>&1
use_device "brick-a" "$REPO_A" "$SAVES_A" "$ROMS_A" "nextui"
enroll_gitignore "$REPO_A"

mkdir -p "$SAVES_A/SFC" "$ROMS_A/SFC"
: > "$ROMS_A/SFC/Super Metroid (USA).sfc"
: > "$ROMS_A/SFC/Chrono Trigger.sfc"
printf 'metroid-sram' > "$SAVES_A/SFC/Super Metroid (USA).sfc.sav"
printf 'metroid-clock' > "$SAVES_A/SFC/Super Metroid (USA).sfc.rtc"
printf 'chrono-sram'  > "$SAVES_A/SFC/Chrono Trigger.sfc.sav"

rc=0; cs_run "$REPO_A" >/dev/null 2>&1 || rc=$?
assert_rc "A cold start ok" 0 "$rc"

remote_files=$("$GIT" -C "$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null)
assert_contains "repo has canonical metroid .srm" "$remote_files" "snes/Super Metroid (USA).srm"
assert_contains "repo has canonical metroid .rtc" "$remote_files" "snes/Super Metroid (USA).rtc"
assert_contains "repo has canonical chrono .srm" "$remote_files" "snes/Chrono Trigger.srm"
# device-native names must NOT leak into the repo
case "$remote_files" in
    *".sfc.sav"*) printf 'FAIL: device-native .sfc.sav leaked into repo\n' >&2; failed=$((failed+1)) ;;
    *) passed=$((passed+1)) ;;
esac

# --- Device B: RetroArch (retrodeck map, snes dirs), ROM only for metroid ---
REPO_B="$TEST_TMPDIR/repo_b"; SAVES_B="$TEST_TMPDIR/saves_b"; ROMS_B="$TEST_TMPDIR/roms_b"
"$GIT" clone "file://$REMOTE" "$REPO_B" >/dev/null 2>&1
"$GIT" -C "$REPO_B" checkout main >/dev/null 2>&1 || true
se_init "$REPO_B" "deck-b" >/dev/null 2>&1
use_device "deck-b" "$REPO_B" "$SAVES_B" "$ROMS_B" "retrodeck"

mkdir -p "$SAVES_B/snes" "$ROMS_B/snes"
: > "$ROMS_B/snes/Super Metroid (USA).sfc"   # has metroid ROM; NO chrono ROM
cs_store_commit "$REPO_B" "$("$GIT" -C "$REPO_B" rev-parse HEAD)"

rc=0; cs_run "$REPO_B" >/dev/null 2>&1 || rc=$?
assert_rc "B cold start ok" 0 "$rc"

# B materializes RA-native names for the ROM it has
assert_file_exists "B has metroid .srm (RA native)" "$SAVES_B/snes/Super Metroid (USA).srm"
assert_eq "B metroid bytes" "metroid-sram" "$(cat "$SAVES_B/snes/Super Metroid (USA).srm" 2>/dev/null)"
# .rtc travelled with its game
assert_file_exists "B has metroid .rtc" "$SAVES_B/snes/Super Metroid (USA).rtc"
assert_eq "B metroid clock bytes" "metroid-clock" "$(cat "$SAVES_B/snes/Super Metroid (USA).rtc" 2>/dev/null)"
# sparse: no ROM for chrono on B -> not materialized
assert_absent "B did NOT materialize chrono (no ROM)" "$SAVES_B/snes/Chrono Trigger.srm"

# =====================================================================
# Part 2 — .rtc two-device conflict preserved like a save
# =====================================================================

REMOTE2="$TEST_TMPDIR/remote2.git"
"$GIT" init --bare "$REMOTE2" >/dev/null 2>&1
"$GIT" -C "$REMOTE2" symbolic-ref HEAD refs/heads/main 2>/dev/null

# Seed remote2 with a canonical .rtc
SEED="$TEST_TMPDIR/seed2"
"$GIT" clone "file://$REMOTE2" "$SEED" >/dev/null 2>&1
"$GIT" -C "$SEED" checkout -b main >/dev/null 2>&1 || true
"$GIT" -C "$SEED" config user.email seed@t; "$GIT" -C "$SEED" config user.name seed
mkdir -p "$SEED/gb"
printf 'rtc-v0' > "$SEED/gb/Link's Awakening.rtc"
"$GIT" -C "$SEED" add -A >/dev/null 2>&1
"$GIT" -C "$SEED" commit -m seed >/dev/null 2>&1
"$GIT" -C "$SEED" push origin main >/dev/null 2>&1

# Device C (MinUI) clones, stores this commit, then diverges locally while
# the remote advances to a different .rtc.
REPO_C="$TEST_TMPDIR/repo_c"; SAVES_C="$TEST_TMPDIR/saves_c"; ROMS_C="$TEST_TMPDIR/roms_c"
"$GIT" clone "file://$REMOTE2" "$REPO_C" >/dev/null 2>&1
"$GIT" -C "$REPO_C" checkout main >/dev/null 2>&1 || true
se_init "$REPO_C" "brick-c" >/dev/null 2>&1
use_device "brick-c" "$REPO_C" "$SAVES_C" "$ROMS_C" "nextui"
mkdir -p "$ROMS_C/GB"; : > "$ROMS_C/GB/Link's Awakening.gb"
cs_store_commit "$REPO_C" "$("$GIT" -C "$REPO_C" rev-parse HEAD)"

# remote advances (another device pushed a different rtc)
rm -rf "$SEED"
"$GIT" clone "file://$REMOTE2" "$SEED" >/dev/null 2>&1
"$GIT" -C "$SEED" checkout main >/dev/null 2>&1 || true
"$GIT" -C "$SEED" config user.email seed@t; "$GIT" -C "$SEED" config user.name seed
printf 'rtc-remote' > "$SEED/gb/Link's Awakening.rtc"
"$GIT" -C "$SEED" commit -am remote-change >/dev/null 2>&1
"$GIT" -C "$SEED" push origin main >/dev/null 2>&1

# device C makes its own local commit on the same rtc -> histories diverge
printf 'rtc-device' > "$REPO_C/gb/Link's Awakening.rtc"
"$GIT" -C "$REPO_C" add -A >/dev/null 2>&1
"$GIT" -C "$REPO_C" commit -m local-change >/dev/null 2>&1

rc=0; se_pull "$REPO_C" >/dev/null 2>&1 || rc=$?
assert_rc "C pull diverges" 1 "$rc"

rc=0; ch_handle_pull_conflict "$REPO_C" >/dev/null 2>&1 || rc=$?
assert_rc "C conflict handler ok" 0 "$rc"

assert_file_exists ".rtc .local preserved" "$REPO_C/gb/Link's Awakening.rtc.brick-c.local"
assert_eq ".rtc .local holds device bytes" "rtc-device" \
    "$(cat "$REPO_C/gb/Link's Awakening.rtc.brick-c.local" 2>/dev/null)"
assert_file_exists ".rtc .conflict metadata" "$REPO_C/gb/Link's Awakening.rtc.conflict"
assert_eq ".rtc canonical is remote bytes" "rtc-remote" \
    "$(cat "$REPO_C/gb/Link's Awakening.rtc" 2>/dev/null)"

# --- Summary ---
printf '\ntest_canonicalization_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
