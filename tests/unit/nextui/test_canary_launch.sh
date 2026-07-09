#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/platforms/nextui/canary_launch.sh
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CANARY_SRC="$PROJECT_ROOT/src/platforms/nextui/canary_launch.sh"

passed=0
failed=0

assert_eq() {
    local desc expected actual
    desc="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual" >&2
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
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s does not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# make_sdroot <name> — build a fake SD card layout with the canary installed
# as Tools/tg5040/Continuity.pak/launch.sh. Prints the root path.
make_sdroot() {
    local root
    root="$TEST_TMPDIR/$1"
    mkdir -p "$root/Tools/tg5040/Continuity.pak" "$root/.system/res"
    printf 'fake-png\n' > "$root/.system/res/logo.png"
    cp "$CANARY_SRC" "$root/Tools/tg5040/Continuity.pak/launch.sh"
    chmod +x "$root/Tools/tg5040/Continuity.pak/launch.sh"
    printf '%s' "$root"
}

# make_show2_stub <dir> — create a fake show2.elf that records its argv.
make_show2_stub() {
    local dir
    dir="$1"
    mkdir -p "$dir"
    cat > "$dir/show2.elf" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "${SHOW2_ARGS_FILE:?}"
exit 0
EOF
    chmod +x "$dir/show2.elf"
}

# --- Test 1: source hygiene — no CRLF, parses under busybox ash ---

cr=$(printf '\r')
if grep -q "$cr" "$CANARY_SRC"; then
    assert_eq "canary source has no CRLF" "clean" "has-crlf"
else
    assert_eq "canary source has no CRLF" "clean" "clean"
fi

if busybox ash -n "$CANARY_SRC" 2>/dev/null; then
    assert_eq "canary parses under busybox ash" "ok" "ok"
else
    assert_eq "canary parses under busybox ash" "ok" "parse-error"
fi

# --- Test 2: happy path, invoked via the exact MinUI dispatch (eval) ---

ROOT=$(make_sdroot happy)
STUB_BIN="$TEST_TMPDIR/happy_bin"
make_show2_stub "$STUB_BIN"
SHOW2_ARGS_FILE="$TEST_TMPDIR/happy_show2_args.txt"
export SHOW2_ARGS_FILE

# Reproduce MinUI.pak's dispatch: nextui.elf writes the single-quoted path
# to a file; the loop does CMD=$(cat file); eval $CMD.
printf "'%s/Tools/tg5040/Continuity.pak/launch.sh'" "$ROOT" > "$TEST_TMPDIR/next"

rc=0
CONTINUITY_CANARY_ROOT="$ROOT" PATH="$STUB_BIN:$PATH" PLATFORM="tg5040" DEVICE="brick" \
    busybox ash -c 'CMD=$(cat "$1"); eval $CMD' _ "$TEST_TMPDIR/next" || rc=$?

assert_eq "canary exits 0 via eval dispatch" "0" "$rc"

PROOF="$ROOT/CONTINUITY_CANARY.txt"
assert_file_exists "proof file created at SD root" "$PROOF"
assert_contains "proof records execution" "$PROOF" "canary ran"
assert_contains "proof records cd success" "$PROOF" "cd_to_pak_dir: ok"
assert_contains "proof records pak-dir write ok" "$PROOF" "pakdir_write: ok"
assert_contains "proof records platform" "$PROOF" "platform: tg5040"
assert_contains "proof records device" "$PROOF" "device: brick"
assert_contains "proof records show2 path" "$PROOF" "show2_path: $STUB_BIN/show2.elf"
assert_contains "proof records show2 exit code" "$PROOF" "show2_exit_code: 0"
assert_file_exists "pak-dir breadcrumb created" \
    "$ROOT/Tools/tg5040/Continuity.pak/canary_pakdir_write.txt"

assert_contains "show2 called in simple mode" "$SHOW2_ARGS_FILE" "--mode=simple"
assert_contains "show2 given the logo image (key=value form)" "$SHOW2_ARGS_FILE" \
    "--image=$ROOT/.system/res/logo.png"
assert_contains "show2 given a timeout" "$SHOW2_ARGS_FILE" "--timeout=5"
assert_contains "show2 given visible text" "$SHOW2_ARGS_FILE" "--text=Continuity canary OK"

# --- Test 3: show2.elf absent — canary still leaves full evidence ---

ROOT2=$(make_sdroot noshow2)
EMPTY_BIN="$TEST_TMPDIR/empty_bin"
mkdir -p "$EMPTY_BIN"

rc=0
CONTINUITY_CANARY_ROOT="$ROOT2" PATH="$EMPTY_BIN:/usr/bin:/bin" \
    busybox ash "$ROOT2/Tools/tg5040/Continuity.pak/launch.sh" || rc=$?

PROOF2="$ROOT2/CONTINUITY_CANARY.txt"
assert_eq "canary exits 0 without show2" "0" "$rc"
assert_file_exists "proof file still created" "$PROOF2"
assert_contains "proof records show2 missing" "$PROOF2" "show2_path: NOT-ON-PATH"
assert_contains "proof records show2 failure code" "$PROOF2" "show2_exit_code: 127"

# --- Test 4: unset env vars are recorded, not fatal ---

assert_contains "unset platform recorded" "$PROOF2" "platform: unset"
assert_contains "unset device recorded" "$PROOF2" "device: unset"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
