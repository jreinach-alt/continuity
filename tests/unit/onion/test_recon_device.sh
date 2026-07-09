#!/bin/sh
# shellcheck shell=ash  # BusyBox ash target — local is supported
# shellcheck disable=SC3043
# Unit tests for src/platforms/onion/recon_device.sh (Sprint 3.1 recon).
set -e

TESTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
RECON="$PROJECT_ROOT/src/platforms/onion/recon_device.sh"

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

assert_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s does not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

assert_not_contains() {
    local desc filepath needle
    desc="$1"; filepath="$2"; needle="$3"
    if ! grep -qF -e "$needle" "$filepath" 2>/dev/null; then
        passed=$((passed + 1))
    else
        printf 'FAIL: %s\n  %s should not contain: %s\n' "$desc" "$filepath" "$needle" >&2
        failed=$((failed + 1))
    fi
}

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# --- ELF classifier (functions sourced, no main) ---

RC_NO_MAIN=1
RC_OUT="$TEST_TMPDIR/unused.txt"
# shellcheck disable=SC1090
. "$RECON"

mk_elf() {
    # mk_elf <path> <class> <machine_lo> <machine_hi>
    # 20-byte ELF header prefix: magic, class, LE, then e_machine at 18-19.
    local path class mlo mhi
    path="$1"; class="$2"; mlo="$3"; mhi="$4"
    printf '\177ELF' > "$path"
    # class, data(LE), version, padding to byte 16, type(2), machine
    printf "\\$(printf '%03o' "$class")" >> "$path"
    printf '\001\001\000\000\000\000\000\000\000\000\000' >> "$path"
    printf '\002\000' >> "$path"
    printf "\\$(printf '%03o' "$mlo")\\$(printf '%03o' "$mhi")" >> "$path"
}

mk_elf "$TEST_TMPDIR/aarch64.bin" 2 183 0
assert_eq "aarch64 ELF classified" "ELF64 LE aarch64" "$(rc_elf_desc "$TEST_TMPDIR/aarch64.bin")"

mk_elf "$TEST_TMPDIR/arm32.bin" 1 40 0
assert_eq "arm32 ELF classified" "ELF32 LE arm32" "$(rc_elf_desc "$TEST_TMPDIR/arm32.bin")"

printf '#!/bin/sh\ntrue makes this file exceed twenty bytes\n' > "$TEST_TMPDIR/script.sh"
assert_eq "script classified as not ELF" "not ELF (script or data)" "$(rc_elf_desc "$TEST_TMPDIR/script.sh")"

assert_eq "missing file" "unreadable" "$(rc_elf_desc "$TEST_TMPDIR/nope.bin")"

printf 'tiny' > "$TEST_TMPDIR/tiny.bin"
assert_eq "tiny file" "short/unknown (od limited or tiny file)" "$(rc_elf_desc "$TEST_TMPDIR/tiny.bin")"

# Octal od fallback must classify identically (minimal busybox od path).
assert_eq "aarch64 via od -b fallback" "ELF64 LE aarch64" "$(RC_FORCE_OD_B=1 rc_elf_desc "$TEST_TMPDIR/aarch64.bin")"
# In ash, an assignment prefixing a FUNCTION call persists — clear it.
unset RC_FORCE_OD_B

# --- RZIP magic detector ---

printf '#RZIPv\001#payload' > "$TEST_TMPDIR/comp.srm"
printf '\000\000\000\000rawdata' > "$TEST_TMPDIR/raw.srm"
if rc_is_rzip "$TEST_TMPDIR/comp.srm"; then passed=$((passed + 1)); else
    printf 'FAIL: rzip magic detected\n' >&2; failed=$((failed + 1)); fi
if ! rc_is_rzip "$TEST_TMPDIR/raw.srm"; then passed=$((passed + 1)); else
    printf 'FAIL: raw save not rzip\n' >&2; failed=$((failed + 1)); fi

# --- Full run against a fixture SD tree ---

SD="$TEST_TMPDIR/sd"
mkdir -p "$SD/Saves/CurrentProfile/saves/gambatte" "$SD/.tmp_update" \
         "$SD/RetroArch/.retroarch"
printf '\000\000save' > "$SD/Saves/CurrentProfile/saves/gambatte/Links Awakening (USA).srm"
printf '#RZIPv\001#x' > "$SD/Saves/CurrentProfile/saves/gambatte/Compressed Game.sav"
printf 'v4.3.1-test\n' > "$SD/.tmp_update/version.txt"
{
    printf 'savefile_directory = "~/.retroarch/saves"\n'
    printf 'sort_savefiles_enable = "true"\n'
} > "$SD/RetroArch/.retroarch/retroarch.cfg"
{
    printf '{\n  "repo_url": "https://github.com/u/saves",\n'
    printf '  "device_name": "my-rg40xx",\n  "pat": "github_pat_SECRETSECRET"\n}\n'
} > "$SD/setup.json"

REPORT="$TEST_TMPDIR/report.txt"
before=$(find "$SD" | sort)
rc=0
RC_OUT="$REPORT" RC_SD_ROOT="$SD" RC_NET=0 busybox ash "$RECON" >/dev/null 2>&1 || rc=$?
after=$(find "$SD" | sort)

assert_eq "recon exits 0" "0" "$rc"
assert_eq "no artifacts left in SD tree" "$before" "$after"
assert_contains "header present" "$REPORT" "Continuity device recon"
assert_contains "gate-0 section present" "$REPORT" "=== firmware identity (Gate 0) ==="
assert_contains "exec-semantics section present" "$REPORT" "=== exec semantics on SD (Fable core) ==="
assert_contains "tmp_update marker seen" "$REPORT" "marker: $SD/.tmp_update EXISTS"
assert_contains "onion version file dumped" "$REPORT" "v4.3.1-test"
assert_contains "real save found" "$REPORT" "Links Awakening (USA).srm"
assert_contains "rzip save flagged" "$REPORT" "rzip: yes"
assert_contains "raw save byte-dumped" "$REPORT" "rzip: no bytes:"
assert_contains "retroarch keys captured" "$REPORT" "sort_savefiles_enable"
assert_contains "network probes skippable" "$REPORT" "network probes skipped (RC_NET=0)"
assert_contains "setup.json PAT masked to length" "$REPORT" "pat=present(23 chars)"
assert_not_contains "PAT value never in report" "$REPORT" "SECRETSECRET"
assert_contains "completion marker" "$REPORT" "=== recon complete ==="

# Second run overwrites (fresh report, not append)
RC_OUT="$REPORT" RC_SD_ROOT="$SD" RC_NET=0 busybox ash "$RECON" >/dev/null 2>&1 || true
assert_eq "report overwritten, single header" "1" "$(grep -c 'Continuity device recon' "$REPORT")"

# Default output path lands at SD root when RC_OUT unset
RC_SD_ROOT="$SD" RC_NET=0 busybox ash "$RECON" >/dev/null 2>&1 || true
if [ -s "$SD/CONTINUITY_RECON.txt" ]; then passed=$((passed + 1)); else
    printf 'FAIL: default report at SD root\n' >&2; failed=$((failed + 1)); fi
rm -f "$SD/CONTINUITY_RECON.txt"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
