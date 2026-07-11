# StateProbe fixtures (Spike T2.0)

Imported from SuperForge (`jreinach-alt/SuperForge`, branch
`claude/stateprobe-diagnostic-rom-em6jh2`, commit `de79be4`) — the
self-auditing diagnostic ROM built to the brief in
`docs/sprints/spike-t2.0-stateprobe-brief.md`. License: **CC0-1.0**
(see the manifest). Contract documentation lives in that repo's
`diagnostics/stateprobe/README.md`; the harness-facing schema is in
`stateprobe_manifest.json` here.

| File | What | Provenance |
|---|---|---|
| `stateprobe.sfc` | StateProbe v0 ROM (32 KiB LoROM, profile 0) | sha256 `b324d2fc…` — MUST match the manifest's `rom.sha256` (byte-reproducible build) |
| `stateprobe_manifest.json` | addresses, RESULT_SCHEMA v1, expectations | copied verbatim |
| `genconfig.json` | generator expectations (bitmaps, epochs_per_pass, sabotage) | copied verbatim |
| `beacon_gen2.mss` | Mesen2 save state captured at the beacon, audit generation 2, `PASS=RAN=0x00003F8F` | captured 2026-07-11 in-session via SuperForge `MesenRunner.save_state_file` (MesenCore = Mesen2 **2.1.1**, header `emuVersion 0x00020101`); capture script: spike scratch `capture_beacon_state.py` (inline in session log) |

Notes for test authors:

- `beacon_gen2.mss` is A valid beacon capture, not a canonical byte
  artifact — regenerating produces a different epoch. Tests must
  assert on decoded content (via `mss_dump` + the manifest), never on
  fixture bytes.
- Header layout was live-verified against the pinned source
  (`tools/transmute/vendor/mesen2` @ `b9fa69d`,
  `Core/Shared/SaveStateManager.cpp:61-83`): `"MSS"`, emuVersion,
  formatVersion=4, consoleType=0, 256×239×2 screenshot block
  (zlib `78 01`), then the keyed payload.
- The state embeds its own result block in WRAM (`$7EF000`) — a
  decoder can self-check against `PASS=RAN=0x3F8F` at gen 2.
