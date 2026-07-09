#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for scripts/build_muos_app.sh — the muOS app packaging:
# card-mirroring layout, verified-binary sourcing, checksums manifest,
# executable bits, CRLF guard, zip creation. Runs against a small
# fixture PAK so the test is fast and never mutates build/.
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

assert_file_exists() {
    local desc="$1" filepath="$2"
    if [ -e "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  file not found: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

assert_executable() {
    local desc="$1" filepath="$2"
    if [ -x "$filepath" ]; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  not executable: %s\n' "$desc" "$filepath" >&2
        failed=$((failed + 1))
    fi
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Fixture PAK: the validated-binary source, tiny stand-ins
PAK="$TEST_TMPDIR/pak"
mkdir -p "$PAK/bin" "$PAK/libexec/git-core" "$PAK/share"
printf 'GITBIN-BYTES' > "$PAK/bin/git"
printf 'BUSYBOX-BYTES' > "$PAK/bin/busybox"
printf 'GITBIN-BYTES' > "$PAK/libexec/git-core/git"
printf 'HTTPS-HELPER' > "$PAK/libexec/git-core/git-remote-https"
printf 'HTTPS-HELPER' > "$PAK/libexec/git-core/git-remote-http"
printf 'CA-BUNDLE' > "$PAK/share/ca-bundle.crt"

OUT="$TEST_TMPDIR/out"
ZIPD="$TEST_TMPDIR/zips"
mkdir -p "$ZIPD"

rc=0
MUOS_APP_SRC_PAK="$PAK" MUOS_APP_OUT_DIR="$OUT" MUOS_APP_ZIP_DIR="$ZIPD" \
    sh "$PROJECT_ROOT/scripts/build_muos_app.sh" > "$TEST_TMPDIR/build.log" 2>&1 || rc=$?
assert_eq "build succeeds" "0" "$rc"

APP="$OUT/.continuity/app"

# ── Card-mirroring layout ────────────────────────────────────────────

assert_file_exists "task entry" "$OUT/MUOS/task/Continuity.sh"
assert_file_exists "recon task entry" "$OUT/MUOS/task/Continuity Recon.sh"
assert_file_exists "boot hook" "$OUT/MUOS/init/continuity.sh"
assert_executable "boot hook +x" "$OUT/MUOS/init/continuity.sh"
assert_file_exists "daemon" "$APP/scripts/continuity_daemon.sh"
assert_file_exists "pal" "$APP/scripts/pal_muos.sh"
assert_file_exists "enroll" "$APP/scripts/enroll_sd_card.sh"
assert_file_exists "preflight" "$APP/scripts/preflight.sh"
assert_file_exists "core sync engine" "$APP/scripts/core/sync_engine.sh"
assert_file_exists "core path mapper" "$APP/scripts/core/path_mapper.sh"
assert_file_exists "platform map" "$APP/config/platform_maps/muos.json"
assert_file_exists "taxonomy" "$APP/config/system_taxonomy.json"
assert_file_exists "git binary" "$APP/bin/git"
assert_file_exists "busybox" "$APP/bin/busybox"
assert_file_exists "https helper" "$APP/libexec/git-core/git-remote-https"
assert_file_exists "http helper copy" "$APP/libexec/git-core/git-remote-http"
assert_file_exists "git in exec path" "$APP/libexec/git-core/git"
assert_file_exists "ca bundle" "$APP/share/ca-bundle.crt"
assert_file_exists "templates keep" "$APP/share/templates/.keep"

# ── Version + checksums ──────────────────────────────────────────────

version=$(cat "$APP/version.txt")
case "$version" in
    0.1.0-muos-*) passed=$((passed + 1)) ;;
    *) printf 'FAIL: version stamp shape, got [%s]\n' "$version" >&2; failed=$((failed + 1)) ;;
esac

# every manifest line verifies (same check preflight runs on-device)
manifest_bad=0
while IFS=' ' read -r sum size path; do
    [ -n "$path" ] || continue
    actual_sum=$(sha256sum "$APP/$path" | cut -d' ' -f1)
    actual_size=$(wc -c < "$APP/$path")
    if [ "$actual_sum" != "$sum" ] || [ "$actual_size" -ne "$size" ]; then
        manifest_bad=1
    fi
done < "$APP/checksums.txt"
assert_eq "checksums manifest verifies" "0" "$manifest_bad"
assert_eq "manifest covers all six binaries" "6" "$(grep -c . "$APP/checksums.txt")"

# ── Executable bits ──────────────────────────────────────────────────

assert_executable "task entry +x" "$OUT/MUOS/task/Continuity.sh"
assert_executable "git +x" "$APP/bin/git"
assert_executable "daemon +x" "$APP/scripts/continuity_daemon.sh"

# ── Zip deliverable ──────────────────────────────────────────────────

zipfile=$(find "$ZIPD" -name "Continuity-muos-*.zip" | head -1)
assert_file_exists "zip created" "$zipfile"
if command -v unzip >/dev/null 2>&1; then
    n=$(unzip -l "$zipfile" 2>/dev/null | grep -c "MUOS/task/Continuity.sh") || n=0
    assert_eq "zip contains task entry at card-relative path" "1" "$n"
fi

# ── Missing binaries fail loudly ─────────────────────────────────────

rm "$PAK/bin/git"
rc=0
MUOS_APP_SRC_PAK="$PAK" MUOS_APP_OUT_DIR="$TEST_TMPDIR/out2" \
    MUOS_APP_ZIP_DIR="$ZIPD" \
    sh "$PROJECT_ROOT/scripts/build_muos_app.sh" > "$TEST_TMPDIR/build2.log" 2>&1 || rc=$?
assert_eq "missing git binary fails the build" "1" "$rc"
grep -q "missing from" "$TEST_TMPDIR/build2.log" && passed=$((passed + 1)) || {
    printf 'FAIL: missing-binary error not named\n' >&2; failed=$((failed + 1)); }

printf '\ntest_build_muos_app: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
