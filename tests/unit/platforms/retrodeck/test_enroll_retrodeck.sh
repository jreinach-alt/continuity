#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests — RetroDeck CLI enrollment (enroll_retrodeck.sh).
# Runs the real script end-to-end against a file:// remote with a
# recording systemctl stub; asserts credential hygiene, device
# registration, unit templating, and argument validation.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
ENROLL="$PROJECT_ROOT/src/platforms/retrodeck/enroll_retrodeck.sh"

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

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  expected rc: %s  actual rc: %s\n' "$desc" "$expected" "$actual" >&2
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

assert_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text lacks: %s\n  text: %s\n' "$desc" "$pattern" "$text" >&2; failed=$((failed + 1)) ;;
    esac
}

assert_not_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) printf 'FAIL: %s\n  text unexpectedly contains: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
        *) passed=$((passed + 1)) ;;
    esac
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# file:// pushes need no network — force "online" so enrollment's push
# behavior is deterministic in sandboxed/offline gate environments.
CONTINUITY_FORCE_ONLINE=1
export CONTINUITY_FORCE_ONLINE

# --- Shared sandbox pieces -------------------------------------------

# Recording systemctl stub
STUB_DIR="$TEST_TMPDIR/stub"
SYSCTL_LOG="$TEST_TMPDIR/systemctl.log"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/systemctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SYSCTL_LOG"
exit 0
EOF
chmod +x "$STUB_DIR/systemctl"

# RetroDeck-shaped config + rdhome
RD="$TEST_TMPDIR/rd"
mkdir -p "$RD/rdhome/saves/gba" "$RD/rdhome/roms/gba" "$RD/conf"
cat > "$RD/conf/retrodeck.json" <<EOF
{
 "paths": {
  "saves_path": "$RD/rdhome/saves",
  "states_path": "$RD/rdhome/states",
  "roms_path": "$RD/rdhome/roms"
 }
}
EOF

# Bare remote with main branch
REMOTE="$TEST_TMPDIR/remote.git"
git init --bare "$REMOTE" >/dev/null 2>&1
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
SEED="$TEST_TMPDIR/seed"
git clone "$REMOTE" "$SEED" >/dev/null 2>&1
git -C "$SEED" checkout -b main >/dev/null 2>&1 || true
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
printf 'seed' > "$SEED/README"
git -C "$SEED" add README >/dev/null 2>&1
git -C "$SEED" commit -m seed >/dev/null 2>&1
git -C "$SEED" push origin main >/dev/null 2>&1

PAT_FILE="$TEST_TMPDIR/pat"
printf 'test-pat-secret' > "$PAT_FILE"

# run_enroll <home> [extra args...] — run the script in a sandboxed HOME
run_enroll() {
    local home="$1"; shift
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_DATA_HOME="$home/.local/share" \
    CONTINUITY_RD_CONF="$RD/conf/retrodeck.json" \
    CONTINUITY_SYSTEMCTL="$STUB_DIR/systemctl" \
    PATH="$STUB_DIR:$PATH" \
        sh "$ENROLL" "$@"
}

# --- 1. Happy path: full enrollment + service install ---
H1="$TEST_TMPDIR/home1"
mkdir -p "$H1"
rc=0
out=$(run_enroll "$H1" --repo-url "file://$REMOTE" --device-name deck-one --pat-file "$PAT_FILE" 2>&1) || rc=$?
assert_rc "enrollment succeeds" 0 "$rc"

repo="$H1/.local/share/continuity/repo"
assert_file_exists "repo cloned" "$repo/.git"
assert_file_exists "device json committed" "$repo/.continuity/devices/deck-one.json"
assert_eq "device_name written" "deck-one" "$(cat "$repo/.continuity/device_name" 2>/dev/null)"
assert_file_exists "credentials stored" "$repo/.continuity/credentials"
perms=$(ls -l "$repo/.continuity/credentials" | cut -c1-10)
assert_eq "credentials 0600" "-rw-------" "$perms"

# registration reached the remote
remote_files=$(git -C "$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null)
assert_contains "device registration pushed" "$remote_files" ".continuity/devices/deck-one.json"

# unit installed with the real checkout path substituted
unit="$H1/.config/systemd/user/continuity.service"
assert_file_exists "unit installed" "$unit"
unit_text=$(cat "$unit" 2>/dev/null)
assert_contains "unit ExecStart templated" "$unit_text" "$PROJECT_ROOT/src/platforms/retrodeck/continuity_daemon.sh"
assert_not_contains "no placeholder left" "$unit_text" "@APP_DIR@"

# systemctl called correctly
sysctl_calls=$(cat "$SYSCTL_LOG" 2>/dev/null)
assert_contains "daemon-reload called" "$sysctl_calls" "--user daemon-reload"
assert_contains "enable --now called" "$sysctl_calls" "--user enable --now continuity.service"

# resolver launcher installed with the real checkout path substituted
launcher="$H1/.local/share/applications/continuity-resolve.desktop"
assert_file_exists "launcher installed" "$launcher"
launcher_text=$(cat "$launcher" 2>/dev/null)
assert_contains "launcher Exec templated" "$launcher_text" "$PROJECT_ROOT/src/platforms/retrodeck/resolve_conflicts.sh"
assert_not_contains "launcher: no placeholder left" "$launcher_text" "@APP_DIR@"

# PAT hygiene: never in output, never left in the repo tree's git config
assert_not_contains "PAT not in output" "$out" "test-pat-secret"
assert_not_contains "PAT not in remote tree" "$remote_files" "credentials"

# --- 2. Re-run: already enrolled is a clean no-op ---
rc=0
out=$(run_enroll "$H1" --repo-url "file://$REMOTE" --device-name deck-one --pat-file "$PAT_FILE" 2>&1) || rc=$?
assert_rc "already enrolled: rc 0" 0 "$rc"
assert_contains "already enrolled: says so" "$out" "Already enrolled"

# --- 3. --no-service skips unit + systemctl ---
H2="$TEST_TMPDIR/home2"
mkdir -p "$H2"
: > "$SYSCTL_LOG"
rc=0
run_enroll "$H2" --repo-url "file://$REMOTE" --device-name deck-two --pat-file "$PAT_FILE" --no-service >/dev/null 2>&1 || rc=$?
assert_rc "--no-service enrollment succeeds" 0 "$rc"
if [ ! -e "$H2/.config/systemd/user/continuity.service" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: --no-service still installed unit\n' >&2; failed=$((failed + 1))
fi
assert_eq "--no-service: systemctl never called" "" "$(cat "$SYSCTL_LOG" 2>/dev/null)"
# The launcher is UI, not the daemon — installed even with --no-service.
assert_file_exists "--no-service: launcher still installed" \
    "$H2/.local/share/applications/continuity-resolve.desktop"

# --- 4. Validation failures ---
H3="$TEST_TMPDIR/home3"
mkdir -p "$H3"

rc=0
out=$(run_enroll "$H3" --device-name x --pat-file "$PAT_FILE" 2>&1) || rc=$?
assert_rc "missing --repo-url rejected" 1 "$rc"
assert_contains "missing --repo-url named" "$out" "repo-url is required"

rc=0
out=$(run_enroll "$H3" --repo-url "file://$REMOTE" --device-name "Bad Name!" --pat-file "$PAT_FILE" 2>&1) || rc=$?
assert_rc "invalid device name rejected" 1 "$rc"

rc=0
out=$(run_enroll "$H3" --repo-url "file://$REMOTE" --pat secret123 2>&1) || rc=$?
assert_rc "--pat on argv rejected" 1 "$rc"
assert_contains "--pat rejection names ps leak" "$out" "leaks via ps"

rc=0
out=$(run_enroll "$H3" --repo-url "file://$REMOTE" --pat-file "$TEST_TMPDIR/nope" 2>&1) || rc=$?
assert_rc "missing pat file rejected" 1 "$rc"

# empty PAT via stdin prompt path (no tty -> plain read)
rc=0
out=$(printf '\n' | run_enroll "$H3" --repo-url "file://$REMOTE" --device-name deck-three 2>&1) || rc=$?
assert_rc "empty PAT rejected" 1 "$rc"
assert_contains "empty PAT named" "$out" "Empty PAT"

# missing RetroDeck config preflight
rc=0
out=$(HOME="$H3" XDG_DATA_HOME="$H3/.local/share" \
      CONTINUITY_RD_CONF="$TEST_TMPDIR/absent.json" \
      CONTINUITY_SYSTEMCTL="$STUB_DIR/systemctl" \
      sh "$ENROLL" --repo-url "file://$REMOTE" --pat-file "$PAT_FILE" 2>&1) || rc=$?
assert_rc "missing RetroDeck config rejected" 1 "$rc"
assert_contains "missing RetroDeck config named" "$out" "RetroDeck config not found"

printf '\ntest_enroll_retrodeck: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
