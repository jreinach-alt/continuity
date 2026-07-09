#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
set -e

# migrate_repo.sh — one-time repo rename to canonical save basenames.
#
# Renames device-natively-named save files already in a Continuity saves
# repo to the canonical <system>/<basename>.srm form (Sprint 2.0). Bytes
# are untouched (git mv is a pure rename); conflict artifacts (.local /
# .conflict) are carried along with their save. RZIP-compressed saves are
# quarantined (reported, never renamed). Idempotent: already-canonical
# files are no-ops, so a second run reports nothing.
#
# DRY-RUN BY DEFAULT — writes nothing until --apply is given.
#
# Delivery ordering (sprint-2.0 spec): run this ONCE from an enrolled full
# device, inside the saves-repo clone, AFTER the 2.0-aware PAK is deployed
# to every device. An old-PAK device would re-push device-native names and
# undo the migration.
#
# Usage: migrate_repo.sh [--apply] [--pal <pal_file>] [repo_dir]
#   --apply        perform the renames (default: dry-run)
#   --pal <file>   PAL to source (default: NextUI PAL)
#   repo_dir       saves repo clone (default: $CONTINUITY_REPO_DIR or cwd)

usage() {
    sed -n '6,22p' "$0" | sed 's/^# \{0,1\}//'
}

APPLY=0
PAL_FILE=""
REPO_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1 ;;
        --pal) shift; PAL_FILE="$1" ;;
        --pal=*) PAL_FILE="${1#--pal=}" ;;
        --help|-h) usage; exit 0 ;;
        -*) printf 'migrate_repo: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) REPO_ARG="$1" ;;
    esac
    shift
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
: "${PAL_FILE:=$REPO_ROOT/src/platforms/nextui/pal_nextui.sh}"

if [ ! -f "$PAL_FILE" ]; then
    printf 'migrate_repo: PAL not found: %s\n' "$PAL_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
. "$PAL_FILE"
# shellcheck source=src/core/pal.sh
. "$REPO_ROOT/src/core/pal.sh"
# shellcheck source=src/core/path_mapper.sh
. "$REPO_ROOT/src/core/path_mapper.sh"

REPO_DIR="${REPO_ARG:-${CONTINUITY_REPO_DIR:-$PWD}}"
GIT="${CONTINUITY_GIT_BIN:-git}"

if ! "$GIT" -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'migrate_repo: not a git repo: %s\n' "$REPO_DIR" >&2
    exit 1
fi

map=$(pal_get_platform_map)
if ! pm_load_platform_map "$map" 2>/dev/null; then
    printf 'migrate_repo: could not load platform map: %s\n' "$map" >&2
    exit 1
fi
if [ -z "$_pm_name_style" ]; then
    printf 'migrate_repo: platform map has no save_name_style (schema 1.0) — nothing to canonicalize\n' >&2
    exit 1
fi

PLAN=$(mktemp)
QUAR=$(mktemp)
COLL=$(mktemp)
TARGETS=$(mktemp)
trap 'rm -f "$PLAN" "$QUAR" "$COLL" "$TARGETS"' EXIT
: > "$PLAN"; : > "$QUAR"; : > "$COLL"; : > "$TARGETS"

tab=$(printf '\t')

# Enumerate every tracked-tree file except git internals, the .continuity
# metadata dir, and the opaque states/ backup (states keep device-native
# names verbatim — one-way, never materialized).
find "$REPO_DIR" -type f \
    ! -path "*/.git/*" \
    ! -path "*/.continuity/*" \
    ! -path "$REPO_DIR/states/*" \
    2>/dev/null | while IFS= read -r abs; do

    rel=${abs#"$REPO_DIR"/}
    case "$rel" in states/*) continue ;; esac

    # Split a conflict artifact suffix off the save it belongs to.
    suffix=""
    base="$rel"
    case "$rel" in
        *.conflict)
            base=${rel%.conflict}
            suffix=".conflict"
            ;;
        *.local)
            base=$(printf '%s' "$rel" | sed 's/\.[^./]*\.local$//')
            suffix=${rel#"$base"}
            ;;
    esac

    # Only save-class bases participate (skip states, README, etc.).
    case "$base" in
        *.srm|*.sav|*.rtc) ;;
        *) continue ;;
    esac

    # Compressed saves are quarantined, not renamed (the .conflict JSON is
    # metadata, never a container, so it is exempt from the sniff).
    case "$base" in
        *.srm)
            if [ "$suffix" != ".conflict" ] && [ "$(pm_container_class "$abs")" = "rzip" ]; then
                printf '%s\n' "$rel" >> "$QUAR"
                continue
            fi
            ;;
    esac

    canon_base=$(pm_repo_canonicalize "$base")
    new_rel="$canon_base$suffix"

    if [ "$new_rel" = "$rel" ]; then
        continue   # already canonical
    fi

    if [ -e "$REPO_DIR/$new_rel" ] || grep -qxF "$new_rel" "$TARGETS"; then
        printf '%s -> %s\n' "$rel" "$new_rel" >> "$COLL"
        continue
    fi

    printf '%s\n' "$new_rel" >> "$TARGETS"
    printf '%s%s%s\n' "$rel" "$tab" "$new_rel" >> "$PLAN"
done

n_plan=$(grep -c . "$PLAN" || true)
n_quar=$(grep -c . "$QUAR" || true)
n_coll=$(grep -c . "$COLL" || true)

if [ "$APPLY" -eq 1 ]; then
    printf 'migrate_repo: APPLYING in %s\n' "$REPO_DIR"
else
    printf 'migrate_repo: DRY-RUN in %s (no changes written; pass --apply to migrate)\n' "$REPO_DIR"
fi

if [ "$n_plan" -gt 0 ]; then
    printf '\nRenames (%s):\n' "$n_plan"
    while IFS="$tab" read -r old new; do
        [ -n "$old" ] || continue
        printf '  %s -> %s\n' "$old" "$new"
    done < "$PLAN"
fi

if [ "$n_quar" -gt 0 ]; then
    printf '\nQuarantined — compressed saves (%s), set save format to uncompressed:\n' "$n_quar"
    while IFS= read -r q; do
        [ -n "$q" ] || continue
        printf '  %s\n' "$q"
    done < "$QUAR"
fi

if [ "$n_coll" -gt 0 ]; then
    printf '\nSkipped — target already exists (%s), resolve by hand:\n' "$n_coll"
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        printf '  %s\n' "$c"
    done < "$COLL"
fi

if [ "$n_plan" -eq 0 ]; then
    printf '\nNothing to migrate — repo is already canonical.\n'
    exit 0
fi

if [ "$APPLY" -eq 0 ]; then
    printf '\nDry-run complete. Re-run with --apply to perform %s rename(s).\n' "$n_plan"
    exit 0
fi

# Apply: pure git renames (bytes preserved).
while IFS="$tab" read -r old new; do
    [ -n "$old" ] || continue
    if ! "$GIT" -C "$REPO_DIR" mv -- "$old" "$new"; then
        printf 'migrate_repo: git mv failed: %s -> %s\n' "$old" "$new" >&2
        exit 1
    fi
    printf '  renamed: %s -> %s\n' "$old" "$new"
done < "$PLAN"

printf '\nMigration complete: %s file(s) renamed. Review "git status" and commit.\n' "$n_plan"
exit 0
