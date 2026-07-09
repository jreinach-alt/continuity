# Save-Format Canonicalization — Phase 2 Design Spec

**Status:** Draft for approval — implementation belongs to Phase 2
(second platform). Written 2026-07-07 while the facts were fresh from
the NextUI bring-up; every upstream claim below is cited to source.
**Owner intent:** "the OS claims the saves are 'MinUI' format, so maybe
there is a standard we can use."

## Problem

The same game's SRAM bytes appear under different names and containers
depending on platform and settings. One platform (NextUI) alone has
four save formats; RetroArch-family platforms add a compression
container. Cross-device sync needs ONE repo representation and
per-device materialization — otherwise "the same save" on two devices
is two unrelated repo paths that can never sync.

## Verified facts (upstream NextUI source, 2026-07-07)

Save formats — `upstream/nextui/src/workspace/all/common/config.h:22`:

| Enum | Settings label | On-disk shape |
|------|----------------|---------------|
| `SAVE_FORMAT_SAV` | "MinUI (default)" | `Game.gba.sav` — **raw SRAM**, ROM extension embedded in the name |
| `SAVE_FORMAT_SRM` | "Retroarch (compressed)" | `Game.srm` — **RZIP container** (zlib-chunked, `#RZIPv1#` magic) |
| `SAVE_FORMAT_SRM_UNCOMPRESSED` | "Retroarch (uncompressed)" | `Game.srm` — raw SRAM |
| `SAVE_FORMAT_GEN` | "Generic" | `Game.sav` — raw SRAM |

- Compiled default is `SAVE_FORMAT_SAV` (`config.h:180`); labels at
  `settings.cpp:459`. The user's Brick reports "MinUI" — raw SRAM in
  `Name.<romext>.sav`.
- minarch does ALL SRAM I/O through libretro-common's
  `rzipstream_*` (`minarch.c:829` and the write path): **rzipstream
  transparently READS both raw and RZIP files** (it sniffs the magic)
  and writes whichever the setting selects. RetroArch proper behaves
  the same (`save_file_compression` option).
- State formats have their own enum (`config.h:34`): MinUI `Game.st0`
  (default) vs RetroArch `Game.state<n>` — recorded for completeness;
  states stay an opaque one-way backup (see field notes) and are OUT of
  scope here.
- SRAM bytes themselves are core-agnostic per game — the founding
  premise, now hardware-verified for GB/GBA/SNES on the Brick.

## Decision 1 — canonical repo format: RAW bytes, `.srm` extension

`<canonical_system>/<canonical_basename>.srm`, raw SRAM bytes.

- Raw is the interchange every implementation reads: rzipstream sniffs
  and accepts raw; MinUI-format devices ARE raw. A repo of raw saves
  can be materialized onto any device family without a decompressor.
- RZIP in the repo would also defeat git's delta compression (zlib
  blobs re-encode wholesale on every save) — raw 8–128 KB SRAM deltas
  beautifully.
- `.srm` matches the existing repo layout (`gb/links_awakening.srm`)
  and the de-facto community convention.

## Decision 2 — cross-device identity: exact ROM basename

Canonical basename = device filename with save-container extensions
stripped: `Links Awakening (USA).gba.sav` → `Links Awakening (USA)`
(+ system `gb`) → repo `gb/Links Awakening (USA).srm`.

- Strip rules per format: `.sav` (MinUI: also the embedded ROM ext —
  `X.gba.sav` → `X`), `.srm`, bare `.sav` (generic). The exact
  upstream ext-strip rule (2–4 char extensions only) and its ambiguity
  cases are pinned in `nextui-format-matrix.md` §2; where a device ROM
  list is available, ROM-anchored resolution (§5 there) supersedes the
  heuristic — Decision 3 already requires the ROM list, so the
  device-side mapper gets exact matching for free.
- **Fuzzy matching is explicitly deferred.** "Links Awakening (USA)"
  vs "Legend of Zelda, The - Link's Awakening (U)" are DIFFERENT repo
  saves. Wrong-merge corrupts someone's 40-hour file; duplicate saves
  cost nothing. A future opt-in `config/aliases.json` (user-managed
  data, not heuristics) can join them later.

## Decision 3 — materialize only where the ROM exists

Outbound (repo → device), a save materializes ONLY when a ROM with the
matching basename exists in the device's ROM dir for that system. The
device-native name (which ROM extension to embed for MinUI format) is
derived from that ROM file. No ROM → no materialization: a save
without its game is noise, and this gives per-device sparse sync for
free (a GB-only handheld never receives 500 PS1 saves).

## Decision 4 — inbound container handling (phased)

- **Phase 2 ships:** raw passthrough + RZIP detection. Sniff the
  8-byte magic; raw saves normalize and sync as today. RZIP-compressed
  saves are **quarantined with a named log line and status ping**
  ("compressed save skipped — set save format to uncompressed"), never
  stored corrupt, never guessed at. NextUI default and RetroDeck with
  compression off cover the real Phase 2 fleet.
- **Phase 3:** the `continuity-rzip` codec lifts the quarantine:
  decompress inbound, and recompress outbound only for devices whose
  platform map declares `"save_container": "rzip"`.
  **Status: the codec already exists and is validated against the
  OS's own code** — `tools/rzip/rzip.c` (built by
  `scripts/build_rzip.sh`: host binary for tests/repo-side, static
  aarch64 for on-device). Validation basis, strongest first:
  libretro-common's `rzip_stream.c` (the code minarch/RetroArch
  compile) is vendored verbatim at `tools/rzip/reference/` and
  compiled into an oracle on every CI run — byte-exact interop is
  required in both directions (`tests/unit/tools/test_rzip_interop.sh`),
  the committed primary fixture is generated BY that reference
  encoder, and the matrix was additionally run against the live saves
  repo's real device files (raw SRAM + snes9x `#!s9xsnp` states —
  which are NOT containers and must classify raw). An independent
  reimplementation cross-check and unit tests
  (`tests/unit/tools/test_rzip.sh`) back it up. Phase 3's remaining
  work is only the shell integration and adding the binary to
  `build_pak.sh` + `checksums.txt`.

## Platform map extensions (config is data)

Each `config/platform_maps/<platform>.json` gains:

```json
{
  "_schema_version": 2,
  "save_name_style": "minui | retroarch | generic",
  "save_container": "raw | rzip",
  "rom_roots": ["Roms"]
}
```

`path_mapper.sh` grows the inverse pair (`pm_device_to_canonical`,
`pm_canonical_to_device`) implemented per name_style; core sync phases
call the mapper only — no format logic leaks into sync_engine or the
daemons. BusyBox-ash-compatible like all of core.

## Migration

Existing repo files are already raw bytes with device-native names, so
data is safe. Phase 2 includes a one-time `scripts/migrate_repo.sh`
rename pass (git mv to canonical basenames) with a mandatory dry-run
mode, run once from any enrolled full device. Devices on older PAK
versions keep working mid-migration: filenames only, bytes untouched.

## Acceptance criteria (for the Phase 2 sprint that implements this)

1. Name normalization table tests: every format above, spaced +
   apostrophe + parenthesized names, round-trip
   `device → canonical → device` identity per style.
2. Container sniff tests: raw fixture syncs; RZIP fixture (real magic
   bytes) quarantines with the named log line, repo untouched.
3. No-ROM-no-materialize proven both ways (ROM present → native name
   reconstructed with correct embedded extension; absent → skipped).
4. Cross-style integration: MinUI-named save from device A appears on
   RetroArch-named device B under B's native name (file:// remote).
5. All tests under busybox ash; porcelain-quoting rules respected
   (`-z` plumbing only — see field notes).

## Out of scope

- RZIP encode/decode implementation (Phase 3, toolchain note above).
- Fuzzy/alias name matching (future opt-in data file).
- Save-state conversion of any kind (see field notes — not buildable).
- Changing what the Brick writes: we adapt to devices, never
  reconfigure them.
