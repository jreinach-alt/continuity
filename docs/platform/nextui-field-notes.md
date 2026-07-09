# NextUI / TrimUI Brick — Field Notes

Hardware-validated facts from the Phase 1 bring-up (2026-07-06/07).
Every item here cost real debugging time; read this before touching the
NextUI platform code. Companion docs:
`docs/design/nextui-tool-pak-research.md` (PAK mechanics, upstream-cited),
`docs/design/pak-launch-failure-findings.md` (launch-chain forensics),
`docs/sprints/sprint-1.1-1.3-summary.md` (defect history).

## Delivery pipeline (how bits reach the card)

- **Never distribute from a git working tree.** The user's clone predated
  `.gitattributes` with `autocrlf=true`: files untouched by later commits
  kept CRLF forever while changed files were re-smudged to LF — a mixed
  tree that `git status` calls clean. Cost three device round-trips.
- **Ship zips built here**: `scripts/build_pak.sh` → verify → zip named
  `Continuity.pak-<version>.zip`. Browser download → Windows Extract-All
  → Explorer copy → exFAT preserves bytes end-to-end.
- **Version stamps are minute-granular** (`0.1.0-YYYYMMDD-HHMM`) and shown
  on-screen + in `launch.log`. Two same-day builds once got confused;
  never again.
- **The card must be ejected properly** — exFAT + Windows lazy writes can
  leave large binaries truncated. Preflight's checksum verification
  catches this and says so on screen.
- The user's working copy lives in **OneDrive on Windows** — a known
  source of stale reads and git index weirdness. Not our problem anymore
  (zip delivery), but never ask them to copy from the tree.

## Filesystem: exFAT (not FAT32 as older docs said)

Behaviorally identical for us: no permission bits (the device mounts
everything executable — proven by every stock pak), **no symlinks**
(ship real file copies; git's `git-remote-https → git-remote-http`
symlink must be materialized), coarse mtimes, no atomic rename
guarantees worth trusting. `sync` after every important write.

## The bundled git (the hard-won part)

- Layout must mirror a real install: `bin/git` AND
  `libexec/git-core/{git, git-remote-http, git-remote-https}` AND
  `share/ca-bundle.crt` AND `share/templates/`.
- **git spawns transport helpers as `git remote-https <remote> <url>`**
  (`transport-helper.c`, `git_cmd=1`) — the exec path must contain **git
  itself**, or every https operation fails with the misleading
  `unable to find remote helper for 'https'` (`silent_exec_failure`).
  Both helper names are required (transport re-invokes the canonical
  `http` name).
- Env wiring (exported by `pal_nextui.sh`, re-defaulted as belts in
  `esd_import` and the preflight probe): `GIT_EXEC_PATH`,
  `GIT_SSL_CAINFO`, `GIT_TEMPLATE_DIR`, plus PAK `bin/` on `PATH`.
- Hang-proofing for headless git: `GIT_TERMINAL_PROMPT=0` (a failed
  credential helper otherwise prompts /dev/tty forever — no keyboard
  exists) and `GIT_HTTP_LOW_SPEED_LIMIT/TIME` (abort stalled transfers).
- CA bundle is the **pristine Mozilla bundle from curl.se** — never the
  build host's system bundle (it contains the CI proxy's CA).
- Build: `scripts/build_git.sh` — plain `gcc-aarch64-linux-gnu`, static
  zlib/openssl(3.0 LTS)/curl/git, canonical non-GitHub mirrors
  (github.com release downloads are blocked from the build container).

## Validation protocol (before ANY binary ships)

1. `scripts/build_pak.sh` (writes version, channel, checksums manifest).
2. qemu smoke: the shipped `bin/git` under `qemu-aarch64-static` runs
   `--version`, `init`, and a **live GitHub clone**.
3. **Hide the host git** (`mv /usr/bin/git`) during validation — the
   `git remote-https` re-invocation silently falls through to the system
   git otherwise, which once produced a false "validated" stamp.
4. Shim every ARM→ARM exec edge explicitly (host shell scripts named
   `git`, `git-remote-http(s)` that qemu-wrap the PAK binaries).
   **Do not use binfmt_misc**: a one-byte mask mistake made every
   process spawn in the container loop through qemu (recovered only via
   direct procfs writes).
5. Full suite (`scripts/test.sh`) — all tests run under `busybox ash`.

## Boot & runtime environment

- Only boot hook: the single user script `$USERDATA_PATH/auto.sh`
  (tg5040 → `/mnt/SDCARD/.userdata/tg5040/auto.sh`). **No per-PAK
  auto.sh exists** — Sprint 1.1's draft was wrong about this.
- The daemon must be fully detached: `</dev/null >/dev/null 2>&1 &`.
- **WiFi races auto.sh at boot** — `wifi_init.sh start` is backgrounded
  seconds earlier. The daemon waits (bounded, 12×5s) for
  `pal_is_online` before boot enrollment.
- A wrong device clock breaks TLS certificate validation; preflight
  checks the year and says so on screen.
- MinUI env available to paks: `PLATFORM=tg5040`, `SDCARD_PATH`,
  `USERDATA_PATH`, `DEVICE=brick`, PATH includes `$SYSTEM_PATH/bin`
  (hence bare `show2.elf`). We default every one we use.

## Display (show2.elf) and input

- `show2.elf` renders ONE text line; args must be `--key=value` (a space
  after the key silently discards the value); `--timeout=N` or it blocks
  forever; daemon mode + FIFO `/tmp/show2.fifo` for live updates;
  1024px panel fits ~64 chars at fontsize 28.
- Buttons via `/dev/input/js0`, 8-byte js_event records; tg5040 numbers:
  **B=0, A=1, Y=2, X=3** (upstream `platform.h` JOY_* — includes the
  official "swapped in first release" comment). One persistent open
  (joydev replays init events per open; init flag 0x80 must be filtered).
  Unmapped numbers are logged so new devices self-document.

## Diagnostics contract (keep these working)

- `<PAK>/launch.log` — one build-stamped line per launch, unconditional.
- `CONTINUITY_DIAGNOSTIC.txt` at SD root — full preflight report
  (clock, CRLF, git, helper exec, checksums, network, live TLS probe,
  masked setup.json, buttons, space).
- `.continuity/enroll.log`, `.continuity/continuity.log`,
  `.continuity/update.log` — enrollment / daemon / OTA.
- On-screen: every failure names itself + build stamp; X/Y replays the
  log during enrollment; B cancels (setup.json is preserved for retry).

## OTA (Sprint 1.6, channels reworked in 1.8)

- `scripts/update.sh`: persistent sparse clone (`--filter=blob:none`,
  fallback plain shallow) of the public project repo at
  `.continuity/ota-repo`, sparse path `build/Continuity.pak` — an update
  is "sync the tracked PAK folder". Verify fetched tree (CRLF +
  checksums) before staged copy; binaries only rewritten when size
  differs; commit recorded in `.continuity/.ota_commit`.
- **Channels are data on main, not branches** (the original
  channel-follows-build-branch design died the moment its branch did —
  owner-caught at PR time). The device's durable channel name
  (stable/nightly) lives in `.continuity/ota_channel` — seeded once
  from the build's `ota_channel.txt`, never overwritten by installs.
  Each check fetches main, reads `release/channels.json` via `git
  show` (no checkout), and fetches the channel's PINNED commit
  (GitHub serves reachable SHAs; file:// test remotes need
  `uploadpack.allowAnySHA1InWant`). Unpublished commits on main are
  invisible to devices. Publish/promote/rollback =
  `scripts/publish_channel.sh` manifest commits; the manifest must be
  reachable from origin/main to take effect.
- **Legacy fallback (migration)**: manifest unreachable or channel
  missing → the channel value is treated as a branch name and the old
  fetch-a-branch flow runs. Pre-manifest devices self-migrate: their
  old branch serves them the new updater once, which then reads the
  manifest. Remove in Phase 2.
- UI: on pak tap when enrolled — "Update available: X installs, B skips".
  Changes take effect next boot. `CONTINUITY_OTA=0` kill switch.
- **Card swaps remain necessary only for**: a broken update.sh/launch.sh
  chain (bootstrap), and binary-toolchain changes too risky to trust to
  a partial copy.

## SRAM flush timing (why "save and keep playing" syncs nothing)

`minarch` writes the `.srm` file ONLY at: game exit (`Core_quit`,
minarch.c:6146), device sleep (`Menu_beforeSleep`, :6269), and MENU-button
press (:8492). **There is no periodic in-game SRAM flush** — an in-game
save updates emulated memory only. The sync story for users is therefore:
"your save reaches the cloud when you take a break" (open the menu, sleep
the device, or quit the game); the daemon's 30s poll picks the file up
from there. Any smoke test must include a MENU press or game exit between
saving and expecting a commit.

## Security notes

- PAT: fine-grained, ONE repo (the saves repo), Contents read/write
  only. Never logged — preflight masks it to a length. Stored on card:
  scope IS the security boundary.
- OTA fetches the PROJECT repo anonymously (it is public — verified from
  the device itself by the preflight ls-remote probe).

## Save format reality (field, 2026-07-07)

- NextUI's COMPILED default save format is `.sav` (`config.h:180
  CFG_DEFAULT_SAVEFORMAT = SAVE_FORMAT_SAV`); `.srm` variants exist
  (SAVE_FORMAT_SRM is rzip-COMPRESSED). Scanners match both `*.srm` and
  `*.sav`; contents are opaque blobs to the sync engine. Canonical
  cross-platform extension normalization is deferred to the Phase 2
  mapper spec (matters when the second platform arrives).
- The platform NEVER SIGTERMs the daemon on reboot/poweroff — every boot
  is a "stale" boot. That's by design tolerable (stale recovery is the
  normal path), and it's why cd_shutdown may never run: do not rely on
  it exclusively. The shutdown sweep exists for the graceful case; the
  stale-boot catch-up covers the rest.
- "Save → quit game → power off" is the canonical user flow: the .srm
  flushes at quit and the daemon may be killed before the next 30s poll.
  Covered twice: cd_shutdown runs a final rp_run sweep (graceful case),
  and next boot's stale catch-up commits anything missed (kill case).

## Save STATES (.st0-.st9) — scope decision (2026-07-07)

Game-switcher/quicksave states live at `.userdata/shared/<TAG>-<core>/`
(e.g. SFC-snes9x). They are NOT monitored and NOT synced, per the
founding scope: save states are emulator-core-and-version-specific
memory snapshots. A "shared cross-platform format" for states is not
buildable — converting a snes9x snapshot for another core would require
running both emulators; even core VERSION bumps break state loading.
SRAM is the portable format and remains the sync unit.

Recorded as a possible future opt-in (Phase 4 backlog): same-core
best-effort state sync — opaque blobs namespaced `states/<tag>-<core>/`,
delivered only to devices advertising the identical core, never
conflict-merged, size-capped. Requires its own approved spec; do not
implement casually.

## Vendored BusyBox — the daemon's pinned interpreter (2026-07-07)

The device's `/bin/sh` and userland are whatever BusyBox build the
firmware (or fork) shipped — version/applet drift across NextUI forks is
real, and the test suite runs under busybox 1.36.1, not under "whatever
the device has". The PAK now ships `bin/busybox` (static aarch64 1.36.1,
`scripts/build_busybox.sh`) and the daemon re-execs itself under it.

- **Fail-open invariant**: the daemon re-execs ONLY after the binary
  passes an on-device self-test (`busybox ash -c true` + `ash -n` parse
  of the daemon itself). Missing/truncated/wrong-arch binary → daemon
  keeps running under the device shell exactly as before vendoring.
  `launch.sh` and the enrollment UI NEVER use the vendored interpreter —
  the bootstrap/recovery path stays device-native. Kill switch:
  `CONTINUITY_VENDOR_SH=0`. The log names the decision every boot
  ("Interpreter: vendored busybox (pinned)" / "device sh (reason)"),
  and preflight's `busybox` check runs the same self-test, so the
  diagnostic predicts the daemon's choice.
- **Applet pinning** via `CONFIG_FEATURE_SH_STANDALONE` +
  `CONFIG_FEATURE_PREFER_APPLETS`: the vendored ash resolves bare
  command names to its own applets (no symlink farm — exFAT has none).
  Two tiers: NOEXEC/NOFORK applets (find, cut, head, date, rm, cp, mv,
  mktemp, chmod, sha256sum, dd, dirname, basename, mkdir, touch, sync)
  run **in-process**; plain applets (grep, sed, tr, cat, cmp, wc, sleep,
  ping, wget, od — yes, grep and sed are PLAIN in 1.36.1, not NOEXEC)
  re-exec via `/proc/self/exe`, which on-device is a native exec of the
  same binary. If that self-exec ever fails, busybox **falls through to
  normal PATH lookup** (device tools) — fail-open at the applet level
  too. Absolute-path invocations (our bundled git) are never shadowed.
- **qemu testability boundary**: under qemu-user with no binfmt (binfmt
  is forbidden here — see validation protocol) the `/proc/self/exe`
  self-exec ENOEXECs, so the exec-tier applets cannot be demonstrated
  end-to-end in emulation. The validation matrix
  (`scripts/validate_busybox.sh`, run it against the SHIPPED
  `build/Continuity.pak/bin/busybox`) therefore proves three things
  separately: every invocation form via DIRECT dispatch
  (`busybox grep ...`), the in-process tier under `PATH=/nonexistent`,
  and the exec-tier PATH fall-through. The
  lifecycle test re-execs the real daemon under a host busybox to prove
  the re-exec mechanics (same PID — SIGTERM supervision depends on it).
- **Build traps**: busybox 1.36.1 `tc.c` does not compile against
  kernel headers >= 6.8 (`TCA_CBQ_*` removed) — `CONFIG_TC` must be
  off. The final `busybox` binary appears only when make fully
  succeeds; `make ... ; tail log` exit codes lie (the tail's rc wins).
  busybox `ping` needs root for raw ICMP — fine, everything on the
  device runs as root.
- **OTA-safe by construction**: a torn OTA copy of `bin/busybox` fails
  the self-test and the daemon falls back to device sh while preflight
  warns — this is the one binary class that is safe to ship OTA.

## The porcelain-quoting trap (the real "no saves" root cause)

`git status --porcelain` C-quotes any path containing spaces, quotes, or
non-ASCII — i.e. **virtually every real ROM's save filename** — and the
trailing quote defeated the extension grep in `cd_detect_changes`, so
spaced files were copied into the repo tree and then silently never
staged, in every sync phase. Fix: `--porcelain -z` (NUL-delimited output
is never quoted) piped through `tr '\0' '\n'`. Additionally, phase
commit gates now treat `cd_detect_changes` output as authoritative (not
just the current run's copy flag) so files stranded by earlier runs get
committed. ANY new git-output parsing MUST use -z or quotepath-immune
plumbing and be tested with `Name (USA).ext` and apostrophe filenames.

## Real-repo byte sweep (first device's actual files, 2026-07-07)

`continuity-rzip detect` + round-trip run against every file the Brick
actually pushed (the live saves repo, not fixtures):

- `snes/….sfc.sav` — 8,192 bytes, leading zeros, raw SRAM (ALttP's
  exact SRAM size). detect: `raw`. ✓
- `states/SFC-snes9x/….sfc.st0` / `.st9` — 823,407 bytes each
  (same size, different bytes — two distinct snapshots), magic
  **`#!s9xsnp`**: that is **snes9x's NATIVE snapshot serialization**,
  written raw (default `STATE_FORMAT_SAV` → `filestream_write_file`,
  upstream-verified). **It is NOT an RZIP container**, despite being a
  `#`-prefixed magic that reads like a sibling of `#RZIPv\x01#` — easy
  and reasonable to misread from a hex view. detect: `raw`. ✓
- Codec round-trips the real payloads byte-identically (8 KB SRAM →
  153 B; 823 KB state → 88.8 KB) — real states compress ~9:1, relevant
  when Phase 3 considers transfer-size options.
- MinUI naming embeds the ROM extension in BOTH classes (`.sfc.sav`,
  `.sfc.st0`) — direct on-repo confirmation of the canonicalization
  spec's basename rules, and real snes9x states (~800 KB) sit well
  under the 8 MB state cap.

Standing lesson: claims about the user's data get tested against the
user's data — the sweep exists because a source-derived "your repo has
no compressed files" answer (which happened to be right) was rightly
challenged as untested.

Follow-up (same day): the challenge also upgraded the codec's
validation basis from spec-reading to the OS's literal code —
libretro-common's `rzip_stream.c` is now vendored verbatim
(`tools/rzip/reference/`, provenance in its README) and compiled into
an interop oracle on every CI run; the committed rzip fixture is
generated by THAT encoder, and the matrix ran against the real device
files above. Build trap for the oracle: `trans_stream.c` gates its
zlib backend behind `#if HAVE_ZLIB` — without `-DHAVE_ZLIB=1` it
builds fine and then every compressed operation fails at runtime.

## Two-device concurrency (harness-proven, 2026-07-07)

`tests/integration/test_two_device_conflict.sh` drives two fully
enrolled simulated devices against one remote through every sync phase
— no timing, deterministic. It exists because the "never silently
overwrite" promise had only ever been unit-tested in isolation, and on
first run it caught three defects that would have shipped into Phase 2:

- **`.sav` conflicts were not preserved**: the conflict handler's
  pathspec was `'*.srm'` only — a two-device conflict on the Brick's
  DEFAULT format hit "no conflicts, reset to remote", and the stale
  catch-up then re-canonicalized the local bytes: last-writer-wins
  with the loser buried in git history, no `.local`, no `.conflict`.
- **One-sided adds crashed recovery**: `diff HEAD origin/main` lists
  remote-only files too; preserving one cp'd a file that doesn't exist
  locally → conflict handler returned 1 → every subsequent boot failed
  recovery the same way — a PERMANENT wedge. And this path is the
  everyday one: enrollment itself pushes a device-registration commit,
  so "device B joined while device A had queued commits" triggers it.
  Conflicts are now classified: preserve only files existing on BOTH
  sides with different bytes; one-sided adds flow through reset (remote
  add) or device re-sync (local add).
- **The porcelain-quoting trap, third sighting**: `diff --name-only`
  C-quotes spaced paths in BOTH the conflict handler and
  `bp_get_remote_changes` (which also filtered `.srm$` only — inbound
  `.sav` changes never applied to devices). Both now use `-z`.

Design behaviors the harness DOCUMENTS as correct: any device's
enrollment/conflict commit advances the remote, so other devices'
runtime pushes rc-1 until their next boot pull — self-healing, and
poll commits stay queued locally meanwhile. After conflict
preservation, boot-pull deliberately overwrites the device slot with
canonical (the divergent bytes live in `.local`; the conflict UI's
try/resolve flow is how they come back).

## Save states — REVISED decision (owner override, 2026-07-07)

The owner wants states backed up even while non-portable. Shipped as
opaque one-way backup (device → repo only): `.st0`–`.st9` under
`$CONTINUITY_STATES_ROOT` (NextUI: `.userdata/shared/<TAG>-<core>/`)
sync to `states/<dir>/<file>` verbatim, size-capped
(`CONTINUITY_STATE_MAX_KB`, default 8 MB, shared gate across poll and
sweep paths). No restore, no merge, no cross-core promises — restore
semantics need their own spec. Portability position unchanged: states
load only on the core (version) that wrote them.
