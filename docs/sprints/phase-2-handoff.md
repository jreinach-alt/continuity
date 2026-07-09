# Phase 2 Kickoff — Handoff Notes (post Sprint 1.9)

Handoff from the Sprint 1.9 migration session to the next (Phase 2)
session. Read this first; it points you at everything else.

## TL;DR

- **Home is now `github.com/jreinach-alt/continuity`.** The ideal_os →
  continuity migration is complete and confirmed on-device. Develop here.
- **Next work is Phase 2 / Sprint 2.0 — Save-Format Canonicalization**,
  and it is **spec-gated**: do NOT implement until the design is approved.
- **Your first action is the Sprint 2.0 design-approval gate** (present
  the drafted design for owner approval + a crisp spec), not code.

## Where things stand (Sprint 1.9 — done)

- continuity seeded from a single root commit `fd849e2` (tree
  byte-identical to the ideal_os handoff merge `bdbe9ea`).
- Both channels pin the seed; the deployed TrimUI Brick OTA-migrated —
  origin repoint + version-parity adoption confirmed in the device's
  `update.log`. No card swap, no re-download.
- Full record: **`docs/sprints/sprint-1.9-summary.md`**.

### Loose ends from 1.9 (owner-side; none block Phase 2)

1. **Archive ideal_os** — keep it **public, never delete/privatize**.
   Its frozen manifest is the permanent straggler self-heal shim.
2. **Busybox interpreter confirmation** — the deployed daemon needs one
   **reboot** to run the handoff build's vendored busybox. After reboot,
   `continuity.log` should read `Interpreter: vendored busybox (pinned)`
   and `CONTINUITY_DIAGNOSTIC.txt` `ok busybox`. Pre-reboot it correctly
   reads `device sh` (the pre-handoff build shipped no busybox).
3. **Seed provenance deviations** — root commit `fd849e2` reads
   "PRs #1–5" (vs the spec template's "#1–4") and carries the standard
   `Co-Authored-By`/`Claude-Session` trailers. Owner-reversible via one
   re-seed (nothing depends on the seed SHA but the manifest).

## Phase 2 / Sprint 2.0 — Save-Format Canonicalization

ONE canonical repo representation of a save + per-device materialization,
so "the same save" is not two unrelated repo paths across platforms. This
is the prerequisite for the second platform (RetroDeck, Sprint 2.1) and
cross-device sync (Sprint 2.3).

### The gate — read, then get approval before coding

- **`docs/design/save-format-canonicalization.md`** — Status: *Draft for
  approval*. The design.
- **`docs/design/nextui-format-matrix.md`** — Status: *Research complete;
  gates 2.0*. §8 spec deltas are 2.0 scope; §6 scanner-coverage + `.rtc`
  fixes are 2.0 prerequisites; identity resolution is ROM-anchored (§5).
- **`docs/roadmap.md`** → Sprint 2.0 entry (scope, dependencies).

### Scope (from the roadmap, pending your spec + owner approval)

- Canonical repo format: raw SRAM as `<system>/<rom_basename>.srm`;
  name-style translation per platform map (`minui`/`retroarch`/`generic`);
  RZIP detection + quarantine (codec deferred to Phase 3).
- Scanner/filter expansion (matrix §6): all five state name shapes +
  `.rtc` as a save-class sibling — today 4 of 5 state formats are never
  backed up and `.rtc` is never synced.
- Identity resolution ROM-anchored (matrix §5); ext-strip heuristic is a
  repo-side fallback only.
- Materialize saves only where the matching ROM exists (per-device
  sparse sync).
- One-time repo-migration script with a dry-run.

## How to start (Session Startup Protocol, in the continuity checkout)

1. Read `CLAUDE.md`.
2. Verify env: `busybox`, `shellcheck`, `git`; then
   `git config core.hooksPath .githooks` (the blocking pre-push gate).
3. Read `docs/roadmap.md`; active sprint = 2.0.
4. Read the two gate docs above; write/confirm the Sprint 2.0 spec and
   get it approved **before** implementing.
5. Always in scope for NextUI work: **`docs/platform/nextui-field-notes.md`**.
6. This handoff + `docs/sprints/sprint-1.9-summary.md` for context.

## Standing guardrails (don't relearn these the hard way)

- **No remote CI** (owner decision). The local tiered gate IS the
  verification: `scripts/gate.sh fast` per push (auto), `full` at
  PAK/publish/PR/closeout. Run `full` before any PR.
- **BusyBox ash floor** for core + constrained-platform code; tests run
  under busybox 1.36.1, **both** privilege passes (current user +
  `nobody`).
- **Format/protocol code is validated against vendored upstream source**,
  not memory or docs (precedents: the rzip reference oracle in
  `tools/rzip/reference/`, the busybox matrix). Byte-level claims about
  user data get tested against the user's real files.
- **Model regimen:** Sprint 2.0 is byte-level format work — consider
  **Fable** for the format/codec internals per CLAUDE.md's escalation
  classes; Opus for the rest.
- **PRs:** work on a `claude/*` branch, target `main`, **the owner merges
  every PR**. Phase 2 is continuity-only — no ideal_os work.

## Key SHAs / facts

- continuity `main`: `2d593c1` (at handoff writing).
- seed (root): `fd849e2`; ideal_os handoff merge: `bdbe9ea`; both carry
  version `0.1.0-20260709-0142`.
- Real device format facts + save sweep: `docs/platform/nextui-field-notes.md`
  ("Real-repo byte sweep") and `docs/design/nextui-format-matrix.md`.
