#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/nextui/continuity_daemon.sh
# QA against sprint 1.1 (PID, module loading, enrollment), 1.2 (boot
# dispatch), and 1.3 (shutdown marker logic) acceptance criteria.
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

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Source the daemon functions without running the daemon. PID file must be
# redirected BEFORE sourcing — the daemon locks it with readonly.
CONTINUITY_PID_FILE="$TEST_TMPDIR/continuity.pid"
CONTINUITY_DAEMON_NO_MAIN=1
. "$PROJECT_ROOT/src/platforms/nextui/continuity_daemon.sh"

# Quiet log capture for assertions on logged messages
LOG_CAPTURE="$TEST_TMPDIR/log_capture.txt"
pal_log() {
    printf '%s: %s\n' "$1" "$2" >> "$LOG_CAPTURE"
}

# Real file-predicate + marker functions from core
. "$PROJECT_ROOT/src/core/cold_start.sh"
. "$PROJECT_ROOT/src/core/stale_boot.sh"

# ═══ Sprint 1.1 — PID management (AC 1-6) ═══════════════════════════

# AC 5: cd_write_pid writes current PID
cd_write_pid
assert_file_exists "AC5: PID file written" "$CONTINUITY_PID_FILE"
assert_eq "AC5: PID file contains \$\$" "$$" "$(cat "$CONTINUITY_PID_FILE")"

# AC 1: running process detected
sleep 60 &
live_pid=$!
printf '%s\n' "$live_pid" > "$CONTINUITY_PID_FILE"
rc=0; cd_is_running || rc=$?
assert_rc "AC1: live PID detected as running" 0 "$rc"
kill "$live_pid" 2>/dev/null
wait "$live_pid" 2>/dev/null || true

# AC 3: stale PID removed and reported not-running
sleep 0.1 &
dead_pid=$!
wait "$dead_pid" 2>/dev/null || true
printf '%s\n' "$dead_pid" > "$CONTINUITY_PID_FILE"
rc=0; cd_is_running || rc=$?
assert_rc "AC3: stale PID reports not running" 1 "$rc"
assert_file_not_exists "AC3: stale PID file removed" "$CONTINUITY_PID_FILE"

# AC 2: absent PID file
rc=0; cd_is_running || rc=$?
assert_rc "AC2: absent PID file reports not running" 1 "$rc"

# AC 4: non-numeric PID content
printf 'garbage\n' > "$CONTINUITY_PID_FILE"
rc=0; cd_is_running || rc=$?
assert_rc "AC4: garbage PID reports not running" 1 "$rc"
assert_file_not_exists "AC4: garbage PID file removed" "$CONTINUITY_PID_FILE"

# AC 6: cd_remove_pid idempotent
cd_write_pid
cd_remove_pid
assert_file_not_exists "AC6: PID file removed" "$CONTINUITY_PID_FILE"
rc=0; cd_remove_pid || rc=$?
assert_rc "AC6: second remove still returns 0" 0 "$rc"

# ═══ Sprint 1.1 — Module loading (AC 8-11) ══════════════════════════

FAKE_PAK="$TEST_TMPDIR/pak"
mkdir -p "$FAKE_PAK/scripts/core"
ln -s "$PROJECT_ROOT/src/platforms/nextui/pal_nextui.sh" "$FAKE_PAK/scripts/pal_nextui.sh"
ln -s "$PROJECT_ROOT/src/platforms/nextui/enroll_sd_card.sh" "$FAKE_PAK/scripts/enroll_sd_card.sh"
for m in pal path_mapper sync_engine enrollment change_detector cold_start \
         boot_pull stale_boot runtime_poll conflict_handler sync_status; do
    ln -s "$PROJECT_ROOT/src/core/$m.sh" "$FAKE_PAK/scripts/core/$m.sh"
done

# AC 8-9: happy path — all modules load, key functions defined
out=$(
    CONTINUITY_PAK_DIR="$FAKE_PAK"
    cd_load_modules 2>/dev/null
    ok=1
    for fn in enroll_is_enrolled se_init pm_load_platform_map \
              cs_is_cold_start sb_is_stale bp_run rp_run esd_import; do
        command -v "$fn" >/dev/null 2>&1 || ok=0
    done
    printf '%s' "$ok"
)
assert_eq "AC8/9: modules load and all key functions defined" "1" "$out"

# AC 10-11: missing module → exit 1, PID file cleaned up
rm "$FAKE_PAK/scripts/core/runtime_poll.sh"
cd_write_pid
rc=0
( CONTINUITY_PAK_DIR="$FAKE_PAK"; cd_load_modules ) 2>/dev/null || rc=$?
assert_rc "AC10: missing module exits 1" 1 "$rc"
assert_file_not_exists "AC11: PID cleaned up on module failure" "$CONTINUITY_PID_FILE"
ln -s "$PROJECT_ROOT/src/core/runtime_poll.sh" "$FAKE_PAK/scripts/core/runtime_poll.sh"

# CRLF-corrupted module → exit 1 with a named error, PID cleaned up
rm "$FAKE_PAK/scripts/core/runtime_poll.sh"
sed 's/$/\r/' "$PROJECT_ROOT/src/core/runtime_poll.sh" \
    > "$FAKE_PAK/scripts/core/runtime_poll.sh"
cd_write_pid
rc=0
( CONTINUITY_PAK_DIR="$FAKE_PAK"; cd_load_modules ) 2>"$TEST_TMPDIR/crlf_err.txt" || rc=$?
assert_rc "CRLF module exits 1" 1 "$rc"
assert_file_not_exists "PID cleaned up on CRLF failure" "$CONTINUITY_PID_FILE"
if grep -q "CRLF line endings in" "$TEST_TMPDIR/crlf_err.txt"; then
    assert_eq "CRLF failure named in log" "named" "named"
else
    assert_eq "CRLF failure named in log" "named" "cryptic"
fi
rm "$FAKE_PAK/scripts/core/runtime_poll.sh"
ln -s "$PROJECT_ROOT/src/core/runtime_poll.sh" "$FAKE_PAK/scripts/core/runtime_poll.sh"

# ═══ Sprint 1.1 — Enrollment check (AC 12-26) ═══════════════════════

# cd_check_enrollment probes the network before enrolling; default to
# online with zero wait so these tests are deterministic and fast.
pal_is_online() { return 0; }
CONTINUITY_NET_WAIT_SLEEP=0

# AC 12-13: already enrolled — esd_import not called
enroll_is_enrolled() { return 0; }
esd_detect_setup_file() { return 0; }
esd_import() { touch "$TEST_TMPDIR/import_called"; return 0; }
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC12: already enrolled returns 0" 0 "$rc"
assert_file_not_exists "AC12: esd_import not called when enrolled" "$TEST_TMPDIR/import_called"

# AC 21-22: not enrolled, no setup.json
enroll_is_enrolled() { return 1; }
esd_detect_setup_file() { return 1; }
: > "$LOG_CAPTURE"
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC21: no setup.json returns 1" 1 "$rc"
if grep -q "setup.json" "$LOG_CAPTURE"; then
    assert_eq "AC22: missing setup.json logged" "logged" "logged"
else
    assert_eq "AC22: missing setup.json logged" "logged" "not-logged"
fi

# AC 14/17: fresh enrollment succeeds
esd_detect_setup_file() { return 0; }
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC17: fresh enrollment returns 0" 0 "$rc"
assert_file_exists "AC14: esd_import called" "$TEST_TMPDIR/import_called"

# AC 24-25: enrollment failure
esd_import() { return 1; }
: > "$LOG_CAPTURE"
rc=0; cd_check_enrollment || rc=$?
assert_rc "AC24: failed enrollment returns 1" 1 "$rc"
if grep -qi "failed" "$LOG_CAPTURE"; then
    assert_eq "AC25: enrollment failure logged" "logged" "logged"
else
    assert_eq "AC25: enrollment failure logged" "logged" "not-logged"
fi

# Boot WiFi race: enrollment waits (bounded) for the network to come up
NET_COUNTER="$TEST_TMPDIR/net_calls"
printf '0' > "$NET_COUNTER"
pal_is_online() {
    local n
    n=$(cat "$NET_COUNTER")
    n=$((n + 1))
    printf '%s' "$n" > "$NET_COUNTER"
    [ "$n" -ge 3 ]    # offline for the first 2 probes, then online
}
esd_import() { touch "$TEST_TMPDIR/net_import_called"; return 0; }
CONTINUITY_NET_WAIT_TICKS=5
CONTINUITY_NET_WAIT_SLEEP=0
rc=0; cd_check_enrollment || rc=$?
assert_rc "net-wait: enrollment succeeds once network appears" 0 "$rc"
assert_file_exists "net-wait: esd_import ran after wait" "$TEST_TMPDIR/net_import_called"

# Network never appears within the window → fail, retry next boot
pal_is_online() { return 1; }
rm -f "$TEST_TMPDIR/net_import_called"
: > "$LOG_CAPTURE"
CONTINUITY_NET_WAIT_TICKS=2
rc=0; cd_check_enrollment || rc=$?
assert_rc "net-wait: offline forever returns 1" 1 "$rc"
assert_file_not_exists "net-wait: esd_import never attempted offline" \
    "$TEST_TMPDIR/net_import_called"
if grep -q "network never came up" "$LOG_CAPTURE"; then
    assert_eq "net-wait: offline outcome logged" "logged" "logged"
else
    assert_eq "net-wait: offline outcome logged" "logged" "not-logged"
fi
pal_is_online() { return 0; }
CONTINUITY_NET_WAIT_TICKS=""
CONTINUITY_NET_WAIT_SLEEP=""

# ═══ Sprint 1.2 — Boot dispatch (AC 1-11) ═══════════════════════════

REPO="$TEST_TMPDIR/repo"
mkdir -p "$REPO/.continuity"

cs_run() { printf '%s' "$1" > "$TEST_TMPDIR/cs_run_arg"; }
sb_run() { printf '%s' "$1" > "$TEST_TMPDIR/sb_run_arg"; }
bp_run() { printf '%s' "$1" > "$TEST_TMPDIR/bp_run_arg"; }
reset_phase_flags() {
    rm -f "$TEST_TMPDIR/cs_run_arg" "$TEST_TMPDIR/sb_run_arg" "$TEST_TMPDIR/bp_run_arg"
}

# AC 1: no sentinel → cold start, repo_dir passed through
reset_phase_flags
rm -f "$REPO/.continuity/sentinel" "$REPO/.continuity/clean_shutdown"
: > "$LOG_CAPTURE"
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_rc "1.2-AC1: cold start dispatch returns 0" 0 "$rc"
assert_file_exists "1.2-AC1: cs_run called" "$TEST_TMPDIR/cs_run_arg"
assert_eq "1.2-AC1: cs_run got repo_dir" "$REPO" "$(cat "$TEST_TMPDIR/cs_run_arg")"
assert_file_not_exists "1.2-AC1: sb_run not called" "$TEST_TMPDIR/sb_run_arg"
assert_file_not_exists "1.2-AC1: bp_run not called" "$TEST_TMPDIR/bp_run_arg"
if grep -qi "cold start" "$LOG_CAPTURE"; then
    assert_eq "1.2-AC6/7: cold start phase logged" "logged" "logged"
else
    assert_eq "1.2-AC6/7: cold start phase logged" "logged" "not-logged"
fi

# AC 2: sentinel, no marker → stale recovery
reset_phase_flags
touch "$REPO/.continuity/sentinel"
rm -f "$REPO/.continuity/clean_shutdown"
: > "$LOG_CAPTURE"
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_file_exists "1.2-AC2: sb_run called" "$TEST_TMPDIR/sb_run_arg"
assert_eq "1.2-AC2: sb_run got repo_dir" "$REPO" "$(cat "$TEST_TMPDIR/sb_run_arg")"
assert_file_not_exists "1.2-AC2: cs_run not called" "$TEST_TMPDIR/cs_run_arg"
if grep -qi "stale" "$LOG_CAPTURE"; then
    assert_eq "1.2-AC7: stale phase logged" "logged" "logged"
else
    assert_eq "1.2-AC7: stale phase logged" "logged" "not-logged"
fi

# AC 3-4: sentinel + marker → boot pull, marker consumed
reset_phase_flags
sb_mark_clean_shutdown "$REPO"
: > "$LOG_CAPTURE"
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_file_exists "1.2-AC3: bp_run called" "$TEST_TMPDIR/bp_run_arg"
assert_eq "1.2-AC3: bp_run got repo_dir" "$REPO" "$(cat "$TEST_TMPDIR/bp_run_arg")"
assert_file_not_exists "1.2-AC4: clean shutdown marker consumed" \
    "$REPO/.continuity/clean_shutdown"
if grep -qi "normal" "$LOG_CAPTURE"; then
    assert_eq "1.2-AC7: normal phase logged" "logged" "logged"
else
    assert_eq "1.2-AC7: normal phase logged" "logged" "not-logged"
fi

# AC 5/8: cs_run failure code propagates
rm -f "$REPO/.continuity/sentinel"
cs_run() { return 1; }
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_rc "1.2-AC8: cs_run rc=1 propagates" 1 "$rc"

# AC 10: bp_run failure code propagates
touch "$REPO/.continuity/sentinel"
sb_mark_clean_shutdown "$REPO"
bp_run() { return 2; }
rc=0; cd_boot_dispatch "$REPO" || rc=$?
assert_rc "1.2-AC10: bp_run rc=2 propagates" 2 "$rc"

# ═══ Poll cycle — deferred cold start retry (field defect) ══════════

CONTINUITY_REPO_DIR="$REPO"
pal_is_online() { return 0; }
cs_run() { touch "$TEST_TMPDIR/poll_cs_run"; }
rp_run() { touch "$TEST_TMPDIR/poll_rp_run"; }
se_has_unpushed_commits() { return 1; }
se_push() { :; }

# No sentinel + online → cold start retried, runtime poll NOT run
rm -f "$REPO/.continuity/sentinel" "$TEST_TMPDIR/poll_cs_run" "$TEST_TMPDIR/poll_rp_run"
cd_poll_once
assert_file_exists "poll retries deferred cold start when online" "$TEST_TMPDIR/poll_cs_run"
assert_file_not_exists "runtime poll skipped until sentinel exists" "$TEST_TMPDIR/poll_rp_run"

# No sentinel + offline → neither runs (no error spam into cs)
pal_is_online() { return 1; }
rm -f "$TEST_TMPDIR/poll_cs_run" "$TEST_TMPDIR/poll_rp_run"
cd_poll_once
assert_file_not_exists "no cold start retry while offline" "$TEST_TMPDIR/poll_cs_run"
assert_file_not_exists "no runtime poll while cold start pending" "$TEST_TMPDIR/poll_rp_run"

# Sentinel present → normal runtime poll
pal_is_online() { return 0; }
touch "$REPO/.continuity/sentinel"
rm -f "$TEST_TMPDIR/poll_cs_run" "$TEST_TMPDIR/poll_rp_run"
cd_poll_once
assert_file_exists "runtime poll runs with sentinel" "$TEST_TMPDIR/poll_rp_run"
assert_file_not_exists "no cold start once sentinel exists" "$TEST_TMPDIR/poll_cs_run"

# ═══ Poll cycle — in-session divergence reconcile (gap review) ══════

sb_run() { touch "$TEST_TMPDIR/poll_sb_run"; }

# Unpushed commits survive the poll while ONLINE → reconcile runs
se_has_unpushed_commits() { return 0; }
_CD_RECONCILE_COOLDOWN=0
rm -f "$TEST_TMPDIR/poll_sb_run"
cd_poll_once
assert_file_exists "reconcile: online+unpushed triggers sb_run" "$TEST_TMPDIR/poll_sb_run"

# Cooldown counts down — next tick must NOT reconcile again
rm -f "$TEST_TMPDIR/poll_sb_run"
cd_poll_once
assert_file_not_exists "reconcile: throttled by cooldown" "$TEST_TMPDIR/poll_sb_run"

# Cooldown expiry re-arms (tick it down to zero, then once more)
_CD_RECONCILE_COOLDOWN=1
rm -f "$TEST_TMPDIR/poll_sb_run"
cd_poll_once   # decrements 1 -> 0, no reconcile this tick
assert_file_not_exists "reconcile: last cooldown tick still throttled" "$TEST_TMPDIR/poll_sb_run"
cd_poll_once   # cooldown 0 -> reconcile again
assert_file_exists "reconcile: re-arms after cooldown expiry" "$TEST_TMPDIR/poll_sb_run"

# Offline → never reconcile (commits queue as designed)
pal_is_online() { return 1; }
_CD_RECONCILE_COOLDOWN=0
rm -f "$TEST_TMPDIR/poll_sb_run"
cd_poll_once
assert_file_not_exists "reconcile: offline never triggers" "$TEST_TMPDIR/poll_sb_run"

# Nothing unpushed → never reconcile
pal_is_online() { return 0; }
se_has_unpushed_commits() { return 1; }
rm -f "$TEST_TMPDIR/poll_sb_run"
cd_poll_once
assert_file_not_exists "reconcile: clean state never triggers" "$TEST_TMPDIR/poll_sb_run"

# ═══ Sprint 1.3 — Shutdown marker logic ═════════════════════════════

CONTINUITY_REPO_DIR="$REPO"
pal_is_online() { return 0; }

# Case A: nothing to push → marker written, PID removed, exit 0
rm -f "$REPO/.continuity/clean_shutdown"
se_has_unpushed_commits() { return 1; }
se_push() { touch "$TEST_TMPDIR/push_called"; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-A: shutdown exits 0" 0 "$rc"
assert_file_exists "1.3-A: clean marker written" "$REPO/.continuity/clean_shutdown"
assert_file_not_exists "1.3-A: PID removed" "$CONTINUITY_PID_FILE"
assert_file_not_exists "1.3-A: no push when nothing unpushed" "$TEST_TMPDIR/push_called"

# Case B: unpushed + online + push succeeds → pushed, marker written
rm -f "$REPO/.continuity/clean_shutdown" "$TEST_TMPDIR/pushed_flag"
se_has_unpushed_commits() { [ ! -f "$TEST_TMPDIR/pushed_flag" ]; }
se_push() { touch "$TEST_TMPDIR/pushed_flag"; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-B: shutdown exits 0" 0 "$rc"
assert_file_exists "1.3-B: final push ran" "$TEST_TMPDIR/pushed_flag"
assert_file_exists "1.3-B: clean marker written after push" "$REPO/.continuity/clean_shutdown"
assert_file_not_exists "1.3-B: PID removed" "$CONTINUITY_PID_FILE"

# Case C: unpushed + push fails → NO clean marker, PID still removed
rm -f "$REPO/.continuity/clean_shutdown"
se_has_unpushed_commits() { return 0; }
se_push() { return 1; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-C: shutdown still exits 0" 0 "$rc"
assert_file_not_exists "1.3-C: no clean marker after failed push" \
    "$REPO/.continuity/clean_shutdown"
assert_file_not_exists "1.3-C: PID removed even on failed push" "$CONTINUITY_PID_FILE"

# Shutdown final sweep: a save flushed after the last poll (save → quit
# → power off) must be committed by the shutdown handler
touch "$REPO/.continuity/sentinel"
rp_run() { touch "$TEST_TMPDIR/shutdown_sweep"; }
pal_is_online() { return 0; }
se_has_unpushed_commits() { return 1; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "shutdown with sweep exits 0" 0 "$rc"
assert_file_exists "shutdown runs a final poll sweep" "$TEST_TMPDIR/shutdown_sweep"

# ...but not before cold start ever completed (no sentinel → no sweep)
rm -f "$REPO/.continuity/sentinel" "$TEST_TMPDIR/shutdown_sweep"
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_file_not_exists "no sweep before first cold start" "$TEST_TMPDIR/shutdown_sweep"
touch "$REPO/.continuity/sentinel"

# Case D: unpushed + offline → NO clean marker
rm -f "$REPO/.continuity/clean_shutdown"
se_has_unpushed_commits() { return 0; }
pal_is_online() { return 1; }
se_push() { touch "$TEST_TMPDIR/offline_push"; return 1; }
cd_write_pid
rc=0; ( cd_shutdown ) 2>/dev/null || rc=$?
assert_rc "1.3-D: shutdown exits 0 offline" 0 "$rc"
assert_file_not_exists "1.3-D: no push attempted offline" "$TEST_TMPDIR/offline_push"
assert_file_not_exists "1.3-D: no clean marker offline with unpushed" \
    "$REPO/.continuity/clean_shutdown"

# ═══ Sprint 1.7 — vendored interpreter re-exec (fail-open) ══════════

# A fake PAK dir per case; a fake "busybox" whose behavior we script.
# The real exec is observed via a subshell: exec replaces the subshell
# with the fake binary, whose exit code (7) becomes the subshell's rc.
BB_PAK="$TEST_TMPDIR/bbpak"
mkdir -p "$BB_PAK/bin"
BB_SELF="$TEST_TMPDIR/fake_daemon.sh"
printf '#!/bin/sh\ntrue\n' > "$BB_SELF"

mk_fake_bb() {
    # $1: rc for self-test 1 (ash -c), $2: rc for self-test 2 (ash -n)
    cat > "$BB_PAK/bin/busybox" <<EOF
#!/bin/sh
case "\$1" in
    ash)
        case "\$2" in
            -c) exit $1 ;;
            -n) exit $2 ;;
            *)  printf '%s\n' "\$*" > "$TEST_TMPDIR/bb_exec_args"; exit 7 ;;
        esac ;;
esac
exit 0
EOF
    chmod +x "$BB_PAK/bin/busybox"
}

# 1.7-A: no vendored binary → fall through to device sh
rm -f "$BB_PAK/bin/busybox" "$TEST_TMPDIR/bb_exec_args"
unset CONTINUITY_BB_REEXEC
CONTINUITY_BB_STATUS=""
CONTINUITY_PAK_DIR="$BB_PAK" CONTINUITY_DAEMON_SELF="$BB_SELF" cd_reexec_busybox
assert_eq "1.7-A: no binary falls through" \
    "device sh (no vendored busybox bundled)" "$CONTINUITY_BB_STATUS"

# 1.7-B: kill switch wins even with a working binary
mk_fake_bb 0 0
CONTINUITY_BB_STATUS=""
CONTINUITY_VENDOR_SH=0 CONTINUITY_PAK_DIR="$BB_PAK" CONTINUITY_DAEMON_SELF="$BB_SELF" cd_reexec_busybox
assert_eq "1.7-B: kill switch disables re-exec" \
    "device sh (vendored interpreter disabled)" "$CONTINUITY_BB_STATUS"
assert_file_not_exists "1.7-B: no exec attempted" "$TEST_TMPDIR/bb_exec_args"

# 1.7-C: binary fails self-test (wrong arch / truncated) → fall through
mk_fake_bb 1 0
CONTINUITY_BB_STATUS=""
CONTINUITY_PAK_DIR="$BB_PAK" CONTINUITY_DAEMON_SELF="$BB_SELF" cd_reexec_busybox
assert_eq "1.7-C: failed self-test falls through" \
    "device sh (vendored busybox failed self-test)" "$CONTINUITY_BB_STATUS"

# 1.7-D: vendored ash cannot parse the daemon → fall through
mk_fake_bb 0 1
CONTINUITY_BB_STATUS=""
CONTINUITY_PAK_DIR="$BB_PAK" CONTINUITY_DAEMON_SELF="$BB_SELF" cd_reexec_busybox
assert_eq "1.7-D: failed parse probe falls through" \
    "device sh (vendored ash cannot parse daemon)" "$CONTINUITY_BB_STATUS"

# 1.7-E: healthy binary → exec taken with ash + script path
mk_fake_bb 0 0
rm -f "$TEST_TMPDIR/bb_exec_args"
rc=0
( CONTINUITY_PAK_DIR="$BB_PAK" CONTINUITY_DAEMON_SELF="$BB_SELF" \
    cd_reexec_busybox --flag ) || rc=$?
assert_rc "1.7-E: subshell replaced by exec (fake bb rc)" 7 "$rc"
assert_eq "1.7-E: exec argv is 'ash <self> <args>'" \
    "ash $BB_SELF --flag" "$(cat "$TEST_TMPDIR/bb_exec_args" 2>/dev/null)"

# 1.7-F: already re-execed → never loop, reports pinned
CONTINUITY_BB_STATUS=""
rm -f "$TEST_TMPDIR/bb_exec_args"
CONTINUITY_BB_REEXEC=1 CONTINUITY_PAK_DIR="$BB_PAK" CONTINUITY_DAEMON_SELF="$BB_SELF" cd_reexec_busybox
assert_eq "1.7-F: re-exec guard reports pinned" \
    "vendored busybox (pinned)" "$CONTINUITY_BB_STATUS"
assert_file_not_exists "1.7-F: no second exec" "$TEST_TMPDIR/bb_exec_args"
unset CONTINUITY_BB_REEXEC

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
