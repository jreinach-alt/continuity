# Sprint 2.1 — RetroDeck PAL + Enrollment (Steam Deck)

**Status:** Draft — awaiting owner approval AND the on-device recon
confirmation (§Recon gate below). Do not implement until both land.
**Branch:** `claude/sprint-2.1-retrodeck-9a0mqd` → PR to `main` (owner
merges). No remote CI — `scripts/gate.sh full` is the verification.
**Kickoff:** `docs/sprints/sprint-2.1-retrodeck-kickoff.md`.
**Reference Specs:** `docs/design/pal.md` (incl. 2026-07-07 addendum),
`docs/design/save-format-canonicalization.md`,
`docs/design/nextui-format-matrix.md`, `docs/design/ui-design-system.md`
(Tier 1 framing only — no UI ships this sprint).

## Goal

Bring Continuity up on the Steam Deck running RetroDeck: a PAL, a
desktop CLI enrollment, and a `systemd --user` daemon skeleton, with all
core sync phases working unchanged through the new PAL. Second real
device; gates Sprint 2.3 (Brick↔Deck cross-device).

## Recon findings (pinned to upstream source, 2026-07-09)

Sources: `github.com/RetroDECK/RetroDECK` @ main (latest release
0.10.9b, 2026-05-30) and `github.com/RetroDECK/components`
(`retroarch/rd_assets/rd_config/retroarch.cfg`). Clones inspected
directly; facts below cite file:line-style locations.

1. **Saves do NOT live in the Flatpak data dir.** The kickoff's
   `~/.var/app/net.retrodeck.retrodeck/data/saves/` assumption (and the
   informational `saves_root` in `config/platform_maps/retrodeck.json`)
   is stale. RetroDeck keeps user content under **`rdhome`** (default
   `/home/deck/retrodeck`, template `config/retrodeck/retrodeck.json`):
   `saves_path=$rdhome/saves`, `states_path=$rdhome/states`,
   `roms_path=$rdhome/roms`. All paths are **user-relocatable** (SD-card
   installs), so the PAL must read them from RetroDeck's live config,
   never hardcode.
2. **Live config location:** `functions/all_vars.sh:4` —
   `rd_conf="$XDG_CONFIG_HOME/retrodeck/retrodeck.json"`, i.e. host path
   `~/.var/app/net.retrodeck.retrodeck/config/retrodeck/retrodeck.json`.
   Same in the 0.10.9b tag. (Pre-0.10 installs used `retrodeck.cfg`
   shell-var format; the recon script reports whichever exists.)
3. **RetroArch save settings (shipped defaults,** `components` repo
   `retroarch/rd_assets/rd_config/retroarch.cfg:3232-3278`**):**
   - `save_file_compression = "false"` → **raw `.srm`** — confirms
     `save_container: raw` in the v2 platform map; no RZIP quarantine
     expected on a default Deck (Decision 1A stays as the safety net).
   - `savefile_directory = "RETRODECKHOMEDIR/saves"`,
     `sort_savefiles_by_content_enable = "true"`,
     `sort_savefiles_enable = "false"`, `savefiles_in_content_dir =
     "false"` → saves land at `$rdhome/saves/<romdir>/<Rom Name>.srm`
     where `<romdir>` is the ROM's immediate parent directory — the
     ES-DE system folder (`gb`, `gba`, `megadrive`, …) in the standard
     flat layout. RetroArch strips the ROM extension → **`retroarch`
     name style confirmed** in the v2 map.
   - `savestate_file_compression = "true"` → states WILL be
     RZIP-compressed. Fine: states are opaque one-way backups and may
     archive compressed bytes verbatim (format-matrix §7).
   - **Caveat:** content-dir sorting keys on the ROM's *immediate*
     parent dir. A nested layout (`roms/gba/hacks/x.gba`) produces
     `saves/hacks/` — outside the taxonomy. The recon script detects
     nested ROM dirs; a nested layout is reported, unsupported in 2.1.
4. **Flatpak sandbox (daemon-placement evidence),**
   `net.retrodeck.retrodeck.yml` finish-args**:** `--filesystem=host`,
   `--share=network`, but **no `--talk-name=org.freedesktop.Flatpak`**
   — the sandbox cannot spawn host processes (`flatpak-spawn --host`
   unavailable), while the host can read/write everything RetroDeck
   touches (`rdhome` is a plain host path precisely so users can put it
   on external media).
5. **Host tooling:** SteamOS ships `bash`, `systemd --user`, `curl`;
   community reports show `/usr/bin/git` present on SteamOS 3.x but it
   is not contractual across updates — **recon item R5**, with a
   fallback plan (§Contingencies). `inotifywait` availability is a
   Sprint 2.2 concern (poll loop suffices for 2.1).

## Decision — daemon placement: host-side `systemd --user` service

The kickoff's options (a) host process against the data path and (c)
systemd user service are the same thing done properly; **(b)
inside-the-sandbox is rejected on manifest evidence**: no
`org.freedesktop.Flatpak` talk-name (no host spawn), no git in the
RetroDeck runtime, and daemon lifecycle would couple to app updates.

The daemon runs **on the host, as the login user's `systemd --user`
service**, reading save paths from RetroDeck's own config:

- Saves/states/ROMs are plain host paths (finding 1) — no sandbox
  boundary to cross, ever.
- System git + full network on the host; nothing RetroDeck does can
  break the daemon and vice versa.
- systemd owns lifecycle: start on login (both Game Mode and desktop
  sessions run the user manager), `Restart=on-failure`, journald
  logging, `systemctl --user stop` sends SIGTERM → the same graceful
  final-push shutdown the Brick daemon does.
- No PID-file dance needed — systemd guarantees single instance.

## In scope (file table)

| # | File | What |
|---|------|------|
| 1 | `src/platforms/retrodeck/deck_recon.sh` | Read-only on-device recon (already on branch — recon tooling, not product code). Owner runs it once; output gates implementation. |
| 2 | `src/platforms/retrodeck/pal_retrodeck.sh` | The PAL. Derives `CONTINUITY_SAVES_ROOT`/`CONTINUITY_STATES_ROOT`/`CONTINUITY_ROMS_ROOT` from `rd_conf` (env overrides win, per PAL addendum); `CONTINUITY_REPO_DIR` default `${XDG_DATA_HOME:-$HOME/.local/share}/continuity/repo`; `CONTINUITY_PLATFORM=retrodeck`; `CONTINUITY_GIT_BIN` = system git; `pal_init` (device name from repo `.continuity/device_name`, git + saves-root existence checks, named error "RetroDeck not initialized — launch it once" when `rd_conf` missing); `pal_is_online` (ping → curl fallback, honors `CONTINUITY_FORCE_ONLINE`); `pal_log` (stderr; journald captures); `pal_get_platform_map` (installed config path relative to `CONTINUITY_APP_DIR`). |
| 3 | `src/platforms/retrodeck/enroll_retrodeck.sh` | Desktop CLI enrollment. Args: `--repo-url`, `--device-name` (validated `[a-z0-9-]`, default `steam-deck`); PAT read from a silent stdin prompt or `--pat-file` (never argv — `ps` exposure). Runs core `enroll_run` (clone, credential store 0600, device JSON, push), then installs + enables the systemd unit (`--no-service` to skip). Headless-git safety per PAL addendum (`GIT_TERMINAL_PROMPT=0`). |
| 4 | `src/platforms/retrodeck/continuity_daemon.sh` | Daemon entry point: source PAL + core modules (same order as NextUI daemon), `pal_init`/`pal_validate`/`se_init`/`pm_load_platform_map`, boot dispatch (cold/stale/normal — same `cs_is_cold_start`/`sb_is_stale` routing), 30s poll loop reusing the NextUI daemon's poll-cycle semantics (deferred-cold-start retry, WiFi-recovery push, in-session reconcile w/ cooldown), SIGTERM → final sweep + push + conditional clean-shutdown marker. No busybox re-exec, no PID file (systemd), no SD-card enrollment. `CONTINUITY_DAEMON_NO_MAIN` test hook kept. |
| 5 | `src/platforms/retrodeck/continuity.service` | `systemd --user` unit (data file): `ExecStart` the daemon, `Restart=on-failure`, `After=network-online.target` best-effort, installed to `~/.config/systemd/user/` by enrollment. |
| 6 | `config/platform_maps/retrodeck.json` | **Informational fields only:** correct `saves_root` + `_saves_root_note` to the rdhome truth (finding 1), add `_states_note` re compressed states. The v2 contract fields (`save_name_style: retroarch`, `save_container: raw`) are confirmed by recon findings 3 and stay untouched pending device confirmation. |
| 7 | `tests/unit/platforms/retrodeck/test_pal_retrodeck.sh` | PAL unit tests (see Tests). |
| 8 | `tests/unit/platforms/retrodeck/test_enroll_retrodeck.sh` | Enrollment unit tests. |
| 9 | `tests/integration/test_retrodeck_flow.sh` | Full-phase integration through the RetroDeck PAL. |
| 10 | `docs/sprints/sprint-2.1-summary.md` | Handoff artifact (at completion). |
| 11 | `docs/platform/retrodeck-field-notes.md` | Created during on-device validation (hardware-validated traps, NextUI-field-notes analog). |

**No `src/core/**` changes.** If implementation finds one is required,
stop and escalate (kickoff ground rule). `scripts/test.sh` already
discovers `tests/unit/**/test_*.sh` — no runner changes.

## PAL derivation contract (the platform-specific heart)

- `RD_CONF` env-defaulted to
  `$HOME/.var/app/net.retrodeck.retrodeck/config/retrodeck/retrodeck.json`.
  `pal_init` extracts `saves_path`/`states_path`/`roms_path` with
  `sed` (no jq dependency), honoring pre-set `CONTINUITY_*` env (test
  sandboxes redirect everything, per the PAL addendum). Legacy
  `retrodeck.cfg` fallback: parse `saves_folder`/`states_folder`/
  `roms_folder` shell-var syntax.
- Every derived path is validated to exist at `pal_init`; failures are
  named on stderr (observability rule) — "RetroDeck config not found",
  "saves path from retrodeck.json does not exist", etc.
- Platform scripts are POSIX sh that MAY call full-Linux tools
  (systemctl, curl); they must parse clean under `busybox ash -n`
  because the test suite runs them under ash. (Bash is allowed by
  CLAUDE.md for retrodeck but nothing here needs it — staying POSIX
  keeps the one test interpreter.)

## Acceptance criteria

1. **PAL:** parses a real-shaped `retrodeck.json` fixture (paths with
   spaces included) and the legacy `.cfg` shape; pre-set env overrides
   win; missing config / missing saves path / missing git produce the
   named errors; `pal_validate` passes post-init.
2. **Core phases unchanged through the new PAL:** cold start, boot
   pull, runtime poll, stale boot, and two-device conflict preservation
   all pass driven through `pal_retrodeck.sh` against a `file://`
   remote in a sandboxed rdhome layout (`saves/gba/Game Name (USA).srm`
   RetroArch-style names) — zero `src/core/**` diffs.
3. **Canonicalization active:** with the v2 retrodeck map + a sandbox
   `CONTINUITY_ROMS_ROOT`, a repo-canonical save materializes under its
   RetroArch native name only where the matching ROM exists (sparse
   skip otherwise), and an RZIP fixture dropped in the saves tree
   quarantines with the named log line (Decision 1A wiring proven on
   this platform).
4. **Enrollment:** fresh sandbox → clone, credentials 0600, device
   JSON committed + pushed, `device_name` written; systemd unit
   installed + enabled via a mockable `systemctl` (test stub);
   `--no-service` skips; invalid device names rejected; PAT never
   appears in argv or logs.
5. **Daemon:** boot dispatch routes correctly (cold/stale/normal);
   poll cycle idempotent; SIGTERM → final sweep, push, clean-shutdown
   marker only when nothing unpushed (mirrors Brick semantics, tested
   by sourcing with `CONTINUITY_DAEMON_NO_MAIN=1`).
6. **Gate:** `scripts/gate.sh full` green — both privilege passes, all
   artifacts under `$TMPDIR` with per-process names.
7. **On-device (owner-run, after merge-ready):** `deck_recon.sh`
   findings confirmed; real enrollment on the Deck; one real save
   round-trips Deck → repo → Deck (cold start + poll detect); daemon
   survives a Game Mode session and a reboot. Results recorded in the
   field notes doc. (Brick↔Deck cross-device is Sprint 2.3, not here.)

## Tests required

- **Unit — PAL:** rd_conf JSON parse (default layout, SD-card paths,
  spaces), legacy cfg parse, env-override precedence, each named
  failure mode, `pal_is_online` force-override.
- **Unit — enrollment:** arg validation, PAT via stdin/file (argv
  scan), core-enrollment wiring against `file://`, systemctl stub
  (records calls), `--no-service`.
- **Integration:** `test_retrodeck_flow.sh` — enrollment → cold start
  with RetroArch-named saves → poll-detected change → boot pull →
  stale recovery → conflict preservation, all through the RetroDeck
  PAL; plus the quarantine + sparse-materialization assertions (AC3).
- All tests busybox-ash, self-contained, unprivileged-safe (no fixed
  /tmp names).

## Recon gate (owner action before implementation is merged)

Run on the Deck in desktop mode and send back the report:

```sh
cd ~/Downloads   # anywhere writable
sh /path/to/deck_recon.sh
# → CONTINUITY_DECK_RECON.txt
```

Items the report must confirm (R1–R5): **R1** `retrodeck.json` present
+ real `saves_path`/`roms_path`; **R2** real `.srm` filenames match
RetroArch style (`Name.srm`, no ROM ext); **R3** container sniff shows
raw (0 compressed) — if compressed appears, those saves quarantine
(Decision 1A) and the owner flips RetroArch's `save_file_compression`
off; **R4** flat `roms/<system>/` layout (no nested ROM dirs); **R5**
host `git` present + version. Implementation may start on owner
approval; anything the report contradicts amends this spec first
(small deltas noted in the summary, structural ones re-approved).

## Contingencies

- **R5 fails (no host git):** fall back to a static x86_64 git built
  by the existing `build_git.sh` pipeline (native build, not
  cross-compile), installed under `~/.local/share/continuity/bin` and
  pointed to by `CONTINUITY_GIT_BIN`. Scoped as a spec amendment —
  not built speculatively.
- **rd_conf format drifts** (RetroDeck 1.0 rework): the PAL's parse is
  isolated in one function with both shapes tested; a third shape is a
  small patch, and `pal_init` fails **named**, never wrong-path-silent.

## Out of scope

- Conflict-resolution UI on the Deck (Tier 1/2 per the UI design
  system) — later sprint; 2.1 ships no UI beyond CLI output.
- `inotifywait` event-driven detection — Sprint 2.2 (polling is fine).
- Brick↔Deck cross-device test — Sprint 2.3 (gated on this sprint).
- RZIP codec integration (Phase 3); compressed saves quarantine.
- Save-state restore/sync (S1–S3 track); states remain one-way backup.
- RetroDeck multi-user mode (`multi_user_mode=true` symlinked configs).
- Packaging/OTA for the Deck (installation = checkout/unpack for now;
  a versioned delivery artifact is a later sprint).
- Nested ROM directory layouts (recon detects; unsupported in 2.1).

## Coordination

Owns `src/platforms/retrodeck/**` (+ the two informational fields in
`config/platform_maps/retrodeck.json`). Disjoint from Onion 3.1
(`src/platforms/onion/**`) and conflict-UI work (`src/core/conflict_ui.sh`).
New unit-test directory `tests/unit/platforms/retrodeck/` collides with
no one.
