# Sprint 1.8 — Release Channels (OTA rework)

**Status:** Complete — merged to main (PR #3, 2026-07-07)
**Date:** 2026-07-07
**Dependencies:** Sprint 1.6 (git-based OTA)
**Trigger:** Owner-caught design flaw at PR time: the 1.6 channel was
the build's source branch, so a merged (deleted) feature branch — or
any session handoff to a new branch name — stranded every deployed
device. Release infrastructure must survive branch lifecycles.

## Goal

Durable, named release channels (`stable`, `nightly`) with
PR-reviewable publish/promote/rollback, built on the existing
git-as-transport stack. No servers, no new trust anchors.

## Design

- **Manifest**: `release/channels.json` on main maps channel →
  `{commit, version}`. Main always exists; manifest changes are
  ordinary commits (promotion and rollback are diffs, reviewable).
- **Device identity**: `.continuity/ota_channel` holds the channel
  NAME — seeded once from the build's `ota_channel.txt`
  (`nightly` by default; `CONTINUITY_BUILD_CHANNEL=stable` for release
  card images), never overwritten by installing a build from another
  channel. `ota_set_channel` switches deliberately.
- **Updater** (`update.sh`): fetch main → read manifest via `git show`
  (no checkout) → compare the channel's pinned commit against
  `.ota_commit` (version-parity adoption preserved) → fetch the pinned
  SHA → verify (unchanged CRLF + checksums machinery) → staged apply.
  A pinned tree whose version.txt contradicts the manifest is refused.
  Unpublished commits on main are invisible to devices.
- **Publisher** (`scripts/publish_channel.sh`): verifies the target
  commit's PAK straight from git objects (blob sizes + sha256 against
  its checksums.txt), guards `stable` to only take commits `nightly`
  currently proves (`--force` for rollback), rewrites the manifest,
  commits `release(<channel>): <version> (<sha7>)`.
- **Migration**: legacy fallback — when the manifest is unreachable
  (pre-merge) or lacks the channel, the channel value is treated as a
  branch name and the 1.6 flow runs. Deployed devices receive this
  updater over their old branch channel exactly once, then follow the
  manifest. Fallback removal is a Phase 2 task.

## Acceptance criteria (all in tests/unit/nextui/test_ota.sh)

1. Devices are offered the PINNED commit even when unpublished builds
   land on main afterwards.
2. Channel switch is authoritative both directions (nightly→stable
   offers the older stable build — rollback by channel).
3. Installing a build seeded for another channel does not move the
   device's channel identity.
4. Publisher guard: stable publish refused unless nightly proves the
   commit; `--force` overrides; commits without a verifiable PAK are
   refused outright.
5. Legacy fallback serves a branch-named channel; unknown channel with
   no branch holds safely without touching the deployed PAK.
6. The REAL publisher runs against the test fixture repo (writer and
   reader tested as one contract), plus the retained 1.6 matrix:
   parity adoption, size-probe binary skip, corrupt-tree refusals.

## Out of scope

- Automated nightly publishing from CI (manual until the release
  cadence earns it; the manifest design already supports it).
- Signed manifests (tracked in the security model as the upgrade path
  if the project gains multiple maintainers).
- On-device channel-switch UI (ota_set_channel exists; UI is Sprint
  1.5 territory).
