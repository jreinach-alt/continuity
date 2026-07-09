#!/bin/sh
# build_digest.sh — daily save-archive digest for a Continuity saves repo.
#
# Scans commits in a time window (default: the last 24 hours), groups
# archived files by the device that pushed them (the `device:` trailer
# Continuity writes in every sync commit), and emits a Markdown digest.
# Conflict artifacts (.local/.conflict) get their own attention section
# — the digest doubles as the safety net after a gameplay session.
#
# Runs inside the SAVES repo (see saves-digest.yml). POSIX sh; tested
# under BusyBox ash by the Continuity project's suite.
#
# Usage: sh build_digest.sh <output.md>
#   DIGEST_SINCE   override the window (default "24 hours ago")
#   Exit 0 with output written  -> save activity found, digest ready
#   Exit 1, no output           -> nothing archived in the window
set -eu

OUT="$1"
SINCE="${DIGEST_SINCE:-24 hours ago}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Commits in the window, oldest first for a natural reading order.
git log --since="$SINCE" --reverse --format='%H' > "$TMP/commits"

: > "$TMP/saves"      # lines: device|file
: > "$TMP/states"     # lines: device|file
: > "$TMP/conflicts"  # lines: device|file
commit_count=0

while IFS= read -r hash; do
    [ -n "$hash" ] || continue

    device=$(git log -1 --format='%B' "$hash" | sed -n 's/^device: *//p' | head -1)
    [ -n "$device" ] || device="unknown device"

    # -z: NUL-delimited file names are never quoted — spaced and
    # non-ASCII save names come through byte-exact.
    git diff-tree --no-commit-id --name-only -z -r "$hash" | tr '\0' '\n' > "$TMP/files"

    # Save/state classification. Keep this set in lockstep with the core
    # single source of truth (src/core/path_mapper.sh: pm_save_grep_re /
    # pm_state_grep_re) — this file deploys into the user's saves repo and
    # cannot source core. Save class = .srm/.sav/.rtc (.rtc carries clock
    # state and travels with its game). States = all five NextUI shapes.
    matched=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            *.local|*.conflict)
                printf '%s|%s\n' "$device" "$f" >> "$TMP/conflicts"; matched=1 ;;
            states/*.st[0-9]|states/*.state|states/*.state[0-9]|states/*.state.[0-9]|states/*.state.auto)
                printf '%s|%s\n' "$device" "$f" >> "$TMP/states"; matched=1 ;;
            *.srm|*.sav|*.rtc)
                printf '%s|%s\n' "$device" "$f" >> "$TMP/saves"; matched=1 ;;
        esac
    done < "$TMP/files"

    [ "$matched" -eq 1 ] && commit_count=$((commit_count + 1))
done < "$TMP/commits"

# Only fire on days that archived something (registration/config
# commits alone do not count as save activity).
if [ ! -s "$TMP/saves" ] && [ ! -s "$TMP/states" ] && [ ! -s "$TMP/conflicts" ]; then
    exit 1
fi

sort -u "$TMP/saves"     > "$TMP/saves.u"
sort -u "$TMP/states"    > "$TMP/states.u"
sort -u "$TMP/conflicts" > "$TMP/conflicts.u"

# emit_by_device <grouped-file> — "### device" headers + file bullets
emit_by_device() {
    local prev dev file
    prev=""
    while IFS='|' read -r dev file; do
        [ -n "$file" ] || continue
        if [ "$dev" != "$prev" ]; then
            printf '\n### %s\n' "$dev"
            prev="$dev"
        fi
        printf -- '- `%s`\n' "$file"
    done < "$1"
}

{
    printf '## Saves archived — %s\n' "$(date -u '+%Y-%m-%d')"
    printf '\n%s save-bearing commit(s) in the last 24h.\n' "$commit_count"

    if [ -s "$TMP/saves.u" ]; then
        emit_by_device "$TMP/saves.u"
    fi

    if [ -s "$TMP/states.u" ]; then
        printf '\n## Save states backed up\n'
        emit_by_device "$TMP/states.u"
    fi

    if [ -s "$TMP/conflicts.u" ]; then
        printf '\n## ⚠ Conflicts recorded — action available\n'
        printf 'Two devices changed the same save; both versions are preserved.\n'
        printf 'Resolve from any device via the Continuity conflict menu.\n'
        emit_by_device "$TMP/conflicts.u"
    fi
} > "$OUT"

exit 0
