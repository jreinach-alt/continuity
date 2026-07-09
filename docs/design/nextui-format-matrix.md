# NextUI Save/State Format Matrix — Sprint 2.0 Gate

**Status:** Research complete 2026-07-08 (owner-requested before
launching Sprint 2.0). Every cell below is pinned to vendored upstream
source (`upstream/nextui/src/workspace/all/`), file:line cited.
**This document gates Sprint 2.0**: the canonicalization mapper must
handle every row, and the scanner-coverage fixes in §6 are 2.0
prerequisites.

## 1. The option matrix (verbatim from settings.cpp:459–470)

- **Save format (4 options):** `MinUI (default)`,
  `Retroarch (compressed)`, `Retroarch (uncompressed)`, `Generic`.
- **Save state format (5 options):** `MinUI (default)`,
  `Retroarch-ish (compressed)`, `Retroarch-ish (uncompressed)`,
  `Retroarch (compressed)`, `Retroarch (uncompressed)`.

"-ish" exists only for STATES: it is an upstream filename typo
(`Game.state.0` — extra dot) "keeping it to avoid a breaking change"
(config.h:38). There is no "-ish" save format and no "Generic" state
format.

## 2. The extension-strip heuristic (minarch.c `formatSavePath` / `State_getPath`)

Everywhere NextUI derives a RetroArch-style name it strips the ROM
extension with the SAME rule: remove the last dot-segment only if its
length (including the dot) is 3–5 chars — i.e. **2–4 character
extensions** (`.gb`, `.gba`, `.sfc`, `.nes` strip; longer/shorter
segments stay). Sprint 2.0's reverse mapping must mirror this rule —
but see §5 for why ROM-anchored resolution should supersede the
heuristic wherever a ROM list is available.

## 3. SRAM matrix (SRAM_getPath :798, SRAM_write :846)

All formats write to the SAME directory: `Saves/<TAG>/`.

| Format | Filename | Container | Payload |
|---|---|---|---|
| MinUI (default) | `<rom_fullname>.sav` (ROM ext kept: `Game.gba.sav`) | raw | bare SRAM |
| Retroarch (compressed) | `<rom_stripped>.srm` | **RZIP** | bare SRAM |
| Retroarch (uncompressed) | `<rom_stripped>.srm` | raw | bare SRAM |
| Generic | `<rom_stripped>.sav` | raw | bare SRAM |

- Only `SAVE_FORMAT_SRM` compresses (SRAM_write: single rzip branch).
- The two `.srm` variants are byte-distinguishable only by container
  sniff (`continuity-rzip detect`).
- **`.sav` is ambiguous between MinUI and Generic** — resolved in §5.
- Reads go through `rzipstream_open` (sniffs both) — a device READS
  either container regardless of its setting, so materializing raw is
  always safe; the device rewrites in its own format on next flush.

## 4. State matrix (State_getPath :940, State_write :1113)

All formats write to `SHARED_USERDATA/<TAG>-<core>/`. Slots 0–7 are
manual, 8 is the MinUI "default state" convention, 9 = AUTO_RESUME
(game switcher).

| Format | Slots 0–8 | Auto slot (9) | Container |
|---|---|---|---|
| MinUI (default) | `<rom_fullname>.st<N>` (ext kept) | `<rom_fullname>.st9` | raw |
| Retroarch-ish (compressed) | `<rom_stripped>.state.<N>` (incl. `.state.0`) | `<rom_stripped>.state.auto` | **RZIP** |
| Retroarch-ish (uncompressed) | same as above | same | raw |
| Retroarch (compressed) | slot 0: `<rom_stripped>.state` (bare!); N≥1: `.state<N>` | `<rom_stripped>.state.auto` | **RZIP** |
| Retroarch (uncompressed) | same as above | same | raw |

- **Payload is ALWAYS bare `core.serialize` data** — NextUI never
  writes a RASTATE wrapper in any mode (State_write has exactly one
  rzip branch and one raw branch). "Retroarch format" from NextUI ≠ a
  state written by real RetroArch (which wraps RASTATE inside the
  rzip); both normalize to bare payload per the state-sync design.
- Auto-slot naming DIFFERS by format: MinUI's handoff slot is `.st9`;
  every other format uses `.state.auto`. Slot canonicalization
  (save-state-sync.md) must map all of: `st9 ↔ state.auto ↔ auto`.
- Slot 0 in RA mode is extensionless-numeral (`Game.state`) — a
  pattern no current scanner glob anticipates.

## 5. Identity resolution: ROM-anchored beats heuristic

`X.gba.sav` could be MinUI-style (ROM `X.gba`) or Generic-style (ROM
literally named `X.gba.<ext>`); `X.v12` pre-suffixes fool the 2–4-char
rule in both directions. The mapper should NOT guess from the filename
alone: Sprint 2.0 already ROM-gates materialization, so **derive
identity by matching against the device's actual ROM list** — a save
basename must equal either a ROM's full filename (MinUI style) or a
ROM's ext-stripped name (RA/Generic style). Exact match against real
ROMs is definitive; the §2 heuristic is the fallback for repo-side
operations with no ROM list at hand.

## 6. Coverage audit of the SHIPPED scanners (2.0 prerequisites)

Current patterns: saves `*.srm|*.sav`; states `*.st[0-9]`.

| Class | Covered today? |
|---|---|
| Saves, all 4 formats | ✅ (`.srm` + `.sav` span the matrix) |
| States, MinUI | ✅ |
| States, -ish (`.state.N`) | ❌ **silently never backed up** |
| States, RA (`.state`, `.stateN`, both auto `.state.auto`) | ❌ same |
| **RTC saves (`<rom_fullname>.rtc`)** — RTC_getPath :888: always raw, always this name, written next to SRAM for clock-driven games (Pokémon RTC etc.) | ❌ **not synced at all — a contract-relevant miss** |

Required pattern set (states): `*.st[0-9]`, `*.state`, `*.state[0-9]`,
`*.state.[0-9]`, `*.state.auto`. Required save-sibling addition:
`*.rtc` — tiny, raw, and it must travel WITH its game's SRAM identity
(a Pokémon save restored without its RTC file breaks clock events).
Every list that enumerates save extensions must be updated together:
the three scanners (poll/cold/stale), `cd_detect_changes`'s grep, the
conflict-handler pathspec, `bp_get_remote_changes`'s filter, and the
saves-digest classifier. (The porcelain/-z rules from the field notes
apply to all of them.)

## 7. What this changes for the RZIP codec

Nothing in the codec itself — RZIP is the only container in the matrix
and it is already oracle-validated. What the matrix adds is WHERE rzip
appears: compressed SAVES (`SAVE_FORMAT_SRM`) and compressed STATES
(both "-ish" and RA compressed) — so state ingest (S1) needs the same
detect/unwrap step as saves, and the Phase-2 "quarantine compressed"
rule applies per-class: quarantine applies to SAVES pending codec
integration; states are opaque backups either way and may archive
compressed bytes verbatim until S1 normalizes them.

## 8. Sprint 2.0 spec deltas (gate output)

1. Scanner + filter pattern expansion per §6, with tests for every
   filename shape in §3/§4 (spaced + apostrophe names included).
2. `.rtc` joins the save class (same identity, same conflict rules —
   it is progress data, not a snapshot).
3. Identity resolution is ROM-anchored (§5), heuristic fallback
   mirrors §2 exactly.
4. Slot canonicalization includes RA slot-0 bare `.state` and the
   auto-slot mapping table.
5. Fixture set: one real-shaped file per matrix row, generated via the
   existing oracles (reference rzip encoder for compressed rows).
