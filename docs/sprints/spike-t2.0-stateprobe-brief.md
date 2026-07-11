# StateProbe — Diagnostic ROM Build Brief (handoff to a SuperForge session)

**Origin:** Continuity Spike T2.0 (`docs/sprints/spike-t2.0-snes-spec.md`
in `jreinach-alt/continuity`). This brief is **self-contained** — a
SuperForge session needs nothing from the continuity repo to execute it.
**Format:** follows SuperForge AGENTS.md prefab-brief conventions
(goal / scope MUST-MUST NOT / hard constraints / verification / report).
**Status:** DRAFT — owner reviews, then hands to a SuperForge session.

## Context (one paragraph)

Continuity is investigating whether a SNES save state written by one
emulator (Mesen2) can be decomposed into architectural machine state
and rebuilt into a state another emulator (bsnes) loads and continues
correctly. The verdict instrument needs a ROM whose machine state is
*known-good by construction* and which can **audit its own state after
being restored inside the target emulator** — converting "did the game
glitch?" into "domain 5 (DSP registers) failed at address X: expected
E, got A." SuperForge's compiler, ASM staging, headless Mesen2 harness,
and power-on-fidelity discipline make it the right shop to build this.

## Goal

A deterministic, owner-authored, redistributable LoROM (no coprocessor)
diagnostic ROM — working name **StateProbe** (`stateprobe.sfc`) — that:

1. drives every architectural state domain into documented,
   seed-derived values (WRAM, VRAM, CGRAM, OAM, ARAM, DSP, SRAM,
   CPU-visible registers, DMA register residue, timers, mailbox ports);
2. raises a **capture beacon** when the configuration is established;
3. continuously **self-audits** every CPU-verifiable domain and writes
   a structured **result block** to WRAM, mirrored to SRAM;
4. renders a **witness frame region** whose pixels depend on the
   write-only PPU state (scroll, mode, windows, color math, palette),
   so the harness catches what the CPU cannot read back;
5. ships in staged profiles (v0 quiescent → v3 hazards, below).

## Scope

**MUST:**
- Plain LoROM, 8 KiB SRAM declared, no expansion chips.
- Deterministic: same build + same inputs ⇒ identical state at any
  given beacon epoch. No reliance on uninitialized memory (SuperForge
  power-on-fidelity rules apply in full — random power-on RAM, ROM
  initializes everything it displays or audits).
- Redistributable: owner-authored code/assets only; will be committed
  as a fixture in the continuity repo (state a license in the ROM
  header docs, e.g. MIT/CC0 — owner's choice).
- Result block + beacon at the exact addresses in the contract below
  (continuity's harness hard-codes them).
- Implementation language: raw 65C816/SPC700 ASM preferred
  (`asm_repo_staging` precedent) — latch-phase and cycle-controlled
  hazards are instruction-level work. SuperForge engine/Lua may
  scaffold non-critical parts if it does not perturb determinism or
  claim the DMA/IRQ resources the probe must own.
- Suggested home: a new `diagnostics/stateprobe/` project dir (final
  location is the SuperForge orchestrator's call).

**MUST NOT:**
- Depend on any specific emulator's quirks (it runs on Mesen2, bsnes,
  and ideally hardware — flag anything hardware-unverifiable).
- Use SA-1/SuperFX/DSP-n or any coprocessor.
- Require harness-side timing heuristics: every capture-relevant
  condition must be CPU-observable (beacon/epoch) — the harness parks
  frame-stepping at a canonical scanline and reads the beacon, nothing
  fuzzier.
- Touch continuity-repo files (this brief is the only interface).

## The contract (continuity's harness consumes exactly this)

### Beacon + result block (RESULT_SCHEMA v1)

WRAM base `$7EF000`, mirrored (same layout) to SRAM offset `$0000`
after every completed audit pass. All multi-byte fields little-endian.

| Offset | Size | Field |
|---|---|---|
| +0 | 4 | magic `SPRB` |
| +4 | 1 | schema version = `$01` |
| +5 | 1 | profile id |
| +6 | 2 | build id |
| +8 | 4 | beacon epoch — increments once per main-loop iteration |
| +12 | 4 | audit generation — completed audit passes since boot |
| +16 | 4 | domain PASS bitmap (bit set = pass at latest audit) |
| +20 | 4 | domain RAN bitmap (coverage — audited at least once) |
| +24 | 1 | first-fail domain id (`$FF` = none) |
| +25 | 3 | first-fail address (24-bit, domain-local) |
| +28 | 4 | first-fail expected value |
| +32 | 4 | first-fail actual value |
| +36 | 4 | block checksum over bytes [+0..+36) |

Capture beacon: `$7EF7F0` = `$A5` exactly while the profile's
documented configuration is established and stable. The harness
captures a state only when beacon = `$A5` (it also records the epoch).

Domain IDs (bitmap bit positions): 0 WRAM, 1 VRAM, 2 CGRAM, 3 OAM,
4 ARAM, 5 DSP registers, 6 SPC timers/ports, 7 SRAM, 8 CPU math
witnesses (mul/div `$4214-17`, M7 product `$2134-36`, WRIO via
`$4213`), 9 IRQ/NMI cadence, 10 H/V + latch witnesses, 11 mailbox
protocol continuity, 12 DMA register residue, 13 epoch continuity.
14–31 reserved.

### Audit rules (hardware-legal, self-hosted)

- VRAM/CGRAM/OAM read-back only in vblank (or a shadow-restored forced
  blank window), respecting the VRAM prefetch quirk.
- ARAM/DSP audit runs SPC-side; results cross the `$2140-43` mailbox
  with sequence numbers (v2+; v0 ships a minimal echo protocol).
- SPC timer reads (`$FD-FF`) are read-to-clear — audit them with
  monotonic expectations, and document the perturbation.
- Write-only PPU state is NOT read back — it is witnessed (below).
- On any audit failure: keep running, keep auditing (the bitmap and
  first-fail fields hold the earliest failure), and paint the failed
  domain's grid cell red.

### Witness frame (for write-only state)

A fixed screen region (recommend top 64 scanlines) renders a pattern
whose pixels are a function of scroll registers, BG mode, window
config, color math, and palette. Requirements: static per epoch,
deterministic, and sensitive — a one-unit scroll change or a swapped
latch phase must visibly shift it. Rest of the screen: a per-domain
pass/fail grid (green/red cells) for instant human verdicts in a GUI
emulator. The harness screenshots the witness region and golden-
compares; the ROM does not need to (and cannot) verify this region
itself.

### Hazard profiles (staged delivery)

| Ver | Profile | Contents |
|---|---|---|
| v0 | 0 quiescent | every domain seeded + static config; simple APU tone loop; mailbox echo protocol; full CPU-side audit; witness frame; result block + SRAM mirror |
| v1 | 1 latch hazards | capture parked with: half-written BGnHOFS/VOFS (one byte of the write-twice pair), CGRAM/OAM address at odd phase, VRAM prefetch pending, WRAM port `$2181-83` mid-sequence; post-restore the ROM COMPLETES the second half — a lost latch phase shifts the witness frame |
| v2 | 2 APU stress | SPC-side ARAM + DSP-register checksum audit; 8 voices staggered envelopes, echo on, noise on one voice; capture parked mid-mailbox-transaction (sequence counters prove continuity) |
| v3 | 3 timing/IRQ + DMA | H/V IRQ armed with known HTIME/VTIME; NMI cadence counting; a mul and a div started a controlled number of cycles before the beacon; a WAI-parked variant; DMA registers left with documented residue; HDMA gradient active (reload-state capture) |

Each version is independently valuable; ship v0 before touching v1.
Profile selection mechanism (per-profile builds vs runtime select) is
the builder's choice — it must be deterministic and recorded in the
result block's profile id.

## Hard constraints

- SuperForge power-on fidelity: never assume zero-init; the harness
  stays on random power-on RAM.
- Every hazard must be *documented in-source* with the exact
  instruction window it creates (these comments become the spike's
  hazard-matrix documentation).
- ROM + all seeds + expected checksums published as a manifest JSON
  next to the ROM (the continuity harness diffs against it).
- Keep the audit's own working memory in a documented, excluded range
  (the audit must not self-invalidate).

## Verification checklist (SuperForge session runs these)

Mechanical gates:
1. Boot under MesenRunner (random power-on) → beacon `$A5` within N
   frames; result block magic/version/checksum valid; PASS bitmap all
   ones for RAN domains; audit generation advancing.
2. Two boots, same build → identical result block at equal epochs
   (determinism gate).
3. Native Mesen2 save-state at beacon → load it back → audit still
   all-pass, epoch continuity intact (same-core control — this is
   continuity's control C2 running inside SuperForge).
4. Uninit-read detector clean (`assert_no_uninitialized_reads`).
5. Witness-region screenshot stable across the two boots of gate 2.

Visual / orchestrator gates: witness frame renders as designed;
pass/fail grid legible; a deliberately-sabotaged build (flip one CGRAM
byte post-seed) turns exactly one cell red (auditor sensitivity
check — continuity's no-false-pass control C3, in-ROM edition).

## Report format (back to the owner)

Per SuperForge AGENTS.md final-report format, plus: the ROM path +
manifest, the result-block dump from gate 1, both screenshots, and any
domain the audit CANNOT cover with rationale (these become documented
blind spots in the spike's verdict, not silent gaps).

## What continuity does with it (context, not tasks)

Mesen2 states captured at the beacon → decoded → rebuilt as bsnes
states → the bsnes-side harness reads the result block after 600
frames and screenshots the witness region. The ROM also boots fresh in
both emulators to calibrate cross-emulator frame comparability
(continuity control C5), and its states become the committed
regression fixtures for same-core state sync (S1–S3) — the instrument
outlives the spike either way.
