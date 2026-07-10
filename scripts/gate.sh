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
        # Skip upstream/ (vendored) and build/ (generated committed
        # artifacts — their scripts are copies of already-linted src/
        # files, and the muOS app's task entries carry spaces in their
        # names, which would break the xargs split below).
        sc_files=$( (git diff --name-only @{upstream}..HEAD 2>/dev/null;                      git diff --name-only HEAD 2>/dev/null;                      git ls-files --others --exclude-standard 2>/dev/null)                    | sort -u | grep '\.sh$'                    | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done                    | grep -Ev '^(upstream|build)/' || true)
        if [ -n "$sc_files" ]; then
            # shellcheck disable=SC2086
            printf '%s\n' "$sc_files" | xargs shellcheck -x --severity=error
        fi
    else
        shellcheck -x --severity=error \
            src/core/*.sh src/platforms/nextui/*.sh src/platforms/muos/*.sh \
            scripts/*.sh \
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

# Shipped-artifact integrity: byte-verify every committed artifact's
# checksums manifest exactly as the device's preflight does. Both the
# NextUI PAK and the muOS app are served by one pinned commit, so a
# publish delivers to the whole fleet — both get verified here.
#   $1 = artifact dir holding checksums.txt (paths relative to it)
verify_artifact_checksums() {
    _va_dir="$1"
    if [ ! -f "$_va_dir/checksums.txt" ]; then
        printf 'skipped (no manifest)\n'
        return 0
    fi
    (
        cd "$_va_dir"
        while IFS=' ' read -r sum size path; do
            [ -n "$path" ] || continue
            actual_size=$(wc -c < "$path")
            actual_sum=$(sha256sum "$path" | cut -d' ' -f1)
            if [ "$actual_size" != "$size" ] || [ "$actual_sum" != "$sum" ]; then
                printf 'MISMATCH: %s\n' "$path" >&2
                exit 1
            fi
        done < checksums.txt
    ) || exit 1
    printf 'ok\n'
}

printf 'gate(full): shipped-PAK integrity... '
verify_artifact_checksums build/Continuity.pak

# The muOS artifact's manifest lives one level in (.continuity/app),
# with paths relative to that app dir — the same layout preflight reads
# on the card.
printf 'gate(full): shipped-muOS-app integrity... '
verify_artifact_checksums build/Continuity-muos.app/.continuity/app

if command -v qemu-aarch64-static >/dev/null 2>&1; then
    if [ -f build/Continuity.pak/bin/busybox ]; then
        printf 'gate(full): busybox validation matrix (PAK)... '
        sh scripts/validate_busybox.sh build/Continuity.pak/bin/busybox >/dev/null
        printf 'ok\n'
    fi
    if [ -f build/Continuity.pak/bin/git ]; then
        printf 'gate(full): bundled git under qemu (PAK)... '
        qemu-aarch64-static build/Continuity.pak/bin/git --version >/dev/null
        printf 'ok\n'
    fi
    # The muOS app ships the same binary class — smoke it too when present
    # (it is byte-identical to the PAK's by build-time byte-compare, but
    # the artifact is committed separately, so verify what actually ships).
    if [ -f build/Continuity-muos.app/.continuity/app/bin/busybox ]; then
        printf 'gate(full): busybox validation matrix (muOS)... '
        sh scripts/validate_busybox.sh build/Continuity-muos.app/.continuity/app/bin/busybox >/dev/null
        printf 'ok\n'
    fi
    if [ -f build/Continuity-muos.app/.continuity/app/bin/git ]; then
        printf 'gate(full): bundled git under qemu (muOS)... '
        qemu-aarch64-static build/Continuity-muos.app/.continuity/app/bin/git --version >/dev/null
        printf 'ok\n'
    fi
else
    printf 'gate(full): qemu checks skipped (qemu-aarch64-static missing)\n' >&2
fi

printf 'gate(full): PASSED\n'
