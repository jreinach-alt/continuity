#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/muos/task_continuity_update.sh — the OTA
# "Continuity Update" Task Toolkit consent surface. Covers the SD-root
# probe (bind-mount trap), and drives the real task end-to-end against a
# file:// fixture repo to prove the current->new report, the applied
# outcome, the kill-switch message, and the not-installed guard (A6).
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
TASK="$PROJECT_ROOT/src/platforms/muos/task_continuity_update.sh"

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

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

GIT_CONFIG_COUNT=1
GIT_CONFIG_KEY_0="commit.gpgsign"
GIT_CONFIG_VALUE_0="false"
export GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0

# --- SD-root probe (source-only) ---
TCU_NO_MAIN=1
# shellcheck disable=SC1090
. "$TASK"

# env override wins
got=$(CONTINUITY_SD_ROOT="$TEST_TMPDIR/explicit" tcu_resolve_sd_root)
assert_eq "SD root: explicit override wins" "$TEST_TMPDIR/explicit" "$got"

# probe: the primary candidate that carries an app install is chosen
PRIMARY="$TEST_TMPDIR/primary"
mkdir -p "$PRIMARY/.continuity/app"
got=$(CONTINUITY_SD_ROOT="" CONTINUITY_MUOS_SD_PRIMARY="$PRIMARY" tcu_resolve_sd_root)
assert_eq "SD root: probed primary carrying an app wins" "$PRIMARY" "$got"

# fallback: nothing carries an app -> the primary mount (breadcrumb still lands)
EMPTY="$TEST_TMPDIR/emptyprimary"
mkdir -p "$EMPTY"
got=$(CONTINUITY_SD_ROOT="" CONTINUITY_MUOS_SD_PRIMARY="$EMPTY" tcu_resolve_sd_root)
assert_eq "SD root: falls back to the primary mount" "$EMPTY" "$got"

# --- End-to-end fixture ---
UPSTREAM="$TEST_TMPDIR/upstream"
mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email t@t
git -C "$UPSTREAM" config user.name t
git -C "$UPSTREAM" config uploadpack.allowFilter true
git -C "$UPSTREAM" config uploadpack.allowAnySHA1InWant true

publish_muos() { # <pak_version> <muos_version> <marker> -> sha
    local pv mv m pak app root
    pv="$1"; mv="$2"; m="$3"
    pak="$UPSTREAM/build/Continuity.pak"; mkdir -p "$pak/bin"
    printf 'PAKBIN' > "$pak/bin/git"
    printf '%s\n' "$pv" > "$pak/version.txt"
    printf '%s %s %s\n' "$(sha256sum "$pak/bin/git" | cut -d' ' -f1)" \
        "$(wc -c < "$pak/bin/git")" "bin/git" > "$pak/checksums.txt"
    root="$UPSTREAM/build/Continuity-muos.app"; app="$root/.continuity/app"
    mkdir -p "$app/scripts/core" "$app/config/platform_maps" "$app/bin" \
             "$root/MUOS/task" "$root/MUOS/init"
    printf '#!/bin/sh\n# daemon marker: %s\ntrue\n' "$m" > "$app/scripts/continuity_daemon.sh"
    printf '#!/bin/sh\n# core marker: %s\ntrue\n' "$m" > "$app/scripts/core/pal.sh"
    # the real updater ships alongside the daemon (the task sources it)
    cp "$PROJECT_ROOT/src/platforms/muos/update.sh" "$app/scripts/update.sh"
    printf '{}\n' > "$app/config/platform_maps/muos.json"
    printf 'MUOSBIN' > "$app/bin/git"
    printf '%s\n' "$mv" > "$app/version.txt"
    printf 'nightly\n' > "$app/ota_channel.txt"
    printf '%s %s %s\n' "$(sha256sum "$app/bin/git" | cut -d' ' -f1)" \
        "$(wc -c < "$app/bin/git")" "bin/git" > "$app/checksums.txt"
    printf '#!/bin/sh\ntrue\n' > "$root/MUOS/task/Continuity.sh"
    printf '#!/bin/sh\ntrue\n' > "$root/MUOS/task/Continuity Update.sh"
    printf '#!/bin/sh\ntrue\n' > "$root/MUOS/init/continuity.sh"
    git -C "$UPSTREAM" add -A
    git -C "$UPSTREAM" commit -qm "build $mv"
    git -C "$UPSTREAM" rev-parse HEAD
}

mkdir -p "$UPSTREAM/release"
printf '{\n  "_schema_version": "1.0",\n  "channels": {\n  }\n}\n' > "$UPSTREAM/release/channels.json"
git -C "$UPSTREAM" add -A; git -C "$UPSTREAM" commit -qm "seed manifest"
V2_SHA=$(publish_muos "0.1.0-pak-v2" "0.1.0-muos-v2" "second-build")
CONTINUITY_PUBLISH_ROOT="$UPSTREAM" sh "$PROJECT_ROOT/scripts/publish_channel.sh" nightly "$V2_SHA" >/dev/null

# Live install on a fake card: an app at v1 with the real updater staged.
SD="$TEST_TMPDIR/card"
APP="$SD/.continuity/app"
mkdir -p "$APP/scripts/core" "$APP/bin" "$SD/MUOS/task" "$SD/MUOS/init"
printf '#!/bin/sh\n# daemon marker: first\ntrue\n' > "$APP/scripts/continuity_daemon.sh"
cp "$PROJECT_ROOT/src/platforms/muos/update.sh" "$APP/scripts/update.sh"
printf '0.1.0-muos-v1\n' > "$APP/version.txt"
printf 'nightly\n' > "$APP/ota_channel.txt"
printf 'MUOSBIN' > "$APP/bin/git"

# --- Kill switch: named message, no change ---
out=$(CONTINUITY_SD_ROOT="$SD" CONTINUITY_OTA_URL="file://$UPSTREAM" \
    CONTINUITY_GIT_BIN="git" CONTINUITY_OTA=0 sh "$TASK" 2>&1) || true
assert_contains_str "kill switch: task says OTA disabled" "$out" "OTA is disabled"
assert_eq "kill switch: no update applied" "0.1.0-muos-v1" "$(cat "$APP/version.txt")"

# --- Happy path: current -> new reported, applied, honest success ---
rc=0
out=$(CONTINUITY_SD_ROOT="$SD" CONTINUITY_OTA_URL="file://$UPSTREAM" \
    CONTINUITY_GIT_BIN="git" sh "$TASK" 2>&1) || rc=$?
assert_eq "update task exits 0 on success" "0" "$rc"
assert_contains_str "reports the current version" "$out" "current version: 0.1.0-muos-v1"
assert_contains_str "reports current -> new" "$out" "0.1.0-muos-v1 -> 0.1.0-muos-v2"
assert_contains_str "reports applied outcome" "$out" "Updated to 0.1.0-muos-v2"
assert_eq "app updated to v2" "0.1.0-muos-v2" "$(cat "$APP/version.txt")"

# --- Idempotent: a second tap finds nothing to do ---
rc=0
out=$(CONTINUITY_SD_ROOT="$SD" CONTINUITY_OTA_URL="file://$UPSTREAM" \
    CONTINUITY_GIT_BIN="git" sh "$TASK" 2>&1) || rc=$?
assert_eq "second tap exits 0 (already current)" "0" "$rc"
assert_contains_str "second tap reports no update" "$out" "No update applied"

# --- Not installed: honest failure, named ---
EMPTY_SD="$TEST_TMPDIR/empty-card"
mkdir -p "$EMPTY_SD/.continuity"
rc=0
out=$(CONTINUITY_SD_ROOT="$EMPTY_SD" sh "$TASK" 2>&1) || rc=$?
assert_eq "not-installed exits 1" "1" "$rc"
assert_contains_str "not-installed names itself" "$out" "not installed"

# --- Report ---
printf '\ntest_task_continuity_update: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
