# Continuity.pak Launch Failure — Verified Findings

Research report answering the four questions from the launch-debug session.
Every claim below is verified against upstream source (citations are
`upstream/nextui/src/...` paths), against git blob bytes, or empirically
under `busybox ash`. No code was changed for this report.

Prior-session artifacts consulted:

- `docs/handoff-launch-failure.md` (branch `claude/review-continuity-docs-uXVPt`)
- `docs/design/nextui-tool-pak-research.md` and
  `docs/design/continuity-pak-benchmark.md` (branch
  `claude/fix-pak-blank-screen-prQ3c`) — spot-checked against source;
  found accurate.

---

## Q1. Are shell-script-only Tool PAKs viable? — YES, definitively

**`Remove Loading.pak` is a pure-shell Tool PAK shipped in the current
tg5040 skeleton.** Its entire contents is one `launch.sh`
(`skeleton/EXTRAS/Tools/tg5040/Remove Loading.pak/`):

```sh
#!/bin/sh

DIR="$(dirname "$0")"
cd "$DIR"

sed -i '/^\/usr\/sbin\/pic2fb \/etc\/splash.png/d' /etc/init.d/runtrimui
show2.elf --mode=simple --image "$SDCARD_PATH/.system/res/logo.png" --text="Done" --timeout=2

mv "$DIR" "$DIR.disabled"
```

The build system (`src/makefile:92-108`) copies compiled `.elf` binaries
into Battery, Game Tracker, Clock, Input, Settings, LedControl, and
Bootlogo paks — and has **no copy line for Remove Loading.pak**. It ships
as shell only.

Corroborating evidence:

- `src/PAKS.md:3`: *"A pak is just a folder with a '.pak' extension that
  contains a shell script named 'launch.sh'."*
- The NextUI launcher itself (`MinUI.pak/launch.sh`) is a shell script
  executing from the same FAT32 SD card on every boot — so shell-script
  execution from the card demonstrably works, and FAT32 exec permissions
  are a non-issue (the mount grants exec; git file modes are irrelevant
  on vfat).
- 7 of 9 stock Tool PAKs use a compiled `.elf` because they are
  **interactive apps** (their binary owns the framebuffer and the input
  loop). Shell-only is the pattern for one-shot tools that show feedback
  via `show2.elf` — exactly Continuity's shape.

Conclusion: our architecture is valid. No compiled binary is required
for the PAK to launch and show feedback.

## Q2. The exact execution chain (traced + empirically reproduced)

1. User selects the pak. Tools entries are `ENTRY_PAK` (matched by the
   `.pak` suffix); `Entry_open` calls `openPak(self->path)`
   (`nextui.c:1520-1523`).
2. `openPak` writes **`'/mnt/SDCARD/Tools/tg5040/Continuity.pak/launch.sh'`**
   (single-quoted, no args, no trailing-newline guarantee) to `/tmp/next`
   and exits the UI (`nextui.c:1220-1231`, `1086-1090`).
   - `queueNext` also does `LOG_info("cmd: %s\n", cmd)` — and nextui's
     stdout/stderr are redirected to
     **`/mnt/SDCARD/.userdata/tg5040/logs/nextui.txt`**
     (`MinUI.pak/launch.sh:165`). This file records the exact dispatch
     command. **No debugging iteration ever looked at it.** It can prove
     whether selection/dispatch happened at all.
3. The MinUI.pak loop (`SYSTEM/tg5040/paks/MinUI.pak/launch.sh:164-173`)
   does `CMD=$(cat /tmp/next); eval $CMD`.

Answers to the specific suspicions:

| Suspicion | Verdict | Evidence |
|---|---|---|
| `eval` sources our script into the parent shell | **No.** `eval` parses the quoted path and executes the file — a normal fork+exec child process. Parent `set -e` is irrelevant (and MinUI.pak sets no `set -e` anyway). | Reproduced under `busybox ash`: child ran, parent unaffected, exit code observed by parent only. |
| CRLF line endings break launch | **Confirmed mechanism, but not present in our repo** (see Q3). CRLF shebang → kernel looks for interpreter `/bin/sh\r` → ENOENT. Empirical result under busybox ash: `eval: ...launch.sh: not found`, exit 127, **zero trace — the `exec 2>>log` redirect never runs, no file is ever created.** Perfectly matches "black flash → menu, no logs." | Reproduced in scratchpad with the exact `CMD=$(cat file); eval $CMD` dispatch. |
| Missing newline at EOF | Harmless (last line still parses). All our blobs end with `\n` anyway. | Byte audit. |
| UTF-8 BOM | Ruled out as a zero-trace cause: ash's ENOEXEC fallback still runs the script (line 1 errors, rest executes, log files appear). Our blobs have no BOM. | Reproduced. |
| FAT32 permissions | Ruled out: exec bits come from mount options, and every stock pak + MinUI itself executes `.sh` from the same card. (No-exec would give exit 126 "Permission denied" — also zero-trace, but impossible here.) | Reproduced 126 case locally; on-device counter-evidence above. |
| Failure visibility | An eval failure prints to MinUI.pak's stderr, which is **not captured anywhere user-visible**. NextUI has no "tool failed" UI — the loop silently restarts `nextui.elf`. A failed launch is cosmetically identical to a successful no-op launch. | `MinUI.pak/launch.sh:164-183`. |

Environment at `launch.sh` entry (relevant facts): CWD is
`.system/tg5040/paks/MinUI.pak/` (not the pak dir — `cd "$(dirname "$0")"`
is mandatory); `PATH` includes `.system/tg5040/bin`, so **`show2.elf` is
callable bare**; `SDCARD_PATH`, `USERDATA_PATH`, `DEVICE`, `HOME`, etc.
are exported (`MinUI.pak/launch.sh:14-26,49-56,101-102`).

## Q3. Audit of our launch.sh — repo content is clean; observability was the casualty

**Byte-level audit of every `launch.sh` blob ever committed** (all 8
revisions, both `src/platforms/nextui/` and `build/Continuity.pak/`
copies): pure LF, `#!/bin/sh\n` shebang, trailing newline, no BOM, no CR
anywhere. **The committed content was never CRLF-corrupted.** The
`fix(build)` commit `5c030f4` ("enforce LF line endings — root cause")
is therefore a *defense* (against user-side `core.autocrlf=true`
checkouts and future Windows contributors), not a verified root cause.

Current PAK scripts (branch `claude/fix-pak-blank-screen-prQ3c`, all 16
`.sh` files): parse clean under `busybox ash -n`; `shellcheck -s dash`
reports only two info-level notes (intentional non-expanding quotes in a
generated credential helper); no bashisms from the CLAUDE.md
compatibility table; every `show2.elf` flag used is a real option in
`--key=value` form (verified against `show2.cpp:562-618`).

**Why the user plausibly saw pure black even if the script ran** — the
versions actually tested on device each had a guaranteed-invisible
display path:

| Tested version | Display defect (silent) | Debug-log defect |
|---|---|---|
| `2764236`, `08e9ace` (attempts 1–2) | `show2.elf` called without `--image=` → prints usage, **exits 1, renders nothing** (`show2.cpp:562-565`) | logs under `/mnt/SDCARD/.continuity/` — a **dot-folder, hidden in macOS Finder** by default |
| `e74f0e5`, `b54c507` (attempts 3–4) | `SHOW2="${PAK_DIR}/bin/show2.elf"` — points **inside our own pak**, where show2 never existed; the `[ -x ]` guard silently skips *all* display and falls back to bare `sleep` | `e74f0e5`: hidden dot-folder again. `b54c507`: SD root (visible) — the one genuinely contradictory data point, *if* that exact build was tested and the root actually checked |
| `5547fa3` (attempt 5) | system show2 path fixed, but `--logoheight=1` scales the logo to 1 px; text should have rendered — black-text-only screen at best | `exec 2>>./launch_debug.log` **inside the pak folder** — did anyone open `Tools/tg5040/Continuity.pak/` on the card? |
| `90fdf27` (attempts 6–7) | simple mode, still `--logoheight=1` | per handoff: **never tested on device** |
| `d9976a2`+`5c030f4` (current) | display path correct (bare `show2.elf`, valid flags, `--timeout`) | **regression for our situation: all debug output is now gated behind `CONTINUITY_DEBUG`, which nothing on the device sets** — if this version fails, we are blind again |

So the honest state of evidence: **we still cannot distinguish "the
script never executed" from "it executed invisibly and the breadcrumbs
were in places nobody looked"** (hidden folders, inside the pak dir, or
locations tied to untested builds). Both remain live. The repo side is
clean; if the script truly never ran, the corruption happened between
repo and card — the prime suspect being a user-side git checkout with
`core.autocrlf=true` (now neutralized by `.gitattributes` + the CRLF
build check), or a stale/partial copy on the card.

## Q4. Compiled .elf wrapper — not needed, and our current toolchain couldn't easily build one anyway

- **Not needed:** shell-only paks are supported and shipped (Q1), and
  `show2.elf` — present on every NextUI install at
  `.system/tg5040/bin/`, already on `PATH` — is the purpose-built
  display mechanism for shell paks (`Remove Loading.pak` uses exactly
  this; upstream even ships `show2/boot-integration-example.sh`).
- **If one were ever needed:** `scripts/build_git.sh` uses plain
  `gcc-aarch64-linux-gnu` with static zlib/openssl/curl — fine for
  console binaries, but a *display* wrapper needs SDL2/SDL2_ttf against
  the TrimUI display stack. Upstream builds those with the LoveRetro
  Docker union toolchain (`ghcr.io/loveretro/tg5040-toolchain`,
  `src/makefile.toolchain`) — a heavyweight new build dependency for
  zero benefit over the system-provided `show2.elf`.

Recommendation: stay shell-only.

---

## Recommended next step (pending approval — no code changed yet)

One on-device canary test resolves the remaining ambiguity in a single
SD-card round-trip:

1. **Canary launch.sh** (temporarily replaces the real one):

   ```sh
   #!/bin/sh
   printf 'continuity canary ran at %s\n' "$(date)" > /mnt/SDCARD/CONTINUITY_WAS_HERE.txt
   sync
   show2.elf --mode=simple --image=/mnt/SDCARD/.system/res/logo.png --text="Continuity canary OK" --timeout=5
   ```

   - Proof file + 5 s logo screen → **execution and display both work**;
     the failure was observability all along → ship the already-rewritten
     `launch.sh` (with one change: keep an unconditional one-line
     breadcrumb write until first confirmed good launch, instead of the
     `CONTINUITY_DEBUG` gate).
   - Proof file but no logo screen → execution works, display broken →
     debug show2 invocation on device.
   - No proof file, instant menu return → **exec is failing on-card** →
     inspect the card's copy of `launch.sh` (`file` / `xxd | head`),
     and the user's `git config --get core.autocrlf` / transfer method.

2. **Collect existing evidence from the card** (all previously unchecked):
   `/mnt/SDCARD/.userdata/tg5040/logs/nextui.txt` (proves dispatch; shows
   the exact command), any `launch_debug.log` inside
   `Tools/tg5040/Continuity.pak/`, and the SD root. In Finder, press
   **Cmd+Shift+.** to reveal dot-files first — at least two earlier debug
   attempts wrote to locations macOS hides by default.

3. Base the next implementation increment on
   `claude/fix-pak-blank-screen-prQ3c` (canonical-pattern launch.sh,
   `.gitattributes` LF enforcement, CRLF build check) rather than
   re-deriving it.
