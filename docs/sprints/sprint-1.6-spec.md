# Sprint 1.6 — OTA Updates

**Status:** Complete — merged to main (PR #3, 2026-07-07)
**Date:** 2026-07-07
**Dependencies:** Sprint 1.1–1.3 (daemon + enrollment, hardware-validated), working bundled git (post-exec-path fix)

## Goal

Eliminate SD-card round-trips for software changes. After first
enrollment, every script/config fix ships over WiFi using the same
bundled git+TLS stack that enrollment proved on hardware.

## Design

- **Mechanism:** the repo tracks the built PAK at `build/Continuity.pak`;
  an update is therefore "sync that folder from the repo". A persistent
  sparse clone (`--filter=blob:none`, graceful fallback to plain shallow)
  lives at `.continuity/ota-repo`, so checks and downloads are
  incremental and unchanged binaries are never refetched.
- **Channel:** `ota_channel.txt` in the PAK, written at build time from
  the source branch — each build tracks its own line of development.
- **Safety:** fetched tree is verified before apply (CRLF scan +
  `checksums.txt` size verification); scripts copy first, binaries only
  when size differs (SD wear + smaller interruption window); state
  commit recorded in `.continuity/.ota_commit`; daemon picks changes up
  at next boot; preflight's on-card checksum verification backstops a
  torn copy. `CONTINUITY_OTA=0` disables.
- **UI:** on pak launch while enrolled, after the status screen:
  "Checking for updates…" → "Update available: <ver> — X installs,
  B skips" (joystick prompt, 4s×10 timeout) → staged apply → "Updated to
  <ver>. Reboot when ready."

## Files

- `src/platforms/nextui/update.sh` — rewritten (`ota_*` functions:
  channel, ensure_repo, check, verify_tree, apply, run). The previous
  curl-based version could never run on-device (no curl exists there).
- `src/platforms/nextui/enroll_ui.sh` — `eui_prompt_button` (bounded
  wait for an accepted button set; reuses the js0 listener).
- `src/platforms/nextui/launch.sh` — OTA flow in the enrolled branch.
- `scripts/build_pak.sh` — writes `ota_channel.txt`.
- Tests: `tests/unit/nextui/test_ota.sh` (16 assertions: detect, apply,
  idempotence, next-version cycle, same-size binary skip, CRLF-tree
  refusal, checksum-mismatch refusal) + launch.sh end-to-end case
  (queued X press applies a fixture update through the real UI path).

## Acceptance criteria

1. Enrolled device with network: pak tap detects a newer commit on its
   channel and offers install. ✔ (unit + integration, off-device)
2. X applies; version.txt/scripts/config match the fetched tree;
   `.ota_commit` advances; second check reports up-to-date. ✔
3. B or timeout skips with no changes. ✔ (prompt-timeout path)
4. Corrupt fetched tree (CRLF or checksum mismatch) is refused with a
   logged reason; live PAK untouched. ✔
5. Binaries are rewritten only when size differs. ✔
6. On-device validation: pending first OTA cycle on the Brick
   (D1: bump a script on the channel → tap → install → reboot →
   verify new version in launch.log).

## Out of scope

- Update of a broken launch.sh/update.sh chain (bootstrap) — card swap.
- Release-tag channels and signed manifests (revisit at Sprint 4.3;
  sha256 manifest exists, signature does not).
- Daemon-initiated background updates (tap-driven only, deliberately).
