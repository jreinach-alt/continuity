# Sprint 3.2 — muOS OTA Updates — Implementation Summary

**Spec:** `docs/sprints/sprint-3.2-spec.md` (APPROVED 2026-07-10)
**Status:** Implemented in an isolated worktree; pending orchestrator QA,
full gate, and merge into `claude/sprint-3.1-anbernic-kickoff-abjqjc`.

Ends card-swap delivery for the muOS client. A "Continuity Update" Task
Toolkit tap fetches the channel's pinned commit, verifies the fetched
tree, and stage-applies the new app tree — the Brick's OTA contract with
muOS-native UX. One pinned commit in `release/channels.json` serves BOTH
platform artifacts (`build/Continuity.pak` + `build/Continuity-muos.app`),
so a single publish updates the whole fleet.

## Files Created

- `src/platforms/muos/update.sh` — the muOS OTA updater (ota_* functions).
  Persistent sparse clone (`--filter=blob:none`, plain-shallow fallback)
  of the public project repo at `.continuity/ota-repo`, sparse path
  `build/Continuity-muos.app`. Reads `release/channels.json` via
  `git show origin/main:...` (no checkout), fetches the channel's PINNED
  commit, verifies the fetched tree (CRLF scan on shipped scripts +
  `checksums.txt` byte/sha) BEFORE any staged copy, then fans the app out
  to `.continuity/app/**` and the `MUOS/task`/`MUOS/init` entries back to
  the card root. Binaries rewritten only when size differs; applied
  commit recorded in `.continuity/.ota_commit`; durable channel seeded
  once from `ota_channel.txt`, never overwritten. `CONTINUITY_OTA=0` kill
  switch. **No legacy branch fallback** (unreachable/missing manifest
  simply holds). No muOS-version branching (Version Support Policy). All
  paths env-overridable for tests.
- `src/platforms/muos/task_continuity_update.sh` — the Task Toolkit
  consent surface (ships as `MUOS/task/Continuity Update.sh`). Breadcrumbs
  to `.continuity/launch.log`, probes the SD root (`/mnt/mmc` first,
  env-overridable, `$0` only as a last candidate — muOS bind-mount trap),
  sources `update.sh`, reports current → fetched version, applies, and
  names failures with the log path. Honest exit codes.
- `tests/unit/muos/test_ota.sh` — 38 assertions against `update.sh`
  driven through the REAL `publish_channel.sh` on a file:// fixture
  remote (`uploadpack.allowAnySHA1InWant`). Covers: manifest-pinned fetch,
  unpublished-commits-invisible (A3), staged apply + `.ota_commit`
  recording (A2), idempotent re-run (A2), channel seed + never-overwrite
  (A4), kill switch across check/run/apply (A5), CRLF + checksum refusal,
  size-diff-only vs size-differing binary rewrite, and staged-apply leaves
  no half-written tree on a verification failure (A6).
- `tests/unit/muos/test_task_continuity_update.sh` — 14 assertions:
  SD-root probe (override / probe / fallback), and the real task driven
  end-to-end against a fixture remote proving current→new report,
  applied outcome, idempotent re-tap, kill-switch message, and the
  not-installed guard (A6). (Added beyond the spec's file table — the new
  task is code and CLAUDE.md requires every code change to ship tests;
  see Deviations.)
- `build/Continuity-muos.app/**` — the second COMMITTED artifact,
  assembled by `build_muos_app.sh` from the validated PAK binaries. Its
  `.continuity/app/checksums.txt` covers all six binaries; binaries are
  byte-identical to `build/Continuity.pak` (matching sha256).

## Files Modified

- `scripts/build_muos_app.sh` — default output is now the committed
  artifact `build/Continuity-muos.app/` (was the gitignored
  `build/muos-app/`); zip built FROM it (stays gitignored). Stages
  `update.sh` under app `scripts/`, the Update task at
  `MUOS/task/Continuity Update.sh`, and writes `ota_channel.txt`
  (`CONTINUITY_BUILD_CHANNEL`, default `nightly`). Test hooks unchanged.
- `.gitignore` — whitelisted `build/Continuity-muos.app/` (mirrors the
  `build/Continuity.pak/` whitelist); zips remain ignored.
- `scripts/gate.sh` — full-tier shipped-artifact integrity now
  byte-verifies BOTH artifacts (refactored into
  `verify_artifact_checksums`; muOS manifest read from
  `.continuity/app/`), and the qemu section smokes the muOS artifact's
  git (`--version`) + busybox (`validate_busybox.sh`) when qemu is
  present. Fast-tier shellcheck delta now also skips `build/` (generated
  artifact copies; the muOS task names carry spaces, which broke the
  `xargs` split) — consistent with the full tier, which never lints
  `build/`.
- `.githooks/pre-push` — full-gate auto-escalation pathspec extended to
  `build/Continuity-muos.app` (mirrors the `build/Continuity.pak` rule).
- `CLAUDE.md` — build/ structure block names both committed artifacts;
  the NextUI OTA-protocol text mentions the muOS updater/artifact and
  the one-pin-serves-both fleet contract.
- `docs/roadmap.md` — inserted Sprint 3.2 (muOS OTA, implemented pending
  merge) into Phase 3; renumbered Android 3.2 → 3.4 (Onion stays 3.3).
- `release/README.md` — noted that one pinned commit serves two artifacts
  so a publish delivers the whole fleet.
- `docs/platform/muos-field-notes.md` — appended an OTA section (safety
  boundary, task-tap consent, staged verified apply, no legacy fallback,
  one-pin-whole-fleet, kill switch, SD-root probe). Append-only.
- `tests/unit/muos/test_build_muos_app.sh` — asserts the new artifact
  location, `update.sh` + Update task staging, `ota_channel.txt` seed
  (default + `CONTINUITY_BUILD_CHANNEL=stable` override).

## Tests Written

- `tests/unit/muos/test_ota.sh` — 38 assertions, all pass under
  `busybox ash`.
- `tests/unit/muos/test_task_continuity_update.sh` — 14 assertions, all
  pass.
- `tests/unit/muos/test_build_muos_app.sh` — extended to 37 assertions,
  all pass.
- Full suite: **48 passed, 0 failed** (`sh scripts/test.sh`).
- `sh scripts/gate.sh fast`: green (CRLF + shellcheck).
- `shellcheck -x --severity=error`: clean on every created/modified `.sh`.

## Acceptance Criteria

- **A1** — build produces committed artifact + zip (identical bytes by
  construction); checksums manifest covers all six binaries; gate
  byte-verifies the muOS artifact and (qemu present in this environment)
  smokes its git `--version` + busybox matrix. Verified manually; the
  orchestrator's `gate.sh full` exercises it in the automated flow. ✓
- **A2** — updater reads the manifest at the pinned commit, fetches only
  the muOS artifact path, refuses checksum/CRLF corruption, applies
  cleanly, records `.ota_commit`, idempotent at the same pin. ✓ (test_ota)
- **A3** — unpublished commits on main are invisible; the manifest pin is
  the only source of truth. ✓ (test_ota Test 1)
- **A4** — first run adopts the build's channel; installs never overwrite
  an existing `.continuity/ota_channel`. ✓ (test_ota Test 4)
- **A5** — `CONTINUITY_OTA=0` disables check/run/apply with a named log
  line, and the task reports it. ✓ (test_ota Test 5, task test)
- **A6** — the Update task reports current→new, names failures, and a
  verification failure leaves NO half-applied tree (staged-apply
  assertion + task end-to-end). ✓ (test_ota Test 10, task test)
- **A7** — all tests pass under `busybox ash`; paths are `$TMPDIR`-derived
  and repo-tree-free (unprivileged-safe). Full `gate.sh full` is the
  orchestrator's step. ✓ (current-user pass green)
- **A8** — coordination respected: no edits to
  `src/platforms/muos/{init_continuity,preflight,task_continuity,recon_device}.sh`,
  `src/platforms/nextui/**`, `src/core/**`, or the sprint-3.1 docs. ✓

## Deviations from Spec

- **Extra test file** `tests/unit/muos/test_task_continuity_update.sh`
  (not in the spec's file table). The Update task is new code, and
  CLAUDE.md mandates tests for every code change; the file table listed
  the updater and build tests but not one for the task. Added it rather
  than ship the consent surface untested. Low-risk; drop if unwanted.
- **Fast-gate shellcheck scope** narrowed to skip `build/` (in addition
  to the pre-existing `upstream/` skip). Necessary because the committed
  muOS task filenames contain spaces (`Continuity Update.sh`) which broke
  the fast tier's `xargs shellcheck` word-splitting; and those scripts
  are generated copies of already-linted `src/` files. The full tier
  already never lints `build/`, so this only aligns the two tiers.
- **No `ota_ensure_repo` origin-reconcile** (NextUI has one for the
  ideal_os→continuity migration). Omitted deliberately: muOS is a
  post-migration platform with no cached clones to repoint, and the spec
  emphasizes the simpler updater. If the project repo URL ever moves, a
  muOS device's cached clone would need a manual reset or a re-clone —
  noted as a future consideration, not a current risk.
- **No version-parity / card-swap adoption** (NextUI compares the
  manifest version against the live version to skip re-offering a
  card-swapped build). Omitted because the shared manifest carries the
  *PAK* version, not the muOS app version, so the comparison can't be
  made cleanly. Consequence: the first OTA tap after a fresh zip install
  re-applies the pinned build once (harmless — identical bytes, size
  probe skips binary rewrites — then `.ota_commit` makes every later tap
  a true no-op). Not required by any acceptance criterion.

## Open Items

- **Hardware validation** on the RG40XX V (real WiFi fetch from GitHub,
  a real tap-driven update, next-boot pickup) — deferred to the same
  device round as Sprint 3.1's remaining validation. The updater rides
  the identical git+TLS stack already hardware-proven for enrollment.
- **First publish to a live channel** for the muOS artifact happens when
  the sprint-3.1 branch merges to main and `publish_channel.sh` pins a
  commit — one pin will then serve both platforms.
- **`gate.sh full`** is the orchestrator's responsibility (per the task);
  run in this environment only the fast tier + targeted muOS artifact
  checks (all green, qemu present).
