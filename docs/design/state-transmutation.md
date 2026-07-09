# State Transmutation — Cross-Emulator Save States as a Commodity

**Status:** R&D framework, draft for approval (owner-requested deep
research, 2026-07-07). PERPETUALLY EXPERIMENTAL by product decision:
the "never lose a save" contract rests on SRAM sync + native state
backups and is never allowed to depend on anything in this document.
**Relationship to other docs:** `save-state-sync.md` (S1–S3) ships the
same-core pipeline this builds on; Sprint 2.0 canonicalization
supplies game identity. This doc adds the tier ABOVE: converting a
state written by one emulator into a state another emulator loads.

## The idea, stated precisely

A save state is an emulator's serialization of two kinds of state:

1. **Architectural state** — the actual machine: work RAM, video RAM,
   palette/OAM, CPU registers, PPU/APU registers, cartridge/mapper
   chip state, the in-memory SRAM view. Two correct emulators of the
   same system must represent semantically identical architectural
   state, however differently they lay it out.
2. **Emulator-internal state** — event schedulers, cycle counters,
   derived caches, UI extras. This has NO cross-emulator equivalent
   and must be RECONSTRUCTED by the target emulator, not translated.

Transmutation = decode(source state) → **Canonical Machine State
(CMS)** per system → encode(CMS) → target state, accepting that
emulator-internal state is regenerated from the architectural
snapshot. Nobody ships this generically; pairwise precedents prove
the physics (below).

## Evidence (all from source, per project discipline)

- **snes9x** (fetched `snapshot.cpp`, the Brick's actual core): the
  state file is ALREADY a tagged block sequence — `RAM` (WRAM), `VRA`
  (VRAM), `SRA` (SRAM view), `CPU`, `REG`/`PPU`, `DMA`, `SND` (APU),
  `CTL`, plus per-chip blocks (`SA1`, `SFX`, `CX4`, `DP1/2/4`, `OBC`,
  `S71`, `SRT`, `BSX`, `MSU`, `ST0`) and emulator-internal ones
  (`TIM` timings, `MOV` movie, `SHO` screenshot). Decomposition is
  not a theory; it is how the flagship core already writes states.
- **RetroArch RASTATE v1** (fetched `task_save.c`): container only —
  `MEM ` block wraps the core's opaque serialization; `ACHV`/`RPLY`
  are frontend extras. The container is already handled by our S1
  design; transmutation operates on the payload inside.
- **Frame-boundary safe point is free on libretro**: the API defines
  `retro_serialize` between `retro_run` calls — every state our
  platforms produce is captured at a frame edge. The classic
  mid-instruction-snapshot hazard applies to standalone emulators
  (out of scope), not to our fleet.
- **Pairwise prior art**: mGBA imports VBA save states; ZSNES→snes9x
  state converters existed as third-party tools; SPC music dumps are
  literal partial-state extraction from SNES snapshots, produced at
  scale for decades. Generalizing "importer" into "codec against a
  canonical schema" is the whole novelty — the physics is settled.

## The framework

### Canonical Machine State (CMS)

Per-system schema, versioned, architectural-only. CMS-SNES v1 sketch:

| Field | Size/shape | Source of truth |
|---|---|---|
| wram | 128 KiB | `RAM` |
| vram | 64 KiB | `VRA` |
| cgram / oam | 512 B / 544 B | `PPU` sub-blocks |
| cpu (65816) | regs + emulation-mode flag | `CPU` |
| ppu regs | documented register file, vblank-consistent | `PPU`/`REG` |
| apu | SPC700 regs + 64 KiB ARAM + DSP regs | `SND` |
| sram view | cart-declared size | `SRA` |
| cart chips | ENUMERATED allowlist; anything else → **refuse** | chip blocks |

The refuse-by-default chip rule is the scope-creep firewall: v1
transmutes plain LoROM/HiROM games; each special chip (SA1, SuperFX,
…) is its own deliberate, validated addition. A refusal is loud,
logged, and leaves the native state untouched in the archive.

### Codecs

`decode: core-state → CMS` and `encode: CMS → core-state`, one pair
per (core, state-format-version), written against the emulator's own
serialization source exactly like the RZIP work (vendored reference,
oracle tests, format pinned from code — never from hex-eyeballing;
the `#!s9xsnp` misread and the RASTATE raw-version-byte are the
cautionary precedents). Encode must synthesize the target's
emulator-internal blocks the same way the target initializes them at
power-on + state-load — which is why codecs are written FROM the
target's load path, not from format docs.

### Validation harness (the actual hard part, and the gate)

Behavioral, not structural: in a headless libretro frontend, load the
ORIGINAL state in the source core and the TRANSMUTED state in the
target core; run N deterministic frames in each; compare framebuffer
hashes, audio-buffer hashes, and the SRAM view at every save-relevant
event. Ship a pair only when the pilot corpus (per-game samples
across the fleet's actual library) passes at an agreed threshold;
below threshold, the pair stays experimental-flagged or dies. This
harness is also the CI regression net: core version bumps re-run it.

**Kill criterion (owner-approved scope fence):** if the pilot pair
cannot reach the threshold with bounded effort, the tier stays
same-core forever and this document becomes the record of why.

## Where transmutation runs

| Option | Verdict |
|---|---|
| On device | **No.** BusyBox-floor CPUs, per-arch codec builds, and running second cores for validation is absurd there. (Owner pre-decided; concur.) |
| **Repo-side: GitHub Actions in the saves repo** | **Default.** Event-driven (state push triggers it), x86_64 with prebuilt libretro cores available, user-owned compute in the user's own repo — no infrastructure we operate, same trust model as everything else. The digest workflow already proved this tier. |
| Desktop companion app | Later option for no-Actions/private setups; same binary. |
| Android client | Has the compute; MAY run its own transmutes locally in Phase 3+. |

Concretely: **Continuity Transmuter** — one containerized CLI
(decode/encode/validate), deployed as a workflow in the saves repo.
Devices stay dumb: they archive native states + sidecars (S1,
unchanged). The Transmuter watches `states/`, reads the fleet's
device registrations, and commits target-native variants alongside
the canonical archive:

```
states/<system>/<game>/<slot>.st            # bare source payload (S1)
states/<system>/<game>/<slot>.meta.json     # capture metadata (S1)
states/<system>/<game>/<slot>.cms           # canonical decomposition (T2)
states/<system>/<game>/<slot>.for-<core>.st # encoded for a fleet core (T2)
```

### Fleet-scoped support matrix (owner requirement)

The Transmuter builds NOTHING speculative: the pair list is derived
from `.continuity/devices/*.json` core inventories — the union of
(core, version) pairs actually enrolled. One core fleet-wide (the
likely Brick+Thor snes9x case) means T0/T1 passthrough and zero
codec work; a second core appearing is what activates a pair.

## Fidelity tiers

| Tier | What | Cost | Status |
|---|---|---|---|
| T0 | same core, same version — byte passthrough | none | S1–S3 design |
| T1 | same core, version drift — cores load their own older snapshots; validate, don't translate | harness only | with S3 |
| T2 | cross-emulator, same system — CMS + codec pair | high, per pair | THIS doc, experimental forever |
| T3 | cross-system | — | never |

## Known product interaction (found in this research)

**States embed their own SRAM view** (`SRA` block; every emulator
does this). Restoring yesterday's state hands the game yesterday's
in-memory save data — the next in-game save flushes it over newer
SRAM. Our SRAM conflict machinery preserves both versions (contract
holds), but the UX should know: S2's restore flow must warn when a
state's embedded SRAM is older than the canonical save, and a T2
research question is whether the SRA block can be safely refreshed
with current SRAM at transmute time (plausible for menu-captured
states; needs per-game validation; promise nothing).

## Pilot proposal

1. **T0/T1 pilot** (with S2/S3): Brick(NextUI+snes9x) ↔
   Thor(RetroArch+snes9x) — the owner's real fleet, likely same core.
2. **T2 pilot pair** (activates only when the fleet actually contains
   two SNES cores, else chosen deliberately): snes9x ↔ bsnes-mercury —
   best-documented system, richest prior art, and the harness exists
   before the codec does (harness-first is the rule).
