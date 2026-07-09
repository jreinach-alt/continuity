# Sprint 1.5 — NextUI Tool PAK: Conflict-Resolution UI

**Status:** DRAFT — awaiting owner approval (spec-gated per CLAUDE.md; no
code before approval). The Brick reference implementation of the approved
`docs/design/conflict-resolution-experience.md`, nested under the approved
`docs/design/ui-design-system.md`.

**Branch:** `claude/sprint-1.5-conflict-ui-wkcvxj` → PR to `main` (owner
merges). No remote CI — `scripts/gate.sh full` green IS the verification.

**Model:** Opus (UI + control-flow logic; not byte-format/codec work).

## Goal

Give the finished, tested conflict *engine* (`src/core/conflict_handler.sh`,
`ch_*`) a front end on the TrimUI Brick, as the reference realization of the
platform-agnostic conflict-resolution experience. Build **presentation over
existing primitives** — a shared, headless-testable controller
(`conflict_ui.sh`) driving `ch_*` through a thin `pal_ui_*` rendering
contract, the NextUI shims, and an extensible PAK menu shell the conflict
flow (and the deferred PAK items) hang off. Do **not** rebuild the engine.

## Design gate (what exists vs. what this sprint adds)

- The engine is complete and covered (design §1). Its `ch_*` surface is the
  callable primitive set; the gap is purely a controller that sequences the
  calls plus per-platform rendering.
- Two divergent `.conflict` shapes exist **in code** today
  (`ch_preserve_conflict`'s v1 and `cold_start.sh`'s inline `{canonical,…}`);
  neither exists in any real repo (design §3). This sprint makes **v2 the
  single schema**, emitted by BOTH producers, with **no** back-compat reader.
- No `pal_ui_*` contract exists yet. This sprint defines it (design §6),
  implements it for NextUI (`show2.elf` + `js0`) and for a scripted **test
  PAL**, and teaches `pal_validate` an OPTIONAL check for it.
- The NextUI PAK's enrolled-state screen (`launch.sh`) shows status/scan/OTA
  today with no menu; this sprint adds an **extensible main-menu shell**
  whose **`Conflicts (N)`** row is the primary entry and whose future rows
  (the deferred PAK items) are one-line additions.

## Scope decision (owner-directed 2026-07-09)

Roadmap 1.5 also lists status display, manual-sync trigger, and unlink.
**Decision: scope this sprint to the conflict-resolution UI plus the
reusable foundation it needs — the PAK launch/menu shell and the `pal_ui_*`
contract — built GENERAL, not conflict-specific, so the remaining PAK items
plug in without rework.** Concretely:

- The **PAK main-menu shell is extensible from day one**: it renders a
  top-level menu whose entries are a data-driven list, shows **`Conflicts
  (N)`** now, and is structured so a future entry (Status, Sync now, Unlink)
  is a one-line addition — but **only the conflict path is wired** in this
  sprint.
- The `pal_ui_*` contract is defined and implemented as a **general
  rendering surface** (menu/message/confirm/handoff), not tailored to
  conflicts, so `status_ui.sh` et al. consume it unchanged.
- **Status display / manual sync / unlink are deferred to a tracked fast
  follow-up (Sprint 1.5b)** — sequenced, not dropped (see §Out of scope).
  They become handlers hung off the same menu shell + `pal_ui_*` surface.

## In scope

1. **Shared controller — `src/core/conflict_ui.sh`** (new, BusyBox ash).
   The §4/§5 resolution state machine driving `ch_*`, with **zero platform
   I/O** — every user interaction goes through `pal_ui_*`. Public `cu_*`
   surface:
   - `cu_run <repo_dir>` — top-level loop: list → detail → try/keep →
     confirm → back, until the user exits or all groups resolve.
   - `cu_list_groups <repo_dir>` — collapse `ch_list_conflicts_detailed`
     into **game-identity groups** (design §4.4): all conflicted files
     sharing the `identity` key (`<system>/<basename>`) are one group,
     regardless of class (`srm`/`rtc`). Prints one group per line.
   - `cu_resolve_group <repo_dir> <identity> <keep_remote|keep_local>` —
     apply the chosen side to **every** file in the group (both `.srm` and
     `.rtc`), never a Frankenstein (design §4 guard 3). Sequences per-member
     `ch_resolve`.
   - `cu_try_group` / `cu_confirm_group` / `cu_promote_group` — the try,
     confirm, and trying-modified promote transitions.
   The controller honors **every §4 guard**: `keep_newest` refusal on
   missing/implausible timestamps degrades to a manual menu (never an error
   dead-end); a trying-modified member ("third version") is surfaced with a
   "keep your progress?" prompt before any keep can discard it; the group
   resolves as a unit.

2. **`pal_ui_*` rendering contract** (design §6) — the four primitives the
   controller calls, each PAL implements:
   - `pal_ui_menu <title> <item>...` → prints the chosen 0-based index, or
     `cancel`.
   - `pal_ui_message <text>` → show, wait for acknowledge, return 0.
   - `pal_ui_confirm <text>` → prints `yes` / `no`.
   - `pal_ui_handoff <text>` → show the "go play, come back" message and
     yield (the platform decides how the user returns).
   Every rendered status string carries its **word** (ui-design-system §3
   color-never-alone) — `Conflict`, `Synced`, etc. — so the contract is
   accessible by construction, independent of any color/dot.

3. **NextUI shims — `src/platforms/nextui/pal_ui_nextui.sh`** (new). Implements
   `pal_ui_*` over a `show2.elf` daemon FIFO (single line, `--key=value`,
   truncate to ~64 chars) + `/dev/input/js0` button reads (B=0, A=1, Y=2,
   X=3), reusing the enroll-UI idiom (`eui_*` button listener / one-line
   show). Menus page with `Y=next`, select with `A`, cancel with `B`
   (ui-design-system §5 Tier-0 paging). All device paths env-overridable for
   tests.

4. **`.conflict` v2 writer change** — update BOTH producers to emit the
   design §3 v2 schema and **delete no-longer-true v1/inline fields**:
   - `ch_preserve_conflict` (`conflict_handler.sh`): add `_schema_version:
     "2.0"`, `identity`, `class`, `source: "pull"`; keep `remote_*`
     nullable.
   - `cold_start.sh` inline preservation: replace the `{canonical,
     local_device, timestamp, source}` block with the full v2 object
     (`source: "cold_start"`, `remote_device: "unknown"`, empty
     `remote_timestamp`).
   `ch_get_conflict_info` reads v2 (already derives system/game; now also
   surfaces `identity`/`class`). **No compatibility shim** (design §3).

5. **Extensible PAK main-menu shell — `src/platforms/nextui/menu_ui.sh`**
   (new). A **general** menu dispatcher rendered entirely through
   `pal_ui_menu`, driven by a data-driven entry list (label + count + handler
   per row). It shows **`Conflicts (N)`** (N from `ch_count_conflicts`, the
   row hidden or shown-as-0 per §Decisions) and dispatches the selected row
   to its handler. **Only the conflict handler (`cu_run`) is wired** this
   sprint; Status / Sync now / Unlink are future rows added in one line each
   (1.5b). The shell owns paging/selection/back via the contract, so adding a
   row needs no new input plumbing. Not conflict-specific.

6. **PAK entry point — `launch.sh`** (modified). In the enrolled state, after
   status/scan, source the menu shell + controller + NextUI shims and open
   `menu_ui`. The conflict row is the **primary** actionable item and does
   **NOT** depend on Sprint 1.4's red dot (handoff): the persistent-dot nudge
   is wired when 1.4 lands; the PAK-tap count is sufficient now. With zero
   conflicts and no other rows wired yet, the menu still opens (single
   `Conflicts (0)` row / "Nothing to resolve" per §Decisions) — the shell is
   the durable home the deferred items attach to.

7. **`pal_validate` optional check** (`pal.sh`) — a platform that advertises
   conflict UI defines the full `pal_ui_*` set; `pal_validate` grows an
   OPTIONAL check that, IF any `pal_ui_*` is defined, ALL four must be
   (partial contract = hard error). Platforms with none fall back to the
   digest-only path — still valid. Does not add to the required-4 set.

## Resolved ambiguities (pre-flight)

- **`class` for the Brick's `.sav`.** Design §3 lists `class: "srm | rtc"`,
  but the Brick's compiled default save extension is `.sav` (field notes),
  and repo files can be `.srm` or `.sav`. **Decision:** `class` is the
  save-*class*, not the file extension — `rtc` for `.rtc`, else `srm` (the
  SRAM class, covering `.srm` **and** `.sav`). `identity` strips whichever of
  `.srm`/`.sav`/`.rtc` is present (matching the existing `game` derivation in
  `ch_get_conflict_info`), so a game's `.sav` + `.rtc` still group. The full
  original path (with real extension) is preserved in `file`.
- **Color-never-alone tweak to `pal_on_sync_result`.** `pal_on_sync_result`
  is not implemented on NextUI today (no dot is rendered; the dot is a 1.4
  concern). There is nothing to pair a word with yet. **Decision:** satisfy
  the rule where this sprint actually renders — the `pal_ui_*` status words
  always carry text — and defer the `pal_on_sync_result` dot-pairing to the
  sprint that introduces the NextUI dot (1.4). Noted, not silently dropped.

## Acceptance criteria

1. **Controller drives every §4 state, headless, under the test PAL, in both
   privilege passes:** UNRESOLVED → TRYING (try remote|local) → back to
   UNRESOLVED (cancel-try); UNRESOLVED → RESOLVED (keep remote|local);
   TRYING → TRYING-MODIFIED (played-on detected) → RESOLVED (promote).
2. **Group resolution:** a game with BOTH `.srm` and `.rtc` conflicts
   resolves as a unit — the chosen side's `.srm` and `.rtc` are both
   promoted; no Frankenstein (device-A `.srm` + device-B `.rtc`) is ever
   produced.
3. **Trying-modified guard:** after try-and-play on one member, a `keep`
   first surfaces "you made progress — keep it?" and routes to
   `ch_promote_trying`; the third version is never silently discarded.
4. **`keep_newest` guard:** offered but, when either timestamp is
   missing/implausible, the UI falls back to a manual choice (not an error
   dead-end); default resolution stays manual.
5. **`.conflict` v2 by BOTH producers:** `ch_preserve_conflict` and
   `cold_start.sh` emit the §3 v2 object; `ch_get_conflict_info` parses
   `identity`/`class`; existing conflict/cold-start tests updated to v2 (no
   shim). `remote_*` stays nullable for cold-start.
6. **Menu shell + PAK entry:** the enrolled launch opens the main-menu shell;
   the `Conflicts (N)` row shows the live count and dispatches to `cu_run`;
   the shell renders entirely through `pal_ui_menu` and its entry list is
   data-driven (proven by a test that adds a throwaway second row and sees it
   render + dispatch without touching input plumbing). Selecting the conflict
   row with N conflicts opens the list; the deferred rows are absent.
7. **No path deletes the losing version before an explicit confirm;** an
   offline resolution queues the commit and pushes on connectivity return
   (engine behavior — asserted through the controller).
8. **NextUI shims:** `pal_ui_menu/message/confirm/handoff` render one line +
   legend and decode B/A/Y/X correctly against synthesized `js_event`
   records (same fixture idiom as the enroll-UI button tests).
9. **`pal_validate`:** all four `pal_ui_*` defined → passes; a partial set →
   fails naming the missing ones; none defined → still passes (fallback).
10. **Hardware validation (B1, design §8):** on the Brick, a real two-device
    conflict opens the PAK list, a try loads a version into the live slot,
    play-on is detected, and a resolution commits + pushes. (Owner-run with
    the device; recorded in the summary. Not gate-blocking for the PR, per
    the headless-first / hardware-second protocol.)
11. `scripts/gate.sh full` green (both privilege passes, shipped-PAK
    integrity unaffected).

## Tests required

- **Unit — `tests/unit/core/test_conflict_ui.sh`** (new): the controller
  against the scripted **test PAL**, covering every §4 transition and guard
  (AC 1–4, 7), group collapse (`cu_list_groups`), and group resolution
  (AC 2). Uses a real `git` temp repo seeded with `ch_*` artifacts; both
  privilege passes; `$TMPDIR`-scoped, per-process temp names (never writes
  into the repo tree).
- **Unit — `tests/unit/nextui/test_pal_ui_nextui.sh`** (new): the NextUI
  shims — menu paging/selection, confirm yes/no, message/handoff ack —
  driven by synthesized 8-byte `js_event` records and a captured show2 FIFO
  file (AC 8), mirroring `test`-side enroll-UI button tests.
- **Integration — `tests/integration/test_conflict_ui_flow.sh`** (new):
  end-to-end over the test PAL and a real two-remote git setup — surface a
  conflict, try, play-on (mutate the live slot), promote; separately, a
  group `.srm`+`.rtc` keep; assert repo artifacts removed + canonical bytes
  correct + push queued (AC 1–3, 5, 7).
- **Fixtures — `tests/fixtures/pal_ui_test.sh`** (new): the scripted-queue
  test PAL. `pal_ui_*` consume a pre-seeded response queue (menu index /
  `yes`/`no` / ack) and append rendered lines to a capture file for
  assertions. Sourced on top of `pal_test.sh`.
- **Updated schema tests:** extend `tests/unit/core/test_conflict_handler.sh`,
  `tests/unit/core/test_cold_start.sh`, and every conflict/cold-start
  integration test that asserts on `.conflict` fields
  (`test_conflict_flow.sh`, `test_conflict_resolution_flow.sh`,
  `test_two_device_conflict.sh`, `test_cold_start_flow.sh` — audited during
  implementation) to the v2 schema (AC 5).
- **Updated `pal_validate` test** (`tests/unit/core/test_pal_validate.sh`):
  the optional `pal_ui_*` check (AC 9).
- **Unit — `tests/unit/nextui/test_menu_ui.sh`** (new): the menu shell over
  the test PAL — the `Conflicts (N)` row shows the count and dispatches to its
  handler; a second (throwaway) data-driven row renders + dispatches with no
  input-plumbing change (proves extensibility, AC 6); back/cancel returns to
  launch cleanly.
- **Updated launch test** (`tests/unit/nextui/test_launch_sh.sh`): the
  enrolled path opens the menu shell and the conflict row reflects the live
  count (AC 6).

## File table

| File | Action |
|---|---|
| `src/core/conflict_ui.sh` | **create** — shared `cu_*` controller |
| `src/platforms/nextui/pal_ui_nextui.sh` | **create** — NextUI `pal_ui_*` shims |
| `src/platforms/nextui/menu_ui.sh` | **create** — extensible PAK main-menu shell (conflict path wired) |
| `tests/fixtures/pal_ui_test.sh` | **create** — scripted-queue test PAL |
| `tests/unit/nextui/test_menu_ui.sh` | **create** — menu shell rendering/dispatch/extensibility tests |
| `tests/unit/core/test_conflict_ui.sh` | **create** — controller/state-machine unit tests |
| `tests/unit/nextui/test_pal_ui_nextui.sh` | **create** — shim rendering/button tests |
| `tests/integration/test_conflict_ui_flow.sh` | **create** — end-to-end flow |
| `src/core/conflict_handler.sh` | **modify** — `ch_preserve_conflict` → v2; `ch_get_conflict_info` surfaces identity/class |
| `src/core/cold_start.sh` | **modify** — inline preservation → v2 |
| `src/core/pal.sh` | **modify** — optional `pal_ui_*` check |
| `src/platforms/nextui/launch.sh` | **modify** — conflict entry point + module wiring |
| `tests/unit/core/test_conflict_handler.sh` | **modify** — v2 assertions |
| `tests/unit/core/test_cold_start.sh` | **modify** — v2 assertions |
| `tests/unit/core/test_pal_validate.sh` | **modify** — optional-contract assertions |
| `tests/unit/nextui/test_launch_sh.sh` | **modify** — conflict-entry assertions |
| `tests/integration/test_conflict_flow.sh` | **modify** — v2 assertions |
| `tests/integration/test_conflict_resolution_flow.sh` | **modify** — v2 assertions (if it asserts schema) |
| `tests/integration/test_two_device_conflict.sh` | **modify** — v2 assertions (if it asserts schema) |
| `tests/integration/test_cold_start_flow.sh` | **modify** — v2 assertions (if it asserts schema) |
| `docs/sprints/sprint-1.5-summary.md` | **create** (closeout) — handoff artifact |

No new top-level folders. All new source under existing `src/core/`,
`src/platforms/nextui/`, `tests/`.

## Out of scope

- **Status home / manual-sync / unlink** — a **tracked fast follow-up
  (Sprint 1.5b)**, sequenced not dropped: each becomes a menu row hung off
  the extensible shell + a `status_ui.sh` consuming the same `pal_ui_*`
  contract this sprint delivers. The foundation (menu shell, `pal_ui_*`) is
  built general here specifically so 1.5b is additive, not a rework.
- **Sprint 1.4 red-dot / notifications** — the PAK-tap count is the entry
  this sprint needs; the persistent dot is wired when 1.4 lands.
- **`pal_on_sync_result` dot-word pairing** — deferred to the sprint that
  renders the NextUI dot (1.4); the rule is honored where this sprint renders.
- **N-way (>2 device) conflict rendering** — design §9; the model supports N
  `.local` files, the first UI targets the two-device case.
- **Onion / RetroDeck `pal_ui_*` shims** — those platform sessions consume
  this contract later; this sprint owns core + NextUI only.
- **Android native reimplementation** (Sprint 3.2) — shares the contract, not
  the code.
- **Rebuilding the conflict engine** — `ch_*` is complete; this is
  presentation only.
- **Sprint 2.0 on-device migration loose ends** — owner-side device work,
  tracked separately (handoff §Carried-forward).

## Decisions

1. **Scope (§Scope decision) — RESOLVED (owner, 2026-07-09):** conflict UI +
   the reusable foundation (extensible PAK menu shell + general `pal_ui_*`
   contract), conflict path wired only; status/manual-sync/unlink deferred to
   a tracked follow-up (Sprint 1.5b).
2. **`class` semantics (§Resolved ambiguities) — adopted default:** `class =
   srm` covers both `.srm` and `.sav` (SRAM class), `rtc` for `.rtc`.
   Proceeding unless the owner objects.
3. **Color-never-alone (§Resolved ambiguities) — adopted default:** honored
   via the always-worded `pal_ui_*` status text now; the `pal_on_sync_result`
   dot pairing defers to the dot's sprint (1.4). Proceeding unless the owner
   objects.
4. **Empty-menu affordance — adopted default:** with zero conflicts the menu
   still opens on a `Conflicts (0)` row (rather than hiding it), so the shell
   is a stable home the deferred rows attach to and the "nothing to resolve"
   state is explicit. Cheap to flip to hide-when-zero if the owner prefers.
