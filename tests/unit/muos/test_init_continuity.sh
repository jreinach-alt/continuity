#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/platforms/muos/init_continuity.sh — the boot hook:
# breadcrumb-always, silent no-op without an install, daemon start
# detached, duplicate-instance guard, and it must return promptly
# (boot never blocks on it).
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
HOOK="$PROJECT_ROOT/src/platforms/muos/init_continuity.sh"

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

assert_file_exists() {
    local desc="$1" filepath="$2"
    if [ -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

SD="$TEST_TMPDIR/sd"
APP="$SD/.continuity/app"
mkdir -p "$SD/MUOS/init" "$APP/scripts"
cp "$HOOK" "$SD/MUOS/init/continuity.sh"
chmod +x "$SD/MUOS/init/continuity.sh"
printf '0.1.0-test\n' > "$APP/version.txt"

run_hook() {
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" \
        CONTINUITY_PID_FILE="$TEST_TMPDIR/continuity.pid" "$@" \
        busybox ash "$SD/MUOS/init/continuity.sh"
}

# ── 1: no daemon installed → silent success + breadcrumb ────────────

rc=0
run_hook >/dev/null 2>&1 || rc=$?
assert_eq "missing install exits 0 (boot never blocks)" "0" "$rc"
assert_file_exists "breadcrumb written" "$SD/.continuity/launch.log"
assert_eq "breadcrumb names the hook" "1" \
    "$(grep -c 'boot init hook' "$SD/.continuity/launch.log")"

# ── 2: installed → daemon started, hook returns promptly ────────────

cat > "$APP/scripts/continuity_daemon.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$\$" > "\${CONTINUITY_PID_FILE:-$TEST_TMPDIR/continuity.pid}"
printf started > "$TEST_TMPDIR/daemon_started"
sleep 10
EOF
chmod +x "$APP/scripts/continuity_daemon.sh"

start=$(date +%s)
rc=0
run_hook >/dev/null 2>&1 || rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "hook exits 0" "0" "$rc"
if [ "$elapsed" -le 3 ]; then passed=$((passed + 1)); else
    printf 'FAIL: hook blocked boot for %ss\n' "$elapsed" >&2; failed=$((failed + 1)); fi
sleep 1
assert_file_exists "daemon started by hook" "$TEST_TMPDIR/daemon_started"
assert_file_exists "daemon wrote pid" "$TEST_TMPDIR/continuity.pid"

# ── 3: daemon already running → no duplicate start ──────────────────

rm -f "$TEST_TMPDIR/daemon_started"
rc=0
run_hook >/dev/null 2>&1 || rc=$?
assert_eq "hook exits 0 when already running" "0" "$rc"
sleep 1
assert_eq "no duplicate start" "no" \
    "$([ -f "$TEST_TMPDIR/daemon_started" ] && printf yes || printf no)"

# stale pid (dead process) → starts again
printf '99999999\n' > "$TEST_TMPDIR/continuity.pid"
rm -f "$TEST_TMPDIR/daemon_started"
rc=0
run_hook >/dev/null 2>&1 || rc=$?
assert_eq "stale pid tolerated" "0" "$rc"
sleep 1
assert_file_exists "daemon restarted past stale pid" "$TEST_TMPDIR/daemon_started"

printf '\ntest_init_continuity: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
