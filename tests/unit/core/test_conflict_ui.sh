#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC2154
# Unit tests for src/core/conflict_ui.sh — the shared resolution controller.
#
# Drives the whole §4 state machine headless through the scripted-queue test
# PAL: every transition and guard (try, cancel-try, keep remote/local,
# keep_newest fallback, trying-modified promote, group resolution of
# .srm+.rtc as a unit). Real git temp repos; both privilege passes; all
# artifacts under $TMPDIR (never writes into the repo tree).
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
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
        printf 'FAIL: %s\n  expected rc: %s\n  actual rc: %s\n' "$desc" "$expected" "$actual" >&2
        failed=$((failed + 1))
    fi
}

assert_file_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ -e "$filepath" ]; then passed=$((passed + 1)); else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_file_not_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ ! -e "$filepath" ]; then passed=$((passed + 1)); else
        printf 'FAIL: %s\n  file should not exist: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *)
            printf 'FAIL: %s\n  text does not contain: %s\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
            ;;
    esac
}

assert_not_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*)
            printf 'FAIL: %s\n  text should not contain: %s\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
            ;;
        *) passed=$((passed + 1)) ;;
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

pal_validate

cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

CONTINUITY_DEVICE_NAME="my-brick"

# ============================================================
# Helper: build a git repo with one or more conflicted files.
# create_conflict_repo <test_id> then add_conflict <repo> <repo_path> ...
# ============================================================
new_repo() {
    local test_id repo_dir
    test_id="$1"
    repo_dir="$TEST_TMPDIR/${test_id}_repo"
    "$CONTINUITY_GIT_BIN" init "$repo_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.email "test@test"
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.name "Test"
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" checkout -b main >/dev/null 2>&1 || true
    mkdir -p "$repo_dir/.continuity"
    printf '%s' "$repo_dir"
}

# add_conflict <repo_dir> <repo_path> <remote_bytes> <local_bytes> <remote_ts> <local_ts>
# Writes canonical (remote) bytes, the .local (local) bytes, and a v2
# .conflict. Empty timestamp args => nullable field.
add_conflict() {
    local repo_dir repo_path remote_bytes local_bytes remote_ts local_ts
    repo_dir="$1"; repo_path="$2"; remote_bytes="$3"; local_bytes="$4"
    remote_ts="$5"; local_ts="$6"

    local dir_part identity class
    dir_part=$(dirname "$repo_path")
    mkdir -p "$repo_dir/$dir_part"
    printf '%s' "$remote_bytes" > "$repo_dir/$repo_path"
    printf '%s' "$local_bytes" > "$repo_dir/$repo_path.my-brick.local"
    identity=$(printf '%s' "$repo_path" | sed 's/\.srm$//; s/\.sav$//; s/\.rtc$//')
    case "$repo_path" in
        *.rtc) class="rtc" ;;
        *)     class="srm" ;;
    esac
    printf '{\n  "_schema_version": "2.0",\n  "file": "%s",\n  "identity": "%s",\n  "class": "%s",\n  "remote_device": "my-deck",\n  "remote_timestamp": "%s",\n  "local_device": "my-brick",\n  "local_timestamp": "%s",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
        "$repo_path" "$identity" "$class" "$remote_ts" "$local_ts" \
        > "$repo_dir/$repo_path.conflict"

    # Make sure a device saves dir exists so ch_try_version can materialize.
    local system_dir local_dir
    system_dir=$(printf '%s' "$repo_path" | sed 's|/.*||')
    local_dir=$(printf '%s\n' "$_pm_reverse_map" | grep "^${system_dir}=" | sed 's/^[^=]*=//')
    [ -n "$local_dir" ] && mkdir -p "$CONTINUITY_SAVES_ROOT/$local_dir"
}

commit_repo() {
    "$CONTINUITY_GIT_BIN" -C "$1" add . >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$1" commit -m "conflict state" >/dev/null 2>&1
}

TS_OLD="2026-03-12T13:00:00Z"
TS_NEW="2026-03-12T15:00:00Z"

# ============================================================
# cu_list_groups / cu_group_members — grouping by identity
# ============================================================
printf '\n=== grouping ===\n' >&2

repo=$(new_repo grp1)
add_conflict "$repo" "gb/Pokemon Crystal.srm" "remote-srm" "local-srm" "$TS_OLD" "$TS_NEW"
add_conflict "$repo" "gb/Pokemon Crystal.rtc" "remote-rtc" "local-rtc" "$TS_OLD" "$TS_NEW"
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"

groups=$(cu_list_groups "$repo")
group_count=$(printf '%s\n' "$groups" | grep -c '.')
assert_eq "cu_list_groups: 2 groups (srm+rtc collapse)" "2" "$group_count"
assert_contains "cu_list_groups: has Pokemon identity" "$groups" "gb/Pokemon Crystal"
assert_contains "cu_list_groups: has Metroid identity" "$groups" "snes/Super Metroid"

members=$(cu_group_members "$repo" "gb/Pokemon Crystal")
member_count=$(printf '%s\n' "$members" | grep -c '.')
assert_eq "cu_group_members: Pokemon group has 2 files" "2" "$member_count"
assert_contains "cu_group_members: includes .srm" "$members" "gb/Pokemon Crystal.srm"
assert_contains "cu_group_members: includes .rtc" "$members" "gb/Pokemon Crystal.rtc"

info=$(cu_group_info "$repo" "gb/Pokemon Crystal")
assert_contains "cu_group_info: game" "$info" "game=Pokemon Crystal"
assert_contains "cu_group_info: remote_device" "$info" "remote_device=my-deck"
assert_contains "cu_group_info: local_device" "$info" "local_device=my-brick"
assert_contains "cu_group_info: not trying" "$info" "trying=no"
assert_contains "cu_group_info: member_count 2" "$info" "member_count=2"

label=$(cu_group_label "$repo" "gb/Pokemon Crystal")
assert_contains "cu_group_label: game + devices" "$label" "Pokemon Crystal — my-deck vs my-brick"

# ============================================================
# cu_run: empty state
# ============================================================
printf '\n=== empty state ===\n' >&2
empty_repo=$(new_repo empty)
"$CONTINUITY_GIT_BIN" -C "$empty_repo" commit --allow-empty -m init >/dev/null 2>&1
pal_ui_seed
cu_run "$empty_repo"
render=$(cat "$PAL_UI_RENDER")
assert_contains "cu_run empty: shows in-sync message" "$render" "No conflicts. Everything's in sync."

# ============================================================
# UNRESOLVED -> RESOLVED: keep remote
# ============================================================
printf '\n=== keep remote ===\n' >&2
repo=$(new_repo keepr)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
# list: pick group 0; detail: item 2 (Keep remote); confirm: yes
pal_ui_seed 0 2 yes
cu_run "$repo"
canonical=$(cat "$repo/snes/Super Metroid.sav")
assert_eq "keep_remote: canonical is remote bytes" "remote-sav" "$canonical"
assert_file_not_exists "keep_remote: .conflict removed" "$repo/snes/Super Metroid.sav.conflict"
assert_file_not_exists "keep_remote: .local removed" "$repo/snes/Super Metroid.sav.my-brick.local"

# ============================================================
# UNRESOLVED -> RESOLVED: keep local
# ============================================================
printf '\n=== keep local ===\n' >&2
repo=$(new_repo keepl)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
# list 0; detail item 3 (Keep local); confirm yes
pal_ui_seed 0 3 yes
cu_run "$repo"
canonical=$(cat "$repo/snes/Super Metroid.sav")
assert_eq "keep_local: canonical is local bytes" "local-sav" "$canonical"
assert_file_not_exists "keep_local: .conflict removed" "$repo/snes/Super Metroid.sav.conflict"

# ============================================================
# Keep, but user declines the confirm -> nothing resolved
# ============================================================
printf '\n=== decline confirm ===\n' >&2
repo=$(new_repo decline)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
# list 0; detail 2 (keep remote); confirm NO; back to detail; then list cancel; exit
# after 'no' we loop in cu_detail; feed a Back (5) then list will re-show, cancel.
pal_ui_seed 0 2 no 5 cancel
cu_run "$repo"
assert_file_exists "decline: .conflict still present" "$repo/snes/Super Metroid.sav.conflict"

# ============================================================
# keep_newest: happy path (local newer) and missing-timestamp fallback
# ============================================================
printf '\n=== keep_newest ===\n' >&2
repo=$(new_repo newest)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
# list 0; detail 4 (keep newest); confirm yes
pal_ui_seed 0 4 yes
cu_run "$repo"
canonical=$(cat "$repo/snes/Super Metroid.sav")
assert_eq "keep_newest: local newer wins" "local-sav" "$canonical"

repo=$(new_repo newest_missing)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "" "$TS_NEW"
commit_repo "$repo"
# list 0; detail 4 (keep newest) -> missing remote ts -> message + continue;
# then detail 5 (Back); list cancel
pal_ui_seed 0 4 5 cancel
cu_run "$repo"
render=$(cat "$PAL_UI_RENDER")
assert_contains "keep_newest missing ts: manual fallback message" "$render" "device clocks aren't reliable"
assert_file_exists "keep_newest missing ts: unresolved (no guess)" "$repo/snes/Super Metroid.sav.conflict"

# ============================================================
# Group resolution: .srm + .rtc resolve to the SAME side (keep local)
# ============================================================
printf '\n=== group resolution ===\n' >&2
repo=$(new_repo group_keep)
add_conflict "$repo" "gb/Pokemon Crystal.srm" "remote-srm" "local-srm" "$TS_OLD" "$TS_NEW"
add_conflict "$repo" "gb/Pokemon Crystal.rtc" "remote-rtc" "local-rtc" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
# list 0; detail 3 (keep local); confirm yes
pal_ui_seed 0 3 yes
cu_run "$repo"
srm=$(cat "$repo/gb/Pokemon Crystal.srm")
rtc=$(cat "$repo/gb/Pokemon Crystal.rtc")
assert_eq "group keep_local: .srm is local" "local-srm" "$srm"
assert_eq "group keep_local: .rtc is local" "local-rtc" "$rtc"
assert_file_not_exists "group keep_local: .srm conflict gone" "$repo/gb/Pokemon Crystal.srm.conflict"
assert_file_not_exists "group keep_local: .rtc conflict gone" "$repo/gb/Pokemon Crystal.rtc.conflict"

# ============================================================
# TRYING: try local loads BOTH members into the live slot, marks trying
# ============================================================
printf '\n=== try (group) ===\n' >&2
repo=$(new_repo try_group)
add_conflict "$repo" "gb/Pokemon Crystal.srm" "remote-srm" "local-srm" "$TS_OLD" "$TS_NEW"
add_conflict "$repo" "gb/Pokemon Crystal.rtc" "remote-rtc" "local-rtc" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
# list 0; detail item 1 (Try local) -> handoff, returns
pal_ui_seed 0 1
cu_run "$repo"
rc=0; ch_is_trying "$repo" "gb/Pokemon Crystal.srm" || rc=$?
assert_rc "try_group: .srm marked trying" 0 "$rc"
rc=0; ch_is_trying "$repo" "gb/Pokemon Crystal.rtc" || rc=$?
assert_rc "try_group: .rtc marked trying" 0 "$rc"
active=$(ch_get_active_version "$repo" "gb/Pokemon Crystal.srm")
assert_eq "try_group: active is local" "local" "$active"

# ============================================================
# TRYING -> cancel-try (discard) -> back to UNRESOLVED
# ============================================================
printf '\n=== cancel-try ===\n' >&2
# reuse try_group repo which is now TRYING. Reopen:
# detail (trying) item 2 (Discard try) -> back to unresolved detail;
# then item 5 (Back to list); list cancel
pal_ui_seed 0 2 5 cancel
cu_run "$repo"
rc=0; ch_is_trying "$repo" "gb/Pokemon Crystal.srm" || rc=$?
assert_rc "cancel-try: .srm no longer trying" 1 "$rc"
assert_file_exists "cancel-try: conflict preserved" "$repo/gb/Pokemon Crystal.srm.conflict"

# ============================================================
# TRYING -> keep the tried side (no play) -> resolved to that side
# ============================================================
printf '\n=== keep tried side ===\n' >&2
repo=$(new_repo keep_tried)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
pal_ui_seed 0 1                 # try local
cu_run "$repo"
pal_ui_seed 0 0 yes             # detail(trying): item 0 keep active; confirm yes
cu_run "$repo"
canonical=$(cat "$repo/snes/Super Metroid.sav")
assert_eq "keep tried: canonical is local (the tried side)" "local-sav" "$canonical"
assert_file_not_exists "keep tried: conflict removed" "$repo/snes/Super Metroid.sav.conflict"

# ============================================================
# TRYING-MODIFIED: try, play-on (mutate slot), then promote the 3rd version
# ============================================================
printf '\n=== trying-modified promote ===\n' >&2
repo=$(new_repo promote)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
pal_ui_seed 0 1                 # try local -> loads into live slot
cu_run "$repo"
# Simulate playing: mutate the device's live slot to a NEW third version.
device_path=$(ch_try_version "$repo" "snes/Super Metroid.sav" "local" 2>/dev/null)
printf 'PLAYED-third-version' > "$device_path"
rc=0; ch_is_trying_modified "$repo" "snes/Super Metroid.sav" || rc=$?
assert_rc "promote: played-on detected (trying-modified)" 0 "$rc"
# Reopen: detail(trying-modified) item 0 (Keep your progress) -> promote
pal_ui_seed 0 0
cu_run "$repo"
canonical=$(cat "$repo/snes/Super Metroid.sav")
assert_eq "promote: canonical is the played third version" "PLAYED-third-version" "$canonical"
assert_file_not_exists "promote: conflict removed" "$repo/snes/Super Metroid.sav.conflict"

# ============================================================
# TRYING-MODIFIED guard: choosing 'discard & pick again' needs explicit
# confirm; the third version is never silently discarded.
# ============================================================
printf '\n=== trying-modified discard guard ===\n' >&2
repo=$(new_repo tm_guard)
add_conflict "$repo" "snes/Super Metroid.sav" "remote-sav" "local-sav" "$TS_OLD" "$TS_NEW"
commit_repo "$repo"
pal_ui_seed 0 1
cu_run "$repo"
device_path=$(ch_try_version "$repo" "snes/Super Metroid.sav" "local" 2>/dev/null)
printf 'PLAYED-third' > "$device_path"
# detail(trying-modified) item 1 (Discard and pick again); confirm NO ->
# stays trying-modified; then item 2 (Back to list); list cancel
pal_ui_seed 0 1 no 2 cancel
cu_run "$repo"
render=$(cat "$PAL_UI_RENDER")
assert_contains "tm guard: asked to confirm discard of progress" "$render" "Discard your progress"
rc=0; ch_is_trying_modified "$repo" "snes/Super Metroid.sav" || rc=$?
assert_rc "tm guard: still trying-modified after declining" 0 "$rc"

# --- Results ---
printf '\n=== conflict_ui: %s passed, %s failed ===\n' "$passed" "$failed" >&2
[ "$failed" -eq 0 ]
