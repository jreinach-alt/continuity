#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/platforms/nextui/launch.sh (state-driven PAK entry)
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

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# PAK sandbox with the real launch.sh and the modules it sources
PAK="$TEST_TMPDIR/Continuity.pak"
mkdir -p "$PAK/scripts/core"
cp "$PROJECT_ROOT/src/platforms/nextui/launch.sh" "$PAK/launch.sh"
cp "$PROJECT_ROOT/src/platforms/nextui/pal_nextui.sh" "$PAK/scripts/"
cp "$PROJECT_ROOT/src/platforms/nextui/enroll_sd_card.sh" "$PAK/scripts/"
cp "$PROJECT_ROOT/src/platforms/nextui/enroll_ui.sh" "$PAK/scripts/"
cp "$PROJECT_ROOT/src/platforms/nextui/preflight.sh" "$PAK/scripts/"
cp "$PROJECT_ROOT/src/platforms/nextui/update.sh" "$PAK/scripts/"
cp "$PROJECT_ROOT/src/platforms/nextui/pal_ui_nextui.sh" "$PAK/scripts/"
cp "$PROJECT_ROOT/src/platforms/nextui/menu_ui.sh" "$PAK/scripts/"
cp "$PROJECT_ROOT"/src/core/*.sh "$PAK/scripts/core/"
mkdir -p "$PAK/config/platform_maps"
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$PAK/config/platform_maps/"
printf '0.1.0-test\n' > "$PAK/version.txt"
chmod +x "$PAK/launch.sh"

# Satisfy the preflight doctor's artifact checks in the sandbox: fake
# https helper + CA bundle. The system git does the real work (its own
# exec path is pre-set below so the PAL's PAK-relative defaults don't
# hijack it), and the TLS probe points at the local bare remote.
mkdir -p "$PAK/libexec/git-core" "$PAK/share/templates"
printf '#!/bin/sh\nexit 129\n' > "$PAK/libexec/git-core/git-remote-https"
chmod +x "$PAK/libexec/git-core/git-remote-https"
printf 'stub-ca\n' > "$PAK/share/ca-bundle.crt"
SYS_GIT_EXEC_PATH="$(git --exec-path)"

# show2.elf stub: records argv (one call per line); daemon mode just exits
STUB_BIN="$TEST_TMPDIR/bin"
mkdir -p "$STUB_BIN"
SHOW2_CALLS="$TEST_TMPDIR/show2_calls.txt"
export SHOW2_CALLS
cat > "$STUB_BIN/show2.elf" <<'EOF'
#!/bin/sh
printf '%s ' "$@" >> "${SHOW2_CALLS:?}"
printf '\n' >> "$SHOW2_CALLS"
exit 0
EOF
chmod +x "$STUB_BIN/show2.elf"

# Sandboxed environment shared by every run
SDROOT="$TEST_TMPDIR/sdcard"
USERDATA="$SDROOT/.userdata/tg5040"
CHOME="$SDROOT/.continuity"
REPO_DIR="$CHOME/repo"
PID_FILE="$TEST_TMPDIR/continuity.pid"
FIFO_CAP="$TEST_TMPDIR/fifo_capture.txt"
mkdir -p "$SDROOT"
: > "$FIFO_CAP"

run_launch() {
    CONTINUITY_SD_ROOT="$SDROOT" CONTINUITY_HOME="$CHOME" \
    CONTINUITY_REPO_DIR="$REPO_DIR" CONTINUITY_GIT_BIN="git" \
    CONTINUITY_PID_FILE="$PID_FILE" CONTINUITY_SHOW2_FIFO="$FIFO_CAP" \
    CONTINUITY_FORCE_ONLINE=1 GIT_EXEC_PATH="$SYS_GIT_EXEC_PATH" \
    PF_LSREMOTE_URL="file://$REMOTE" \
    CONTINUITY_OTA="${TEST_OTA:-0}" CONTINUITY_OTA_URL="${TEST_OTA_URL:-}" \
    USERDATA_PATH="$USERDATA" PATH="$STUB_BIN:$PATH" \
    EUI_FIFO="$FIFO_CAP" EUI_JS_DEV="$TEST_TMPDIR/js0" \
    EUI_TICK="0.1" EUI_TIMEOUT_TICKS=100 \
    PUI_TIMEOUT_TICKS=40 PUI_HANDOFF_TICKS=5 \
        busybox ash "$PAK/launch.sh"
}
: > "$TEST_TMPDIR/js0"

# --- Test 1: not enrolled, no setup.json — hook installed, guidance shown ---

mkdir -p "$USERDATA"
printf '#!/bin/sh\necho preexisting\n' > "$USERDATA/auto.sh"

rc=0; run_launch || rc=$?
assert_eq "run exits 0 (no setup.json)" "0" "$rc"

AUTO_SH="$USERDATA/auto.sh"
assert_contains "auto.sh keeps pre-existing content" "$AUTO_SH" "echo preexisting"
assert_contains "auto.sh has daemon hook" "$AUTO_SH" "scripts/continuity_daemon.sh"
assert_contains "daemon hook detaches stdio" "$AUTO_SH" "</dev/null >/dev/null 2>&1 &"
assert_file_exists "hook marker created" "$CHOME/.hook_installed"
assert_file_exists "breadcrumb log created" "$PAK/launch.log"
assert_contains "breadcrumb carries build stamp" "$PAK/launch.log" "(build 0.1.0-test)"
assert_contains "not-enrolled guidance shown with build stamp" "$SHOW2_CALLS" \
    "Not enrolled (build 0.1.0-test). Put setup.json on SD root"

# --- Test 2: hook install is idempotent across runs ---

rc=0; run_launch || rc=$?
hook_count=$(grep -cF "continuity_daemon.sh" "$AUTO_SH")
assert_eq "hook not duplicated" "1" "$hook_count"
assert_eq "breadcrumb has two lines" "2" "$(wc -l < "$PAK/launch.log")"

# --- Test 3: setup.json present — real enrollment via the supervisor,
#             stale partial clone cleared first ---

# Bare remote seeded with one save
REMOTE="$TEST_TMPDIR/remote.git"
git init --bare -q "$REMOTE"
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
SEED="$TEST_TMPDIR/seed"
git clone -q "$REMOTE" "$SEED" 2>/dev/null
git -C "$SEED" checkout -q -b main 2>/dev/null || true
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
mkdir -p "$SEED/gb"
printf 'seed' > "$SEED/gb/links_awakening.srm"
git -C "$SEED" add -A && git -C "$SEED" commit -qm seed && git -C "$SEED" push -q origin main

# Stale partial clone from a simulated mid-clone power loss
mkdir -p "$REPO_DIR/.git"
printf 'junk' > "$REPO_DIR/partial_junk"

printf '{\n  "repo_url": "file://%s",\n  "pat": "test-pat",\n  "device_name": "test-brick"\n}\n' \
    "$REMOTE" > "$SDROOT/setup.json"

: > "$FIFO_CAP"
rc=0; run_launch || rc=$?
assert_eq "enrollment run exits 0" "0" "$rc"
assert_file_exists "device enrolled (device_name written)" "$REPO_DIR/.continuity/device_name"
assert_eq "device name recorded" "test-brick" "$(cat "$REPO_DIR/.continuity/device_name")"
assert_file_not_exists "stale partial clone was cleared" "$REPO_DIR/partial_junk"
assert_file_not_exists "setup.json consumed after success" "$SDROOT/setup.json"
assert_file_exists "enrollment log written" "$CHOME/enroll.log"
assert_contains "success message shown" "$FIFO_CAP" "Enrolled! Reboot to start syncing."
assert_file_exists "diagnostic report at SD root" "$SDROOT/CONTINUITY_DIAGNOSTIC.txt"
assert_contains "preflight passed before enrollment" "$SDROOT/CONTINUITY_DIAGNOSTIC.txt" \
    "=== preflight PASSED ==="
assert_contains "preflight report copied into enroll.log" "$CHOME/enroll.log" \
    "=== preflight PASSED ==="

# --- Test 4: enrolled + daemon alive — status shows last sync ---

printf '%s\n' "$$" > "$PID_FILE"     # this test process is "the daemon"
printf '[2026-07-06 10:00:00] info: Sync complete — 2 saves pushed\n' \
    > "$CHOME/continuity.log"
: > "$SHOW2_CALLS"
rc=0; run_launch || rc=$?
assert_eq "status run exits 0" "0" "$rc"
assert_contains "last sync shown" "$SHOW2_CALLS" "Sync complete"

# --- Test 5: enrolled + daemon alive, no syncs yet ---

: > "$CHOME/continuity.log"
: > "$SHOW2_CALLS"
rc=0; run_launch || rc=$?
assert_contains "running-no-syncs message" "$SHOW2_CALLS" "Daemon running — no syncs yet."

# --- Test 6: enrolled + daemon dead — honest status + last error ---

sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
printf '%s\n' "$dead_pid" > "$PID_FILE"
printf '[2026-07-06 10:05:00] error: Push failed: network unreachable\n' \
    > "$CHOME/continuity.log"
: > "$SHOW2_CALLS"
rc=0; run_launch || rc=$?
assert_contains "daemon-not-running shown with build stamp" "$SHOW2_CALLS" \
    "Daemon NOT running (build 0.1.0-test). Reboot to start it."
assert_contains "last error surfaced" "$SHOW2_CALLS" "Push failed: network unreachable"

# --- Test 6b: OTA end-to-end — update offered on X press, applied ---

UPSTREAM="$TEST_TMPDIR/ota-upstream"
mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email t@t; git -C "$UPSTREAM" config user.name t
TREE="$UPSTREAM/build/Continuity.pak"
mkdir -p "$TREE/scripts/core"
printf '#!/bin/sh\n# ota-marker\ntrue\n' > "$TREE/launch.sh"
printf '#!/bin/sh\ntrue\n' > "$TREE/scripts/update.sh"
printf '#!/bin/sh\ntrue\n' > "$TREE/scripts/core/pal.sh"
printf '9.9.9-ota\n' > "$TREE/version.txt"
printf 'main\n' > "$TREE/ota_channel.txt"
git -C "$UPSTREAM" add -A && git -C "$UPSTREAM" commit -qm ota
printf 'main\n' > "$PAK/ota_channel.txt"

# Daemon "alive", X press queued for the update prompt
printf '%s\n' "$$" > "$PID_FILE"
: > "$CHOME/continuity.log"
: > "$TEST_TMPDIR/js0"
printf "$(printf '\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o' 0 0 0 0 1 0 1 3)" \
    >> "$TEST_TMPDIR/js0"     # js_event: X press (value=1 type=1 number=3)
: > "$FIFO_CAP"
rc=0; TEST_OTA=1 TEST_OTA_URL="file://$UPSTREAM" run_launch || rc=$?
assert_eq "OTA launch exits 0" "0" "$rc"
assert_contains "update offered" "$FIFO_CAP" "Update available: 9.9.9-ota"
assert_contains "update applied confirmation" "$FIFO_CAP" "Updated to 9.9.9-ota"
assert_contains "PAK launch.sh replaced by OTA" "$PAK/launch.sh" "ota-marker"
assert_eq "PAK version now OTA version" "9.9.9-ota" "$(cat "$PAK/version.txt")"

# Restore the real launch.sh and modules the OTA fixture overwrote
cp "$PROJECT_ROOT/src/platforms/nextui/launch.sh" "$PAK/launch.sh"
cp "$PROJECT_ROOT/src/platforms/nextui/update.sh" "$PAK/scripts/update.sh"
cp "$PROJECT_ROOT/src/core/pal.sh" "$PAK/scripts/core/pal.sh"
printf '0.1.0-test\n' > "$PAK/version.txt"
chmod +x "$PAK/launch.sh"

# --- Test 6c: enrolled + a conflict present — the menu opens and its
#              "Conflicts (N)" row reflects the live count (primary entry) ---

mkdir -p "$REPO_DIR/gb"
printf 'remote' > "$REPO_DIR/gb/Zelda.sav"
printf 'local'  > "$REPO_DIR/gb/Zelda.sav.test-brick.local"
printf '{\n  "_schema_version": "2.0",\n  "file": "gb/Zelda.sav",\n  "identity": "gb/Zelda",\n  "class": "srm",\n  "remote_device": "deck",\n  "remote_timestamp": "2026-03-12T13:00:00Z",\n  "local_device": "test-brick",\n  "local_timestamp": "2026-03-12T14:00:00Z",\n  "source": "pull",\n  "status": "unresolved"\n}\n' \
    > "$REPO_DIR/gb/Zelda.sav.conflict"

printf '%s\n' "$$" > "$PID_FILE"      # daemon "alive"
: > "$CHOME/continuity.log"
: > "$TEST_TMPDIR/js0"
printf "$(printf '\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o\\%03o' 0 0 0 0 1 0 1 0)" \
    >> "$TEST_TMPDIR/js0"     # js_event: B press (number=0) → cancel the menu
: > "$FIFO_CAP"
rc=0; run_launch || rc=$?
assert_eq "conflict-menu launch exits 0" "0" "$rc"
assert_contains "menu opened with live conflict count" "$FIFO_CAP" "Conflicts (1)"

# Remove the conflict so later tests see a clean, zero-conflict repo again.
rm -f "$REPO_DIR/gb/Zelda.sav" "$REPO_DIR/gb/Zelda.sav.test-brick.local" \
      "$REPO_DIR/gb/Zelda.sav.conflict"

# --- Test 7: CRLF-corrupted module is named on screen, not a silent death ---

sed 's/$/\r/' "$PROJECT_ROOT/src/core/pal.sh" > "$PAK/scripts/core/pal.sh"
: > "$SHOW2_CALLS"
rc=0; run_launch || rc=$?
assert_eq "corrupted module exits 1" "1" "$rc"
assert_contains "corruption named on screen" "$SHOW2_CALLS" \
    "Corrupt line endings in scripts/core/pal.sh — re-copy the PAK"
cp "$PROJECT_ROOT/src/core/pal.sh" "$PAK/scripts/core/pal.sh"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
