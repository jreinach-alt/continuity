# tools/transmute/harness — Spike T2.0 P1 harness

Capture/verify drivers for the cross-core state spike (spec §Harness,
phase P1). Desktop-tier x86_64 Python + a compiled bsnes runner — **not**
BusyBox-constrained, never shipped to a device, `src/**` untouched.

## What's here

| File | What | Status |
|---|---|---|
| `mesen_state.py` | Spike-local `MesenRunner` subclass adding `.mss` save/load over the InteropDLL `SaveStateFile`/`LoadStateFile` exports; SuperForge locator; `HarnessUnavailable` skip signal | P1 ✓ |
| `stateprobe.py` | StateProbe RESULT_SCHEMA v1 reader + audit predicate, driven entirely by the committed fixture manifest (no hardcoded offsets) | P1 ✓ |
| `bsnes_host.cpp` | Headless libretro driver: boots a ROM, save/loads byte-compatible `.bst` (12-byte header + nall RLE<1> payload, reproduced from the desktop path) | P1 ✓ |
| `build_bsnes_host.sh` | Builds the pinned bsnes libretro core + compiles `bsnes_host` into `build/` (gitignored) | P1 ✓ |
| `bst.py` | Python `.bst` container + RLE<1> codec (mirror of the host, byte-verified against it); payload layout incl. the `random.state` internal-field mask | P1 ✓ |
| `bsnes_runner.py` | Python wrapper over the compiled bsnes host (save / reload / check) | P1 ✓ |
| `controls.py` | Validity controls C1–C4 CLI. C1/C2/C3 full; C4 first pass (WRAM decode + injection) | C1/C2/C3/C4 ✓ |

## The bsnes headless runner (P1 build risk — resolved)

The spike drives bsnes through the **libretro core** (the headless
boundary bsnes already ships): `retro_serialize` returns the raw
`System::serialize()` payload, and the runner wraps it in the exact
desktop `.bst` container (`target-bsnes/program/states.cpp`) using a
faithful transcription of nall's RLE<1>. Result: states written here are
byte-identical to what bsnes itself writes — verified two ways, by the P0
`bst_dump` oracle decoding them to zero residual and by the real bsnes
core loading them. `bsnes_ppu_fast=ON` and `bsnes_entropy=None` are forced
(fastPPU matches the user-facing build; entropy=None makes states
deterministic without changing the format — the `random` block is an
internal field either way).

Build once: `sh tools/transmute/harness/build_bsnes_host.sh` (~2-4 min for
the core). Needs the vendored bsnes tree (`fetch_refs.sh`) + g++ (C++17).

## The Mesen2 state bindings (spike-local, open question 4)

The spike does **not** modify SuperForge's shipped `mesen_runner.py`. It
subclasses whatever `MesenRunner` is on the SuperForge checkout and layers
`save_state_file`/`load_state_file` on top. The binding logic mirrors the
verified upstream implementation on SuperForge branch
`claude/stateprobe-diagnostic-rom-em6jh2` (`de79be4`) — the same code that
captured `beacon_gen2.mss`. Keeping it spike-local means P1 has no hard
dependency on that branch being merged.

Requires SuperForge in scope (auto-located; override with
`SUPERFORGE_ROOT`) and its `MesenCore.so` + SDL2/ALSA runtime deps.

## Running the controls

```sh
python3 tools/transmute/harness/controls.py c2 --json    # full evidence
python3 tools/transmute/harness/controls.py c2            # checklist
```

```sh
python3 tools/transmute/harness/controls.py c1   # bsnes native round-trip
python3 tools/transmute/harness/controls.py c3   # corrupted-state rejection
python3 tools/transmute/harness/controls.py c4   # decode + live re-inject
```

Exit codes: `0` pass · `1` fail · `77` skip (emulator dependency absent).

The committed gate wrapper `tests/unit/transmute/test_controls_mesen.sh`
turns exit 77 into a clean skip so the mainline gate (which has no
MesenCore) stays green, and turns exit 1 into a loud failure.

## C1 — bsnes native `.bst` round-trip (control, must pass)

Gold-standard state-transfer proof: a `.bst` saved by bsnes at frame N,
reloaded into a **fresh** bsnes core and advanced K frames, reconstructs
the exact architectural state of a native run straight to N+K — the only
divergence being bsnes's per-boot PRNG seed (`random.state`, payload bytes
[542,550)), which the CMS classifies emulator-internal and never
translates. Also checks: the state loads without rejection, the emulator
is demonstrably live (A ≠ B), and the load+advance path is deterministic.

## C3 — corrupted `.bst` rejected (control, must fail loudly)

A both-directions oracle check: a valid state is accepted, and a battery
of corruptions that hit real load-path gates — container signature,
container size, serializer signature, version string, `serializeSize`,
empty/truncated — are each rejected. Proves the bsnes oracle is neither a
rubber stamp nor a blanket rejector.

## C2 — Mesen2 native `.mss` round-trip (control, must pass)

Boots StateProbe under MesenCore, runs to the gen-2 self-audit, confirms
`PASS = RAN = 0x3F8F` with a valid RESULT_SCHEMA checksum, saves a `.mss`,
advances frames (beacon epoch ticks up — emulation is live), loads the
`.mss` back, and confirms the **beacon epoch rewinds** (the load oracle —
`LoadStateFile`'s bool is unreliable under async apply) with the audit
still passing and the beacon byte surviving. This proves the source-side
capture/restore path end-to-end before any transmutation is scored.

## C4 — CMS decode → live re-injection (first pass, WRAM domain)

Isolates "is the architectural decomposition complete?" from "can we
synthesize bsnes's format?" (spec §method upgrade). This first pass proves
the two halves of live injection on the WRAM domain:

1. **Decode correctness vs ground truth** — the WRAM the decode oracle
   (`mss_dump -x memoryManager.workRam`) pulls out of a `.mss` is
   byte-identical to the live core's WRAM at the instant that `.mss` was
   captured. The decode recovers exactly what Mesen serialized, tested
   against Mesen itself.
2. **Live injection** — that decoded WRAM, written via `write_bytes` into
   a *different* parked core (which had a different beacon epoch), reads
   back as the captured state's self-audit (magic + PASS bitmap + beacon).

Full behavioural-continuation C4 (run the injected core, require it to
match a native load) additionally needs CPU/PPU register injection via
`SetCpuState`/`SetPpuState` — exports present in the core, not yet bound in
MesenRunner. That, plus extending the decode to VRAM/CGRAM/OAM/SRAM and
formalizing it in `transmute_snes.c`, is the P2 entry point.
