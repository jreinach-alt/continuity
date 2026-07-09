#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/nextui/preflight.sh (the doctor)
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

assert_not_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if ! grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s should not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

# --- Setup: healthy fake environment ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

PAK="$TEST_TMPDIR/pak"
SDROOT="$TEST_TMPDIR/sdcard"
mkdir -p "$PAK/scripts/core" "$PAK/libexec/git-core" "$PAK/share" "$SDROOT"
printf '0.1.0-test\n' > "$PAK/version.txt"
printf '#!/bin/sh\ntrue\n' > "$PAK/launch.sh"
printf '#!/bin/sh\ntrue\n' > "$PAK/scripts/core/pal.sh"
printf '#!/bin/sh\nexit 129\n' > "$PAK/libexec/git-core/git-remote-https"
chmod +x "$PAK/libexec/git-core/git-remote-https"
printf 'fake ca\n' > "$PAK/share/ca-bundle.crt"

# Matching checksums manifest (same format as build_pak.sh writes)
write_checksums() {
    : > "$PAK/checksums.txt"
    for f in libexec/git-core/git-remote-https share/ca-bundle.crt; do
        printf '%s %s %s\n' \
            "$(sha256sum "$PAK/$f" | cut -d' ' -f1)" \
            "$(wc -c < "$PAK/$f")" \
            "$f" >> "$PAK/checksums.txt"
    done
}
write_checksums

# git stub: FAKE_LSREMOTE_FAIL makes ls-remote fail like a TLS error
GIT_STUB="$TEST_TMPDIR/git"
cat > "$GIT_STUB" <<'EOF'
#!/bin/sh
case "$1" in
    --version) printf 'git version 2.47.1\n'; exit 0 ;;
    ls-remote)
        if [ -n "$FAKE_LSREMOTE_FAIL" ]; then
            printf 'fatal: unable to access: server certificate verification failed\n' >&2
            exit 128
        fi
        printf 'abc123def456abc123def456abc123def456abc1\tHEAD\n'
        exit 0 ;;
esac
exit 0
EOF
chmod +x "$GIT_STUB"

printf '{\n  "repo_url": "https://github.com/u/r",\n  "pat": "sekrit999",\n  "device_name": "brick"\n}\n' \
    > "$SDROOT/setup.json"

CONTINUITY_PAK_DIR="$PAK"
CONTINUITY_SD_ROOT="$SDROOT"
CONTINUITY_GIT_BIN="$GIT_STUB"
EUI_JS_DEV="$TEST_TMPDIR/js0"
: > "$EUI_JS_DEV"
pal_is_online() { return 0; }
PF_LSREMOTE_URL="https://github.com/u/r"

. "$PROJECT_ROOT/src/platforms/nextui/preflight.sh"

# --- Test 1: all green ---
R1="$TEST_TMPDIR/r1.txt"
rc=0; pf_run "$R1" || rc=$?
assert_eq "healthy environment passes" "0" "$rc"
assert_contains "clock ok" "$R1" "ok   clock"
assert_contains "git binary version captured" "$R1" "git version 2.47.1"
assert_contains "https helper executes" "$R1" "https-helper   executes"
assert_contains "binaries verified" "$R1" "all shipped binaries intact"
assert_contains "ca bundle found" "$R1" "ok   ca-bundle"
assert_contains "live TLS probe ran" "$R1" "unauthenticated ls-remote succeeded"
assert_contains "verdict is PASSED" "$R1" "=== preflight PASSED ==="

# --- Test 2: PAT is never written to the report ---
assert_not_contains "PAT value never in report" "$R1" "sekrit999"
assert_contains "PAT presence masked with length" "$R1" "pat=present(9 chars)"

# --- Test 3: wrong clock is fatal with guidance ---
rc=0; PF_YEAR=1980 pf_run "$TEST_TMPDIR/r3.txt" || rc=$?
assert_eq "1980 clock fails" "1" "$rc"
case "$_pf_first_fail" in
    clock:*) assert_eq "first fail is the clock" "clock" "clock" ;;
    *)       assert_eq "first fail is the clock" "clock" "$_pf_first_fail" ;;
esac

# --- Test 4: offline skips the TLS probe and is fatal ---
pal_is_online() { return 1; }
R4="$TEST_TMPDIR/r4.txt"
rc=0; pf_run "$R4" || rc=$?
assert_eq "offline fails" "1" "$rc"
assert_contains "TLS probe skipped offline" "$R4" "skipped (offline)"
pal_is_online() { return 0; }

# --- Test 5: TLS probe failure is fatal and captured verbatim ---
R5="$TEST_TMPDIR/r5.txt"
rc=0; FAKE_LSREMOTE_FAIL=1 pf_run "$R5" || rc=$?
assert_eq "TLS failure fails preflight" "1" "$rc"
assert_contains "TLS error text captured" "$R5" "certificate verification failed"

# --- Test 6: missing https helper is fatal ---
mv "$PAK/libexec/git-core/git-remote-https" "$TEST_TMPDIR/helper.bak"
rc=0; pf_run "$TEST_TMPDIR/r6.txt" || rc=$?
assert_eq "missing helper fails" "1" "$rc"
assert_contains "helper failure named" "$TEST_TMPDIR/r6.txt" "git-remote-https missing"
mv "$TEST_TMPDIR/helper.bak" "$PAK/libexec/git-core/git-remote-https"

# --- Test 7: CRLF module is fatal ---
printf '#!/bin/sh\r\ntrue\r\n' > "$PAK/scripts/core/pal.sh"
rc=0; pf_run "$TEST_TMPDIR/r7.txt" || rc=$?
assert_eq "CRLF module fails" "1" "$rc"
assert_contains "CRLF file named" "$TEST_TMPDIR/r7.txt" "CRLF in:"
printf '#!/bin/sh\ntrue\n' > "$PAK/scripts/core/pal.sh"

# --- Test 8: missing joystick is only a warning ---
rm -f "$EUI_JS_DEV"
R8="$TEST_TMPDIR/r8.txt"
rc=0; pf_run "$R8" || rc=$?
assert_eq "missing js0 does not fail preflight" "0" "$rc"
assert_contains "js0 warning recorded" "$R8" "warn buttons"
: > "$EUI_JS_DEV"

# --- Test 9a: helper present but not executable by the kernel is fatal ---
printf 'not an executable\n' > "$PAK/libexec/git-core/git-remote-https"
chmod +x "$PAK/libexec/git-core/git-remote-https"
write_checksums
rc=0; pf_run "$TEST_TMPDIR/r9a.txt" || rc=$?
assert_eq "non-executing helper fails" "1" "$rc"
assert_contains "exec failure named" "$TEST_TMPDIR/r9a.txt" "present but will not execute"
printf '#!/bin/sh\nexit 129\n' > "$PAK/libexec/git-core/git-remote-https"
chmod +x "$PAK/libexec/git-core/git-remote-https"
write_checksums

# --- Test 9b: truncated binary caught by checksum verification ---
printf 'truncated' > "$PAK/share/ca-bundle.crt"   # size differs from manifest
rc=0; pf_run "$TEST_TMPDIR/r9b.txt" || rc=$?
assert_eq "corrupt copy fails" "1" "$rc"
assert_contains "corruption named with re-copy guidance" "$TEST_TMPDIR/r9b.txt" \
    "corrupt on card: share/ca-bundle.crt"
printf 'fake ca\n' > "$PAK/share/ca-bundle.crt"
write_checksums

# --- Test 9: unparseable setup.json is fatal ---
printf '{ "garbage": true }\n' > "$SDROOT/setup.json"
rc=0; pf_run "$TEST_TMPDIR/r9.txt" || rc=$?
assert_eq "bad setup.json fails" "1" "$rc"
assert_contains "bad setup.json named" "$TEST_TMPDIR/r9.txt" "unparseable"

# --- Test 10: mapping check parses the real map and translates a probe ---
printf '{\n  "repo_url": "https://github.com/u/r",\n  "pat": "sekrit999",\n  "device_name": "brick"\n}\n' \
    > "$SDROOT/setup.json"    # restore after test 9's garbage
CONTINUITY_SAVES_ROOT="$TEST_TMPDIR/Saves"
cp "$PROJECT_ROOT/config/platform_maps/nextui.json" "$TEST_TMPDIR/platform_map.json"
pal_get_platform_map() { printf '%s\n' "$TEST_TMPDIR/platform_map.json"; }
. "$PROJECT_ROOT/src/core/path_mapper.sh"
R10="$TEST_TMPDIR/r10.txt"
rc=0; pf_run "$R10" || rc=$?
assert_eq "healthy run with mapper stays green" "0" "$rc"
assert_contains "mapping check passes with real map" "$R10" "watched dirs; SFC probe translates"

# --- Test 11: vendored busybox states (all fail-open, never fatal) ---
# 11a: absent → info (Test 1's green run already had no bin/busybox)
assert_contains "absent busybox is informational" "$R1" "not bundled"

# 11b: bundled + healthy → ok, predicts daemon pinning
mkdir -p "$PAK/bin"
printf '#!/bin/sh\nexit 0\n' > "$PAK/bin/busybox"
chmod +x "$PAK/bin/busybox"
R11="$TEST_TMPDIR/r11.txt"
rc=0; pf_run "$R11" || rc=$?
assert_eq "healthy busybox stays green" "0" "$rc"
assert_contains "healthy busybox predicts pinning" "$R11" "daemon will pin to it"

# 11c: bundled but broken → warn only, run stays green
printf '#!/bin/sh\nexit 1\n' > "$PAK/bin/busybox"
chmod +x "$PAK/bin/busybox"
R11c="$TEST_TMPDIR/r11c.txt"
rc=0; pf_run "$R11c" || rc=$?
assert_eq "broken busybox never fails preflight" "0" "$rc"
assert_contains "broken busybox warns with fallback" "$R11c" "falls back to device sh"

# 11d: kill switch → info
R11d="$TEST_TMPDIR/r11d.txt"
rc=0; CONTINUITY_VENDOR_SH=0 pf_run "$R11d" || rc=$?
assert_eq "kill switch stays green" "0" "$rc"
assert_contains "kill switch reported" "$R11d" "disabled (CONTINUITY_VENDOR_SH=0)"
rm -rf "$PAK/bin"

# --- Test 12: credentials embedded in repo_url are warned and masked ---
printf '{\n  "repo_url": "https://x:leaky-token@github.com/u/r",\n  "pat": "sekrit999",\n  "device_name": "brick"\n}\n' \
    > "$SDROOT/setup.json"
R12="$TEST_TMPDIR/r12.txt"
rc=0; pf_run "$R12" || rc=$?
assert_contains "embedded-credential URL warns" "$R12" \
    "repo_url embeds credentials"
assert_not_contains "embedded token never in report" "$R12" "leaky-token"
printf '{\n  "repo_url": "https://github.com/u/r",\n  "pat": "sekrit999",\n  "device_name": "brick"\n}\n' \
    > "$SDROOT/setup.json"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
