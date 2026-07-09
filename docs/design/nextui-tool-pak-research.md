# NextUI Tool PAK — Research Reference

Source-of-truth reference for building Tool PAKs on NextUI (TrimUI Brick / Smart Pro / Smart Pro S, platforms `tg5040` and `tg5050`).

All citations are line numbers in files under `/home/user/ideal_os/upstream/nextui/src/` and `/home/user/ideal_os/upstream/nextui/notes/`, unless otherwise noted.

---

## TL;DR — Canonical Tool PAK pattern

A minimal Tool PAK that will reliably appear in the Tools menu and run without a blank-screen-then-immediate-return failure:

```sh
#!/bin/sh
# /mnt/SDCARD/Tools/tg5040/MyTool.pak/launch.sh

cd "$(dirname "$0")"               # 1. Always do this. CWD on entry is MinUI.pak/, not your pak.
./mytool.elf                       # 2. Run a *blocking* program that draws on the framebuffer.
                                   #    When it exits, control returns to the launcher.
```

That is the entire stock pattern. Every shipped Tool PAK in `skeleton/EXTRAS/Tools/tg5040/` follows it (Battery, Clock, Files, Settings, Game Tracker, Input, LedControl, Bootlogo). See citations below.

Crucial rules that follow from how NextUI dispatches PAKs:

1. **launch.sh must block while the UI is visible.** As soon as launch.sh returns, MinUI's outer loop will (a) `killall -9 show2.elf`, (b) re-launch `nextui.elf`, and (c) repaint the menu. If launch.sh has nothing on-screen and returns immediately, the user sees a momentary blank screen followed by the menu reappearing. (`SYSTEM/tg5040/paks/MinUI.pak/launch.sh:159,164-173`)
2. **You must run a program that paints the framebuffer.** Just writing to stdout is invisible; the framebuffer is whatever the last SDL program left on it (i.e. blank, because MinUI killed `show2.elf` at line 159 before invoking your pak).
3. **`show2.elf` only accepts `--key=value` form.** `--key value` is silently parsed as `--key=true` and the following positional argument is ignored. (`workspace/all/show2/show2.cpp:511-527`)
4. **`show2.elf` in `simple`/`progress` mode blocks until killed** unless `--timeout=N` is given. Without `--timeout`, you must run it in the background and `kill` it yourself. (`workspace/all/show2/show2.cpp:221-237`)
5. **Subdirectories inside a `.pak` are fine.** `Bootlogo.pak` ships with `brick/` and `smartpro/` subdirs; `bin/`, `scripts/`, `config/` are all unproblematic. (`skeleton/EXTRAS/Tools/tg5040/Bootlogo.pak/`)

---

## 1. Tool PAK directory layout

### On-disk path

Tools live at:

```
/mnt/SDCARD/Tools/<platform>/<Name>.pak/launch.sh
```

where `<platform>` is the lowercase platform tag (`tg5040` for Brick / Smart Pro, `tg5050` for Smart Pro S, etc.). See:

- `PAKS.md:5-7` — "Tool paks live in the Tools folder. … Inside the Emus and Tools folders you will find (or need to create) platform folders."
- `workspace/all/nextui/nextui.c:702-705` — `hasTools()` checks `"%s/Tools/%s"` (SDCARD_PATH, PLATFORM).
- `workspace/all/nextui/nextui.c:514-520` — `entryFromPakName` looks up `"%s/Tools/%s/%s.pak"`.

### Minimal contents

Only `launch.sh` is required. Stock Tool PAKs that ship as a single-file `launch.sh`:

```
$ ls -la skeleton/EXTRAS/Tools/tg5040/Battery.pak/
-rwxr-xr-x  59  launch.sh
$ ls -la skeleton/EXTRAS/Tools/tg5040/Clock.pak/
-rwxr-xr-x  57  launch.sh
$ ls -la skeleton/EXTRAS/Tools/tg5040/Game Tracker.pak/
-rwxr-xr-x  62  launch.sh
$ ls -la skeleton/EXTRAS/Tools/tg5040/Input.pak/
-rwxr-xr-x  43  launch.sh
```

### Subdirectories

Subdirectories are not flagged by NextUI in any way. The `entryFromPakName`/`hasTools` code just confirms the `.pak` folder exists; everything inside is the pak author's business.

Examples in stock paks:

- `Bootlogo.pak/` contains `brick/` and `smartpro/` per-device asset dirs (`skeleton/EXTRAS/Tools/tg5040/Bootlogo.pak/`).
- `Files.pak/` ships `tg3040.cfg` and `tg5040.cfg` alongside `launch.sh`.
- `LedControl.pak/` ships `main.ttf` (a font), `ledsettings.txt`, `ledsettings_brick.txt`.

So `bin/`, `scripts/`, `config/`, `assets/`, etc. inside a Tool PAK are all fine. NextUI does not iterate or scrutinize them.

The only hard rule: **the entry point is `launch.sh`** at the pak root, executable, with a `#!/bin/sh` shebang.

### Hidden caveat for `.system/`

`PAKS.md:5` warns: "Extra paks should never be added to the hidden `.system` folder at the root of the SD card. This folder is deleted and replaced every time a user updates NextUI." So a tool author's PAK must live under `/mnt/SDCARD/Tools/`, never under `/mnt/SDCARD/.system/`.

---

## 2. How NextUI invokes `launch.sh`

The invocation is a two-stage handoff: `nextui.elf` writes a command file, exits, and `MinUI.pak/launch.sh` re-`eval`s the command in its outer `while` loop.

### Stage 1: nextui.elf queues the command

When the user selects a Tool from the menu, `Entry_open` routes ENTRY_PAK to `openPak`:

```c
// workspace/all/nextui/nextui.c:1520-1523
else if (self->type==ENTRY_PAK) {
    startgame = 1;
    openPak(self->path);
}
```

`openPak` formats a shell command and writes it to `/tmp/next`:

```c
// workspace/all/nextui/nextui.c:1220-1231
static void openPak(char* path) {
    saveLast(path);

    char cmd[256];
    sprintf(cmd, "'%s/launch.sh'", escapeSingleQuotes(path));
    queueNext(cmd);
}
```

```c
// workspace/all/nextui/nextui.c:1086-1090
static void queueNext(char* cmd) {
    LOG_info("cmd: %s\n", cmd);
    putFile("/tmp/next", cmd);
    quit = 1;
}
```

So the file `/tmp/next` ends up containing exactly:

```
'/mnt/SDCARD/Tools/tg5040/MyTool.pak/launch.sh'
```

— a single-quoted path, no arguments, no environment, no trailing newline guarantees. `nextui.elf` then exits.

### Stage 2: MinUI.pak/launch.sh reads /tmp/next and `eval`s it

The outer loop in `MinUI.pak/launch.sh` is:

```sh
# skeleton/SYSTEM/tg5040/paks/MinUI.pak/launch.sh:158-173
# kill show2.elf if running
killall -9 show2.elf > /dev/null 2>&1

EXEC_PATH="/tmp/nextui_exec"
NEXT_PATH="/tmp/next"
touch "$EXEC_PATH"  && sync
while [ -f $EXEC_PATH ]; do
    nextui.elf &> $LOGS_PATH/nextui.txt
    echo $CPU_SPEED_PERF > $CPU_PATH
    
    if [ -f $NEXT_PATH ]; then
        CMD=`cat $NEXT_PATH`
        eval $CMD
        rm -f $NEXT_PATH
        echo $CPU_SPEED_PERF > $CPU_PATH
    fi
    ...
done
```

Key facts about this dispatch:

| Question | Answer | Evidence |
|---|---|---|
| Is launch.sh run via `eval`? | Yes, **`eval $CMD`** (unquoted). | tg5040 line 170 |
| In a subshell? | The `eval` itself runs in the MinUI.pak shell process. Because the command is just a path to an executable script (not a function), the kernel forks+execs a new `/bin/sh` to interpret it. So launch.sh runs in a child shell process; environment is inherited via exec. | tg5040 line 170 + standard POSIX `execve` |
| With what working directory? | The cwd at `eval` time — namely `$(dirname "$0")` of MinUI.pak's own launch.sh, which is `/mnt/SDCARD/.system/$PLATFORM/paks/MinUI.pak/`. **NOT the tool pak's directory.** | tg5040 line 154 (`cd $(dirname "$0")`) |
| With what environment exported? | The full export block set by MinUI.pak/launch.sh (see §3). Plus whatever `nextui.elf` and `auto.sh` might have leaked. | tg5040 lines 14-26, 49-56, 101-102 |
| Are stdin/stdout/stderr a TTY? | No. `nextui.elf &> $LOGS_PATH/nextui.txt` redirects its own output, but the outer loop doesn't redirect after that. Stdout/stderr point at whatever launched MinUI.pak (typically the boot scripts — eventually a logfile or `/dev/null`). | tg5040 line 165 |
| Are signals propagated cleanly? | MinUI.pak doesn't `trap` SIGCHLD. When launch.sh exits, the loop continues immediately. | tg5040 lines 164-183 |
| Is `set -e` set? | No. | inspect tg5040/MinUI.pak/launch.sh top |

The `eval $CMD` (unquoted) is what makes the single-quoted command work: word-splitting on whitespace, with the single quotes preventing splitting within the path. Paths with single quotes are escaped via `escapeSingleQuotes()` (nextui.c:1118-1125).

### What happens when launch.sh returns

Control returns to MinUI.pak/launch.sh just after the `eval` line. It then:

1. Removes `/tmp/next` (line 171).
2. Resets the CPU governor.
3. Checks `/tmp/poweroff` / `/tmp/reboot`.
4. Loops back to the top of `while`, which **calls `killall -9 show2.elf`** (line 159) and then re-execs `nextui.elf` (line 165).

This is the entire reason a launch.sh that returns immediately produces a "blank screen → menu" flicker.

---

## 3. Environment variables available to launch.sh

All variables exported by `MinUI.pak/launch.sh` before reaching the `eval $CMD` line, in order. See `skeleton/SYSTEM/tg5040/paks/MinUI.pak/launch.sh:14-26, 49-56, 101-102`.

| Variable | Value (on tg5040) | Line |
|---|---|---|
| `PLATFORM` | `tg5040` | 14 |
| `SDCARD_PATH` | `/mnt/SDCARD` | 15 |
| `BIOS_PATH` | `/mnt/SDCARD/Bios` | 16 |
| `ROMS_PATH` | `/mnt/SDCARD/Roms` | 17 |
| `SAVES_PATH` | `/mnt/SDCARD/Saves` | 18 |
| `CHEATS_PATH` | `/mnt/SDCARD/Cheats` | 19 |
| `SYSTEM_PATH` | `/mnt/SDCARD/.system/tg5040` | 20 |
| `CORES_PATH` | `/mnt/SDCARD/.system/tg5040/cores` | 21 |
| `USERDATA_PATH` | `/mnt/SDCARD/.userdata/tg5040` | 22 |
| `SHARED_USERDATA_PATH` | `/mnt/SDCARD/.userdata/shared` | 23 |
| `LOGS_PATH` | `/mnt/SDCARD/.userdata/tg5040/logs` | 24 |
| `DATETIME_PATH` | `/mnt/SDCARD/.userdata/shared/datetime.txt` | 25 |
| `HOME` | `/mnt/SDCARD/.userdata/tg5040` (= `$USERDATA_PATH`) | 26 |
| `TRIMUI_MODEL` | `Trimui Brick` or `Trimui Smart Pro` (from `strings /usr/trimui/bin/MainUI`) | 49 |
| `DEVICE` | `brick` or `smartpro` (derived from `TRIMUI_MODEL`) | 50-54 |
| `IS_NEXT` | `yes` | 56 |
| `LD_LIBRARY_PATH` | `/mnt/SDCARD/.system/tg5040/lib:/usr/trimui/lib:$LD_LIBRARY_PATH` | 101 |
| `PATH` | `/mnt/SDCARD/.system/tg5040/bin:/usr/trimui/bin:$PATH` | 102 |

On tg5050 (Smart Pro S), `PLATFORM=tg5050` and `DEVICE=smartpros` (set conditionally on `TRIMUI_MODEL == "Trimui Smart Pro S"`). See `skeleton/SYSTEM/tg5050/paks/MinUI.pak/launch.sh:14, 50-51`.

Notably **not** exported:

- `CONTROLLER_PATH`, `FONT_PATH`, etc. — these are PAK-internal conventions only.
- Per-pak vars like `EMU_TAG` — those are conventions used inside emulator pak launch.sh templates (see `PAKS.md:37`).

Because `PATH` includes `$SYSTEM_PATH/bin`, all standard NextUI helper binaries are callable bare:

- `show2.elf` (splash/loading display)
- `keymon.elf`, `batmon.elf`, `audiomon.elf` (input/battery/audio daemons — already running)
- `nextval.elf` (NextUI settings reader)
- `gametimectl.elf` (game time tracker)
- `syncsettings.elf` (brightness/volume restoration helper — see `PAKS.md:88-103`)
- `poweroff_next`, `reboot_next` (shutdown helpers)
- `minarch.elf` (libretro core host — for emulator paks)

---

## 4. Working directory at entry

**At entry, `pwd` is `/mnt/SDCARD/.system/$PLATFORM/paks/MinUI.pak/`.**

This is because MinUI.pak/launch.sh runs `cd $(dirname "$0")` at line 154 (tg5040) / line 166 (tg5050) before the main loop, and `eval $CMD` doesn't change directory before invoking your script.

**Yes, launch.sh should do `cd "$(dirname "$0")"` first.** Every stock Tool PAK does so:

```sh
# Battery.pak/launch.sh:1-4
#!/bin/sh

cd $(dirname "$0")
./battery.elf # &> ./log.txt
```

```sh
# Game Tracker.pak/launch.sh:1-4
#!/bin/sh

cd "$(dirname "$0")"
./gametime.elf # &> ./log.txt
```

```sh
# LedControl.pak/launch.sh:1-2
#!/bin/sh
cd $(dirname "$0")
```

Some paks even do it twice (LedControl.pak lines 2 and 13). Both quoted (`"$(dirname "$0")"`) and unquoted (`$(dirname "$0")`) variants appear in stock paks — the unquoted form is fine because `$0` here is `/mnt/SDCARD/Tools/tg5040/<Name>.pak/launch.sh`, a path with no spaces in the Tool/platform portion (though folder names like `Game Tracker.pak` _do_ contain spaces and Game Tracker.pak nonetheless ships unquoted form too — works because IFS-splitting on the cd argument still yields the same fragments NextUI passes intact via the single-quoted /tmp/next command).

To be safe: **`cd "$(dirname "$0")"` (with double quotes around the command substitution).**

---

## 5. show2.elf

Read `workspace/all/show2/show2.cpp` end to end.

### 5a. Argument-parsing form: `--key=value` only

`parseArguments` (lines 511-530):

```cpp
for (int i = 1; i < argc; i++) {
    std::string arg(argv[i]);
    if (arg.find("--") == 0) {
        size_t eq_pos = arg.find('=');
        if (eq_pos != std::string::npos) {
            std::string key = arg.substr(2, eq_pos - 2);
            std::string value = arg.substr(eq_pos + 1);
            args[key] = value;
        } else {
            args[arg.substr(2)] = "true";          // <-- silent fallback
        }
    }
}
```

Consequences:

- `--image=splash.png` → `args["image"] = "splash.png"`. **Correct.**
- `--image splash.png` → `args["image"] = "true"`, then `splash.png` (which has no `--` prefix) is **silently dropped**. The program later does `access("true", F_OK)` which fails and prints "Image not found: true" to stderr; no logo is rendered, but the program proceeds. (Lines 136-166.)
- `--image` alone → `args["image"] = "true"`, same as above.
- `--logoheight 1` → `args["logoheight"] = "true"`, then `std::stoi("true")` at line 614 will throw `std::invalid_argument` and crash the program with an uncaught exception. **Tool returns immediately, screen blank, menu reappears.**

This is the most common single-line failure mode for tools that pass any flag value with a space. There is a real example of this typo in shauninman's own code: `Remove Loading.pak/launch.sh:7` uses `--image "$SDCARD_PATH/..."` with a space. That tool ships in good standing because `access("true", F_OK)` fails gracefully and the remaining flags (which _are_ in `--key=value` form) still get used, so it shows the logo from `--text=Done` and `--timeout=2` (though the `--image=` portion is broken).

### 5b. `simple` / `progress` mode is a blocking spin loop

```cpp
// workspace/all/show2/show2.cpp:221-237
void runSimpleLoop() {
    while (running) {
        render();
        if (config.timeout_seconds > 0) {
            uint32_t elapsed_ms = SDL_GetTicks() - start_time;
            uint32_t timeout_ms = static_cast<uint32_t>(config.timeout_seconds) * 1000;
            if (elapsed_ms >= timeout_ms) {
                running = false;
                break;
            }
        }
        SDL_Delay(1000 / FPS);  // 60 FPS
    }
}
```

So:

- Without `--timeout`, the loop runs until `running` is flipped by SIGINT. **It does not return on its own.**
- The only ways out: `kill $SHOW_PID` (SIGINT) or `kill -9 $SHOW_PID` (the outer MinUI loop's `killall -9 show2.elf`).
- With `--timeout=N`, it returns after N seconds. This is the safest form for a Tool PAK that wants to display a message and then exit.

In `simple` mode `render()` (line 329-342) clears to `bg_color_sdl`, then `renderSimple()` (line 344-372) blits the logo (centered) and the text (at `text_y_pct`% of screen height). If `logo` is null (e.g. image missing), only the text and bg are drawn.

### 5c. Missing or nonexistent `--image=`

`--image` is **mandatory**. `main` at lines 562-565:

```cpp
if (args.find("help") != args.end() || args.find("image") == args.end() || args.find("mode") == args.end()) {
    printUsage();
    return args.find("help") != args.end() ? 0 : 1;
}
```

Missing `--image` → prints usage to stdout, returns 1, no display at all.

If `--image=somepath` but file doesn't exist, `access()` fails at line 136 → "Image not found: …" to stderr, but show2 **continues running** and displays the bg color + text + progress bar. So a missing logo is non-fatal, but a missing `--image=` argument is fatal-on-startup.

### 5d. Effect of `--logoheight=1`

Lines 140-163. When `logo_height > 0` and differs from the actual loaded logo height, show2 scales the logo to `logo_height` pixels tall (maintaining aspect ratio). `--logoheight=1` therefore scales the logo to **1 pixel tall** (and ~`(logo->w / logo->h)` pixels wide). Effectively invisible.

This appears to be a misunderstanding of the parameter. The correct usage is either:

- Omit `--logoheight` entirely → no scaling, original size.
- `--logoheight=128` (or some sensible pixel value) → scale to 128 px tall.

Setting `--logoheight=1` produces a "no logo visible" effect that compounds with any other display problems.

### 5e. FIFO signaling

The FIFO at `/tmp/show2.fifo` is **only used in `--mode=daemon`**. (Lines 239-254.)

```cpp
void runDaemonMode() {
    unlink(FIFO_PATH);
    if (mkfifo(FIFO_PATH, 0666) < 0) { perror("mkfifo"); }
    pthread_create(&fifo_thread_handle, nullptr, fifoThreadEntry, this);
    while (running) {
        render();
        SDL_Delay(1000 / FPS);
    }
    pthread_join(fifo_thread_handle, nullptr);
    unlink(FIFO_PATH);
}
```

- FIFO is created **at the moment `runDaemonMode()` starts**, not at process start.
- `simple` and `progress` modes never create or read the FIFO.
- Commands written to the FIFO: `TEXT:<msg>`, `PROGRESS:<n>`, `BGCOLOR:<hex>`, `FONTCOLOR:<hex>`, `TEXTY:<n>`, `PROGRESSY:<n>`, `QUIT`. (Lines 285-322; documented `show2/README.md:88-96`.)
- In daemon mode, the FIFO read **blocks until a reader writes** (line 263: `open(FIFO_PATH, O_RDONLY)` is a blocking open). Important caveat: writes from shell into the FIFO will block until the daemon's read loop opens for reading (it does immediately at start, but there's a brief race window — hence the `sleep 0.5` after backgrounding in `workspace/all/show2/boot-integration-example.sh:25`).

---

## 6. Why a Tool PAK shows "blank screen → return to menu"

### What the user sees

1. User highlights "MyTool" in the Tools list, presses A.
2. nextui.elf calls `openPak`, writes `/tmp/next`, sets `quit=1`, exits.
3. MinUI.pak/launch.sh resumes its while loop:
   - `killall -9 show2.elf` runs (line 159) — but no show2 is currently up, so noop.
   - `eval $CMD` runs launch.sh.
   - launch.sh does its work and exits.
   - `/tmp/next` is removed.
4. Loop iterates: `nextui.elf` is re-launched. It reloads the menu and repaints.

The "blank screen" is **whatever was last drawn to the framebuffer**. Because MinUI killed show2 _before_ invoking your pak, and nextui.elf had already exited (its window torn down), the framebuffer is left with whatever pixels happened to be last drawn — typically black or the last menu frame. If your launch.sh draws nothing, the user sees that frozen frame for the duration of your script's runtime. As soon as your script exits, nextui.elf restarts and repaints the menu.

The "return to menu" is just step 4. There is no NextUI logic that says "the tool failed"; from NextUI's perspective the tool completed perfectly.

### Common silent-failure modes

In rough order of likelihood:

1. **launch.sh exits immediately with no blocking call.** If you do `cd; some_setup; exit 0` with no `show2.elf --timeout=N`, no `./mybinary.elf` that holds a window, no `sleep`, you get instant return → blank flash → menu.

2. **`show2.elf` called with `--key value` instead of `--key=value`.** Particularly `--logoheight 1` or `--image somepath` — `std::stoi("true")` throws and show2 dies before drawing anything. (`show2.cpp:614, 614, 614`.)

3. **`show2.elf --mode=simple` without `--timeout`, run synchronously, with no kill in sight.** The script will block forever, but the user sees only the bg color + whatever logo/text rendered. Without text or with `--logoheight=1`, this looks like a hung blank screen. Pressing MENU or POWER will not exit show2 — only `kill` from another process does.

4. **`show2.elf` called but binary not found / not executable.** Stock paks guard with `[ -x "$SHOW2" ]` and fall back to `sleep` — which means the user sees nothing (because there's nothing on the framebuffer). The "diagnostic" message intended for show2 is never displayed.

5. **`set -e` triggered by an unrelated command.** Many writers add `set -e` at the top out of habit. Then any non-zero exit (e.g. `grep -q somepattern file` in a file that doesn't contain the pattern) terminates the script. Combined with no preceding visible output, this looks identical to "tool did nothing."

6. **Script syntax error from bash-isms.** MinUI runs BusyBox ash. `[[ ]]`, `${var//pat/rep}`, `<<<` here-strings, arrays, `function name()`, `local var=$(cmd)` — any of these will produce a parse-time or runtime error and the script will exit early. The error message goes to stderr, which is whatever MinUI.pak's stderr is (typically a log file in `$LOGS_PATH/`, but not a TTY).

7. **Long-running setup with no UI.** A first-run init that does `mkdir`, `cp`, `git clone`, etc. without `show2.elf` running in the background will hold a black screen for as long as the setup takes, then return to menu. The user has no feedback that anything happened.

8. **`cd "$(dirname "$0")"` omitted.** If you then reference `./mybinary.elf`, the script tries to run `./mybinary.elf` from MinUI.pak's directory and fails (file not found). Same observable failure as #4.

### How well-behaved Tool PAKs guard against this

Look at the stock pattern: every working Tool PAK either (a) launches a binary that itself opens an SDL window and runs an event loop until the user presses a quit button (Battery, Clock, Files via NextCommander, Game Tracker, Input via minput, Settings, LedControl), or (b) is a one-shot configuration change that explicitly shows feedback via `show2.elf` _with_ `--timeout` (Remove Loading.pak).

The "interactive binary" pattern (a) is the dominant one. It is implicitly safe because: the binary holds the framebuffer, the binary handles input, the binary exits on the user's signal — at which point launch.sh returns cleanly. No race, no blank screen.

For one-shot tools (pattern b), the safe template is:

```sh
#!/bin/sh
cd "$(dirname "$0")"
do_some_work_that_takes_under_2s
show2.elf --mode=simple --image="$SDCARD_PATH/.system/res/logo.png" \
          --text="Done" --timeout=2
```

Note `--timeout=2` ensures the show2 process exits on its own; no `kill` needed.

For long-running one-shot tools, use `--mode=daemon` so you can update text + progress:

```sh
#!/bin/sh
cd "$(dirname "$0")"
show2.elf --mode=daemon --image="./logo.png" --text="Working..." &
SHOW_PID=$!
sleep 0.5    # let mkfifo land

do_step_1
echo "TEXT:Step 2..." > /tmp/show2.fifo
echo "PROGRESS:50" > /tmp/show2.fifo
do_step_2
echo "PROGRESS:100" > /tmp/show2.fifo
sleep 1
echo "QUIT" > /tmp/show2.fifo
wait $SHOW_PID
```

---

## 7. `auto.sh` semantics

### The user-installable boot hook at `$USERDATA_PATH/auto.sh`

This is the **only** `auto.sh` convention that exists in NextUI. The code:

```sh
# skeleton/SYSTEM/tg5040/paks/MinUI.pak/launch.sh:149-152
AUTO_PATH=$USERDATA_PATH/auto.sh
if [ -f "$AUTO_PATH" ]; then
    "$AUTO_PATH"
fi
```

Same on tg5050 (lines 160-165), with additional `/tmp/nextui_boottime` timestamping bracketing the call.

Documented in user-facing terms:

> `skeleton/BASE/README.txt:152`: NextUI can automatically run a user-authored shell script on boot. Just place a file named `auto.sh` in `/.userdata/<DEVICE>/`. If you're on Windows, make sure your text editor uses Unix line-endings (eg. `\n`), these devices usually choke on Windows line-endings (eg. `\r\n`).

(Note: the README says `<DEVICE>` but the actual code uses `$PLATFORM`. On tg5040 this is `/mnt/SDCARD/.userdata/tg5040/auto.sh`.)

### Per-PAK `auto.sh` — there isn't one

Searches across the NextUI source tree:

```
$ grep -rn "auto.sh" upstream/nextui/src/workspace/
(no matches in C code)

$ grep -rn "auto.sh" upstream/nextui/src/skeleton/
… only MinUI.pak/launch.sh files, all referencing $USERDATA_PATH/auto.sh
```

There is **no per-PAK `auto.sh` convention** in NextUI itself. nextui.c does not look for `auto.sh` in any pak directory; MinUI.pak/launch.sh only looks for one in `$USERDATA_PATH`.

If a sprint spec claims per-PAK `auto.sh` is a thing, that is a community convention some third party invented (or a misreading) — not a NextUI feature. To get a per-pak hook to run on boot, a Tool PAK must **install itself** into the global `$USERDATA_PATH/auto.sh` (appending a line, idempotently), which is exactly what `Continuity.pak/launch.sh` does at lines 25-43 of `build/Continuity.pak/launch.sh`.

### When and how often `auto.sh` runs

- **Once per boot**, before the main NextUI menu loop is entered.
- **Blocking** — MinUI.pak's launch.sh waits for `auto.sh` to return before proceeding to `nextui.elf`. So any work `auto.sh` does delays the menu appearance by that much.
- If `auto.sh` needs to launch a daemon, it **must background it explicitly** (`my_daemon.sh &`) and ideally detach (`nohup my_daemon.sh </dev/null >/dev/null 2>&1 &` or `setsid`) so that it doesn't accidentally inherit the controlling tty/pgroup.
- `auto.sh` does **not** re-run when the user exits a game or a tool — only at full boot. Subsequent passes through MinUI's outer while-loop do not re-invoke it.

### Implications for daemon design

A daemon installed via auto.sh:

- Starts once per boot.
- Survives across game/tool launches (because MinUI's outer loop only restarts `nextui.elf`, not the device — and only `show2.elf` is `killall -9`'d).
- Does not survive reboot/poweroff unless launched again from auto.sh.
- Inherits the exported environment from MinUI.pak/launch.sh at the time auto.sh ran (`$SDCARD_PATH`, `$USERDATA_PATH`, `$PLATFORM`, `$DEVICE`, etc.).

---

## 8. Conventional background-daemon launch on NextUI

Within the NextUI source itself, the canonical examples of daemons launched from `MinUI.pak/launch.sh` are:

```sh
# skeleton/SYSTEM/tg5040/paks/MinUI.pak/launch.sh:112, 119-124
trimui_inputd &
keymon.elf & # &> $SDCARD_PATH/keymon.txt &
batmon.elf & # &> $SDCARD_PATH/batmon.txt &
audiomon.elf & # &> $SDCARD_PATH/audiomon.txt &
```

So the stock pattern is dirt-simple: `binary &`. Stdio is inherited but typically redirected to a log file by uncommenting `&> $SDCARD_PATH/<name>.txt`. There's no use of `nohup` or `setsid` in the stock launcher itself.

The `PAKS.md` guidance for daemons is in the "Brightness and Volume" section (lines 88-103):

```sh
# PAKS.md:91-92
syncsettings.elf &
./DinguxCommander
```

…or for daemons that need to be restarted on a loop:

```sh
# PAKS.md:95-103
while :; do
    syncsettings.elf
done &
LOOP_PID=$!

./PPSSPPSDL --pause-menu-exit "$ROM_PATH"

kill $LOOP_PID
```

### Community convention for a persistent daemon installed by a Tool PAK

Search for community-bundled tools that install a long-running daemon turns up only `LedControl.pak` in-tree, which:

- On first launch, copies its configuration files to `$SHARED_USERDATA_PATH` (lines 14-29).
- Then runs `./ledcontrol.elf > ledcontrol.log 2>&1` (line 31) — a foreground program that itself handles input and runs an SDL window.

So `LedControl.pak` is **not** a persistent-daemon installer; it's an interactive configurator that writes a config file the actual LED daemon (started elsewhere — see `MinUI.pak/launch.sh:60-67` where the old LedControl daemon is _removed_) reads. The actual daemon must be running from elsewhere — apparently from `auto.sh`-equivalent or a system-level service, but NextUI's own deletion of `/etc/LedControl` in lines 60-67 suggests the original community pattern was to install a daemon under `/etc/init.d/`, which NextUI now actively cleans up.

The takeaway: **the stock NextUI source contains no installed-daemon-by-Tool-PAK example.** Continuity's pattern of "Tool PAK launches once, installs itself into `$USERDATA_PATH/auto.sh`, on subsequent boots auto.sh starts the daemon" is therefore the right architecture — it just isn't pioneered by an existing pak in-tree. Externally, community PAKs (e.g. for syncthing, ftpd, wifi sharing) follow the same pattern.

For such a daemon installer, the recommended structure:

- **Installation:** PAK launch.sh on first run, idempotently appends a guarded line to `$USERDATA_PATH/auto.sh` (creates the file if absent). Marker file under `$SHARED_USERDATA_PATH/.<paknname>/installed` or similar to track first-run vs subsequent.
- **First-run vs subsequent:** Check marker file. First-run: do install, show "Installed — reboot to activate" via show2 with `--timeout`. Subsequent: show daemon status (last log line, PID present, etc.) via show2 with `--timeout`.
- **Logging:** Daemon writes to `$USERDATA_PATH/logs/<daemon>.log` or `$SHARED_USERDATA_PATH/<paknname>/<daemon>.log`.
- **Status to user:** Tool PAK launch.sh reads the log file or queries the daemon (e.g. `pgrep` for the PID), uses `show2.elf --mode=simple --timeout=3` to display.
- **Surviving reboots:** Achieved by living in `$USERDATA_PATH/auto.sh`. Cleaned up only if the user manually edits or deletes that file.

---

## 9. Other things third-party developers commonly get wrong

1. **Forgetting `cd "$(dirname "$0")"`.** Stock paks do this universally. Without it, every `./binary` reference fails.

2. **`#!/bin/bash` instead of `#!/bin/sh`.** TrimUI Brick/Smart Pro do not have `/bin/bash` (BusyBox ash only). The script silently fails to start. Stock paks all use `#!/bin/sh`.

3. **Windows line endings.** README.txt:152 calls this out explicitly. Symptoms: cryptic "command not found" with the trailing `\r` invisible in the error, or the whole script "starts" but the shebang interpreter can't be found. Use `dos2unix` or ensure your editor uses LF.

4. **Assuming a TTY.** Tool PAKs have no terminal. `read`, `tput`, `clear`, color escapes — all useless.

5. **Assuming `LD_LIBRARY_PATH` includes the pak's own `lib/`.** It doesn't. If you bundle your own `.so` files, add their dir explicitly: `export LD_LIBRARY_PATH="$(pwd)/lib:$LD_LIBRARY_PATH"`.

6. **Assuming binaries are executable.** When the pak is delivered via `.pakz` (zipped), extraction preserves Unix permissions, but if a developer scp's the pak from a Windows machine or via SMB, executable bits may be lost. Stock paks ship `-rwxr-xr-x` on `launch.sh` and on all `.elf` binaries. The `LedControl.pak/launch.sh` from skeleton actually has mode `0644` (not executable!) — relying on MinUI's `eval $CMD` not actually exec'ing the file but interpreting it as a shell command in a sub-shell. Even so, the safer bet is `chmod +x launch.sh`.

7. **`show2.elf` path differences across platforms.** On tg5040 it's `/mnt/SDCARD/.system/tg5040/bin/show2.elf`; on tg5050 it's `/mnt/SDCARD/.system/tg5050/bin/show2.elf`. **Always invoke as `show2.elf` (unqualified)** so that `$PATH` resolves correctly per platform, rather than hardcoding the absolute path.

8. **Long path with spaces in `cmd[256]`.** nextui.c builds the command into a fixed 256-byte buffer (`workspace/all/nextui/nextui.c:1228`). A pak placed at a deep path with a long name could overflow this. Not normally hit but worth knowing.

9. **Calling `killall show2.elf` from within your own launch.sh** — this can race with MinUI's own `killall -9 show2.elf` at the next loop iteration, but more importantly, if your launch.sh starts a show2 daemon, exits, and expects show2 to persist: it won't. MinUI kills it.

10. **Daemon launched from launch.sh expected to survive past launch.sh exit.** When launch.sh exits and MinUI loops, the daemon's parent shell goes away. If the daemon was started with `&` it should keep running (reparented to init), but if the daemon's stdin/stdout/stderr is still tied to the (now-gone) shell, it may receive SIGPIPE or SIGHUP. Use `daemon_cmd >/dev/null 2>&1 </dev/null &` and ideally `setsid` to fully detach. The correct architectural choice is "install daemon launch into `$USERDATA_PATH/auto.sh`, daemon runs from boot, Tool PAK only reports status" — which is exactly Continuity's design.

11. **`exec 2>>./launch_debug.log` traps script stderr but not subprocess stderr by default if subprocesses are re-redirected.** Helpful for diagnosing; not problematic.

12. **`set -x` adds noise but no display.** Useful for log inspection later.

13. **Black background + same-color text in `show2.elf`.** Default `--bgcolor=0x000000` and `--fontcolor=0xFFFFFF` is fine; but `--bgcolor=0x000000 --fontcolor=0x000000` produces invisible text. Verify color contrast.

14. **`show2.elf` without text rendering only the logo.** If `font_size` is too small to render the embedded font at all, text disappears. Default 24 is fine.

15. **Background daemon writing to a file under `/tmp/`.** `/tmp` is tmpfs and is cleared at boot. Logs you want to persist must go under `$USERDATA_PATH/logs/` or `$SHARED_USERDATA_PATH/`.

16. **Reliance on `wifion`/Bluetooth state at PAK launch time.** WiFi init is backgrounded (lines 142-145 of MinUI.pak/launch.sh) — it may not be up by the time your Tool PAK runs the first time. Daemons that need network must wait or retry.

17. **First-run state under `$SDCARD_PATH/.continuity/` vs `$SHARED_USERDATA_PATH/<pak>/`.** NextUI updates _delete_ `.system/` but _do not_ delete `.userdata/`. Storing your state under `$SHARED_USERDATA_PATH` (i.e. `/mnt/SDCARD/.userdata/shared/`) is the convention used by LedControl.pak (lines 14-29). State directly under SD card root (`/mnt/SDCARD/.continuity/`) is fine but is "user-visible" and may be cleaned by users who don't know what it is.

---

## Open questions

Items not fully determinable from local source:

1. **Exact SDL surface size returned by show2.elf on the device.** show2 calls `SDL_CreateWindow("", UNDEFINED, UNDEFINED, 0, 0, SDL_WINDOW_SHOWN)`. On the Brick/Smart Pro, this should yield a full-screen surface matching the panel resolution (likely 1024×768 on Brick, 1280×720 on Smart Pro) but the SDL backend behavior depends on the TrimUI SDL build. If `screen->w` or `screen->h` is 0, text drawn at `(screen->h * 80) / 100` lands at y=0 and may be invisible against the bg. Verify on hardware by reading `$USERDATA_PATH/logs/` or strace.

2. **Whether the framebuffer is fully cleared between show2's window destruction and nextui.elf's startup.** Empirically there is a brief moment of "stale framebuffer contents." Worst case is undefined garbage; typical case is black.

3. **Whether `eval $CMD` failing (e.g. launch.sh has a parse error) gets logged anywhere.** stdout/stderr of the MinUI.pak shell at that point go to whatever launched MinUI.pak — usually a system log file under `/var/log/` or `/tmp/`. Need to inspect a real device to confirm where script errors land.

4. **The exact behavior of `--logoheight=1` rendering.** show2 calls `SDL_BlitScaled` to scale the logo to 1px tall. SDL2's scaler may produce undefined results for such an extreme downscale (potential black 1×N artifact). Practical effect on the device: needs visual confirmation. The arithmetic in show2 is well-defined; rendering artifacts are SDL-dependent.

5. **Is there a per-pak install/uninstall hook NextUI calls?** Searched for `install.sh`, `uninstall.sh`, `setup.sh` patterns in the nextui.c source — only `post_install.sh` for `.pakz` extraction (referenced in `boot-flow-analysis.md:42` and `show2/boot-integration-example.sh:82`). No per-pak hook for Tool PAKs run by NextUI directly. Tools self-install by checking a marker file on first launch (the pattern Continuity uses).

6. **Whether MinUI's `killall -9 show2.elf` kills a show2 daemon a Tool PAK started in the background.** Almost certainly yes — `killall -9 show2.elf` kills _all_ processes with that exe name regardless of who started them. So any show2 daemon a Tool PAK spawned and didn't itself kill before exiting will be terminated by MinUI on the next outer-loop iteration. Need to verify the timing — there's a small window between the pak's exit and the next `killall`, but the kill happens before nextui.elf re-launches.

7. **Exact failure semantics of `auto.sh` returning non-zero.** `MinUI.pak/launch.sh:150-152` calls `"$AUTO_PATH"` with no checking of return code. If `auto.sh` exits non-zero, the launcher continues regardless. There is no surfacing of auto.sh failures to the user.
