#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/muos/update.sh (channel-manifest OTA for
# the muOS app artifact) driven through the REAL scripts/publish_channel.sh
# against a fixture repo — the manifest writer and the on-device reader
# are tested as one contract. One pinned commit carries BOTH a
# build/Continuity.pak (which the publisher verifies) and a
# build/Continuity-muos.app (which this updater fetches): a publish
# delivers to the whole fleet.
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

assert_contains_str() {
    local desc haystack needle
    desc="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  [%s] does not contain [%s]\n' "$desc" "$haystack" "$needle" >&2
           failed=$((failed + 1)) ;;
    esac
}

# --- Setup ---
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# Fixture "project repo": main, a tracked PAK (for the publisher), a
# tracked muOS app (for the updater), and a release manifest.
UPSTREAM="$TEST_TMPDIR/upstream"
mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email t@t
git -C "$UPSTREAM" config user.name t
git -C "$UPSTREAM" config uploadpack.allowFilter true
# Devices fetch manifest-pinned SHAs directly (GitHub serves reachable
# SHAs; file:// remotes need it enabled).
git -C "$UPSTREAM" config uploadpack.allowAnySHA1InWant true

# publish_muos <pak_version> <muos_version> <marker> [gitbytes]
#   commits a PAK tree (publisher-verifiable) AND a muOS app tree, both
#   under one commit; prints its sha. gitbytes controls the muOS git
#   binary size so the size-diff rewrite probe can be exercised.
publish_muos() {
    local pv mv m gb pak app root
    pv="$1"; mv="$2"; m="$3"; gb="${4:-MUOSBINv1}"

    pak="$UPSTREAM/build/Continuity.pak"
    mkdir -p "$pak/bin"
    printf 'PAKBIN' > "$pak/bin/git"
    printf '%s\n' "$pv" > "$pak/version.txt"
    printf '%s %s %s\n' "$(sha256sum "$pak/bin/git" | cut -d' ' -f1)" \
        "$(wc -c < "$pak/bin/git")" "bin/git" > "$pak/checksums.txt"

    root="$UPSTREAM/build/Continuity-muos.app"
    app="$root/.continuity/app"
    mkdir -p "$app/scripts/core" "$app/config/platform_maps" "$app/bin" \
             "$root/MUOS/task" "$root/MUOS/init"
    printf '#!/bin/sh\n# daemon marker: %s\ntrue\n' "$m" > "$app/scripts/continuity_daemon.sh"
    printf '#!/bin/sh\n# core marker: %s\ntrue\n' "$m" > "$app/scripts/core/pal.sh"
    printf '#!/bin/sh\n# update marker: %s\ntrue\n' "$m" > "$app/scripts/update.sh"
    printf '{}\n' > "$app/config/platform_maps/muos.json"
    printf '%s' "$gb" > "$app/bin/git"
    printf '%s\n' "$mv" > "$app/version.txt"
    printf 'nightly\n' > "$app/ota_channel.txt"
    printf '%s %s %s\n' "$(sha256sum "$app/bin/git" | cut -d' ' -f1)" \
        "$(wc -c < "$app/bin/git")" "bin/git" > "$app/checksums.txt"
    printf '#!/bin/sh\n# task marker: %s\ntrue\n' "$m" > "$root/MUOS/task/Continuity.sh"
    printf '#!/bin/sh\n# update-task marker: %s\ntrue\n' "$m" > "$root/MUOS/task/Continuity Update.sh"
    printf '#!/bin/sh\n# init marker: %s\ntrue\n' "$m" > "$root/MUOS/init/continuity.sh"

    git -C "$UPSTREAM" add -A
    git -C "$UPSTREAM" commit -qm "build $mv"
    git -C "$UPSTREAM" rev-parse HEAD
}

publish_channel() { # <channel> <sha> [--force] — the REAL publisher
    CONTINUITY_PUBLISH_ROOT="$UPSTREAM" \
        sh "$PROJECT_ROOT/scripts/publish_channel.sh" "$@"
}

# Seed: a v2 build published to both channels
mkdir -p "$UPSTREAM/release"
printf '{\n  "_schema_version": "1.0",\n  "channels": {\n  }\n}\n' > "$UPSTREAM/release/channels.json"
git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" commit -qm "seed manifest"
V2_SHA=$(publish_muos "0.1.0-pak-v2" "0.1.0-muos-v2" "second-build")
publish_channel nightly "$V2_SHA" >/dev/null
publish_channel stable  "$V2_SHA" >/dev/null

# Device-side fake live install: card root with app dir + MUOS entries.
SD="$TEST_TMPDIR/card"
APP="$SD/.continuity/app"
HOME_DIR="$SD/.continuity"
mkdir -p "$APP/scripts/core" "$APP/bin" "$SD/MUOS/task" "$SD/MUOS/init"
printf '#!/bin/sh\n# daemon marker: first-build\ntrue\n' > "$APP/scripts/continuity_daemon.sh"
printf '0.1.0-muos-v1\n' > "$APP/version.txt"
printf 'nightly\n' > "$APP/ota_channel.txt"
printf 'MUOSBINv1' > "$APP/bin/git"
printf '#!/bin/sh\n# task marker: first-build\ntrue\n' > "$SD/MUOS/task/Continuity.sh"
printf '#!/bin/sh\n# init marker: first-build\ntrue\n' > "$SD/MUOS/init/continuity.sh"

CONTINUITY_SD_ROOT="$SD"
CONTINUITY_APP_DIR="$APP"
CONTINUITY_HOME="$HOME_DIR"
CONTINUITY_OTA_URL="file://$UPSTREAM"
CONTINUITY_GIT_BIN="git"

. "$PROJECT_ROOT/src/platforms/muos/update.sh"

# --- Test 1: manifest-pinned update; unpublished main is invisible (A3) ---
# Land an UNPUBLISHED build on main after the publish — the device must
# still be offered the PINNED commit, not the branch head.
UNPUB_SHA=$(publish_muos "0.1.0-pak-unpub" "0.1.0-muos-unpub" "never-see-this")
rc=0; info=$(ota_check) || rc=$?
assert_eq "update detected via manifest" "0" "$rc"
assert_contains_str "pinned muOS version reported (not the PAK version)" "$info" "0.1.0-muos-v2"
commit="${info##* }"
assert_eq "offered commit is the PINNED sha, not main head" "$V2_SHA" "$commit"
assert_eq "unpublished head is NOT offered" "1" "$([ "$commit" != "$UNPUB_SHA" ] && echo 1 || echo 0)"
assert_eq "device channel identity seeded from build" "nightly" "$(cat "$HOME_DIR/ota_channel")"

# --- Test 2: apply updates app scripts, version, MUOS entries, marker (A2) ---
rc=0; ota_apply "$commit" || rc=$?
assert_eq "apply succeeds" "0" "$rc"
assert_contains_str "daemon script updated" "$(cat "$APP/scripts/continuity_daemon.sh")" "second-build"
assert_contains_str "core module updated" "$(cat "$APP/scripts/core/pal.sh")" "second-build"
assert_contains_str "update.sh staged into app" "$(cat "$APP/scripts/update.sh")" "second-build"
assert_eq "version updated" "0.1.0-muos-v2" "$(cat "$APP/version.txt")"
assert_contains_str "task entry updated at card root" "$(cat "$SD/MUOS/task/Continuity.sh")" "second-build"
assert_contains_str "update task fanned out (spaces in name)" "$(cat "$SD/MUOS/task/Continuity Update.sh")" "second-build"
assert_contains_str "boot hook updated at card root" "$(cat "$SD/MUOS/init/continuity.sh")" "second-build"
assert_eq "commit recorded in .ota_commit" "$commit" "$(cat "$HOME_DIR/.ota_commit")"

# --- Test 3: idempotent re-run at same pin (A2) ---
rc=0; ota_check >/dev/null || rc=$?
assert_eq "no update when current (idempotent)" "1" "$rc"
rc=0; ota_run || rc=$?
assert_eq "ota_run is a no-op at the same pin" "1" "$rc"

# --- Test 4: channel seeding never overwritten by a foreign-channel install (A4) ---
printf 'stable\n' > "$APP/ota_channel.txt"   # what a stable-seeded build would carry
assert_eq "device identity survives foreign-channel install" \
    "nightly" "$(ota_channel)"
printf 'nightly\n' > "$APP/ota_channel.txt"

# --- Test 5: kill switch disables everything with a named message (A5) ---
: > "$HOME_DIR/update.log"
rc=0; CONTINUITY_OTA=0 ota_check >/dev/null || rc=$?
assert_eq "kill switch: ota_check holds" "1" "$rc"
assert_contains_str "kill switch names itself in the log" \
    "$(cat "$HOME_DIR/update.log")" "OTA disabled via CONTINUITY_OTA=0"
rc=0; CONTINUITY_OTA=0 ota_run || rc=$?
assert_eq "kill switch: ota_run holds" "1" "$rc"
rc=0; CONTINUITY_OTA=0 ota_apply "$commit" || rc=$?
assert_eq "kill switch: ota_apply refuses" "1" "$rc"

# --- Test 6: nightly publish v3 followed via ota_run; size-diff binary rewrite ---
before_git=$(stat -c %Y "$APP/bin/git" 2>/dev/null || date +%s)
sleep 1
V3_SHA=$(publish_muos "0.1.0-pak-v3" "0.1.0-muos-v3" "third-build")   # default 8-byte git, same size
publish_channel nightly "$V3_SHA" >/dev/null
rc=0; ota_run || rc=$?
assert_eq "ota_run applies nightly publish" "0" "$rc"
assert_eq "version now v3" "0.1.0-muos-v3" "$(cat "$APP/version.txt")"
after_git=$(stat -c %Y "$APP/bin/git" 2>/dev/null || printf '%s' "$before_git")
assert_eq "same-size binary untouched (size probe)" "$before_git" "$after_git"

# Now a size-DIFFERING binary IS rewritten
V4_SHA=$(publish_muos "0.1.0-pak-v4" "0.1.0-muos-v4" "fourth-build" "MUOSBIN-v4-LONGER")
publish_channel nightly "$V4_SHA" >/dev/null
rc=0; ota_run || rc=$?
assert_eq "v4 applied" "0.1.0-muos-v4" "$(cat "$APP/version.txt")"
assert_eq "size-differing binary rewritten" "MUOSBIN-v4-LONGER" "$(cat "$APP/bin/git")"

# --- Test 7: channel switch is authoritative — stable offers the rollback ---
ota_set_channel stable
rc=0; info=$(ota_check) || rc=$?
assert_eq "stable channel offers its pinned build" "0" "$rc"
assert_contains_str "stable still pins v2" "$info" "0.1.0-muos-v2"
ota_set_channel nightly

# --- Test 8: unknown channel holds safely (no legacy branch fallback) ---
git -C "$UPSTREAM" branch some-branch "$V3_SHA"   # a real branch exists...
ota_set_channel some-branch                        # ...but muOS has NO branch fallback
: > "$HOME_DIR/update.log"
rc=0; ota_check >/dev/null 2>&1 || rc=$?
assert_eq "unknown channel holds (rc 1) — no branch fallback" "1" "$rc"
assert_contains_str "hold reason: channel not in manifest" \
    "$(cat "$HOME_DIR/update.log")" "not in manifest"
assert_eq "held device keeps its version" "0.1.0-muos-v4" "$(cat "$APP/version.txt")"
ota_set_channel nightly

# --- Test 9: verify refusals — CRLF and checksum mismatch ---
CORRUPT="$TEST_TMPDIR/corrupt-tree"
mkdir -p "$CORRUPT/.continuity/app/scripts" "$CORRUPT/MUOS"
printf '#!/bin/sh\r\ntrue\r\n' > "$CORRUPT/.continuity/app/scripts/continuity_daemon.sh"
rc=0; ota_verify_tree "$CORRUPT" || rc=$?
assert_eq "CRLF tree refused" "1" "$rc"

BADSUM="$TEST_TMPDIR/badsum-tree"
mkdir -p "$BADSUM/.continuity/app/scripts" "$BADSUM/.continuity/app/bin" "$BADSUM/MUOS"
printf '#!/bin/sh\ntrue\n' > "$BADSUM/.continuity/app/scripts/continuity_daemon.sh"
printf 'short' > "$BADSUM/.continuity/app/bin/git"
printf 'deadbeef 999 bin/git\n' > "$BADSUM/.continuity/app/checksums.txt"
rc=0; ota_verify_tree "$BADSUM" || rc=$?
assert_eq "size/checksum-mismatched tree refused" "1" "$rc"

# --- Test 10: staged apply leaves NO half-written tree on verify failure (A6) ---
# A fresh device; materialize the pinned tree via ota_check, then corrupt
# the FETCHED clone so ota_apply's pre-copy verify fails — the live tree
# must be byte-for-byte untouched.
SD2="$TEST_TMPDIR/card2"
APP2="$SD2/.continuity/app"
HOME2="$SD2/.continuity"
mkdir -p "$APP2/scripts/core" "$APP2/bin" "$SD2/MUOS/task" "$SD2/MUOS/init"
printf '#!/bin/sh\n# daemon marker: PRISTINE\ntrue\n' > "$APP2/scripts/continuity_daemon.sh"
printf '0.1.0-muos-PRISTINE\n' > "$APP2/version.txt"
printf 'nightly\n' > "$APP2/ota_channel.txt"
printf 'MUOSBINv1' > "$APP2/bin/git"
printf '#!/bin/sh\n# task marker: PRISTINE\ntrue\n' > "$SD2/MUOS/task/Continuity.sh"

OTA_SD_ROOT="$SD2"; OTA_APP_DIR="$APP2"; OTA_HOME="$HOME2"
OTA_REPO="$OTA_HOME/ota-repo"; OTA_LOG="$OTA_HOME/update.log"
OTA_URL="file://$UPSTREAM"
mkdir -p "$HOME2"

rc=0; info=$(ota_check) || rc=$?
assert_eq "fresh device sees the pinned update" "0" "$rc"
half_commit="${info##* }"
# Corrupt the fetched tree (CRLF into a shipped script) so verify fails.
printf '#!/bin/sh\r\nbroken\r\n' \
    > "$OTA_REPO/build/Continuity-muos.app/.continuity/app/scripts/continuity_daemon.sh"
pre_ver=$(cat "$APP2/version.txt")
pre_daemon=$(cat "$APP2/scripts/continuity_daemon.sh")
rc=0; ota_apply "$half_commit" || rc=$?
assert_eq "apply refuses a tree that fails verification" "1" "$rc"
assert_eq "live version untouched after refused apply" "$pre_ver" "$(cat "$APP2/version.txt")"
assert_eq "live daemon script untouched after refused apply" "$pre_daemon" "$(cat "$APP2/scripts/continuity_daemon.sh")"
assert_eq "no .ota_commit written on a refused apply" "1" \
    "$([ ! -f "$HOME2/.ota_commit" ] && echo 1 || echo 0)"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
