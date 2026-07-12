# Spike T2.0 — Running Summary / Findings Ledger

**Status: P1 COMPLETE (gate G1 met, full-behavioural C4 landed); P2
ENTERED — gate G2 MET, G3 partial with a named root cause.** Session 4
(2026-07-12, branch `claude/spike-t2-continuation-oqroko`) bound the
CPU/PPU register-injection API, extended the decode to every architectural
memory domain, upgraded C4 to the full behavioural transplant-vs-native
test, and built the P2 donor-encoder reaching G2. Details in "## Session 4
— P1 finish (full C4) + P2 entry (G2/G3)" below.

**Status: P1 (harness) SUBSTANTIALLY COMPLETE — gate G1 met.** Session 3
(2026-07-12, branch `claude/spike-t2-continuation-u35uat`) built the
bsnes headless runner (the P1 build risk — resolved), the Mesen2 state
bindings, and all four validity controls C1–C4 green. Details in
"## Session 3 — P1 (harness + controls C1–C4)" below.

**Status: P0 (format archaeology) COMPLETE** — session 2 (2026-07-11,
continuation branch `claude/spike-t2-continuation-4ejjew`) delivered
the full field inventory, the CMS mapping tables, both decode
oracles, and their test suite; session 1 (post-closeout addendum,
`6611b6c`) imported the StateProbe fixtures and captured a real
beacon `.mss`; session 2 merged and independently verified every
import claim against bytes. **No structural blocker found: G0's
technical bar is fully met; owner check-in before P1 is due.**

---

## Session 4 — P1 finish (full behavioural C4) + P2 entry (G2/G3)

**Branch:** `claude/spike-t2-continuation-oqroko` (continuity only; no
SuperForge tree change — `mesen_state.py` still subclasses SuperForge's
`MesenRunner` without touching it, per open-question-4). Env: `fetch_refs.sh`
+ `build_bsnes_host.sh` (both pins built clean), `libsdl2` + `shellcheck` +
`busybox-static`. Gate posture: spike-disabled (unchanged).

### P1 FINISH — full behavioural C4 (Question A answered: YES for v0 domains)

The P1 ledger's "next session" item 1 is done. C4 is no longer WRAM-only; it
is the full architectural transplant-vs-native-load test.

**Register-injection API bound** (summary finding 6 closed). `mesen_state.py`
now binds `Get/SetCpuState` + `Get/SetPpuState` over the committed
MesenCore.so exports (verified present via `nm -D`). `SnesCpuState` is a
ctypes struct transcribed field-for-field from the pinned header
(`SnesCpuTypes.h:12` over empty `BaseState` — no vtable, begins at
`CycleCount`@0); `Debugger::SetCpuState` for `CpuType::Snes` is a whole-struct
`memcpy` (`Debugger.cpp:858`), so injecting the struct sets every CPU field at
once. PPU is bound as an opaque `_PPU_STATE_BUF_SIZE` buffer (Get→Set round-
trips the whole register file without needing `sizeof(SnesPpuState)`).

**Decode extended to every architectural memory domain** (`cms_decode.py`).
Ground-truth record keys (from `mss_dump` on the real beacon, not guessed):
`memoryManager.workRam`, `ppu.vram`, `ppu.oamRam`, `ppu.cgram`,
`cart.saveRam`, `spc.ram`; CPU from the 17 `cpu.*` scalar records → the
struct (`cpu.waiOver` is serialized but is NOT a `SnesCpuState` member, so it
is out of reach of `SetCpuState` — a recorded gap, immaterial at frame-edge).

**C4 (now, all gating checks green):**
- **C4a decode completeness (vs Mesen ground truth):** all six memory domains
  are byte-identical to the live core's region at capture; the CPU record
  transcodes field-exact to `GetCpuState` (CycleCount excepted — free-running
  emulator-internal). Reads live BEFORE save (ordering matters — a
  read-after-save shows a benign 1-frame skew, not a decode error).
- **C4b architectural sufficiency:** transplanting {file-decoded memory +
  file-decoded CPU + the PPU register file via `SetPpuState`} into a
  DIFFERENT parked core makes its StateProbe continuation match a native
  `LoadStateFile` — same full pass bitmap `0x3F8F`, same beacon, both
  progressed. Timing PHASE differs (epoch off by ~2 ticks) — expected and
  explicitly not the bar.

**Findings worth carrying (C4):**
1. **The PPU register file is architecturally LOAD-BEARING, empirically.**
   A memory+CPU-only transplant (PPU left un-injected) fails exactly one
   StateProbe domain — bit 9 (`0x3F8F & ~0x3D8F = 0x200`). Injecting the PPU
   closes it. This is field-level attribution: `SetPpuState` is not cosmetic.
2. **That partial-transplant result is NONDETERMINISTIC by construction** —
   the target boots the same ROM under RANDOM power-on (Mesen
   `RamState::Random`, re-seeded per boot), so its own PPU is sometimes close
   enough that every domain passes anyway. Recorded as evidence, never gated;
   the deterministic story is "full injection → deterministic pass; leaving
   PPU to the boot RNG → domain 9 left to chance."
3. **The capture CPU parks in WAI** (`cpu.stopState = 2 = WaitingForIrq`,
   `pc = 0x8135`) — the decode recovers it exactly; `SetCpuState` restores the
   WAI so the injected core resumes waiting for the same NMI.

### P2 ENTRY — donor-encode gates (G2 MET, G3 partial + root cause)

Reached the P1-ledger "next session" item 2's first gate. `encode_bsnes.py`
boots a **power-on bsnes donor** (`bsnes_host save --frames 0`, `fastppu=1`),
overwrites its architectural fields from the CMS decode of the committed
quiescent `beacon_gen2.mss`, and re-wraps. `bst_dump` gained an additive
`-O` **offset-map mode** (`offset\tlength\tname` for every field; default
output unchanged — C1/C3 + the zero-residual walk still green) so the encoder
locates each domain in the payload without re-deriving the serialize walk.

**G2 — MET.** The rebuilt cross-emulator state LOADS in bsnes (`check` →
`RC_OK`), and a byte-mangled rebuilt is rejected (`RC_REJECTED`) — the gate is
not a rubber stamp. Overwritten this pass: the raw byte-array domains
(WRAM/VRAM/CGRAM/SRAM/ARAM) + the 65C816 register file (pinned transform:
`wdc.pc=(pbr<<16)|pc`, PS-byte flag unpack, `stopState→wai/stp`).

**G3 — NOT yet demonstrated (partial, with a named root cause).** The
memory+CPU-only transfer does **not** produce a continuable execution: run
forward in bsnes, StateProbe's beacon epoch stays FROZEN at the injected
value (548) across 100/900/2500 frames. **Tautology guard (critical):** the
RESULT block lives in WRAM, which the encoder overwrites — so a "passing"
bitmap read straight back proves nothing. G3 requires the epoch to ADVANCE
(live re-audit). Verified two-sided: a native Mesen load of the same beacon
advances the epoch 552→1453 over 900 frames; native bsnes StateProbe advances
112→512→1112 and reaches `0x3F8F` on its own — so the frozen transplant is a
genuine negative, not a StateProbe halt.
**Root cause (field-level):** the deferred register-file domains — PPU
register file, SMP/SPC700 regs, DSP blob, structured OAM, and CPU I/O timing
(`nmiEnable`, PPU counters) — are at the donor's power-on values, inconsistent
with the transferred CPU/memory; the WAI never resumes into a healthy audit.
This is exactly C4's "PPU is load-bearing" finding, extended: the APU/timing
register files are load-bearing too. Those transforms (the mapping JSON pins
them) are the transmute_snes.c body and the direct G3 path.

### Files created (session 4)

- `tools/transmute/harness/cms_decode.py` — CMS decode from a `.mss`:
  all-domain memory extraction + CPU-record → `SnesCpuState` transcode
  (`mss_dump -x` primitive).
- `tools/transmute/harness/encode_bsnes.py` — donor-template bsnes `.bst`
  encoder: overwrite architectural domains over a power-on donor, re-wrap.
- `tools/transmute/harness/gates_p2.py` — G2/G3 driver (donor → encode →
  load → advance-gated audit readback), tautology-guarded.
- `tests/unit/transmute/test_gates_p2.sh` — G2/G3 gate (skip-safe).

### Files modified (session 4)

- `tools/transmute/harness/mesen_state.py` — `SnesCpuState` struct +
  `Get/SetCpuState`, `Get/SetPpuState`, `write_region` bindings.
- `tools/transmute/harness/controls.py` — C4 rewritten to full behavioural
  (all-domain decode-completeness + transplant-vs-native continuation +
  non-gating PPU-load-bearing diagnostic).
- `tools/transmute/bst_dump.c` — additive `-O` offset-map mode.
- `tests/unit/transmute/test_controls_mesen.sh` — C4 comment refreshed.

### Next session (G3)

1. **Implement the register-file transforms** (the mapping JSON pins each):
   PPU register file, SMP/SPC700 regs, DSP blob (blargg `copy_state` order),
   and the structured OAM table→object transform — overwrite these in the
   donor alongside memory+CPU, then G3's epoch must advance and reach
   `0x3F8F` on a live bsnes re-audit. Start with PPU + CPU-I/O timing
   (`nmiEnable`, htime/vtime, PPU counters) — C4 proved PPU is the first
   load-bearing gap; the WAI-resume needs the NMI timing consistent.
2. **Formalize the decode/encode in `tools/transmute/transmute_snes.c`**
   (spec file table) — the Python encoder is the P1-style oracle-driven
   stand-in; the C tool is the shipping pipeline.
3. **Then Tier-2 confirmation games** (owner-local) once G3 lands.

---

## Session 3 — P1 (harness + controls C1–C4)

**Branch:** `claude/spike-t2-continuation-u35uat` (continuity + SuperForge).
G0 acknowledged by the owner's instruction to proceed to P1.

**Gate G1 verdict: MET.** Same-core round-trips pass both sides, the
live-injection control passes on the WRAM domain, and the corrupted-state
control fails loudly. All four controls are committed, runnable, and
skip-safe (they SKIP, never FAIL, where the emulator deps are absent — so
the mainline gate stays green).

### Controls — all green

| Ctrl | What | Result |
|---|---|---|
| **C1** | bsnes native `.bst` → fresh bsnes, advance K → reconstructs a native run to N+K **byte-for-byte except the internal PRNG seed** (`random.state`) | PASS — load accepted, emulation live, reload deterministic |
| **C2** | Mesen2 native `.mss` → Mesen2: save at gen-2 audit (PASS=0x3F8F), advance (epoch ticks), reload → **beacon epoch rewinds**, audit still passes | PASS |
| **C3** | corrupted/truncated `.bst` → bsnes: container-sig / container-size / serializer-sig / version / serializeSize / empty / truncated all **rejected**; valid accepted | PASS (both directions) |
| **C4** | CMS decode → live re-inject (WRAM domain, first pass) | PASS — see below |

### The bsnes headless runner (P1 build risk — RESOLVED)

- **Chosen path: the vendored libretro core** (the headless boundary bsnes
  already ships). `retro_serialize` returns the raw `System::serialize()`
  payload; our `bsnes_host.cpp` wraps it in the exact desktop `.bst`
  container (12-byte header + nall RLE<1>, transcribed from
  `target-bsnes/program/states.cpp` + `nall/encode/rle.hpp` @ pin).
- **Byte-compatibility proven two ways:** the P0 `bst_dump` oracle walks
  our `.bst` to **zero residual**, and the real bsnes core loads it.
- **fastPPU=true confirmed** (`bsnes_ppu_fast=ON`, and `header.fastppu=1`
  in every state); `SerializerVersion "115.1"` matches.
- **Build:** `make target=libretro platform=linux local=false` (~2–4 min,
  built clean at pin `7d5aa1e`). Wrapped by
  `tools/transmute/harness/build_bsnes_host.sh`.

### Findings worth carrying (P1)

1. **P0 bst_dump oracle validated against a REAL bsnes state.** bst_dump
   was written in P0 from vendored serializer source against *synthetic*
   fixtures (bsnes couldn't be built then). It now walks a real
   bsnes-produced state to exactly zero residual — the entire P0 bsnes
   field inventory is confirmed against reality. **Usage note:** StateProbe
   carries 8 KiB battery SRAM, so real StateProbe states need
   `bst_dump -s 8192` (else 8192 residual bytes → refuse; not a bug).
2. **C1 validates the decompose/resynthesize thesis on the target side.**
   A bsnes state reloaded into a fresh core and advanced K frames matches a
   native run to N+K on **every byte except `random.state`** (payload
   [542,550)), bsnes's per-boot PRNG seed — exactly the CMS
   "emulator-internal, never translated" class. That is the physics the
   spike is testing, seen working.
3. **bsnes power-on entropy is a single 8-byte field.** With
   `bsnes_entropy=None` (deterministic; format-identical — the `random`
   block is internal either way, size/layout unchanged, unserialize never
   checks its values), two fresh boots differ ONLY in `random.state`. The
   load path itself is fully deterministic.
4. **Decode-vs-ground-truth (C4a):** the WRAM `mss_dump -x
   memoryManager.workRam` pulls from a `.mss` is **byte-identical**
   (crc-verified) to the live MesenCore's WRAM at capture. The decode
   recovers exactly what Mesen serialized — validated against Mesen itself.
5. **Live memory injection works (C4b):** `MesenRunner.write_bytes`
   (`SetMemoryValues`) transplants the decoded 128 KiB WRAM into a
   different parked core; it reads back as the captured self-audit.
6. **Register injection is the next primitive.** `SetCpuState` /
   `SetPpuState` / `SetMemoryState` are exported by the committed
   MesenCore.so but NOT yet bound in MesenRunner. Full behavioural-
   continuation C4 (run the injected core, require it to match a native
   load) needs them + decode of VRAM/CGRAM/OAM/SRAM. That is the P2 entry.
7. **H8 bindings kept spike-local (open question 4).** Rather than merge
   the SuperForge StateProbe branch, `harness/mesen_state.py` subclasses
   whatever `MesenRunner` is on the SuperForge checkout and adds
   `save_state_file`/`load_state_file` — faithful to the verified `de79be4`
   implementation. No SuperForge tree change; P1 has no branch dependency.

### Files created (session 3)

- `tools/transmute/harness/mesen_state.py` — spike-local `MesenRunner`
  subclass (`.mss` save/load), SuperForge locator, `HarnessUnavailable`.
- `tools/transmute/harness/stateprobe.py` — manifest-driven RESULT_SCHEMA
  v1 reader + audit predicate.
- `tools/transmute/harness/bsnes_host.cpp` — headless libretro driver +
  byte-compatible `.bst` container.
- `tools/transmute/harness/build_bsnes_host.sh` — core + host build.
- `tools/transmute/harness/bst.py` — Python `.bst`/RLE codec (byte-verified
  against the host) + internal-field mask.
- `tools/transmute/harness/bsnes_runner.py` — Python wrapper over the host.
- `tools/transmute/harness/controls.py` — controls C1–C4 CLI.
- `tools/transmute/harness/README.md` — harness charter.
- `tests/unit/transmute/test_controls_mesen.sh` — C2 + C4 gate (skip-safe).
- `tests/unit/transmute/test_controls_bsnes.sh` — C1 + C3 + real-state
  bst_dump walk (skip-safe).

### Toolchain deps installed this session

`libsdl2-2.0-0` (MesenCore.so runtime), `shellcheck` (gate). No
`qemu-aarch64-static` in the web container (gate's qemu checks skip; spike
is exempt anyway — no committed binaries).

### Next session (P1 finish → P2 entry)

1. **Bind `SetCpuState`/`SetPpuState` in the harness** and extend the
   decode to VRAM/CGRAM/OAM/SRAM/APU → **full behavioural C4** (run the
   injected core, require continuation identical to a native load). This
   also answers spike Question A (is the decomposition complete?) directly.
2. **P2 donor encode (G2/G3):** power-on bsnes donor `.bst`, overwrite
   architectural fields from CMS, emit; first rebuilt state must LOAD
   (G2), then StateProbe v0 all-domain pass on quiescent transfer (G3).
   Formalize the decode in `tools/transmute/transmute_snes.c` (the P1 pass
   currently uses `mss_dump -x` as the decode primitive).
3. **Tier-2 confirmation games** (owner-local): SMW, FF3/FF6, +1 stresser,
   Star Fox as the chip-firewall negative control.

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
