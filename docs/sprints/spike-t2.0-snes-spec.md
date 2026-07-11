# Spike T2.0 — SNES Cross-Core State Transmutation: Rule It In or Out

**Status:** DRAFT — pending owner approval. No implementation until
approved (project methodology).
**Type:** Research spike, transmutation tier (numbered outside platform
phases; "T2" = the cross-emulator tier defined in
`docs/design/state-transmutation.md`).
**Requested:** 2026-07-11, owner: "investigate and rule out decisively
whether save state cross-core decomposition and rebuild to another core
is possible", pilot pair Mesen → bsnes, SNES first (owner has deep SNES
domain experience from the SuperForge project).
**Branch:** `claude/save-state-cross-core-spike-rxus2h`

## The question under test

Can a save state written by emulator A be decomposed into architectural
machine state and rebuilt into a state that emulator B loads and
continues **correctly** — for real games, not toy cases?

`state-transmutation.md` already frames the theory (CMS, codecs,
harness-first, fidelity tiers) and carries an owner-approved **kill
criterion**: *if the pilot pair cannot reach the threshold with bounded
effort, the tier stays same-core forever and the document becomes the
record of why.* This spike is the instrument that executes that
criterion. Its deliverable is a **verdict with evidence**, not a
shipping feature. A decisive NO is full success.

## Why Mesen2 → bsnes is the right pilot pair

This is deliberately the **most favorable pair that exists** — which is
what makes a negative result decisive:

1. Both are cycle-accurate. Their architectural snapshots are
   semantically as close as two independent SNES emulators get. Any
   pair in the wild (e.g. snes9x-family) has a *larger* semantic gap.
2. Mesen2 (source side) uses a keyed serializer — believed
   self-describing per field (H1) — the easiest possible decode target.
3. bsnes (target side) uses a synchronize-before-serialize scheduler
   discipline — believed to keep cothread/internal state out of the
   file (H2) — the smallest possible synthesis burden on encode.
4. Both codebases are open, buildable headless, and pinnable
   (Mesen2 upstream was archived 2026-06 — its format is now frozen,
   which makes the pin permanent).

**Decisiveness asymmetry (pre-registered):**
- A **structural failure** on this pair (state provably cannot be
  rebuilt without replaying emulation) generalizes: the tier is dead
  for every pair, fleet-wide. Kill criterion fires; design doc records.
- A **threshold failure** (works sometimes, below threshold after
  bounded effort) also fires the kill criterion per the design doc —
  recorded as a product decision rather than a physics impossibility.
- A **positive** result proves the physics but does NOT promise fleet
  pairs (snes9x-class cores are less accurate; different gap). That is
  explicitly a separate, later question.

## Hypotheses to pin in P0 (from source, never from memory)

Project discipline: byte-level and internals claims are validated
against vendored upstream source (`tools/rzip/reference/` precedent;
the `#!s9xsnp` misread is the cautionary tale). Everything below is
treated as **unverified hypothesis** until pinned:

| # | Hypothesis | Why it matters |
|---|---|---|
| H1 | Mesen2 states are a header + deflate-compressed **keyed** field stream (names in file) | keyed ⇒ robust decode; positional ⇒ decode mirrors source order (brittle but doable) |
| H2 | bsnes serializes only register/counter state per chip; cothreads are forced to sync points before serialize and rebuilt on load — no stack/scheduler blobs in the file | if false and opaque internal blobs exist ⇒ candidate structural blocker |
| H3 | Both emulators' UI/Lua state captures land on frame edges (or can be forced there via scripting) | frame-edge capture eliminates mid-scanline/mid-DMA hazards; libretro already guarantees this fleet-side |
| H4 | The dominant correctness hazard is CPU↔APU relative phase (port handshakes, streaming engines) and DSP internal state (envelope phase, BRR position, echo offset) representation gaps | drives the hostile-capture test matrix (G4) |
| H5 | bsnes's loader validates a version signature and field-stream length, not semantic invariants | determines whether "loads at all" (G2) is a format problem or a semantics problem |
| H6 | A bsnes state serialized at power-on is a valid donor template: overwrite architectural fields, keep internal fields, and the loader accepts it | this is the encode strategy — synthesis FROM the target's own power-on + load path, exactly as the design doc mandates |
| H7 | Mesen2's state embeds settings/ROM identity that must match at load; bsnes likewise per-version | pins what the codec must carry through vs regenerate |

P0 ends with each hypothesis marked CONFIRMED/REFUTED with file/line
citations into the vendored source. A refuted H2/H6 is an early
structural-blocker candidate and triggers an owner check-in before
further spend.

## Method

### Decomposition target: CMS-SNES v1 (from the design doc, made concrete)

Field inventory produced in P0 classifies every serialized field of
BOTH emulators into:
- **Architectural** — WRAM, VRAM, CGRAM, OAM, ARAM; 65C816 regs +
  emulation flag; PPU register file incl. write-twice latches and
  open-bus values; APU (SPC700 regs, DSP 128-byte file, timers, ports
  both directions, IPL flag); DMA/HDMA channel registers; controller
  latch/auto-read state; mul/div result registers; H/V counter +
  latch state; SRAM view. Plain LoROM/HiROM only — **coprocessor
  blocks refuse-by-default** (design-doc firewall).
- **Emulator-internal** — cycle counters, scheduler/event state, DSP
  resampler position, caches. Never translated; synthesized on encode.
- **Ambiguous** — hardware-real but sub-instruction (in-flight mul/div
  countdown, DRAM refresh position). Resolved per-field with a
  documented synthesis rule (frame-edge capture makes most moot).

The mapping table (Mesen2 field ↔ CMS ↔ bsnes field, with transforms)
is a committed artifact — it is the codec's spec and the verdict's
evidence either way.

### Rebuild strategy: donor-template encode

Primary encoder: boot the pinned bsnes headless for the same ROM,
serialize at power-on ⇒ **donor template** containing every
emulator-internal field in a self-consistent configuration from
bsnes's own code path (H6; this satisfies the design rule that encode
is written FROM the target's load path). Overwrite the architectural
fields from CMS; emit.

Diagnostic fallback: donor captured mid-game in bsnes at a frame edge.
When a rebuilt state fails, **bisect field groups** between donor and
transplant (swap CPU block, PPU block, APU block…) until the offender
is isolated. This is the highest-information failure-analysis tool and
turns "it crashed" into a named field-level root cause — which is what
"decisively" requires.

### Verification: behavioral, with controls

Bit-identical framebuffers across different emulators are NOT the bar
(internal timing phase differs; transient divergence then behavioral
convergence is expected). Per test case:

- Loads without rejection.
- Runs 600 frames, no crash/hang/black-screen.
- Scripted input produces expected WRAM invariant deltas (per-game
  probe table: player X/Y, game-mode byte, RNG-independent counters —
  this is where the owner's SuperForge-era SNES RAM knowledge plugs in
  directly; SMW's fully public RAM map makes it the first corpus game).
- Audio alive after 600 frames (buffer not flatlined unless the scene
  is legitimately silent); transient click = logged, not failed.
- Human spot-check screenshots at frames {1, 60, 600}.

**Controls (harness validity, before any transmutation is scored):**
- C1: bsnes native state → bsnes: must pass.
- C2: Mesen2 native state → Mesen2 (testrunner): must pass.
- C3: corrupted/truncated state → bsnes: harness must FAIL it loudly
  (no false-pass oracle).

### Corpus (pre-registered before P3 runs)

- 2 homebrew ROMs (redistributable — license-verified) → committable
  fixtures for regression tests.
- 10 commercial plain LoROM/HiROM games from the owner's library
  (candidates: SMW, ALttP, Super Metroid, F-Zero, Contra III, Chrono
  Trigger, FF6, EarthBound, Gradius III, DKC — owner picks/amends).
  ROMs and commercial-derived states NEVER enter the repo; runs are
  local, results recorded as hashes + verdicts.
- Capture points per game, all frame-edge via Lua: 3 quiescent (title,
  menu/pause, idle overworld) + 3 hostile (mid-action, SFX burst,
  HDMA-heavy scene / streaming-audio moment where applicable).
- Side-measurement (design-doc open question): whether the embedded
  SRAM view can be refreshed with current SRAM at rebuild time for
  menu-captured states.

## Pre-registered verdict criteria

| Verdict | Condition |
|---|---|
| **RULED IN (physics)** | ≥80% of quiescent cases pass across ≥8/10 commercial games; hostile-case failures root-caused to enumerable, fixable mapping gaps |
| **RULED OUT — structural** | A load-path requirement provably unsatisfiable from architectural state + synthesis (source-cited), surviving full donor bisection; generalizes to all pairs |
| **RULED OUT — threshold** | <30% quiescent pass after bisection within the effort cap; kill criterion fires as product decision |
| **PARTIAL** | Between the bounds: works for named classes (e.g. quiescent-only), fails others with root causes; owner decides posture within the perpetually-experimental fence |

Every failure in the matrix gets a root cause tied to a field or a
source line — "it glitched" is not an admissible result.

## Phases, gates, effort cap

| Phase | Work | Gate to proceed | Box |
|---|---|---|---|
| **P0 — Format archaeology** | `fetch_refs.sh` pins both emulators by commit; build both headless; write `mss_dump` + `bst_dump` (read-only field-inventory tools against vendored serializer source); H1–H7 verdicts; CMS mapping table drafted | G0: both formats fully inventoried; no structural blocker found (else: owner check-in with evidence) | 1 session |
| **P1 — Harness** | Mesen2 `--testrunner` + Lua capture/probe scripts; bsnes headless runner (custom minimal target linking `sfc/`, or the libretro build — timeboxed choice, must serialize byte-compatibly with the user-facing build); controls C1–C3 green | G1: same-core round-trips pass, corrupted-state control fails properly | 1–2 sessions |
| **P2 — Transplant** | Power-on donor encoder; CMS decode from Mesen2; first rebuilt states; bisection tooling; iterate on SMW until verdict-quality signal | G2: rebuilt state **loads** (format accepted). G3: SMW quiescent cases pass behavioral oracle | 1–2 sessions |
| **P3 — Matrix + verdict** | Full corpus × capture-point matrix (owner runs commercial set locally or supplies ROMs to a session); hostile cases (G4); verdict per pre-registered criteria; append verdict + evidence to `state-transmutation.md`; summary handoff | Spike ends in a verdict, whichever it is | 1 session + owner corpus time |

**Effort cap (kill-criterion bound, owner-adjustable):** 6 focused
sessions total. Any phase busting its box by 2× ⇒ stop, report, owner
decides. Mandatory owner check-in at every gate.

## File table

| File | Action |
|---|---|
| `docs/sprints/spike-t2.0-snes-spec.md` | this spec |
| `docs/roadmap.md` | add spike under the Proposed section |
| `tools/transmute/README.md` | charter + how-to-run; verdict pointer when done |
| `tools/transmute/fetch_refs.sh` | pin + fetch Mesen2/bsnes sources at exact commits into `vendor/` |
| `tools/transmute/vendor/` | gitignored (emulator sources + builds; multi-MB, never committed) |
| `tools/transmute/mss_dump.c`, `bst_dump.c` | state → field inventory (decode oracles) |
| `tools/transmute/cms/cms_snes_v1.json` + `mapping_mesen2_bsnes.json` | CMS schema + field mapping (data, not code) |
| `tools/transmute/transmute_snes.c` | decode → CMS → donor-encode pipeline |
| `tools/transmute/harness/` | Mesen2 Lua scripts, bsnes headless runner, matrix driver, probe tables `probes/<game>.json` |
| `tests/unit/transmute/` | oracle tests over homebrew fixtures (round-trip, dump stability, refuse-unknown-chip) |
| `tests/fixtures/transmute/` | homebrew-derived states + hashes only |
| `.gitignore` | add `tools/transmute/vendor/` and build outputs |
| `docs/design/state-transmutation.md` | verdict section appended at spike end (the doc is the record) |
| `docs/sprints/spike-t2.0-snes-summary.md` | handoff artifact |

Out-of-table files or `src/**` edits: STOP and escalate. Nothing in
this spike touches shipped sync code, and nothing about the SRAM
contract changes regardless of outcome.

**Toolchain note:** this is desktop-tier x86_64 tooling (the design
doc already decided transmutation never runs on device). C + POSIX
sh; NOT BusyBox-ash-constrained; exempt from the qemu/artifact gate
(no committed binaries). Unit tests still respect the unprivileged
`$TMPDIR` rules.

## Acceptance criteria (for the spike itself)

- A1. H1–H7 each carry a CONFIRMED/REFUTED verdict with source
  citations into pinned vendored code.
- A2. Complete field inventory of both formats; every field classified
  (architectural / internal / ambiguous-with-rule); mapping table
  committed.
- A3. Harness controls C1–C3 pass, proving the oracle can both pass
  valid states and fail invalid ones, before any transmutation scored.
- A4. Every corpus cell has a recorded outcome; every failure has a
  field-level or source-level root cause.
- A5. A verdict per the pre-registered criteria, appended to
  `state-transmutation.md` with the evidence matrix.
- A6. `scripts/gate.sh full` green; committed tests run under the
  standard suite (homebrew fixtures only); no ROMs, no
  commercial-derived states, no vendor trees in git.
- A7. Summary handoff with Files/Tests/Deviations/Open Items.

## Out of scope

- Coprocessor carts (SA-1, SuperFX, DSP-n, …): refused by CMS design;
  the verdict doc records the reasoning, no experiments attempted.
- The reverse direction (bsnes → Mesen2): stretch goal only if P2
  lands early; noted, never required.
- Fleet pairs (snes9x-family), product integration, Transmuter
  workflow, on-device anything, other systems (GB/GBA/…).
- Any change to same-core state sync (S1–S3) or SRAM sync semantics.

## Open questions for the owner (answer at spec approval)

1. **Which Mesen artifact?** Recommendation: **standalone Mesen2**
   (SNES core of the archived-2026-06 upstream — frozen format, best
   debugger, headless testrunner). The alternative, the old Mesen-S
   libretro core, is a different dead codebase with a different
   format. Confirm Mesen2.
2. **Which bsnes build?** Recommendation: **bsnes-emu/bsnes master**
   (the maintained v115 lineage), pinned at spike start. bsnes-hd and
   ares are out of scope. Confirm.
3. **Corpus picks** — amend the 10-game candidate list to match your
   library/experience (games where you know the RAM map cold are worth
   double).
4. **SuperForge assets** — if that work left you WRAM maps, probe
   tooling, or test states for specific games, they slot directly into
   the invariant-probe tables; which games?
5. **Effort cap** — is 6 sessions the right kill-criterion bound?
6. **Where commercial-corpus runs happen** — your desktop with your
   library (harness ships as a local CLI), or ROMs provided to a
   session environment? (Either works; nothing commercial is ever
   committed.)

## Reference specs

- `docs/design/state-transmutation.md` — the framework this executes
  (CMS, tiers, kill criterion, harness-first rule).
- `docs/design/save-state-sync.md` — same-core design (S1–S3);
  RASTATE/bare-payload facts; unaffected by this spike.
- `tools/rzip/reference/` — the vendored-oracle precedent this
  follows.
- External, to be pinned by `fetch_refs.sh` in P0:
  [SourMesen/Mesen2](https://github.com/SourMesen/Mesen2) (archived
  2026-06; GPL-3.0),
  [bsnes-emu/bsnes](https://github.com/bsnes-emu/bsnes) (active),
  Mesen testrunner/Lua docs
  ([apireference](https://www.mesen.ca/docs/apireference.html),
  [misc/testrunner](https://www.mesen.ca/docs/apireference/misc.html)).
