#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC2154
# Unit tests for Sprint 0.9 conflict resolution operations
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

assert_file_not_exists() {
    local desc filepath
    desc="$1"; filepath="$2"
    if [ ! -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file should not exist: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_files_identical() {
    local desc file_a file_b
    desc="$1"; file_a="$2"; file_b="$3"
    if cmp -s "$file_a" "$file_b"; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  files differ: %s vs %s\n' "$desc" "$file_a" "$file_b" >&2
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

assert_not_contains() {
    local desc text pattern
    desc="$1"; text="$2"; pattern="$3"
    case "$text" in
        *"$pattern"*)
            printf 'FAIL: %s\n  text should not contain: %s\n' "$desc" "$pattern" >&2
            failed=$((failed + 1))
            ;;
        *)
            passed=$((passed + 1))
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
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/conflict_handler.sh"

pal_validate

# Load platform map
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$(pal_get_platform_map)"
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

CONTINUITY_DEVICE_NAME="my-brick"

# ============================
# Helper: create a minimal repo with a conflict
# Sets up: canonical .srm (remote bytes), .local file (local bytes), .conflict JSON
# Also sets up a mock device saves directory
# Returns: repo_dir (space separated, just one value)
# ============================
create_test_conflict() {
    local test_id repo_path local_device remote_device
    test_id="$1"
    repo_path="$2"
    local_device="$3"
    remote_device="$4"

    local repo_dir
    repo_dir="$TEST_TMPDIR/${test_id}_repo"

    # Init a git repo
    "$CONTINUITY_GIT_BIN" init "$repo_dir" >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.email "test@test"
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" config user.name "Test"
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" checkout -b main >/dev/null 2>&1 || true

    # Create canonical .srm with "remote" bytes
    local dir_part
    dir_part=$(dirname "$repo_path")
    mkdir -p "$repo_dir/$dir_part"
    printf 'remote-save-bytes' > "$repo_dir/$repo_path"

    # Create .local file with "local" bytes
    printf 'local-save-bytes' > "$repo_dir/$repo_path.$local_device.local"

    # Create .conflict JSON (schema v2)
    local identity class
    identity=$(printf '%s' "$repo_path" | sed 's/\.srm$//; s/\.sav$//; s/\.rtc$//')
    case "$repo_path" in
        *.rtc) class="rtc" ;;
        *)     class="srm" ;;
    esac
    printf '{\n  "_schema_version": "2.0",\n  "file": "%s",\n  "identity": "%s",\n  "class": "%s",\n  "remote_device": "%s",\n  "remote_timestamp": "2026-03-12T13:00:00Z",\n  "local_device": "%s",\n  "local_timestamp": "2026-03-12T14:30:00Z",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
        "$repo_path" "$identity" "$class" "$remote_device" "$local_device" \
        > "$repo_dir/$repo_path.conflict"

    # Create .continuity dir
    mkdir -p "$repo_dir/.continuity"

    # Commit everything
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" add . >/dev/null 2>&1
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" commit -m "initial conflict state" >/dev/null 2>&1

    # Create device saves directory
    local system_dir
    system_dir=$(printf '%s' "$repo_path" | sed 's|/.*||')
    local local_dir
    local_dir=$(printf '%s\n' "$_pm_reverse_map" | grep "^${system_dir}=" | sed 's/^[^=]*=//')
    if [ -n "$local_dir" ]; then
        mkdir -p "$CONTINUITY_SAVES_ROOT/$local_dir"
    fi

    printf '%s' "$repo_dir"
}

# ============================
# Tests for ch_get_conflict_info
# ============================
printf '\n=== ch_get_conflict_info tests ===\n' >&2

# Test: parse valid .conflict file — all 12 fields present (v2 adds
# identity + class, read straight from the record)
repo_dir=$(create_test_conflict "gci1" "snes/super_metroid.srm" "my-brick" "my-deck")
output=$(ch_get_conflict_info "$repo_dir" "snes/super_metroid.srm" 2>/dev/null)
rc=$?
assert_rc "gci1: returns 0" 0 "$rc"
assert_contains "gci1: file field" "$output" "file=snes/super_metroid.srm"
assert_contains "gci1: identity field" "$output" "identity=snes/super_metroid"
assert_contains "gci1: class field" "$output" "class=srm"
assert_contains "gci1: system field" "$output" "system=snes"
assert_contains "gci1: game field" "$output" "game=super_metroid"
assert_contains "gci1: remote_device field" "$output" "remote_device=my-deck"
assert_contains "gci1: remote_timestamp field" "$output" "remote_timestamp=2026-03-12T13:00:00Z"
assert_contains "gci1: local_device field" "$output" "local_device=my-brick"
assert_contains "gci1: local_timestamp field" "$output" "local_timestamp=2026-03-12T14:30:00Z"
assert_contains "gci1: status field" "$output" "status=unresolved"
assert_contains "gci1: active_version default remote" "$output" "active_version=remote"
assert_contains "gci1: trying_modified default no" "$output" "trying_modified=no"

# Verify 12 lines of output
line_count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
assert_eq "gci1: 12 key-value lines" "12" "$line_count"

# Test: system and game derivation for gb path
repo_dir=$(create_test_conflict "gci2" "gb/pokemon_red.srm" "my-brick" "my-deck")
output=$(ch_get_conflict_info "$repo_dir" "gb/pokemon_red.srm" 2>/dev/null)
assert_contains "gci2: system=gb" "$output" "system=gb"
assert_contains "gci2: game=pokemon_red" "$output" "game=pokemon_red"

# Test: missing .conflict → returns 1
repo_dir=$(create_test_conflict "gci3" "snes/super_metroid.srm" "my-brick" "my-deck")
rc=0
ch_get_conflict_info "$repo_dir" "snes/nonexistent.srm" 2>/dev/null || rc=$?
assert_rc "gci3: missing .conflict returns 1" 1 "$rc"

# Test: active_version = local after writing try marker
repo_dir=$(create_test_conflict "gci4" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
output=$(ch_get_conflict_info "$repo_dir" "snes/super_metroid.srm" 2>/dev/null)
assert_contains "gci4: active_version=local" "$output" "active_version=local"
assert_contains "gci4: trying_modified=no" "$output" "trying_modified=no"

# Test: trying_modified=yes after modifying device save
repo_dir=$(create_test_conflict "gci5" "snes/super_metroid.srm" "my-brick" "my-deck")
device_path=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
printf 'extra' >> "$device_path"
output=$(ch_get_conflict_info "$repo_dir" "snes/super_metroid.srm" 2>/dev/null)
assert_contains "gci5: trying_modified=yes" "$output" "trying_modified=yes"

# Test: missing required fields → returns 1
repo_dir="$TEST_TMPDIR/gci6_repo"
mkdir -p "$repo_dir/snes"
printf '{\n  "file": "snes/test.srm"\n}\n' > "$repo_dir/snes/test.srm.conflict"
rc=0
ch_get_conflict_info "$repo_dir" "snes/test.srm" 2>/dev/null || rc=$?
assert_rc "gci6: missing fields returns 1" 1 "$rc"

# ============================
# Tests for ch_list_conflicts_detailed
# ============================
printf '\n=== ch_list_conflicts_detailed tests ===\n' >&2

# Test: no conflicts → empty output
repo_dir="$TEST_TMPDIR/lcd1_repo"
"$CONTINUITY_GIT_BIN" init "$repo_dir" >/dev/null 2>&1
output=$(ch_list_conflicts_detailed "$repo_dir" 2>/dev/null)
rc=$?
assert_rc "lcd1: returns 0" 0 "$rc"
assert_eq "lcd1: empty output" "" "$output"

# Test: one conflict → one block
repo_dir=$(create_test_conflict "lcd2" "snes/super_metroid.srm" "my-brick" "my-deck")
output=$(ch_list_conflicts_detailed "$repo_dir" 2>/dev/null)
assert_contains "lcd2: has file field" "$output" "file=snes/super_metroid.srm"
assert_contains "lcd2: has system field" "$output" "system=snes"
assert_contains "lcd2: has 10 fields" "$output" "trying_modified="

# Test: two conflicts → two blocks separated by blank line
repo_dir=$(create_test_conflict "lcd3" "snes/super_metroid.srm" "my-brick" "my-deck")
# Add a second conflict
mkdir -p "$repo_dir/gb"
printf 'remote-gb' > "$repo_dir/gb/pokemon_red.srm"
printf 'local-gb' > "$repo_dir/gb/pokemon_red.srm.my-brick.local"
printf '{\n  "_schema_version": "1.0",\n  "file": "gb/pokemon_red.srm",\n  "remote_device": "my-deck",\n  "remote_timestamp": "2026-03-12T11:00:00Z",\n  "local_device": "my-brick",\n  "local_timestamp": "2026-03-12T12:00:00Z",\n  "status": "unresolved"\n}\n' \
    > "$repo_dir/gb/pokemon_red.srm.conflict"
"$CONTINUITY_GIT_BIN" -C "$repo_dir" add . >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" commit -m "add gb conflict" >/dev/null 2>&1

output=$(ch_list_conflicts_detailed "$repo_dir" 2>/dev/null)
assert_contains "lcd3: has snes conflict" "$output" "file=snes/super_metroid.srm"
assert_contains "lcd3: has gb conflict" "$output" "file=gb/pokemon_red.srm"

# ============================
# Tests for ch_count_conflicts
# ============================
printf '\n=== ch_count_conflicts tests ===\n' >&2

# Test: no conflicts → 0
repo_dir="$TEST_TMPDIR/cc1_repo"
"$CONTINUITY_GIT_BIN" init "$repo_dir" >/dev/null 2>&1
output=$(ch_count_conflicts "$repo_dir" 2>/dev/null)
assert_eq "cc1: zero conflicts" "0" "$output"

# Test: one conflict → 1
repo_dir=$(create_test_conflict "cc2" "snes/super_metroid.srm" "my-brick" "my-deck")
output=$(ch_count_conflicts "$repo_dir" 2>/dev/null)
assert_eq "cc2: one conflict" "1" "$output"

# Test: three conflicts → 3
repo_dir=$(create_test_conflict "cc3" "snes/super_metroid.srm" "my-brick" "my-deck")
mkdir -p "$repo_dir/gb" "$repo_dir/gba"
printf '{}' > "$repo_dir/gb/pokemon.srm.conflict"
printf '{}' > "$repo_dir/gba/minish.srm.conflict"
output=$(ch_count_conflicts "$repo_dir" 2>/dev/null)
assert_eq "cc3: three conflicts" "3" "$output"

# ============================
# Tests for ch_try_version
# ============================
printf '\n=== ch_try_version tests ===\n' >&2

# Test: try remote — device save matches canonical .srm
repo_dir=$(create_test_conflict "tv1" "snes/super_metroid.srm" "my-brick" "my-deck")
device_path=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "remote" 2>/dev/null)
rc=$?
assert_rc "tv1: try remote returns 0" 0 "$rc"
assert_files_identical "tv1: device save matches canonical" \
    "$repo_dir/snes/super_metroid.srm" "$device_path"

# Test: try local — device save matches .local file
repo_dir=$(create_test_conflict "tv2" "snes/super_metroid.srm" "my-brick" "my-deck")
device_path=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
rc=$?
assert_rc "tv2: try local returns 0" 0 "$rc"
assert_files_identical "tv2: device save matches .local" \
    "$repo_dir/snes/super_metroid.srm.my-brick.local" "$device_path"

# Test: try with nonexistent conflict → returns 1
repo_dir=$(create_test_conflict "tv3" "snes/super_metroid.srm" "my-brick" "my-deck")
rc=0
ch_try_version "$repo_dir" "snes/nonexistent.srm" "remote" >/dev/null 2>&1 || rc=$?
assert_rc "tv3: no conflict returns 1" 1 "$rc"

# Test: try with invalid version → returns 1
repo_dir=$(create_test_conflict "tv4" "snes/super_metroid.srm" "my-brick" "my-deck")
rc=0
ch_try_version "$repo_dir" "snes/super_metroid.srm" "bogus" >/dev/null 2>&1 || rc=$?
assert_rc "tv4: invalid version returns 1" 1 "$rc"

# Test: try with unmapped system → returns 1
repo_dir=$(create_test_conflict "tv5" "fakesys/game.srm" "my-brick" "my-deck")
rc=0
ch_try_version "$repo_dir" "fakesys/game.srm" "remote" >/dev/null 2>&1 || rc=$?
assert_rc "tv5: unmapped system returns 1" 1 "$rc"

# Test: no git commits after try
repo_dir=$(create_test_conflict "tv6" "snes/super_metroid.srm" "my-brick" "my-deck")
commit_before=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-list --count HEAD)
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
commit_after=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-list --count HEAD)
assert_eq "tv6: no new commits" "$commit_before" "$commit_after"

# Test: try marker written with all 3 fields
repo_dir=$(create_test_conflict "tv7" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
marker_file="$repo_dir/.continuity/trying/snes_super_metroid.srm"
assert_file_exists "tv7: marker exists" "$marker_file"
marker_content=$(cat "$marker_file")
assert_contains "tv7: marker has version" "$marker_content" "version=local"
assert_contains "tv7: marker has checksum" "$marker_content" "checksum="
assert_contains "tv7: marker has device_path" "$marker_content" "device_path="

# Test: .gitignore created in trying dir
repo_dir=$(create_test_conflict "tv8" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
assert_file_exists "tv8: .gitignore created" "$repo_dir/.continuity/trying/.gitignore"
gi_content=$(cat "$repo_dir/.continuity/trying/.gitignore")
assert_contains "tv8: .gitignore contains *" "$gi_content" "*"
assert_contains "tv8: .gitignore excludes itself" "$gi_content" "!.gitignore"

# Test: try markers not visible to git
repo_dir=$(create_test_conflict "tv9" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
# Add the trying dir's gitignore and commit (may be empty commit if nothing new)
"$CONTINUITY_GIT_BIN" -C "$repo_dir" add .continuity/trying/.gitignore >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" commit -m "add trying gitignore" >/dev/null 2>&1 || true
untracked=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" status --porcelain 2>/dev/null)
assert_not_contains "tv9: markers not in git status" "$untracked" "trying/snes_"

# Test: swap local → remote → local — final has local bytes
repo_dir=$(create_test_conflict "tv10" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
ch_try_version "$repo_dir" "snes/super_metroid.srm" "remote" >/dev/null 2>&1
device_path=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
assert_files_identical "tv10: final swap has local bytes" \
    "$repo_dir/snes/super_metroid.srm.my-brick.local" "$device_path"

# Test: idempotency — two tries with local produce same result
repo_dir=$(create_test_conflict "tv11" "snes/super_metroid.srm" "my-brick" "my-deck")
device_path1=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
device_path2=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
assert_eq "tv11: same device path" "$device_path1" "$device_path2"
assert_files_identical "tv11: idempotent local bytes" \
    "$repo_dir/snes/super_metroid.srm.my-brick.local" "$device_path2"

# ============================
# Tests for ch_is_trying
# ============================
printf '\n=== ch_is_trying tests ===\n' >&2

# Test: no marker → returns 1
repo_dir=$(create_test_conflict "it1" "snes/super_metroid.srm" "my-brick" "my-deck")
rc=0
ch_is_trying "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "it1: no marker returns 1" 1 "$rc"

# Test: after try → returns 0
repo_dir=$(create_test_conflict "it2" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
rc=0
ch_is_trying "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "it2: after try returns 0" 0 "$rc"

# Test: after clear → returns 1
repo_dir=$(create_test_conflict "it3" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "remote" >/dev/null 2>&1
ch_clear_try_markers "$repo_dir"
rc=0
ch_is_trying "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "it3: after clear returns 1" 1 "$rc"

# Test: works with both remote and local
repo_dir=$(create_test_conflict "it4" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "remote" >/dev/null 2>&1
rc=0
ch_is_trying "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "it4: remote try returns 0" 0 "$rc"

# ============================
# Tests for ch_is_trying_modified
# ============================
printf '\n=== ch_is_trying_modified tests ===\n' >&2

# Test: immediately after try → returns 1 (not modified)
repo_dir=$(create_test_conflict "itm1" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
rc=0
ch_is_trying_modified "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "itm1: not modified returns 1" 1 "$rc"

# Test: after modifying device save → returns 0 (modified)
repo_dir=$(create_test_conflict "itm2" "snes/super_metroid.srm" "my-brick" "my-deck")
device_path=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
printf 'gameplay' >> "$device_path"
rc=0
ch_is_trying_modified "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "itm2: modified returns 0" 0 "$rc"

# Test: no marker → returns 1
repo_dir=$(create_test_conflict "itm3" "snes/super_metroid.srm" "my-brick" "my-deck")
rc=0
ch_is_trying_modified "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "itm3: no marker returns 1" 1 "$rc"

# Test: after re-try → returns 1 (checksum refreshed)
repo_dir=$(create_test_conflict "itm4" "snes/super_metroid.srm" "my-brick" "my-deck")
device_path=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
printf 'gameplay' >> "$device_path"
rc=0
ch_is_trying_modified "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "itm4: modified before re-try" 0 "$rc"
# Re-try refreshes checksum
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
rc=0
ch_is_trying_modified "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "itm4: after re-try returns 1" 1 "$rc"

# ============================
# Tests for ch_get_active_version
# ============================
printf '\n=== ch_get_active_version tests ===\n' >&2

# Test: no marker → remote
repo_dir=$(create_test_conflict "gav1" "snes/super_metroid.srm" "my-brick" "my-deck")
output=$(ch_get_active_version "$repo_dir" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "gav1: default remote" "remote" "$output"

# Test: after try local → local
repo_dir=$(create_test_conflict "gav2" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
output=$(ch_get_active_version "$repo_dir" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "gav2: local after try local" "local" "$output"

# Test: after try remote → remote
repo_dir=$(create_test_conflict "gav3" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "remote" >/dev/null 2>&1
output=$(ch_get_active_version "$repo_dir" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "gav3: remote after try remote" "remote" "$output"

# ============================
# Tests for ch_clear_try_markers
# ============================
printf '\n=== ch_clear_try_markers tests ===\n' >&2

# Test: clear with markers → directory empty except .gitignore
repo_dir=$(create_test_conflict "ctm1" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
ch_clear_try_markers "$repo_dir"
marker_count=$(find "$repo_dir/.continuity/trying" -maxdepth 1 -type f ! -name '.gitignore' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "ctm1: no markers after clear" "0" "$marker_count"
assert_file_exists "ctm1: .gitignore preserved" "$repo_dir/.continuity/trying/.gitignore"

# Test: clear with no markers → returns 0
repo_dir=$(create_test_conflict "ctm2" "snes/super_metroid.srm" "my-brick" "my-deck")
rc=0
ch_clear_try_markers "$repo_dir" || rc=$?
assert_rc "ctm2: idempotent returns 0" 0 "$rc"

# Test: after clear, get_active_version returns remote
repo_dir=$(create_test_conflict "ctm3" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
ch_clear_try_markers "$repo_dir"
output=$(ch_get_active_version "$repo_dir" "snes/super_metroid.srm" 2>/dev/null)
assert_eq "ctm3: remote after clear" "remote" "$output"

# ============================
# Tests for ch_promote_trying
# ============================
printf '\n=== ch_promote_trying tests ===\n' >&2

# Test: promote modified trying version
repo_dir=$(create_test_conflict "pt1" "snes/super_metroid.srm" "my-brick" "my-deck")
# Need a remote for push
remote_dir="$TEST_TMPDIR/pt1_remote.git"
"$CONTINUITY_GIT_BIN" init --bare "$remote_dir" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" remote add origin "file://$remote_dir" >/dev/null 2>&1 || \
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" remote set-url origin "file://$remote_dir" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" push -u origin main >/dev/null 2>&1

device_path=$(ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" 2>/dev/null)
printf 'new-gameplay-progress' > "$device_path"

rc=0
ch_promote_trying "$repo_dir" "snes/super_metroid.srm" 2>/dev/null || rc=$?
assert_rc "pt1: promote returns 0" 0 "$rc"

# Canonical .srm matches device bytes
srm_content=$(cat "$repo_dir/snes/super_metroid.srm")
assert_eq "pt1: canonical has new progress" "new-gameplay-progress" "$srm_content"

# .local and .conflict removed
assert_file_not_exists "pt1: .local removed" "$repo_dir/snes/super_metroid.srm.my-brick.local"
assert_file_not_exists "pt1: .conflict removed" "$repo_dir/snes/super_metroid.srm.conflict"

# Git commit created with "promote" in message
latest_msg=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" log -1 --format="%s")
assert_contains "pt1: commit has promote" "$latest_msg" "promote"

# Try marker removed
rc=0
ch_is_trying "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "pt1: marker removed" 1 "$rc"

# Count conflicts = 0
count=$(ch_count_conflicts "$repo_dir" 2>/dev/null)
assert_eq "pt1: zero conflicts after promote" "0" "$count"

# Test: non-modified trying → returns 1
repo_dir=$(create_test_conflict "pt2" "snes/super_metroid.srm" "my-brick" "my-deck")
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1
rc=0
ch_promote_trying "$repo_dir" "snes/super_metroid.srm" 2>/dev/null || rc=$?
assert_rc "pt2: non-modified returns 1" 1 "$rc"

# Test: no trying state → returns 1
repo_dir=$(create_test_conflict "pt3" "snes/super_metroid.srm" "my-brick" "my-deck")
rc=0
ch_promote_trying "$repo_dir" "snes/super_metroid.srm" 2>/dev/null || rc=$?
assert_rc "pt3: no trying returns 1" 1 "$rc"

# ============================
# Tests for ch_resolve device save update
# ============================
printf '\n=== ch_resolve device save update tests ===\n' >&2

# Test: keep_remote → device save has remote bytes, try marker removed
repo_dir=$(create_test_conflict "rds1" "snes/super_metroid.srm" "my-brick" "my-deck")
remote_dir="$TEST_TMPDIR/rds1_remote.git"
"$CONTINUITY_GIT_BIN" init --bare "$remote_dir" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" remote add origin "file://$remote_dir" >/dev/null 2>&1 || \
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" remote set-url origin "file://$remote_dir" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" push -u origin main >/dev/null 2>&1

# Create a try marker first
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1

# Store commit for cs_store_commit to work
mkdir -p "$repo_dir/.continuity"
head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
cs_store_commit "$repo_dir" "$head_hash"

rc=0
ch_resolve "$repo_dir" "snes/super_metroid.srm" "keep_remote" 2>/dev/null || rc=$?
assert_rc "rds1: keep_remote returns 0" 0 "$rc"

# Device save has remote bytes
device_path=$(pm_repo_to_local "snes/super_metroid.srm" 2>/dev/null)
assert_files_identical "rds1: device save has remote bytes" \
    "$repo_dir/snes/super_metroid.srm" "$device_path"

# Try marker removed
rc=0
ch_is_trying "$repo_dir" "snes/super_metroid.srm" || rc=$?
assert_rc "rds1: try marker removed" 1 "$rc"

# Test: keep_local → device save has local bytes
repo_dir=$(create_test_conflict "rds2" "snes/super_metroid.srm" "my-brick" "my-deck")
remote_dir="$TEST_TMPDIR/rds2_remote.git"
"$CONTINUITY_GIT_BIN" init --bare "$remote_dir" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" remote add origin "file://$remote_dir" >/dev/null 2>&1 || \
    "$CONTINUITY_GIT_BIN" -C "$repo_dir" remote set-url origin "file://$remote_dir" >/dev/null 2>&1
"$CONTINUITY_GIT_BIN" -C "$repo_dir" push -u origin main >/dev/null 2>&1
mkdir -p "$repo_dir/.continuity"
head_hash=$("$CONTINUITY_GIT_BIN" -C "$repo_dir" rev-parse HEAD)
cs_store_commit "$repo_dir" "$head_hash"

rc=0
ch_resolve "$repo_dir" "snes/super_metroid.srm" "keep_local" 2>/dev/null || rc=$?
assert_rc "rds2: keep_local returns 0" 0 "$rc"

# After keep_local, canonical has local bytes, and device save matches canonical
device_path=$(pm_repo_to_local "snes/super_metroid.srm" 2>/dev/null)
assert_files_identical "rds2: device save matches canonical" \
    "$repo_dir/snes/super_metroid.srm" "$device_path"

# ============================
# Tests for rp_confirm_changes trying-state skip
# ============================
printf '\n=== rp_confirm_changes trying-state skip tests ===\n' >&2

# Source runtime_poll
. "$PROJECT_ROOT/src/core/change_detector.sh"
. "$PROJECT_ROOT/src/core/runtime_poll.sh"

# Test: trying-state file excluded from confirmed changes
repo_dir=$(create_test_conflict "rpc1" "snes/super_metroid.srm" "my-brick" "my-deck")
# Get the device path for snes
device_path=$(pm_repo_to_local "snes/super_metroid.srm" 2>/dev/null)
mkdir -p "$(dirname "$device_path")"
printf 'different-content' > "$device_path"

# Set up trying state
ch_try_version "$repo_dir" "snes/super_metroid.srm" "local" >/dev/null 2>&1

# Confirm changes — trying-state file should be excluded
confirmed=$(rp_confirm_changes "$repo_dir" "$device_path" 2>/dev/null)
assert_eq "rpc1: trying-state file excluded" "" "$confirmed"

# Test: non-trying file still included
repo_dir=$(create_test_conflict "rpc2" "snes/super_metroid.srm" "my-brick" "my-deck")
device_path=$(pm_repo_to_local "snes/super_metroid.srm" 2>/dev/null)
mkdir -p "$(dirname "$device_path")"
printf 'changed-content' > "$device_path"
# No try marker — file should be confirmed
confirmed=$(rp_confirm_changes "$repo_dir" "$device_path" 2>/dev/null)
assert_contains "rpc2: non-trying file included" "$confirmed" "$device_path"

# ============================
# Summary
# ============================
printf '\n=== Results: %s passed, %s failed ===\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
exit 0
