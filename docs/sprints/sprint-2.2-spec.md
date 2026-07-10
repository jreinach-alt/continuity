# Sprint 2.2 — RetroDeck Event-Driven Daemon + Conflict UI

**Status:** Draft — awaiting owner approval. Spec-gated: no implementation
before approval.
**Branch:** `claude/sprint-2-2-retrodeck-conflict-3musse` → PR to `main`
(owner merges). No remote CI — `scripts/gate.sh full` is the verification.
**Reference Specs:** `docs/design/conflict-resolution-experience.md`
(approved 2026-07-09), `docs/design/ui-design-system.md` (approved
2026-07-09, Tier 1/2), `docs/design/pal.md` (incl. `pal_on_sync_result`
contract + notification behavior table), `docs/sprints/sprint-2.1-spec.md`
(recon findings R1–R5, daemon placement decision).

## Goal

Finish the Steam Deck client: replace the 30-second poll with
event-driven change detection (`inotifywait`), and give the Deck its
conflict-resolution surface — a desktop notification as the passive
"needs you" signal and a resolution flow that REUSES the shared
`conflict_ui.sh` controller through a new `pal_ui_retrodeck.sh` shim.
Same core sync engine, zero `src/core/**` changes.

## Decision — fold both parts into one sprint (recommended)

The roadmap's 2.2 entry already names both halves ("inotifywait …;
conflict resolution via desktop notification"). Both live entirely in
`src/platforms/retrodeck/**` + tests, they share the notification
plumbing (`pal_on_sync_result` serves the daemon's red signal AND the
conflict UI's entry point), and they share one owner recon round-trip
to the Deck. The conflict UI half is thin by design — the controller
and state machine shipped in 1.5; the NextUI shim it mirrors is ~150
lines. Comparable total size to Sprint 2.1.

**Split line if the owner prefers two PRs:** Part B detaches cleanly
(files 3–7 + their tests) with no Part A dependency. Part A alone would
still ship file 8's recon probes for both parts.

## Part A — event-driven change detection

### Design: inotify wakes the cycle; the sentinel scan stays the detector

The poll cycle (`rp_run`: `find -newer` sentinel → `cmp -s` confirm →
commit/push) remains the single source of truth for WHAT changed.
inotify only decides WHEN a cycle runs. The daemon's `sleep 30` is
replaced by a **one-shot `inotifywait` with a timeout**:

```
while true; do
    rdd_poll_once                  # unchanged cycle semantics
    rdd_wait_for_change            # block until save/state event OR timeout
done
```

`rdd_wait_for_change` in inotify mode runs (backgrounded + `wait`, so
SIGTERM still interrupts immediately, same as today's sleep):

```
inotifywait -qq -r -t <timeout> \
    -e close_write -e moved_to -e create \
    "$CONTINUITY_SAVES_ROOT" [＋"$CONTINUITY_STATES_ROOT" if set + exists]
```

- **rc 0 (event):** sleep `CONTINUITY_EVENT_SETTLE` (default 2s) so a
  burst (`.srm` + `.rtc`, RetroArch temp-write-then-rename) coalesces
  into one commit, then run the cycle. Typical save→commit latency
  drops from ≤30 s to ~3 s.
- **rc 2 (timeout):** normal housekeeping wake — the cycle still runs,
  preserving every periodic behavior the poll loop carries (deferred
  cold-start retry, WiFi-recovery push, throttled in-session
  reconcile).
- **rc 1 / not runnable:** degradation path (below).

Why one-shot instead of `inotifywait -m` (persistent monitor): no
background watcher process to manage, no event-stream parsing, no
inotify-queue-overflow data-loss mode, and watches re-establish every
cycle so newly created system dirs are covered automatically. The cost
is a blind window while a cycle runs (no watch armed): a save written
exactly then and never touched again is picked up at the next
housekeeping timeout or by the SIGTERM final sweep — bounded, and the
sentinel scan means nothing is ever lost. This is the same
detection-correctness story as today's poll, with better latency.

### Mode selection and degradation (every transition names itself)

- `rdd_detect_watch_mode` at startup: `CONTINUITY_DETECT_MODE`
  (`auto`|`inotify`|`poll`, default `auto`); `auto` picks inotify iff
  `inotifywait` is on PATH (`CONTINUITY_INOTIFY_BIN` overridable for
  tests/static-binary contingency). The chosen mode is logged:
  `"Change detection: inotify (event-driven)"` or
  `"inotifywait not found — falling back to 30s polling"`.
- Runtime failure (rc not in {0,2} — e.g. watch limit exhausted, saves
  root unmounted): sleep `CONTINUITY_POLL_INTERVAL` for that cycle (no
  hot spin), count consecutive failures, and after 3 flip permanently
  to poll mode with a named log line. rc 0/2 resets the counter.
  Recovery to inotify requires a daemon restart (systemd/next login) —
  deliberate, to keep the state machine trivial.
- Poll mode is byte-for-byte today's behavior: backgrounded
  `sleep $CONTINUITY_POLL_INTERVAL` + `wait`.

### Adaptive housekeeping timeout (idle Decks stop waking every 30s)

The one-shot timeout per cycle is chosen by pending work:

- **Pending** (`cs_is_cold_start` deferred OR `se_has_unpushed_commits`):
  `CONTINUITY_POLL_INTERVAL` (default 30 s) — recovery scenarios keep
  today's cadence exactly. This also keeps the in-session reconcile
  cooldown (`_RDD_RECONCILE_COOLDOWN`, counted in cycles) at its
  designed ~5-minute wall-clock pace, since the cooldown only counts
  while pushes are failing — i.e. while cycles are short.
- **Idle + synced:** `CONTINUITY_EVENT_IDLE_INTERVAL` (default 300 s).
  Events still wake instantly; only no-op housekeeping slows down.
- Poll mode ignores the idle interval entirely (no behavior change).

### Shutdown

`rdd_shutdown` additionally kills the backgrounded waiter
(`_RDD_WAIT_PID`, guarded `kill … 2>/dev/null || true`) before the
existing final sweep. systemd's default control-group kill remains the
backstop.

## Part B — conflict UI: notification + resolution surface

### B1. The passive signal: `pal_on_sync_result` → desktop notification

Core already fires the hook (`ss_notify` in `sync_status.sh`) on every
meaningful outcome — including **red with the conflict count after a
diverged pull** and red for trying-modified saves. Sprint 0.10 §Deferred
explicitly parked "RetroDeck `pal_on_sync_result` implementation (D-Bus
notification)" for this platform sprint. Implement it in
`pal_retrodeck.sh` over `notify-send` (D-Bus
`org.freedesktop.Notifications` — works from a `systemd --user` service
without `DISPLAY`):

| Level | notify-send mapping | Duration (pal.md contract) |
|---|---|---|
| `green` | summary `Continuity — Synced`, body = message, normal urgency | `-t 3000`, auto-dismiss |
| `yellow` | summary `Continuity — Queued`, body = message, normal urgency | `-t 4000`, auto-dismiss |
| `red` | summary `Continuity — needs you`, body = message + resolver hint, `-u critical` | persistent until dismissed (KDE keeps critical notifications on screen) |

- Status words per ui-design-system §3 (`Synced`/`Queued` in the
  summary; red's specific word — Conflict vs Error — arrives in the
  core message body, which the platform displays verbatim and never
  parses, per the pal.md contract).
- **Red debounce (required):** core re-fires red every cycle while the
  condition persists; the Deck must not stack duplicates. Suppress a
  red whose message is identical to the last **successfully sent** red
  of this daemon run (state under `$XDG_RUNTIME_DIR`/`$TMPDIR`, keyed
  per process/session); a changed message, a daemon restart, or any
  intervening green clears the suppression. `notify-send
  --print-id`/`-r` replacement is an acceptable alternative mechanism
  where available. Failed sends are never recorded as sent (Game Mode
  has no notification daemon — the red lands on the next desktop
  session's re-fire).
- **Never breaks sync:** `notify-send` missing or failing → `pal_log`
  only, return 0 always (the daemon runs under `set -e`).
- `CONTINUITY_NOTIFY_BIN` env override (test stub hook).

### B2. The rendering shim: `pal_ui_retrodeck.sh`

Implements the four-function `pal_ui_*` contract (conflict-UX §6) that
`cu_run` drives. Backend selected once at load:
`CONTINUITY_UI_BACKEND` (`auto`|`kdialog`|`zenity`|`cli`, default
`auto`) → else `kdialog` if present + display (`$DISPLAY` or
`$WAYLAND_DISPLAY`; Deck desktop mode is KDE Plasma, so kdialog first)
→ else `zenity` if present + display → else `cli` if stdin is a tty →
else fail with a named error ("no dialog tool and no terminal —
install kdialog or run from Konsole").

| Contract call | kdialog | zenity | cli |
|---|---|---|---|
| `pal_ui_menu <title> <item>…` → index or `cancel` | `--menu` with 0-based tags; prints selected tag; rc 1 → `cancel` | `--list` with hidden 0-based index column (`--print-column=1`); rc 1 → `cancel` | numbered list on stderr; reads stdin; re-prompts on invalid; empty/`q`/EOF → `cancel` |
| `pal_ui_confirm <text>` → `yes`/`no` | `--yesno`, rc 0/1 | `--question`, rc 0/1 | `[y/N]` read; EOF/anything-but-y → `no` (safe default) |
| `pal_ui_message <text>` | `--msgbox` | `--info` | print + wait for Enter (EOF ok) |
| `pal_ui_handoff <text>` | `--msgbox` (user closes and goes to play) | `--info` | print + return |

Desktop dialogs block until acted on — that is normal desktop behavior,
not a wedge (the resolver is user-launched, unlike the Brick's bounded
button waits). All stdout is reserved for contract return values;
rendering goes to the dialog tool or stderr.

### B3. The entry point: `resolve_conflicts.sh`

Mirrors `launch.sh`'s enrolled path: derive `CONTINUITY_APP_DIR` from
`$0`, source PAL + core modules + `conflict_handler.sh` +
`conflict_ui.sh` + `pal_ui_retrodeck.sh`, check `enroll_is_enrolled`,
`pal_init`/`pal_validate`/`se_init`/`pm_load_platform_map`, then
`cu_run "$CONTINUITY_REPO_DIR"` — which itself renders the empty state
("No conflicts. Everything's in sync.") and the whole §4/§5 flow.
`--backend <name>` maps to `CONTINUITY_UI_BACKEND`. Offline resolutions
queue and push on recovery (engine + daemon behavior, already tested).
Not-enrolled exits with the named error, code 78 convention.

**Controller and engine are consumed UNCHANGED.** The state machine,
group-by-identity, try/promote, and every §4 guard are already
implemented and tested in `src/core/conflict_ui.sh` — this sprint only
renders it. Any change found necessary under `src/core/**` stops the
sprint and escalates.

Concurrency note: the resolver and daemon share the repo clone exactly
as the NextUI PAK and daemon do (shipped precedent). Engine operations
are short; a rare `index.lock` collision logs a warn and the next cycle
self-heals. No new locking this sprint.

### B4. Discoverability: `continuity-resolve.desktop`

A desktop launcher template (`@APP_DIR@`-substituted, same mechanism as
the systemd unit) installed by enrollment to
`${XDG_DATA_HOME:-$HOME/.local/share}/applications/` —
`Name=Continuity — Resolve save conflicts`, `Exec=<app>/src/platforms/
retrodeck/resolve_conflicts.sh`, `Terminal=false`. Install is
best-effort (warn, never fail enrollment), mirroring the unit install.
The red notification's body hint names this launcher (and the script
path for terminal users). Cuttable line-item if the owner wants the
minimum.

## File table

| # | File | New/Mod | What |
|---|------|---------|------|
| 1 | `src/platforms/retrodeck/continuity_daemon.sh` | mod | Part A: mode detection, `rdd_wait_for_change`, adaptive timeout, degradation, waiter cleanup in shutdown |
| 2 | `src/platforms/retrodeck/pal_retrodeck.sh` | mod | B1: `pal_on_sync_result` (notify-send mapping, red debounce, log-only degrade) |
| 3 | `src/platforms/retrodeck/pal_ui_retrodeck.sh` | new | B2: the four `pal_ui_*` shims over kdialog → zenity → CLI |
| 4 | `src/platforms/retrodeck/resolve_conflicts.sh` | new | B3: resolution entry point running `cu_run` |
| 5 | `src/platforms/retrodeck/continuity-resolve.desktop` | new | B4: launcher template (`@APP_DIR@`) |
| 6 | `src/platforms/retrodeck/enroll_retrodeck.sh` | mod | B4: install the .desktop next to the unit install (best-effort) |
| 7 | `src/platforms/retrodeck/deck_recon.sh` | mod | Recon probes for 2.2: inotifywait, notify-send (+ `--print-id` support), kdialog, zenity, user-service display env (R6–R8) |
| 8 | `tests/unit/platforms/retrodeck/test_retrodeck_daemon_events.sh` | new | Part A units (stub inotifywait) |
| 9 | `tests/unit/platforms/retrodeck/test_pal_ui_retrodeck.sh` | new | B2 units (stub kdialog/zenity, CLI stdin) |
| 10 | `tests/unit/platforms/retrodeck/test_retrodeck_notifications.sh` | new | B1 units (stub notify-send) |
| 11 | `tests/integration/test_retrodeck_events_flow.sh` | new | Part A end-to-end (stub-driven; real inotifywait leg when present) |
| 12 | `tests/integration/test_retrodeck_conflict_ui_flow.sh` | new | B end-to-end: real two-device conflict resolved through the resolver |
| 13 | `docs/sprints/sprint-2.2-summary.md` | new | Handoff artifact (at completion) |
| 14 | `docs/roadmap.md` | mod | Sprint 2.2 status (rides the summary commit) |

**No `src/core/**` changes. No `config/**` changes.** The existing
`tests/integration/test_retrodeck_flow.sh` (incl. Phase 6 live-daemon)
must stay green in both worlds — with and without inotify-tools
installed.

## Environment knobs (all env-defaulted; production leaves them unset)

| Var | Default | Meaning |
|---|---|---|
| `CONTINUITY_DETECT_MODE` | `auto` | `auto`\|`inotify`\|`poll` |
| `CONTINUITY_POLL_INTERVAL` | `30` | poll-mode interval; event-mode timeout while work is pending |
| `CONTINUITY_EVENT_IDLE_INTERVAL` | `300` | event-mode housekeeping timeout when idle + synced |
| `CONTINUITY_EVENT_SETTLE` | `2` | seconds to coalesce an event burst before syncing |
| `CONTINUITY_INOTIFY_BIN` | `inotifywait` | watcher binary (test stub / static-binary contingency) |
| `CONTINUITY_NOTIFY_BIN` | `notify-send` | notifier binary (test stub) |
| `CONTINUITY_UI_BACKEND` | `auto` | `auto`\|`kdialog`\|`zenity`\|`cli` |

## Acceptance criteria

### Part A

1. **Mode detection:** `auto` picks inotify iff the watcher binary
   exists; `poll`/`inotify` force their mode; the chosen mode is a
   named log line at startup.
2. **Event wake:** with a (stub or real) watcher reporting rc 0, the
   daemon runs a cycle after the settle delay; a save written while the
   daemon idles lands committed (and pushed, online) without waiting
   for the timeout. Watcher argv includes `-r`, the saves root, and the
   states root when set.
3. **Timeout wake:** rc 2 runs the same cycle — deferred cold start,
   recovery push, and in-session reconcile all still happen in event
   mode (proven by unit-level branches, not wall-clock waits).
4. **Adaptive timeout:** pending work (deferred cold start or unpushed
   commits) selects `CONTINUITY_POLL_INTERVAL`; idle+synced selects
   `CONTINUITY_EVENT_IDLE_INTERVAL`.
5. **Degradation:** three consecutive watcher failures flip to poll
   mode permanently with a named log line; each failed cycle still
   waits a full poll interval (no hot spin); missing binary in `auto`
   never attempts inotify.
6. **Shutdown:** SIGTERM during the wait interrupts immediately (no
   full-interval stall on `systemctl --user stop`), the waiter process
   is killed, and the existing final-sweep/push/clean-marker semantics
   are unchanged.
7. **Poll mode unchanged:** forced poll mode reproduces today's loop
   exactly; `test_retrodeck_flow.sh` Phase 6 passes unmodified.

### Part B

8. **Hook mapping:** `pal_on_sync_result` maps green/yellow/red to the
   table above (urgency, expiry, summary word); message text is passed
   through verbatim, never parsed.
9. **Red debounce:** an identical red re-fired does not send a second
   notification; a changed message does; a green clears suppression; a
   FAILED send is not recorded (the next re-fire retries).
10. **Degrade:** without `notify-send`, every level logs and returns 0
    — the daemon never crashes or blocks on notification.
11. **Backend selection:** override wins; kdialog preferred over zenity
    (display present); CLI when only a tty; named error when nothing is
    available. Each backend maps all four `pal_ui_*` calls per the
    table (menu index/cancel, confirm yes/no with no-on-EOF, message,
    handoff), stdout carrying only contract values.
12. **Resolver end-to-end:** against a real two-device `file://`
    conflict (engine-produced v2 `.conflict`), the resolver driven
    through the CLI backend (scripted stdin) and through stub dialogs
    resolves a group — `.conflict`/`.local` removed, chosen side
    canonical on device and in the repo, commit pushed; the
    try → play-on → promote path works across two resolver invocations;
    a `.srm`+`.rtc` group resolves as a unit through the retrodeck map
    (RetroArch naming); zero-conflict run shows the in-sync message.
13. **Enrollment installs the launcher** (templated path, best-effort
    warn on failure, `--no-service` unaffected); re-run stays a no-op.
14. **No core diffs:** `git diff --stat main -- src/core config` is
    empty at PR time.

### Gate + hardware

15. **Gate:** `scripts/gate.sh full` green — both privilege passes, all
    test artifacts under `$TMPDIR` with per-process names, shellcheck
    clean, every script parses under `busybox ash -n`.
16. **On-device (owner-run, after merge-ready — recorded in
    `docs/platform/retrodeck-field-notes.md`):** recon R6–R8 confirmed;
    a real save lands in the repo within seconds of writing (event
    mode observed in journald); a real Brick⇆Deck conflict raises the
    critical notification in desktop mode; the launcher opens the
    resolver; a group resolves on the Deck and pushes. (This is also
    the front half of the Sprint 2.3 hardware protocol, which already
    assumes "the inotify daemon".)

## Tests required

- **Unit — daemon events (file 8):** sourced `NO_MAIN`; mode detection
  matrix (auto±binary, forced modes); adaptive timeout branches
  (stubbed `cs_is_cold_start`/`se_has_unpushed_commits`); wait
  semantics vs a stub watcher staged to rc 0/2/1 (settle applied on 0;
  failure counter; 3-strike permanent flip + named line; no hot spin);
  watcher argv recorded and asserted (roots, `-r`, timeout).
- **Unit — pal_ui shim (file 9):** backend precedence matrix (env,
  PATH stubs, DISPLAY set/unset, tty/no-tty); per-backend mapping of
  all four calls including cancel/no/EOF paths, via PATH stubs that
  record argv and return staged output/rc; CLI paths via scripted
  stdin.
- **Unit — notifications (file 10):** level→argv table; debounce
  (same/changed/cleared/failed-send); absent-binary degrade; always
  rc 0 under `set -e`.
- **Integration — events (file 11):** real daemon process with the stub
  watcher: idle daemon + staged event syncs a new save to the remote
  fast (bounded wait, no timeout reliance); SIGTERM responsiveness
  during the wait; degradation to poll still syncs. Plus a
  real-inotifywait leg that runs when the tool is present (present in
  the dev container; self-skips with a named line elsewhere) proving an
  event — not the timer — triggered the sync (idle interval set high).
- **Integration — conflict UI (file 12):** the AC12 script, built on
  the `test_conflict_ui_flow.sh` + `test_retrodeck_flow.sh` patterns
  (rdhome sandbox, `file://` remote, RetroDeck PAL throughout).
- All tests busybox-ash, self-contained, unprivileged-safe (per-process
  `$TMPDIR` names only).

## Recon gate (owner action; mirrors 2.1's R1–R5)

Re-run `deck_recon.sh` (now extended) on the Deck and send the report:

- **R6 — inotifywait:** present on SteamOS host? If absent, the shipped
  behavior is the named poll fallback (no regression vs 2.1);
  contingency = a static `inotifywait` under
  `~/.local/share/continuity/bin` pointed to by
  `CONTINUITY_INOTIFY_BIN` — a spec amendment, not built speculatively
  (same shape as 2.1's R5 git contingency).
- **R7 — notify-send:** present + a notification actually renders from
  the user-service context in desktop mode (recon prints versions and
  the user manager's display env). If absent: log-only degrade; the
  daily digest remains the passive channel; amendment could add a
  `kdialog --passivepopup` alternative.
- **R8 — kdialog / zenity:** which dialog tool exists. If neither: the
  CLI backend via Konsole is the surface and the .desktop flips to
  `Terminal=true` (small amendment).

Implementation may start on owner approval of this spec (everything is
stub-tested headless); recon contradictions amend the spec small-delta,
per the 2.1 precedent. Hardware validation (AC16) stays owner-run.

## Out of scope

- Any `src/core/**` change (controller, engine, sync phases, mappers) —
  stop-and-escalate if one seems required.
- In-session periodic PULL of remote changes (today: boot +
  push-failure reconcile only) — unchanged by design; event detection
  is about local writes.
- Daemon-skeleton hoisting into core (2.1 Open Item 3) — waits for the
  third consumer (Onion 3.1).
- Notification action buttons (`notify-send -A` launching the resolver)
  — nice-to-have; the launcher + hint text is the v1 surface.
- Status/Sync-now/Unlink surfaces on the Deck (the 1.5b analog), Game
  Mode notification delivery, RetroDeck multi-user mode, packaging/OTA
  for the Deck, save-state restore.
- The Brick's `pal_on_sync_result` dot implementation (Sprint 1.4).

## Coordination

Owns `src/platforms/retrodeck/**` + `tests/**/retrodeck*` — disjoint
from in-flight Onion 3.1 (`src/platforms/onion/**`). Touches no shared
core/config files, so no merge coordination is expected.
