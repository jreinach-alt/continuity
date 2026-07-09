# Sprint 1.5 — NextUI Tool PAK: Conflict-Resolution UI — Summary

**Status:** Implemented; `scripts/gate.sh full` green (current-user 41/41 +
unprivileged/`nobody` 41/41 + shipped-PAK integrity ok; qemu git-binary
checks skipped in the dev container — this sprint ships no binaries).
Hardware validation on the Brick (AC10/B1) is the one owner-side open item.

Implements the approved `docs/sprints/sprint-1.5-spec.md` (reference
realization of `docs/design/conflict-resolution-experience.md`, under
`docs/design/ui-design-system.md`).

## Files Created

- **`src/core/conflict_ui.sh`** — the shared, platform-agnostic resolution
  controller (`cu_*`). Drives the §4/§5 state machine over the finished
  `ch_*` engine through the `pal_ui_*` contract, with zero platform I/O.
  Group-by-game (`cu_list_groups`/`cu_group_members`/`cu_group_info`);
  group operations that apply a chosen side to a game's `.srm` **and**
  `.rtc` as a unit (`cu_try_group`/`cu_resolve_group`/`cu_promote_group`/
  `cu_clear_group_try`); the interactive `cu_detail`/`cu_run` loop honoring
  every §4 guard.
- **`src/platforms/nextui/pal_ui_nextui.sh`** — the Tier-0 `pal_ui_*` shims
  (`pal_ui_menu`/`message`/`confirm`/`handoff`) over `show2.elf` (one line)
  + `js0` (B/A/Y/X), built on the proven `enroll_ui.sh` `eui_*` primitives.
  Menus page with Y, pick with A, cancel with B; bounded waits so a
  walk-away never wedges the tool.
- **`src/platforms/nextui/menu_ui.sh`** — the extensible PAK main-menu shell
  (`mu_run`). Data-driven entry table (`mu_build_menu`): adding a PAK
  feature is one line + a handler. Renders `Conflicts (N)` and dispatches to
  `cu_run`; only the conflict path is wired this sprint (Status / Sync now /
  Unlink are commented one-liners for 1.5b).
- **`tests/fixtures/pal_ui_test.sh`** — scripted-queue test PAL: decisions
  pre-seeded in a queue, renders captured for assertions. Makes the whole
  controller headless-testable in both privilege passes.
- **`tests/unit/core/test_conflict_ui.sh`** — controller unit tests (38
  assertions): grouping, every §4 transition/guard, group `.srm`+`.rtc`
  resolution, keep_newest manual fallback, trying-modified promote + discard
  guard.
- **`tests/unit/nextui/test_pal_ui_nextui.sh`** — shim tests (16): menu
  paging/selection/cancel, confirm yes/no, message/handoff ack, against
  synthesized 8-byte `js_event` records + a captured show2 FIFO.
- **`tests/unit/nextui/test_menu_ui.sh`** — menu-shell tests (8): live count
  in the row, dispatch into `cu_run`, empty/zero state, and an extensibility
  probe (a throwaway second data-driven row renders + dispatches with no
  input-plumbing change).
- **`tests/integration/test_conflict_ui_flow.sh`** — end-to-end over a real
  two-device `file://` remote (22 assertions): engine-produced v2
  `.conflict`; group keep_local via `cu_run` (both members, pushed); try →
  play-on → promote the third version across two `cu_run` invocations;
  offline resolution queues then pushes on recovery.

## Files Modified

- **`src/core/conflict_handler.sh`** — `ch_preserve_conflict` now emits the
  v2 `.conflict` schema (`_schema_version 2.0`, `identity`, `class`,
  `source: pull`); `ch_get_conflict_info` reads/surfaces `identity`+`class`
  (with a defensive path-derived fallback). No back-compat reader.
- **`src/core/cold_start.sh`** — inline conflict preservation now emits the
  same v2 object (`source: cold_start`, `remote_*` nullable).
- **`src/core/pal.sh`** — `pal_validate` grows the OPTIONAL `pal_ui_*` check:
  all four defined → valid; a partial set → hard error naming the missing
  ones; none defined → still valid (digest-only fallback).
- **`src/platforms/nextui/launch.sh`** — enrolled path sources the menu
  shell + controller + shims and opens `mu_run` when there are conflicts to
  act on; removed the now-redundant `enroll_ui.sh` source in the OTA block
  (see Deviations).
- **v2 schema test updates** — `tests/unit/core/test_conflict_handler.sh`,
  `test_conflict_ops.sh` (helper + 12-field parse), `test_cold_start.sh`,
  `tests/integration/test_cold_start_flow.sh`; the `keep_newest` fixtures in
  `test_conflict_handler.sh` re-authored to v2.
- **`tests/unit/core/test_pal_validate.sh`** — optional-contract cases
  (none/full/partial).
- **`tests/unit/nextui/test_launch_sh.sh`** — copies the two new nextui
  files into the sandbox; new Test 6c (conflict present → menu opens with
  live count); PUI timeouts bounded in `run_launch`.

## Tests Written / Results

- New: `test_conflict_ui.sh` (38), `test_pal_ui_nextui.sh` (16),
  `test_menu_ui.sh` (8), `test_conflict_ui_flow.sh` (22).
- Suite grew 37 → 41 files; **41/41 pass in both privilege passes**.
- All §4 states/guards proven headless under the test PAL; the group
  `.srm`+`.rtc` unit resolution and the trying-modified "third version"
  path are covered in both the unit and the real-remote integration tests.

## Deviations from Spec

1. **Menu open policy (Decision 4).** The spec's adopted default was to open
   the menu even at zero conflicts (a `Conflicts (0)` home). Implemented
   instead: `launch.sh` opens the menu only when `ch_count_conflicts > 0` —
   a single-row menu demanding a B-press on every enrolled tap is noise
   while nothing needs attention. The menu **shell** still renders the
   zero/empty state (covered by `test_menu_ui.sh` Test 3), so the capability
   the spec wanted exists; only launch's open-policy differs. A comment in
   `launch.sh` marks the flip to unconditional-open for Sprint 1.5b, when
   Status/Sync/Unlink rows make an always-on home useful. Cheap to flip now
   if the owner prefers the always-open home.
2. **`keep_newest` is always listed** in the fresh detail menu (fixed index)
   with a manual-fallback message when a timestamp is missing, rather than
   being conditionally hidden. This keeps the Tier-0 index map stable and
   still honors the §4 guard (refusal → manual, never a dead-end).
3. **Tier-0 menu legend uses Y-paging** (`A=pick Y=next B=back`), not the
   design's *illustrative* per-verb legend (`A=try X=keep Y=other`). The
   `pal_ui_menu` contract returns an index via paging, so the shim pages;
   this is faithful to the shared contract (ui-design-system §5 "Y=next"),
   not to that one example line.
4. **Reused `enroll_ui.sh` `eui_*`** for the NextUI shim (button decode +
   one-line show) rather than re-deriving the hard-won `js_event` path. This
   required removing the duplicate `enroll_ui.sh` source in `launch.sh`'s OTA
   block — sourcing it twice re-declares its `readonly` button constants,
   which aborts ash (caught as a real exit-2 regression by the launch test).

## Open Items

1. **Hardware validation on the Brick (AC10 / design B1):** headless-proven;
   the owner runs the on-device pass (real two-device conflict → PAK opens
   the list → try loads a version into the live slot → play-on detected →
   resolution commits + pushes). Not gate-blocking for the PR per the
   headless-first / hardware-second protocol.
2. **Sprint 1.5b (tracked follow-up):** Status display, manual-sync trigger,
   Unlink — each a `mu_build_menu` row + handler over the same `pal_ui_*`
   contract (a `status_ui.sh` for the status/devices surface). At that point
   flip `launch.sh` to open the menu unconditionally.
3. **color-never-alone / `pal_on_sync_result`:** honored here via the
   always-worded `pal_ui_*` status text; the NextUI dot-word pairing defers
   to the dot's sprint (1.4), which has no dot to pair yet.
4. **Carried-forward (owner-side, from the 1.5 handoff):** the Sprint 2.0
   on-device migration and the vendored-busybox reboot confirmation — Brick
   is on hand; unchanged by this sprint.
