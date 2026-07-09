#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034
# Unit tests for src/platforms/nextui/update.sh (channel-manifest OTA)
# and scripts/publish_channel.sh — the REAL publisher runs against the
# fixture repo, so the manifest writer and the on-device reader are
# tested as one contract.
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

# Fixture "project repo" with main, a tracked PAK, and a release manifest
UPSTREAM="$TEST_TMPDIR/upstream"
mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q -b main
git -C "$UPSTREAM" config user.email t@t
git -C "$UPSTREAM" config user.name t
git -C "$UPSTREAM" config uploadpack.allowFilter true
# Devices fetch manifest-pinned SHAs directly (GitHub serves reachable
# SHAs; file:// remotes need it enabled)
git -C "$UPSTREAM" config uploadpack.allowAnySHA1InWant true

publish_pak() { # <version> <marker> — commits a PAK tree, prints its sha
    local v m tree
    v="$1"; m="$2"
    tree="$UPSTREAM/build/Continuity.pak"
    mkdir -p "$tree/scripts/core" "$tree/config/platform_maps" "$tree/bin"
    printf '#!/bin/sh\n# marker: %s\ntrue\n' "$m" > "$tree/launch.sh"
    printf '#!/bin/sh\n# core marker: %s\ntrue\n' "$m" > "$tree/scripts/core/pal.sh"
    printf '#!/bin/sh\ntrue\n' > "$tree/scripts/update.sh"
    printf '{}\n' > "$tree/config/platform_maps/nextui.json"
    printf 'BINARYv1' > "$tree/bin/git"
    printf '%s\n' "$v" > "$tree/version.txt"
    printf 'nightly\n' > "$tree/ota_channel.txt"
    printf '%s %s %s\n' "$(sha256sum "$tree/bin/git" | cut -d' ' -f1)" \
        "$(wc -c < "$tree/bin/git")" "bin/git" > "$tree/checksums.txt"
    git -C "$UPSTREAM" add -A
    git -C "$UPSTREAM" commit -qm "build $v"
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
V2_SHA=$(publish_pak "0.1.0-v2" "second-build")
publish_channel nightly "$V2_SHA" >/dev/null
publish_channel stable  "$V2_SHA" >/dev/null

# Device-side fake live PAK + state home
PAK="$TEST_TMPDIR/live-pak"
HOME_DIR="$TEST_TMPDIR/chome"
mkdir -p "$PAK/scripts/core" "$PAK/bin"
printf '#!/bin/sh\n# marker: first-build\ntrue\n' > "$PAK/launch.sh"
printf '0.1.0-v1\n' > "$PAK/version.txt"
printf 'nightly\n' > "$PAK/ota_channel.txt"
printf 'BINARYv1' > "$PAK/bin/git"

CONTINUITY_PAK_DIR="$PAK"
CONTINUITY_HOME="$HOME_DIR"
CONTINUITY_OTA_URL="file://$UPSTREAM"
CONTINUITY_GIT_BIN="git"

. "$PROJECT_ROOT/src/platforms/nextui/update.sh"

# --- Test 1: manifest-pinned update detected; unpublished main is invisible ---
# land an UNPUBLISHED build on main after the publish — devices must
# still be offered the PINNED commit, not the branch head
UNPUB_SHA=$(publish_pak "0.1.0-unpublished" "never-see-this")
rc=0; info=$(ota_check) || rc=$?
assert_eq "update detected via manifest" "0" "$rc"
assert_contains_str "pinned version reported" "$info" "0.1.0-v2"
commit="${info##* }"
assert_eq "offered commit is the PINNED sha, not main head" "$V2_SHA" "$commit"
assert_eq "device channel identity seeded from build" "nightly" "$(cat "$HOME_DIR/ota_channel")"

# --- Test 2: apply updates scripts, version, state marker ---
rc=0; ota_apply "$commit" || rc=$?
assert_eq "apply succeeds" "0" "$rc"
assert_contains_str "launch.sh updated" "$(cat "$PAK/launch.sh")" "second-build"
assert_contains_str "core module updated" "$(cat "$PAK/scripts/core/pal.sh")" "second-build"
assert_eq "version updated" "0.1.0-v2" "$(cat "$PAK/version.txt")"
assert_eq "commit recorded" "$commit" "$(cat "$HOME_DIR/.ota_commit")"

# --- Test 3: up to date afterwards ---
rc=0; ota_check >/dev/null || rc=$?
assert_eq "no update when current" "1" "$rc"

# --- Test 4: publish v3 to nightly only; nightly device follows via ota_run ---
V3_SHA=$(publish_pak "0.1.0-v3" "third-build")
publish_channel nightly "$V3_SHA" >/dev/null
rc=0; ota_run || rc=$?
assert_eq "ota_run applies nightly publish" "0" "$rc"
assert_eq "version now v3" "0.1.0-v3" "$(cat "$PAK/version.txt")"
assert_contains_str "third marker present" "$(cat "$PAK/launch.sh")" "third-build"

# --- Test 5: channel switch is authoritative — stable offers the rollback ---
ota_set_channel stable
rc=0; info=$(ota_check) || rc=$?
assert_eq "stable channel offers its pinned build" "0" "$rc"
assert_contains_str "stable still pins v2" "$info" "0.1.0-v2"
rc=0; ota_apply "${info##* }" || rc=$?
assert_eq "downgrade to stable applies" "0" "$rc"
assert_eq "device back on v2" "0.1.0-v2" "$(cat "$PAK/version.txt")"
ota_set_channel nightly
rc=0; ota_run || rc=$?
assert_eq "back on nightly, v3 again" "0.1.0-v3" "$(cat "$PAK/version.txt")"

# --- Test 6: installing a build seeded for another channel does NOT move the device ---
printf 'stable\n' > "$PAK/ota_channel.txt"   # what a stable-seeded build would carry
assert_eq "device identity survives foreign-channel install" \
    "nightly" "$(ota_channel)"
printf 'nightly\n' > "$PAK/ota_channel.txt"

# --- Test 7: unchanged binary is not rewritten (size probe) ---
before=$(stat -c %Y "$PAK/bin/git" 2>/dev/null || date +%s)
sleep 1
V4_SHA=$(publish_pak "0.1.0-v4" "fourth-build")
publish_channel nightly "$V4_SHA" >/dev/null
rc=0; ota_run || rc=$?
assert_eq "v4 applied" "0.1.0-v4" "$(cat "$PAK/version.txt")"
after=$(stat -c %Y "$PAK/bin/git" 2>/dev/null || printf '%s' "$before")
assert_eq "same-size binary untouched" "$before" "$after"

# --- Test 8: card-swapped deploy parity — same version adopted, not re-offered ---
V5_SHA=$(publish_pak "0.1.0-v5" "fifth-build")
publish_channel nightly "$V5_SHA" >/dev/null
printf '0.1.0-v5\n' > "$PAK/version.txt"   # simulate card swap of v5
rm -f "$HOME_DIR/.ota_commit"              # card swap never writes OTA state
rc=0; ota_check >/dev/null || rc=$?
assert_eq "matching deployed version not re-offered" "1" "$rc"
assert_eq "pinned commit adopted as current" "$V5_SHA" "$(cat "$HOME_DIR/.ota_commit")"

# --- Test 9: legacy fallback — channel value doubles as a branch name ---
git -C "$UPSTREAM" branch legacy-dev "$V3_SHA"
ota_set_channel legacy-dev
rc=0; info=$(ota_check) || rc=$?
assert_eq "legacy branch mode still serves pre-manifest devices" "0" "$rc"
assert_contains_str "legacy offer is the branch head's build" "$info" "0.1.0-v3"
rc=0; ota_apply "${info##* }" || rc=$?
assert_eq "legacy apply works" "0.1.0-v3" "$(cat "$PAK/version.txt")"

# --- Test 10: unknown channel with no branch holds safely ---
ota_set_channel does-not-exist
rc=0; ota_check >/dev/null 2>&1 || rc=$?
assert_eq "unknown channel holds (rc 1)" "1" "$rc"
assert_eq "held device keeps its version" "0.1.0-v3" "$(cat "$PAK/version.txt")"
ota_set_channel nightly

# --- Test 11: publisher guard — stable can't skip past nightly ---
V6_SHA=$(publish_pak "0.1.0-v6" "sixth-build")
rc=0; publish_channel stable "$V6_SHA" >/dev/null 2>&1 || rc=$?
assert_eq "stable publish refused when nightly hasn't proven it" "1" "$rc"
rc=0; publish_channel stable "$V6_SHA" --force >/dev/null 2>&1 || rc=$?
assert_eq "--force overrides (rollback path)" "0" "$rc"
entry=$(git -C "$UPSTREAM" show HEAD:release/channels.json | grep '"stable"')
assert_contains_str "manifest stable entry updated" "$entry" "$V6_SHA"

# --- Test 12: publisher refuses a commit without a verifiable PAK ---
printf 'not a pak\n' > "$UPSTREAM/stray.txt"
git -C "$UPSTREAM" add stray.txt
git -C "$UPSTREAM" commit -qm "no pak change"
git -C "$UPSTREAM" rm -q -r build/Continuity.pak
git -C "$UPSTREAM" commit -qm "remove pak"
NOPAK_SHA=$(git -C "$UPSTREAM" rev-parse HEAD)
rc=0; publish_channel nightly "$NOPAK_SHA" >/dev/null 2>&1 || rc=$?
assert_eq "publish refused for commit without a PAK" "1" "$rc"

# --- Test 13: corrupt fetched tree refused (verify unchanged) ---
CORRUPT="$TEST_TMPDIR/corrupt-tree"
mkdir -p "$CORRUPT/scripts"
printf '#!/bin/sh\r\ntrue\r\n' > "$CORRUPT/launch.sh"
rc=0; ota_verify_tree "$CORRUPT" || rc=$?
assert_eq "CRLF tree refused" "1" "$rc"

BADSIZE="$TEST_TMPDIR/badsize-tree"
mkdir -p "$BADSIZE/scripts" "$BADSIZE/bin"
printf '#!/bin/sh\ntrue\n' > "$BADSIZE/launch.sh"
printf 'short' > "$BADSIZE/bin/git"
printf 'deadbeef 999 bin/git\n' > "$BADSIZE/checksums.txt"
rc=0; ota_verify_tree "$BADSIZE" || rc=$?
assert_eq "size-mismatched tree refused" "1" "$rc"

# ─────────────────────────────────────────────────────────────────────
# Sprint 1.9 — OTA origin reconcile + migration rehearsal
# ─────────────────────────────────────────────────────────────────────

init_fixture_repo() { # <dir> — a servable project repo with an empty manifest
    local r; r="$1"
    mkdir -p "$r"
    git -C "$r" init -q -b main
    git -C "$r" config user.email t@t
    git -C "$r" config user.name t
    git -C "$r" config uploadpack.allowFilter true
    git -C "$r" config uploadpack.allowAnySHA1InWant true
    mkdir -p "$r/release"
    printf '{\n  "_schema_version": "1.0",\n  "channels": {\n  }\n}\n' > "$r/release/channels.json"
    git -C "$r" add -A
    git -C "$r" commit -qm "seed manifest"
}

publish_pak_in() { # <dir> <version> <marker> — commit a PAK tree, print its sha
    local r v m tree
    r="$1"; v="$2"; m="$3"
    tree="$r/build/Continuity.pak"
    mkdir -p "$tree/scripts/core" "$tree/config/platform_maps" "$tree/bin"
    printf '#!/bin/sh\n# marker: %s\ntrue\n' "$m" > "$tree/launch.sh"
    printf '#!/bin/sh\n# core marker: %s\ntrue\n' "$m" > "$tree/scripts/core/pal.sh"
    printf '#!/bin/sh\ntrue\n' > "$tree/scripts/update.sh"
    printf '{}\n' > "$tree/config/platform_maps/nextui.json"
    printf 'BINARYv1' > "$tree/bin/git"
    printf '%s\n' "$v" > "$tree/version.txt"
    printf 'nightly\n' > "$tree/ota_channel.txt"
    printf '%s %s %s\n' "$(sha256sum "$tree/bin/git" | cut -d' ' -f1)" \
        "$(wc -c < "$tree/bin/git")" "bin/git" > "$tree/checksums.txt"
    git -C "$r" add -A
    git -C "$r" commit -qm "build $v"
    git -C "$r" rev-parse HEAD
}

publish_channel_in() { # <dir> <channel> <sha> [--force] — the REAL publisher
    local r; r="$1"; shift
    CONTINUITY_PUBLISH_ROOT="$r" sh "$PROJECT_ROOT/scripts/publish_channel.sh" "$@"
}

# --- Test 14: origin reconcile — a clone made against a stale home is
#     repointed to the current OTA_URL on the next check, and logs it ---
REPO_R="$TEST_TMPDIR/reco-home"
init_fixture_repo "$REPO_R"
R_SHA=$(publish_pak_in "$REPO_R" "0.1.0-rp" "repoint-build")
publish_channel_in "$REPO_R" nightly "$R_SHA" >/dev/null

RPAK="$TEST_TMPDIR/reco-pak"; RHOME="$TEST_TMPDIR/reco-chome"
mkdir -p "$RPAK/bin"
printf '0.1.0-old\n' > "$RPAK/version.txt"
printf 'nightly\n' > "$RPAK/ota_channel.txt"

OTA_PAK_DIR="$RPAK"
OTA_HOME="$RHOME"; OTA_REPO="$OTA_HOME/ota-repo"; OTA_LOG="$OTA_HOME/update.log"
OTA_URL="file://$REPO_R"
mkdir -p "$RHOME"

ota_ensure_repo                                   # honest clone against the real home
STALE_URL="file://$TEST_TMPDIR/old-ideal_os"
git -C "$OTA_REPO" remote set-url origin "$STALE_URL"
assert_eq "clone starts on the stale origin" "$STALE_URL" \
    "$(git -C "$OTA_REPO" remote get-url origin)"

: > "$OTA_LOG"                                     # only observe this check's lines
rc=0; info=$(ota_check) || rc=$?
assert_eq "check succeeds after repoint" "0" "$rc"
assert_contains_str "offers the fixture's pinned build" "$info" "0.1.0-rp"
assert_eq "origin now matches the current OTA_URL" "file://$REPO_R" \
    "$(git -C "$OTA_REPO" remote get-url origin)"
assert_contains_str "repoint line logged" "$(cat "$OTA_LOG")" \
    "OTA remote repointed to file://$REPO_R"

# --- Test 15: reconcile is idempotent — a matching origin logs nothing ---
: > "$OTA_LOG"
rc=0; ota_check >/dev/null || rc=$?
case "$(cat "$OTA_LOG")" in
    *"OTA remote repointed"*) reco_again=yes ;;
    *) reco_again=no ;;
esac
assert_eq "second check does not repoint (idempotent)" "no" "$reco_again"
assert_eq "origin unchanged on the idempotent pass" "file://$REPO_R" \
    "$(git -C "$OTA_REPO" remote get-url origin)"

# --- Test 16: migration rehearsal — the whole handoff in miniature ---
# Repo A (old home) serves a handoff build whose OTA_URL will name repo B.
# B (continuity) is seeded by commit-tree from A's handoff TREE — a new
# SHA universe, same version — with a channel pinning the seed. A device
# on A installs the handoff, then on the next check repoints to B and
# version-parity-adopts B's seed pin WITHOUT refetching it.
REPO_A="$TEST_TMPDIR/mig-a"
REPO_B="$TEST_TMPDIR/mig-b"
init_fixture_repo "$REPO_A"
HANDOFF_A=$(publish_pak_in "$REPO_A" "0.1.0-handoff" "handoff-build")
publish_channel_in "$REPO_A" nightly "$HANDOFF_A" >/dev/null

# Seed B from A's handoff tree (parentless commit-tree => new universe)
git clone -q "$REPO_A" "$REPO_B"
git -C "$REPO_B" config user.email t@t
git -C "$REPO_B" config user.name t
git -C "$REPO_B" config uploadpack.allowFilter true
git -C "$REPO_B" config uploadpack.allowAnySHA1InWant true
HANDOFF_TREE=$(git -C "$REPO_B" rev-parse "$HANDOFF_A^{tree}")
SEED_B=$(git -C "$REPO_B" commit-tree "$HANDOFF_TREE" -m "Continuity — seeded root")
assert_eq "seed tree == handoff tree (identical by construction)" \
    "$HANDOFF_TREE" "$(git -C "$REPO_B" rev-parse "$SEED_B^{tree}")"
if [ "$SEED_B" = "$HANDOFF_A" ]; then new_universe=no; else new_universe=yes; fi
assert_eq "seed is a new SHA universe (different commit)" "yes" "$new_universe"
git -C "$REPO_B" checkout -q -B main "$SEED_B"
publish_channel_in "$REPO_B" nightly "$SEED_B" >/dev/null   # B correct before any device arrives

# Device on A installs the handoff build
MPAK="$TEST_TMPDIR/mig-pak"; MHOME="$TEST_TMPDIR/mig-chome"
mkdir -p "$MPAK/bin"
printf '0.1.0-pre\n' > "$MPAK/version.txt"
printf 'nightly\n' > "$MPAK/ota_channel.txt"

OTA_PAK_DIR="$MPAK"
OTA_HOME="$MHOME"; OTA_REPO="$OTA_HOME/ota-repo"; OTA_LOG="$OTA_HOME/update.log"
OTA_URL="file://$REPO_A"
mkdir -p "$MHOME"

rc=0; ota_run || rc=$?
assert_eq "device installs the handoff from A" "0" "$rc"
assert_eq "device now on the handoff version" "0.1.0-handoff" "$(cat "$MPAK/version.txt")"
assert_eq "persistent clone still points at A" "file://$REPO_A" \
    "$(git -C "$OTA_REPO" remote get-url origin)"

# The handoff build's new OTA_URL default takes effect on the next boot.
OTA_URL="file://$REPO_B"
: > "$OTA_LOG"
rc=0; ota_check >/dev/null || rc=$?
assert_eq "no update offered — seed adopted by version parity" "1" "$rc"
assert_eq "clone repointed to B" "file://$REPO_B" \
    "$(git -C "$OTA_REPO" remote get-url origin)"
mlog=$(cat "$OTA_LOG")
assert_contains_str "repoint to B logged" "$mlog" "OTA remote repointed to file://$REPO_B"
assert_contains_str "version-parity adoption of the seed logged" "$mlog" \
    "Deployed build 0.1.0-handoff already matches $SEED_B — adopting"
assert_eq "device adopted B's seed commit without refetch" "$SEED_B" \
    "$(cat "$MHOME/.ota_commit")"

# --- Report ---
printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
