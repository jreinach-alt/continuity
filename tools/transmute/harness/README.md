# tools/transmute/harness — Spike T2.0 P1 harness

Capture/verify drivers for the cross-core state spike (spec §Harness,
phase P1). Desktop-tier x86_64 Python + a compiled bsnes runner — **not**
BusyBox-constrained, never shipped to a device, `src/**` untouched.

## What's here

| File | What | Status |
|---|---|---|
| `mesen_state.py` | Spike-local `MesenRunner` subclass adding `.mss` save/load over the InteropDLL `SaveStateFile`/`LoadStateFile` exports; SuperForge locator; `HarnessUnavailable` skip signal | P1 ✓ |
| `stateprobe.py` | StateProbe RESULT_SCHEMA v1 reader + audit predicate, driven entirely by the committed fixture manifest (no hardcoded offsets) | P1 ✓ |
| `controls.py` | Validity controls C1–C4 CLI. C2 (Mesen2 native round-trip) implemented; C1/C3 land with the bsnes runner, C4 with the first decode pass | C2 ✓ |
| `bsnes_runner.py` | Python wrapper over the compiled bsnes headless runner | pending |

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

Exit codes: `0` pass · `1` fail · `77` skip (emulator dependency absent).

The committed gate wrapper `tests/unit/transmute/test_controls_mesen.sh`
turns exit 77 into a clean skip so the mainline gate (which has no
MesenCore) stays green, and turns exit 1 into a loud failure.

## C2 — Mesen2 native `.mss` round-trip (control, must pass)

Boots StateProbe under MesenCore, runs to the gen-2 self-audit, confirms
`PASS = RAN = 0x3F8F` with a valid RESULT_SCHEMA checksum, saves a `.mss`,
advances frames (beacon epoch ticks up — emulation is live), loads the
`.mss` back, and confirms the **beacon epoch rewinds** (the load oracle —
`LoadStateFile`'s bool is unreliable under async apply) with the audit
still passing and the beacon byte surviving. This proves the source-side
capture/restore path end-to-end before any transmutation is scored.
