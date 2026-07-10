#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC1090,SC1091
# Integration test — Sprint 2.2: the RetroDeck conflict-resolution
# surface end-to-end. A REAL two-device divergence (engine-produced v2
# .conflict via the actual poll → rejected push → reconcile path) is
# resolved through resolve_conflicts.sh running as a separate process —
# the shared cu_* controller rendered by the Deck's pal_ui_* shims.
#
#   Phase 1 — cold start + real divergence: one game group (.srm + .rtc)
#   Phase 2 — resolver (CLI backend, scripted stdin): keep the OTHER
#             device's copy — both members flip as a unit, artifacts
#             removed, resolution pushed, device slot materialized
#   Phase 3 — try → play-on → promote the third version across two
#             resolver invocations
#   Phase 4 — zero conflicts: the in-sync message
#   Phase 5 — the kdialog dialog path (stub) resolves keep-local e2e
set -e

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
DAEMON="$PROJECT_ROOT/src/platforms/retrodeck/continuity_daemon.sh"
RESOLVER="$PROJECT_ROOT/src/platforms/retrodeck/resolve_conflicts.sh"

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
        *) printf 'FAIL: %s\n  text lacks: %s\n' "$desc" "$pattern" >&2; failed=$((failed + 1)) ;;
    esac
}

# --- Sandbox ---------------------------------------------------------

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

RDHOME="$TEST_TMPDIR/rd home"
RD_CONF_DIR="$TEST_TMPDIR/rdconf"
mkdir -p "$RDHOME/saves/gb" "$RDHOME/states" "$RDHOME/roms/gb" "$RD_CONF_DIR"
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

SANDBOX_HOME="$TEST_TMPDIR/home"
mkdir -p "$SANDBOX_HOME"
CONTINUITY_RD_CONF="$RD_CONF_DIR/retrodeck.json"
CONTINUITY_REPO_DIR="$SANDBOX_HOME/.local/share/continuity/repo"
CONTINUITY_APP_DIR="$PROJECT_ROOT"
CONTINUITY_FORCE_ONLINE=1
export CONTINUITY_RD_CONF CONTINUITY_REPO_DIR CONTINUITY_APP_DIR CONTINUITY_FORCE_ONLINE

# The game: RetroArch-native names on the Deck, ROM present so the
# reverse mapping (canonical -> device slot) works for try/materialize.
SRM_DEV="$RDHOME/saves/gb/Pokemon Crystal.srm"
RTC_DEV="$RDHOME/saves/gb/Pokemon Crystal.rtc"
: > "$RDHOME/roms/gb/Pokemon Crystal.gb"
printf 'deck-srm-v1' > "$SRM_DEV"
printf 'deck-rtc-v1' > "$RTC_DEV"

# Phase 0 — enroll, then load the daemon's function surface (real PAL +
# all core modules, exactly as the daemon sources them).
PAT_FILE="$TEST_TMPDIR/pat"
printf 'file-remote-needs-no-pat' > "$PAT_FILE"
rc=0
HOME="$SANDBOX_HOME" sh "$PROJECT_ROOT/src/platforms/retrodeck/enroll_retrodeck.sh" \
    --repo-url "file://$REMOTE" --device-name deck-ui \
    --pat-file "$PAT_FILE" --no-service >/dev/null 2>&1 || rc=$?
assert_rc "enrollment ok" 0 "$rc"

CONTINUITY_DAEMON_NO_MAIN=1
. "$DAEMON"
rdd_load_modules
# The daemon doesn't drive the UI controller; the test's group
# assertions do.
. "$PROJECT_ROOT/src/core/conflict_ui.sh"
pal_init >/dev/null 2>&1
pal_validate
se_init "$CONTINUITY_REPO_DIR" "$CONTINUITY_DEVICE_NAME" >/dev/null 2>&1
pm_load_platform_map "$(pal_get_platform_map)" 2>/dev/null

# other_commit <repo-rel path> <bytes> <ts> — the second device writes
# from "elsewhere" with the device/timestamp trailer the engine parses.
OTHER="$TEST_TMPDIR/other"
git clone "$REMOTE" "$OTHER" >/dev/null 2>&1
git -C "$OTHER" checkout main >/dev/null 2>&1 || true
git -C "$OTHER" config user.email c@other; git -C "$OTHER" config user.name Continuity
other_commit() {
    printf '%s' "$2" > "$OTHER/$1"
    git -C "$OTHER" add "$1" >/dev/null 2>&1
    git -C "$OTHER" commit \
        -m "$(printf 'save\n\ndevice: brick-a\ntimestamp: %s' "$3")" >/dev/null 2>&1
    git -C "$OTHER" push -q origin main
}

# run_resolver <stdin-text> <stderr-log> [extra args...]
run_resolver() {
    local input="$1" errlog="$2" rrc=0
    shift 2
    printf '%s' "$input" | \
        HOME="$SANDBOX_HOME" CONTINUITY_UI_BACKEND="${RESOLVER_BACKEND:-cli}" \
        sh "$RESOLVER" "$@" >"$TEST_TMPDIR/resolver.out" 2>"$errlog" || rrc=$?
    printf '%s' "$rrc"
}

# =====================================================================
# Phase 1 — cold start, then a REAL divergence through the poll path
# =====================================================================
printf '=== Phase 1: cold start + real divergence ===\n' >&2

cs_run "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true
assert_eq "cold start pushed canonical srm" "deck-srm-v1" \
    "$(git -C "$REMOTE" show 'main:gb/Pokemon Crystal.srm' 2>/dev/null)"

# The other device diverges both members of the game...
git -C "$OTHER" pull -q origin main
other_commit "gb/Pokemon Crystal.srm" "brick-srm-v2" "2026-07-09T13:00:00Z"
other_commit "gb/Pokemon Crystal.rtc" "brick-rtc-v2" "2026-07-09T13:00:00Z"

# ...while the Deck plays on (mtime granularity: settle before writing).
sleep 1
printf 'deck-srm-v2' > "$SRM_DEV"
printf 'deck-rtc-v2' > "$RTC_DEV"

# Poll: commits locally, push rejected (remote moved) — the real path.
rp_run "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true
# Reconcile: preserve deck's bytes, accept remote as canonical.
ch_handle_pull_conflict "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true

assert_eq "one conflict group" "1" \
    "$(cu_list_groups "$CONTINUITY_REPO_DIR" | grep -c '.')"
assert_eq "two members (.srm + .rtc)" "2" \
    "$(cu_group_members "$CONTINUITY_REPO_DIR" "gb/Pokemon Crystal" | grep -c '.')"
conflict_json=$(cat "$CONTINUITY_REPO_DIR/gb/Pokemon Crystal.srm.conflict")
assert_contains "v2 schema from the engine" "$conflict_json" '"_schema_version": "2.0"'
assert_contains "remote device attributed" "$conflict_json" '"remote_device": "brick-a"'

# =====================================================================
# Phase 2 — resolver process (CLI backend): keep the OTHER side
# =====================================================================
printf '=== Phase 2: resolver keeps the other device copy ===\n' >&2

remote_before=$(git -C "$REMOTE" rev-parse refs/heads/main)
# stdin: group 1 -> detail item 3 (Keep brick-a's copy) -> y
rc=$(run_resolver '1
3
y
' "$TEST_TMPDIR/p2.err")
assert_rc "resolver exits 0" 0 "$rc"

assert_eq "canonical .srm is brick-a's" "brick-srm-v2" \
    "$(cat "$CONTINUITY_REPO_DIR/gb/Pokemon Crystal.srm")"
assert_eq "canonical .rtc is brick-a's (group unit)" "brick-rtc-v2" \
    "$(cat "$CONTINUITY_REPO_DIR/gb/Pokemon Crystal.rtc")"
assert_absent ".srm conflict gone" "$CONTINUITY_REPO_DIR/gb/Pokemon Crystal.srm.conflict"
assert_absent ".rtc conflict gone" "$CONTINUITY_REPO_DIR/gb/Pokemon Crystal.rtc.conflict"
assert_eq "no .local remains" "0" \
    "$(find "$CONTINUITY_REPO_DIR" -name '*.local' ! -path '*/.git/*' | grep -c '.' || true)"
assert_eq "device slot materialized to the kept side" "brick-srm-v2" "$(cat "$SRM_DEV")"

remote_after=$(git -C "$REMOTE" rev-parse refs/heads/main)
if [ "$remote_after" != "$remote_before" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: resolution was not pushed\n' >&2
    failed=$((failed + 1))
fi
assert_eq "remote tip == deck HEAD" \
    "$(git -C "$CONTINUITY_REPO_DIR" rev-parse HEAD)" "$remote_after"

# =====================================================================
# Phase 3 — try, play on it, promote the third version (two launches)
# =====================================================================
printf '=== Phase 3: try -> play-on -> promote ===\n' >&2

git -C "$OTHER" pull -q origin main
other_commit "gb/Pokemon Crystal.srm" "brick-srm-v3" "2026-07-10T09:00:00Z"
sleep 1
printf 'deck-srm-v3' > "$SRM_DEV"
rp_run "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true
ch_handle_pull_conflict "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true
assert_eq "fresh conflict present" "1" "$(ch_count_conflicts "$CONTINUITY_REPO_DIR")"

# Resolver launch #1: group 1 -> Try brick-a's copy (item 1) -> handoff.
rc=$(run_resolver '1
1
' "$TEST_TMPDIR/p3a.err")
assert_rc "try launch exits 0" 0 "$rc"
rc=0; ch_is_trying "$CONTINUITY_REPO_DIR" "gb/Pokemon Crystal.srm" || rc=$?
assert_rc "trying state set" 0 "$rc"
assert_eq "live slot holds the tried copy" "brick-srm-v3" "$(cat "$SRM_DEV")"
assert_contains "handoff message shown" "$(cat "$TEST_TMPDIR/p3a.err")" "Play, then reopen Continuity"

# The user goes and plays on the tried copy — a NEW third version.
printf 'brick-srm-v3-played-on-deck' > "$SRM_DEV"
rc=0; ch_is_trying_modified "$CONTINUITY_REPO_DIR" "gb/Pokemon Crystal.srm" || rc=$?
assert_rc "played-on detected" 0 "$rc"

remote_before=$(git -C "$REMOTE" rev-parse refs/heads/main)
# Resolver launch #2: group 1 -> "Keep your progress" (item 1).
rc=$(run_resolver '1
1
' "$TEST_TMPDIR/p3b.err")
assert_rc "promote launch exits 0" 0 "$rc"
assert_eq "canonical is the played third version" "brick-srm-v3-played-on-deck" \
    "$(cat "$CONTINUITY_REPO_DIR/gb/Pokemon Crystal.srm")"
assert_eq "no conflicts remain" "0" "$(ch_count_conflicts "$CONTINUITY_REPO_DIR")"
remote_after=$(git -C "$REMOTE" rev-parse refs/heads/main)
if [ "$remote_after" != "$remote_before" ]; then
    passed=$((passed + 1))
else
    printf 'FAIL: promotion was not pushed\n' >&2
    failed=$((failed + 1))
fi

# =====================================================================
# Phase 4 — nothing to resolve: the in-sync empty state
# =====================================================================
printf '=== Phase 4: zero conflicts ===\n' >&2

rc=$(run_resolver '' "$TEST_TMPDIR/p4.err")
assert_rc "empty-state run exits 0" 0 "$rc"
assert_contains "in-sync message" "$(cat "$TEST_TMPDIR/p4.err")" "No conflicts. Everything's in sync."

# =====================================================================
# Phase 5 — the dialog path: stub kdialog resolves keep-local e2e
# =====================================================================
printf '=== Phase 5: kdialog backend (stub) ===\n' >&2

git -C "$OTHER" pull -q origin main
other_commit "gb/Pokemon Crystal.srm" "brick-srm-v4" "2026-07-10T11:00:00Z"
sleep 1
printf 'deck-srm-v4' > "$SRM_DEV"
rp_run "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true
ch_handle_pull_conflict "$CONTINUITY_REPO_DIR" >/dev/null 2>&1 || true
assert_eq "P5: conflict present" "1" "$(ch_count_conflicts "$CONTINUITY_REPO_DIR")"

# Stub kdialog: menus pop scripted answers (a queue file, consumed via a
# counter file so it survives subshells); --yesno and --msgbox accept.
KD_DIR="$TEST_TMPDIR/kd"
mkdir -p "$KD_DIR"
cat > "$KD_DIR/kdialog" <<'EOF'
#!/bin/sh
mode=""
for a in "$@"; do
    case "$a" in
        --menu) mode=menu ;;
        --yesno|--msgbox) mode=accept ;;
    esac
done
if [ "$mode" = "menu" ]; then
    seen=0
    [ -f "$KD_ANSWERS.seen" ] && seen=$(cat "$KD_ANSWERS.seen")
    seen=$((seen + 1))
    printf '%s' "$seen" > "$KD_ANSWERS.seen"
    ans=$(sed -n "${seen}p" "$KD_ANSWERS")
    if [ -z "$ans" ]; then exit 1; fi   # queue exhausted -> cancel
    printf '%s\n' "$ans"
    exit 0
fi
exit 0
EOF
chmod +x "$KD_DIR/kdialog"

KD_ANSWERS="$TEST_TMPDIR/kd_answers"
# list: group 0 -> detail: tag 3 = Keep deck-ui's copy -> (yesno accepts)
printf '0\n3\n' > "$KD_ANSWERS"
: > "$KD_ANSWERS.seen"

rc=0
HOME="$SANDBOX_HOME" PATH="$KD_DIR:$PATH" KD_ANSWERS="$KD_ANSWERS" \
    sh "$RESOLVER" --backend kdialog >/dev/null 2>"$TEST_TMPDIR/p5.err" </dev/null || rc=$?
assert_rc "P5: dialog resolver exits 0" 0 "$rc"
assert_eq "P5: canonical is the deck's copy (keep_local)" "deck-srm-v4" \
    "$(cat "$CONTINUITY_REPO_DIR/gb/Pokemon Crystal.srm")"
assert_eq "P5: no conflicts remain" "0" "$(ch_count_conflicts "$CONTINUITY_REPO_DIR")"
assert_eq "P5: resolution pushed" \
    "$(git -C "$CONTINUITY_REPO_DIR" rev-parse HEAD)" \
    "$(git -C "$REMOTE" rev-parse refs/heads/main)"

printf '\ntest_retrodeck_conflict_ui_flow: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
