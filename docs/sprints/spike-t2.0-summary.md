# Spike T2.0 — Running Summary / Findings Ledger

**Status: P0 (format archaeology) COMPLETE except fixture import** —
session 2 (2026-07-11, continuation branch
`claude/spike-t2-continuation-4ejjew`) delivered the full field
inventory, the CMS mapping tables, both decode oracles, and their test
suite. The one remaining P0 item — StateProbe fixture import + a real
beacon `.mss` — is blocked on SuperForge repo access (below) and rides
into the next session. **No structural blocker found: G0's technical
bar is met; owner check-in before P1 is now due.**

## Files Created

- `tools/transmute/fetch_refs.sh` — pinned fetch of both reference
  trees (session 1).
- `tools/transmute/README.md` — workbench charter + pin table (s1;
  updated s2).
- `tools/transmute/cms/cms_snes_v1.json` — CMS-SNES v1 schema:
  architectural state only, every field classified, StateProbe domain
  IDs cross-referenced, capture contract + excluded domains explicit.
- `tools/transmute/cms/mapping_mesen2_bsnes.json` — the P0 core
  artifact: both containers, both payload framings, the COMPLETE
  field inventory of both formats in stream/key order with widths and
  citations, per-field classification, CMS correspondence +
  transforms, interrupt truth-table sketch, refuse rules, and the
  short list of P2 pins.
- `tools/transmute/mss_dump.c` — Mesen2 `.mss` decode oracle
  (container header, zlib payload, keyed record walk, chip-firewall
  refuse; exit 0/1/2 = clean/malformed/refused).
- `tools/transmute/bst_dump.c` — bsnes `.bst` decode oracle
  (container, nall RLE<1>, header gates exactly as `unserialize`,
  full positional plain-cart walk at pinned widths for the
  fastPPU=true layout, zero-residual check as the mechanical chip
  firewall).
- `tools/transmute/gen_fixtures.py` — deterministic synthetic
  container fixtures + sha256 manifest.
- `tests/fixtures/transmute/` — 6 committed fixtures + manifest
  (valid/chip-cart/truncated `.mss`; valid/sync0/chip-residual
  `.bst`).
- `tests/unit/transmute/test_dumpers.sh` — 22 assertions: builds both
  oracles, fixture-manifest integrity, decode + planted-value spot
  checks, dump stability, every refuse/gate path, usage errors.

## Files Modified

- `.gitignore` — `tools/transmute/{vendor,build}/` (s1).
- `docs/sprints/spike-t2.0-snes-spec.md` — s1: approval + corpus Q3;
  s2: H3 verdict recorded in the hypothesis table.
- `docs/roadmap.md` — spike entry status (s1; s2 refresh).

## Tests Written

`tests/unit/transmute/test_dumpers.sh` — 22/22 green under
`busybox ash`, shellcheck clean, unprivileged-safe (mktemp under
`$TMPDIR` only). Note the cross-check design: the fixture generator
transcribes the byte layout from the mapping JSON, the dumpers
transcribe it from the vendored serialize sources — the synthetic
`.bst` walking to exactly zero residual (290,423/290,423 bytes)
verifies the two independent transcriptions agree on every width.
Semantic (emulator-produced) oracle fixtures arrive with the
StateProbe import.

## Pins

| Tree | Commit |
|---|---|
| Mesen2 | `b9fa69ddc6d0a331fb103fdb5eef6904305703c2` (archived upstream's final commit, 2026-06-04) |
| bsnes | `7d5aa1e656b9171524d01b1b22917197d8121cb4` (bsnes-emu master; `SerializerVersion "115.1"`) |

All citations are `path:line@pin` in `tools/transmute/vendor/`.

**Session-2 pins (Open Items 4+5 of session 1, all resolved):**
- `configuration.hacks.ppu.fast = true` is the DEFAULT
  (`bsnes:sfc/interface/configuration.hpp:38`) → default `.bst`
  states carry `fastppu=1` and the **ppu-fast layout**;
  `PPU::serialize` always writes 3 display ints first, then
  dispatches (`sfc/ppu/serialization.cpp:1-8`). The encoder targets
  the fast layout; the accurate layout is inventoried (decode-refused
  as out-of-pilot-scope — the pipeline never produces it).
- `hacks.dsp.fast = true` default is EXECUTION-only
  (`sfc/dsp/dsp.cpp:11`); DSP serialization layout is unaffected.
- `runToSave` semantics (`sfc/system/system.cpp:16-108`): Fast =
  default+fallback (run to CPU-thread sync, then force-sync
  smp/ppu/coprocessors ignoring desyncs); Strict = resync-all loop
  with SMP synced twice; per-title Strict overrides (Star Ocean,
  Tales of Phantasia, ICD carts); `coprocessor.delayedSync` forced on
  during save.
- H3 pinned CONFIRMED — see spec table (frame-edge no-debugger path /
  debugger-park path; both 65C816-instruction-boundary).
- nall serializer primitives (`nall/serializer.hpp:85-137`,
  `nall/primitives/natural.hpp:8-13`): integers LE at sizeof
  (bool=1); `Natural<N>`/`Integer<N>` at utype width 1/2/4/8;
  floats raw memory bytes; u8 arrays memcpy'd.
- `int16 samplebuffer[8192]` → 16,384 bytes (`sfc/dsp/dsp.hpp:22`);
  SPC_DSP blob fixed 640 bytes (514 meaningful + zero pad;
  `SPC_DSP.h:61`, walk in `SPC_DSP.cpp:949-1016`).

## Hypothesis ledger (spec §Hypotheses)

| # | Verdict | Evidence |
|---|---|---|
| H1 (Mesen2 keyed) | **CONFIRMED** (s1) | `Serializer.h:255-283` — keyed records, unknown keys tolerated |
| H2 (bsnes: no cothread stacks in normal states) | **CONFIRMED** (s1) | stacks only in `synchronize=false` rewind variant; `bst_dump` refuses those |
| H3 (frame-edge captures) | **CONFIRMED w/ caveat** (s2) | see spec table; SPC700 sub-instruction state is the residual hazard, handled as a refuse-class |
| H4 (CPU↔APU phase + DSP state are the top hazard) | OPEN → **NARROWED** (s2) | inventory shows both DSPs are the same blargg-lineage silicon model — `dsp_internal` maps nearly field-for-field (names align: NoiseLfsr↔noise, Counter↔counter, BrrNextAddress↔t_brr_next_addr, …). The remaining H4 core is CPU↔SMP relative phase (Thread.clock donor alignment) + SPC mid-instruction captures. P2 empirics (StateProbe v2/v3) quantify |
| H5 (bsnes loader: format checks only) | **CONFIRMED** (s1) | 4 gates, no semantics; `bst_dump` mirrors them |
| H6 (power-on donor viable) | STRENGTHENED (s1), unchanged | loader power-cycles before positional read |
| H7 (ROM identity) | **REVISED** (s1) | neither format validates ROM identity; manifest sha256 is OUR discipline |
| H8 (InteropDLL state exports) | **CONFIRMED** (s1) | StateProbe gate 3 |

## Container formats

Pinned in session 1; now machine-readable in
`cms/mapping_mesen2_bsnes.json` §containers and executable in the two
dumpers. One refinement landed in s2: the `.mss` payload's
`[u8 isCompressed]` may legally be 0 (records to EOF, no size words)
— `mss_dump` handles both.

## Session-2 findings worth carrying (decode/encode design inputs)

1. **bsnes serializes NO controller/expansion state** — the ports'
   `serialize()` are empty (`controller.cpp:60-61`,
   `expansion.cpp:36-37`). A plain-cart stream is exactly
   header+random+sram+cpu+smp+ppu+dsp. Controller shift-register
   state mid-manual-read is unrepresentable in bsnes regardless of
   codec → quiescent rule (auto-read results carry via joy1-4).
2. **The DSP is the good news** (H4 narrowed): same silicon model
   both sides, near-1:1 field mapping including envelope phase, BRR
   position, echo offset — the design doc's "scariest" domain is a
   mapping table, not a research problem.
3. **The SPC700 is the sharp edge**: Mesen2 models it as a per-CYCLE
   state machine (`spc.opStep/opSubStep/tmp1-3`); bsnes is
   instruction-atomic. Decode rule (in mapping + CMS): refuse
   captures with the SPC mid-instruction (partial replay can
   double-consume read-to-clear $FD-FF). P2 measures how often
   beacon-parked captures hit this (expectation: rarely-to-never at
   a StateProbe idle-loop beacon; Mesen2's own save path runs an SPC
   catch-up first).
4. **In-flight CPU→APU port writes** (`spc.pendingCpuRegUpdate` +
   staged values) are a Mesen2-only 1-cycle pipeline; quiescent rule
   = must be false (StateProbe v0 guarantees), flush-rule validated
   in P2 else refuse.
5. **htime transform**: bsnes stores `(dot+1)<<2` master-clock
   comparator (`sfc/cpu/io.cpp:204-215`); Mesen2 stores the raw dot
   (`InternalRegisters.cpp:352-360`). CMS canonicalizes the raw dot.
   First worked example of a real per-field transform.
6. **Interrupt edge pipelines differ microarchitecturally** (5
   bsnes bools vs 3-4 Mesen2 counters/flags per line) — the one
   mapping that needs a truth table + StateProbe v3 cadence audit
   rather than a copy/pack transform. Sketch committed in the
   mapping; quiescent captures sidestep it (no edge in flight).
7. **DMA $43x0 bit crosswalk pinned by register bit, not name**
   (Mesen2 `invertDirection`=bsnes `direction`, `decrement`=bsnes
   `reverseTransfer`, …) — names lie, bits don't.

## Open Items (P0 remainder → P1 entry)

1. **[BLOCKED] StateProbe fixture import** — `add_repo` for
   `jreinach-alt/SuperForge` could not complete in this
   non-interactive session (permission stream unavailable). Next
   session with the owner present: add the repo, copy
   `stateprobe.sfc` + manifest (+ genconfig) from branch
   `claude/stateprobe-diagnostic-rom-em6jh2` @ `de79be4` into
   `tests/fixtures/transmute/`, capture a beacon `.mss` via
   MesenRunner, and re-run `mss_dump` over it (first REAL-file oracle
   run; assert record keys match the mapping inventory).
2. **[BLOCKED, same cause] MesenCore.so pin check** — compare its
   version exports against the Mesen2 pin; rebuild via SuperForge
   `scripts/build_mesen2.sh` if drifted.
3. bsnes headless runner build (P1 critical path, unchanged).
4. P2 pin list — now enumerated machine-readably in
   `mapping_mesen2_bsnes.json` §open_p2_pins (OAM bit packing, SPC
   timer stage crosswalk, env_mode enums, dsp.step units, externalRegs
   semantics, io.irqEnable composite, interrupt truth table, donor
   Thread.clock, fast-PPU oam live/reload split).
5. Owner: third Tier-2 pass-game (audio/HDMA stresser) — still open.

## Deviations from Spec

- `bst_dump` decodes the fastPPU=true layout only (the accurate-PPU
  layout is inventoried in the mapping but reported as
  out-of-pilot-scope on decode). Justification: fastPPU=true is the
  bsnes DEFAULT, our encoder emits only that layout, and the pilot
  pipeline never produces accurate-layout files. Recorded here as a
  scope decision, owner-visible.
- Synthetic container fixtures added (not in the spec's file table,
  which lists StateProbe fixtures): the SuperForge import is blocked
  and the dumpers need committed test inputs. They complement — not
  replace — the StateProbe fixtures.

## Session handoff — brief for the next session

Session 2 (2026-07-11, this branch) completed: small pins (fastPPU
default, dsp.fast, runToSave, H3, serializer primitives), the full
both-sides field inventory → `cms/cms_snes_v1.json` +
`cms/mapping_mesen2_bsnes.json`, `mss_dump.c` + `bst_dump.c`,
deterministic fixtures + 22-assertion test suite (all green).

**G0 status: technical bar MET** — both formats fully inventoried,
every field classified, mapping committed, dumpers green over
fixtures, no structural blocker found. The identified hazards (SPC
mid-instruction, in-flight port writes, interrupt pipelines,
CPU↔SMP clock phase) all have documented rules/refuse paths, none is
a load-path impossibility. **Owner check-in is the G0 gate** — the
spec mandates it before P1 spend. Also deliver to the owner: the
fixture-import blocker (item 1 above) and the fastPPU-only decode
scope decision.

**Startup:** standard protocol → this file → `sh
tools/transmute/fetch_refs.sh` (~2 min). Gate posture unchanged
(spec §Gate posture). Model regimen: Fable-class (unchanged).

**P1 order once G0 is acknowledged:** (1) unblock SuperForge items
1-2 above; (2) bsnes headless runner (custom minimal target linking
`sfc/` vs libretro build — timeboxed choice; must serialize
byte-compatibly with the user-facing build: same SerializerVersion,
fastPPU=true, same cart profile); (3) controls C1-C3; (4) donor
capture + first `transmute_snes.c` decode pass against the real
beacon `.mss`.

**Session-2 closeout gate: PASSED** — `scripts/gate.sh full`, 62/62
both privilege passes (incl. the new transmute test in both) + both
shipped-artifact integrity checks; qemu checks skipped (no
`qemu-aarch64-static` in the web container; checksums still
verified). First run failed 61/62 on the KNOWN flake below —
reconfirmed passing in isolation (11/11) before the clean rerun,
same protocol as session 1.

**Pre-existing flake (from session 1, still open for a mainline
session):** `tests/integration/test_retrodeck_events_flow.sh` Phase 1
fails intermittently under full-suite load (observed once this
session, first gate run); passes in isolation every time. Untouched
by this spike.
