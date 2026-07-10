#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC1090,SC1091,SC2317
# Integration test — Sprint 2.3: REAL cross-device sync between the TrimUI
# Brick (real pal_nextui.sh) and the Steam Deck (real pal_retrodeck.sh)
# against ONE shared file:// remote. The end-to-end proof of Sprint 2.0's
# canonicalization: "the same save on two different-platform devices".
#
# Each device runs in its OWN subshell that sources exactly ONE real PAL +
# the core modules and drives the core sync phases directly (cs_run /
# rp_run / bp_run / se_pull / ch_handle_pull_conflict). Isolation is by
# subshell (both PALs define the same pal_* symbols); every persistent bit
# of device state lives on disk (each device's own repo clone + saves/roms
# trees + the shared remote) — exactly like two physical devices. Daemon
# lifecycle is separately covered (test_daemon_lifecycle.sh,
# test_retrodeck_flow.sh Phase 6).
#
#   Part 1 — Brick -> repo -> Deck  (minui  => canonical => retroarch)
#            native MinUI name becomes ONE canonical .srm and materializes
#            under the Deck's RA-native name; .rtc travels; a Brick-only
#            game is NOT materialized on the Deck (per-device sparse sync).
#   Part 2 — Deck -> repo -> Brick  (retroarch => canonical => minui)
#            an RA-named save materializes on the Brick under its MinUI
#            native name (ROM extension embedded, reconstructed from the
#            Brick's ROM); a Deck-only game is NOT materialized on Brick.
#   Part 3 — cross-format divergence on the SAME game collapses to ONE
#            canonical identity + ONE .local: a Brick .sav and a Deck .srm
#            for Super Metroid both canonicalize to snes/….srm, so the
#            conflict yields a single .conflict (one identity, class=srm)
#            and a single .local, bytes preserved on both sides.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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

assert_file_exists() {
    local desc="$1" filepath="$2"
    if [ -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_absent() {
    local desc="$1" filepath="$2"
    if [ ! -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file unexpectedly present: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text lacks: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
    esac
}

assert_not_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) printf 'FAIL: %s\n  text unexpectedly has: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
        *) passed=$((passed + 1)) ;;
    esac
}

# --- Sandbox --------------------------------------------------------

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# One bare remote shared by both devices.
REMOTE="$TEST_TMPDIR/remote.git"
git init --bare "$REMOTE" >/dev/null 2>&1
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null

# --- Device worlds --------------------------------------------------
# Brick: MinUI naming, TAG dirs (SFC/GBA); env-overridden pal_nextui.sh.
BRICK_REPO="$TEST_TMPDIR/brick/repo"
BRICK_SAVES="$TEST_TMPDIR/brick/saves"
BRICK_ROMS="$TEST_TMPDIR/brick/roms"
BRICK_STATES="$TEST_TMPDIR/brick/states"
BRICK_NAME="brick-dev"
mkdir -p "$BRICK_SAVES" "$BRICK_ROMS" "$BRICK_STATES"

# Deck: RetroArch naming, system dirs (snes/gba/psx); real pal_retrodeck.sh
# derives paths from a live retrodeck.json (rdhome carries a space, like an
# SD-card install).
DECK_NAME="deck-dev"
RDHOME="$TEST_TMPDIR/rd home"
RD_CONF="$TEST_TMPDIR/rdconf/retrodeck.json"
DECK_SAVES="$RDHOME/saves"
DECK_ROMS="$RDHOME/roms"
DECK_STATES="$RDHOME/states"
DECK_REPO="$TEST_TMPDIR/deck/repo"
mkdir -p "$DECK_SAVES" "$DECK_ROMS" "$DECK_STATES" "$TEST_TMPDIR/rdconf"
cat > "$RD_CONF" <<EOF
{
 "version": "0.10.9b",
 "paths": {
  "rd_home_path": "$RDHOME",
  "roms_path": "$DECK_ROMS",
  "saves_path": "$DECK_SAVES",
  "states_path": "$DECK_STATES"
 }
}
EOF

# --- Real-PAL device drivers ---------------------------------------
# Each spawns a subshell that sources the platform's REAL PAL + core and
# runs the phase passed as "$@". CONTINUITY_TEST_FORCE_OFFLINE=1 forces
# pal_is_online false (the container may have real network — an env unset
# is not enough, per the retrodeck flow test).

run_brick() {
    (
        set -e
        CONTINUITY_SAVES_ROOT="$BRICK_SAVES"
        CONTINUITY_ROMS_ROOT="$BRICK_ROMS"
        CONTINUITY_STATES_ROOT="$BRICK_STATES"
        CONTINUITY_REPO_DIR="$BRICK_REPO"
        CONTINUITY_PAK_DIR="$PROJECT_ROOT"      # -> real config/platform_maps/nextui.json
        CONTINUITY_GIT_BIN="git"
        CONTINUITY_FORCE_ONLINE=1
        export CONTINUITY_SAVES_ROOT CONTINUITY_ROMS_ROOT CONTINUITY_STATES_ROOT \
               CONTINUITY_REPO_DIR CONTINUITY_PAK_DIR CONTINUITY_GIT_BIN CONTINUITY_FORCE_ONLINE

        . "$PROJECT_ROOT/src/platforms/nextui/pal_nextui.sh"
        . "$PROJECT_ROOT/src/core/pal.sh"
        . "$PROJECT_ROOT/src/core/path_mapper.sh"
        . "$PROJECT_ROOT/src/core/sync_engine.sh"
        . "$PROJECT_ROOT/src/core/change_detector.sh"
        . "$PROJECT_ROOT/src/core/cold_start.sh"
        . "$PROJECT_ROOT/src/core/boot_pull.sh"
        . "$PROJECT_ROOT/src/core/stale_boot.sh"
        . "$PROJECT_ROOT/src/core/runtime_poll.sh"
        . "$PROJECT_ROOT/src/core/conflict_handler.sh"

        if [ -n "${CONTINUITY_TEST_FORCE_OFFLINE:-}" ]; then
            pal_is_online() { return 1; }
        fi

        pal_init >/dev/null 2>&1
        pm_load_platform_map "$(pal_get_platform_map)" >/dev/null 2>&1
        se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" >/dev/null 2>&1
        "$@"
    )
}

run_deck() {
    (
        set -e
        # Do NOT pre-set the roots — let the REAL PAL derive them from the
        # live retrodeck.json (exercises _pal_rd_path).
        CONTINUITY_RD_CONF="$RD_CONF"
        CONTINUITY_REPO_DIR="$DECK_REPO"
        CONTINUITY_APP_DIR="$PROJECT_ROOT"      # -> real config/platform_maps/retrodeck.json
        CONTINUITY_GIT_BIN="git"
        CONTINUITY_FORCE_ONLINE=1
        export CONTINUITY_RD_CONF CONTINUITY_REPO_DIR CONTINUITY_APP_DIR \
               CONTINUITY_GIT_BIN CONTINUITY_FORCE_ONLINE

        . "$PROJECT_ROOT/src/platforms/retrodeck/pal_retrodeck.sh"
        . "$PROJECT_ROOT/src/core/pal.sh"
        . "$PROJECT_ROOT/src/core/path_mapper.sh"
        . "$PROJECT_ROOT/src/core/sync_engine.sh"
        . "$PROJECT_ROOT/src/core/change_detector.sh"
        . "$PROJECT_ROOT/src/core/cold_start.sh"
        . "$PROJECT_ROOT/src/core/boot_pull.sh"
        . "$PROJECT_ROOT/src/core/stale_boot.sh"
        . "$PROJECT_ROOT/src/core/runtime_poll.sh"
        . "$PROJECT_ROOT/src/core/conflict_handler.sh"

        if [ -n "${CONTINUITY_TEST_FORCE_OFFLINE:-}" ]; then
            pal_is_online() { return 1; }
        fi

        pal_init >/dev/null 2>&1
        pm_load_platform_map "$(pal_get_platform_map)" >/dev/null 2>&1
        se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" >/dev/null 2>&1
        "$@"
    )
}

# enroll_device <repo_dir> <device_name> <first?> — the minimum the real
# pal_init accepts: a clone with .continuity/device_name. The first device
# also seeds the shared .continuity/.gitignore (device-local state stays
# out of commits). Enrollment proper is covered elsewhere.
enroll_device() {
    local repo="$1" name="$2" first="$3"
    git clone "file://$REMOTE" "$repo" >/dev/null 2>&1
    git -C "$repo" checkout -B main >/dev/null 2>&1 || true
    git -C "$repo" config user.email "continuity@device"
    git -C "$repo" config user.name "Continuity"
    git -C "$repo" config commit.gpgsign false
    mkdir -p "$repo/.continuity"
    printf '%s' "$name" > "$repo/.continuity/device_name"
    if [ "$first" = "first" ]; then
        printf 'credentials\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' \
            > "$repo/.continuity/.gitignore"
        git -C "$repo" add .continuity/.gitignore >/dev/null 2>&1
        git -C "$repo" commit -m "enroll: gitignore" >/dev/null 2>&1
        git -C "$repo" push origin main >/dev/null 2>&1
    fi
}

# clone_remote_ref — a throwaway clone to inspect what actually reached the
# remote (bytes, not just tree names).
remote_bytes() {
    local path="$1" work got
    work=$(mktemp -d)
    git clone "file://$REMOTE" "$work/c" >/dev/null 2>&1
    got=$(cat "$work/c/$path" 2>/dev/null)
    rm -rf "$work"
    printf '%s' "$got"
}

# =====================================================================
# Part 1 — Brick -> repo -> Deck (minui => canonical => retroarch)
# =====================================================================

enroll_device "$BRICK_REPO" "$BRICK_NAME" first

# Brick has two SNES games (ROM + MinUI-native save); metroid also has RTC.
mkdir -p "$BRICK_SAVES/SFC" "$BRICK_ROMS/SFC"
: > "$BRICK_ROMS/SFC/Super Metroid (USA).sfc"
: > "$BRICK_ROMS/SFC/Chrono Trigger.sfc"
printf 'metroid-sram-v1' > "$BRICK_SAVES/SFC/Super Metroid (USA).sfc.sav"
printf 'metroid-clock-v1' > "$BRICK_SAVES/SFC/Super Metroid (USA).sfc.rtc"
printf 'chrono-sram-v1' > "$BRICK_SAVES/SFC/Chrono Trigger.sfc.sav"

rc=0; run_brick cs_run "$BRICK_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "Brick cold start ok" 0 "$rc"

remote_files=$(git -C "$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null)
assert_contains "repo has canonical metroid .srm" "$remote_files" "snes/Super Metroid (USA).srm"
assert_contains "repo has canonical metroid .rtc" "$remote_files" "snes/Super Metroid (USA).rtc"
assert_contains "repo has canonical chrono .srm" "$remote_files" "snes/Chrono Trigger.srm"
# device-native MinUI names must NEVER reach the repo
assert_not_contains "no device-native .sfc.sav leaked into repo" "$remote_files" ".sfc.sav"
assert_not_contains "no device-native .sfc.rtc leaked into repo" "$remote_files" ".sfc.rtc"

# Deck enrolls (clone carries the canonical saves) and has ONLY metroid's ROM.
enroll_device "$DECK_REPO" "$DECK_NAME"
mkdir -p "$DECK_ROMS/snes"
: > "$DECK_ROMS/snes/Super Metroid (USA).sfc"     # metroid ROM present; NO chrono ROM

rc=0; run_deck cs_run "$DECK_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "Deck cold start ok" 0 "$rc"

# Deck materializes RA-native names for the ROM it has, byte-identical.
assert_file_exists "Deck has metroid .srm (RA native)" "$DECK_SAVES/snes/Super Metroid (USA).srm"
assert_eq "Deck metroid bytes match Brick" "metroid-sram-v1" \
    "$(cat "$DECK_SAVES/snes/Super Metroid (USA).srm" 2>/dev/null)"
# .rtc travelled with its game
assert_file_exists "Deck has metroid .rtc" "$DECK_SAVES/snes/Super Metroid (USA).rtc"
assert_eq "Deck metroid clock bytes match Brick" "metroid-clock-v1" \
    "$(cat "$DECK_SAVES/snes/Super Metroid (USA).rtc" 2>/dev/null)"
# sparse: no chrono ROM on the Deck -> not materialized
assert_absent "Deck did NOT materialize chrono (no ROM)" "$DECK_SAVES/snes/Chrono Trigger.srm"

# =====================================================================
# Part 2 — Deck -> repo -> Brick (retroarch => canonical => minui)
# =====================================================================

# Deck writes a NEW RA-named save for a ROM it has, plus a Deck-ONLY game
# the Brick lacks. sleep BEFORE writing so the new saves are strictly newer
# than the sentinel (busybox find -newer is second-granular).
sleep 1
mkdir -p "$DECK_SAVES/gba" "$DECK_ROMS/gba" "$DECK_SAVES/psx" "$DECK_ROMS/psx"
: > "$DECK_ROMS/gba/Zelda Minish Cap (USA).gba"
printf 'zelda-sram-deck' > "$DECK_SAVES/gba/Zelda Minish Cap (USA).srm"
: > "$DECK_ROMS/psx/Some PS1 Game.chd"
printf 'ps1-sram-deck' > "$DECK_SAVES/psx/Some PS1 Game.srm"

rc=0; run_deck rp_run "$DECK_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "Deck runtime poll ok" 0 "$rc"

remote_files=$(git -C "$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null)
# Repo uses the CANONICAL system name: the Deck's local dir is psx, but
# the canonical system for PS1 is ps1 (retrodeck map: "ps1": "psx").
assert_contains "repo has canonical zelda .srm" "$remote_files" "gba/Zelda Minish Cap (USA).srm"
assert_contains "repo has canonical ps1 .srm (canonical system name)" "$remote_files" "ps1/Some PS1 Game.srm"
assert_eq "repo zelda bytes are Deck's" "zelda-sram-deck" \
    "$(remote_bytes "gba/Zelda Minish Cap (USA).srm")"
assert_eq "repo ps1 bytes are Deck's" "ps1-sram-deck" \
    "$(remote_bytes "ps1/Some PS1 Game.srm")"

# Brick gains the Zelda GBA ROM (but NO PS1 ROM), then pulls.
mkdir -p "$BRICK_ROMS/GBA"
: > "$BRICK_ROMS/GBA/Zelda Minish Cap (USA).gba"

rc=0; run_brick bp_run "$BRICK_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "Brick boot pull ok" 0 "$rc"

# HEADLINE reverse mapping: Brick materializes the MinUI-native name with
# the ROM extension embedded, reconstructed from the Brick's own ROM.
assert_file_exists "Brick materialized MinUI-native zelda name" \
    "$BRICK_SAVES/GBA/Zelda Minish Cap (USA).gba.sav"
assert_eq "Brick zelda bytes are Deck's" "zelda-sram-deck" \
    "$(cat "$BRICK_SAVES/GBA/Zelda Minish Cap (USA).gba.sav" 2>/dev/null)"
# reverse sparse: no PS1 ROM on the Brick -> not materialized (any name)
assert_absent "Brick did NOT materialize ps1 .srm (no ROM)" \
    "$BRICK_SAVES/PS/Some PS1 Game.srm"
assert_absent "Brick did NOT materialize ps1 .sav (no ROM)" \
    "$BRICK_SAVES/PS/Some PS1 Game.chd.sav"

# =====================================================================
# Part 3 — cross-format divergence collapses to ONE canonical identity
# =====================================================================
# Brick's native metroid save is .sfc.sav; the Deck's is .srm. Both
# canonicalize to snes/Super Metroid (USA).srm, so a divergence yields a
# SINGLE .conflict (one identity, class=srm) and a SINGLE .local.

# Deck advances the shared game first (becomes canonical).
sleep 1
printf 'metroid-deck-v2' > "$DECK_SAVES/snes/Super Metroid (USA).srm"
rc=0; run_deck rp_run "$DECK_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "Deck pushes divergent metroid" 0 "$rc"
assert_eq "repo metroid canonical is Deck v2" "metroid-deck-v2" \
    "$(remote_bytes "snes/Super Metroid (USA).srm")"

# Brick diverges to different bytes while OFFLINE (commits locally, no push).
sleep 1
printf 'metroid-brick-v2' > "$BRICK_SAVES/SFC/Super Metroid (USA).sfc.sav"
CONTINUITY_TEST_FORCE_OFFLINE=1
run_brick rp_run "$BRICK_REPO" >/dev/null 2>&1 || true
unset CONTINUITY_TEST_FORCE_OFFLINE

# Brick pull now diverges; the conflict handler preserves + regroups.
rc=0; run_brick se_pull "$BRICK_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "Brick pull diverges (rc 1)" 1 "$rc"
rc=0; run_brick ch_handle_pull_conflict "$BRICK_REPO" >/dev/null 2>&1 || rc=$?
assert_rc "Brick conflict handler ok" 0 "$rc"

# Exactly ONE .local and ONE .conflict for the shared game — the two
# native formats (.sav, .srm) collapsed to one canonical identity.
local_count=$(find "$BRICK_REPO/snes" -name '*.local' ! -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')
conflict_count=$(find "$BRICK_REPO/snes" -name '*.conflict' ! -path '*/.git/*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly one .local for the shared game" "1" "$local_count"
assert_eq "exactly one .conflict for the shared game" "1" "$conflict_count"

CONFLICT_META="$BRICK_REPO/snes/Super Metroid (USA).srm.conflict"
LOCAL_FILE="$BRICK_REPO/snes/Super Metroid (USA).srm.$BRICK_NAME.local"
assert_file_exists "conflict metadata at canonical path" "$CONFLICT_META"
assert_file_exists "device .local at canonical path" "$LOCAL_FILE"

# v2 grouping fields: identity is the canonical path minus the save-class
# extension; class is the SRAM class (covers both .srm and the Brick .sav).
meta_identity=$(grep '"identity"' "$CONFLICT_META" | sed 's/.*: *"\([^"]*\)".*/\1/')
meta_class=$(grep '"class"' "$CONFLICT_META" | sed 's/.*: *"\([^"]*\)".*/\1/')
meta_schema=$(grep '"_schema_version"' "$CONFLICT_META" | sed 's/.*: *"\([^"]*\)".*/\1/')
assert_eq "conflict identity is canonical game (ext stripped)" \
    "snes/Super Metroid (USA)" "$meta_identity"
assert_eq "conflict class is srm (spans .srm and .sav)" "srm" "$meta_class"
assert_eq "conflict schema is v2" "2.0" "$meta_schema"

# Bytes preserved on BOTH sides: .local holds the Brick's divergent bytes,
# canonical holds the Deck's.
assert_eq ".local holds Brick's divergent bytes" "metroid-brick-v2" \
    "$(cat "$LOCAL_FILE" 2>/dev/null)"
assert_eq "canonical holds Deck's bytes" "metroid-deck-v2" \
    "$(cat "$BRICK_REPO/snes/Super Metroid (USA).srm" 2>/dev/null)"

# --- Summary --------------------------------------------------------
printf '\ntest_cross_device_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
