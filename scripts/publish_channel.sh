#!/bin/sh
# Publish a built PAK to an OTA release channel.
#
# Usage: publish_channel.sh <channel> <commit-ish> [--force] [--push]
#
#   <channel>    stable | nightly (any name; these two are the contract)
#   <commit-ish> the PUSHED commit whose tree carries the verified
#                build/Continuity.pak (resolve with git log -- build/)
#   --force      allow publishing stable to a commit nightly has not
#                proven (rollbacks), or re-pinning to the same commit
#   --push       push the manifest commit to origin after committing
#
# What it does:
#   1. Verifies the target commit's PAK straight from git objects:
#      version.txt present, every checksums.txt entry matches blob
#      size AND sha256 — no worktree, no card, no trust in the caller.
#   2. Rewrites release/channels.json (other channels preserved).
#   3. Commits `release(<channel>): <version> (<sha7>)`.
#
# Devices read the manifest from MAIN — a publish takes effect for
# devices once this commit is reachable from origin/main (direct push
# to main or a merged PR).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# CONTINUITY_PUBLISH_ROOT: test hook — lets the suite run this real
# publisher against a fixture repo, so the manifest writer and the
# on-device reader can never drift apart.
PROJECT_ROOT="${CONTINUITY_PUBLISH_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANIFEST="$PROJECT_ROOT/release/channels.json"

CHANNEL="${1:-}"
TARGET="${2:-}"
FORCE=0
PUSH=0
for a in "${3:-}" "${4:-}"; do
    [ "$a" = "--force" ] && FORCE=1
    [ "$a" = "--push" ] && PUSH=1
done

if [ -z "$CHANNEL" ] || [ -z "$TARGET" ]; then
    printf 'usage: publish_channel.sh <channel> <commit-ish> [--force] [--push]\n' >&2
    exit 2
fi

SHA=$(git -C "$PROJECT_ROOT" rev-parse --verify "$TARGET^{commit}") || {
    printf 'ERROR: cannot resolve commit: %s\n' "$TARGET" >&2
    exit 1
}

# Publishing is the moment bits reach devices — the FULL gate runs
# here (it checks the working tree; publish from the tree state you
# built). CONTINUITY_SKIP_GATE=1 bypasses in emergencies — say so.
# (Suppressed under CONTINUITY_PUBLISH_ROOT: the test fixture repo has
# no gate to run.)
if [ -z "${CONTINUITY_PUBLISH_ROOT:-}" ] && [ "${CONTINUITY_SKIP_GATE:-0}" != "1" ]; then
    printf 'publish: running the full gate (device-delivery moment)\n'
    sh "$PROJECT_ROOT/scripts/gate.sh" full
fi

# ── Verify the commit's PAK from git objects ─────────────────────────
VERSION=$(git -C "$PROJECT_ROOT" show "$SHA:build/Continuity.pak/version.txt" 2>/dev/null) || {
    printf 'ERROR: %s carries no build/Continuity.pak/version.txt\n' "$SHA" >&2
    exit 1
}

sums=$(git -C "$PROJECT_ROOT" show "$SHA:build/Continuity.pak/checksums.txt" 2>/dev/null) || {
    printf 'ERROR: %s carries no checksums.txt\n' "$SHA" >&2
    exit 1
}
printf '%s\n' "$sums" | while IFS=' ' read -r sum size path; do
    [ -n "$path" ] || continue
    actual_size=$(git -C "$PROJECT_ROOT" cat-file -s "$SHA:build/Continuity.pak/$path" 2>/dev/null) || {
        printf 'ERROR: manifest lists %s but the commit lacks it\n' "$path" >&2
        exit 1
    }
    if [ "$actual_size" != "$size" ]; then
        printf 'ERROR: %s size %s != manifest %s\n' "$path" "$actual_size" "$size" >&2
        exit 1
    fi
    actual_sum=$(git -C "$PROJECT_ROOT" cat-file blob "$SHA:build/Continuity.pak/$path" | sha256sum | cut -d' ' -f1)
    if [ "$actual_sum" != "$sum" ]; then
        printf 'ERROR: %s sha256 mismatch vs manifest\n' "$path" >&2
        exit 1
    fi
done

# ── Channel discipline: stable only gets what nightly proved ─────────
get_entry() { # <channel> -> "commit version" or empty
    sed -n 's/.*"'"$1"'": *{ *"commit": *"\([0-9a-f]\{40\}\)", *"version": *"\([^"]*\)".*/\1 \2/p' \
        "$MANIFEST" 2>/dev/null
}

if [ "$CHANNEL" = "stable" ] && [ "$FORCE" -ne 1 ]; then
    nightly_commit=$(get_entry nightly | cut -d' ' -f1)
    if [ "$nightly_commit" != "$SHA" ]; then
        printf 'ERROR: stable must point where nightly points (%s)\n' "${nightly_commit:-none}" >&2
        printf '       publish nightly first, or use --force (rollback)\n' >&2
        exit 1
    fi
fi

# ── Rewrite the manifest, preserving other channels ──────────────────
TMP=$(mktemp)
{
    printf '{\n'
    printf '  "_schema_version": "1.0",\n'
    printf '  "channels": {\n'
    first=1
    # existing channels, target replaced in place
    while IFS=' ' read -r name commit version; do
        [ -n "$name" ] || continue
        if [ "$name" = "$CHANNEL" ]; then
            commit="$SHA"; version="$VERSION"
        fi
        [ "$first" -eq 1 ] || printf ',\n'
        printf '    "%s": { "commit": "%s", "version": "%s" }' "$name" "$commit" "$version"
        first=0
        printf '%s\n' "$name" >> "$TMP.seen"
    done <<EOF
$(sed -n 's/.*"\([a-z0-9_-]*\)": *{ *"commit": *"\([0-9a-f]\{40\}\)", *"version": *"\([^"]*\)".*/\1 \2 \3/p' "$MANIFEST" 2>/dev/null)
EOF
    # channel not previously present — append it
    if ! grep -qx "$CHANNEL" "$TMP.seen" 2>/dev/null; then
        [ "$first" -eq 1 ] || printf ',\n'
        printf '    "%s": { "commit": "%s", "version": "%s" }' "$CHANNEL" "$SHA" "$VERSION"
    fi
    printf '\n  }\n}\n'
} > "$TMP"
rm -f "$TMP.seen"
mv "$TMP" "$MANIFEST"

git -C "$PROJECT_ROOT" add "$MANIFEST"
git -C "$PROJECT_ROOT" commit -m "release($CHANNEL): $VERSION ($(printf '%s' "$SHA" | cut -c1-7))" >/dev/null

printf 'published %s -> %s (%s)\n' "$CHANNEL" "$VERSION" "$SHA"
if [ "$PUSH" -eq 1 ]; then
    branch=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
    git -C "$PROJECT_ROOT" push -u origin "$branch"
else
    printf 'now push:  git push -u origin %s\n' "$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)"
    printf 'devices see it once it is reachable from origin/main\n'
fi
