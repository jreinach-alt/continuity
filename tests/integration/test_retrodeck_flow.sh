#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC1090,SC1091
# Integration test — Sprint 2.1: all core sync phases through the REAL
# RetroDeck PAL (rd_conf-derived paths) with zero core changes.
#
#   Phase 0 — CLI enrollment (enroll_retrodeck.sh) against file:// remote
#   Phase 1 — cold start: RetroArch-native saves -> canonical repo
#   Phase 2 — runtime poll detects a changed save; quarantines RZIP
#   Phase 3 — clean shutdown -> normal boot pull materializes a remote
#             save (ROM present) and sparse-skips one (ROM absent)
#   Phase 4 — stale boot reconciles local+remote divergence
#   Phase 5 — two-device conflict preserved (.local + .conflict)
#   Phase 6 — the daemon as a real process: poll, SIGTERM, clean marker
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

assert_absent() {
    local desc="$1" filepath="$2"
    if [ ! -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file unexpectedly present: %s\n' "$desc" "$filepath" >&2
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

# --- Sandbox --------------------------------------------------------

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# RetroDeck-shaped world: rdhome (with a space, like "rd home" installs
# can have), live config json, RetroArch-sorted saves, ES-DE rom dirs.
RDHOME="$TEST_TMPDIR/rd home"
RD_CONF_DIR="$TEST_TMPDIR/rdconf"
mkdir -p "$RDHOME/saves/gba" "$RDHOME/saves/snes" "$RDHOME/states" \
         "$RDHOME/roms/gba" "$RDHOME/roms/snes" "$RD_CONF_DIR"
cat > "$RD_CONF_DIR/retrodeck.json" <<EOF
{
 "version": "0.10.9b",
 "paths": {
  "rd_home_path": "$RDHOME",
  "roms_path": "$RDHOME/roms",
  "saves_path": "$RDHOME/saves",
  "states_path": "$RDHOME/states"
 }
}
EOF

# Bare remote with a main branch
REMOTE="$TEST_TMPDIR/remote.git"
git init --bare "$REMOTE" >/dev/null 2>&1
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
SEED="$TEST_TMPDIR/seed"
git clone "$REMOTE" "$SEED" >/dev/null 2>&1
git -C "$SEED" checkout -b main >/dev/null 2>&1 || true
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
printf 'continuity saves repo\n' > "$SEED/README.md"
git -C "$SEED" add README.md >/dev/null 2>&1
git -C "$SEED" commit -m seed >/dev/null 2>&1
git -C "$SEED" push -q origin main

# remote_put <path> <content> — advance the remote from "elsewhere"
remote_put() {
    local work
    work=$(mktemp -d)
    git clone "$REMOTE" "$work/c" >/dev/null 2>&1
    git -C "$work/c" checkout main >/dev/null 2>&1 || true
    git -C "$work/c" config user.email r@t; git -C "$work/c" config user.name r
    mkdir -p "$work/c/$(dirname "$1")"
    printf '%s' "$2" > "$work/c/$1"
    git -C "$work/c" add -A >/dev/null 2>&1
    git -C "$work/c" commit -m "remote: $1" >/dev/null 2>&1
    git -C "$work/c" push -q origin main
    rm -rf "$work"
}

# Device-side environment: everything the PAL derives comes from the
# rd_conf json; repo dir + app dir are explicit.
SANDBOX_HOME="$TEST_TMPDIR/home"
mkdir -p "$SANDBOX_HOME"
CONTINUITY_RD_CONF="$RD_CONF_DIR/retrodeck.json"
CONTINUITY_REPO_DIR="$SANDBOX_HOME/.local/share/continuity/repo"
CONTINUITY_APP_DIR="$PROJECT_ROOT"
CONTINUITY_FORCE_ONLINE=1
export CONTINUITY_RD_CONF CONTINUITY_REPO_DIR CONTINUITY_APP_DIR CONTINUITY_FORCE_ONLINE

# Device content: RetroArch-native save names, matching ROMs
printf 'zelda-sram-v1' > "$RDHOME/saves/gba/Zelda Minish Cap (USA).srm"
: > "$RDHOME/roms/gba/Zelda Minish Cap (USA).gba"
: > "$RDHOME/roms/snes/Super Metroid (USA).sfc"   # ROM present, no save yet

# =====================================================================
# Phase 0 — CLI enrollment
# =====================================================================

PAT_FILE="$TEST_TMPDIR/pat"
printf 'file-remote-needs-no-pat-but-flow-does' > "$PAT_FILE"
rc=0
HOME="$SANDBOX_HOME" sh "$PROJECT_ROOT/src/platforms/retrodeck/enroll_retrodeck.sh" \
    --repo-url "file://$REMOTE" --device-name deck-flow \
    --pat-file "$PAT_FILE" --no-service >/dev/null 2>&1 || rc=$?
assert_rc "enrollment ok" 0 "$rc"
assert_eq "device name stored" "deck-flow" \
    "$(cat "$CONTINUITY_REPO_DIR/.continuity/device_name" 2>/dev/null)"

# =====================================================================
# Load the daemon's function surface through the real PAL
# =====================================================================

CONTINUITY_DAEMON_NO_MAIN=1
. "$PROJECT_ROOT/src/platforms/retrodeck/continuity_daemon.sh"
rdd_load_modules

rc=0; pal_init >/dev/null 2>&1 || rc=$?
assert_rc "pal_init ok (rd_conf-derived paths)" 0 "$rc"
assert_eq "saves root derived from rd_conf" "$RDHOME/saves" "$CONTINUITY_SAVES_ROOT"
rc=0; pal_validate >/dev/null 2>&1 || rc=$?
assert_rc "pal_validate ok" 0 "$rc"
se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" >/dev/null 2>&1
rc=0; pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null || rc=$?
assert_rc "retrodeck platform map loads" 0 "$rc"

# =====================================================================
# Phase 1 — cold start (boot dispatch routes it)
# =====================================================================

rc=0; rdd_boot_dispatch "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "cold start via boot dispatch" 0 "$rc"

remote_files=$(git -C "$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null)
assert_contains "canonical save reached remote" "$remote_files" "gba/Zelda Minish Cap (USA).srm"
assert_file_exists "sentinel created" "$CONTINUITY_REPO_DIR/.continuity/sentinel"

# =====================================================================
# Phase 2 — runtime poll: change detection + RZIP quarantine
# =====================================================================

sleep 1
printf 'zelda-sram-v2-longer' > "$RDHOME/saves/gba/Zelda Minish Cap (USA).srm"
# an RZIP-compressed save (real reference-encoder bytes) with its ROM
cp "$TESTS_DIR/fixtures/rzip/save_rzip.bin" "$RDHOME/saves/gba/Compressed Game.srm"
: > "$RDHOME/roms/gba/Compressed Game.gba"

poll_log="$TEST_TMPDIR/poll.log"
rc=0; rdd_poll_once >/dev/null 2>"$poll_log" || rc=$?
assert_rc "poll cycle ok" 0 "$rc"

# The mapper is a pure classifier (rc 3); the PHASE surfaces the named
# "compressed save skipped" line to the daemon log. (Previously the
# mapper's line was swallowed by the 2>/dev/null at every phase call site
# — fixed so the poll cycle itself names the quarantine.)
rc=0
pm_device_to_canonical "$RDHOME/saves/gba/Compressed Game.srm" >/dev/null 2>&1 || rc=$?
assert_rc "compressed save quarantined (rc 3)" 3 "$rc"

work=$(mktemp -d)
git clone "$REMOTE" "$work/v" >/dev/null 2>&1
assert_eq "poll pushed changed bytes" "zelda-sram-v2-longer" \
    "$(cat "$work/v/gba/Zelda Minish Cap (USA).srm" 2>/dev/null)"
rm -rf "$work"

remote_files=$(git -C "$REMOTE" ls-tree -r --name-only HEAD 2>/dev/null)
case "$remote_files" in
    *"Compressed Game"*) printf 'FAIL: RZIP save leaked into repo\n' >&2; failed=$((failed+1)) ;;
    *) passed=$((passed+1)) ;;
esac
assert_contains "quarantine names itself in the daemon log" \
    "$(cat "$poll_log")" "compressed save skipped"
rm -f "$RDHOME/saves/gba/Compressed Game.srm" "$RDHOME/roms/gba/Compressed Game.gba"

# =====================================================================
# Phase 3 — clean shutdown, then normal boot pull (+ sparse skip)
# =====================================================================

( rdd_shutdown ) >/dev/null 2>&1 || true
assert_file_exists "clean shutdown marker written" \
    "$CONTINUITY_REPO_DIR/.continuity/clean_shutdown"

# Remote gains: a save for a ROM the device HAS, one it does NOT have
remote_put "snes/Super Metroid (USA).srm" "metroid-from-elsewhere"
remote_put "snes/No Rom Here.srm" "orphan-save"

rc=0; rdd_boot_dispatch "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "normal boot pull ok" 0 "$rc"
assert_eq "remote save materialized (ROM present, RA-native name)" \
    "metroid-from-elsewhere" \
    "$(cat "$RDHOME/saves/snes/Super Metroid (USA).srm" 2>/dev/null)"
assert_absent "sparse: no ROM -> not materialized" "$RDHOME/saves/snes/No Rom Here.srm"
assert_absent "clean marker consumed" "$CONTINUITY_REPO_DIR/.continuity/clean_shutdown"

# =====================================================================
# Phase 4 — stale boot reconciles both directions
# =====================================================================

# No clean marker now. Local save changes "while daemon was down";
# remote advances independently.
sleep 1
printf 'zelda-sram-v3-after-crash' > "$RDHOME/saves/gba/Zelda Minish Cap (USA).srm"
remote_put "snes/Super Metroid (USA).srm" "metroid-v2"

rc=0; rdd_boot_dispatch "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "stale boot ok" 0 "$rc"

work=$(mktemp -d)
git clone "$REMOTE" "$work/v" >/dev/null 2>&1
assert_eq "stale: local change pushed" "zelda-sram-v3-after-crash" \
    "$(cat "$work/v/gba/Zelda Minish Cap (USA).srm" 2>/dev/null)"
rm -rf "$work"
assert_eq "stale: remote change applied" "metroid-v2" \
    "$(cat "$RDHOME/saves/snes/Super Metroid (USA).srm" 2>/dev/null)"

# =====================================================================
# Phase 5 — two-device conflict preserved through this PAL
# =====================================================================

# Local commits a change while the remote advances the SAME save.
sleep 1
printf 'zelda-device-side' > "$RDHOME/saves/gba/Zelda Minish Cap (USA).srm"
# Simulate offline (the container may have real network — an env unset
# is not enough): commit locally without pushing.
pal_is_online() { return 1; }
rdd_poll_once >/dev/null 2>&1 || true
pal_is_online() { return 0; }
remote_put "gba/Zelda Minish Cap (USA).srm" "zelda-remote-side"

rc=0; se_pull "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "divergent pull reports conflict" 1 "$rc"
rc=0; ch_handle_pull_conflict "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || rc=$?
assert_rc "conflict handler ok" 0 "$rc"
assert_file_exists "device version preserved as .local" \
    "$CONTINUITY_REPO_DIR/gba/Zelda Minish Cap (USA).srm.deck-flow.local"
assert_eq ".local holds device bytes" "zelda-device-side" \
    "$(cat "$CONTINUITY_REPO_DIR/gba/Zelda Minish Cap (USA).srm.deck-flow.local" 2>/dev/null)"
assert_file_exists "conflict metadata written" \
    "$CONTINUITY_REPO_DIR/gba/Zelda Minish Cap (USA).srm.conflict"

# Settle the conflict state so Phase 6 starts clean: keep the remote
# canon, drop artifacts, push.
git -C "$CONTINUITY_REPO_DIR" rm -q --ignore-unmatch \
    "gba/Zelda Minish Cap (USA).srm.deck-flow.local" \
    "gba/Zelda Minish Cap (USA).srm.conflict" >/dev/null 2>&1 || true
git -C "$CONTINUITY_REPO_DIR" commit -qm "test: settle conflict" >/dev/null 2>&1 || true
CONTINUITY_FORCE_ONLINE=1 se_push "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true
cp "$CONTINUITY_REPO_DIR/gba/Zelda Minish Cap (USA).srm" \
   "$RDHOME/saves/gba/Zelda Minish Cap (USA).srm"

# =====================================================================
# Phase 6 — the daemon as a real process (systemd's view of it)
# =====================================================================

sleep 1
printf 'zelda-live-daemon' > "$RDHOME/saves/gba/Zelda Minish Cap (USA).srm"

daemon_log="$TEST_TMPDIR/daemon.log"
# env(1), not a shell assignment prefix: sourcing the daemon NO_MAIN
# above made CONTINUITY_POLL_INTERVAL readonly in this shell.
env CONTINUITY_POLL_INTERVAL=1 \
    sh "$PROJECT_ROOT/src/platforms/retrodeck/continuity_daemon.sh" \
    >/dev/null 2>"$daemon_log" &
daemon_pid=$!

# give it: boot dispatch + at least one poll cycle
tries=20
while [ "$tries" -gt 0 ]; do
    work=$(mktemp -d)
    git clone "$REMOTE" "$work/v" >/dev/null 2>&1
    got=$(cat "$work/v/gba/Zelda Minish Cap (USA).srm" 2>/dev/null)
    rm -rf "$work"
    [ "$got" = "zelda-live-daemon" ] && break
    tries=$((tries - 1))
    sleep 1
done
if [ "$got" != "zelda-live-daemon" ]; then
    printf '  ── daemon log ──\n' >&2
    sed 's/^/  /' "$daemon_log" >&2
fi
assert_eq "live daemon synced the save" "zelda-live-daemon" "$got"

kill -TERM "$daemon_pid" 2>/dev/null
wait "$daemon_pid" 2>/dev/null || true
assert_file_exists "SIGTERM -> clean shutdown marker" \
    "$CONTINUITY_REPO_DIR/.continuity/clean_shutdown"
assert_contains "daemon shutdown named in log" "$(cat "$daemon_log")" "Shutdown: complete"

# =====================================================================
printf '\ntest_retrodeck_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
