# Spike T2.0 — SNES Cross-Core State Transmutation: Rule It In or Out

**Status:** APPROVED 2026-07-11 (owner: "Spec is good") — P0 underway.
Approval adopts the in-spec recommendations for open questions 2
(bsnes-emu/bsnes master, pinned at P0) and 5 (6-session cap); Q6
(Tier-2 run location) stays open until P3.
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
5. **The owner's SuperForge project already ships a headless Mesen2
   harness** (`jreinach-alt/SuperForge`, confirmed in-repo 2026-07-11
   — see §SuperForge assets). The source-side harness, the hardest
   part of P1, is substantially prebuilt and battle-tested.

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
| H3 | ~~Both emulators' UI/Lua state captures land on frame edges~~ **CONFIRMED 2026-07-11 (with a pinned caveat)** — Mesen2 no-debugger captures park at the first CPU instruction boundary after vblank starts (`_scanline == _nmiScanline` → `RunFrame` exit → `WaitForLock`, SnesPpu.cpp:464/482 → SnesConsole.cpp:59-70 → Emulator.cpp:148) with the SPC cycle-caught-up (`Spc::ProcessEndFrame`); with a debugger attached, `AcquireLock(allowDebuggerLock=true)` (Emulator.h:179) captures at the debugger's parked instruction boundary instead — which is exactly MesenRunner's canonical-scanline parking. Both paths are 65C816-instruction-boundary; the SPC700 may be mid-instruction in either (see ledger: refuse-class) | frame-edge capture eliminates mid-scanline/mid-DMA hazards; libretro already guarantees this fleet-side |
| H4 | The dominant correctness hazard is CPU↔APU relative phase (port handshakes, streaming engines) and DSP internal state (envelope phase, BRR position, echo offset) representation gaps | drives the hostile-capture test matrix (G4) |
| H5 | bsnes's loader validates a version signature and field-stream length, not semantic invariants | determines whether "loads at all" (G2) is a format problem or a semantics problem |
| H6 | A bsnes state serialized at power-on is a valid donor template: overwrite architectural fields, keep internal fields, and the loader accepts it | this is the encode strategy — synthesis FROM the target's own power-on + load path, exactly as the design doc mandates |
| H7 | Mesen2's state embeds settings/ROM identity that must match at load; bsnes likewise per-version | pins what the codec must carry through vs regenerate |
| H8 | ~~Mesen2's InteropDLL exports save/load-state entry points usable headless~~ **CONFIRMED 2026-07-11** — the StateProbe delivery added `save_state_file`/`load_state_file` to `MesenRunner` (upstream, in SuperForge) over the `SaveStateFile`/`LoadStateFile` InteropDLL exports; exercised by StateProbe gate 3 (save → run past → load → epoch rewind observed → 2 further all-green audit passes) | P1's source-side state bindings are DONE before the spike starts |

P0 ends with each hypothesis marked CONFIRMED/REFUTED with file/line
citations into the vendored source. A refuted H2/H6 is an early
structural-blocker candidate and triggers an owner check-in before
further spend.

## Method

### SuperForge assets (owner's prior art — surveyed 2026-07-11)

`jreinach-alt/SuperForge` (in session scope; cloned at
`/workspace/superforge`, HEAD `9bfeab3`) supplies:

- **`infrastructure/test_harness/mesen_runner.py`** (~2.8k lines) —
  headless Mesen2 via ctypes over `MesenCore.so` (InteropDLL). Already
  provides: ROM load, deterministic frame stepping with
  **canonical-scanline parking** (exactly the capture-phase discipline
  this spike needs), debugger break/resume, controller injection,
  screenshots, `read_region`/`read_bytes`/**`write_bytes`** across
  WRAM/SRAM/VRAM/OAM/CGRAM/SPC, streaming-idle detection, and an
  uninitialized-read detector. Missing ONLY state save/load (H8).
  Companion tools: `dpmap.py` (globals→DP-slot mapping),
  `visual_assertions.py`, `golden_frames.py`,
  `tools/breakpoint_diag/mesen_watchpoint.py`.
- **`docs/reference/fullsnes.txt`** (nocash) + distilled
  `resources/hardware/REF-HW-002_fullsnes_nocash.md` + audit docs —
  the hardware-semantics reference for classifying CMS fields
  (architectural truth). Format truth still comes from vendored
  emulator source only, per project discipline.
- **`scripts/build_mesen2.sh`** — builds `MesenCore.so` from
  SourMesen/Mesen2 master (unpinned, but upstream archived 2026-06 ⇒
  master is terminal; the spike records the final commit hash as the
  pin).
- **SuperForge-built ROMs** (own compiler, fully known memory maps) —
  ideal committable homebrew fixtures: liveness probes can be derived
  mechanically from `dpmap` instead of reverse-engineered.
- Note: SuperForge's MCP tool layer is per-session in that repo and
  not available here; per its own AGENTS.md, direct use of the Python
  harness is the sanctioned fallback — and is the right shape for this
  spike's standalone CLI anyway.

**Method upgrade this enables — live-core injection (control C4):**
because the wrapper has debugger-grade *write* access, we can validate
CMS completeness without any file encoding: decode a Mesen2 state →
re-inject the architectural fields into a live parked Mesen2 core →
require behaviorally identical continuation vs. natively loading that
same state. That isolates **Question A: "is the architectural
decomposition complete?"** from **Question B: "can we synthesize
bsnes's file format?"** — so a failure in P2 is immediately
attributable to semantics or to format, never ambiguous between them.

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

### Primary instrument: the StateProbe diagnostic ROM (owner insight, 2026-07-11)

Rather than inferring transfer fidelity from how commercial games
behave, the spike's primary evidence comes from a purpose-built,
owner-authored diagnostic ROM — **StateProbe** — built by a SuperForge
session against `docs/sprints/spike-t2.0-stateprobe-brief.md` (a
self-contained handoff brief). StateProbe seeds every architectural
domain with known values, raises a capture beacon, then **audits its
own state from inside whatever emulator it wakes up in**, writing a
per-domain pass/fail result block to WRAM (mirrored to SRAM, so even
an emulator with no memory API exports the verdict as a save file).
Write-only PPU state is covered by a rendered witness region whose
pixels depend on it; deliberately-parked hazards (half-written scroll
latches, mid-mailbox APU transactions, in-flight division) arrive in
staged profiles v0–v3.

What this buys the verdict:
- **Coverage by construction** — every domain and every named hazard
  is exercised deliberately; a game corpus exercises whatever it
  happens to exercise.
- **Field-level failure attribution inside one run** — the result
  block names the failed domain and address; most donor-bisection
  becomes unnecessary.
- **A fully committable Tier-1 matrix** — StateProbe is
  redistributable, so the core evidence runs anywhere (and its states
  double as the S1–S3 same-core regression fixtures afterward).

Games do not vanish: a synthetic ROM is a *model* of fragile game
code, not the population of it. The commercial corpus shrinks from
primary evidence (10 games) to an **ecological-validity confirmation
sample (3 games)**.

**Delivery status (2026-07-11):** StateProbe **v0 delivered** on
SuperForge branch `claude/stateprobe-diagnostic-rom-em6jh2` (final
commit `de79be4`) and review-verified by this spike's orchestrator:
RESULT_SCHEMA v1 byte-exact at the brief's addresses (NMI-only block
writes ⇒ untorn mid-frame reads), byte-reproducible build (committed
ROM = container rebuild = manifest sha256), hardware quirks encoded
from ground truth (VRAM prefetch dummy read, CGRAM bit-15 mask, RDDIV
clobber, IPL kick residue), honest blind-spot register (domains 4/5/6
gray until v2; ARAM `$F0-$FF` unreachable; PPU version bits
unasserted). Verification gates 1–6 (incl. determinism, same-core
round-trip = control C2, sabotage sensitivity = control C3) green in
the SuperForge session AND independently re-run by this spike. Two
review findings (a vacuous gate-2 skew branch; a control-page doc
mismatch) fixed in `de79be4`. v1–v3 hazard profiles remain staged
work; profile plumbing is in place.

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
- C2: Mesen2 native state → Mesen2 (via MesenRunner + new state
  bindings): must pass.
- C3: corrupted/truncated state → bsnes: harness must FAIL it loudly
  (no false-pass oracle).
- C4: CMS decode → live-core re-injection into parked Mesen2 →
  continuation behaviorally identical to native state load. Proves the
  decomposition captured everything that matters BEFORE any bsnes
  encoding is attempted (semantics/format failure isolation).
- C5: StateProbe booted fresh (no state transfer) in BOTH emulators to
  the same beacon epoch → witness frames compared. Establishes whether
  cross-emulator pixel-exact comparison is valid for this pair (both
  claim bit-exact PPU output) or the harness must fall back to
  within-bsnes comparisons; also calibrates the audit baseline in each
  emulator independently.

### Corpus (pre-registered before P3 runs)

**Tier 1 — StateProbe matrix (primary evidence, fully committable):**
- StateProbe profiles v0–v3 × multiple beacon epochs. Every cell reads
  as a per-domain pass/fail bitmap + witness-frame compare — the
  mechanism verdict comes from this matrix.
- StateProbe ROM, manifest, capture states, and goldens are repo
  fixtures; the whole tier runs in CI/container with no external ROMs.
- Delivery is staged (v0 first); the Tier-1 verdict on quiescent
  transfer needs only v0, hazard classification needs v1–v3.

**Tier 2 — commercial confirmation sample (ecological validity):**
- 3 plain LoROM/HiROM games from the owner's library (proposed: SMW —
  public RAM map; one HiROM RPG, e.g. Chrono Trigger or FF6; one
  audio/HDMA stresser — owner picks). A synthetic ROM models fragile
  game code; real games confirm the model generalizes.
- Capture points per game, all frame-edge: 2 quiescent + 2 hostile
  (mid-action; music-heavy scene). ROMs and commercial-derived states
  NEVER enter the repo; runs are local, results recorded as hashes +
  verdicts.
- Side-measurement (design-doc open question): whether the embedded
  SRAM view can be refreshed with current SRAM at rebuild time for
  menu-captured states (StateProbe can answer this precisely: its SRAM
  is seeded and audited).

## Pre-registered verdict criteria

| Verdict | Condition |
|---|---|
| **RULED IN (physics)** | StateProbe v0 (quiescent): ALL audited domains pass across all epochs; hazard profiles (v1–v3): every failing domain has a written root cause and a classification (fixable mapping gap vs inherently unpreservable); AND 3/3 confirmation games pass their quiescent cases |
| **RULED OUT — structural** | A load-path requirement provably unsatisfiable from architectural state + synthesis (source-cited), surviving full donor bisection — OR a StateProbe domain that fails irreducibly with the failure pinned to information absent from any architectural snapshot; generalizes to all pairs |
| **RULED OUT — threshold** | Persistent StateProbe v0 domain failures without isolable root cause within the effort cap; kill criterion fires as product decision |
| **PARTIAL** | Between the bounds — e.g. StateProbe clean but confirmation games fail hostile cases: works for named classes with root causes; owner decides posture within the perpetually-experimental fence |

The domain bitmap makes the verdict *enumerable*: "possible" is
asserted per-domain, per-hazard, not as a vibe about gameplay.

Every failure in the matrix gets a root cause tied to a field or a
source line — "it glitched" is not an admissible result.

## Phases, gates, effort cap

| Phase | Work | Gate to proceed | Box |
|---|---|---|---|
| **P0 — Format archaeology** | `fetch_refs.sh` pins both emulators by commit; build both headless; write `mss_dump` + `bst_dump` (read-only field-inventory tools against vendored serializer source); H1–H7 verdicts; CMS mapping table drafted | G0: both formats fully inventoried; no structural blocker found (else: owner check-in with evidence) | 1 session |
| **P1 — Harness** | Extend SuperForge `MesenRunner` with state save/load bindings (H8) — capture/probe side rides the existing wrapper; bsnes headless runner (custom minimal target linking `sfc/`, or the libretro build — timeboxed choice, must serialize byte-compatibly with the user-facing build); controls C1–C4 green | G1: same-core round-trips + live-injection control pass, corrupted-state control fails properly | 1–2 sessions (bsnes runner is now the only build risk) |
| **P2 — Transplant** | Power-on donor encoder; CMS decode from Mesen2; first rebuilt states; bisection tooling; iterate on StateProbe v0 (self-diagnosing) once delivered — SuperForge template ROMs serve as interim targets if v0 lags | G2: rebuilt state **loads** (format accepted). G3: StateProbe v0 all-domain pass on quiescent transfer | 1–2 sessions |
| **P3 — Matrix + verdict** | StateProbe Tier-1 matrix (v0 + delivered hazard profiles) as G4; Tier-2 confirmation sample (3 games, owner-local or session-supplied ROMs); verdict per pre-registered criteria; append verdict + evidence to `state-transmutation.md`; summary handoff | Spike ends in a verdict, whichever it is | 1 session + owner corpus time |

**Parallel track (SuperForge side, not counted in the cap):**
StateProbe is built by a SuperForge session against
`docs/sprints/spike-t2.0-stateprobe-brief.md` — v0 wanted by P2's
iteration start; v1–v3 land whenever ready and extend the Tier-1
matrix (G4 depth follows delivery). P0/P1 here have no dependency on
it.

**Effort cap (kill-criterion bound, owner-adjustable):** 6 focused
sessions total. Any phase busting its box by 2× ⇒ stop, report, owner
decides. Mandatory owner check-in at every gate.

## File table

| File | Action |
|---|---|
| `docs/sprints/spike-t2.0-snes-spec.md` | this spec |
| `docs/sprints/spike-t2.0-stateprobe-brief.md` | self-contained StateProbe build brief (handed to a SuperForge session; the ROM itself is built THERE, consumed here as a fixture) |
| `docs/roadmap.md` | add spike under the Proposed section |
| `tools/transmute/README.md` | charter + how-to-run; verdict pointer when done |
| `tools/transmute/fetch_refs.sh` | pin + fetch Mesen2/bsnes sources at exact commits into `vendor/` |
| `tools/transmute/vendor/` | gitignored (emulator sources + builds; multi-MB, never committed) |
| `tools/transmute/mss_dump.c`, `bst_dump.c` | state → field inventory (decode oracles) |
| `tools/transmute/cms/cms_snes_v1.json` + `mapping_mesen2_bsnes.json` | CMS schema + field mapping (data, not code) |
| `tools/transmute/transmute_snes.c` | decode → CMS → donor-encode pipeline |
| `tools/transmute/harness/` | MesenRunner state-binding extension (spike-local subclass or upstreamed to SuperForge — owner's call), bsnes headless runner, matrix driver, probe tables `probes/<game>.json` |
| `tests/unit/transmute/` | oracle tests over homebrew fixtures (round-trip, dump stability, refuse-unknown-chip) |
| `tests/fixtures/transmute/` | StateProbe ROM + manifest + beacon states + goldens (redistributable by construction); other homebrew-derived states + hashes |
| `.gitignore` | add `tools/transmute/vendor/` and build outputs |
| `docs/design/state-transmutation.md` | verdict section appended at spike end (the doc is the record) |
| `docs/sprints/spike-t2.0-snes-summary.md` | handoff artifact |

Out-of-table files or `src/**` edits: STOP and escalate. Nothing in
this spike touches shipped sync code, and nothing about the SRAM
contract changes regardless of outcome.

**Toolchain note:** this is desktop-tier x86_64 tooling (the design
doc already decided transmutation never runs on device). C + Python
(the SuperForge harness is Python) + POSIX sh; NOT
BusyBox-ash-constrained; exempt from the qemu/artifact gate (no
committed binaries). Unit tests still respect the unprivileged
`$TMPDIR` rules.

**Gate posture (owner decision, 2026-07-11):** the pre-push gate is
disabled in spike sessions (`core.hooksPath` unset locally — the
mainline suite doesn't exercise spike work; Startup Step 2 re-enables
it in any mainline session). A6's full-gate green at spike close
stands: the final handoff must not regress the mainline suite.

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

1. ~~Which Mesen artifact?~~ **RESOLVED by SuperForge survey
   (2026-07-11): standalone Mesen2**, the archived upstream's final
   master — the exact build SuperForge's `MesenCore.so` wraps; the
   spike records that commit hash as the pin. (Mesen-S libretro is a
   different dead codebase; out of scope.)
2. **Which bsnes build?** Recommendation: **bsnes-emu/bsnes master**
   (the maintained v115 lineage), pinned at spike start. bsnes-hd and
   ares are out of scope. Confirm.
3. **Confirmation-sample picks** — PARTIALLY RESOLVED (owner,
   2026-07-11): **SMW** (plain LoROM) + **FF3 US / FF6** (plain HiROM)
   confirmed. Owner also named Star Fox expecting chip coverage —
   corrected: SuperFX is excluded by the chip firewall; **Star Fox is
   slotted as the Tier-2 NEGATIVE CONTROL** instead (the pipeline must
   detect the GSU cart and refuse loudly, leaving state untouched —
   exercising the refuse-by-default rule against a real chip cart).
   Still open: the third PASS-game (plain-cart audio/HDMA stresser —
   candidates: Axelay, Super Castlevania IV, Tales of Phantasia JP).
4. ~~SuperForge assets~~ **RESOLVED (2026-07-11): surveyed** — see
   §SuperForge assets (harness, fullsnes.txt, dpmap-derived probes,
   SuperForge ROMs as fixtures). Remaining sub-question: should the
   state-binding extension to `MesenRunner` land upstream in SuperForge
   (useful there too) or stay spike-local under `tools/transmute/`?
5. **Effort cap** — is 6 sessions the right kill-criterion bound?
   (P1's source-side risk has collapsed thanks to the wrapper; the cap
   now mostly buys bsnes-runner work and the corpus matrix.)
6. **Where Tier-2 confirmation runs happen** — your desktop with your
   library (harness ships as a local CLI), or ROMs provided to a
   session environment? Tier 1 (StateProbe) is fully self-contained,
   so this now only affects 3 games. (Nothing commercial is ever
   committed.)
7. ~~StateProbe brief sign-off~~ **RESOLVED (2026-07-11): brief
   executed** — v0 delivered (`de79be4`, CC0-1.0), review-verified,
   gates green in both repos' hands. See §Primary instrument delivery
   status. Remaining v1–v3 hazard profiles are follow-on SuperForge
   sprints, scheduled at owner discretion (v1 latch hazards is the
   next most valuable for G4).

## Reference specs

- `docs/design/state-transmutation.md` — the framework this executes
  (CMS, tiers, kill criterion, harness-first rule).
- `docs/design/save-state-sync.md` — same-core design (S1–S3);
  RASTATE/bare-payload facts; unaffected by this spike.
- `tools/rzip/reference/` — the vendored-oracle precedent this
  follows.
- `jreinach-alt/SuperForge` (private; in session scope) —
  `infrastructure/test_harness/mesen_runner.py`,
  `scripts/build_mesen2.sh`, `docs/reference/fullsnes.txt`,
  `AGENTS.md`/`CLAUDE.md` for that repo's conventions.
- External, to be pinned by `fetch_refs.sh` in P0:
  [SourMesen/Mesen2](https://github.com/SourMesen/Mesen2) (archived
  2026-06; GPL-3.0),
  [bsnes-emu/bsnes](https://github.com/bsnes-emu/bsnes) (active),
  Mesen testrunner/Lua docs
  ([apireference](https://www.mesen.ca/docs/apireference.html),
  [misc/testrunner](https://www.mesen.ca/docs/apireference/misc.html))
  — testrunner path kept as fallback; primary harness is the
  SuperForge wrapper.
