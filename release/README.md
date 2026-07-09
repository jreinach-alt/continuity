# Release channels

`channels.json` is the OTA release manifest — the single source of
truth for what every device installs. It lives on `main`, so it
survives feature branches, PR merges, and session handoffs by
construction; publishing, promotion, and rollback are ordinary
reviewable commits.

## The contract

- A **channel** is a durable name (`stable`, `nightly`) mapping to a
  pinned commit whose tree contains the released
  `build/Continuity.pak`. Channel names never die; branches can.
- A **device** holds its channel identity in
  `.continuity/ota_channel` (seeded on first run from the build's
  `ota_channel.txt`, never overwritten by updates — installing a
  nightly build does not silently move a stable device to nightly).
- The updater fetches `main`, reads this manifest (`git show`, no
  checkout), and fetches its channel's pinned commit for the PAK tree.
  If the manifest is unreachable or lacks the channel, it falls back
  to the legacy fetch-a-branch mechanism, treating the channel value
  as a branch name — that fallback is the zero-risk migration path for
  devices deployed before this manifest existed, and can be removed in
  Phase 2.

## Operations (all via `scripts/publish_channel.sh`)

```sh
# publish the current verified build to nightly (after the build
# commit is pushed — the manifest must reference a pushed commit):
sh scripts/publish_channel.sh nightly <commit>

# promote to stable exactly what nightly has proven:
sh scripts/publish_channel.sh stable <same-commit>

# roll back: point the channel at the previous good commit:
sh scripts/publish_channel.sh stable <previous-commit> --force
```

The script verifies the target commit actually carries a PAK
(version + checksums verified straight from git objects, no worktree),
guards stable against publishing a commit nightly hasn't proven
(`--force` overrides, e.g. for rollback), commits the manifest change,
and prints the push command. Publishing is deliberately manual until
the release cadence earns automation.

## Invariants

- The manifest only ever references commits reachable from `main`
  (merged history) — devices must be able to fetch them forever.
- `stable` should only ever point where `nightly` has pointed before,
  except during rollback.
- Removing a channel from this file strands devices on it (they hold
  at their current version via the legacy fallback failing loudly in
  the log) — don't remove channels, repoint them.

## Migration: the frozen ideal_os manifest (Sprint 1.9)

Continuity was reseeded from `ideal_os` at Phase 1 complete — a fresh SHA
universe (see the repo README's Provenance section). The deployed fleet
repoints here automatically via a normal OTA: the handoff build changes the
updater's `OTA_URL` default **and** reconciles the cached clone's `origin`,
so a device already in the field moves to continuity on its next check, not
just fresh installs.

`ideal_os` is **frozen** at the handoff: its `channels.json` permanently
pins the handoff build (both `stable` and `nightly`), and the repo stays
public and archived — never deleted, never made private. That frozen
manifest is the permanent self-healing shim: any straggler device that only
ever checks `ideal_os` still receives the handoff build, repoints to
continuity, and version-parity-adopts continuity's seed without a refetch.
Deleting `ideal_os` or making it private would strand such a device.
