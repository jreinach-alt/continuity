# Save-State Sync — Cross-Device Design (Draft for approval)

**Status:** Draft — owner requested un-deferring states (2026-07-07).
Supersedes the "opaque backup only" scope note in the field notes once
approved. Nothing here is implemented; Phase 0 below is the currently
shipped behavior.
**Research basis:** NextUI verified from vendored source
(`upstream/`); RetroArch state format verified from fetched
`tasks/task_save.c` (same provenance discipline as the RZIP oracle);
MuOS/RetroDeck/Android layouts from platform documentation — marked
with confidence levels.

## Why states were deferred, and what changed

The founding objection stands: a save state is a core-version-specific
memory snapshot; converting between DIFFERENT cores is not buildable.
What the research changes is the SAME-core story: every roadmap
platform except NextUI runs RetroArch, NextUI's minarch uses the same
libretro serialization, and RetroArch's loader accepts bare core
data as its legacy format (`task_save.c content_deserialize_state`:
"old format is just core data, load it directly"). Same-core handoff
across devices — quicksave on the Brick, resume on the Thor — is
buildable with container transforms only. No emulator changes.

## Platform research

| Platform | State location | Core identity | Payload |
|---|---|---|---|
| **NextUI** (verified: source) | `.userdata/shared/<TAG>-<core>/<Game>.<romext>.st<0-9>` | **in dir name** (`SFC-snes9x`) | bare `core.serialize` bytes; rzip container only if RetroArch state format selected. Slot 9 = auto-resume (game switcher), slot 8 = MinUI "default state" convention, 0-7 manual. |
| **OnionOS** (docs, high confidence — owner-confirmed target, replacing the earlier MuOS reading) | `Saves/CurrentProfile/states/<CoreName>/<Game>.state<N>` | **in dir name** | RASTATE v1, rzip-wrapped when state compression on; legacy bare data possible (RetroArch-based, same family as MuOS) |
| **RetroDeck** (docs, medium) | `~/retrodeck/states/<system>/<Game>.state<N>` | **NOT in path** — system dir only; core must be resolved from the system's configured default core (per-game overrides exist) | RASTATE v1 (± rzip) |
| **Android / RetroArch (Ayn Thor)** (docs, medium) | `RetroArch/states/` FLAT by default (sort-by-core optional, user setting) | **NOT in path** by default | RASTATE v1 (± rzip) |

**RASTATE v1** (verified: source): 8-byte magic `RASTATE` + raw
version byte `0x01` (same raw-version-byte pattern as RZIP — the
`#!s9xsnp` lesson says pin these from source, never from hex-eyeballing),
then blocks of `[4-char id][u32le size][payload]`: `MEM ` (the bare
core data), optional `ACHV` (RetroAchievements), `RPLY` (replay),
`END `. The `MEM ` payload IS what NextUI writes as the whole file.

**Consequence:** path conventions cannot carry core identity on two of
four platforms. The repo model must carry explicit metadata written by
the CAPTURING device, and the two RetroArch-frontend clients must
capture the active core themselves (RetroDeck: system→core config;
Android: client-side capture — both PAL responsibilities).

## Repo model

```
states/<system>/<canonical_basename>/<slot>.st          # bare core data, ALWAYS
states/<system>/<canonical_basename>/<slot>.meta.json   # sidecar, same commit
```

- `<canonical_basename>` follows the Sprint 2.0 canonicalization rules
  (same identity as the game's SRAM — states and saves of one game
  travel together).
- `<slot>`: canonical slots `0..7`, `default` (NextUI 8), `auto`
  (NextUI 9 / RetroArch `.state.auto`). Per-platform slot naming is
  data in the platform map.
- **Payload is normalized to bare core data at ingest** (rzip
  unwrapped — codec exists; RASTATE unwrapped to its `MEM ` block —
  small new tool, format pinned from source, oracle-testable the same
  way as rzip). Rationale: bare data is the one form every reader
  accepts (RetroArch legacy path + minarch), it delta-compresses in
  git, and wrapping is cheap at materialization. `ACHV`/`RPLY` blocks
  are dropped at ingest (device-local concerns; recorded in meta).
- Sidecar:

```json
{
  "_schema_version": "1.0",
  "core": "snes9x",
  "core_version": "1.62.3 (unknown allowed)",
  "system": "snes",
  "source_platform": "nextui",
  "source_device": "my-brick",
  "source_slot": "9",
  "captured_at": "2026-07-07T21:14:00Z",
  "payload": "raw-core-data",
  "original_container": "raw | rzip | rastate | rastate+rzip"
}
```

Core names are normalized (`snes9x_libretro.so` → `snes9x`) by a
mapping table in `config/` (data, not code).

## Compatibility gate (materialization)

A state materializes onto a device only when ALL hold:

1. **Core match**: the device advertises the same normalized core for
   that system. Device core inventory joins the existing device
   registration (`.continuity/devices/<name>.json` gains a `cores`
   map, refreshed by the daemon — the PAL provides platform-specific
   discovery: NextUI/Onion from dirs, RetroDeck from config, Android
   from client).
2. **Core version policy**: `exact` (default until proven) → versions
   equal or both unknown; `lenient` opt-in → same core name only.
   Mismatch = skip with a named log line, never a guess.
3. **ROM present** — same gate as saves (see Library-aware
   materialization below). No game, no state.
4. **Slot mappable** on the target platform.

Materialization re-wraps for the target: NextUI → bare (or rzip if
its state format demands); RetroArch family → bare works everywhere
via the legacy loader; wrapping to RASTATE is available if a platform
ever requires it.

## Conflict policy (deliberately different from saves)

States are snapshots, not accumulating progress: per slot,
**last-writer-wins with device attribution in the commit**, no
`.local` artifacts (a quicksave conflict every session would bury the
UI in artifacts). git history IS the undo — any prior state version
is recoverable by commit. The auto slot is the handoff slot and
last-writer-wins is exactly the desired semantics for "continue where
I left off". SRAM keeps the full both-versions-preserved machinery
unchanged.

## Phasing

- **Phase 0 (shipped today)**: opaque one-way archive of NextUI
  `.st0-.st9`, size-capped. No restore. This stays the floor.
- **Phase S1 — metadata + normalized ingest** (NextUI only): sidecars,
  rzip/RASTATE unwrap at ingest, canonical layout, slot mapping,
  core inventory in device registration. One-way still. Migration for
  already-archived opaque states: re-ingest from device (they're
  still on-card), then retire `states/<TAG>-<core>/` paths.
- **Phase S2 — same-core restore on NextUI**: materialize auto +
  manual slots back to the Brick behind the compatibility gate.
  Hardware-validate the full quicksave → cloud → restore loop on one
  device before any cross-device promises.
- **Phase S3 — cross-device handoff**: second platform (whichever
  lands first: OnionOS or RetroDeck) materializes Brick states and vice
  versa. The Brick↔Thor snes9x handoff is the acceptance test.
- Ordering: S1 rides with Sprint 2.0 canonicalization (shared basename
  rules); S2/S3 follow the second-platform PAL.

## Open questions for the owner

1. ~~MuOS vs Onion~~ **RESOLVED (owner, 2026-07-07): OnionOS** is
   the Anbernic target. Onion is RetroArch-based
   (`Saves/CurrentProfile/states/<CoreName>/`), so the design applies
   unchanged.
2. Auto-slot handoff default: materialize the `auto` slot on boot
   pull (a device you pick up resumes the other device's session), or
   behind a per-device opt-in? Proposal: opt-in until S2 is
   hardware-proven, then default-on.
3. Retention: states rewrite constantly; git history grows ~90 KB per
   compressed snapshot commit (measured: 823 KB snes9x state → 88.8 KB).
   Proposal: accept growth in Phase S1-S2; revisit shallow/rewrite
   policies only if the repo actually gets heavy.
