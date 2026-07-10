#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for tools/saves-repo/build_digest.sh — the daily digest
# script shipped (with saves-digest.yml) into the user's saves repo.
# Builds a synthetic saves repo with Continuity's real commit format
# (`device:` trailers) and asserts the digest's grouping, filtering,
# window handling, and only-fire-on-activity gate.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DIGEST="$PROJECT_ROOT/tools/saves-repo/build_digest.sh"

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

assert_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s does not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

assert_not_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if ! grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s should not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

# --- Setup: synthetic saves repo in Continuity's commit format ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

REPO="$TEST_TMPDIR/saves-repo"
git init -q -b main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" checkout -q -b main
}
git -C "$REPO" config user.email "test@digest"
git -C "$REPO" config user.name "Digest Test"

commit_as() {
    # commit_as <device> <subject> — commits whatever is staged, with
    # Continuity's trailer format
    git -C "$REPO" commit -q -m "$2

device: $1
timestamp: 2026-07-07T00:00:00Z"
}

# An OLD save commit outside every test window (backdated a year)
mkdir -p "$REPO/gb"
printf 'ancient' > "$REPO/gb/ancient.sav"
git -C "$REPO" add -A
GIT_AUTHOR_DATE='2025-07-07T00:00:00Z' GIT_COMMITTER_DATE='2025-07-07T00:00:00Z' \
    commit_as "brick-a" "gb/ancient.sav updated"

# Recent: saves from two devices, spaced name, both formats
mkdir -p "$REPO/snes"
printf 'v1' > "$REPO/snes/Super Metroid (USA).srm"
git -C "$REPO" add -A
commit_as "brick-a" "snes/Super Metroid (USA).srm updated"

printf 'v2' > "$REPO/gb/links_awakening.sav"
# .rtc is a save-class sibling (Sprint 2.0) — same commit, same device
printf 'clk' > "$REPO/gb/pokemon_crystal.rtc"
git -C "$REPO" add -A
commit_as "deck-b" "gb/links_awakening.sav updated"

# Recent: save-state backups across every state name-shape (Sprint 2.0
# expanded coverage — 4 of 5 were never archived before)
mkdir -p "$REPO/states/SFC-snes9x"
printf 's0' > "$REPO/states/SFC-snes9x/Super Metroid (USA).st0"
printf 'sb' > "$REPO/states/SFC-snes9x/Super Metroid (USA).state"
printf 'sn' > "$REPO/states/SFC-snes9x/Super Metroid (USA).state1"
printf 'si' > "$REPO/states/SFC-snes9x/Super Metroid (USA).state.0"
printf 'sa' > "$REPO/states/SFC-snes9x/Super Metroid (USA).state.auto"
printf 'sx' > "$REPO/states/SFC-snes9x/Super Metroid (USA).state10"
printf 'sp' > "$REPO/states/SFC-snes9x/Super Metroid (USA).state10.png"
git -C "$REPO" add -A
commit_as "brick-a" "state backup"

# Recent: conflict artifacts
printf 'local-bytes' > "$REPO/snes/Super Metroid (USA).srm.deck-b.local"
printf '{}' > "$REPO/snes/Super Metroid (USA).srm.conflict"
git -C "$REPO" add -A
commit_as "deck-b" "conflict: 1 save(s) preserved from deck-b"

# Recent: a NON-save commit (device registration) — must not count
mkdir -p "$REPO/.continuity/devices"
printf '{}' > "$REPO/.continuity/devices/new-device.json"
git -C "$REPO" add -A
commit_as "new-device" "enroll: register new-device"

# --- Test 1: digest over the active window ---
OUT="$TEST_TMPDIR/digest.md"
rc=0
( cd "$REPO" && sh "$DIGEST" "$OUT" ) || rc=$?
assert_eq "digest exits 0 with activity" "0" "$rc"

assert_contains "header present" "$OUT" "## Saves archived"
assert_contains "device A section" "$OUT" "### brick-a"
assert_contains "device B section" "$OUT" "### deck-b"
assert_contains "spaced .srm listed byte-exact" "$OUT" \
    '- `snes/Super Metroid (USA).srm`'
assert_contains ".sav listed" "$OUT" '- `gb/links_awakening.sav`'
assert_contains ".rtc classified as a save" "$OUT" '- `gb/pokemon_crystal.rtc`'
assert_contains "states section" "$OUT" "## Save states backed up"
assert_contains "state file listed" "$OUT" \
    '- `states/SFC-snes9x/Super Metroid (USA).st0`'
assert_contains "state .state shape listed" "$OUT" \
    '- `states/SFC-snes9x/Super Metroid (USA).state`'
assert_contains "state .state.auto shape listed" "$OUT" \
    '- `states/SFC-snes9x/Super Metroid (USA).state.auto`'
assert_contains "multi-digit slot classified (muOS field defect)" "$OUT" \
    '- `states/SFC-snes9x/Super Metroid (USA).state10`'
assert_contains "state thumbnail classified" "$OUT" \
    '- `states/SFC-snes9x/Super Metroid (USA).state10.png`'
assert_contains "conflict section flagged" "$OUT" "## ⚠ Conflicts recorded"
assert_contains ".local artifact listed" "$OUT" \
    '- `snes/Super Metroid (USA).srm.deck-b.local`'
assert_contains "commit count reflects save-bearing commits only" "$OUT" \
    "4 save-bearing commit(s)"

assert_not_contains "old commit outside window excluded" "$OUT" "ancient.sav"
assert_not_contains "registration commit not listed" "$OUT" "new-device.json"

# --- Test 2: window override excludes everything -> no digest ---
# (a window starting in the far future is guaranteed empty; "N seconds
# ago" would still include the commits this test created moments ago,
# and git's approxidate quietly mis-parses relative words like
# "tomorrow" — an explicit date is the only reliable form)
OUT2="$TEST_TMPDIR/digest2.md"
rc=0
( cd "$REPO" && DIGEST_SINCE='2099-01-01' sh "$DIGEST" "$OUT2" ) || rc=$?
assert_eq "no activity in window exits 1" "1" "$rc"
assert_eq "no output written without activity" "no" "$([ -s "$OUT2" ] && printf 'yes' || printf 'no')"

# --- Test 3: registration-only day -> no digest ---
REPO2="$TEST_TMPDIR/quiet-repo"
git init -q -b main "$REPO2" 2>/dev/null || {
    git init -q "$REPO2"
    git -C "$REPO2" checkout -q -b main
}
git -C "$REPO2" config user.email "test@digest"
git -C "$REPO2" config user.name "Digest Test"
mkdir -p "$REPO2/.continuity/devices"
printf '{}' > "$REPO2/.continuity/devices/only.json"
git -C "$REPO2" add -A
git -C "$REPO2" commit -q -m "enroll: register only

device: only
timestamp: 2026-07-07T00:00:00Z"
OUT3="$TEST_TMPDIR/digest3.md"
rc=0
( cd "$REPO2" && sh "$DIGEST" "$OUT3" ) || rc=$?
assert_eq "registration-only day exits 1 (no email)" "1" "$rc"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
