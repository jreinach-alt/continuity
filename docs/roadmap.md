# Continuity — Development Roadmap

## Roadmap Philosophy

Small, modular sprints. Each sprint produces a testable, working increment. All core sync logic is platform-agnostic, built on the Platform Abstraction Layer (PAL). Platform clients share core logic and provide only platform-specific entry points and configuration.

**Ordering principle:** Each sprint is testable the moment it's complete. No sprint depends on hardware or infrastructure that doesn't exist yet. Automated tests use the test PAL; on-device validation uses the NextUI PAL.

---

## Phase 0 — Foundation and Core Sync

**Goal:** PAL framework, enrollment, and all sync phases — fully tested, platform-agnostic. Everything a platform daemon needs to function.

### Sprint 0.1 — Repo Scaffolding and System Taxonomy

**Status:** Complete

**Scope:**
- Pivot repo from Ideal OS to Continuity
- Establish directory structure per CLAUDE.md
- Define canonical system taxonomy (`config/system_taxonomy.json`)
- Define platform path mappings (`config/platform_maps/*.json`)
- Write foundational design specs (architecture, security, roadmap)
- Set up test harness (`scripts/test.sh`)

**Acceptance Criteria:**
- Directory structure matches CLAUDE.md spec
- System taxonomy JSON is valid, covers all target systems
- Platform maps exist for NextUI, Onion OS, RetroDeck, Android
- Design docs cover architecture, security model, enrollment flow
- Test harness runs and reports pass/fail

---

### Sprint 0.2 — Platform Abstraction Layer and Path Mapper

**Status:** Complete

**Scope:**
- Define the PAL interface (`src/core/pal.sh`) — required variables, required functions, validator
- Implement NextUI PAL (`src/platforms/nextui/pal_nextui.sh`)
- Implement test PAL (`tests/fixtures/pal_test.sh`)
- Implement path mapper (`src/core/path_mapper.sh`) — uses PAL for platform map selection
- Unit tests proving same path mapper code works with both test PAL and NextUI PAL

**Acceptance Criteria:**
- PAL validator catches missing variables and functions
- NextUI PAL sets all required variables and implements all required functions
- Test PAL provides synthetic environment for CI
- Path mapper correctly translates paths for all 4 platforms
- Path mapper round-trips: `repo_to_local(local_to_repo(path)) == path`
- Paths with spaces (RetroArch Android) handled correctly
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.1 (taxonomy and platform maps)

**Reference Specs:** `docs/design/pal.md`

---

### Sprint 0.3 — Enrollment

**Status:** Complete

**Scope:**
- Implement core enrollment logic (`src/core/enrollment.sh`) — clone repo, register device, store credentials, write device name
- Implement NextUI enrollment trigger (`src/platforms/nextui/enroll_sd_card.sh`) — detect and import `setup.json` from SD card
- Implement test enrollment helper (`tests/fixtures/enroll_test.sh`) — scripted setup for CI (no SD card, no user interaction)
- Implement sync engine (`src/core/sync_engine.sh`) — git clone, add, commit, push, pull (needed by enrollment for initial clone and device registration push)
- Device registration in `.continuity/devices/<name>.json` (committed to repo)
- Device name stored locally for PAL to read

**Acceptance Criteria:**
- Core enrollment: clones repo, writes device JSON, commits and pushes registration
- NextUI enrollment: detects `setup.json` on SD card, imports credentials, deletes setup file
- Test enrollment: scripted setup creates cloned repo with device registered
- Device name persisted and readable by PAL on next boot
- Credential stored at platform-appropriate location
- All tests pass under `busybox ash` (104 new tests)

**Dependencies:** Sprint 0.2 (PAL, path mapper)

---

### Sprint 0.4 — Cold Start Sync

**Status:** Complete

**Scope:**
- Implement cold start sync flow (`src/core/cold_start.sh`) — first run with no prior state (no sentinel, no stored commit)
- `cmp -s` all `.srm` files in both directions (device → repo, repo → device)
- Write only files that actually differ
- Conflicting files (same game, different bytes): repo wins, device version preserved as `.<device_name>.local` and committed
- Create sentinel file and store commit hash after initial sync
- Unit tests for cold start flow
- Integration test: cold start merge between device saves and repo saves

**Acceptance Criteria:**
- Cold start with empty repo + device saves: all device saves copied to repo, committed, pushed
- Cold start with repo saves + empty device: all repo saves copied to device at correct paths
- Cold start with identical saves on both sides: no unnecessary writes, no `.local` file
- Cold start with differing saves: repo wins on device, device version preserved as `.<device_name>.local` in repo and committed
- Sentinel file created after successful cold start
- Commit hash stored for boot pull comparison
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.3 (enrollment — cloned repo must exist)

---

### Sprint 0.5 — Boot Pull

**Status:** Complete

**Scope:**
- Implement boot pull sync (`src/core/boot_pull.sh`) — normal boot with existing sentinel and stored commit
- `git diff --name-only` against stored commit to identify remote changes
- Apply only changed remote saves to device
- Update stored commit hash after pull
- Unit and integration tests for boot pull flow

**Acceptance Criteria:**
- Detects remote changes since last stored commit
- Copies only changed saves to device (unchanged files untouched)
- Updates stored commit hash after successful pull
- No-op when no remote changes exist
- Handles the case where remote has new systems/files not on device (creates dirs)
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.4 (cold start — sentinel and commit tracking established)

---

### Sprint 0.6 — Runtime Poll

**Status:** Complete

**Scope:**
- Implement runtime change detection (`src/core/runtime_poll.sh`) — `find -newer` sentinel + `cmp -s` candidates
- Single poll cycle: detect local `.srm` changes, stage, commit, push confirmed changes
- Update sentinel after each sync cycle
- Unit and integration tests for runtime detection

**Acceptance Criteria:**
- `find -newer` sentinel identifies candidate changed files
- `cmp -s` against repo copy filters out false positives (touched but identical)
- Only truly changed files are committed and pushed
- Sentinel updated after each successful sync cycle
- Poll cycle is idempotent — no commit when nothing changed
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.5 (boot pull — sentinel lifecycle in steady state)

---

### Sprint 0.7 — Stale Boot Recovery

**Status:** Complete

**Scope:**
- Handle stale boot (`src/core/stale_boot.sh`) — sentinel exists but may be outdated (crash, unclean shutdown)
- Combine boot pull (fetch remote changes) with catch-up scan (detect local changes missed during interrupted session)
- Reconcile both directions before resuming normal operation
- Unit and integration tests for stale boot scenarios

**Acceptance Criteria:**
- Detects stale state (sentinel present but no clean shutdown marker)
- Pulls remote changes AND scans for local changes
- Correctly reconciles both directions without data loss
- Transitions to normal steady-state after recovery
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.6 (runtime poll — full sentinel lifecycle)

---

### Sprint 0.8 — Conflict Handler

**Status:** Complete

**Scope:**
- Implement `src/core/conflict_handler.sh` — detect git merge conflicts, preserve both versions with device attribution
- Conflict metadata format (`.conflict` JSON files with device names, timestamps)
- Resolution logic: `prompt`, `keep_newest`, `keep_device`
- Enumerate existing `.local` files across the repo for resolution UI
- Unit tests for conflict scenarios
- Integration test: simulate two-device conflict, verify both saves preserved

**Acceptance Criteria:**
- Merge conflict on `.srm` file preserves both versions (`.<device_name>.local` + canonical)
- Conflict metadata JSON written with device names and timestamps
- Resolution removes `.local` and `.conflict` artifacts and commits result
- Enumeration lists all `.local` files with device attribution
- No save data is ever silently overwritten
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.7 (all sync phases operational)

---

## Phase 1 — NextUI Platform Client (TrimUI Brick)

**Phase status: MERGED TO MAIN (PR #3, 2026-07-07) and
hardware-validated on the TrimUI Brick.** Statuses below reflect the
merge: the owner's merge of PR #3 constitutes approval of the
implemented sprints (1.1–1.3, 1.6, 1.7, 1.8) and their specs.

**Goal:** Working save sync on a TrimUI Brick. Core sync is already built — this phase wraps it in platform-specific daemon lifecycle and user-facing UI.

### Sprint 1.1 — Daemon Bootstrap + Enrollment

**Status:** Implemented — HARDWARE-VALIDATED 2026-07-07 (first successful enrollment on TrimUI Brick; device registration pushed to user repo). Pending formal approval; see sprint-1.1-1.3-summary.md.

**Scope:**
- Implement `src/platforms/nextui/continuity_daemon.sh` — daemon skeleton
- `auto.sh` boot hook for NextUI (non-blocking, starts daemon in background)
- PID file management in `/tmp/` (prevent duplicate instances, auto-cleanup on reboot)
- Module loading: source NextUI PAL + all core modules in dependency order
- Enrollment integration: detect `setup.json`, run SD card enrollment, verify enrolled state
- Log file setup (stderr redirect to `/mnt/SDCARD/.continuity/continuity.log`)

**Acceptance Criteria:**
- Daemon starts on boot via auto.sh
- PID file prevents duplicate instances
- Enrollment runs automatically when `setup.json` is present
- Daemon exits cleanly after enrollment (boot dispatch in Sprint 1.2)
- All tests pass under `busybox ash`

**Dependencies:** Sprint 0.10 (all core modules complete)

---

### Sprint 1.2 — Boot Dispatch

**Status:** Complete — merged to main (PR #3); hardware-validated

**Scope:**
- Boot phase detection: cold start (no sentinel) vs stale boot (sentinel + no clean_shutdown) vs normal boot (sentinel + clean_shutdown)
- Dispatch to `cs_run`, `sb_run`, or `bp_run` accordingly
- Clean shutdown marker consumed on normal boot
- Boot dispatch errors are non-fatal (logged, daemon continues)

**Acceptance Criteria:**
- Correctly dispatches to cold start, boot pull, or stale boot on startup
- Saves synced to/from repo during boot
- Boot failures do not prevent daemon from continuing
- All tests pass under `busybox ash`

**Dependencies:** Sprint 1.1 (daemon bootstrap + enrollment)

---

### Sprint 1.3 — Poll Loop + Graceful Shutdown

**Status:** Complete — merged to main (PR #3); hardware-validated

**Scope:**
- Runtime poll loop: call `rp_run` every 30 seconds
- SIGTERM handler: final push attempt, conditional clean shutdown marker, PID cleanup
- Trap set after boot dispatch (not before)
- Clean shutdown marker written only when no unpushed commits remain

**Acceptance Criteria:**
- Runtime poll detects changes within 30 seconds
- Commits and pushes when WiFi is available
- Clean shutdown on SIGTERM with final push
- After clean shutdown → next boot is normal boot pull
- After unclean shutdown (SIGKILL) → next boot is stale recovery
- All tests pass under `busybox ash`

**Dependencies:** Sprint 1.2 (boot dispatch)

---

### Sprint 1.4 — WiFi Recovery, Notifications, Log Management

**Status:** Draft

**Scope:**
- WiFi recovery: push queued commits when connectivity returns (checked at poll-loop top)
- `pal_on_sync_result` implementation in NextUI PAL (colored dots via `show2.elf`)
- Log rotation: size-based (256 KB), 1 backup, ~512 KB max disk usage

**Acceptance Criteria:**
- Queues commits locally when offline, pushes when connectivity returns
- Green/yellow dots appear transiently on sync events
- Red dot persists for conflicts/errors
- Graceful degradation if `show2.elf` unavailable
- Log stays bounded at ~512 KB
- All tests pass under `busybox ash`

**Dependencies:** Sprint 1.3 (poll loop + shutdown)

---

### Sprint 1.6 — OTA Updates

**Status:** Complete — merged to main (PR #3); reworked by Sprint 1.8 (channels)

**Scope:** git-based over-the-air updates using the bundled git — persistent sparse clone of the tracked PAK, channel from build branch, verified staged apply, X/B on-device prompt. Card swaps only for binaries and bootstrap breakage.

---

### Sprint 1.5 — NextUI Tool PAK (conflict UI = reference impl of the UX design)

**Status:** Planned — **gated on** the Conflict-Resolution Experience
design (`docs/design/conflict-resolution-experience.md`, Draft 2026-07-09).
The Brick is the first reference implementation of that platform-agnostic
design (owner has the device on hand).

**Scope:**
- Implement `src/platforms/nextui/Continuity.pak/launch.sh` — Tool PAK for sync UI
- Status display: last sync time, pending changes, linked devices
- Manual sync trigger
- Conflict resolution UI — the Brick realization of the design spec:
  `src/core/conflict_ui.sh` (shared controller) driven through the NextUI
  `pal_ui_*` rendering shims (`show2.elf` + `js0`), grouping conflicts by
  game identity, try/promote flow, `.conflict` schema v2.
- Unlink device option

**Acceptance Criteria:**
- PAK appears in Tools menu on device
- Shows sync status, last sync time
- Manual sync pushes/pulls immediately
- Conflict resolution presents conflicted games with device attribution,
  supports try-before-commit, and honors every guard in the design's §4
  state machine (headless-tested via the test PAL, hardware-validated on
  the Brick)
- Unlink removes device registration and clears credentials

**Dependencies:** Sprint 1.4 (full daemon running); the Conflict-Resolution
Experience design (approved).

**Reference Specs:** `docs/design/conflict-resolution-experience.md`

---

### Sprint 1.9 — Repo Migration (ideal_os → continuity)

**Status:** Complete — the project's home moved from `jreinach-alt/ideal_os`
to `jreinach-alt/continuity` at Phase 1 complete.

**Scope:**
- Seeded `continuity` from a single root commit carrying the Phase 1 tree
  byte-identical to the `ideal_os` handoff merge (`commit-tree` from that
  merge's tree — same bytes by construction, new SHA universe).
- Handoff build: the NextUI updater's `OTA_URL` default and preflight probe
  repoint to continuity, and `ota_ensure_repo` reconciles a cached clone's
  `origin` so deployed devices repoint on an ordinary OTA (not just fresh
  installs), riding an update served from the old repo.
- continuity publishes its own channel pins to the seed **before** ideal_os
  serves the handoff, so a repointed device never sees foreign pins.
- `ideal_os` is archived (public, frozen at the handoff pins) as the
  permanent straggler shim — see `release/README.md`.

**Reference Specs:** `docs/sprints/sprint-1.9-spec.md`

---

## Phase 2 — Second Platform (RetroDeck / Steam Deck)

**Goal:** Cross-device sync works between TrimUI Brick and Steam Deck. Validates the PAL architecture with a fundamentally different platform.

### Sprint 2.0 — Save-Format Canonicalization (design approved first)

**Status:** Approved 2026-07-09 (Decisions 1A quarantine + 2A
state-coverage-only) — in progress on `claude/sprint-2.0-canonicalization`.
Spec: `docs/sprints/sprint-2.0-spec.md`.

**Reference Specs:** `docs/design/save-format-canonicalization.md` +
`docs/design/nextui-format-matrix.md` (owner-requested research gate,
completed 2026-07-08: full 4-save × 5-state NextUI option matrix pinned
to vendored source; its §8 spec deltas are 2.0 scope and its §6
scanner-coverage + `.rtc` fixes are 2.0 prerequisites).

**Scope:**
- Implement `docs/design/save-format-canonicalization.md` (drafted 2026-07-07; approve before implementation) with the format-matrix §8 deltas
- Canonical repo format: raw SRAM as `<system>/<rom_basename>.srm`; name-style translation per platform map (`minui`/`retroarch`/`generic`); RZIP detection + quarantine (codec deferred to Phase 3)
- Scanner/filter pattern expansion (matrix §6): all five state name shapes + `.rtc` as a save-class sibling — today 4 of 5 state formats are never backed up and `.rtc` is never synced
- Identity resolution ROM-anchored (matrix §5); ext-strip heuristic as repo-side fallback only
- Materialize saves only where the matching ROM exists (per-device sparse sync)
- One-time repo migration script with dry-run

**Dependencies:** Phase 1 complete. Must land before Sprint 2.3 (cross-device test needs shared identity).

---

### Sprint 2.1 — RetroDeck PAL and Enrollment

**Scope:**
- Implement RetroDeck PAL (`src/platforms/retrodeck/pal_retrodeck.sh`)
- CLI enrollment script (detect save paths, clone repo, register device)
- systemd user service definition for daemon
- Verify all core sync phases work with RetroDeck PAL (no core code changes expected)

---

### Sprint 2.2 — RetroDeck Daemon (inotify-based)

**Scope:**
- Daemon using `inotifywait` for event-driven change detection (replaces polling)
- Same core sync engine, different detection trigger
- Conflict resolution via desktop notification

---

### Sprint 2.3 — Cross-Device Integration Test

**Scope:**
- End-to-end test: save on Brick → sync → verify on RetroDeck (and reverse)
- Conflict scenario: save on both devices → verify both preserved with device attribution
- This sprint validates the entire PAL architecture across two real platforms

---

## Phase 3 — Additional Platforms

### Sprint 3.1 — muOS Client, Anbernic RG40XX V (in progress)

**Status:** Spec drafted (`docs/sprints/sprint-3.1-spec.md`, DRAFT) —
Gate 0 resolved 2026-07-09: the fleet's H700 handheld runs **muOS**
(Onion OS has no H700 build; see Sprint 3.3). Recon script shipped;
implementation blocked on the on-device recon report + spec approval.

New PAL implementation + enrollment trigger. Nearly identical to NextUI:
same aarch64 arch as the Brick (binary port expected, not a new
cross-compile), different save paths, muOS boot/task mechanism. Same
core engine. No core code changes.

### Sprint 3.2 — muOS OTA Updates

**Status:** Implemented — pending owner merge (`docs/sprints/sprint-3.2-spec.md`,
APPROVED 2026-07-10; summary in `docs/sprints/sprint-3.2-summary.md`).

Ends card-swap delivery for the muOS client. A "Continuity Update" Task
Toolkit tap fetches the pinned channel commit, verifies, and
stage-applies the new app tree — the Brick's OTA contract (Sprints
1.6/1.8) with muOS-native UX. Second committed artifact
`build/Continuity-muos.app/`, assembled by `scripts/build_muos_app.sh`;
new updater `src/platforms/muos/update.sh` (manifest-only, no legacy
branch fallback). One pinned commit in `release/channels.json` serves
BOTH platform artifacts, so a publish updates the whole fleet. No core
code changes.

### Sprint 3.3 — Onion OS Client (outline, deferred — no test hardware)

Onion OS targets the Miyoo Mini family (ARMv7) — a NEW cross-compile
target, not a port of the Brick binaries. Owner wants Onion support,
but the current fleet has no Onion-capable device to validate against,
and platform facts are validated on real hardware (project rule).
Revisit when the fleet grows. `config/platform_maps/onion.json` is the
placeholder.

### Sprint 3.4 — Android Client (outline)

Java/Kotlin app implementing the PAL interface natively. JGit for git operations. `FileObserver` for change detection. Material UI for status and conflict resolution. The conflict UI is the **native reimplementation** of the Conflict-Resolution Experience design (`docs/design/conflict-resolution-experience.md`): same on-repo `.conflict`/`.local`/trying artifacts and the same §4 resolution guards, in Kotlin rather than the shared shell controller. (Owner's Ayn Thor is the available validation device.)

---

## Proposed — Save-State Sync (pending owner approval)

Design drafted 2026-07-07 at owner request: `docs/design/save-state-sync.md`.
Un-defers save states from opaque backup to same-core cross-device
handoff (quicksave on one device, resume on another). Key findings:
every roadmap platform's state payload reduces to bare libretro core
data (RetroArch's loader accepts it as the legacy format — verified in
source), so handoff is container transforms + metadata, no emulator
changes. Phases S1–S3 in the doc; S1 rides with Sprint 2.0.
**Owner decisions:** platform list = OnionOS (confirmed 2026-07-07;
MuOS reading was wrong). [2026-07-09 correction: the H700 handheld in
the fleet runs muOS after all — Onion has no H700 build. Onion remains
desired but is deferred until Onion-capable hardware exists; see
Sprint 3.3.] Still open: auto-slot handoff default;
conflict-policy approval (states = last-writer-wins per slot, history
as undo — unlike saves). Cross-emulator tier: see
`docs/design/state-transmutation.md` (R&D framework, perpetually
experimental; repo-side compute via the Continuity Transmuter).

## Sync robustness backlog (gap review 2026-07-07)

From an offline-queue/dedupe contract review; ordered by severity:

1. ~~In-session divergence never reconciles~~ **FIXED 2026-07-07**:
   `cd_poll_once` now detects commits that would not push while
   online and runs the stale-boot reconcile inline, throttled
   (`CONTINUITY_RECONCILE_COOLDOWN_TICKS`, default 10). Proven by
   harness scenario S2b (poll ticks only — no reboot) and daemon
   unit cases.
2. ~~Misleading failure message~~ **FIXED 2026-07-07**: rejected
   pushes now notify "Push rejected — will reconcile" (git's real
   stderr was always in the log).
3. **`keep_newest` trusts device wall clocks** — MITIGATED
   2026-07-07: refuses to guess when either timestamp is missing
   (falls back to manual/prompt). Residual: a plausibly-wrong clock
   still wins ties; preflight fails hard on absurd clocks; UI default
   remains `prompt`. Accepted for now.
4. **Clock-set-backwards blind spot in the poll sentinel**: a save
   written while the device clock is behind the sentinel's mtime is
   invisible to `find -newer` until the next boot's full catch-up
   scan (which always recovers it). Bounded; documented rather
   than fixed — the fix (content-hash scanning every poll) costs more
   than the window is worth on SD cards.

Verified-covered (no action): offline commit queuing + WiFi-recovery
push + shutdown final push; two-device offline weave incl. one-sided
adds (harness S5); cmp-based no-op dedupe; OTA version-parity
adoption; enrollment offline retry; conflict resolution while offline
queues and pushes on recovery.

---

## Phase 4 — Polish and Community

### Sprint 4.1 — Enrollment Web Experience (outline)

- `idealos.dev/setup` — guided repo creation and App installation
- QR code for device setup URL

### Sprint 4.2 — Token Expiry and Rotation (outline)

- Warn when PAT approaching expiry
- Guide user through rotation without losing sync

### Sprint 4.3 — Documentation and Release (outline)

- User-facing setup guides per platform
- Core selection compatibility guide ("which cores produce compatible SRAM across devices")
- First public release

---

## Versioning

SemVer: `MAJOR.MINOR.PATCH`

| Milestone | Version |
|-----------|---------|
| Core sync engine + NextUI client working | 0.1.0 |
| RetroDeck client + cross-device validated | 0.2.0 |
| Onion OS + Android clients | 0.3.0 |
| Public release | 1.0.0 |

Dates intentionally omitted — ship when ready.
