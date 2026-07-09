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

## Recon results (2026-07-09 — device report analyzed)

Owner ran the recon via Task Toolkit on the first try. Full findings in
the spec's "Recon Findings" section; headline: muOS with
**conflicting version signals** (os-release: 2410 Banana;
version.txt: 2502.0 Pixie; owner: probably Banana — not updated in a
while). Owner requirement follows: fleet muOS versions are unknown, so
the client is **feature-probed, never version-gated** (spec: Version
Support Policy; acceptance I9). aarch64/glibc/busybox 1.36.1,
no git/ssh/inotifywait (bundled git + polling daemon, Brick shape),
**exec-from-SD works** (mount is nosuid,nodev but not noexec), no
symlinks, `/proc/self/exe` fine, saves per-CORE at
`/run/muos/storage/save/file/<Core>/<rom>.srm` in confirmed retroarch
name-style, compression off + real saves byte-checked raw (RZIP risk
retired), WiFi/DNS/HTTPS/clock all good. Open blank: the user boot
hook (Task Toolkit manual start is the day-one fallback). Main design
flag: per-core save dirs vs `system_paths` — likeliest core-escalation
candidate, analyzed in the spec.

Recon probe defect found via the real report and fixed (recon-2): the
exec probe's copied binary must be NAMED `busybox` — a multi-call
binary dispatches on argv[0], so an arbitrary probe name returns
"applet not found" (rc 127) and reads like a failed exec even though
the exec succeeded. The heuristic line now distinguishes
output-produced (exec worked) from silent rc 126/127 (exec failed).

## Open Items

1. **Owner: approve the Sprint 3.1 spec** (or annotate) — the only
   remaining blocker.
2. Implementation (Phase I of the spec) — blocked on 1.
3. At implementation: add `src/platforms/muos/*.sh` to gate.sh's
   full-tier shellcheck list (coordinated shared edit); resolve the
   boot hook in the first validation round (preflight dumps S01muos +
   /opt/muos/script/).
4. Roadmap: future Onion sprint needs Onion-capable hardware (Miyoo
   Mini family, ARMv7 → new cross-compile target) — revisit when the
   fleet grows.
