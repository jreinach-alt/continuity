# Sprint 1.5 Kickoff — Handoff Notes (post conflict-UX design approval)

Handoff from the conflict-UX scoping session to the next (Sprint 1.5
implementation) session. Read this first; it points you at everything else.

## TL;DR

- **The Conflict-Resolution Experience design is APPROVED** —
  `docs/design/conflict-resolution-experience.md`. It IS the spec source
  for this sprint. Read it before anything else.
- **Next work is Sprint 1.5 — NextUI Tool PAK**, whose conflict UI is the
  **Brick reference implementation** of that platform-agnostic design.
- **Spec-gated:** write the Sprint 1.5 sprint spec (scope, file table,
  acceptance criteria, tests) and get it **approved** before implementing.
  No code before an approved sprint spec (CLAUDE.md).
- **Your first action is the Sprint 1.5 spec, not code.**

## Where things stand

- **Sprint 2.0 (Save-Format Canonicalization) is merged to `main`**
  (PR #4). The on-device migration has **not** been run yet — see the
  carried-forward loose ends below.
- **The conflict-UX design is approved and merged** (see the design doc
  above). Approved decisions, locked — do not relitigate:
  - **group-by-game** resolution (a game's `.srm` + `.rtc` resolve to the
    same side);
  - **shared `conflict_ui.sh` controller + `pal_ui_*` contract** (one
    tested controller, thin per-platform shims);
  - **`.conflict` v2 is the standard, no back-compat reader** (no real repo
    has ever held a `.conflict`; the fleet is one device);
  - **NextUI Tool PAK first**, Brick-validated;
  - **`keep_newest` offered but clock-guarded**, manual is the default.
- **The conflict ENGINE already exists and is complete + tested** —
  `src/core/conflict_handler.sh` (`ch_*` API). **Do NOT rebuild it.** 1.5
  builds presentation over it. Its surface is tabulated in the design doc
  §1; the on-repo artifacts (`.local` / `.conflict` / trying markers) are
  the real cross-platform interface (design §3).

## Sprint 1.5 — what to build (from the approved design + roadmap §1.5)

- **`src/core/conflict_ui.sh`** (new, BusyBox ash) — the shared controller:
  the resolution state machine (design §4/§5) driving `ch_*`, with **zero**
  platform I/O. Honors every §4 guard (trying-modified "third version";
  group resolution of `.srm`+`.rtc` together).
- **`pal_ui_*` rendering contract** — `pal_ui_menu` / `pal_ui_message` /
  `pal_ui_confirm` / `pal_ui_handoff` (design §6). NextUI implements them
  over `show2.elf` (one line, `--key=value`, `--timeout`) + `/dev/input/js0`
  (B=0, A=1, Y=2, X=3). The **test PAL** implements them as scripted queues
  so the whole controller is headless-testable (both privilege passes),
  exactly like the sync phases.
- **`.conflict` v2 writer change** — update BOTH producers
  (`ch_preserve_conflict` and `cold_start.sh`'s inline preservation) to
  emit the v2 schema (design §3); update their existing tests. No shim.
- **The PAK conflict screens** — list → detail → try → confirm (design §5),
  Brick realization = single-line + button legend.
- **Decide in the spec** whether the other roadmap 1.5 items (status
  display, manual sync trigger, unlink device) scope into this sprint or
  split into a follow-up — the conflict UI is the heavy, gated part.
- **Entry point:** the PAK tap showing "N conflicts" is the PRIMARY entry
  and does **not** depend on Sprint 1.4. The persistent red-dot nudge is a
  1.4 concern; wire it in when 1.4 lands. So 1.5's conflict UI is not
  actually blocked by 1.4 despite the roadmap's stated dependency — note
  this in the spec.

## Standing guardrails (don't relearn these the hard way)

- **BusyBox ash floor** for core + NextUI; tests run under busybox 1.36.1,
  **both** privilege passes (current user + `nobody`).
- **No remote CI** (owner decision). The local tiered gate IS the
  verification: `scripts/gate.sh fast` per push (auto), `full` before any
  PR and at closeout. The pre-push hook runs it — a push blocks for ~4 min
  while the full gate runs, so push with a long timeout / in the background.
- **Model:** this sprint is UI + control-flow logic, not byte-level
  format/codec work — **Opus** per CLAUDE.md; no Fable needed.
- **ALWAYS in scope for NextUI work:** `docs/platform/nextui-field-notes.md`
  (show2.elf one-line/`--timeout`, js0 button numbers, the porcelain `-z`
  rule, PAK launch mechanics, the vendored-busybox fail-open invariant).
- **Develop on `claude/sprint-1.5-<slug>`; PR to `main`; the owner merges
  every PR.** Run `gate.sh full` green before the PR.
- **Headless first, hardware second:** prove the controller under the test
  PAL, THEN hardware-validate on the Brick (available — see below).

## Hardware & environment (as of 2026-07-09)

- **TrimUI Brick: AVAILABLE.** It's the validation device for 1.5, and the
  device that can close the Sprint 2.0 loose ends below.
- **Steam Deck (RetroDeck) + Anbernic (Onion): in storage ~2 weeks** — the
  2.1–2.3 and Onion platform sprints stay blocked meanwhile.
- **Windows PC: dev/validation surface only** (WSL/Git-Bash can run the
  shell core for headless testing), NOT a roadmap platform.
- **Ayn Thor (Android): available** for the eventual native Android
  reimplementation of this same design (Sprint 3.2) — not 1.5.

## Carried-forward loose ends (owner-side; the Brick is now on hand)

1. **Sprint 2.0 migration has not been run on the live saves repo.** Before
   `migrate_repo.sh --apply`: (a) confirm the Brick's real ROM-folder
   naming (`Roms/<TAG>` vs `Roms/<Display (TAG)>` — `pm_rom_dir` handles
   both, but confirm on hardware); (b) round-trip a real save through the
   migrated repo; (c) deploy the 2.0 PAK to the Brick FIRST (lockstep — an
   old-PAK device would re-push device-native names and undo the
   migration). Now that the Brick is accessible, this could be closed in
   the next session alongside or ahead of 1.5. Full context:
   `docs/sprints/sprint-2.0-summary.md`.
2. **Vendored-busybox confirmation:** the deployed Brick needs one reboot
   to report `Interpreter: vendored busybox (pinned)` (from the 1.9
   handoff). Verify if convenient while you have the device.

## How to start (Session Startup Protocol, in the continuity checkout)

1. Read `CLAUDE.md`; run Step 2 env checks + `git config core.hooksPath
   .githooks`.
2. Read `docs/roadmap.md` → active sprint = **1.5**.
3. Read **`docs/design/conflict-resolution-experience.md`** (the spec
   source) and **`docs/platform/nextui-field-notes.md`** (always in scope
   for NextUI).
4. Read this handoff + `docs/sprints/sprint-2.0-summary.md` for recent
   context.
5. Write the **Sprint 1.5 spec** (scope, file table, acceptance criteria,
   tests required, out-of-scope) and get it **approved** before coding.

## Key SHAs / facts

- `main` includes Sprint 2.0 (merge `2ee55e1`) + the conflict-UX design.
- Conflict engine: `src/core/conflict_handler.sh` (`ch_*` API, unchanged).
- Approved design: `docs/design/conflict-resolution-experience.md`.
- Deferred with the design (not 1.5): the native Android reimplementation
  (Sprint 3.2, Ayn Thor validation); N-way (>2 device) conflict rendering.
