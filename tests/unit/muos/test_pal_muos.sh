#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
set -e

# Unit tests for src/platforms/muos/pal_muos.sh — the Version Support
# Policy is the point (acceptance I9): every muOS path resolves by
# existence probe across layout-variant fixtures, never by version
# string; the resolution is logged; pre-set environment always wins.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PAL="$REPO_ROOT/src/platforms/muos/pal_muos.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

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
    local desc="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -e "$needle"; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  [%s] does not contain [%s]\n' "$desc" "$haystack" "$needle" >&2
        failed=$((failed + 1))
    fi
}

# probe <env assignments...> — source the PAL in a clean subshell with
# the given fixture env and print the resolved roots for the parent to
# assert on. env(1) keeps the parent shell unpolluted.
probe() {
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" "$@" busybox ash -c '
        . "$0"
        printf "saves=%s\n"  "$CONTINUITY_SAVES_ROOT"
        printf "states=%s\n" "$CONTINUITY_STATES_ROOT"
        printf "roms=%s\n"   "$CONTINUITY_ROMS_ROOT"
        printf "repo=%s\n"   "$CONTINUITY_REPO_DIR"
        printf "map=%s\n"    "$(pal_get_platform_map)"
    ' "$PAL"
}

# ── Layout A: modern muOS (storage indirection + unionfs present) ────

A="$TEST_TMPDIR/layoutA"
mkdir -p "$A/sd/MUOS/save/file" "$A/sd/MUOS/save/state" "$A/sd/ROMS" \
         "$A/run/storage/save/file" "$A/run/storage/save/state" "$A/union/ROMS"
out=$(probe CONTINUITY_SD_ROOT="$A/sd" CONTINUITY_MUOS_RUNROOT="$A/run" \
            CONTINUITY_MUOS_UNION="$A/union")
assert_contains "A: saves via storage indirection" "$out" "saves=$A/run/storage/save/file"
assert_contains "A: states via storage indirection" "$out" "states=$A/run/storage/save/state"
assert_contains "A: roms via unionfs" "$out" "roms=$A/union/ROMS"

# ── Layout B: older/direct layout (no indirection, no union) ─────────

B="$TEST_TMPDIR/layoutB"
mkdir -p "$B/sd/MUOS/save/file" "$B/sd/MUOS/save/state" "$B/sd/ROMS"
out=$(probe CONTINUITY_SD_ROOT="$B/sd" CONTINUITY_MUOS_RUNROOT="$B/absent" \
            CONTINUITY_MUOS_UNION="$B/absent")
assert_contains "B: saves fall back to direct SD path" "$out" "saves=$B/sd/MUOS/save/file"
assert_contains "B: states fall back to direct SD path" "$out" "states=$B/sd/MUOS/save/state"
assert_contains "B: roms fall back to SD ROMS" "$out" "roms=$B/sd/ROMS"

# ── Fresh device: nothing exists yet — paths still well-formed ───────

C="$TEST_TMPDIR/layoutC"
mkdir -p "$C/sd"
out=$(probe CONTINUITY_SD_ROOT="$C/sd" CONTINUITY_MUOS_RUNROOT="$C/absent" \
            CONTINUITY_MUOS_UNION="$C/absent")
assert_contains "C: fresh device saves path well-formed" "$out" "saves=$C/sd/MUOS/save/file"
assert_contains "C: repo dir under .continuity" "$out" "repo=$C/sd/.continuity/repo"

# ── Pre-set environment always wins ─────────────────────────────────

out=$(probe CONTINUITY_SD_ROOT="$A/sd" CONTINUITY_MUOS_RUNROOT="$A/run" \
            CONTINUITY_MUOS_UNION="$A/union" CONTINUITY_SAVES_ROOT=/custom/saves)
assert_contains "pre-set saves root wins over probe" "$out" "saves=/custom/saves"

# ── Platform map location follows the app dir ───────────────────────

out=$(probe CONTINUITY_SD_ROOT="$B/sd" CONTINUITY_APP_DIR="$B/app")
assert_contains "map under app dir" "$out" "map=$B/app/config/platform_maps/muos.json"

# ── pal_validate + pal_init against the muOS PAL ─────────────────────

APPD="$TEST_TMPDIR/app"
mkdir -p "$APPD/bin" "$B/sd/.continuity/repo/.continuity"
printf '#!/bin/sh\nexit 0\n' > "$APPD/bin/git"
chmod +x "$APPD/bin/git"
printf 'my-rg40xx\n' > "$B/sd/.continuity/repo/.continuity/device_name"

run_init() {
    env -i PATH="$PATH" HOME="$TEST_TMPDIR" "$@" busybox ash -c '
        . "$0"
        . "$1"
        # Daemon order (cd_main init block): pal_init THEN pal_validate —
        # init reads the device name that validate requires.
        if pal_init 2>&1 && pal_validate 2>&1; then
            printf "INIT-OK device=%s\n" "$CONTINUITY_DEVICE_NAME"
        else
            printf "INIT-FAIL\n"
        fi
    ' "$PAL" "$REPO_ROOT/src/core/pal.sh"
}

out=$(run_init CONTINUITY_SD_ROOT="$B/sd" CONTINUITY_MUOS_RUNROOT="$B/absent" \
               CONTINUITY_MUOS_UNION="$B/absent" CONTINUITY_APP_DIR="$APPD" \
               CONTINUITY_GIT_BIN="$APPD/bin/git")
assert_contains "validate+init pass when enrolled" "$out" "INIT-OK device=my-rg40xx"
assert_contains "init logs path resolution" "$out" "muOS path resolution: saves="

# init fails without device name
out=$(run_init CONTINUITY_SD_ROOT="$C/sd" CONTINUITY_MUOS_RUNROOT="$C/absent" \
               CONTINUITY_MUOS_UNION="$C/absent" CONTINUITY_APP_DIR="$APPD" \
               CONTINUITY_GIT_BIN="$APPD/bin/git")
assert_contains "init fails unenrolled" "$out" "INIT-FAIL"

# init fails with missing git binary
out=$(run_init CONTINUITY_SD_ROOT="$B/sd" CONTINUITY_MUOS_RUNROOT="$B/absent" \
               CONTINUITY_MUOS_UNION="$B/absent" CONTINUITY_APP_DIR="$TEST_TMPDIR/noapp" \
               CONTINUITY_GIT_BIN="$TEST_TMPDIR/noapp/bin/git")
assert_contains "init fails without git binary" "$out" "INIT-FAIL"

# ── git env wiring engages when the app dir carries the real layout ──

mkdir -p "$APPD/libexec/git-core" "$APPD/share/templates"
printf 'ca' > "$APPD/share/ca-bundle.crt"
out=$(env -i PATH="$PATH" HOME="$TEST_TMPDIR" \
        CONTINUITY_SD_ROOT="$B/sd" CONTINUITY_APP_DIR="$APPD" busybox ash -c '
    . "$0"
    printf "exec=%s cainfo=%s tmpl=%s\n" "$GIT_EXEC_PATH" "$GIT_SSL_CAINFO" "$GIT_TEMPLATE_DIR"
    case ":$PATH:" in *":$CONTINUITY_APP_DIR/bin:"*) printf "pathbelt=yes\n" ;; *) printf "pathbelt=no\n" ;; esac
' "$PAL")
assert_contains "GIT_EXEC_PATH wired" "$out" "exec=$APPD/libexec/git-core"
assert_contains "GIT_SSL_CAINFO wired" "$out" "cainfo=$APPD/share/ca-bundle.crt"
assert_contains "GIT_TEMPLATE_DIR wired" "$out" "tmpl=$APPD/share/templates"
assert_contains "PATH belt engaged" "$out" "pathbelt=yes"

printf '\ntest_pal_muos: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
