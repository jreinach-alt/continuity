#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
set -e

# Unit tests for the Sprint 2.0 canonical save-format mapper
# (src/core/path_mapper.sh): name-style translation, ROM-anchored
# identity, container sniff/quarantine, sparse (no-ROM) materialization,
# repo-side canonicalization, and the shared save/state pattern helpers.
# Self-contained: temp dirs + synthetic ROM tree, cleaned on EXIT.

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
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected empty, got: [%s]\n' "$desc" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_match() {
    local desc="$1" str="$2" re="$3"
    if printf '%s' "$str" | grep -q "$re"; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  [%s] did not match /%s/\n' "$desc" "$str" "$re" >&2
        failed=$((failed + 1))
    fi
}

assert_nomatch() {
    local desc="$1" str="$2" re="$3"
    if printf '%s' "$str" | grep -q "$re"; then
        printf 'FAIL: %s\n  [%s] unexpectedly matched /%s/\n' "$desc" "$str" "$re" >&2
        failed=$((failed + 1))
    else
        passed=$((passed + 1))
    fi
}

# shellcheck source=tests/fixtures/pal_test.sh
. "$REPO_ROOT/tests/fixtures/pal_test.sh"
# shellcheck source=src/core/pal.sh
. "$REPO_ROOT/src/core/pal.sh"
# shellcheck source=src/core/path_mapper.sh
. "$REPO_ROOT/src/core/path_mapper.sh"
pal_init

# write_map <style> — emit and load a v2 platform map with the given style.
write_map() {
    cat > "$TEST_TMPDIR/platform_map.json" <<EOF
{
  "_schema_version": "2.0",
  "platform": "test",
  "saves_root": "$TEST_TMPDIR/saves",
  "system_paths": {
    "snes": "SFC",
    "gb": "GB"
  },
  "save_name_style": "$1",
  "save_container": "raw",
  "rom_roots": ["Roms"]
}
EOF
    pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null
}

CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/saves"
CONTINUITY_ROMS_ROOT="$TEST_TMPDIR/roms"
mkdir -p "$TEST_TMPDIR/saves/SFC" "$TEST_TMPDIR/saves/GB"
mkdir -p "$TEST_TMPDIR/roms/SFC" "$TEST_TMPDIR/roms/GB"
: > "$TEST_TMPDIR/roms/SFC/Super Metroid (USA).sfc"
: > "$TEST_TMPDIR/roms/SFC/Chrono Trigger.sfc"
: > "$TEST_TMPDIR/roms/GB/Link's Awakening.gb"

# =====================================================================
# Gating: canonicalization needs BOTH save_name_style and a ROM dir
# =====================================================================

write_map "minui"
if pm_canon_enabled; then passed=$((passed+1)); else failed=$((failed+1)); printf 'FAIL: canon enabled with style+roms\n' >&2; fi

_saved_roms="$CONTINUITY_ROMS_ROOT"
CONTINUITY_ROMS_ROOT=""
if pm_canon_enabled; then failed=$((failed+1)); printf 'FAIL: canon must be off with no roms root\n' >&2; else passed=$((passed+1)); fi
# with no roms root, forward is pure passthrough (legacy)
result=$(pm_device_to_canonical "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sfc.sav")
assert_eq "no-roms forward is passthrough" "snes/Super Metroid (USA).sfc.sav" "$result"
CONTINUITY_ROMS_ROOT="$_saved_roms"

# =====================================================================
# MinUI style: device <rom_full>.sav <-> canonical <basename>.srm
# =====================================================================

write_map "minui"
mk_save() { printf 'raw-sram-bytes' > "$1"; }

mk_save "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sfc.sav"
result=$(pm_device_to_canonical "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sfc.sav")
assert_eq "minui fwd .sav->.srm (parenthesized)" "snes/Super Metroid (USA).srm" "$result"

result=$(pm_canonical_to_device "snes/Super Metroid (USA).srm")
assert_eq "minui rev embeds rom ext" "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sfc.sav" "$result"

# apostrophe name, gb system
mk_save "$TEST_TMPDIR/saves/GB/Link's Awakening.gb.sav"
result=$(pm_device_to_canonical "$TEST_TMPDIR/saves/GB/Link's Awakening.gb.sav")
assert_eq "minui fwd apostrophe" "gb/Link's Awakening.srm" "$result"
result=$(pm_canonical_to_device "gb/Link's Awakening.srm")
assert_eq "minui rev apostrophe" "$TEST_TMPDIR/saves/GB/Link's Awakening.gb.sav" "$result"

# .rtc is a save-class sibling: canonical keeps .rtc, minui rev embeds ext
printf 'clock' > "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sfc.rtc"
result=$(pm_device_to_canonical "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sfc.rtc")
assert_eq "minui fwd .rtc" "snes/Super Metroid (USA).rtc" "$result"
result=$(pm_canonical_to_device "snes/Super Metroid (USA).rtc")
assert_eq "minui rev .rtc" "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sfc.rtc" "$result"

# round-trip minui (spaced + apostrophe + parenthesized)
for f in "SFC/Super Metroid (USA).sfc.sav" "GB/Link's Awakening.gb.sav" "SFC/Chrono Trigger.sfc.sav"; do
    orig="$TEST_TMPDIR/saves/$f"
    mk_save "$orig"
    back=$(pm_canonical_to_device "$(pm_device_to_canonical "$orig")")
    assert_eq "minui round-trip $f" "$orig" "$back"
done

# =====================================================================
# RetroArch style: device <basename>.srm <-> canonical (identity name)
# =====================================================================

write_map "retroarch"
mk_save "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).srm"
result=$(pm_device_to_canonical "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).srm")
assert_eq "retroarch fwd .srm identity" "snes/Super Metroid (USA).srm" "$result"
result=$(pm_canonical_to_device "snes/Super Metroid (USA).srm")
assert_eq "retroarch rev native .srm" "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).srm" "$result"

# cross-style: a MinUI-produced canonical name materializes as RA-native
result=$(pm_canonical_to_device "snes/Chrono Trigger.srm")
assert_eq "cross-style minui->retroarch native" "$TEST_TMPDIR/saves/SFC/Chrono Trigger.srm" "$result"

# =====================================================================
# Generic style: device <basename>.sav <-> canonical <basename>.srm
# =====================================================================

write_map "generic"
mk_save "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sav"
result=$(pm_device_to_canonical "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sav")
assert_eq "generic fwd .sav->.srm" "snes/Super Metroid (USA).srm" "$result"
result=$(pm_canonical_to_device "snes/Super Metroid (USA).srm")
assert_eq "generic rev native .sav" "$TEST_TMPDIR/saves/SFC/Super Metroid (USA).sav" "$result"

# =====================================================================
# ROM-anchoring: no matching ROM -> sparse skip (rc 2); forward heuristic
# =====================================================================

write_map "minui"
rc=0; out=$(pm_canonical_to_device "snes/Nonexistent Game.srm") || rc=$?
assert_eq "no-ROM materialize returns rc 2" "2" "$rc"
assert_empty "no-ROM materialize prints nothing" "$out"

# forward with no matching ROM falls back to the 2-4 char ext-strip heuristic
mk_save "$TEST_TMPDIR/saves/SFC/Orphan Game.gba.sav"
result=$(pm_device_to_canonical "$TEST_TMPDIR/saves/SFC/Orphan Game.gba.sav")
assert_eq "forward heuristic strips .gba" "snes/Orphan Game.srm" "$result"

# =====================================================================
# Container sniff + quarantine
# =====================================================================

# real RZIP magic (#RZIPv\x01# + padding to >=20 bytes)
printf '#RZIPv\001#____________xxxx' > "$TEST_TMPDIR/saves/SFC/Compressed.sfc.srm"
assert_eq "sniff rzip" "rzip" "$(pm_container_class "$TEST_TMPDIR/saves/SFC/Compressed.sfc.srm")"
rc=0; out=$(pm_device_to_canonical "$TEST_TMPDIR/saves/SFC/Compressed.sfc.srm" 2>/dev/null) || rc=$?
assert_eq "rzip save quarantined rc 3" "3" "$rc"
assert_empty "rzip save prints nothing" "$out"

# snes9x native snapshot magic must NOT be mistaken for a container
printf '#!s9xsnp____________xxxx' > "$TEST_TMPDIR/s9x.bin"
assert_eq "sniff snes9x state as raw" "raw" "$(pm_container_class "$TEST_TMPDIR/s9x.bin")"
# raw SRAM (leading zeros) is raw
printf '\000\000\000\000rawsram' > "$TEST_TMPDIR/raw.bin"
assert_eq "sniff raw sram" "raw" "$(pm_container_class "$TEST_TMPDIR/raw.bin")"
# nonexistent file reads raw
assert_eq "sniff missing file as raw" "raw" "$(pm_container_class "$TEST_TMPDIR/nope.bin")"

# tie the sniff to the committed reference-encoder fixtures (the rzip one
# is produced BY libretro-common's encoder — see tools/rzip/reference/)
assert_eq "sniff reference rzip fixture" "rzip" \
    "$(pm_container_class "$REPO_ROOT/tests/fixtures/rzip/save_rzip.bin")"
assert_eq "sniff reference raw fixture" "raw" \
    "$(pm_container_class "$REPO_ROOT/tests/fixtures/rzip/save_raw.bin")"
assert_eq "sniff reference multichunk rzip fixture" "rzip" \
    "$(pm_container_class "$REPO_ROOT/tests/fixtures/rzip/save_rzip_multichunk.bin")"

# =====================================================================
# pm_repo_canonicalize (migration side)
# =====================================================================

write_map "minui"
assert_eq "repo canon .sav->.srm" "snes/Super Metroid (USA).srm" \
    "$(pm_repo_canonicalize 'snes/Super Metroid (USA).sfc.sav')"
assert_eq "repo canon .rtc kept" "snes/Super Metroid (USA).rtc" \
    "$(pm_repo_canonicalize 'snes/Super Metroid (USA).sfc.rtc')"
assert_eq "repo canon idempotent" "snes/Super Metroid (USA).srm" \
    "$(pm_repo_canonicalize 'snes/Super Metroid (USA).srm')"
# no ROM -> heuristic
assert_eq "repo canon heuristic" "snes/Orphan.srm" \
    "$(pm_repo_canonicalize 'snes/Orphan.gba.sav')"

# =====================================================================
# Shared pattern helpers — the single source of truth
# =====================================================================

save_re=$(pm_save_grep_re)
state_re=$(pm_state_grep_re)
union_re=$(pm_save_or_state_grep_re)

for s in "gb/Game.srm" "gb/Game.sav" "gb/Game.rtc" "gb/Name (USA).srm" "gb/A's.rtc"; do
    assert_match "save_re matches $s" "$s" "$save_re"
    assert_match "union_re matches $s" "$s" "$union_re"
done
assert_nomatch "save_re rejects state" "sc/Game.st0" "$save_re"

# every state shape (matrix §4): .st[0-9], .state, .stateN, .state.N, .state.auto
for s in "Game.st0" "Game.st9" "Game.state" "Game.state1" "Game.state.0" "Game.state.auto"; do
    assert_match "state_re matches $s" "$s" "$state_re"
    assert_match "union_re matches $s" "$s" "$union_re"
done
assert_nomatch "state_re rejects .srm" "Game.srm" "$state_re"

# find wrappers: save class + all five state shapes
mkdir -p "$TEST_TMPDIR/fscan/SFC" "$TEST_TMPDIR/fscan/states"
cd "$TEST_TMPDIR/fscan"
for n in "Game.srm" "Game.sav" "Game.rtc"; do : > "SFC/$n"; done
: > "SFC/ignore.txt"
for n in "S.st0" "S.state" "S.state3" "S.state.0" "S.state.auto"; do : > "states/$n"; done
: > "states/ignore.log"
n_saves=$(pm_find_saves "$TEST_TMPDIR/fscan/SFC" | grep -c .)
assert_eq "pm_find_saves finds 3 save-class files" "3" "$n_saves"
n_states=$(pm_find_states "$TEST_TMPDIR/fscan/states" | grep -c .)
assert_eq "pm_find_states finds all 5 state shapes" "5" "$n_states"
cd "$REPO_ROOT"

# =====================================================================
# Results
# =====================================================================

printf '\ntest_canonical_mapper: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
