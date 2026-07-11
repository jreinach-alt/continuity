# Spike T2.0 — Running Summary / Findings Ledger

**Status: P0 (format archaeology) IN PROGRESS** — started 2026-07-11
immediately on spec approval. This file is the running handoff record;
the pre-registered verdict semantics live in the spec.

## Files Created

- `tools/transmute/fetch_refs.sh` — pinned fetch of both reference
  trees (idempotent, refuses wrong-pin trees, never deletes).
- `tools/transmute/README.md` — workbench charter + pin table.
- this file.

## Files Modified

- `.gitignore` — `tools/transmute/{vendor,build}/`.
- `docs/sprints/spike-t2.0-snes-spec.md` — approval recorded; corpus
  Q3 partially resolved (SMW + FF3us confirmed; Star Fox re-slotted as
  the chip-refusal NEGATIVE control — SuperFX is out of transmutation
  scope by the firewall; third pass-game still open).

## Tests Written

None yet — the P0 exit tests ride with `mss_dump`/`bst_dump` (oracle
tests over StateProbe fixtures), per the spec's file table.

## Pins

| Tree | Commit |
|---|---|
| Mesen2 | `b9fa69ddc6d0a331fb103fdb5eef6904305703c2` (archived upstream's final commit, 2026-06-04) |
| bsnes | `7d5aa1e656b9171524d01b1b22917197d8121cb4` (bsnes-emu master; `SerializerVersion "115.1"`) |

All citations below are `path:line@pin` in `tools/transmute/vendor/`.

## Hypothesis ledger (spec §Hypotheses)

| # | Verdict | Evidence |
|---|---|---|
| H1 (Mesen2 keyed) | **CONFIRMED** | `SV(var)` stringifies field names, keys are prefix-scoped (`mesen2/Utilities/Serializer.h:11,95-102`); binary record = `[key][0x00][u32 LE size][LE value]` (`Serializer.h:255-266`); load is lookup-by-key, **missing/unknown keys are silently tolerated** (`Serializer.h:271-283`) — decode is maximally robust |
| H2 (bsnes: no cothread stacks in normal states) | **CONFIRMED** | `synchronize` mode is a stored field; `=true` runs `runToSave()` (threads parked; `sfc/system/system.cpp:17`) and load `power(reset=false)`s before the positional read (`sfc/system/serialization.cpp:6,45`); raw stacks serialize ONLY in the `synchronize=false` rewind variant (`serialization.cpp:90-97`), which we never emit; UI saves default `synchronize=true` (`sfc/interface/interface.hpp:61`) |
| H3 (frame-edge captures) | OPEN | fleet/libretro side is frame-edge by API; Mesen2 standalone `SaveState` runs under `AcquireLock` (`SaveStateManager.cpp:91`) — the exact suspension point needs pinning in P1 (StateProbe's beacon+epoch makes capture-point verification empirical anyway) |
| H4 (CPU↔APU phase is the top hazard) | OPEN | experimental question — P2/P3 |
| H5 (bsnes loader: format checks only) | **CONFIRMED** | `unserialize` checks exactly: signature `0x31545342`, exact `serializeSize` (per-cartridge dry-run `serializeInit`, `serialization.cpp:103-119`), `version[16] == "115.1"` (`emulator/emulator.hpp:38`), `fastPPU` flag match — then loads positionally, **no checksum, no ROM hash, no semantic validation** (`serialization.cpp:25-48`). G2 (acceptance) is purely mechanical |
| H6 (power-on donor viable) | STRENGTHENED, pending P2 empirics | loader power-cycles before applying `synchronize=true` states — donor-internal consistency burden is minimal by construction (`serialization.cpp:45`) |
| H7 (states carry ROM identity that must match) | **REVISED** | Mesen2: ROM name stored but **never validated**; no hash in format ≥ v4 (40-byte SHA1 existed only ≤ v3: `SaveStateManager.cpp:180-183,196-200`); gates are emuVersion ≤ running, formatVersion ≥ 3 (= 4 current: `SaveStateManager.h:23-24`), consoleType. bsnes: no ROM identity either — only the four H5 checks. Identity discipline is OURS to enforce (manifest sha256), not the emulators' |
| H8 (InteropDLL state exports) | **CONFIRMED** (2026-07-11, StateProbe delivery) | `MesenRunner.save_state_file`/`load_state_file` upstream in SuperForge; exercised by StateProbe gate 3 |

## Container formats (pinned, both directions)

**Mesen2 `.mss`** (`SaveStateManager.cpp:61-83,155-223`):
`"MSS"` + u32 emuVersion + u32 formatVersion(4) + u32 consoleType +
screenshot block (4×u32 + zlib framebuffer, 2 MB cap) + u32 nameLen +
romName, then the payload from `Emulator::Serialize`
(`Emulator.cpp:913`): `[u8 isCompressed][u32 rawSize][u32 compSize]
[zlib]` (10 MB caps on load: `Serializer.cpp:64-91`), containing the
keyed record stream (H1).

**bsnes `System::serialize` stream** (`serialization.cpp:1-23`):
u32 `0x31545342` + u32 exactSize + char[16] version + char[512]
description + bool synchronize + bool fastPPU, then `serializeAll` —
positional nall stream (LE integers, raw byte arrays, no tags:
`nall/serializer.hpp:85-125`), block order `random, cartridge, cpu,
smp, ppu, dsp, [coprocessors iff cartridge.has.*], controllerPort1/2,
expansionPort` (`serialization.cpp:52-98`). The chip firewall is
mechanical: plain carts have no chip blocks; `cartridge.has.*` from a
GSU cart (Star Fox) triggers the REFUSE path in our decoder.

**bsnes `.bst` file** (`target-bsnes/program/states.cpp:1,75-100`):
u32 `0x5A220000` + u32 rleStateSize + u32 rlePreviewSize +
`Encode::RLE<1>(serializer stream)` + `RLE<2>(256×240 preview)`.

## Open Items (P0 remainder)

1. Per-chip field inventory: walk every `Serialize(s)`/`serialize(s)`
   for SNES-relevant chips in both trees → CMS-SNES v1 mapping table
   (`cms/`). The bulk of remaining P0.
2. `mss_dump` + `bst_dump` decode oracles + unit tests over StateProbe
   fixtures (import ROM+manifest from SuperForge `de79be4`).
3. Verify SuperForge's committed `MesenCore.so` was built at (or
   format-compatibly near) the Mesen2 pin — else rebuild at pin via
   their `build_mesen2.sh`.
4. Pin bsnes `hacks.fastPPU` default for the target build (affects
   which PPU serialization layout the encoder mirrors) and the
   `runToSave` Fast/Strict setting semantics (`system.cpp:37-38`).
5. H3: pin Mesen2's state-capture suspension point.
6. bsnes headless runner build (P1 critical path).
7. Owner: third Tier-2 pass-game (plain-cart audio/HDMA stresser).

## Deviations from Spec

None. (Star Fox corpus re-slotting is recorded as a Q3 resolution in
the spec itself, owner-visible.)

## Session handoff — brief for the next session (P0 completion)

Session 1 (2026-07-11) covered: spec authored + approved; StateProbe
brief authored; StateProbe v0 delivered by SuperForge and
review-verified here (17/17 gates, independent rerun); reference pins;
container-format archaeology (ledger above).

**Session closeout gate: PASSED** — `scripts/gate.sh full`, 61/61 both
privilege passes + both shipped-artifact integrity checks (qemu checks
skipped: no `qemu-aarch64-static` in the web container; checksums
still verified). First run failed 60/61 on a PRE-EXISTING flake,
handed off below.

**Defect handed off (pre-existing, NOT spike fallout):**
`tests/integration/test_retrodeck_events_flow.sh` Phase 1
("event-driven sync reached the remote", expected 0 actual 1) fails
intermittently under full-suite load — observed twice this session in
gate runs, passes in isolation every time (3× reconfirmed, 11/11).
Scope: Sprint 2.2 RetroDeck event daemon test, untouched by this
spike (docs + `tools/transmute/` only). Likely a timing assumption in
the event-wake phase under CPU contention; owner/next mainline session
should harden the test's wait window.

**Startup:** standard protocol (CLAUDE.md Steps 1–6 → this file), then
`sh tools/transmute/fetch_refs.sh` (re-fetches vendor trees in a fresh
container, ~2 min). Gate posture: owner disabled the pre-push hook for
spike sessions (spec §Gate posture) — re-disable with
`git config --local --unset core.hooksPath` after Startup Step 2
re-enables it, or leave it on (spike pushes are docs + isolated tools;
the fast gate passes). Model regimen: this spike is Fable-class
(CLAUDE.md §Model Regimen — emulation/binary internals); the CMS
field-classification judgments are exactly where that matters.

**Task order (P0 remainder — Open Items above, expanded):**

1. **Field inventory → `cms/` mapping tables.** Walk every state
   field on both sides and classify architectural / emulator-internal
   / ambiguous-with-rule (spec §Decomposition target). Where to read:
   - Mesen2 (keyed — record key names): `Core/SNES/*.cpp` `Serialize`
     methods — `SnesConsole`, `SnesCpu`, `SnesPpu`, `Spc`, `NecDsp`n/a,
     `SnesDmaController`, `InternalRegisters`, `AluMulDiv`,
     `SnesControlManager` + `Input/`, `BaseCartridge`, `Core/SNES/DSP`
     (audio DSP), memory manager. Grep `void .*::Serialize` under
     `Core/SNES/`.
   - bsnes (positional — record exact code order):
     `sfc/{cpu,smp,dsp,cartridge,controller,expansion,memory}/serialization.cpp`,
     `sfc/ppu/serialization.cpp` AND `sfc/ppu-fast/serialization.cpp`
     (fastPPU flag selects the layout — pin the default first, Open
     Item 4), plus `random` (first block) from `sfc/system/`.
   - Output: `cms/cms_snes_v1.json` + `cms/mapping_mesen2_bsnes.json`
     (spec file table). Every CMS field: mesen2 key ↔ bsnes stream
     position/width ↔ transform ↔ classification ↔ fullsnes citation
     for semantics (SuperForge `docs/reference/fullsnes.txt`).
2. **`mss_dump` + `bst_dump`** (C, zlib for mss; RLE<1> codec for bst
   — trivial, pin from `nall/encode/rle.hpp`) + unit tests under
   `tests/unit/transmute/` against StateProbe fixtures.
3. **Import StateProbe fixtures** from SuperForge branch
   `claude/stateprobe-diagnostic-rom-em6jh2` @ `de79be4`
   (`stateprobe.sfc`, manifest, genconfig; capture a beacon `.mss`
   via MesenRunner) into `tests/fixtures/transmute/`. SuperForge-side
   merge of that branch is the owner's call and does not block (pin
   the commit).
4. **MesenCore.so pin check** (Open Item 3) — compare its version
   exports against the pin; rebuild via SuperForge
   `scripts/build_mesen2.sh` if drifted.
5. Small pins: bsnes `hacks.fastPPU` default + `runToSave`
   Fast/Strict; Mesen2 capture suspension point (H3).

**P0 exit = G0:** both formats fully inventoried, mapping table
committed, dumpers green over fixtures, no structural blocker found —
then owner check-in before P1 (bsnes headless runner is the P1
critical path).

**Owner loose ends:** third Tier-2 pass-game pick; SuperForge
StateProbe branch merge (at leisure).
