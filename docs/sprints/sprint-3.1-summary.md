# Sprint 3.1 — Summary (kickoff stage)

**Status:** Recon phase shipped; Gate 0 RESOLVED (muOS); spec DRAFT
awaiting the on-device recon report + owner approval. NO implementation
has begun (spec-gated).
**Session:** 2026-07-09 (Fable kickoff session).
**Branch:** `claude/sprint-3.1-anbernic-kickoff-abjqjc`

## Gate 0 resolution (2026-07-09)

Desk research: **no Onion OS build exists for H700/Anbernic hardware**
(Onion targets the Miyoo Mini family, ARMv7; H700 is an open feature
request — OnionUI/Onion discussion #1697). Owner Q&A confirmed the
device in hand is an **RG40XX V with working WiFi**, and the owner then
identified the installed firmware: **muOS**. Sprint retargeted
accordingly (platform id `muos`); **Onion OS stays on the roadmap as a
future platform** — owner wants it, but the current fleet has no
Onion-capable hardware to validate against. The owner has **no shell
access**; on-device recon ships as a muOS Task Toolkit script
(`MUOS/task/`, tap-to-run).

## Files Created

- `src/platforms/muos/recon_device.sh` — one-shot, read-only on-device
  recon for the RG40XX V (firmware/version fingerprint, arch/libc ELF
  decode, exec-semantics probes on the SD mount, real-save byte checks
  incl. RZIP magic, RetroArch config, boot-hook candidates,
  network/clock; secrets masked). Runs under `busybox ash`; every probe
  individually guarded (deliberate `set -e` deviation, documented in
  the header). Delivered via muOS Task Toolkit — no shell needed.
- `tests/unit/muos/test_recon_device.sh` — 25 assertions: ELF
  classifier (aarch64/arm32/non-ELF/tiny/missing + minimal-od octal
  fallback), RZIP magic detection, full run against a fixture SD tree
  (exit 0, no artifacts left, all key sections, PAT masked to length,
  secret never in report, overwrite semantics, default output path).
- `docs/sprints/sprint-3.1-spec.md` — the sprint spec (DRAFT).

(Both platform files were first created under `onion/` from the brief's
premise and moved to `muos/` when Gate 0 resolved — same session.)

## Files Modified

- `docs/roadmap.md` — Sprint 3.1 retitled to muOS client (RG40XX V);
  Onion OS moved to a deferred outline (no test hardware); save-state
  section's platform note corrected.
- `CLAUDE.md` — target-platform line, repo-structure listing, and
  commit scopes updated for `muos` (owner-directed retarget).

## Tests Written

`tests/unit/muos/test_recon_device.sh` (25 assertions, green under
`busybox ash`, exercised by `scripts/gate.sh full` in both privilege
passes).

## Deviations from Spec

The spec itself is the deliverable; one house-style deviation inside
the recon script (`set -e` omitted), documented and justified in the
script header and the spec. The kickoff brief's platform premise
("Onion OS on the RG40XX V") was corrected by Gate 0 — recorded in the
spec rather than treated as a deviation.

## Open Items

1. **Owner: run recon via Task Toolkit** — copy
   `src/platforms/muos/recon_device.sh` to SD1 as
   `MUOS/task/Continuity Recon.sh` (no editor re-save — CRLF trap),
   boot, Applications → Task Toolkit → Continuity Recon, then send back
   `CONTINUITY_RECON.txt` from the card root. If `MUOS/task/` doesn't
   exist on the card, send a top-level card listing instead (Task
   Toolkit moved across muOS releases).
2. **Owner: approve the Sprint 3.1 spec** (or annotate).
3. Implementation (Phase I of the spec) — blocked on 1–2.
4. At implementation: add `src/platforms/muos/*.sh` to gate.sh's
   full-tier shellcheck list (coordinated shared edit).
5. Roadmap: future Onion sprint needs Onion-capable hardware (Miyoo
   Mini family, ARMv7 → new cross-compile target) — revisit when the
   fleet grows.
