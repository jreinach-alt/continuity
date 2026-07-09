# Sprint 3.1 — Summary (kickoff stage)

**Status:** Recon phase shipped; spec DRAFT awaiting on-device recon
results + owner approval. NO implementation has begun (spec-gated).
**Session:** 2026-07-09 (Fable kickoff session).
**Branch:** `claude/sprint-3.1-anbernic-kickoff-abjqjc`

## Files Created

- `src/platforms/onion/recon_device.sh` — one-shot, read-only on-device
  recon for the RG40XX V (firmware fingerprint, arch/libc ELF decode,
  exec-semantics probes on the SD mount, real-save byte checks incl.
  RZIP magic, RetroArch config, boot-hook candidates, network/clock;
  secrets masked). Runs under `busybox ash`; every probe individually
  guarded (deliberate `set -e` deviation, documented in the header).
- `tests/unit/onion/test_recon_device.sh` — 25 assertions: ELF
  classifier (aarch64/arm32/non-ELF/tiny/missing + minimal-od octal
  fallback), RZIP magic detection, full run against a fixture SD tree
  (exit 0, no artifacts left, all key sections, PAT masked to length,
  secret never in report, overwrite semantics, default output path).
- `docs/sprints/sprint-3.1-spec.md` — the sprint spec (DRAFT).

## Files Modified

None. (Coordination rule: this sprint touches only its own files;
the one planned shared edit — gate.sh shellcheck list — is deferred to
implementation.)

## Tests Written

`tests/unit/onion/test_recon_device.sh` (25 assertions, green under
`busybox ash`, exercised by `scripts/gate.sh full` in both privilege
passes).

## Deviations from Spec

None yet — the spec is the deliverable. One deviation from house style
inside the recon script (`set -e` omitted), documented and justified in
the script header and the spec.

## Key finding (Gate 0)

Desk research found **no Onion OS build exists for H700/Anbernic
hardware** (open feature request only — OnionUI/Onion discussion #1697);
the real CFW candidates for the RG40XX V are muOS, Knulli, ROCKNIX, or
modified stock. This contradicts the project premise "Anbernic (Onion
OS)" and is now Decision Gate 0 in the spec: the recon report's
firmware-identity section resolves it factually, and branch B (retarget
to the real firmware) or C (Onion target is actually a Miyoo ARMv7
device → new cross-compile) needs an owner decision.

## Open Items

1. **Owner: run recon on the RG40XX V** — copy
   `src/platforms/onion/recon_device.sh` to the SD card root, get a
   shell (SSH/terminal per firmware), `sh /mnt/SDCARD/<name>.sh`, send
   back `CONTINUITY_RECON.txt`. No secrets are captured.
2. **Owner: resolve Decision Gate 0** (firmware identity / naming) once
   the report is in.
3. **Owner: approve the Sprint 3.1 spec** (or annotate).
4. Implementation (Phase I of the spec) — blocked on 1–3.
5. At implementation: add `src/platforms/onion/*.sh` to gate.sh's
   full-tier shellcheck list (coordinated shared edit).
