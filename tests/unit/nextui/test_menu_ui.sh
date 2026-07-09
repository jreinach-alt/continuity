#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC2154
# Unit tests for src/platforms/nextui/menu_ui.sh — the extensible PAK menu.
#
# Drives mu_run through the scripted-queue test PAL (no hardware): the
# Conflicts(N) row shows the live count and dispatches to cu_run, and a
# throwaway second data-driven row renders + dispatches with NO input-plumbing
# change — proving the shell is extensible (a future PAK item is one line).
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

passed=0
failed=0

assert_eq() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then passed=$((passed + 1)); else
        printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}
assert_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text does not contain: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
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
. "$TESTS_DIR/fixtures/pal_ui_test.sh"

. "$PROJECT_ROOT/src/core/pal.sh"
. "$PROJECT_ROOT/src/core/sync_engine.sh"
. "$PROJECT_ROOT/src/core/path_mapper.sh"
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"
. "$PROJECT_ROOT/src/core/conflict_ui.sh"
. "$PROJECT_ROOT/src/platforms/nextui/menu_ui.sh"

cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null
CONTINUITY_DEVICE_NAME="my-brick"

# Build a repo with N conflicts.
make_repo() {
    local id count repo_dir i
    id="$1"; count="$2"
    repo_dir="$TEST_TMPDIR/${id}_repo"
    "$CONTINUITY_GIT_BIN" init "$repo_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.email t@t
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.name T
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" checkout -b main >/dev/null 2>&1 || true
    mkdir -p "$repo_dir/snes" "$repo_dir/.continuity"
    i=1
    while [ "$i" -le "$count" ]; do
        printf 'remote' > "$repo_dir/snes/Game $i.sav"
        printf 'local' > "$repo_dir/snes/Game $i.sav.my-brick.local"
        printf '{\n  "_schema_version": "2.0",\n  "file": "snes/Game %s.sav",\n  "identity": "snes/Game %s",\n  "class": "srm",\n  "remote_device": "deck",\n  "remote_timestamp": "2026-03-12T13:00:00Z",\n  "local_device": "my-brick",\n  "local_timestamp": "2026-03-12T14:00:00Z",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
            "$i" "$i" > "$repo_dir/snes/Game $i.sav.conflict"
        i=$((i + 1))
    done
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" add . >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit -m conflicts >/dev/null 2>&1
    printf '%s' "$repo_dir"
}

# ═══ Test 1: Conflicts(N) row shows the live count ═══
repo=$(make_repo t1 3)
# Open menu, then immediately cancel (don't enter the conflict flow).
pal_ui_seed cancel
mu_run "$repo"
render=$(cat "$PAL_UI_RENDER")
assert_contains "row shows live count Conflicts (3)" "$render" "Conflicts (3)"

# ═══ Test 2: selecting the row dispatches into cu_run ═══
repo=$(make_repo t2 1)
# menu: pick row 0 (Conflicts); cu_run list: pick group 0; detail: Keep local
# (item 3); confirm yes; back in menu loop: cancel.
pal_ui_seed 0 0 3 yes cancel
mu_run "$repo"
assert_eq "dispatched cu_run resolved the conflict" "0" "$(ch_count_conflicts "$repo")"
canonical=$(cat "$repo/snes/Game 1.sav")
assert_eq "kept local via dispatched flow" "local" "$canonical"

# ═══ Test 3: menu cancel exits cleanly (0 conflicts still opens the row) ═══
repo=$(make_repo t3 0)
pal_ui_seed cancel
rc=0; mu_run "$repo" || rc=$?
assert_eq "empty menu still opens + cancels cleanly" "0" "$rc"
render=$(cat "$PAL_UI_RENDER")
assert_contains "shows Conflicts (0) row" "$render" "Conflicts (0)"

# ═══ Test 4: EXTENSIBILITY — a throwaway second row renders + dispatches
# with no input-plumbing change (the whole point of the data-driven shell).
mu_probe_hit="$TEST_TMPDIR/probe_hit"
rm -f "$mu_probe_hit"
mu_probe_handler() { printf 'hit\n' > "$mu_probe_hit"; }
# Override the entry table to add a second row — one line, as advertised.
mu_build_menu() {
    local repo_dir n
    repo_dir="$1"
    n=$(ch_count_conflicts "$repo_dir" 2>/dev/null); [ -z "$n" ] && n=0
    printf 'mu_open_conflicts|Conflicts (%s)\n' "$n"
    printf 'mu_probe_handler|Probe row\n'
}
repo=$(make_repo t4 2)
# menu: pick row 1 (Probe row) -> dispatch handler; back in menu: cancel.
pal_ui_seed 1 cancel
mu_run "$repo"
render=$(cat "$PAL_UI_RENDER")
assert_contains "second row rendered" "$render" "Probe row"
assert_contains "second row: first row still present" "$render" "Conflicts (2)"
assert_eq "second row dispatched its handler" "hit" "$(cat "$mu_probe_hit" 2>/dev/null)"

# --- Results ---
printf '\n=== menu_ui: %s passed, %s failed ===\n' "$passed" "$failed" >&2
[ "$failed" -eq 0 ]
