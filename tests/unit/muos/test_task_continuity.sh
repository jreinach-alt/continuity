#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/platforms/muos/task_continuity.sh — the Task
# Toolkit entry: breadcrumb-always, preflight, state-driven dispatch
# (unenrolled guidance / enrollment / daemon start / status), and a
# full real enrollment through the task against a bare git remote.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

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

assert_contains() {
    local desc="$1" filepath="$2" needle="$3"
    if grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s does not contain: %s\n' "$desc" "$filepath" "$needle" >&2
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

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# App sandbox with the real modules (mirrors the shipped layout)
SD="$TEST_TMPDIR/sd"
APP="$SD/.continuity/app"
mkdir -p "$APP/scripts/core" "$APP/config/platform_maps" "$APP/bin" \
         "$APP/libexec/git-core" "$APP/share" \
         "$SD/MUOS/save/file/Snes9x" "$SD/MUOS/save/state" "$SD/ROMS" \
         "$SD/MUOS/task"
cp "$PROJECT_ROOT/src/platforms/muos/task_continuity.sh" "$SD/MUOS/task/Continuity.sh"
cp "$PROJECT_ROOT/src/platforms/muos/pal_muos.sh" "$APP/scripts/"
cp "$PROJECT_ROOT/src/platforms/muos/enroll_sd_card.sh" "$APP/scripts/"
cp "$PROJECT_ROOT/src/platforms/muos/preflight.sh" "$APP/scripts/"
cp "$PROJECT_ROOT/src/platforms/muos/continuity_daemon.sh" "$APP/scripts/"
cp "$PROJECT_ROOT"/src/core/*.sh "$APP/scripts/core/"
cp "$PROJECT_ROOT/config/platform_maps/muos.json" "$APP/config/platform_maps/"
printf '0.1.0-test\n' > "$APP/version.txt"
printf '#!/bin/sh\nexit 129\n' > "$APP/libexec/git-core/git-remote-https"
chmod +x "$APP/libexec/git-core/git-remote-https"
printf 'ca\n' > "$APP/share/ca-bundle.crt"
chmod +x "$SD/MUOS/task/Continuity.sh"

# Bare remote with one commit (local network-free "GitHub")
REMOTE="$TEST_TMPDIR/remote.git"
git init -q --bare "$REMOTE"
git --git-dir="$REMOTE" symbolic-ref HEAD refs/heads/main
SEED="$TEST_TMPDIR/seed"
git init -q -b main "$SEED"
( cd "$SEED" && git config user.email t@t && git config user.name t &&
  printf 'seed\n' > README && git add README &&
  git commit -qm seed && git push -q "$REMOTE" HEAD:main )

SYSGIT=$(command -v git)

# run_task <extra env...> — run the task entry as muOS would
run_task() {
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" TMPDIR="$TEST_TMPDIR" \
        CONTINUITY_SD_ROOT="$SD" \
        CONTINUITY_MUOS_RUNROOT="$TEST_TMPDIR/absent" \
        CONTINUITY_MUOS_UNION="$TEST_TMPDIR/absent" \
        CONTINUITY_PID_FILE="$TEST_TMPDIR/continuity.pid" \
        CONTINUITY_GIT_BIN="$SYSGIT" \
        CONTINUITY_FORCE_ONLINE=1 \
        PF_LSREMOTE_URL="$REMOTE" \
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
        "$@" busybox ash "$SD/MUOS/task/Continuity.sh"
}

# ── 1: missing app dir → named error + breadcrumb, rc 1 ─────────────

rc=0
out=$(env -i PATH="$PATH" HOME="$TEST_TMPDIR" \
      CONTINUITY_SD_ROOT="$TEST_TMPDIR/bare_sd" \
      busybox ash "$SD/MUOS/task/Continuity.sh" 2>&1) || rc=$?
mkdir -p "$TEST_TMPDIR/bare_sd"  # (created by breadcrumb mkdir already)
assert_eq "missing app dir exits 1" "1" "$rc"
printf '%s\n' "$out" > "$TEST_TMPDIR/out1.txt"
assert_contains "missing app dir named on console" "$TEST_TMPDIR/out1.txt" "not installed"
assert_file_exists "breadcrumb written even on failure" "$TEST_TMPDIR/bare_sd/.continuity/launch.log"

# ── 2: not enrolled, no setup.json → guidance, rc 0 ─────────────────

rc=0
out=$(run_task 2>&1) || rc=$?
printf '%s\n' "$out" > "$TEST_TMPDIR/out2.txt"
assert_eq "unenrolled guidance exits 0" "0" "$rc"
assert_contains "guidance names setup.json" "$TEST_TMPDIR/out2.txt" "Stage setup.json"
assert_file_exists "preflight report at SD root" "$SD/CONTINUITY_DIAGNOSTIC.txt"
assert_contains "preflight records version signals" "$SD/CONTINUITY_DIAGNOSTIC.txt" "muos-version"
assert_contains "launch breadcrumb accumulates" "$SD/.continuity/launch.log" "task launch, app="

# ── 3: full enrollment through the task (real git, bare remote) ─────

printf '{\n  "repo_url": "%s",\n  "pat": "unused-for-file-remote",\n  "device_name": "test-rg40xx"\n}\n' \
    "$REMOTE" > "$SD/setup.json"
# stub the daemon so "start" is observable without a real poll loop —
# it behaves like a healthy daemon: writes its PID file, then lingers
# long enough for tc_start_daemon's liveness verification to see it.
mv "$APP/scripts/continuity_daemon.sh" "$APP/scripts/continuity_daemon.real"
cat > "$APP/scripts/continuity_daemon.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$\$" > "\${CONTINUITY_PID_FILE:-$TEST_TMPDIR/continuity.pid}"
printf started > "$TEST_TMPDIR/daemon_started"
sleep 10
EOF
chmod +x "$APP/scripts/continuity_daemon.sh"

rc=0
out=$(run_task 2>&1) || rc=$?
printf '%s\n' "$out" > "$TEST_TMPDIR/out3.txt"
assert_eq "enrollment run exits 0" "0" "$rc"
assert_contains "enrollment completion named" "$TEST_TMPDIR/out3.txt" "Enrollment complete: test-rg40xx"
assert_contains "daemon liveness verified after start" "$TEST_TMPDIR/out3.txt" "Daemon confirmed alive"
assert_eq "setup.json deleted after enrollment" "no" "$([ -f "$SD/setup.json" ] && printf yes || printf no)"
assert_file_exists "device name persisted" "$SD/.continuity/repo/.continuity/device_name"
assert_eq "device name content" "test-rg40xx" "$(cat "$SD/.continuity/repo/.continuity/device_name")"
# registration pushed to the remote
assert_eq "registration visible in remote" "1" \
    "$(git --git-dir="$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null | grep -c 'devices/test-rg40xx.json')"
sleep 1  # detached stub daemon
assert_file_exists "daemon started after enrollment" "$TEST_TMPDIR/daemon_started"

# ── 4: enrolled + not running → starts daemon; running → status only ─

rm -f "$TEST_TMPDIR/daemon_started" "$TEST_TMPDIR/continuity.pid"
rc=0
out=$(run_task 2>&1) || rc=$?
printf '%s\n' "$out" > "$TEST_TMPDIR/out4.txt"
assert_eq "enrolled rerun exits 0" "0" "$rc"
assert_contains "daemon start attempted" "$TEST_TMPDIR/out4.txt" "Starting Continuity daemon"

# a dead daemon must be reported loudly, not silently (the field
# failure: muOS killed the task's process group and nothing said so)
printf '#!/bin/sh\nexit 0\n' > "$APP/scripts/continuity_daemon.sh"
chmod +x "$APP/scripts/continuity_daemon.sh"
rm -f "$TEST_TMPDIR/continuity.pid"
rc=0
out=$(run_task TC_START_WAIT_TICKS=1 2>&1) || rc=$?
printf '%s\n' "$out" > "$TEST_TMPDIR/out4b.txt"
assert_contains "dead daemon reported loudly" "$TEST_TMPDIR/out4b.txt" "did NOT stay up"

# fake a live daemon PID (this test process)
printf '%s\n' "$$" > "$TEST_TMPDIR/continuity.pid"
rm -f "$TEST_TMPDIR/daemon_started"
rc=0
out=$(run_task 2>&1) || rc=$?
printf '%s\n' "$out" > "$TEST_TMPDIR/out5.txt"
assert_contains "running daemon reported" "$TEST_TMPDIR/out5.txt" "enrolled and running"
sleep 1
assert_eq "no duplicate daemon start" "no" \
    "$([ -f "$TEST_TMPDIR/daemon_started" ] && printf yes || printf no)"

printf '\ntest_task_continuity: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
