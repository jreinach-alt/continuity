#!/bin/sh
# Continuity quality gate — tiered so the everyday push loop stays
# fast while consequential moments get the full treatment.
#
#   gate.sh fast   ~15s: CRLF scan + shellcheck error gate.
#                  Default for ordinary pushes (checkpoints on the dev
#                  branch — nothing consumes them automatically).
#   gate.sh full   ~4min: fast + full suite as current user + full
#                  suite UNPRIVILEGED (root-only-skipped branches once
#                  hid a real bug; nobody's read-only repo is stricter
#                  than any CI runner) + shipped-PAK integrity
#                  (checksums byte-verify, busybox 69-check matrix,
#                  bundled git under qemu).
#
# FULL is required — and automated — at the moments a mistake actually
# travels: a push whose range touches build/Continuity.pak (pre-merge,
# the device's legacy OTA channel follows the branch head), a channel
# publish (publish_channel.sh runs it), PR creation/update, and
# session closeout (CLAUDE.md protocol).
set -e

TIER="${1:-full}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

printf 'gate(%s): CRLF scan... ' "$TIER"
cr=$(printf '\r')
bad=$(git ls-files -- '*.sh' '*.json' '*.md' '*.txt' ':!:upstream/**' \
      | while IFS= read -r f; do
            [ -f "$f" ] && grep -l "$cr" "$f" 2>/dev/null || true
        done)
if [ -n "$bad" ]; then
    printf 'FAIL\nCRLF line endings in:\n%s\n' "$bad" >&2
    exit 1
fi
printf 'ok\n'

printf 'gate(%s): shellcheck (error gate)... ' "$TIER"
if command -v shellcheck >/dev/null 2>&1; then
    if [ "$TIER" = "fast" ]; then
        # Fast tier lints only the outgoing delta (upstream..HEAD plus
        # any uncommitted edits) — the full tier re-lints everything.
        sc_files=$( (git diff --name-only @{upstream}..HEAD 2>/dev/null;                      git diff --name-only HEAD 2>/dev/null;                      git ls-files --others --exclude-standard 2>/dev/null)                    | sort -u | grep '\.sh$'                    | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done                    | grep -v '^upstream/' || true)
        if [ -n "$sc_files" ]; then
            # shellcheck disable=SC2086
            printf '%s\n' "$sc_files" | xargs shellcheck -x --severity=error
        fi
    else
        shellcheck -x --severity=error \
            src/core/*.sh src/platforms/nextui/*.sh scripts/*.sh \
            tools/saves-repo/*.sh .githooks/pre-push \
            tests/unit/*/*.sh tests/integration/*.sh tests/fixtures/*.sh
    fi
    printf 'ok\n'
else
    printf 'FAIL (shellcheck not installed — Startup Step 2 installs it)\n' >&2
    exit 1
fi

if [ "$TIER" = "fast" ]; then
    printf 'gate(fast): PASSED (full gate runs at PAK push / publish / PR / closeout)\n'
    exit 0
fi

printf 'gate(full): test suite (current user)...\n'
sh scripts/test.sh

if [ "$(id -u)" -eq 0 ] && command -v setpriv >/dev/null 2>&1; then
    printf 'gate(full): test suite (unprivileged)...\n'
    NR_TMP=$(mktemp -d /tmp/continuity-gate.XXXXXX)
    chmod 777 "$NR_TMP"
    nr_rc=0
    setpriv --reuid=65534 --regid=65534 --clear-groups \
        env HOME="$NR_TMP" TMPDIR="$NR_TMP" \
        sh scripts/test.sh > "$NR_TMP/out" 2>&1 || nr_rc=$?
    if [ "$nr_rc" -ne 0 ]; then
        printf 'gate(full): UNPRIVILEGED suite FAILED:\n' >&2
        tail -40 "$NR_TMP/out" >&2
        rm -rf "$NR_TMP"
        exit 1
    fi
    tail -1 "$NR_TMP/out"
    rm -rf "$NR_TMP"
else
    printf 'gate(full): unprivileged pass skipped (not root or setpriv missing)\n' >&2
fi

printf 'gate(full): shipped-PAK integrity... '
if [ -f build/Continuity.pak/checksums.txt ]; then
    (
        cd build/Continuity.pak
        while IFS=' ' read -r sum size path; do
            [ -n "$path" ] || continue
            actual_size=$(wc -c < "$path")
            actual_sum=$(sha256sum "$path" | cut -d' ' -f1)
            if [ "$actual_size" != "$size" ] || [ "$actual_sum" != "$sum" ]; then
                printf 'MISMATCH: %s\n' "$path" >&2
                exit 1
            fi
        done < checksums.txt
    )
    printf 'ok\n'
else
    printf 'skipped (no manifest)\n'
fi

if command -v qemu-aarch64-static >/dev/null 2>&1; then
    if [ -f build/Continuity.pak/bin/busybox ]; then
        printf 'gate(full): busybox validation matrix... '
        sh scripts/validate_busybox.sh build/Continuity.pak/bin/busybox >/dev/null
        printf 'ok\n'
    fi
    if [ -f build/Continuity.pak/bin/git ]; then
        printf 'gate(full): bundled git under qemu... '
        qemu-aarch64-static build/Continuity.pak/bin/git --version >/dev/null
        printf 'ok\n'
    fi
else
    printf 'gate(full): qemu checks skipped (qemu-aarch64-static missing)\n' >&2
fi

printf 'gate(full): PASSED\n'
