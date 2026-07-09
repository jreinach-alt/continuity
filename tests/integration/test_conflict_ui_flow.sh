#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: the conflict_ui.sh controller end-to-end over the test
# PAL and a REAL two-device file:// remote. Conflicts are produced by the
# actual engine (ch_handle_pull_conflict → v2 .conflict), then resolved
# through cu_run, asserting on-repo artifacts, canonical bytes, and pushes.
#
# Covers: group .srm+.rtc resolution as a unit; try → play-on → promote the
# third version; offline resolution queues and pushes on recovery.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
assert_rc() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" -eq "$actual" ]; then passed=$((passed + 1)); else
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
. "$PROJECT_ROOT/src/core/change_detector.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"
. "$PROJECT_ROOT/src/core/conflict_ui.sh"

pal_validate

cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

CONTINUITY_DEVICE_NAME="device-b"

REMOTE_DIR="$TEST_TMPDIR/remote.git"
DEVICE_A="$TEST_TMPDIR/device_a"
DEVICE_B="$TEST_TMPDIR/device_b"

"$CONTINUITY_GIT_BIN" init --bare "$REMOTE_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" symbolic-ref HEAD refs/heads/main 2>/dev/null

SEED_DIR="$TEST_TMPDIR/seed"
"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$SEED_DIR" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" checkout -b main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.email "seed@test"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" config user.name "Seed"
mkdir -p "$SEED_DIR/gb"
printf 'seed-srm' > "$SEED_DIR/gb/Pokemon Crystal.srm"
printf 'seed-rtc' > "$SEED_DIR/gb/Pokemon Crystal.rtc"
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" add . >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" commit -m "seed" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$SEED_DIR" push origin main >/dev/null 2>&1

"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$DEVICE_A" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" checkout main >/dev/null 2>&1 || true
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config user.email "continuity@device-a"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config user.name "Continuity"
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" config commit.gpgsign false

"$CONTINUITY_GIT_BIN" clone "file://$REMOTE_DIR" "$DEVICE_B" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$DEVICE_B" checkout main >/dev/null 2>&1 || true
se_init "$DEVICE_B" "device-b" >/dev/null 2>&1
mkdir -p "$DEVICE_B/.continuity"
head_hash=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
cs_store_commit "$DEVICE_B" "$head_hash"

mkdir -p "$CONTINUITY_SAVES_ROOT/GB"

# a_commit — device-a writes bytes to a save + commits with device/timestamp
# trailer (so ch_preserve_conflict parses remote_device), then pushes.
a_commit() {
    local path bytes ts
    path="$1"; bytes="$2"; ts="$3"
    printf '%s' "$bytes" > "$DEVICE_A/$path"
    "$CONTINUITY_GIT_BIN" -C "$DEVICE_A" add "$path" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$DEVICE_A" commit \
        -m "$(printf 'save\n\ndevice: device-a\ntimestamp: %s' "$ts")" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$DEVICE_A" push origin main >/dev/null 2>&1
}
b_commit() {
    local path bytes
    path="$1"; bytes="$2"
    printf '%s' "$bytes" > "$DEVICE_B/$path"
    "$CONTINUITY_GIT_BIN" -C "$DEVICE_B" add "$path" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$DEVICE_B" commit -m "device-b save" >/dev/null 2>&1
}

# ============================================================
# Scenario A: two-device GROUP conflict (.srm + .rtc), resolved keep_local
# through cu_run — both members land on local, and the resolution is pushed.
# ============================================================
printf '\n=== Scenario A: group keep_local via cu_run ===\n' >&2

a_commit "gb/Pokemon Crystal.srm" "a-srm" "2026-03-12T13:00:00Z"
a_commit "gb/Pokemon Crystal.rtc" "a-rtc" "2026-03-12T13:00:00Z"
b_commit "gb/Pokemon Crystal.srm" "b-srm"
b_commit "gb/Pokemon Crystal.rtc" "b-rtc"

ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

# Real engine wrote v2 .conflict (AC 5)
conflict_json=$(cat "$DEVICE_B/gb/Pokemon Crystal.srm.conflict")
assert_contains "A: engine wrote v2 schema" "$conflict_json" '"_schema_version": "2.0"'
assert_contains "A: v2 identity" "$conflict_json" '"identity": "gb/Pokemon Crystal"'
assert_contains "A: v2 class srm" "$conflict_json" '"class": "srm"'

# One game group, two members
groups=$(cu_list_groups "$DEVICE_B")
assert_eq "A: one group" "1" "$(printf '%s\n' "$groups" | grep -c '.')"
assert_eq "A: two members" "2" "$(cu_group_members "$DEVICE_B" "gb/Pokemon Crystal" | grep -c '.')"

remote_before=$("$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" rev-parse refs/heads/main)

# Resolve keep_local through the UI: list 0; detail item 3 (Keep local); yes
pal_ui_seed 0 3 yes
cu_run "$DEVICE_B"

assert_eq "A: .srm canonical is local" "b-srm" "$(cat "$DEVICE_B/gb/Pokemon Crystal.srm")"
assert_eq "A: .rtc canonical is local" "b-rtc" "$(cat "$DEVICE_B/gb/Pokemon Crystal.rtc")"
assert_file_not_exists "A: .srm conflict gone" "$DEVICE_B/gb/Pokemon Crystal.srm.conflict"
assert_file_not_exists "A: .rtc conflict gone" "$DEVICE_B/gb/Pokemon Crystal.rtc.conflict"
assert_eq "A: no conflicts remain" "0" "$(ch_count_conflicts "$DEVICE_B")"

# Pushed: the bare remote advanced past its pre-resolve tip, and its tip
# matches device-b's HEAD.
remote_after=$("$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" rev-parse refs/heads/main)
local_head=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)
if [ "$remote_after" != "$remote_before" ]; then passed=$((passed + 1)); else
    printf 'FAIL: A: remote advanced after resolve\n' >&2; failed=$((failed + 1))
fi
assert_eq "A: remote tip == device-b HEAD (pushed)" "$local_head" "$remote_after"

# ============================================================
# Scenario B: try → play-on → promote the third version, across two cu_run
# invocations (the real relaunch pattern). The played version becomes
# canonical and is pushed.
# ============================================================
printf '\n=== Scenario B: try, play-on, promote ===\n' >&2

# Fresh conflict on the .srm only.
"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1
a_commit "gb/Pokemon Crystal.srm" "a2-srm" "2026-03-13T09:00:00Z"
b_commit "gb/Pokemon Crystal.srm" "b2-srm"
ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1
assert_eq "B: conflict present" "1" "$(ch_count_conflicts "$DEVICE_B")"

# cu_run #1: list 0; detail item 0 (Try remote) → loads into live slot, hands off
pal_ui_seed 0 0
cu_run "$DEVICE_B"
rc=0; ch_is_trying "$DEVICE_B" "gb/Pokemon Crystal.srm" || rc=$?
assert_rc "B: trying after cu_run try" 0 "$rc"

# Simulate the user playing on the tried copy: mutate the live device slot.
device_path=$(pm_canonical_to_device "gb/Pokemon Crystal.srm")
printf 'b2-played-further' > "$device_path"
rc=0; ch_is_trying_modified "$DEVICE_B" "gb/Pokemon Crystal.srm" || rc=$?
assert_rc "B: played-on detected" 0 "$rc"

remote_before=$("$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" rev-parse refs/heads/main)

# cu_run #2 (relaunch): detail(trying-modified) item 0 (Keep your progress) → promote
pal_ui_seed 0 0
cu_run "$DEVICE_B"
assert_eq "B: canonical is the played third version" "b2-played-further" "$(cat "$DEVICE_B/gb/Pokemon Crystal.srm")"
assert_eq "B: no conflicts remain" "0" "$(ch_count_conflicts "$DEVICE_B")"
remote_after=$("$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" rev-parse refs/heads/main)
if [ "$remote_after" != "$remote_before" ]; then passed=$((passed + 1)); else
    printf 'FAIL: B: remote advanced after promote\n' >&2; failed=$((failed + 1))
fi

# ============================================================
# Scenario C: offline resolution queues locally, then pushes on recovery.
# ============================================================
printf '\n=== Scenario C: offline resolution queues, pushes on recovery ===\n' >&2

"$CONTINUITY_GIT_BIN" -C "$DEVICE_A" pull origin main >/dev/null 2>&1
a_commit "gb/Pokemon Crystal.srm" "a3-srm" "2026-03-14T09:00:00Z"
b_commit "gb/Pokemon Crystal.srm" "b3-srm"
ch_handle_pull_conflict "$DEVICE_B" >/dev/null 2>&1

remote_before=$("$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" rev-parse refs/heads/main)

# Go offline for the resolution.
pal_is_online() { return 1; }
pal_ui_seed 0 2 yes   # list 0; detail Keep remote; yes
cu_run "$DEVICE_B"
assert_eq "C: resolved locally (canonical remote)" "a3-srm" "$(cat "$DEVICE_B/gb/Pokemon Crystal.srm")"
assert_eq "C: no conflicts remain" "0" "$(ch_count_conflicts "$DEVICE_B")"
remote_mid=$("$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" rev-parse refs/heads/main)
assert_eq "C: remote unchanged while offline (queued)" "$remote_before" "$remote_mid"
local_head=$("$CONTINUITY_GIT_BIN" -C "$DEVICE_B" rev-parse HEAD)

# Recover connectivity and flush the queued commit.
pal_is_online() { return 0; }
se_push "$DEVICE_B" >/dev/null 2>&1
remote_after=$("$CONTINUITY_GIT_BIN" -C "$REMOTE_DIR" rev-parse refs/heads/main)
assert_eq "C: pushed on recovery (remote == local HEAD)" "$local_head" "$remote_after"

# --- Results ---
printf '\n=== conflict_ui_flow: %s passed, %s failed ===\n' "$passed" "$failed" >&2
[ "$failed" -eq 0 ]
