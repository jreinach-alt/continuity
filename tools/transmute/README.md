# tools/transmute — Spike T2.0 workbench

Cross-core SNES save-state transmutation spike (Mesen2 → bsnes).
**Spec (approved 2026-07-11):** `docs/sprints/spike-t2.0-snes-spec.md`.
Running findings ledger + handoff: `docs/sprints/spike-t2.0-summary.md`.
Primary instrument: StateProbe diagnostic ROM (built in SuperForge from
`docs/sprints/spike-t2.0-stateprobe-brief.md`; imported here as a
fixture during P1).

Everything here is **desktop-tier x86_64 tooling** — not
BusyBox-constrained, never shipped to a device, and independent of the
product's sync code (`src/**` is untouched by this spike).

## Layout

| Path | What |
|---|---|
| `fetch_refs.sh` | pins + fetches both emulator source trees into `vendor/` |
| `vendor/mesen2`, `vendor/bsnes` | vendored reference sources (gitignored; ~70 MB) |
| `build/` | local build outputs (gitignored) |
| `cms/cms_snes_v1.json` | CMS-SNES v1 schema — architectural state only, per-field classification (P0 exit artifact) |
| `cms/mapping_mesen2_bsnes.json` | complete both-sides field inventory + CMS correspondence + transforms + refuse rules (P0 exit artifact) |
| `mss_dump.c` | Mesen2 `.mss` decode oracle: container + keyed records, chip firewall (`cc -O2 mss_dump.c -lz`) |
| `bst_dump.c` | bsnes `.bst` decode oracle: container + RLE + exact positional plain-cart walk, fastPPU layout (`cc -O2 bst_dump.c -lz`) |
| `gen_fixtures.py` | deterministic synthetic container fixtures → `tests/fixtures/transmute/` (+ sha256 manifest) |
| `transmute_snes.c` | decode → CMS → donor-encode pipeline (P2) |
| `harness/` | capture/verify drivers (P1) |

Tests: `tests/unit/transmute/test_dumpers.sh` (compiles the dumpers,
runs them over the committed fixtures; container/codec/gate/refuse
coverage). Semantic oracle fixtures (StateProbe beacon captures) land
with the SuperForge import in P1.

## Pins

| Tree | Commit | Why this one |
|---|---|---|
| `vendor/mesen2` | `b9fa69ddc6d0a331fb103fdb5eef6904305703c2` | final commit of the archived upstream (2026-06-04) — the format is frozen here forever; SuperForge's `MesenCore.so` wraps this codebase |
| `vendor/bsnes` | `7d5aa1e656b9171524d01b1b22917197d8121cb4` | bsnes-emu/bsnes master at spike start; `Emulator::SerializerVersion = "115.1"` |

Format citations in spike docs are written `path:line@pin` against
these trees. If a pin ever changes, every citation must be re-verified
(that is the point of pinning).
