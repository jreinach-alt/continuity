#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
set -e

# Unit tests for the schema-2.1 rom_paths extension (Sprint 3.1, owner
# approved 2026-07-09): platforms whose save layout is coarser than
# system identity (muOS: saves per-CORE, ROMs per-system). Covers the
# rom_paths block parse, pm_rom_dir precedence, ROM-anchored resolution
# of shared save dirs (gb+gbc under Gambatte — proven by the RG40XX V's
# real files), watched-dir dedupe, deterministic fallbacks, and
# backward compatibility for maps without rom_paths.

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

# shellcheck source=tests/fixtures/pal_test.sh
. "$REPO_ROOT/tests/fixtures/pal_test.sh"
# shellcheck source=src/core/pal.sh
. "$REPO_ROOT/src/core/pal.sh"
# shellcheck source=src/core/path_mapper.sh
. "$REPO_ROOT/src/core/path_mapper.sh"
pal_init

CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/saves"
CONTINUITY_ROMS_ROOT="$TEST_TMPDIR/roms"

# muOS-shaped map: per-core save dirs, per-system ROM dirs (real names
# from the RG40XX V recon), retroarch name style.
write_muos_map() {
    cat > "$TEST_TMPDIR/platform_map.json" <<EOF
{
  "_schema_version": "2.1",
  "platform": "muos-test",
  "saves_root": "$TEST_TMPDIR/saves",
  "system_paths": {
    "gb": "Gambatte",
    "gbc": "Gambatte",
    "snes": "Snes9x"
  },
  "rom_paths": {
    "gb": "Nintendo - GB",
    "gbc": "Nintendo - GBC",
    "snes": "Nintendo - SNES"
  },
  "save_extension": ".srm",
  "save_name_style": "retroarch",
  "save_container": "raw",
  "rom_roots": ["ROMS"]
}
EOF
    pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null
}

mkdir -p "$TEST_TMPDIR/saves/Gambatte" "$TEST_TMPDIR/saves/Snes9x"
mkdir -p "$TEST_TMPDIR/roms/Nintendo - GB" "$TEST_TMPDIR/roms/Nintendo - GBC" \
         "$TEST_TMPDIR/roms/Nintendo - SNES"
: > "$TEST_TMPDIR/roms/Nintendo - GB/Final Fantasy Adventure (USA).gb"
: > "$TEST_TMPDIR/roms/Nintendo - GBC/Mario Golf (USA).gbc"
: > "$TEST_TMPDIR/roms/Nintendo - GBC/Link's Awakening DX (USA).gbc"
: > "$TEST_TMPDIR/roms/Nintendo - SNES/Chrono Trigger.sfc"

write_muos_map

# ── rom_paths parse + pm_rom_dir precedence ─────────────────────────

assert_eq "pm_rom_dir uses rom_paths (gb)" \
    "$TEST_TMPDIR/roms/Nintendo - GB" "$(pm_rom_dir gb)"
assert_eq "pm_rom_dir uses rom_paths (gbc)" \
    "$TEST_TMPDIR/roms/Nintendo - GBC" "$(pm_rom_dir gbc)"

# ── the disambiguation this extension exists for ────────────────────
# Both saves live in the SAME Gambatte dir; the ROM anchor must split
# them into gb/ and gbc/ (the RG40XX V's real layout).

printf 'sram' > "$TEST_TMPDIR/saves/Gambatte/Final Fantasy Adventure (USA).srm"
printf 'sram' > "$TEST_TMPDIR/saves/Gambatte/Mario Golf (USA).srm"
printf 'sram' > "$TEST_TMPDIR/saves/Gambatte/Link's Awakening DX (USA).srm"
printf 'sram' > "$TEST_TMPDIR/saves/Snes9x/Chrono Trigger.srm"

assert_eq "GB save resolves to gb/" "gb/Final Fantasy Adventure (USA).srm" \
    "$(pm_device_to_canonical "$TEST_TMPDIR/saves/Gambatte/Final Fantasy Adventure (USA).srm")"
assert_eq "GBC save resolves to gbc/ (same save dir)" "gbc/Mario Golf (USA).srm" \
    "$(pm_device_to_canonical "$TEST_TMPDIR/saves/Gambatte/Mario Golf (USA).srm")"
assert_eq "apostrophe GBC save resolves" "gbc/Link's Awakening DX (USA).srm" \
    "$(pm_device_to_canonical "$TEST_TMPDIR/saves/Gambatte/Link's Awakening DX (USA).srm")"
assert_eq "single-candidate dir unaffected" "snes/Chrono Trigger.srm" \
    "$(pm_device_to_canonical "$TEST_TMPDIR/saves/Snes9x/Chrono Trigger.srm")"

# ── materialization: both systems land back in the shared dir ───────

assert_eq "gb materializes into Gambatte/" \
    "$TEST_TMPDIR/saves/Gambatte/Final Fantasy Adventure (USA).srm" \
    "$(pm_canonical_to_device "gb/Final Fantasy Adventure (USA).srm")"
assert_eq "gbc materializes into Gambatte/" \
    "$TEST_TMPDIR/saves/Gambatte/Mario Golf (USA).srm" \
    "$(pm_canonical_to_device "gbc/Mario Golf (USA).srm")"

# sparse skip still ROM-gated through rom_paths
rc=0; out=$(pm_canonical_to_device "gbc/No Such Game.srm") || rc=$?
assert_eq "no-ROM materialize rc 2 via rom_paths" "2" "$rc"
assert_eq "no-ROM materialize silent" "" "$out"

# round-trip through the shared dir
back=$(pm_canonical_to_device "$(pm_device_to_canonical "$TEST_TMPDIR/saves/Gambatte/Mario Golf (USA).srm")")
assert_eq "gbc round-trip through shared dir" \
    "$TEST_TMPDIR/saves/Gambatte/Mario Golf (USA).srm" "$back"

# ── no-ROM forward fallback: first-listed candidate + heuristic ─────

printf 'sram' > "$TEST_TMPDIR/saves/Gambatte/Orphan Game.srm"
assert_eq "orphan save falls back to first candidate (gb)" \
    "gb/Orphan Game.srm" \
    "$(pm_device_to_canonical "$TEST_TMPDIR/saves/Gambatte/Orphan Game.srm")"

# legacy pm_local_to_repo stays deterministic on shared dirs
assert_eq "pm_local_to_repo picks first-listed canonical" \
    "gb/Mario Golf (USA).srm" \
    "$(pm_local_to_repo "$TEST_TMPDIR/saves/Gambatte/Mario Golf (USA).srm")"

# ── watched dirs deduped, order preserved ───────────────────────────

watched=$(pm_list_watched_dirs)
assert_eq "watched dirs deduped" "2" "$(printf '%s\n' "$watched" | grep -c .)"
assert_eq "watched dir order preserved" \
    "$TEST_TMPDIR/saves/Gambatte
$TEST_TMPDIR/saves/Snes9x" "$watched"

# ── pm_canonicals_for_dir ───────────────────────────────────────────

assert_eq "canonicals for shared dir" "gb
gbc" "$(pm_canonicals_for_dir Gambatte)"
assert_eq "canonicals for plain dir" "snes" "$(pm_canonicals_for_dir Snes9x)"

# ── backward compatibility: no rom_paths block ──────────────────────
# Same-named save/ROM dirs (the NextUI shape) must behave exactly as
# before the extension.

cat > "$TEST_TMPDIR/platform_map.json" <<EOF
{
  "_schema_version": "2.0",
  "platform": "compat-test",
  "saves_root": "$TEST_TMPDIR/saves2",
  "system_paths": {
    "snes": "SFC"
  },
  "save_name_style": "minui",
  "save_container": "raw",
  "rom_roots": ["Roms"]
}
EOF
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null
CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/saves2"
CONTINUITY_ROMS_ROOT="$TEST_TMPDIR/roms2"
mkdir -p "$TEST_TMPDIR/saves2/SFC" "$TEST_TMPDIR/roms2/SFC"
: > "$TEST_TMPDIR/roms2/SFC/Super Metroid (USA).sfc"
printf 'sram' > "$TEST_TMPDIR/saves2/SFC/Super Metroid (USA).sfc.sav"

assert_eq "v2.0 map: rom dir from system_paths" \
    "$TEST_TMPDIR/roms2/SFC" "$(pm_rom_dir snes)"
assert_eq "v2.0 map: minui forward unchanged" \
    "snes/Super Metroid (USA).srm" \
    "$(pm_device_to_canonical "$TEST_TMPDIR/saves2/SFC/Super Metroid (USA).sfc.sav")"
assert_eq "v2.0 map: minui reverse unchanged" \
    "$TEST_TMPDIR/saves2/SFC/Super Metroid (USA).sfc.sav" \
    "$(pm_canonical_to_device "snes/Super Metroid (USA).srm")"
assert_eq "v2.0 map: single watched dir" \
    "$TEST_TMPDIR/saves2/SFC" "$(pm_list_watched_dirs)"

printf '\ntest_path_mapper_rom_paths: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
