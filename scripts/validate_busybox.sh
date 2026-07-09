#!/bin/sh
# Validate the vendored aarch64 busybox under qemu-aarch64-static.
#
# Three layers, mirroring how standalone ash dispatches on the device:
#   1. DIRECT: `busybox <applet> ...` for every invocation form the
#      daemon-path code uses — validates the vendored implementations.
#   2. IN-PROCESS TIER: NOEXEC/NOFORK applets must run from standalone
#      ash with PATH emptied — validates the pinning machinery.
#   3. EXEC TIER: plain applets (grep/sed/tr/cat/cmp/wc/...) self-exec
#      via /proc/self/exe on the device (native, works); under qemu
#      (no binfmt — forbidden) that exec ENOEXECs and busybox must FALL
#      BACK to PATH — validates the applet-level fail-open.
set -u

BB="$1"
# The script cd's around during the matrix — a relative binary path
# would silently stop resolving after the first cd (every later check
# fails "not found"; field-found on the CI runner, which passes the
# repo-relative path).
case "$BB" in
    /*) ;;
    *)  BB="$(pwd)/$BB" ;;
esac
Q="qemu-aarch64-static"
W=$(mktemp -d)
trap 'cd /; rm -rf "$W"' EXIT
pass=0; fail=0

ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$1" >&2; }
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok; else bad "$desc"; fi; }

# ── binary basics ────────────────────────────────────────────────────
check "busybox runs (true)"        $Q "$BB" true
check "ash -c true"                $Q "$BB" ash -c 'true'
if $Q "$BB" ash -c 'echo probe' 2>&1 | grep -q probe; then ok; else bad "ash echo"; fi

# ── layer 1: DIRECT — the load-bearing invocation forms ─────────────
# porcelain-fix extension match (BRE alternation) incl. spaced/apostrophe names
printf 'SFC/Super Metroid (USA).srm\ngba/minish.sav\nstates/SFC-snes9x/Zelda'"'"'s.st0\nnotes.txt\n' > "$W/paths"
n=$($Q "$BB" grep -c '\.\(srm\|sav\|st[0-9]\)$' "$W/paths" 2>/dev/null)
[ "$n" = "3" ] && ok || bad "grep BRE alternation (got: ${n:-none})"
check "grep -q"                    sh -c "printf 'needle\n' | $Q '$BB' grep -q needle"
check "grep -qF -e --leading"      sh -c "printf -- '--weird\n' | $Q '$BB' grep -qF -e '--weird'"
n=$(printf 'a\nb\nc\n' | $Q "$BB" grep -c '.' 2>/dev/null)
[ "$n" = "3" ] && ok || bad "grep -c ."
n=$(printf 'one\0two\0' | $Q "$BB" tr '\0' '\n' 2>/dev/null | grep -c .)
[ "$n" = "2" ] && ok || bad "tr NUL handling (got: ${n:-none})"
out=$(printf 'XY /repo/gb/file.srm\n' | $Q "$BB" sed 's/^...//' 2>/dev/null)
[ "$out" = "/repo/gb/file.srm" ] && ok || bad "sed strip-3 (porcelain prefix)"
out=$(printf '/repo/dir/f.srm\n' | $Q "$BB" sed 's|^/repo/||' 2>/dev/null)
[ "$out" = "dir/f.srm" ] && ok || bad "sed pipe-delimited prefix strip"
out=$(printf 'a_b\n' | $Q "$BB" sed 's/_/-/g' 2>/dev/null)
[ "$out" = "a-b" ] && ok || bad "sed s///g"

mkdir -p "$W/saves/SFC" "$W/repo/.git/x"
printf s > "$W/saves/SFC/Super Metroid (USA).srm"
printf v > "$W/saves/SFC/game.sav"
printf t > "$W/saves/SFC/notes.txt"
touch -d '2001-01-01' "$W/sentinel" 2>/dev/null || touch "$W/sentinel"
n=$($Q "$BB" find "$W/saves" \( -name "*.srm" -o -name "*.sav" \) -newer "$W/sentinel" 2>/dev/null | grep -c .)
[ "$n" = "2" ] && ok || bad "find grouped -name -o -newer (got: ${n:-none})"
printf g > "$W/repo/.git/x/f.srm"
printf r > "$W/repo/real.srm"
n=$($Q "$BB" find "$W/repo" -name "*.srm" ! -path "*/.git/*" 2>/dev/null | grep -c .)
[ "$n" = "1" ] && ok || bad "find ! -path exclusion (got: ${n:-none})"
n=$($Q "$BB" find "$W/saves" -name "*.st[0-9]" 2>/dev/null | wc -l)
[ "$n" = "0" ] && ok || bad "find -name char class"

check "cmp -s equal"               sh -c "printf a > '$W/f1'; printf a > '$W/f2'; $Q '$BB' cmp -s '$W/f1' '$W/f2'"
if $Q "$BB" cmp -s "$W/f1" "$W/saves/SFC/notes.txt" 2>/dev/null; then bad "cmp -s differs"; else ok; fi
d=$($Q "$BB" mktemp -d "$W/mt.XXXXXX" 2>/dev/null); [ -d "$d" ] && ok || bad "mktemp -d TEMPLATE"
f=$($Q "$BB" mktemp "$W/mf.XXXXXX" 2>/dev/null);   [ -f "$f" ] && ok || bad "mktemp TEMPLATE"
check "mkdir -p nested"            $Q "$BB" mkdir -p "$W/a/b/c"
check "cp"                         $Q "$BB" cp "$W/f1" "$W/a/b/c/f1"
check "mv"                         $Q "$BB" mv "$W/a/b/c/f1" "$W/a/b/c/f1m"
check "rm -rf"                     $Q "$BB" rm -rf "$W/a"
check "touch"                      $Q "$BB" touch "$W/touched"
check "sync"                       $Q "$BB" sync
check "chmod +x"                   $Q "$BB" chmod +x "$W/touched"
out=$($Q "$BB" dirname "/x/y/z.srm"); [ "$out" = "/x/y" ] && ok || bad "dirname"
out=$($Q "$BB" basename "/x/y/z.srm"); [ "$out" = "z.srm" ] && ok || bad "basename"
n=$(printf 'abcde' | $Q "$BB" wc -c); [ "$n" -eq 5 ] && ok || bad "wc -c"
out=$(printf 'a b c\n' | $Q "$BB" cut -d' ' -f2); [ "$out" = "b" ] && ok || bad "cut -d -f"
out=$(printf 'abcdefgh\n' | $Q "$BB" cut -c1-3); [ "$out" = "abc" ] && ok || bad "cut -c range"
out=$(printf '1\n2\n3\n4\n' | $Q "$BB" head -2 | wc -l); [ "$out" -eq 2 ] && ok || bad "head -N"
check "cat"                        $Q "$BB" cat "$W/f1"
$Q "$BB" date '+%Y-%m-%d %H:%M:%S' 2>/dev/null | grep -qE '^20[0-9]{2}-' && ok || bad "date +fmt"
$Q "$BB" date '+%s' 2>/dev/null | grep -qE '^[0-9]+$' && ok || bad "date +%s"
check "sleep 0 (integer)"          $Q "$BB" sleep 0
check "sleep 0.1 (fractional)"     $Q "$BB" sleep 0.1
# ping needs a raw socket: root-only. The device runs everything as
# root; CI runners do not — so assert flag PARSING here (a permission
# error is acceptable, a usage error is not), same pattern as wget.
pout=$($Q "$BB" ping -c 1 -W 3 127.0.0.1 2>&1); prc=$?
if [ $prc -eq 0 ] || ! printf '%s' "$pout" | grep -qi 'usage\|invalid\|bad option'; then ok; else bad "ping -c 1 -W 3 flags (rc=$prc out=$pout)"; fi
wout=$($Q "$BB" wget --spider -q -T 3 https://127.0.0.1:1 2>&1); wrc=$?
if [ $wrc -ne 0 ] && ! printf '%s' "$wout" | grep -qi 'usage\|unrecognized\|bad option'; then ok; else bad "wget --spider -q -T flags (rc=$wrc)"; fi
h=$(printf 'x' | $Q "$BB" sha256sum | cut -d' ' -f1)
[ "$h" = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881" ] && ok || bad "sha256sum digest"
# enrollment-UI forms (device-sh path today, but keep the door open)
out=$(printf 'ab' | $Q "$BB" dd bs=8 count=1 2>/dev/null); [ "$out" = "ab" ] && ok || bad "dd bs=8 count=1"
printf '\001\002' | $Q "$BB" od -An -tu1 2>/dev/null | grep -q '1  *2' && ok || bad "od -An -tu1"

# ── layer 2: IN-PROCESS TIER (NOEXEC/NOFORK under empty PATH) ───────
inproc() { desc="$1"; shift; if $Q "$BB" ash -c "PATH=/nonexistent; $*" >/dev/null 2>&1; then ok; else bad "in-process: $desc"; fi; }
cd "$W"
inproc "find"      "find . -name 'f1'"
inproc "cut"       "printf 'a b\n' | cut -d' ' -f1"
inproc "head"      "head -1 paths"
inproc "date"      "date '+%Y'"
inproc "rm/cp/mv"  "cp f1 ip1; mv ip1 ip2; rm ip2"
inproc "mktemp"    "t=\$(mktemp ./ip.XXXXXX) && rm \"\$t\""
inproc "mkdir -p"  "mkdir -p ipd/ipd2 && rm -rf ipd"
inproc "touch"     "touch ipt && rm ipt"
inproc "sync"      "sync"
inproc "chmod"     "touch ipc; chmod +x ipc; rm ipc"
inproc "sha256sum" "printf x | sha256sum"
inproc "dirname"   "dirname /a/b"
inproc "basename"  "basename /a/b"
cd /

# ── layer 3: EXEC TIER falls back to PATH when self-exec fails ──────
# Under qemu the /proc/self/exe re-exec ENOEXECs (no binfmt, by policy);
# busybox must fall through to PATH lookup. Host tools stand in for the
# device's own busybox here.
fb() { desc="$1"; shift; if $Q "$BB" ash -c "$*" >/dev/null 2>&1; then ok; else bad "PATH-fallback: $desc"; fi; }
fb "grep"  "printf 'a\n' | grep -q a"
fb "sed"   "printf 'x\n' | sed s/x/y/"
fb "tr"    "printf 'a\0' | tr '\\\\0' '\n'"
fb "cat"   "printf hi | cat"
fb "cmp"   "cmp -s '$W/f1' '$W/f2'"
fb "wc"    "printf abc | wc -c"
fb "sleep" "sleep 0"

# absolute paths must exec the real file (git must NOT be shadowed)
printf '#!/bin/sh\necho realfile\n' > "$W/realbin"; chmod +x "$W/realbin"
if $Q "$BB" ash -c "'$W/realbin'" 2>/dev/null | grep -q realfile; then ok; else bad "absolute path exec passthrough"; fi

# ── ash semantics the daemon leans on ───────────────────────────────
check "ash: trap TERM + bg sleep + wait" $Q "$BB" ash -c 'trap "exit 0" TERM; sleep 0.1 & wait $! || true; exit 0'
check "ash: set -e with guarded rc"      $Q "$BB" ash -c 'set -e; f(){ return 3; }; rc=0; f || rc=$?; [ $rc -eq 3 ]'
check "ash: local in function"           $Q "$BB" ash -c 'f(){ local v; v=7; [ "$v" = 7 ]; }; f'
check "ash: read -r loop"                $Q "$BB" ash -c 'printf "a b\nc\n" | while IFS= read -r l; do [ -n "$l" ]; done'
check 'ash: cmd-subst nesting'           $Q "$BB" ash -c 'v=$(dirname "$(printf /a/b/c)"); [ "$v" = /a/b ]'
check "ash: kill -0 self"                $Q "$BB" ash -c 'kill -0 $$'
check "ash: exec builtin replaces"       $Q "$BB" ash -c 'exec true'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
