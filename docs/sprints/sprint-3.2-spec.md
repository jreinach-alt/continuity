# Sprint 3.2 — muOS OTA Updates

**Status:** APPROVED 2026-07-10 (owner: "go ahead and draft this and
launch it" — spec + implementation authorized in one motion; runs in
parallel with Sprint 3.1's remaining hardware validation).
**Development:** implemented by a coding agent in an isolated worktree;
orchestrator QAs, gates, and merges into
`claude/sprint-3.1-anbernic-kickoff-abjqjc` (single designated branch).
(Roadmap renumber: Android becomes 3.4; Onion stays 3.3.)

## Goal

End card-swap delivery for the muOS client: after one final manual
install, updates arrive over WiFi through the existing channel
infrastructure (Sprints 1.6/1.8) — a "Continuity Update" Task Toolkit
tap fetches the pinned channel commit, verifies, and stage-applies the
new app tree, exactly like the Brick's OTA but with muOS-native UX.

## Design (reuses the proven contract — release/README.md)

- **Channels are unchanged**: stable/nightly pinned to commits in
  `release/channels.json` on main; publish/promote/rollback via
  `scripts/publish_channel.sh` (which already runs the full gate). One
  pinned commit serves BOTH platform artifacts — a publish updates the
  whole fleet, which is why the publish gate matters.
- **Second committed artifact**: `build/Continuity-muos.app/` — the
  muOS app tree, assembled by `scripts/build_muos_app.sh`, committed
  like `build/Continuity.pak` (checksums manifest included; the zip for
  first-installs is built FROM it and stays gitignored).
- **muOS updater**: `src/platforms/muos/update.sh`, adapted from the
  NextUI updater: persistent sparse clone (`--filter=blob:none`,
  fallback plain shallow) of the PUBLIC project repo at
  `.continuity/ota-repo`, sparse path `build/Continuity-muos.app`;
  reads `release/channels.json` via `git show` (no checkout); fetches
  the channel's pinned commit; verifies the fetched tree (CRLF +
  checksums) BEFORE a staged copy; binaries rewritten only when size
  differs; applied commit recorded in `.continuity/.ota_commit`.
  **No legacy branch-name fallback** (NextUI's exists only for
  pre-manifest devices; no such muOS devices exist — omit it, simpler).
- **UX**: `MUOS/task/Continuity Update.sh` — tapping the task IS the
  consent (no button prompt; muOS has no show2). Reports current →
  fetched version, applies, tells the user changes take effect on next
  daemon restart/boot, and offers the truth on failure (named error +
  log path). Kill switch: `CONTINUITY_OTA=0`.
- **Safety boundary (same as the Brick)**: scripts and the vendored
  busybox are OTA-safe (fail-open self-test); a git-binary change still
  warrants a card swap. The updater must stage-apply so a torn update
  cannot half-replace the tree it is running from (NextUI's staged-copy
  pattern transfers).
- **Channel seed**: `ota_channel.txt` in the artifact (default
  `nightly`, `CONTINUITY_BUILD_CHANNEL` override at build) seeds the
  device's durable `.continuity/ota_channel` once; never overwritten by
  installs.

## File table

| File | Action |
|---|---|
| `docs/sprints/sprint-3.2-spec.md` | this spec |
| `src/platforms/muos/update.sh` | create (adapted from nextui/update.sh; no legacy fallback) |
| `src/platforms/muos/task_continuity_update.sh` | create (ships as `MUOS/task/Continuity Update.sh`) |
| `scripts/build_muos_app.sh` | modify: assemble into `build/Continuity-muos.app/` (committed), zip from it; ship update.sh + the Update task; write ota_channel.txt |
| `build/Continuity-muos.app/**` | committed artifact (rebuilt by the script) |
| `.gitignore` | whitelist `build/Continuity-muos.app/` |
| `scripts/gate.sh` | extend shipped-artifact integrity + qemu checks to the muOS artifact; auto-escalation note |
| `.githooks/pre-push` | extend the full-gate auto-escalation pathspec to the muOS artifact (mirror the Continuity.pak rule) |
| `CLAUDE.md` | structure: second committed artifact under build/; NextUI-protocol section gains the muOS artifact mention |
| `docs/roadmap.md` | Sprint 3.2 (this), Android → 3.4 |
| `release/README.md` | note: pinned commits now serve two artifacts |
| `tests/unit/muos/test_ota.sh` | create (adapt tests/unit/nextui/test_ota.sh: manifest fetch via file:// remote with `uploadpack.allowAnySHA1InWant`, staged verified apply, checksum/CRLF rejection, size-diff binary rewrite, channel seeding, kill switch, .ota_commit tracking) |
| `tests/unit/muos/test_build_muos_app.sh` | modify: new artifact location, update.sh + Update task staged, ota_channel.txt |
| `docs/sprints/sprint-3.2-summary.md` | handoff artifact (required sections) |
| `docs/platform/muos-field-notes.md` | OTA section (safety boundary, task-tap consent) |

Out-of-table files or `src/core/**` edits: STOP and escalate.

## Acceptance criteria

- A1. `build_muos_app.sh` produces the committed artifact + zip; both
  carry identical bytes; checksums manifest covers all six binaries;
  full gate byte-verifies the muOS artifact exactly as it does the PAK
  (and runs its busybox matrix/git qemu checks when qemu is present).
- A2. `update.sh` against a local file:// remote: reads the manifest at
  the pinned commit, fetches only the muOS artifact path, REFUSES a
  tree with a checksum mismatch or CRLF, applies cleanly otherwise,
  records `.ota_commit`, and is idempotent (re-run = no-op at same pin).
- A3. Unpublished commits on main are invisible to devices (manifest
  pin is the only source of truth).
- A4. Channel seeding: first run adopts the build's channel; installs
  never overwrite an existing `.continuity/ota_channel`.
- A5. `CONTINUITY_OTA=0` disables everything with a named message.
- A6. Update task: reports current→new version, names failures, never
  leaves a half-applied tree (staged apply proven by a
  kill-mid-copy-style test or equivalent staging assertion).
- A7. All tests pass under `busybox ash`, both privilege passes
  ($TMPDIR-derived paths only); `scripts/gate.sh full` green.
- A8. Coordination: NONE of these files touched:
  `src/platforms/muos/{init_continuity,preflight,task_continuity,recon_device}.sh`,
  `src/platforms/nextui/**`, `src/core/**`, sprint-3.1 docs (parallel
  session owns them).

## Out of scope

- First-install/enrollment via OTA (the zip remains the bootstrap).
- Per-platform channel split (one pin serves the fleet; revisit if the
  platforms ever need to diverge).
- Any rollback UX beyond `publish_channel.sh` re-pinning.
- On-device update prompts (task-tap is the consent).
- Sprint 3.1's remaining hardware validation (parallel work).

## Reference specs

`docs/sprints/sprint-1.6-spec.md` + `release/README.md` (the OTA
contract), `src/platforms/nextui/update.sh` (the template),
`docs/platform/nextui-field-notes.md` §OTA (traps: manifest
reachability, `uploadpack.allowAnySHA1InWant` for file:// tests,
staged apply, torn-copy safety), `docs/platform/muos-field-notes.md`,
`docs/sprints/sprint-3.1-spec.md` (Version Support Policy — the
updater must not version-gate).
