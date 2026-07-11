#!/bin/sh
# Continuity — Daijisho config extraction (issue #14 mapping-seed recon)
#
# Daijisho has NO local settings export (its backup/restore is Google
# Drive-only — off-limits per the project's no-cloud-OAuth tenet) and
# is closed-source with an undocumented schema, so this script goes
# after the app's SQLite database directly and dumps WHATEVER schema it
# finds — the dump is evidence for designing the #14 mapping seed
# (platforms, players/cores, sync paths), not production parsing.
#
# Strategy ladder (each rung is probed; a locked door is a FINDING,
# not a crash):
#   A. App-external storage (/storage/.../Android/data|media/<pkg>) —
#      normally scoped-storage-restricted, but the Thor's adb build
#      demonstrably reads RetroArch's Android/data, so probe first.
#   B. `adb backup` — deprecated; on Android 12+ most apps yield an
#      empty archive, but it costs one tap to try. Requires the
#      on-device confirmation ("Back up my data", leave password
#      EMPTY).
#   C. Root (`su`) — copies the databases dir out of
#      /data/data/<pkg>/. Only if the device is rooted.
#
# Read-only posture: nothing of Daijisho's is modified. Rung C (only)
# writes a TEMPORARY copy under /sdcard/Download/ on the device and
# removes it after pulling — declared here because deck_recon-class
# scripts promise zero device writes.
#
# Run on a PC with adb + python3 (stdlib only: zlib/tarfile/sqlite3):
#   sh daijisho_db_recon.sh
# Outputs:
#   CONTINUITY_DAIJISHO_DUMP.txt   — the report (send back / attach to #14)
#   ./daijisho_db/                 — recovered .db/.json files (attach too)
# Env overrides: CONTINUITY_DJ_PKG (default com.magneticchen.daijishou),
#   CONTINUITY_RECON_OUT (report path).
#
# POSIX sh so the file parses under the test-suite interpreter.
set -u

report="${CONTINUITY_RECON_OUT:-./CONTINUITY_DAIJISHO_DUMP.txt}"
outdir="./daijisho_db"
pkg="${CONTINUITY_DJ_PKG:-com.magneticchen.daijishou}"
workdir="${TMPDIR:-/tmp}/continuity_dj_recon.$$"

out() { printf '%s\n' "$*" >>"$report"; }
section() { out ""; out "== $* =="; }

# adb with stdin starved — adb slurps a caller's stdin and empties
# any while-read loop feeding it (field-found in thor_recon.sh).
run_dev() { adb shell "$1" </dev/null 2>/dev/null | tr -d '\r'; }

: >"$report"
mkdir -p "$outdir" "$workdir"
trap 'rm -rf "$workdir"' EXIT

out "Continuity Daijisho DB recon — $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"

# --- Prerequisites ----------------------------------------------------
section "Prerequisites"
if ! command -v adb >/dev/null 2>&1; then
    out "adb: NOT FOUND on this PC — install platform-tools (or symlink the Windows adb.exe into WSL, see thor_recon.sh header)"
    printf 'Wrote %s (adb missing)\n' "$report"; cat "$report"; exit 0
fi
state=$(adb get-state 2>/dev/null | tr -d '\r')
out "adb state: ${state:-no device}"
if [ "${state:-}" != "device" ]; then
    printf 'Wrote %s (no device — connect the Thor, enable USB debugging)\n' "$report"; cat "$report"; exit 0
fi
if command -v python3 >/dev/null 2>&1; then
    out "python3: $(command -v python3) ($(python3 --version 2>&1))"
else
    out "python3: NOT FOUND — required for backup unpack + sqlite dump (apt install python3)"
    printf 'Wrote %s (python3 missing)\n' "$report"; cat "$report"; exit 0
fi

section "Daijisho package"
found=$(run_dev 'pm list packages' | sed -n 's/^package://p' | grep -x "$pkg" || true)
if [ -z "$found" ]; then
    out "$pkg: NOT INSTALLED (override with CONTINUITY_DJ_PKG if the id differs)"
    out "candidates on device:"
    run_dev 'pm list packages' | sed -n 's/^package://p' | grep -i 'daiji\|magneticchen' | while IFS= read -r p; do
        [ -n "$p" ] && out "  $p"
    done
    printf 'Wrote %s\n' "$report"; cat "$report"; exit 0
fi
ver=$(run_dev "dumpsys package $pkg" | sed -n 's/^ *versionName=//p' | head -1)
out "$pkg installed (versionName ${ver:-unknown})"

# --- Rung A: app-external storage --------------------------------------
section "Rung A — app-external storage probe"
got_a=0
for base in "/storage/emulated/0/Android/data/$pkg" "/storage/emulated/0/Android/media/$pkg"; do
    listing=$(run_dev "find \"$base\" -maxdepth 4 -type f 2>/dev/null" | head -60)
    if [ -n "$listing" ]; then
        out "$base: readable — files:"
        printf '%s\n' "$listing" | while IFS= read -r f; do
            [ -n "$f" ] && out "  $f"
        done
        # Pull anything that looks like config/database (small files only).
        printf '%s\n' "$listing" | grep -i '\.db$\|\.db-wal$\|\.db-shm$\|\.sqlite$\|\.json$' | while IFS= read -r f; do
            [ -z "$f" ] && continue
            adb pull "$f" "$outdir/" >/dev/null 2>&1 </dev/null && out "  PULLED: $f"
        done
        got_a=1
    else
        out "$base: not readable / empty (expected under scoped storage — Room DBs default to internal storage anyway)"
    fi
done
[ "$got_a" -eq 1 ] || out "rung A result: nothing recovered"

# --- Rung B: adb backup -------------------------------------------------
section "Rung B — adb backup (deprecated mechanism; needs one on-device tap)"
printf '\n>>> On the Thor: a "Full backup" screen should appear.\n>>> Leave the password EMPTY and tap "Back up my data".\n>>> (If no screen appears within ~15s, the mechanism is disabled — fine, rung C next.)\n\n'
adb backup -f "$workdir/dj.ab" "$pkg" </dev/null >/dev/null 2>&1 || true
absize=$(wc -c <"$workdir/dj.ab" 2>/dev/null | tr -d ' ') ; absize=${absize:-0}
out "backup archive size: $absize bytes"
if [ "$absize" -gt 1024 ]; then
    python3 - "$workdir/dj.ab" "$workdir/ab_extract" <<'PYEOF' >>"$report" 2>&1 || true
import io, sys, os, zlib, tarfile
ab_path, dest = sys.argv[1], sys.argv[2]
with open(ab_path, "rb") as f:
    magic = f.readline()
    if magic.strip() != b"ANDROID BACKUP":
        print(f"ab: unexpected magic {magic!r} — not an adb backup archive"); sys.exit(0)
    version = f.readline().strip().decode()
    compressed = f.readline().strip() == b"1"
    encryption = f.readline().strip().decode()
    print(f"ab: version={version} compressed={compressed} encryption={encryption}")
    if encryption != "none":
        print("ab: archive is ENCRYPTED — re-run and leave the password empty"); sys.exit(0)
    payload = f.read()
if compressed:
    d = zlib.decompressobj()
    payload = d.decompress(payload) + d.flush()
os.makedirs(dest, exist_ok=True)
n = 0
with tarfile.open(fileobj=io.BytesIO(payload)) as tar:
    for m in tar.getmembers():
        parts = m.name.split("/")
        if m.name.startswith("/") or ".." in parts or not m.isfile():
            continue
        tar.extract(m, dest)
        n += 1
print(f"ab: extracted {n} file(s)")
PYEOF
    # Collect databases/config from the extracted tree.
    find "$workdir/ab_extract" -type f \( -name '*.db' -o -name '*.db-wal' -o -name '*.db-shm' -o -name '*.sqlite' -o -name '*.json' -o -name '*.xml' \) 2>/dev/null | while IFS= read -r f; do
        cp "$f" "$outdir/" 2>/dev/null && out "  RECOVERED from backup: ${f#"$workdir"/ab_extract/}"
    done
else
    out "rung B result: empty/trivial archive — the app does not opt in to adb backup on this Android version (the common case on 12+)"
fi

# --- Rung C: root -------------------------------------------------------
section "Rung C — root probe"
suid=$(run_dev 'su -c id' | head -1)
case "$suid" in
    *uid=0*)
        out "root: AVAILABLE ($suid)"
        dblist=$(run_dev "su -c 'ls /data/data/$pkg/databases 2>/dev/null'")
        if [ -n "$dblist" ]; then
            out "databases dir:"
            printf '%s\n' "$dblist" | while IFS= read -r f; do
                [ -n "$f" ] && out "  $f"
            done
            # Temp copy on shared storage (declared write), pull, clean up.
            tmpdev="/sdcard/Download/.continuity_dj_tmp"
            run_dev "su -c 'rm -rf $tmpdev && mkdir -p $tmpdev && cp /data/data/$pkg/databases/* $tmpdev/ && chmod 644 $tmpdev/*'" >/dev/null
            run_dev "ls \"$tmpdev\"" | while IFS= read -r f; do
                [ -z "$f" ] && continue
                adb pull "$tmpdev/$f" "$outdir/" >/dev/null 2>&1 </dev/null && out "  PULLED: $f"
            done
            run_dev "su -c 'rm -rf $tmpdev'" >/dev/null
            out "  (device temp copy removed)"
        else
            out "databases dir empty/unreadable even with root — check /data/data/$pkg layout manually"
        fi
        ;;
    *)
        out "root: not available (expected on a stock Thor) — rung C skipped"
        ;;
esac

# --- Schema-agnostic dump ----------------------------------------------
section "SQLite dump (schema discovery)"
dbcount=$(find "$outdir" -maxdepth 1 -type f \( -name '*.db' -o -name '*.sqlite' \) 2>/dev/null | grep -c . || true)
if [ "${dbcount:-0}" -eq 0 ]; then
    out "no database recovered by any rung."
    out "FALLBACK SEEDS for #14 (no device access needed): the ES-DE dir"
    out "parse (thor_recon.sh frontend section) + matching folder names"
    out "against the community platform JSONs (TapiocaFox/Daijishou-"
    out "Platforms) that Daijisho users imported in the first place."
else
    find "$outdir" -maxdepth 1 -type f \( -name '*.db' -o -name '*.sqlite' \) | sort | while IFS= read -r db; do
        out ""
        out "--- $db ---"
        python3 - "$db" <<'PYEOF' >>"$report" 2>&1 || true
import json, sys, sqlite3
path = sys.argv[1]
def render(v, cap=2000):
    if isinstance(v, bytes):
        return f"<blob {len(v)} bytes: {v[:32].hex()}...>"
    s = v if isinstance(v, str) else v
    if isinstance(s, str) and len(s) > cap:
        return s[:cap] + f"...<+{len(s)-cap} chars>"
    return s
conn = None
for uri in (f"file:{path}?mode=ro", f"file:{path}?immutable=1"):
    try:
        conn = sqlite3.connect(uri, uri=True); conn.execute("select 1"); break
    except Exception as e:
        print(f"open {uri}: {e}"); conn = None
if conn is None:
    sys.exit(0)
rows = conn.execute("select name, sql from sqlite_master where type='table' order by name").fetchall()
names = [r[0] for r in rows]
print(f"tables ({len(names)}): {', '.join(names)}")
print()
print("-- schema --")
for name, sql in rows:
    print((sql or "").strip() + ";")
# Interesting tables first (platform/player/path/setting-ish), then the rest.
KEY = ("platform", "player", "path", "setting", "sync", "emulat", "core")
ordered = sorted(names, key=lambda n: (not any(k in n.lower() for k in KEY), n))
CAP = 500
for name in ordered:
    try:
        cnt = conn.execute(f'select count(*) from "{name}"').fetchone()[0]
    except Exception as e:
        print(f"\n-- {name}: count failed: {e}"); continue
    print(f"\n-- {name} ({cnt} rows{', capped to %d' % CAP if cnt > CAP else ''}) --")
    try:
        cur = conn.execute(f'select * from "{name}" limit {CAP}')
        cols = [d[0] for d in cur.description]
        for row in cur:
            print(json.dumps({c: render(v) for c, v in zip(cols, row)}, ensure_ascii=False, default=str))
    except Exception as e:
        print(f"dump failed: {e}")
conn.close()
PYEOF
    done
fi

out ""
out "Done. Send back: $report  +  the contents of $outdir/  (attach to issue #14)"
printf 'Wrote %s\n' "$report"
printf 'Recovered files (if any) are in %s\n' "$outdir"
