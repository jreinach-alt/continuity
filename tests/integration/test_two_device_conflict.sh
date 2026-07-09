#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Integration test: TWO enrolled devices against ONE remote — the core
# product promise under concurrency: "if two devices modify the same
# save, both versions are kept — never silently overwrite."
#
# Each simulated device gets its own saves root, repo clone, identity,
# and offline switch; sync phases (cold start, boot pull, stale
# recovery, runtime poll, conflict handling) run through a per-device
# driver subprocess exactly as the daemon would call them — no timing,
# no sleeps, deterministic ordering.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
export HARNESS_ROOT="$TEST_TMPDIR"
export HARNESS_PROJECT_ROOT="$PROJECT_ROOT"

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

REMOTE="$TEST_TMPDIR/remote.git"
git init --bare "$REMOTE" >/dev/null 2>&1
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main

# Seed the remote
SEED="$TEST_TMPDIR/seed"
git clone "$REMOTE" "$SEED" >/dev/null 2>&1
git -C "$SEED" checkout -b main >/dev/null 2>&1 || true
git -C "$SEED" config user.email "seed@test"
git -C "$SEED" config user.name "Seed"
mkdir -p "$SEED/snes" "$SEED/gb"
printf 'seed-metroid' > "$SEED/snes/super_metroid.srm"
printf 'seed-zelda'   > "$SEED/gb/links_awakening.sav"
printf 'seed-mario'   > "$SEED/snes/Super Mario World (USA).srm"
git -C "$SEED" add -A >/dev/null
git -C "$SEED" commit -m "seed: initial saves" >/dev/null
git -C "$SEED" push origin main >/dev/null 2>&1
rm -rf "$SEED"

# remote_file <repo-rel-path> — canonical truth straight from the remote
remote_file() {
    git -C "$REMOTE" show "main:$1" 2>/dev/null
}

# remote_has <repo-rel-path> — 0 when the path exists at remote HEAD
remote_has() {
    git -C "$REMOTE" cat-file -e "main:$1" 2>/dev/null
}

# --- Device driver ---
# Runs one core function in a fully-initialized device context.
# Wrappers (d_*) keep scenarios readable.
cat > "$TEST_TMPDIR/driver.sh" <<'DRIVER'
#!/bin/sh
set -e
DEV="$1"; shift
DEV_HOME="$HARNESS_ROOT/dev-$DEV"

CONTINUITY_SAVES_ROOT="$DEV_HOME/Saves"
CONTINUITY_REPO_DIR="$DEV_HOME/repo"
CONTINUITY_DEVICE_NAME="$DEV"
CONTINUITY_STATES_ROOT="$DEV_HOME/states"
CONTINUITY_GIT_BIN="git"
CONTINUITY_SD_ROOT="$DEV_HOME"

pal_log() { printf '[%s] %s: %s\n' "$DEV" "$1" "$2" >> "$HARNESS_ROOT/harness.log"; }
pal_is_online() { [ ! -f "$DEV_HOME/offline" ]; }
pal_init() { mkdir -p "$CONTINUITY_SAVES_ROOT" "$(dirname "$CONTINUITY_REPO_DIR")"; return 0; }
pal_get_platform_map() { printf '%s\n' "$DEV_HOME/platform_map.json"; }

. "$HARNESS_PROJECT_ROOT/src/core/pal.sh"
. "$HARNESS_PROJECT_ROOT/src/core/path_mapper.sh"
. "$HARNESS_PROJECT_ROOT/src/core/sync_engine.sh"
. "$HARNESS_PROJECT_ROOT/src/core/enrollment.sh"
. "$HARNESS_PROJECT_ROOT/src/core/change_detector.sh"
. "$HARNESS_PROJECT_ROOT/src/core/cold_start.sh"
. "$HARNESS_PROJECT_ROOT/src/core/boot_pull.sh"
. "$HARNESS_PROJECT_ROOT/src/core/stale_boot.sh"
. "$HARNESS_PROJECT_ROOT/src/core/runtime_poll.sh"
. "$HARNESS_PROJECT_ROOT/src/core/conflict_handler.sh"
. "$HARNESS_PROJECT_ROOT/src/core/sync_status.sh"

pal_init

# Post-enrollment initialization, mirroring the daemon's cd_main
if [ -d "$CONTINUITY_REPO_DIR/.git" ]; then
    se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" >/dev/null 2>&1
    pm_load_platform_map "$(pal_get_platform_map)" >/dev/null 2>&1
fi

d_enroll()  { enroll_run "file://$HARNESS_ROOT/remote.git" "$DEV" "test-pat"; }
# One daemon poll tick — the REAL cd_poll_once, including the
# in-session divergence reconcile (sourced with NO_MAIN).
d_tick() {
    CONTINUITY_DAEMON_NO_MAIN=1
    CONTINUITY_PID_FILE="$DEV_HOME/tick.pid"
    . "$HARNESS_PROJECT_ROOT/src/platforms/nextui/continuity_daemon.sh"
    cd_poll_once
}
d_cold()    { cs_run "$CONTINUITY_REPO_DIR"; }
d_pull()    { bp_run "$CONTINUITY_REPO_DIR"; }
d_stale()   { sb_run "$CONTINUITY_REPO_DIR"; }
d_poll()    { rp_run "$CONTINUITY_REPO_DIR"; }

# d_write_save <saves-rel-path> <content> — a save landing on the device,
# with the sentinel backdated so the next poll must see it.
d_write_save() {
    mkdir -p "$CONTINUITY_SAVES_ROOT/$(dirname "$1")"
    printf '%s' "$2" > "$CONTINUITY_SAVES_ROOT/$1"
    touch -d '2001-01-01 00:00:00' "$CONTINUITY_REPO_DIR/.continuity/sentinel" 2>/dev/null || true
}

d_device_file() { cat "$CONTINUITY_SAVES_ROOT/$1"; }
d_repo_file()   { cat "$CONTINUITY_REPO_DIR/$1"; }
d_repo_has()    { [ -f "$CONTINUITY_REPO_DIR/$1" ]; }
d_conflicts()   { ch_count_conflicts "$CONTINUITY_REPO_DIR"; }
d_resolve()     { ch_resolve "$CONTINUITY_REPO_DIR" "$1" "$2"; }
d_offline()     { touch "$DEV_HOME/offline"; }
d_online()      { rm -f "$DEV_HOME/offline"; }
d_local_files() { ch_list_local_files "$CONTINUITY_REPO_DIR"; }
d_conflict_field() {
    grep "\"$2\"" "$CONTINUITY_REPO_DIR/$1.conflict" | sed 's/.*: *"\([^"]*\)".*/\1/'
}
# Unpushed local commits present? prints yes/no
d_has_unpushed() {
    if se_has_unpushed_commits "$CONTINUITY_REPO_DIR" 2>/dev/null; then
        printf 'yes\n'
    else
        printf 'no\n'
    fi
}

"$@"
DRIVER
chmod +x "$TEST_TMPDIR/driver.sh"

# dev <name> <wrapper> [args...]
dev() {
    busybox ash "$TEST_TMPDIR/driver.sh" "$@"
}

mk_device() {
    local name
    name="$1"
    mkdir -p "$TEST_TMPDIR/dev-$name/Saves" "$TEST_TMPDIR/dev-$name/states"
    cp "$PROJECT_ROOT/config/platform_maps/nextui.json" \
       "$TEST_TMPDIR/dev-$name/platform_map.json"
    dev "$name" d_enroll >/dev/null 2>&1
}

# ═══ Setup: two devices, both enrolled and cold-started ═══════════════
# Enrollment pushes a device-registration commit, so each enrollment
# moves the remote; cold-start both AFTER both registrations (as real
# boots would) so the scenarios begin from a shared head.
mk_device brick-a
mk_device deck-b
dev brick-a d_cold >/dev/null 2>&1
dev deck-b  d_cold >/dev/null 2>&1

assert_eq "setup: A cold start pulled seed save" \
    "seed-metroid" "$(dev brick-a d_repo_file snes/super_metroid.srm)"
assert_eq "setup: B cold start pulled seed save" \
    "seed-metroid" "$(dev deck-b d_repo_file snes/super_metroid.srm)"

# ═══ S1: plain propagation A → B ══════════════════════════════════════
dev brick-a d_write_save "SFC/super_metroid.srm" "A-progress-1"
rc=0; dev brick-a d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S1: A poll syncs and pushes" 0 "$rc"
assert_eq "S1: remote canonical is A's version" \
    "A-progress-1" "$(remote_file snes/super_metroid.srm)"

rc=0; dev deck-b d_pull >/dev/null 2>&1 || rc=$?
assert_rc "S1: B boot pull succeeds" 0 "$rc"
assert_eq "S1: B repo received A's version" \
    "A-progress-1" "$(dev deck-b d_repo_file snes/super_metroid.srm)"
assert_eq "S1: B device save updated" \
    "A-progress-1" "$(dev deck-b d_device_file SFC/super_metroid.srm)"

# ═══ S2: true concurrent divergence on one .srm ═══════════════════════
# Both play the same game while apart; A syncs first; B's runtime push
# is rejected; B's next boot runs stale recovery -> conflict handler.
dev brick-a d_write_save "SFC/super_metroid.srm" "A-progress-2"
dev deck-b  d_write_save "SFC/super_metroid.srm" "B-progress-2"
rc=0; dev brick-a d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S2: A syncs first" 0 "$rc"

rc=0; dev deck-b d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S2: B poll commits locally but push is rejected (rc 1)" 1 "$rc"
assert_eq "S2: B holds unpushed commits" "yes" "$(dev deck-b d_has_unpushed)"

rc=0; dev deck-b d_stale >/dev/null 2>&1 || rc=$?
assert_rc "S2: B stale recovery handles the divergence" 0 "$rc"

assert_eq "S2: canonical on remote is A's version" \
    "A-progress-2" "$(remote_file snes/super_metroid.srm)"
assert_eq "S2: B's version preserved on remote as .local" \
    "B-progress-2" "$(remote_file "snes/super_metroid.srm.deck-b.local")"
rc=0; remote_has "snes/super_metroid.srm.conflict" || rc=$?
assert_rc "S2: conflict metadata pushed to remote" 0 "$rc"
assert_eq "S2: conflict names the local device" \
    "deck-b" "$(dev deck-b d_conflict_field snes/super_metroid.srm local_device)"
assert_eq "S2: conflict attributes the remote device from the commit trailer" \
    "brick-a" "$(dev deck-b d_conflict_field snes/super_metroid.srm remote_device)"
assert_eq "S2: exactly one conflict on B" "1" "$(dev deck-b d_conflicts)"

# A learns about the conflict on next boot
rc=0; dev brick-a d_pull >/dev/null 2>&1 || rc=$?
assert_rc "S2: A boot pull succeeds after conflict commit" 0 "$rc"
assert_eq "S2: A sees the same conflict" "1" "$(dev brick-a d_conflicts)"
assert_eq "S2: A's device save untouched (canonical already A's)" \
    "A-progress-2" "$(dev brick-a d_device_file SFC/super_metroid.srm)"

# ═══ S2b: in-session divergence reconcile — NO reboot involved ════════
# Gap review 2026-07-07: a powered-on device whose push is rejected
# used to retry blindly until reboot. Now the poll tick itself detects
# the stranded commits and reconciles inline.
dev brick-a d_write_save "SFC/donkey_kong.srm" "A-dk-1"
rc=0; dev brick-a d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S2b: A pushes a new game" 0 "$rc"

dev deck-b d_write_save "SFC/donkey_kong.srm" "B-dk-1"
rc=0; dev deck-b d_tick >/dev/null 2>&1 || rc=$?
assert_rc "S2b: B's poll tick returns 0 despite rejected push" 0 "$rc"

assert_eq "S2b: canonical is A's (reconciled without reboot)" \
    "A-dk-1" "$(remote_file snes/donkey_kong.srm)"
assert_eq "S2b: B's version preserved as .local by the TICK" \
    "B-dk-1" "$(remote_file "snes/donkey_kong.srm.deck-b.local")"
assert_eq "S2b: B holds nothing unpushed after the tick" \
    "no" "$(dev deck-b d_has_unpushed)"
assert_eq "S2b: B device slot follows canonical" \
    "A-dk-1" "$(dev deck-b d_device_file SFC/donkey_kong.srm)"

# fence — converge both devices on the current remote head (what the
# next real boot would do) so each scenario starts from shared state.
fence() {
    dev brick-a d_pull >/dev/null 2>&1 || true
    dev deck-b  d_pull >/dev/null 2>&1 || true
}

fence
# ═══ S3: divergence on a .sav (the Brick's DEFAULT format) ════════════
dev brick-a d_write_save "GB/links_awakening.sav" "A-zelda-2"
dev deck-b  d_write_save "GB/links_awakening.sav" "B-zelda-2"
rc=0; dev brick-a d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S3: A syncs .sav first" 0 "$rc"
rc=0; dev deck-b d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S3: B .sav push rejected" 1 "$rc"
rc=0; dev deck-b d_stale >/dev/null 2>&1 || rc=$?
assert_rc "S3: B stale recovery on .sav divergence" 0 "$rc"

assert_eq "S3: canonical .sav on remote is A's" \
    "A-zelda-2" "$(remote_file gb/links_awakening.sav)"
assert_eq "S3: B's .sav version preserved on remote (NEVER silently lost)" \
    "B-zelda-2" "$(remote_file "gb/links_awakening.sav.deck-b.local")"

fence
# ═══ S4: spaced filename through the conflict path ════════════════════
dev brick-a d_write_save "SFC/Super Mario World (USA).srm" "A-mario-2"
dev deck-b  d_write_save "SFC/Super Mario World (USA).srm" "B-mario-2"
rc=0; dev brick-a d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S4: A syncs spaced save" 0 "$rc"
rc=0; dev deck-b d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S4: B spaced push rejected" 1 "$rc"
rc=0; dev deck-b d_stale >/dev/null 2>&1 || rc=$?
assert_rc "S4: B stale recovery on spaced-name divergence" 0 "$rc"

assert_eq "S4: canonical spaced save is A's" \
    "A-mario-2" "$(remote_file "snes/Super Mario World (USA).srm")"
assert_eq "S4: B's spaced version preserved (quoting-proof)" \
    "B-mario-2" "$(remote_file "snes/Super Mario World (USA).srm.deck-b.local")"

fence
# ═══ S5: non-overlapping offline progress (different games) ═══════════
# The everyday case: both devices used offline overnight on DIFFERENT
# games. No same-file conflict exists — recovery must weave both
# histories without losing or mislabeling anything.
dev brick-a d_write_save "SFC/chrono_trigger.srm" "A-chrono-1"
rc=0; dev brick-a d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S5: A pushes a brand-new game save" 0 "$rc"

dev deck-b d_offline
dev deck-b d_write_save "GBA/minish_cap.srm" "B-minish-1"
rc=0; dev deck-b d_poll >/dev/null 2>&1 || rc=$?
assert_rc "S5: B offline poll queues the commit (rc 0)" 0 "$rc"
assert_eq "S5: B holds queued commit" "yes" "$(dev deck-b d_has_unpushed)"
dev deck-b d_online

rc=0; dev deck-b d_stale >/dev/null 2>&1 || rc=$?
assert_rc "S5: B reconnect recovery weaves diverged histories" 0 "$rc"

assert_eq "S5: A's new game survived on remote" \
    "A-chrono-1" "$(remote_file snes/chrono_trigger.srm)"
assert_eq "S5: B's queued game survived on remote" \
    "B-minish-1" "$(remote_file gba/minish_cap.srm)"
assert_eq "S5: B's repo has A's new game after recovery" \
    "A-chrono-1" "$(dev deck-b d_repo_file snes/chrono_trigger.srm)"
# One-sided adds are NOT conflicts: no bogus artifacts for either file
rc=0; remote_has "snes/chrono_trigger.srm.deck-b.local" && rc=1 || true
assert_rc "S5: no bogus .local for A's one-sided add" 0 "$rc"
rc=0; remote_has "gba/minish_cap.srm.conflict" && rc=1 || true
assert_rc "S5: no bogus .conflict for B's one-sided add" 0 "$rc"

fence
# ═══ S6: resolution round-trip (keep_local on B) ══════════════════════
rc=0; dev deck-b d_resolve snes/super_metroid.srm keep_local >/dev/null 2>&1 || rc=$?
assert_rc "S6: B resolves S2's conflict keeping its own version" 0 "$rc"
assert_eq "S6: remote canonical is now B's version" \
    "B-progress-2" "$(remote_file snes/super_metroid.srm)"
rc=0; remote_has "snes/super_metroid.srm.deck-b.local" && rc=1 || true
assert_rc "S6: .local artifact removed from remote" 0 "$rc"
rc=0; remote_has "snes/super_metroid.srm.conflict" && rc=1 || true
assert_rc "S6: .conflict artifact removed from remote" 0 "$rc"

rc=0; dev brick-a d_pull >/dev/null 2>&1 || rc=$?
assert_rc "S6: A pulls the resolution" 0 "$rc"
assert_eq "S6: A's device save now carries B's resolved version" \
    "B-progress-2" "$(dev brick-a d_device_file SFC/super_metroid.srm)"

# ═══ The invariant: every version ever synced is still reachable ══════
# (canonical or .local at remote HEAD, or in remote history)
in_remote_history() {
    git -C "$REMOTE" log --all --format='%H' | while IFS= read -r h; do
        git -C "$REMOTE" grep -q -F "$1" "$h" 2>/dev/null && printf 'found\n' && break
    done
}
for bytes in A-progress-1 A-progress-2 B-progress-2 A-zelda-2 B-zelda-2 \
             A-mario-2 B-mario-2 A-chrono-1 B-minish-1; do
    assert_eq "invariant: '$bytes' reachable in remote history" \
        "found" "$(in_remote_history "$bytes")"
done

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
