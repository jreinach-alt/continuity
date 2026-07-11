# Sprint 3.2a — Android Sync Core + Enrollment (Ayn Thor)

**Status:** Draft v2 — recon COMPLETE (both runs 2026-07-10; gate
CLOSED, R1–R6 all settled — findings below), R3 decided (by-core:
Option A) and R4 decided (inbound RZIP transcode) by owner the same
day. Awaiting ONE thing: full spec approval. Do not implement until it
lands.
**Branch:** `claude/sprint-3-2a-android-sync-zcvvr5` → PR to `main` (owner
merges). No remote CI — `scripts/gate.sh full` is the verification.
**Architecture gate:** `docs/design/android-client-architecture.md`
(approved 2026-07-09 — all five §8 decisions locked; this spec implements
its 3.2a slice and does not relitigate them).
**Model:** Opus; escalate the byte-level canonicalization / `.conflict`
writer parity to Fable only if it gets hairy (architecture Decision 5).
**Reference Specs:** `docs/design/save-format-canonicalization.md`,
`docs/design/nextui-format-matrix.md` (§2 ext-strip, §5 ROM-anchoring),
`docs/design/conflict-resolution-experience.md` (§3 schema v2 only — the
§4/§5 UI is 3.2b), `docs/design/security-model.md`, `docs/design/pal.md`
(concept map), Sprint 2.1/2.3 specs (parity target + interop contract).

## Goal

A native Kotlin Continuity client for Android (validation device: the
owner's **Ayn Thor**) reaching **sync parity with RetroDeck 2.1**:
enrollment + device registration, all sync phases (cold start, boot pull,
runtime detection, stale recovery), conflict PRESERVATION (v2 `.conflict`
+ `.local`), canonicalization (retroarch name style, ROM-anchoring,
container sniff + inbound RZIP transcode — quarantine demoted to the
corrupt-file failure path), and save-state one-way archive — with
**byte-identical on-repo artifacts**, proven by a mandatory cross-language
conformance suite and a headless cross-device interop test. Git via JGit;
PAT in Android Keystore. NOT this sprint: the conflict UI (3.2b) and
polish (3.2c).

## The two locked Android decisions, made concrete

**Storage (architecture §4a, Decision 1 — `MANAGE_EXTERNAL_STORAGE`):**
the app requests All Files Access (`MANAGE_EXTERNAL_STORAGE`, granted via
the Settings intent flow) and uses direct `java.io.File` access. Sideload
distribution only — no Play compliance work.
**Hard constraint this spec adds:** All Files Access does **NOT** reach
another app's `Android/data/<pkg>` or `Android/obb` on Android 11+. If
RetroArch keeps saves at its app-private default
(`Android/data/com.retroarch*/files/saves`), Continuity **cannot read
them** — the user must point RetroArch's `savefile_directory` (and
states/ROM dirs) at shared storage once (e.g.
`/storage/emulated/0/RetroArch/saves`). This follows the established
instruct-don't-reconfigure pattern (the shell platforms' RZIP "set save
format to uncompressed" precedent): enrollment preflight detects it and
names the fix on-screen; we never rewrite RetroArch's config ourselves. The recon
(R2) determines whether the owner's Thor already has reachable paths.
All Files Access spans **every shared-storage volume, including
removable SD cards** (`/storage/<VOLUME-ID>/…`) — only
`Android/data`/`Android/obb` are excluded, on every volume — so
SD-resident ROMs and saves are fully in scope.

**ROM roots are multi-volume (owner-confirmed 2026-07-10: the Thor's
ROMs live on its SD card).** The app treats ROM roots as an ORDERED
LIST of absolute directories (internal and/or SD volumes), chosen at
enrollment and validated by preflight; each root is laid out
`<root>/<system_dir>/`. ROM-anchoring searches the roots in order,
first match wins — per-root lookup semantics identical to the shell
reference's single `CONTINUITY_ROMS_ROOT` (the conformance corpus pins
single-root behavior, which the shell can express; the ordered-union
across roots is Android-only surface and is unit-tested Kotlin-side).
The v2 map's `rom_roots` field stays informational, like retrodeck's —
the authoritative roots are the enrolled absolute paths (the rdhome
relocatability precedent). An absent root (card ejected, reformatted →
new volume ID) is a NAMED preflight/status finding and degrades safely
at sync time: device→repo sync continues unaffected; repo→device
materialization sparse-skips (no visible ROM → nothing materialized —
never a wrong write).

**Background (architecture §4b, Decision 2 — lifecycle + WorkManager):**
no persistent daemon. The shell daemon's lifecycle maps onto Android as:

| Shell daemon moment | Android trigger | Phase run |
|---|---|---|
| boot dispatch (cold/stale/normal) | app launch/foreground; `BOOT_COMPLETED` receiver → expedited one-shot Work | same dispatch: no sentinel → cold start; sentinel + no `clean_shutdown` → stale recovery; else boot pull |
| 30 s poll loop | WorkManager periodic sync (15-min floor, network-constrained) + a foreground-service poll loop while "Sync while playing" is enabled (optional toggle, 30 s ticks) | runtime poll cycle |
| SIGTERM final sweep | app `onStop`/background transition | final runtime scan + push; write `clean_shutdown` only when nothing unpushed |
| WiFi-recovery push | WorkManager network constraint (deferred work runs when connectivity returns) + a pending-push check at every cycle start | `se_push` retry semantics |
| in-session reconcile (cooldown) | any cycle whose push is rejected non-fast-forward | stale-recovery reconcile inline, throttled (same cooldown default: 10 cycles) |

Every cycle is single-flight (a mutex serializes phases; WorkManager +
lifecycle + service triggers never run concurrently). `clean_shutdown` is
cleared at cycle start and written at clean cycle end, so any
process-death mid-cycle self-heals as a stale boot — strictly the shell
semantics, adapted to a runtime where "unclean shutdown" is routine.

## Module layout (no new top-level folders)

The Android client is a self-contained Gradle project rooted at
`src/platforms/android/` (CLAUDE.md already lists the folder; Gradle
build outputs are gitignored — rule 5, no generated files in `src/`):

```
src/platforms/android/
  settings.gradle.kts, build.gradle.kts, gradle.properties
  gradlew, gradlew.bat, gradle/wrapper/            (pinned wrapper; the
                                                    jar is vendored tooling,
                                                    like the PAK binaries)
  .gitignore                                       (build/, .gradle/, local.properties)
  core/       — PURE-JVM Kotlin module, zero Android dependencies:
                canonicalization, platform-map parsing, sync phases,
                conflict writer, enrollment, JGit engine, state archive,
                .continuity state files, and a small headless CLI driver.
                THIS is what the gate tests (JUnit on the plain JVM).
  app/        — Android application module: manifest + permissions,
                storage-access flow, enrollment activity, WorkManager
                workers, boot receiver, lifecycle hooks, optional
                foreground service, Keystore PAT store, logging.
                Needs the Android SDK to build; NOT built by the gate
                (see §Gate integration).
```

Package id `dev.continuity` (`dev.continuity.core` / `dev.continuity.app`)
— sideload-only, so the namespace is a convention, not a store claim;
owner may rename at approval. The `core`/`app` split is the load-bearing
decision: everything with a byte-level contract lives in `core`, testable
on any JVM, so the conformance suite runs in this container and in the
gate without an Android SDK or device.

## The shared contracts — byte inventory the Kotlin must reproduce

The on-repo artifacts are the interop surface (architecture §2). Pinned
to the shell reference, these are the exact bytes `core` must produce:

1. **Canonical save paths** — `<canonical_system>/<basename>.srm` (and
   `.rtc` sibling), per `src/core/path_mapper.sh`:
   `pm_device_to_canonical` (container sniff first: 8-byte magic
   `23525a4950760123`), ROM-anchored identity
   (`pm_rom_match_basename`: save stem == ROM full filename OR ROM
   ext-stripped name), heuristic fallback = strip one trailing 2–4 char
   alphanumeric extension (`pm_rom_ext_strip`, matrix §2),
   `.sav`→`.srm` class mapping, `.rtc` kept.
   **Android layout note (R3 resolution, decided 2026-07-10):** the
   Thor sorts saves BY CORE, so the device dir component is OPAQUE and
   ROM-anchoring is REQUIRED inbound — system is resolved from the
   enrolled ROM roots, never from the save dir (full design:
   §R3 resolution).
   **Container handling — DECLARED deviation from the shell platforms
   (owner-directed 2026-07-10):** a healthy RZIP device file
   **transcodes inbound** — decoded to raw payload by a Kotlin RZIP
   decoder (`java.util.zip.Inflater`; validated byte-exact against the
   vendored libretro reference oracle `tools/rzip/reference/` and its
   reference-encoder-generated fixtures) — instead of quarantining.
   This is the canonicalization doc's Decision-4 Phase-3 inbound lift,
   executed Kotlin-first (target Android users may have
   `save_file_compression` on, and "re-save every game" is not an
   acceptable onboarding step); it supersedes the architecture doc's
   §2 "RZIP quarantine" wording for Android, approved via this spec.
   Consequences, all pinned: EVERY repo-side byte (canonical file,
   `.local` preservation) is raw payload; ALL device-vs-repo byte
   comparisons (cold-start dedupe/conflict check, poll confirm, stale
   catch-up) compare decompressed PAYLOADS, so RetroArch recompressing
   an identical payload never registers as a change; materialization
   ALWAYS writes raw — safe on any setting because `rzipstream` sniffs
   and reads both containers (canonicalization doc, pinned to upstream
   source), and the device rewrites its preferred container on next
   flush. Quarantine semantics survive ONLY as the failure path: a
   corrupt/truncated RZIP, or one whose header claims an absurd
   decompressed size (bomb guard, hard cap ~64 MB), is skipped with a
   named log line and never stored — the never-store-garbage guarantee
   is unchanged. States are untouched by all of this (opaque archive,
   compressed bytes verbatim, format-matrix §7).
   `pm_canonical_to_device` for retroarch style = `<basename>.srm`
   under the mapped system dir, ROM-gated (no ROM → sparse skip, rc-2
   semantics). The Kotlin mapper implements all three styles
   (minui/retroarch/generic) so conformance can pin the full table, but
   Android runs `retroarch`.
2. **`.conflict` v2 JSON** — byte-exact per the two shell writers:
   `conflict_handler.sh:80` (source `pull`: remote device/timestamp from
   `git log -1 --format=%cI%n%B origin/main -- <path>`, `device:` trailer
   parsed, `unknown` fallback) and `cold_start.sh:160` (source
   `cold_start`: `remote_device` `"unknown"`, `remote_timestamp` `""`).
   Exact key order, 2-space indent, `\n` line endings, trailing newline,
   double-quote-only escaping (`sed 's/"/\\"/g'` equivalent — no other
   JSON escaping), `identity` = path minus `.srm|.sav|.rtc`, `class` =
   `rtc` for `.rtc` else `srm`. Timestamps: local =
   `yyyy-MM-dd'T'HH:mm:ss'Z'` UTC; remote = git `%cI` strict ISO (offset
   form, e.g. `+00:00`).
3. **`.local` files** — `<canonical_path>.<device_name>.local`, bytes =
   verbatim copy of the losing side.
4. **Commit messages** — the digest/conflict tooling parses these:
   - sync commits (`se_commit`): subject `"<file> updated"` (1 file) or
     `"<N> saves updated"`, then `\n\ndevice: <name>\ntimestamp: <ISO-Z>`;
   - conflict commit: `"conflict: <N> save(s) preserved from <device>"`
     (no trailers — matches `ch_handle_pull_conflict`);
   - enrollment: `"enroll: register <device>"` + trailers;
   - stale catch-up: `"stale boot catch-up from <device>"` + trailers.
   Committer identity `Continuity <continuity@device>`, no signing.
5. **`.continuity/` layout** — `devices/<name>.json` (exact
   `enroll_write_device_json` bytes: `_schema_version "1.0"`,
   `device_name`, `platform`, `enrolled_at`, `last_sync: null`,
   `last_push: null`), the committed `.gitignore` seeded with exactly
   `enrollment.sh:209`'s six lines when Android enrolls first, and the
   local-only state files (`device_name`, `sentinel`,
   `last_known_commit`, `clean_shutdown`, `last_status`) kept
   shape-compatible for debuggability. **Deviation from shell:** no
   `credentials` file and no `git_credential_helper.sh` — the PAT lives
   in Keystore-backed `EncryptedSharedPreferences` (§Security). Device
   JSON `platform` value: `"retroarch_android"` (matches the platform
   map name).
6. **Sync phase semantics** — faithful ports of `cold_start.sh` /
   `boot_pull.sh` / `runtime_poll.sh` / `stale_boot.sh` /
   `conflict_handler.sh (ch_handle_pull_conflict)` /
   `change_detector.sh`, including: repo-wins-on-cold-start with
   preservation; one-sided adds are NOT conflicts (both-sides-exist
   classification via cat-file semantics); `reset --hard origin/main`
   acceptance; save-class-only filters (`.srm/.sav/.rtc`; states never
   applied device-ward); candidates-newer-than-sentinel then
   byte-compare confirmation; sentinel/commit bookkeeping order;
   offline-deferred sentinel on cold start; trying-marker read guard in
   the poll (skip + red notify on trying-modified — markers are written
   by the 3.2b UI, but the 3.2a engine must already honor them); state
   archive one-way with the 8 MB default cap (`CONTINUITY_STATE_MAX_KB`
   equivalent); the five state name shapes. Where the shell had a known
   call-site defect (2.1 Open Item 1, since fixed on main: rc-3
   quarantine logging), parity is to CURRENT main behavior.
   **Android-only additions (R3 resolution):** the per-game binding
   lifecycle threads through the phases — cold start auto-binds
   single-location games and surfaces duplicate/ambiguity findings;
   poll and stale catch-up resolve device paths through bindings;
   materialization (cold start, boot pull) writes through bindings and
   DEFERS unbound repo saves; the first sync after a late bind runs
   the per-file cold-start semantic (repo wins on device, fresh local
   bytes preserved as `.local`).
7. **JGit engine rc mapping** — `se_pull` 0/1/2 and `se_push` 0/1/2
   semantics: ff-only pull (fetch + ancestor check; diverged → 1),
   network-classed failures → 2 (JGit `TransportException` et al.
   replace the shell's stderr-string matching), push retry ×5 with
   2/4/8/16 s backoff on network class only, offline short-circuit → 2.
   HTTPS with `UsernamePasswordCredentialsProvider("x-token", pat)` —
   same username convention as the shell credential helper. Repo clone
   lives in app-private internal storage (`filesDir/repo`) — it is
   device-local state, not user-visible data.
8. **Backup archive (Android-INTRODUCED repo surface, owner-directed
   2026-07-10 — not a shell-reproduced artifact):** a save-class file
   the mapper cannot canonicalize — its system is outside the
   taxonomy/platform map (the Thor's Saturn save), or its dir is
   unmapped — is archived one-way to
   `backup/<device_name>/<device-rel-save-dir>/<filename>.bak` on
   main: VERBATIM device bytes (no transcode — these formats are
   exactly the unverified ones), state-cap sized, committed with the
   normal trailers, never materialized anywhere, never conflicting
   (same-path overwrite is fine; it is a backup, and git history
   keeps every version). The **`.bak` suffix is load-bearing**: the
   current shell fleet's save-class filters are extension-anchored,
   and `boot_pull` HARD-FAILS on save-class repo paths it cannot map
   (`src/core/boot_pull.sh:82-85` — filed as issue #16); `.bak`
   makes the archive invisible to deployed clients. Promotion of a
   backed-up system to canonical sync is issue #15 (taxonomy entry +
   byte-portability verification per system); this archive is the
   don't-lose-data floor under that queue.

## Conformance suite (architecture Decision 3 — mandatory)

The drift-killer. One corpus, two executors, committed expected bytes:

- **`tests/fixtures/conformance/`** — `cases/` (inputs: a TSV manifest —
  tab-separated because real ROM names contain spaces and apostrophes —
  plus payload fixtures, reusing `tests/fixtures/rzip/save_rzip.bin` /
  `save_raw.bin` for container rows), `expected/` (committed
  reference outputs), `generate_expected.sh`, `README.md`.
- **Corpus dimensions:** name mapping (device→canonical and
  canonical→device, all three styles × spaced/apostrophe/parenthesized/
  pre-suffixed names × ROM-present/absent/ambiguous → path or rc 1/2/3),
  container classification (raw, RZIP, short file, `#!s9xsnp` state
  bytes → raw), `.conflict` JSON (both sources, quote-in-name escaping
  case, unknown-remote fallback), `.local` naming, device JSON,
  `.gitignore` seed bytes, commit messages (all four shapes).
- **Container-transcode rows (second oracle):** RZIP decode cases
  (single-chunk, multichunk, truncated → named skip, oversized-header →
  named skip) assert the Kotlin decoder's output byte-exact. The shell
  reference cannot generate these expected bytes (shell platforms
  quarantine — a declared behavior difference, see byte-inventory 1);
  their oracle is the vendored libretro reference at
  `tools/rzip/reference/` — the committed fixtures are already
  reference-encoder-generated, and `scripts/build_rzip.sh`'s host
  binary regenerates/extends them. Everything else keeps the shell
  reference as its oracle.
- **Determinism:** the generator runs the REAL shell writers in a
  sandbox with `date` shadowed by a shell function (functions shadow
  binaries in command substitution) and `GIT_COMMITTER_DATE` pinned, so
  timestamps are inputs, not runtime noise. The Kotlin side injects the
  same instants via `java.time.Clock`. Expected bytes are therefore
  exactly reproducible from both sides.
- **Shell-side test** `tests/unit/core/test_conformance_corpus.sh`
  (busybox ash, both privilege passes, `$TMPDIR`-only): regenerates from
  the shell reference and byte-diffs against `expected/` — alarms on
  shell drift or stale fixtures.
- **Kotlin-side test** (JUnit in `core`): runs every case through the
  Kotlin implementation and byte-compares against the same `expected/`
  files (corpus dir passed via a Gradle system property).
- Adding a case = adding an input row + regenerating; a case that
  passes on one side and fails on the other is, definitionally, the
  drift the architecture doc feared — fix the Kotlin (the shell is the
  reference), never the fixture.

## Headless cross-device interop (the 2.3 contract, third device)

`core` ships a small CLI (`continuity-core-cli`) exposing
enroll/cold/poll/boot/stale/pull-conflict against explicit `--repo`,
`--saves-root`, `--roms-root`, `--map`, `--device-name` args (PAT unused
over `file://`). It exists for exactly one purpose: letting the existing
shell integration harness drive the Kotlin engine as a real device.
`tests/integration/test_android_cross_device.sh` re-runs the
`test_cross_device_flow.sh` pattern with the Brick subshell (real
`pal_nextui.sh`) ⇆ the Kotlin CLI as the second device over one shared
`file://` remote: minui⇒canonical⇒retroarch materialization and reverse,
`.rtc` travel, sparse both ways, no native-name leaks, and a
cross-format divergence collapsing to ONE grouped v2 `.conflict` + ONE
`.local` regardless of which side runs the conflict handler. The test
SKIPS with a named line when no JVM/built jar is present (see gate
tiers) and runs for real in the gate's current-user pass.

## Gate integration (JVM tests alongside the shell-only gate)

The gate stays the verification; it grows one Android-aware step, in the
same conditional style as the existing qemu checks:

1. **`scripts/test_android.sh`** — the one entry point: `cd
   src/platforms/android && ./gradlew --console=plain :core:test
   :core:cliJar`, then runs `tests/integration/test_android_cross_device.sh`
   against the built jar. First run resolves pinned dependencies over
   the network (cached in `~/.gradle` thereafter); subsequent runs are
   offline-capable.
2. **`scripts/gate.sh` full tier** adds, after the unprivileged suite:
   `gate(full): android conformance (JVM)...` → runs
   `scripts/test_android.sh` when `java` is available; otherwise prints
   a LOUD named skip (`skipped — NO JVM; required before any
   android-touching push/PR`). Rationale: identical posture to the
   qemu-aarch64 steps — conditional on toolchain, mandatory at the
   moments that matter, and this dev container has Java 21 + Gradle, so
   PR-gating full runs always exercise it here.
3. **`.githooks/pre-push`** escalates fast→full when the outgoing range
   touches `src/platforms/android/**` or
   `tests/fixtures/conformance/**` (same mechanism as the existing
   `build/Continuity.pak` escalation) — an Android-touching push cannot
   ride the 15 s tier past the JVM suite.
4. **The `nobody` pass stays shell-only.** Gradle cannot run against a
   read-only repo tree with a scratch `$HOME` (it writes module `build/`
   dirs and a dependency cache), and the unprivileged pass exists to
   catch tests that write into the repo tree — a JVM-side concern the
   Kotlin tests avoid structurally (JUnit temp dirs). The shell half of
   the conformance suite (`test_conformance_corpus.sh`) DOES run in both
   privilege passes via normal `scripts/test.sh` discovery. This split
   is deliberate and documented in CLAUDE.md by this sprint (see file
   table) — per the CLAUDE.md rule, the current-user pass is what
   exercises the JVM step every full gate, so it is never a
   silently-dead branch.
5. **The `app` module is NOT gate-built** (needs the Android SDK).
   APK assembly is a developer/release action:
   `scripts/build_android_apk.sh` documents/automates SDK bootstrap +
   `:app:assembleRelease` and stamps the version; its output is the
   sideload artifact for the Thor. Gate-independence keeps the
   verification hermetic; the byte-contract code all lives in `core`,
   which IS gated.

## Recon gate — CLOSED 2026-07-10 (both runs received; R1–R6 settled in §Recon findings)

`src/platforms/android/thor_recon.sh` is on the branch (read-only; adb
from a PC, or `CONTINUITY_RECON_LOCAL=1` in Termux on the device; a
manual RetroArch-UI checklist covers anything scoped storage hides from
adb). Step-by-step USB-debugging enablement for the Thor is in the
script's header comment. SD volumes are probed automatically;
`CONTINUITY_ROM_ROOTS=/abs/path1:/abs/path2` force-probes unusual
locations:

```sh
sh src/platforms/android/thor_recon.sh
# → CONTINUITY_THOR_RECON.txt — send it back
```

Items the report must confirm:

- **R1** — Device + RetroArch inventory: Android version, RetroArch
  package(s) and version, which build is actually played (M5).
- **R2 (the storage crux)** — `savefile_directory` / `savestate_directory`
  are concrete paths on SHARED storage (reachable by All Files Access).
  If they sit in `Android/data` (including the `:`-relative default):
  owner relocates them in RetroArch's Directory settings once —
  contingency C1 — and re-runs recon.
- **R3 (the map shape)** — the save-sorting mode: by-content-dir
  (`saves/<system>/Game.srm`), by-core, or FLAT. This decides the v2
  map's `system_paths` values (validated against the REAL directory
  names, replacing the current v1 guesses) and triggers C3 if flat.
- **R4** — real save filenames match retroarch style (`Name.srm`, ROM
  ext stripped), plus the container census (raw vs RZIP). Compressed
  saves are fully supported via the inbound transcode (byte-inventory
  1) — the census only tells us which path the hardware validation
  exercises; no user action either way. (The original quarantine +
  "turn compression off" posture was superseded 2026-07-10 by owner
  direction: target users arrive with arbitrary compression settings,
  and per-game re-saving is not an acceptable ask.)
- **R5** — ROM root(s) + flat `roms/<system>/` layout; the real system
  dir names for `system_paths` and `rom_roots`.
- **R6** — which volumes hold saves and ROMs: internal
  (`/storage/emulated/0`) vs SD (`/storage/<VOLUME-ID>`), the SD
  volume ID, and the exact ROM root path(s) per volume. ROMs are
  expected on the SD card (owner-stated); the report's SD-volume
  section pins the ordered ROM-roots list enrollment will validate and
  confirms the SD roots follow the flat `<root>/<system>/` layout (R5
  applies per root).

Implementation may start on owner approval of this spec; anything the
report contradicts amends the spec first (small deltas noted in the
summary, structural ones re-approved) — same protocol as 2.1.

## Recon findings (Thor, 2026-07-10) — deltas for approval

First owner-run report received (adb mode). Caveat: the report's
directory censuses were truncated by a recon-script defect (adb
consumed loop stdin; fixed on-branch) — a re-run completes the map
data. The findings below are already conclusive:

- **R1 ✓** AYN Thor (`kalama`), Android 13 / SDK 33, arm64-v8a;
  RetroArch buildbot `com.retroarch.aarch64` 1.22.2_GIT (settles M5).
- **R2 ✓** `savefile_directory` / `savestate_directory` =
  `/storage/emulated/0/RetroArch/{saves,states}` — shared storage,
  reachable; no relocation needed. `retroarch.cfg` itself is
  app-private (adb's shell uid could read it on this build; the app
  cannot) — confirming the spec's model of enrollment-time path
  configuration + preflight validation, not live-cfg parsing.
- **R4 — compression ON, RESOLVED as supported (owner-directed
  2026-07-10):** `save_file_compression = true`; the sniffed save is
  RZIP. The initial posture (quarantine + instruct the owner to turn
  compression off) was rejected as unreasonable for target users —
  they arrive with arbitrary settings, and per-game re-saving is not
  an onboarding step. Resolution: **inbound RZIP transcode** in the
  Kotlin engine (byte-inventory 1) — no user action, no setting flip,
  no on-device file rewriting (an enrollment-time bulk decompress was
  considered and rejected: it edits user save files in place, races a
  running RetroArch, and silently breaks again if the user re-enables
  compression). The owner keeps compression ON — the Thor thereby
  exercises the transcode path with real data during hardware
  validation. `savestate_file_compression = true` needs no action —
  states archive verbatim (format-matrix §7).
- **R3 — STRUCTURAL FINDING, DECIDED: Option A (below):** save
  sorting is **by CORE NAME** (`sort_savefiles_enable = true`,
  by-content `false`): the device layout is
  `saves/<Core Name>/<Game>.srm` (`Snes9x/`, `mGBA/`, `bsnes-hd
  beta/`, `Beetle PCE/`, …) — the directory component carries NO
  system information — and the SAME game legitimately exists under
  several core dirs (ALttP (MSU1) appears under Snes9x, bsnes,
  bsnes-hd beta AND Mesen-S), making device→canonical a many-to-one
  collapse. Neither the flat nor by-content shapes the original C3
  contemplated.
- **R5/R6 ✓ (census complete, second run 2026-07-10):** the ROM root
  is **`/storage/388C-68F7/Roms`** — the SD volume (`Roms`/`ROMs`/
  `roms` alias to one case-insensitive directory; the internal
  `/storage/emulated/0/ROMs` exists but is EMPTY; `ES-DE` dirs on
  both volumes are frontend config, not ROMs). Flat
  `<root>/<System>/` layout confirmed (the only nested files are
  inert PowerShell scripts under `N3DS/7Z/` — not a synced system).
  24 system dirs on-device; the 14 canonical-taxonomy systems map to
  (v2 `system_paths`, ROM-anchoring vocabulary — these values are
  approved WITH this spec and land in
  `config/platform_maps/retroarch_android.json` + the path-mapper
  test rows at implementation):
  `gb→GB, gbc→GBC, gba→GBA, nes→NES, snes→SNES, genesis→Genesis,
  sms→MasterSystem, gg→GameGear, pce→PCEngine, ps1→PSX, n64→N64,
  nds→NDS, psp→PSP, arcade→NeoGeo`.
  **Provenance (owner-raised 2026-07-10):** these pairings were
  derived by semantic NAME-MATCHING against the taxonomy vocabulary —
  informed judgment, not device metadata — and the device dir names
  themselves are one user's convention (carried from an earlier
  handheld), NOT fixed per device. Owner-reviewed as good enough to
  start; they are **Thor-validated defaults**, seeded per-device and
  shown at enrollment (read-only review + unmapped-dirs list in
  3.2a); the editable mapping surface + taxonomy alias seeding is
  **issue #14**. `arcade→NeoGeo` exemplifies the judgment class: a
  `MAME` dir also exists (1 file) but the device's FBNeo-class saves
  are NeoGeo titles; MAME stays unmapped in 3.2a
  (single-dir-per-system mapper contract; multi-dir is #14 territory).
  **Out-of-taxonomy inventory — dispositioned (owner 2026-07-10):
  BACK UP NOW, promote later (#15).** Present on-device: Dreamcast,
  Saturn (a real YabaSanshiro `.srm` exists), SegaCD, PCEngineCD, GC,
  PS2, N3DS, PSVita, 3do, adam. Their saves join the one-way
  **backup archive** (byte-inventory 8) so nothing is lost while each
  system awaits taxonomy expansion + per-system byte-portability
  verification (issue #15 tracks promotion; SRAM portability is
  verified only for the founding systems, and PS2/GC are
  memory-card-shaped — maybe not SRAM at all). Standalone-emu content
  (`PSP/` PPSSPP dir, `Azahar` 3DS) stays M7 inventory — different
  track.
- **Container census (completes R4's evidence):** 12 of 15 saves are
  RZIP, **3 are raw — and they are exactly the bsnes-family copies**
  (bsnes ×2, bsnes-hd beta ×1), which write raw even with
  `save_file_compression = true`. One device, one setting, MIXED
  containers: per-FILE sniffing (never a per-device container
  assumption) is validated as a requirement, and the transcode is the
  mainline path, not an edge case. The duplicate set is
  container-mixed too (ALttP: Snes9x/Mesen-S RZIP vs bsnes-family
  raw), so duplicate comparison MUST be payload-level.
- **Binding scale confirmed small:** 16 core dirs, 9 holding saves,
  ~22 save files total — the picker moment is minutes, not an
  onboarding wall.
- **New cross-platform finding — multi-digit state slots (issue
  #17):** `Shining Force (USA).state10` exists on-device, and the
  owner reports auto-increment runs producing HUNDREDS of states with
  slot numbers rolling past 900 into `.state1000+` (an SNES FF3 run).
  The shared pattern set (`pm_state_grep_re` / `pm_find_states`,
  matrix §6) matches only single-digit `.state[0-9]` and silently
  skips every multi-digit slot on EVERY platform (states are one-way
  archive, so the miss is invisible). Two halves, both in #17: the
  one-line core pattern fix (out of 3.2a's lane), and a RETENTION
  policy — hundreds of states per game with no count/total cap
  balloons the repo. **3.2a position:** the Android state scanner
  ships multi-digit patterns from day one (a DECLARED superset of the
  shell set until core aligns — safe: the archive is one-way opaque
  and a superset only archives more); retention is out of scope
  pending the #17 policy decision (per-file 8 MB cap only).

### R3 resolution — native by-core support (Option A, DECIDED 2026-07-10)

Owner decision: **adapt to the device — support by-core natively.**
The rejected alternative (Option B: reconfigure RetroArch to
sort-by-content and hand-consolidate the existing saves into
system-named dirs) meant one-time manual file surgery on a working
device and changed RetroArch's save behavior for everything played
thereafter. Normative design, reflected in byte-inventory 1/6,
file-table 3/4, and AC2/AC6:

- **The device save-tree dir component is OPAQUE.** RetroArch sorting
  may produce a core name (the Thor), a content-dir name
  (RetroDeck-style), or nothing (flat) — the mapper never interprets
  it. Inbound identity is **ROM-anchored, REQUIRED** (not fallback): a
  save's system is the system dir of the matching ROM under the
  enrolled ROM roots; `system_paths` maps canonical names to ROM-tree
  dir names (values from the census re-run). One mechanism thus covers
  by-core, by-content, flat, and mixed-history trees — unit rows cover
  each shape, and the former flat-layout contingency (old C3)
  dissolves into supported behavior.
- **Ambiguity is never guessed:** a save basename matching ROMs in
  MORE than one system is a NAMED finding, resolved through the same
  picker surface as duplicates (below); that save is not synced until
  resolved. Wrong-merge corrupts a 40-hour file; waiting costs nothing
  (Decision-2 ethos).
- **Per-game core binding** (device-local state, never committed):
  sync binds each canonical identity to the device location (core dir)
  holding its save. Auto-bound when exactly one location has the game
  — the common case. Multi-location duplicates (ALttP (MSU1) under
  four core dirs) become a NAMED enrollment/status finding the user
  resolves ONCE per game — pick which copy syncs; unchosen files stay
  on device untouched, just unsynced. Never auto-picked. Refinement
  (recon-informed): duplicates whose decompressed PAYLOADS are all
  byte-identical auto-bind silently — equivalence is proven, not
  guessed (binding goes to the most-recently-modified copy); the
  picker is reserved for genuinely divergent bytes. Comparison is
  payload-level by necessity: the Thor's real ALttP set mixes
  containers across copies (RZIP and raw).
- **Materialization writes through the binding.** A repo save with no
  binding DEFERS until the game is first played on the Thor
  (RetroArch creates the device file, the binding auto-records), and
  that first sync runs the per-file COLD-START semantic: repo wins on
  device, the fresh local bytes are preserved as `.local`. This is
  the anti-clobber guard for late-materializing layouts (shell
  platforms materialize before play, so the rule is additive, not
  divergent; on-repo artifacts are unchanged, which is why conformance
  vs the shell reference is unaffected — bindings are Android-local).

R4 required no user action under either option — resolved separately
by the inbound transcode (above).

## In scope (file table)

| # | File | What |
|---|------|------|
| 1 | `src/platforms/android/thor_recon.sh` | On-device recon (already on branch — recon tooling, not product code). |
| 2 | `src/platforms/android/{settings,build}.gradle.kts`, `gradle.properties`, `gradlew*`, `gradle/wrapper/*`, `.gitignore` | Gradle skeleton, pinned wrapper + dependency versions (Kotlin, JGit, JUnit, WorkManager, security-crypto). |
| 3 | `src/platforms/android/core/` (module) | `PlatformMap` (v2 JSON), `PathMapper` (styles, ext-strip, ROM-anchor required on opaque-dir layouts, sparse), `CoreBindings` (per-game binding store, device-local JSON: auto-bind, duplicate + cross-system ambiguity findings, late-bind cold-start rule), `ContainerSniff` (RZIP magic) + `RzipCodec` (inbound decode via `Inflater`, reference-oracle-validated, bomb cap, named-skip failure path; payload-compare helpers), `ConflictWriter` (v2 + `.local`), `SyncEngine` (JGit: clone/ff-pull/push-retry/stage/commit trailers/rc mapping), `Phases` (cold/boot/poll/stale + pull-conflict handler + reconcile cooldown), `Enrollment` (validation rules ported exactly: `[a-z0-9-]`, ≤32, no edge hyphens; device JSON; `.gitignore` seed), `ArchiveSync` (states: the shell shapes EXTENDED to multi-digit slots — declared superset, #17 — plus the one-way `backup/` archive for unmappable-system saves, byte-inv. 8; size caps), `ContinuityState` (sentinel/commit/clean-shutdown/last_status files), `Cli` (headless driver), JUnit tests incl. the conformance executor. |
| 4 | `src/platforms/android/app/` (module) | Manifest (`MANAGE_EXTERNAL_STORAGE`, `INTERNET`, `RECEIVE_BOOT_COMPLETED`, `FOREGROUND_SERVICE`), All-Files-Access grant flow, enrollment Activity (repo URL + device name + PAT paste + ordered ROM-roots selection across volumes; setup.json import from the storage root as a convenience, same schema + delete-on-success rules as the Brick), duplicate/ambiguity resolution picker (one-time per game, drives `CoreBindings` — R3 resolution), system-mapping review at enrollment (read-only: detected dirs → canonical + the unmapped list feeding the backup archive; editable surface is #14), Keystore-backed PAT store, sync coordinator (single-flight mutex + lifecycle hooks), WorkManager periodic + expedited boot work, boot receiver, optional "Sync while playing" foreground service (minimal notification; polish is 3.2c), preflight/diagnostic report (named errors on-screen + `CONTINUITY_DIAGNOSTIC.txt` at the storage root — observability rule), file+logcat logging. |
| 5 | `config/platform_maps/retroarch_android.json` | → schema 2.0: `save_name_style: retroarch`, `save_container: raw` (what we WRITE; inbound is per-file sniff + transcode), `rom_roots: ["Roms"]`, `system_paths` = the recon-validated ROM-dir vocabulary pinned in §Recon findings R5/R6 (approved with this spec), `_notes` for the opaque-save-dirs model + mixed-container census. |
| 6 | `tests/fixtures/conformance/` | Corpus: `cases/` + `expected/` + `generate_expected.sh` + `README.md`. |
| 7 | `tests/unit/core/test_conformance_corpus.sh` | Shell side of the conformance suite (both privilege passes). |
| 8 | `tests/integration/test_android_cross_device.sh` | Brick(shell) ⇆ Kotlin-CLI over one `file://` remote; named JVM-absent skip. |
| 9 | `scripts/test_android.sh` | JVM suite entry point (gradle test + cliJar + interop test). |
| 10 | `scripts/gate.sh` | Add the conditional `android conformance (JVM)` full-tier step. |
| 11 | `.githooks/pre-push` | Escalate to full on android/conformance-touching ranges. |
| 12 | `scripts/build_android_apk.sh` | SDK bootstrap + release APK assembly + version stamp (developer/release path, not gate). |
| 13 | `docs/platform/android-validation.md` | Owner hardware protocol: Thor enrollment, on-Thor round-trip, and the 2.3 protocol extended to three devices (Brick⇆Thor⇆Deck: canonical names, sha256 byte-match, sparse both ways, one grouped conflict). |
| 14 | `docs/design/security-model.md` | Android addendum: PAT byte inventory (Keystore-backed EncryptedSharedPreferences; NO plaintext credentials file; masking rules in app logs). **Fable-class review flag** per CLAUDE.md — called out to the owner in the PR. |
| 15 | `CLAUDE.md` | Testing-requirements note: JVM suite location, `scripts/test_android.sh`, the two-pass split rationale; Android build/deliver pointer. |
| 16 | `docs/roadmap.md` | 3.2a status updates. |
| 17 | `docs/sprints/sprint-3.2a-summary.md` | Handoff artifact (at completion). |
| 18 | `docs/platform/thor-field-notes.md` | Created during on-device validation (hardware-validated traps; NextUI field-notes analog). |
| 19 | `tests/unit/core/test_path_mapper.sh` | Android rows updated to the recon-validated v2 values (they currently assert the v1 guesses). Mapper-mechanics coverage only — the Android RUNTIME treats save dirs as opaque (R3 resolution); these values serve ROM-anchoring. |

**No changes to `src/core/**`, `src/platforms/nextui/**`,
`src/platforms/onion/**`, `src/platforms/retrodeck/**`.** If Kotlin
parity work surfaces a shell-side defect, FLAG it in the summary (2.1
Open-Item precedent), don't fix it in-lane.

## Acceptance criteria

1. **Conformance (the primary gate):** every corpus case produces
   byte-identical output from the Kotlin implementation and the
   committed expected files (oracle per row class: the shell reference
   for name/conflict/commit/JSON rows; the vendored rzip reference for
   container-transcode rows) — canonical paths + rc classes, RZIP
   decode payloads, both `.conflict` shapes, `.local` names/bytes,
   device JSON, `.gitignore` seed, all four commit-message shapes. The
   shell-side test regenerates its rows' `expected/` identically under
   busybox ash in both privilege passes.
2. **Unit (Kotlin):** mapper style table round-trips
   (device→canonical→device per style); RZIP transcode semantics —
   healthy RZIP (incl. multichunk) decodes byte-exact to the reference
   fixtures' payloads, corrupt/truncated/oversized-header inputs skip
   with the named log line and store nothing, and a device-side
   recompression of an identical payload produces NO commit
   (payload-compare); ROM-anchor beats heuristic; sparse skip rc-2;
   phase state-file lifecycle (sentinel/commit/clean-shutdown ordering,
   offline-deferred cold-start sentinel); ordered multi-root
   ROM-anchoring (first match wins; absent root → sparse skip, named
   status); core-binding lifecycle (auto-bind single-location games
   and identical-payload duplicates; divergent duplicates and
   cross-system basename ambiguity → named findings, nothing synced,
   never auto-picked; late-bind first sync = per-file cold start with
   `.local` preserved; by-core, by-content, and flat tree shapes all
   covered); backup-archive routing (unmappable-system save →
   `backup/<device>/…/<file>.bak`, verbatim bytes, one-way, size cap;
   never materialized); multi-digit state slots archived
   (`.state10`, `.state1000`); JGit rc mapping incl. push
   retry/backoff and non-FF rejection; enrollment validation matrix;
   PAT never appears in any log line or exception message (masking
   test).
3. **Interop (incl. fleet safety):** `test_android_cross_device.sh`
   green, and the shell device in the harness boot-pulls a repo
   already containing `backup/**.bak` entries CLEANLY (no phase
   failure, commit stored, no materialization) — proving the `.bak`
   suffix shields the deployed fleet from the new namespace (see
   issue #16 for the underlying defect). Brick-written
   MinUI save lands via repo on the Kotlin device under retroarch
   naming with identical bytes (and reverse), `.rtc` travels, sparse
   honored both directions, no device-native names leak, cross-format
   divergence yields exactly ONE v2 `.conflict` (identity/class
   grouped) + ONE `.local` with bytes preserved on both sides.
4. **Map:** `retroarch_android.json` v2 fields validated against the
   Thor recon report (R3/R4/R5) — no guessed values remain.
5. **Gate:** `scripts/gate.sh full` green in this container — fast
   checks, both shell suite passes, the JVM step, PAK integrity —
   with zero diffs outside this sprint's file table.
6. **On-Thor (owner-run, after merge-ready):** All-Files-Access flow +
   preflight names any unreachable path; enrollment from the app
   (device registered on GitHub) with the ROM roots pointed at the
   Thor's SD card; cold start materializes existing repo saves for
   owned ROMs — ROM-anchored against the SD-resident ROM tree; play →
   save → canonical name appears on GitHub, **with SaveRAM Compression
   left ON** (recon-confirmed reality): the device's RZIP file lands in
   the repo as raw payload, and a materialized raw save loads correctly
   in RetroArch — the transcode path proven on hardware end to end;
   the real multi-core duplicate set (ALttP (MSU1) under four core
   dirs) surfaces in the picker, the chosen copy syncs, and the
   unchosen copies stay untouched on device; the real Saturn save
   (out-of-taxonomy) lands verbatim under `backup/thor/…/…srm.bak` on
   GitHub; boot pull applies a remote change; a WorkManager periodic
   cycle fires with the app backgrounded; results in the field notes
   doc.
7. **Three-device round-trip (owner-run):** the
   `android-validation.md` protocol passes across Brick ⇆ Thor ⇆ Deck —
   canonical on-repo names, sha256 byte-match at each hop, sparse
   skips, and one grouped conflict from a Thor-vs-other divergence.

## Tests required

- Kotlin: JUnit suites in `core` (conformance executor + unit tests
  above). No Android instrumentation tests this sprint — everything
  device-only (WorkManager firing, storage grant, Keystore) is covered
  by the on-Thor protocol instead (hardware-dependent test rule).
- Shell: `test_conformance_corpus.sh` (unit) +
  `test_android_cross_device.sh` (integration; JVM-conditional with a
  named skip). Both self-contained, `$TMPDIR`-only, per-process names,
  busybox-ash clean.
- Existing suites untouched and green.

## Contingencies

- **C1 — saves under `Android/data` (R2 fails):** owner relocates
  RetroArch's save/state dirs to shared storage (one-time, in
  RetroArch's own UI); enrollment preflight permanently guards this
  with a named error. No code change.
- **C2 — RZIP decode failure path (compression itself is SUPPORTED
  via the inbound transcode — see R4 resolution):** a corrupt or
  truncated RZIP, or a header claiming an absurd decompressed size,
  is skipped with a named log line and never stored — the
  never-store-garbage guarantee survives the dequarantine. If decode
  failures turn out to be common on real hardware (not expected —
  the format is RetroArch's own), that is a defect investigation, not
  a data-loss event: the device file is untouched and RetroArch still
  reads it.
- **C3 — RETIRED into the R3 resolution (2026-07-10):** the
  opaque-dir + required-ROM-anchoring design handles by-core (the
  Thor), by-content (RetroDeck-style), flat, and mixed trees with one
  mechanism, so flat-layout support no longer needs a contingency —
  it needs unit rows (AC2 covers each shape). Residual note: a flat
  tree leans harder on the cross-system basename ambiguity finding —
  still surfaced, still never guessed.
- **C4 — Gradle cold-cache in the gate:** first `test_android.sh` run
  needs network for pinned dependencies; if the container is offline at
  that moment the step fails NAMED (not skipped) — rerun when online.
  Versions are pinned so resolution is reproducible.
- **C5 — JGit vs GitHub edge behavior** (auth quirks, shallow
  handling): the engine wraps all transport in one class; any
  incompatibility is contained there and fixed against a live-GitHub
  smoke test (the enrollment AC covers it on real hardware).
- **C6 — SD volume changes** (card swapped or reformatted →
  `/storage/<VOLUME-ID>` changes): preflight/status names the missing
  ROM root; the fix is re-pointing the roots in app settings — no
  re-enrollment, no repo impact. While the card is absent,
  materialization sparse-skips and device→repo sync is unaffected
  (saves live on reachable storage per R2; only ROM lookups pause).

## Out of scope (deferred)

- Conflict-resolution UI and the §4 state machine driving (3.2b) — the
  3.2a engine only WRITES preservation artifacts and READS trying
  markers.
- Status UI, notifications polish, log viewer, WorkManager tuning,
  battery instrumentation (3.2c).
- RZIP ENCODE on Android (outbound recompression / a
  `save_container: rzip` materialization mode) — unnecessary:
  `rzipstream` reads raw regardless of the compression setting, so
  materialization always writes raw. Decode-only ships (byte-inv. 1).
- Dequarantining the SHELL platforms (the Phase-3 shell integration of
  `tools/rzip`) — their fleet reality is raw; stays scheduled Phase-3
  work, out of this sprint's lane.
- SAF / Play Store compliance; any store distribution.
- Save-state restore/cross-device state sync (project-wide gate).
- Non-RetroArch emulators on Android (recon M7 inventories only).
- Taxonomy expansion / promotion of backed-up systems to canonical
  sync (issue #15) — 3.2a ships only the `backup/` floor.
- The EDITABLE system-mapping surface + taxonomy alias seeding
  (issue #14) — 3.2a ships the read-only review. Owner challenge
  2026-07-10 folded into #14: seed the mapping (and core bindings)
  from FRONTEND config — ES-DE parses passively from its
  shared-storage dir; Daijishō has NO local export (owner-verified;
  its backup is Google-Drive-only, unusable per the no-cloud-OAuth
  tenet), so `daijisho_db_recon.sh` attempts direct SQLite extraction
  (app-external storage → adb backup → root, schema-agnostic dump);
  assessment + fixture asks on the issue; `thor_recon.sh` collects
  the ES-DE evidence (frontend section + checklist M8).
- State-archive retention policy for auto-increment users (issue
  #17) — 3.2a ships multi-digit coverage with the per-file cap only.
- The core `boot_pull` unknown-path fix (issue #16) — the `.bak`
  suffix makes 3.2a safe without it.
- Migrating `migrate_repo.sh` or any repo-side tooling to Kotlin.
- OTA/self-update for the APK (sideload zips this phase; revisit with
  3.2c).

## Coordination

Owns `src/platforms/android/**`, `config/platform_maps/
retroarch_android.json`, `tests/fixtures/conformance/**`, and the new
test/script files above. Shared-file edits are confined to:
`scripts/gate.sh` + `.githooks/pre-push` (additive steps), `CLAUDE.md`
(one section), `docs/roadmap.md`, `docs/design/security-model.md`
(addendum). Disjoint from Onion 3.1 (`src/platforms/onion/**`) and
RetroDeck 2.2 (`src/platforms/retrodeck/**`); if either lands a
gate.sh/pre-push edit first, rebase and keep both.
