# Sprint 1.9 — Repo Migration (ideal_os → continuity) + OTA Repoint

**Status:** Approved (owner-directed, 2026-07-08; seeded-start mode
chosen by owner over full-history mirror). Executed by a dedicated
migration session.
**Date:** 2026-07-08
**Dependencies:** Sprint 1.8 (channel-manifest OTA — the machinery this
migration rides). PR #4 merged (this spec and the current docs must be
on main before work starts).

## Goal

Give the project a new home at `jreinach-alt/continuity` that tells the
product's story from commit 1 — a single seeded root commit carrying
the current tree, not the ideal_os-era whole-OS history — and repoint
the deployed fleet (one TrimUI Brick) via a normal OTA update. No card
swap, no stranded devices, and a permanent self-healing path for any
device that misses the handoff window. The full engineering record
stays readable forever in the archived ideal_os repo; nothing is lost,
it just isn't dragged along.

## The trap this spec exists for

The deployed updater keeps a persistent clone at `$OTA_HOME/ota-repo`
and every fetch goes through its stored `origin` remote
(`src/platforms/nextui/update.sh` @ a814bd9: `fetch origin main` :203,
`fetch origin "$head"` :156, `fetch origin "$channel"` :222).
`ota_ensure_repo` returns early when the clone exists (:95–97) and
never touches the remote URL. Changing the `OTA_URL` default alone
repoints only FRESH installs; the deployed Brick would keep fetching
ideal_os forever. The handoff build must reconcile the cached clone's
remote, and the reconcile must ride an update served from the OLD repo.

Seeded-start adds a second constraint: continuity's commits are a new
SHA universe, so the pinned commits in the seed's copied
`release/channels.json` are foreign there. Continuity must publish its
own channel pins (to the seed commit) BEFORE any device can arrive —
the sequence below guarantees that ordering. Version-parity adoption
(built in 1.6, preserved in 1.8) is what makes the cross-repo hop free:
the device lands on continuity holding the handoff version, finds the
manifest pinning a different COMMIT with the SAME version, and adopts
the new commit without refetching anything.

## Design

### 1. The handoff build (the only product-code change)

- `src/platforms/nextui/update.sh:44` — default `OTA_URL` →
  `https://github.com/jreinach-alt/continuity`.
- `src/platforms/nextui/preflight.sh:22` — default `PF_LSREMOTE_URL` →
  the same URL (the reachability probe should test what the updater
  will actually hit).
- **Origin reconcile** in `ota_ensure_repo`'s reuse branch (:95–97) —
  the single entry point both check modes pass through (`ota_check`
  :196 calls it at :200): when the existing clone's
  `remote get-url origin` differs from `$OTA_URL`, run
  `git remote set-url origin "$OTA_URL"` and log
  `"OTA remote repointed to <url>"`. Idempotent, observable (protocol:
  every action names itself in the log), and it turns ALL future
  repoints into ordinary builds.
- Rebuild the PAK (`scripts/build_pak.sh`) so the shipped copies under
  `build/Continuity.pak/scripts/` pick up both files; version stamp and
  checksums update with it.

Considered and rejected: a device-side `ota_url` state file (analogous
to `ota_channel`). The URL is infrastructure, not device identity — a
stale device file overriding the shipped default is exactly the
stranding class this sprint removes.

### 2. Seed mechanics (single root commit, identical by construction)

The seed is created AFTER the handoff build merges, from its merge
commit's tree object — so continuity's very first state already points
at itself, and the tree is byte-identical by construction rather than
by careful copying:

```sh
handoff_sha=$(git rev-parse origin/main)      # handoff PR merge commit
tree=$(git rev-parse "$handoff_sha^{tree}")
seed=$(git commit-tree "$tree" -m "<provenance brief — template below>")
git push <continuity-remote> "$seed":refs/heads/main
```

- `commit-tree` reuses the existing tree/blob objects — no checkout, no
  `cp`, no re-add. This sidesteps the CRLF-smudge and attribute-drift
  traps (field notes) entirely: the seed's tree SHA EQUALS the handoff
  commit's tree SHA, a one-line verification.
- The root commit has no parents, so the push pack is self-contained —
  pushing from the session's shallow clone is fine.
- An empty repo cannot take a PR (there is no base branch), so the
  provenance brief rides the root commit message; a README provenance
  section lands in continuity's first PR (step 3 below). The archived
  ideal_os remains the durable full-history record.

**Provenance brief template (root commit message):**

```
Continuity — seeded from ideal_os at Phase 1 complete

This project began as "Ideal OS", an appliance-style OS for the TrimUI
Brick. Building an OS was the wrong scope; the piece worth shipping was
the piece nothing else does well: never lose a save. Continuity is that
product — cross-platform SRAM save sync over git, using the user's own
private repo as the server.

This root commit is the byte-identical tree of
jreinach-alt/ideal_os@<handoff-sha> — Phase 1 complete: hardware-
validated NextUI (TrimUI Brick) client, vendored git/busybox toolchain,
channel-manifest OTA, tiered local quality gate, and the Sprint 2.0
format-matrix research. The full engineering record (sprints 0.1–1.9,
PRs #1–4, field notes, defect history) lives in the archived source
repo: https://github.com/jreinach-alt/ideal_os
```

### 3. Sequence (each step gated on the previous)

0. **Preconditions — verify or stop:** PR #4 merged;
   `jreinach-alt/continuity` exists, is PUBLIC (OTA fetches are
   anonymous), and is EMPTY (no README/license/.gitignore). No
   branch-protection rules yet (they would block the seed push to
   main).
1. **Handoff build** on the session's designated branch: URL defaults +
   origin reconcile + tests + PAK rebuild. PR to ideal_os main (the
   PAK-bearing push auto-escalates the pre-push gate to full —
   expected, not a hang). Owner merges. `<handoff-sha>` = the merge
   commit.
2. **Seed continuity** per §2. Verify: `git rev-parse seed^{tree}` ==
   `git rev-parse <handoff-sha>^{tree}`; GitHub default branch is
   `main`.
3. **Publish on continuity FIRST** (before ideal_os serves the handoff
   to anyone): from a branch off the seed,
   `publish_channel.sh nightly <seed-sha>` then
   `publish_channel.sh stable <seed-sha>` (the guard reads the
   locally-updated manifest, so both release commits stack). Same PR
   adds the README provenance section, a `release/README.md` note that
   ideal_os is frozen at the handoff pins, and the roadmap note
   recording the move. This is continuity PR #1; owner merges. Run the
   CLAUDE.md startup step 2 in the continuity checkout too
   (`core.hooksPath`) — the publisher runs the full gate there.
4. **Publish on ideal_os**: from post-merge main,
   `publish_channel.sh nightly <handoff-sha>` then
   `stable <handoff-sha>`, one PR; owner merges. Only NOW can any
   device receive the handoff build — and continuity's manifest is
   already correct, so there is no window where a repointed device
   sees foreign pins.
5. **On-device (owner):** run the update (tap Continuity → update, or
   reboot). Expected `update.log`: install of the handoff version;
   then on the NEXT check, `OTA remote repointed to .../continuity`
   followed by version-parity adoption of the seed commit (the agent's
   checklist quotes the exact adoption log line from
   `_ota_finish_check`) and `Up to date`.
6. **Archive ideal_os (owner; NEVER delete, and keep it PUBLIC):** an
   archived public repo still serves anonymous fetches read-only, so
   its frozen manifest — permanently pinning the handoff build —
   self-repoints any straggler device forever. Deleting it (or making
   it private) would break that safety net.
7. Future sessions are created on continuity; development on ideal_os
   ends at the handoff.

### 4. What does NOT change

- `Continuity.pak` name, `CONTINUITY_*` variable names, `$OTA_HOME`
  paths, channel identities, the device PAT (scoped to the SAVES repo —
  enrollment and sync never touch the project repo).
- The user's saves repo is completely untouched by this migration.

### Variant considered and rejected: full-history mirror

Bare clone + `push --mirror` (never `clone --mirror` — GitHub exposes
`refs/pull/*` to mirror clones but rejects pushing them). Old pins
would remain valid, skipping step 3. Rejected by owner 2026-07-08: the
ideal_os-era history is a different project's story, and the archive
preserves it without dragging it along.

## Tests

- `tests/unit/nextui/test_ota.sh` — new cases against the existing
  file:// fixture machinery:
  1. **Repoint:** existing clone whose `origin` points at a stale path;
     `ota_check` with `CONTINUITY_OTA_URL` at the real fixture: check
     succeeds, `remote get-url origin` now matches, repoint line
     logged.
  2. **Idempotence:** second check logs no repoint line; matching
     origin logs nothing.
  3. **Migration rehearsal (the whole flow in miniature):** fixture
     repo A (old home) serves a handoff build whose `OTA_URL` names
     fixture repo B — B seeded via `commit-tree` from A's handoff tree
     (different SHA universe, same version) with channels published to
     pin the seed. Device state on A installs the handoff, next check
     repoints to B and version-parity-adopts B's pin without refetch.
     This exercises reconcile + parity + foreign-pin ordering together
     and rehearses the live sequence end-to-end.
- Existing suite stays green under both privilege passes (full gate).

## Acceptance criteria

1. Continuity is a single root commit whose tree SHA equals the handoff
   merge commit's tree SHA; manifest pins the seed; the seed's PAK
   verifies from git objects (publisher check).
2. Handoff build validated under `qemu-aarch64-static` against live
   GitHub with the host git hidden (field-notes protocol): check
   against ideal_os → install → repoint → parity-adopt against the
   real continuity repo.
3. New test_ota.sh cases (repoint, idempotence, migration rehearsal)
   pass under busybox ash, both privilege passes; full gate green at
   the PAK push (automatic) and at PR creation.
4. On-device, owner-confirmed: `update.log` shows the repoint line and
   parity adoption of the seed; `CONTINUITY_DIAGNOSTIC.txt` preflight
   green with the new ls-remote URL.
5. ideal_os archived (public) only after criterion 4 is confirmed.

## Out of scope

- Renaming code identifiers, the PAK, or on-device paths (the product
  is already named Continuity).
- OnionOS / RetroDeck / Android (no deployed devices to migrate).
- Deleting ideal_os or making it private (forbidden — it is the
  permanent straggler shim).
- Any change to the user's saves repo.
- History rewriting/filtering on ideal_os itself (it archives as-is).
