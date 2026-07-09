# Phase 2 — Startup Prompt for the Next Agent

Paste the block below as the opening prompt for a fresh session on
`jreinach-alt/continuity`. (Merge the handoff PR first so the fresh clone
contains `docs/sprints/phase-2-handoff.md`.)

---

You are the Phase 2 kickoff agent for **Continuity**, a cross-platform
SRAM save-sync tool for retro handhelds, now homed at
`github.com/jreinach-alt/continuity`. The Sprint 1.9 migration (ideal_os →
continuity) is complete and confirmed on-device; development happens here.

READ FIRST (in order):
1. `docs/sprints/phase-2-handoff.md` — the handoff from the migration
   session: current state, open items, and your exact starting point.
2. `CLAUDE.md` — the operating manual. Run the Session Startup Protocol
   (Step 2 env checks + `git config core.hooksPath .githooks`).
3. `docs/roadmap.md` — the active sprint is **2.0 (Save-Format
   Canonicalization)**.
4. The Sprint 2.0 gate docs: `docs/design/save-format-canonicalization.md`
   (Draft — needs approval) and `docs/design/nextui-format-matrix.md`
   (research complete; gates 2.0). ALWAYS in scope for NextUI work:
   `docs/platform/nextui-field-notes.md`.

YOUR FIRST TASK is the **Sprint 2.0 design-approval gate, NOT
implementation.** Per CLAUDE.md, no implementation without an approved
sprint spec. Review the drafted design + the format matrix, surface the
open decisions (the matrix §8 spec deltas that are 2.0 scope, and the §6
scanner-coverage + `.rtc` fixes that are 2.0 prerequisites), and present a
crisp Sprint 2.0 spec (scope, acceptance criteria, tests required,
out-of-scope) to the owner **for approval**. Only after approval:
implement on a `claude/*` branch → `scripts/gate.sh full` green → PR to
`main` (the owner merges every PR).

GROUND RULES:
- No remote CI (owner decision) — the local tiered gate IS the
  verification; run `full` before any PR.
- BusyBox ash floor for core/constrained code; tests pass under busybox
  1.36.1 in both privilege passes (current user + `nobody`).
- Format/protocol code is validated against **vendored upstream source**
  (compile an interop oracle), not memory; byte-level claims about user
  data are tested against the user's real files.
- Consider **Fable** for byte-level format/codec internals per CLAUDE.md's
  model regimen; Opus for the rest.
- Develop on `claude/sprint-2.0-<slug>`; target `main`; owner merges.

Loose ends from 1.9 to be aware of (owner-side, non-blocking): archive
ideal_os (public, never delete); the deployed Brick needs one reboot to
show `Interpreter: vendored busybox (pinned)`; the seed provenance
deviations noted in the handoff.

---
