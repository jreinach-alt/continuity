# Continuity.pak — Benchmark Against Canonical NextUI Tool PAK Pattern

Companion doc to `docs/design/nextui-tool-pak-research.md`. Compares the current
`Continuity.pak` build (commit `90fdf27`, branch `claude/fix-pak-blank-screen-prQ3c`)
to the canonical pattern and lists defects in priority order.

Reproduction context: launching Continuity from the NextUI Tools menu shows a
black screen for ~3 seconds, then returns to the menu. No persistent UI, no
visible message. Five iterative "fixes" by a previous agent (commits
`08e9ace..90fdf27`) did not resolve it.

## Summary of findings

| # | Severity | Defect | Fix |
|---|---|---|---|
| 1 | **P0** | `show2.elf` invoked with `--logoheight=1` — scales logo to 1 px tall (invisible). Likely primary cause of "blank screen." | Drop `--logoheight` entirely, or use a sensible value (`128`). |
| 2 | P1 | First-run path does git clone + enrollment **synchronously before any UI is shown** — display stays blank for the duration. | Start `show2.elf --mode=daemon` early, update text via FIFO during long ops, `QUIT` on completion. |
| 3 | P1 | `SHOW2` is hardcoded to `/mnt/SDCARD/.system/tg5040/bin/show2.elf`. Not portable; fragile if NextUI moves the binary. | Invoke as bare `show2.elf` — `$PATH` already includes `$SYSTEM_PATH/bin` (`research.md §3`). |
| 4 | P2 | Sources six shell modules during the first-run branch (`pal_nextui.sh`, `pal.sh`, `path_mapper.sh`, `sync_engine.sh`, `enrollment.sh`, `enroll_sd_card.sh`). Any sourcing error aborts the script before any visible output. | Validate each file exists with a `[ -f ... ] || show_error_and_exit` guard, OR avoid running enrollment from `launch.sh` at all (let `auto.sh` → daemon do it on next boot). |
| 5 | P2 | `show_message()` falls back to plain `sleep` if `show2.elf` is missing. The user sees nothing during the fallback. | Remove the fallback; if show2 isn't present, log and exit. show2 is part of every NextUI install. |
| 6 | P3 | `cd $(dirname "$0")` is unquoted. Works today (PAK path has no spaces) but breaks if the user ever renames the parent dir. | `cd "$(dirname "$0")"` (quote the command substitution). |
| 7 | P3 | `exec 2>>./launch_debug.log` + `set -x` permanently captures debug output into the PAK directory. Useful while developing; should be gated by an env var. | `[ -n "$CONTINUITY_DEBUG" ] && { exec 2>>./launch_debug.log; set -x; }`. |
| 8 | P3 | Tool PAK structure is correct (subdirectories `bin/`, `scripts/`, `config/`, `launch.sh` at root) and matches the canonical layout in `research.md §1`. | No change. |

The numbered sections below detail each finding.

---

## 1. `--logoheight=1` — the primary suspect (P0)

**Where:** `src/platforms/nextui/launch.sh:18`

```sh
"$SHOW2" --mode=simple --image="$LOGO" --bgcolor=0x000000 \
    --logoheight=1 --text="$1" --fontsize=28 --timeout="$2"
```

**What it does** (`upstream/nextui/src/workspace/all/show2/show2.cpp:140-163`):

When `logo_height > 0` and differs from the loaded surface's height, show2
calls `SDL_BlitScaled` to rescale the logo to exactly `logo_height` pixels
tall. With `--logoheight=1`, the logo becomes 1 px tall × `(w/h)` px wide.

The combined screen is then:
- `--bgcolor=0x000000` → black background fills the whole framebuffer.
- 1-px-tall scaled logo, centered → effectively invisible.
- `--text="$1"` rendered at default `texty=80%`, `fontsize=28` → a thin line
  of white text near the bottom.

For 3 seconds (the `--timeout`), the user sees what looks like a completely
black screen. Then show2 exits, launch.sh returns, MinUI's outer loop kills
show2 and re-launches `nextui.elf`, which repaints the menu. Total impression:
"nothing happened."

There is a secondary concern: `SDL_BlitScaled` with such an extreme downscale
factor (a 200-px tall logo → 1 px) may produce undefined results on the SDL
build NextUI uses — potentially a crash that exits show2 with no rendering at
all (research.md §Open Questions #4).

**Fix:** drop `--logoheight` entirely. The logo will render at its native
resolution (the `/mnt/SDCARD/.system/res/logo.png` is sized for the boot
splash, ~144 px tall, which fits comfortably on both Brick and Smart Pro).

```sh
show2.elf --mode=simple --image="$LOGO" --bgcolor=0x000000 \
    --text="$1" --fontsize=28 --timeout="$2"
```

This alone is almost certainly enough to unblock the visible-output failure.

---

## 2. Long-running first-run work with no UI (P1)

**Where:** `src/platforms/nextui/launch.sh:26-62`

The "first run" branch (no `HOOK_MARKER` file present) does:

1. `mkdir -p` and write to `$AUTO_SH` — fast.
2. **`touch "$HOOK_MARKER"`** — fast.
3. **If `setup.json` exists:** source 6 files, call `esd_import` — which calls
   `enroll_run` → `se_clone` → `git clone` over HTTPS.

Step 3's `git clone` can take 5-30 seconds depending on network and repo size,
during which the framebuffer holds whatever frame was left when `nextui.elf`
exited (probably a torn-down SDL window — i.e. black). Then `show_message
"Enrolled!"` runs for 3 seconds. The user can't tell the difference between
"enrolling now" and "finished, telling you to reboot."

This matches the antipattern in `research.md §6.7`:
> Long-running setup with no UI. A first-run init that does mkdir, cp, git
> clone, etc. without show2.elf running in the background will hold a black
> screen for as long as the setup takes.

**Fix:** start `show2.elf --mode=daemon` first, then push status messages over
the FIFO at `/tmp/show2.fifo` during the long operation. Pattern from
`research.md §6`:

```sh
show2.elf --mode=daemon --image="$LOGO" --bgcolor=0x000000 \
    --text="Setting up Continuity..." --fontsize=28 &
SHOW_PID=$!
sleep 0.5    # let mkfifo land

# ...sourcing, hook install...
echo "TEXT:Enrolling device..." > /tmp/show2.fifo

if esd_import; then
    echo "TEXT:Enrolled! Reboot to start syncing." > /tmp/show2.fifo
    sleep 3
else
    echo "TEXT:Enrollment failed. Check setup.json." > /tmp/show2.fifo
    sleep 5
fi

echo "QUIT" > /tmp/show2.fifo
wait $SHOW_PID
```

A simpler architectural alternative: **don't run enrollment from `launch.sh`
at all.** Have `launch.sh` only install the auto.sh hook and show "Installed.
Reboot to start." On next boot, the daemon (which already handles enrollment
in `cd_check_enrollment`, `continuity_daemon.sh:96-127`) does the work.

This is arguably the cleaner design — it removes the duplicated enrollment
path from launch.sh entirely and means launch.sh has only fast, predictable
work to do.

---

## 3. Hardcoded path to `show2.elf` (P1)

**Where:** `src/platforms/nextui/launch.sh:11`

```sh
SHOW2="/mnt/SDCARD/.system/tg5040/bin/show2.elf"
```

This works on tg5040 (Brick) only. On tg5050 (Smart Pro S) the binary lives
at `/mnt/SDCARD/.system/tg5050/bin/show2.elf`. NextUI exports `$PATH` to
include `$SYSTEM_PATH/bin`, so the unqualified name resolves correctly per
platform (`research.md §3, §9 #7`).

Also: hardcoding the path means an `[ -x "$SHOW2" ]` check can fail spuriously
if the file system layout shifts. Bare `show2.elf` always works as long as
NextUI is installed.

**Fix:** drop the variable, just call `show2.elf` directly. Optionally probe
with `command -v show2.elf >/dev/null` if you want a guard.

---

## 4. Sourcing chain can fail silently before UI (P2)

**Where:** `src/platforms/nextui/launch.sh:48-53`

```sh
. ./scripts/pal_nextui.sh
. ./scripts/core/pal.sh
. ./scripts/core/path_mapper.sh
. ./scripts/core/sync_engine.sh
. ./scripts/core/enrollment.sh
. ./scripts/enroll_sd_card.sh
```

Each `.` is a hard dependency. If any file is missing (e.g. an OTA update
went sideways and one of these vanished), the `.` will print "not found" to
stderr (which goes to `launch_debug.log` per line 8) and `set -e` would
abort — but `set -e` is **not** set in this script (verified: only `set -x`
at line 9). The script continues past the failed source, then dies later
with "function not found" when it tries to call `esd_import`. Either way,
the user sees the same blank-screen failure with no diagnosis.

The sourced files themselves were audited and don't use `set -e` or
top-level `exit`:

```
$ grep -Hn '^set -e\|^trap\|^exit ' src/core/*.sh src/platforms/nextui/*.sh
src/platforms/nextui/continuity_daemon.sh:6:set -e
src/platforms/nextui/update.sh:7:set -e
(daemon and update aren't sourced by launch.sh; no exits in sourced modules)
```

So the sourced files are safe; the risk is purely "one of them might be
missing on disk."

**Fix (cheap):** test each file before sourcing and show a visible error.

```sh
for f in scripts/pal_nextui.sh scripts/core/pal.sh scripts/core/path_mapper.sh \
         scripts/core/sync_engine.sh scripts/core/enrollment.sh \
         scripts/enroll_sd_card.sh; do
    if [ ! -f "./$f" ]; then
        show_message "Missing module: $f. Reinstall Continuity.pak." 5
        exit 1
    fi
done
```

**Fix (architectural, preferred):** don't source these at launch.sh time at
all (see §2 alternative — move enrollment to the daemon on next boot).

---

## 5. Silent `sleep` fallback (P2)

**Where:** `src/platforms/nextui/launch.sh:16-23`

```sh
show_message() {
    if [ -x "$SHOW2" ] && [ -f "$LOGO" ]; then
        "$SHOW2" --mode=simple ...
    else
        sleep "$2"
    fi
}
```

If `show2.elf` or `logo.png` is unavailable, the function sleeps silently —
which is indistinguishable from "tool failed instantly." This is the same
problem identified in `research.md §6.4`:
> show2.elf called but binary not found / not executable. Stock paks guard
> with [ -x "$SHOW2" ] and fall back to sleep — which means the user sees
> nothing.

show2.elf is part of every NextUI install (`upstream/nextui/src/workspace/all/show2/` ships in the SYSTEM tree); the fallback should never trigger in
practice. If it does, the right response is "log the missing prerequisite
and exit cleanly with no fake delay" — at least then the symptom doesn't
masquerade as the canonical failure mode.

**Fix:** remove the fallback. If show2 is missing, that's a fatal
installation error.

---

## 6. Unquoted command substitution (P3)

**Where:** `src/platforms/nextui/launch.sh:4`

```sh
cd $(dirname "$0")
```

Stock paks (Battery.pak, Clock.pak) use this unquoted form too, and it works
because the PAK install path doesn't contain spaces. But the moment someone
renames the PAK or installs at a non-standard path with whitespace, it
breaks.

**Fix:** quote it. `cd "$(dirname "$0")"`.

---

## 7. Always-on debug log + xtrace (P3)

**Where:** `src/platforms/nextui/launch.sh:7-9`

```sh
date >> ./launch_debug.log
exec 2>>./launch_debug.log
set -x
```

This permanently appends a verbose xtrace dump to `./launch_debug.log` on
every invocation. The file lives in the PAK dir (FAT32) and grows
unbounded. Useful right now while debugging, but should be gated.

**Fix:** require an env var.

```sh
if [ -n "$CONTINUITY_DEBUG" ]; then
    date >> ./launch_debug.log
    exec 2>>./launch_debug.log
    set -x
fi
```

A user troubleshooting from the device can set the var by editing the
auto.sh hook (or by adding a marker file the script checks).

---

## 8. Directory layout is correct (informational)

The current PAK layout is fine per `research.md §1`:

```
build/Continuity.pak/
├── launch.sh                                    # entry point at root  ✓
├── version.txt
├── bin/git                                      # 6 MB aarch64 static  ✓
├── config/
│   ├── system_taxonomy.json
│   └── platform_maps/nextui.json
└── scripts/
    ├── continuity_daemon.sh
    ├── enroll_sd_card.sh
    ├── pal_nextui.sh
    ├── update.sh
    └── core/
        ├── boot_pull.sh
        ├── change_detector.sh
        ├── cold_start.sh
        ├── conflict_handler.sh
        ├── enrollment.sh
        ├── pal.sh
        ├── path_mapper.sh
        ├── runtime_poll.sh
        ├── stale_boot.sh
        ├── sync_engine.sh
        └── sync_status.sh
```

Subdirectories inside a Tool PAK are unproblematic (research.md §1, stock
`Bootlogo.pak` ships with `brick/` and `smartpro/` subdirs, `LedControl.pak`
ships fonts and config files alongside its binary). NextUI only looks for
`launch.sh` at the root, which this PAK provides.

The static aarch64 git binary is correctly placed and correctly architected
(`file build/Continuity.pak/bin/git` confirms ARM aarch64, static).

The hook-installation pattern (write to `$USERDATA_PATH/auto.sh`) is the
right architecture — there is no per-PAK auto.sh convention in NextUI; the
global user-installable boot hook is the only path (research.md §7).

---

## Recommended sequence of fixes

In the order that will produce the largest behavioral change for the least
risk:

1. **Drop `--logoheight=1`** (one-line change in `launch.sh`). Rebuild and
   test on device. This alone is the highest-probability fix.
2. **Use bare `show2.elf` instead of the hardcoded path.** Defensive, also
   makes the script portable to tg5050.
3. **Switch the long-running first-run branch to `show2.elf --mode=daemon`**
   with FIFO updates. Makes the user-visible behavior match the actual
   work.
4. **Gate debug logging behind `$CONTINUITY_DEBUG`.** Stops the unbounded
   log file.
5. **Quote `$(dirname "$0")`.** Belt-and-suspenders.
6. **Add per-source-file existence checks** OR **remove enrollment from
   launch.sh entirely**. The second is the cleaner long-term fix — leaves
   `launch.sh` doing only the install-hook-and-show-status work, with
   enrollment driven from the daemon on next boot.

After applying #1-#5, the next on-device test should produce a visible
"Installed! Reboot to start daemon." message for 3 seconds, followed by a
clean return to the menu. If it still doesn't, the problem is no longer
in launch.sh and we'd need on-device strace output (or the
`launch_debug.log` contents) to diagnose further.

---

## What we still can't verify from source alone

Items where a hardware test is required to confirm hypothesis:

- That `--logoheight=1` is actually what makes the screen look blank (vs.
  show2 crashing outright). The two hypotheses produce indistinguishable
  user-visible behavior but differ in what's in `launch_debug.log`.
- That `logo.png` exists at `/mnt/SDCARD/.system/res/logo.png` on the
  user's specific NextUI install. (Upstream skeleton has it at
  `SYSTEM/res/logo.png`; the install path is `.system/res/`. Should be
  fine but worth confirming.)
- That the script even runs — i.e. that `launch_debug.log` is being
  written to. If the file doesn't exist after a failed launch attempt,
  NextUI may be rejecting the PAK entirely (executable bit lost during
  copy, wrong line endings, etc. — research.md §9 #6, #3).

These are all answerable by SSHing onto the device or reading the
`launch_debug.log` from the SD card after a failed launch attempt.
