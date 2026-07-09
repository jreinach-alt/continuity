#!/bin/sh
# Assemble the canary diagnostic PAK: a Continuity.pak containing ONLY the
# canary launch.sh (see src/platforms/nextui/canary_launch.sh).
#
# Output: build/canary/Continuity.pak/ — copy this folder to the SD card at
# Tools/tg5040/, replacing the real Continuity.pak for one boot cycle.
#
# CANARY_OUT_ROOT overrides the output root (used by tests).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CANARY_SRC="$PROJECT_ROOT/src/platforms/nextui/canary_launch.sh"
OUT_ROOT="${CANARY_OUT_ROOT:-$PROJECT_ROOT/build/canary}"
PAK_DIR="$OUT_ROOT/Continuity.pak"

if [ ! -f "$CANARY_SRC" ]; then
    printf 'ERROR: canary source not found: %s\n' "$CANARY_SRC" >&2
    exit 1
fi

rm -rf "$PAK_DIR"
mkdir -p "$PAK_DIR"
cp "$CANARY_SRC" "$PAK_DIR/launch.sh"
chmod +x "$PAK_DIR/launch.sh"

# ── Sanity checks ────────────────────────────────────────────────────
# CRLF anywhere in launch.sh makes the kernel exec fail silently on the
# device (interpreter becomes "/bin/sh\r"). Same check as build_pak.sh.

cr=$(printf '\r')
if grep -q "$cr" "$PAK_DIR/launch.sh"; then
    printf 'ERROR: CRLF line endings in %s\n' "$PAK_DIR/launch.sh" >&2
    printf 'NextUI cannot exec scripts with CRLF; fix the source and rebuild.\n' >&2
    exit 1
fi

# Parse check under the strictest interpreter available.
if command -v busybox >/dev/null 2>&1; then
    busybox ash -n "$PAK_DIR/launch.sh"
else
    sh -n "$PAK_DIR/launch.sh"
fi

# ── Summary ──────────────────────────────────────────────────────────

printf '\n=== Canary PAK assembled ===\n\n'
printf '  Location: %s\n' "$PAK_DIR"
printf '  Contents:\n'
find "$PAK_DIR" -type f | sort | while read -r f; do
    printf '    %s (%s bytes)\n' "${f#"$OUT_ROOT"/}" "$(wc -c < "$f")"
done
printf '\n  Deploy: copy %s\n' "$PAK_DIR"
printf '  over    SDCARD/Tools/tg5040/Continuity.pak (replace the folder).\n\n'
printf '  After one launch attempt on the device, collect from the card:\n'
printf '    - CONTINUITY_CANARY.txt                      (SD card root)\n'
printf '    - Tools/tg5040/Continuity.pak/canary_pakdir_write.txt\n'
printf '    - .userdata/tg5040/logs/nextui.txt           (hidden folder)\n\n'
