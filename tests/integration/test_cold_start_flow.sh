#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: full cold start across multiple save scenarios
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
        printf 'FAIL: %s\n  expected rc: %s\n  actual rc:   %s\n' "$desc" "$expected" "$actual" >&2
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

assert_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*)
            passed=$((passed + 1))
            ;;
        *)
            printf 'FAIL: %s\n  text does not contain: %s\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
            ;;
    esac
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

. "$TESTS_DIR/fixtures/pal_test.sh"
pal_init

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/path_mapper.sh"
. "$PROJECT_ROOT/src/core/change_detector.sh"
. "$PROJECT_ROOT/src/core/cold_start.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# --- Create bare remote and seed with saves from "another device" ---
REMOTE="$TEST_TMPDIR/remote.git"
SEED="$TEST_TMPDIR/seed"
REPO="$TEST_TMPDIR/repo"

"$CONTINUITY_GIT_BIN" init --bare "$REMOTE" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REMOTE" symbolic-ref HEAD refs/heads/main 2>/dev/null

"$CONTINUITY_GIT_BIN" clone "file://$REMOTE" "$SEED" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED" checkout -b main 2>/dev/null || true
"$CONTINUITY_GIT_BIN" -C "$SEED" config user.email "other@device"
"$CONTINUITY_GIT_BIN" -C "$SEED" config user.name "Other"

# Seed saves: 3 systems from another device
mkdir -p "$SEED/gb" "$SEED/snes" "$SEED/gba"
printf 'repo_links' > "$SEED/gb/links_awakening.srm"
printf 'repo_metroid' > "$SEED/snes/super_metroid.srm"
printf 'repo_minish' > "$SEED/gba/minish_cap.srm"

"$CONTINUITY_GIT_BIN" -C "$SEED" add -A >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED" commit -m "seed: saves from other device" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED" push origin main >/dev/null 2>&1
rm -rf "$SEED"

# --- Clone as fresh device (no sentinel) ---
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE" "$REPO" >/dev/null 2>&1
se_init "$REPO" "test-device"

# Write .continuity/.gitignore (normally enrollment does this)
mkdir -p "$REPO/.continuity"
printf 'credentials\ngit_credential_helper.sh\ndevice_name\nsentinel\nlast_known_commit\nclean_shutdown\n' > "$REPO/.continuity/.gitignore"
"$CONTINUITY_GIT_BIN" -C "$REPO" add .continuity/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REPO" commit -m "enroll: gitignore" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REPO" push origin main >/dev/null 2>&1

# --- Populate device saves ---
SAVES="$CONTINUITY_SAVES_ROOT"
# SFC/super_metroid.srm — DIFFERENT from repo (conflict)
mkdir -p "$SAVES/SFC"
printf 'device_metroid' > "$SAVES/SFC/super_metroid.srm"

# GBA/minish_cap.srm — IDENTICAL to repo (no conflict)
mkdir -p "$SAVES/GBA"
printf 'repo_minish' > "$SAVES/GBA/minish_cap.srm"

# GBC/pokemon_red.srm — device-only (not in repo)
mkdir -p "$SAVES/GBC"
printf 'device_pokemon' > "$SAVES/GBC/pokemon_red.srm"

# No GB/ save — links_awakening is repo-only

# Update CONTINUITY_REPO_DIR
CONTINUITY_REPO_DIR="$REPO"

# --- Run cold start ---
rc=0; cs_run "$REPO" >/dev/null 2>&1 || rc=$?
assert_rc "cs_run returns 0" 0 "$rc"

# --- Assertions ---

# 1. links_awakening pulled to device (repo-only)
assert_file_exists "links_awakening on device" "$SAVES/GB/links_awakening.srm"
la_content=$(cat "$SAVES/GB/links_awakening.srm")
assert_eq "links_awakening content" "repo_links" "$la_content"

# 2. super_metroid on device matches repo (repo wins)
sm_device=$(cat "$SAVES/SFC/super_metroid.srm")
assert_eq "super_metroid on device is repo version" "repo_metroid" "$sm_device"

# 3. .local file preserved in repo
assert_file_exists "super_metroid .local exists" "$REPO/snes/super_metroid.srm.test-device.local"
sm_local=$(cat "$REPO/snes/super_metroid.srm.test-device.local")
assert_eq "super_metroid .local has device version" "device_metroid" "$sm_local"

# 4. .conflict metadata exists
assert_file_exists "super_metroid .conflict exists" "$REPO/snes/super_metroid.srm.conflict"
conflict_json=$(cat "$REPO/snes/super_metroid.srm.conflict")
assert_contains ".conflict has canonical" "$conflict_json" '"canonical": "snes/super_metroid.srm"'
assert_contains ".conflict has source" "$conflict_json" '"source": "cold_start"'

# 5. minish_cap on device unchanged (identical)
mc_device=$(cat "$SAVES/GBA/minish_cap.srm")
assert_eq "minish_cap unchanged" "repo_minish" "$mc_device"

# 6. pokemon_red pushed to repo (device-only)
assert_file_exists "pokemon_red in repo" "$REPO/gbc/pokemon_red.srm"
pr_repo=$(cat "$REPO/gbc/pokemon_red.srm")
assert_eq "pokemon_red content in repo" "device_pokemon" "$pr_repo"

# 7. Sentinel exists
assert_file_exists "sentinel exists" "$REPO/.continuity/sentinel"

# 8. last_known_commit exists with valid SHA
assert_file_exists "last_known_commit exists" "$REPO/.continuity/last_known_commit"
lkc=$(cat "$REPO/.continuity/last_known_commit")
lkc_clean=$(printf '%s' "$lkc" | tr -d '[:space:]')
lkc_len=$(printf '%s' "$lkc_clean" | wc -c | tr -d ' ')
assert_eq "last_known_commit is 40-char SHA" "40" "$lkc_len"

# 9. cs_is_cold_start returns 1 (not cold start anymore)
rc=0; cs_is_cold_start "$REPO" || rc=$?
assert_rc "cs_is_cold_start after run returns 1" 1 "$rc"

# 10. Remote contains .local and pokemon_red (push succeeded)
remote_files=$("$CONTINUITY_GIT_BIN" -C "$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null)
assert_contains "remote has .local" "$remote_files" "snes/super_metroid.srm.test-device.local"
assert_contains "remote has pokemon_red" "$remote_files" "gbc/pokemon_red.srm"

# --- Summary ---
printf '\ntest_cold_start_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
