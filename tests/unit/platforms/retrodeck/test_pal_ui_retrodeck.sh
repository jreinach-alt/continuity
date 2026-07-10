#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043,SC2034,SC1090
# Unit tests — Sprint 2.2 pal_ui_* shims for RetroDeck
# (src/platforms/retrodeck/pal_ui_retrodeck.sh).
#
# Backend precedence and all four contract calls, per backend, against
# stub kdialog/zenity binaries (argv recorded, output/rc staged) and
# scripted stdin for the CLI backend. stdout must carry ONLY contract
# values — renders are asserted via the stub logs / stderr captures.
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SHIM="$PROJECT_ROOT/src/platforms/retrodeck/pal_ui_retrodeck.sh"

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

assert_contains() {
    local desc="$1" text="$2" pattern="$3"
    case "$text" in
        *"$pattern"*) passed=$((passed + 1)) ;;
        *) printf 'FAIL: %s\n  text lacks: %s\n  text: %s\n' "$desc" "$pattern" "$text" >&2; failed=$((failed + 1)) ;;
    esac
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub dialog tool: argv recorded (one per line, '---' terminator),
# prints $STUB_OUT when set, exits $STUB_RC (default 0).
make_stub() {
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'EOF'
#!/bin/sh
for a in "$@"; do printf '%s\n' "$a" >> "$STUB_LOG"; done
printf -- '---\n' >> "$STUB_LOG"
if [ -n "${STUB_OUT:-}" ]; then printf '%s\n' "$STUB_OUT"; fi
exit "${STUB_RC:-0}"
EOF
    chmod +x "$1"
}

KD_DIR="$TEST_TMPDIR/kd"
ZEN_DIR="$TEST_TMPDIR/zen"
make_stub "$KD_DIR/kdialog"
make_stub "$ZEN_DIR/zenity"

# =====================================================================
# Backend resolution
# =====================================================================

# --- 1. Forced cli wins regardless of environment ---
out=$(
    CONTINUITY_UI_BACKEND=cli
    . "$SHIM"
    printf '%s' "$RDUI_BACKEND"
)
assert_eq "forced cli" "cli" "$out"

# --- 2. auto + display + kdialog only ---
out=$(
    CONTINUITY_UI_BACKEND=auto DISPLAY=:0
    unset WAYLAND_DISPLAY 2>/dev/null || true
    PATH="$KD_DIR:$PATH"
    export DISPLAY PATH
    . "$SHIM"
    printf '%s' "$RDUI_BACKEND"
) </dev/null
assert_eq "auto: kdialog when present" "kdialog" "$out"

# --- 3. auto + display + zenity only ---
out=$(
    CONTINUITY_UI_BACKEND=auto DISPLAY=:0
    PATH="$ZEN_DIR:$PATH"
    export DISPLAY PATH
    . "$SHIM"
    printf '%s' "$RDUI_BACKEND"
) </dev/null
assert_eq "auto: zenity fallback" "zenity" "$out"

# --- 4. auto + display + both -> kdialog preferred (Plasma first) ---
out=$(
    CONTINUITY_UI_BACKEND=auto DISPLAY=:0
    PATH="$ZEN_DIR:$KD_DIR:$PATH"
    export DISPLAY PATH
    . "$SHIM"
    printf '%s' "$RDUI_BACKEND"
) </dev/null
assert_eq "auto: kdialog preferred over zenity" "kdialog" "$out"

# --- 5. auto + no display + no tty -> none; backend_ok fails NAMED ---
rc=0
err=$(
    {
        CONTINUITY_UI_BACKEND=auto
        unset DISPLAY WAYLAND_DISPLAY 2>/dev/null || true
        PATH="$ZEN_DIR:$KD_DIR:$PATH"
        export PATH
        . "$SHIM"
        printf '%s|' "$RDUI_BACKEND"
        rdui_backend_ok
    } 2>&1
) </dev/null || rc=$?
assert_eq "auto headless: backend_ok refuses" "1" "$rc"
assert_contains "auto headless: backend none" "$err" "none|"
assert_contains "auto headless: named error" "$err" "install kdialog or run from Konsole"

# --- 6. forced kdialog without the tool -> backend_ok fails NAMED ---
rc=0
err=$(
    {
        CONTINUITY_UI_BACKEND=kdialog
        . "$SHIM"
        rdui_backend_ok
    } 2>&1
) </dev/null || rc=$?
assert_eq "forced kdialog missing: refused" "1" "$rc"
assert_contains "forced kdialog missing: named" "$err" "not installed"

# --- 7. unknown value warns and falls through to auto ---
err=$(
    {
        CONTINUITY_UI_BACKEND=gtk4
        unset DISPLAY WAYLAND_DISPLAY 2>/dev/null || true
        . "$SHIM"
    } 2>&1
) </dev/null
assert_contains "unknown backend: named warn" "$err" "unknown CONTINUITY_UI_BACKEND"

# =====================================================================
# pal_ui_menu
# =====================================================================

# --- 8. kdialog menu: selection, tag pairs, title ---
STUB_LOG="$TEST_TMPDIR/kd_menu"; : > "$STUB_LOG"
out=$(
    CONTINUITY_UI_BACKEND=kdialog
    PATH="$KD_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_OUT="1" STUB_RC=0
    export PATH STUB_LOG STUB_OUT STUB_RC
    . "$SHIM"
    pal_ui_menu "Conflicts (2)" "Crystal — a vs b" "Emerald — a vs b"
)
assert_eq "kdialog menu: chosen index" "1" "$out"
log=$(cat "$STUB_LOG")
assert_contains "kdialog menu: --menu used" "$log" "--menu"
assert_contains "kdialog menu: title passed" "$log" "Conflicts (2)"
assert_contains "kdialog menu: item labels intact" "$log" "Crystal — a vs b"

# --- 9. kdialog menu: cancel (rc 1) ---
STUB_LOG="$TEST_TMPDIR/kd_cancel"; : > "$STUB_LOG"
out=$(
    CONTINUITY_UI_BACKEND=kdialog
    PATH="$KD_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_OUT="" STUB_RC=1
    export PATH STUB_LOG STUB_OUT STUB_RC
    . "$SHIM"
    pal_ui_menu "Conflicts" "One"
)
assert_eq "kdialog menu: cancel" "cancel" "$out"

# --- 10. zenity menu: selection via hidden index column ---
STUB_LOG="$TEST_TMPDIR/zen_menu"; : > "$STUB_LOG"
out=$(
    CONTINUITY_UI_BACKEND=zenity
    PATH="$ZEN_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_OUT="0" STUB_RC=0
    export PATH STUB_LOG STUB_OUT STUB_RC
    . "$SHIM"
    pal_ui_menu "Pick" "Item A" "Item B"
)
assert_eq "zenity menu: chosen index" "0" "$out"
log=$(cat "$STUB_LOG")
assert_contains "zenity menu: --list used" "$log" "--list"
assert_contains "zenity menu: index printed back" "$log" "--print-column=1"

# --- 11. zenity menu: cancel rc 1, and OK-with-no-selection ---
STUB_LOG="$TEST_TMPDIR/zen_cancel"; : > "$STUB_LOG"
out=$(
    CONTINUITY_UI_BACKEND=zenity
    PATH="$ZEN_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_OUT="" STUB_RC=1
    export PATH STUB_LOG STUB_OUT STUB_RC
    . "$SHIM"
    pal_ui_menu "Pick" "Item A"
)
assert_eq "zenity menu: cancel on rc 1" "cancel" "$out"
out=$(
    CONTINUITY_UI_BACKEND=zenity
    PATH="$ZEN_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_OUT="" STUB_RC=0
    export PATH STUB_LOG STUB_OUT STUB_RC
    . "$SHIM"
    pal_ui_menu "Pick" "Item A"
)
assert_eq "zenity menu: cancel on empty selection" "cancel" "$out"

# --- 12. cli menu: 1-based input, 0-based return ---
out=$(
    printf '2\n' | {
        CONTINUITY_UI_BACKEND=cli
        . "$SHIM"
        pal_ui_menu "Pick" "Item A" "Item B" "Item C" 2>/dev/null
    }
)
assert_eq "cli menu: choice 2 -> index 1" "1" "$out"

# --- 13. cli menu: invalid inputs re-prompt, then accept ---
errlog="$TEST_TMPDIR/cli_reprompt"
out=$(
    printf 'x\n9\n3\n' | {
        CONTINUITY_UI_BACKEND=cli
        . "$SHIM"
        pal_ui_menu "Pick" "Item A" "Item B" "Item C" 2>"$errlog"
    }
)
assert_eq "cli menu: re-prompt then index 2" "2" "$out"
err=$(cat "$errlog")
assert_contains "cli menu: non-number named" "$err" "Not a number"
assert_contains "cli menu: out-of-range named" "$err" "Out of range"

# --- 14. cli menu: q, empty line, and EOF all cancel ---
out=$(printf 'q\n' | { CONTINUITY_UI_BACKEND=cli; . "$SHIM"; pal_ui_menu "P" "A" 2>/dev/null; })
assert_eq "cli menu: q cancels" "cancel" "$out"
out=$(printf '\n' | { CONTINUITY_UI_BACKEND=cli; . "$SHIM"; pal_ui_menu "P" "A" 2>/dev/null; })
assert_eq "cli menu: empty line cancels" "cancel" "$out"
out=$({ CONTINUITY_UI_BACKEND=cli; . "$SHIM"; pal_ui_menu "P" "A" 2>/dev/null; } </dev/null)
assert_eq "cli menu: EOF cancels" "cancel" "$out"

# --- 15. zero items: cancel without touching any backend ---
out=$({ CONTINUITY_UI_BACKEND=cli; . "$SHIM"; pal_ui_menu "Empty" 2>/dev/null; } </dev/null)
assert_eq "menu with no items: cancel" "cancel" "$out"

# =====================================================================
# pal_ui_confirm
# =====================================================================

# --- 16. kdialog yes/no ---
STUB_LOG="$TEST_TMPDIR/kd_confirm"; : > "$STUB_LOG"
out=$(
    CONTINUITY_UI_BACKEND=kdialog
    PATH="$KD_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_RC=0
    export PATH STUB_LOG STUB_RC
    . "$SHIM"
    pal_ui_confirm "Keep it?"
)
assert_eq "kdialog confirm: yes" "yes" "$out"
assert_contains "kdialog confirm: --yesno used" "$(cat "$STUB_LOG")" "--yesno"
out=$(
    CONTINUITY_UI_BACKEND=kdialog
    PATH="$KD_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_RC=1
    export PATH STUB_LOG STUB_RC
    . "$SHIM"
    pal_ui_confirm "Keep it?"
)
assert_eq "kdialog confirm: no" "no" "$out"

# --- 17. zenity question ---
STUB_LOG="$TEST_TMPDIR/zen_confirm"; : > "$STUB_LOG"
out=$(
    CONTINUITY_UI_BACKEND=zenity
    PATH="$ZEN_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_RC=0
    export PATH STUB_LOG STUB_RC
    . "$SHIM"
    pal_ui_confirm "Keep it?"
)
assert_eq "zenity confirm: yes" "yes" "$out"
assert_contains "zenity confirm: --question used" "$(cat "$STUB_LOG")" "--question"

# --- 18. cli: y -> yes; anything else / EOF -> no (safe default) ---
out=$(printf 'y\n' | { CONTINUITY_UI_BACKEND=cli; . "$SHIM"; pal_ui_confirm "Sure?" 2>/dev/null; })
assert_eq "cli confirm: y" "yes" "$out"
out=$(printf 'n\n' | { CONTINUITY_UI_BACKEND=cli; . "$SHIM"; pal_ui_confirm "Sure?" 2>/dev/null; })
assert_eq "cli confirm: n" "no" "$out"
out=$({ CONTINUITY_UI_BACKEND=cli; . "$SHIM"; pal_ui_confirm "Sure?" 2>/dev/null; } </dev/null)
assert_eq "cli confirm: EOF is no" "no" "$out"

# =====================================================================
# pal_ui_message / pal_ui_handoff
# =====================================================================

# --- 19. kdialog message + handoff use --msgbox ---
STUB_LOG="$TEST_TMPDIR/kd_msg"; : > "$STUB_LOG"
(
    CONTINUITY_UI_BACKEND=kdialog
    PATH="$KD_DIR:$PATH"
    STUB_LOG="$STUB_LOG" STUB_RC=0
    export PATH STUB_LOG STUB_RC
    . "$SHIM"
    pal_ui_message "All synced."
    pal_ui_handoff "Loaded the copy. Go play."
) </dev/null
log=$(cat "$STUB_LOG")
assert_eq "kdialog message+handoff: two dialogs" "2" "$(grep -c -- '^---$' "$STUB_LOG")"
assert_contains "kdialog message: text shown" "$log" "All synced."
assert_contains "kdialog handoff: text shown" "$log" "Loaded the copy. Go play."
assert_contains "kdialog message: --msgbox used" "$log" "--msgbox"

# --- 20. cli message renders to stderr, waits for Enter, EOF ok ---
errlog="$TEST_TMPDIR/cli_msg"
rc=0
(
    CONTINUITY_UI_BACKEND=cli
    . "$SHIM"
    pal_ui_message "All synced." 2>"$errlog"
) </dev/null || rc=$?
assert_eq "cli message: rc 0 on EOF" "0" "$rc"
assert_contains "cli message: rendered on stderr" "$(cat "$errlog")" "All synced."

# --- 21. cli handoff consumes NO input (next read still gets line 1) ---
out=$(
    printf '1\n' | {
        CONTINUITY_UI_BACKEND=cli
        . "$SHIM"
        pal_ui_handoff "Go play." 2>/dev/null
        pal_ui_menu "Pick" "A" "B" 2>/dev/null
    }
)
assert_eq "cli handoff: stdin untouched" "0" "$out"

# --- 22. backend none: safe contract defaults ---
out=$(
    CONTINUITY_UI_BACKEND=auto
    unset DISPLAY WAYLAND_DISPLAY 2>/dev/null || true
    . "$SHIM"
    m=$(pal_ui_menu "P" "A" 2>/dev/null)
    c=$(pal_ui_confirm "Sure?" 2>/dev/null)
    printf '%s|%s' "$m" "$c"
) </dev/null
assert_eq "backend none: cancel|no" "cancel|no" "$out"

printf '\ntest_pal_ui_retrodeck: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ] || exit 1
