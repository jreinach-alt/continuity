# Spike T2.0 — Running Summary / Findings Ledger

**Status: P0 (format archaeology) COMPLETE** — session 2 (2026-07-11,
continuation branch `claude/spike-t2-continuation-4ejjew`) delivered
the full field inventory, the CMS mapping tables, both decode
oracles, and their test suite; session 1 (post-closeout addendum,
`6611b6c`) imported the StateProbe fixtures and captured a real
beacon `.mss`; session 2 merged and independently verified every
import claim against bytes. **No structural blocker found: G0's
technical bar is fully met; owner check-in before P1 is due.**

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
  refuse; `-x key` raw-extraction mode; exit 0/1/2/3 =
  clean/malformed/refused/key-missing).
- `tools/transmute/bst_dump.c` — bsnes `.bst` decode oracle
  (container, nall RLE<1>, header gates exactly as `unserialize`,
  full positional plain-cart walk at pinned widths for the
  fastPPU=true layout, zero-residual check as the mechanical chip
  firewall).
- `tools/transmute/gen_fixtures.py` — deterministic synthetic
  container fixtures + sha256 manifest.
- `tests/fixtures/transmute/` — 6 synthetic container fixtures +
  manifest (valid/chip-cart/truncated `.mss`; valid/sync0/
  chip-residual `.bst`).
- `tests/fixtures/transmute/stateprobe/` — REAL fixtures (s1
  addendum, from SuperForge `de79be4`, CC0): `stateprobe.sfc` (32 KiB
  LoROM), `stateprobe_manifest.json`, `genconfig.json`, and
  `beacon_gen2.mss` — a live MesenRunner capture at the beacon, audit
  generation 2.
- `tests/unit/transmute/test_dumpers.sh` — 35 assertions: builds both
  oracles, fixture-manifest integrity, decode + planted-value spot
  checks, dump stability, every refuse/gate path, usage errors, and
  the REAL-file oracle section (below).

## Files Modified

- `.gitignore` — `tools/transmute/{vendor,build}/` (s1).
- `docs/sprints/spike-t2.0-snes-spec.md` — s1: approval + corpus Q3;
  s2: H3 verdict recorded in the hypothesis table.
- `docs/roadmap.md` — spike entry status (s1; s2 refresh).

## Tests Written

`tests/unit/transmute/test_dumpers.sh` — 35/35 green under
`busybox ash`, shellcheck clean, unprivileged-safe (mktemp under
`$TMPDIR` only). Two cross-check designs:
- Synthetic: the fixture generator transcribes the byte layout from
  the mapping JSON, the dumpers transcribe it from the vendored
  serialize sources — the synthetic `.bst` walking to exactly zero
  residual (290,423/290,423 bytes) verifies the two independent
  transcriptions agree on every width.
- Real: `mss_dump` over `beacon_gen2.mss` (an actual Mesen2 2.1.1
  state) asserts header fields, record census, quiescent-rule fields,
  ROM-hash-vs-manifest identity, and the RESULT_SCHEMA v1 block
  (SPRB magic at WRAM `$7EF000`, beacon `$A5` at `$7EF7F0`) via
  extraction mode.

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

**MesenCore.so pin check — CLOSED (s1 addendum, s2-verified):** the
captured state's `emuVersion` field reads `0x00020101` = 2.1.1, and
the pinned tree declares exactly 2.1.1
(`mesen2:Core/Shared/EmuSettings.cpp:135-142@pin`) — SuperForge's
committed core and our vendored reference are the same version.

## Hypothesis ledger (spec §Hypotheses)

| # | Verdict | Evidence |
|---|---|---|
| H1 (Mesen2 keyed) | **CONFIRMED** (s1) | `Serializer.h:255-283` — keyed records, unknown keys tolerated. s2: real 1344-record state parses cleanly with the independent C walker |
| H2 (bsnes: no cothread stacks in normal states) | **CONFIRMED** (s1) | stacks only in `synchronize=false` rewind variant; `bst_dump` refuses those |
| H3 (frame-edge captures) | **CONFIRMED w/ caveat** (s2) | see spec table; SPC700 sub-instruction state is the residual hazard, handled as a refuse-class — and the first real beacon capture lands `spc.opStep=0` (instruction boundary), supporting the expectation that beacon captures rarely-to-never trip it |
| H4 (CPU↔APU phase + DSP state are the top hazard) | OPEN → **NARROWED** (s2) | inventory shows both DSPs are the same blargg-lineage silicon model — `dsp_internal` maps nearly field-for-field (names align: NoiseLfsr↔noise, Counter↔counter, BrrNextAddress↔t_brr_next_addr, …). The remaining H4 core is CPU↔SMP relative phase (Thread.clock donor alignment) + SPC mid-instruction captures. P2 empirics (StateProbe v2/v3) quantify |
| H5 (bsnes loader: format checks only) | **CONFIRMED** (s1) | 4 gates, no semantics; `bst_dump` mirrors them |
| H6 (power-on donor viable) | STRENGTHENED (s1), unchanged | loader power-cycles before positional read |
| H7 (ROM identity) | **REVISED** (s1) | neither format validates ROM identity; manifest sha256 is OUR discipline — now enforced in CI (test asserts committed ROM hash appears in the manifest) |
| H8 (InteropDLL state exports) | **CONFIRMED** (s1) | StateProbe gate 3; s1-addendum used exactly those exports for the beacon capture |

## Container formats

Pinned in session 1; machine-readable in
`cms/mapping_mesen2_bsnes.json` §containers and executable in the two
dumpers. s2 refinement: the `.mss` payload's `[u8 isCompressed]` may
legally be 0 (records to EOF, no size words) — `mss_dump` handles
both. **Survived contact with real bytes** (s1-addendum capture,
s2-verified): MSS magic, emuVersion, formatVersion=4, consoleType=0,
256×239 screenshot block, zlib framing, and the keyed record stream
all decode at exactly the pinned offsets.

## Real-capture verification record (s2, 2026-07-11)

Independent verification of the s1-addendum import (project rule:
byte-level claims get tested, not trusted):

1. `sha256(stateprobe.sfc)` = `b324d2fc…dca902dc` = the manifest's
   `rom.sha256` ✓
2. `mss_dump beacon_gen2.mss` → exit 0, 1344 records, no coprocessor
   keys; header: emuVersion 131329 (=2.1.1), format 4, console 0,
   video 256×239, rom name `stateprobe.sfc` ✓
3. Record census matches the mapping inventory exactly per domain:
   cpu=18, memoryManager=10, controlManager=8, dmaController=143
   (7 + 8×17), internalRegisters=34, spc=184, ppu=946, cart=1 ✓
4. RESULT_SCHEMA v1 in extracted WRAM at `$7EF000`: magic `SPRB`,
   schema 1, profile 0, build_id 54233 (= manifest), epoch 548,
   audit generation 2, `PASS=RAN=0x00003F8F` (bits 4/5/6 clear = the
   documented v0 blind spots), first-fail `$FF`, beacon `$A5` ✓
5. SRAM mirror = WRAM block except `epoch` (545 vs 548) and the
   checksum covering it — exactly the brief's "mirrored after every
   completed audit pass" semantics (the WRAM epoch keeps ticking
   between mirror and capture). Tests must never compare the two
   blocks byte-for-byte; compare excluding epoch+checksum.
6. Quiescent-rule empirics on a real capture: `spc.opStep=0`,
   `spc.pendingCpuRegUpdate=0`, `cpu.k/pc` parked in ROM code ✓ —
   first evidence the decode rules' happy path is the common case.

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
   double-consume read-to-clear $FD-FF). First real data point:
   beacon capture landed at opStep=0.
4. **In-flight CPU→APU port writes** (`spc.pendingCpuRegUpdate` +
   staged values) are a Mesen2-only 1-cycle pipeline; quiescent rule
   = must be false (StateProbe v0 guarantees; confirmed false in the
   real capture), flush-rule validated in P2 else refuse.
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

## Open Items (P0 → P1 entry)

1. ~~StateProbe fixture import~~ **CLOSED** (s1 addendum `6611b6c`,
   s2 merge + independent verification above).
2. ~~MesenCore.so pin check~~ **CLOSED** — see Pins section.
3. bsnes headless runner build (P1 critical path, unchanged).
4. P2 pin list — enumerated machine-readably in
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
- Synthetic container fixtures added alongside the StateProbe ones
  (not in the spec's file table): they exercise malformed/refuse
  paths a valid capture never can. Complementary, both stay.

## Session handoff — brief for the next session (P1)

**P0 is COMPLETE and G0's technical bar is fully met:** both formats
inventoried and classified, mapping committed, dumpers green over
synthetic AND real fixtures, MesenCore pin aligned, no structural
blocker. The identified hazards (SPC mid-instruction, in-flight port
writes, interrupt pipelines, CPU↔SMP clock phase) all have documented
rules/refuse paths; none is a load-path impossibility. **Owner
check-in is the G0 gate — required before P1 spend.**

**Session-creation requirement (platform):** create the P1 session
with BOTH `jreinach-alt/continuity` AND `jreinach-alt/SuperForge`
selected as sources at creation. Mid-session repo adds are broken on
this platform surface (the session's claude-code-remote MCP endpoint
rejects approved calls; the desktop app's add-repo control only sends
a chat message that depends on the same broken call — verified
end-to-end 2026-07-11, bug reported by owner). P0 needed no
SuperForge access thanks to the in-repo fixtures; P1's MesenRunner
integration does.

**Startup:** standard protocol → this file → `sh
tools/transmute/fetch_refs.sh` (~2 min). Gate posture unchanged
(spec §Gate posture). Model regimen: Fable-class (unchanged).

**P1 order once G0 is acknowledged:** (1) bsnes headless runner
(custom minimal target linking `sfc/` vs libretro build — timeboxed
choice; must serialize byte-compatibly with the user-facing build:
same SerializerVersion "115.1", fastPPU=true, same cart profile);
(2) MesenRunner harness integration (SuperForge in scope; H8 exports
already proven by the s1-addendum capture); (3) controls C1–C3
(C2 partially banked: the beacon capture + StateProbe's own gate 3);
(4) donor capture + first `transmute_snes.c` decode pass against
`beacon_gen2.mss`.

**Session-2 closeout gates: PASSED twice** — `scripts/gate.sh full`
62/62 both privilege passes + both shipped-artifact integrity checks,
run before the first push AND rerun after the fixture merge with the
real-file test additions (both green; qemu checks skipped: no
`qemu-aarch64-static` in the web container; checksums still
verified). One earlier s2 gate run failed 61/62 on the KNOWN flake
below — reconfirmed passing in isolation (11/11), same protocol as
session 1.

**Pre-existing flake (from session 1, still open for a mainline
session):** `tests/integration/test_retrodeck_events_flow.sh` Phase 1
fails intermittently under full-suite load (observed once in s2,
first gate run); passes in isolation every time. Untouched by this
spike.
