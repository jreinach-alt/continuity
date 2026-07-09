# Conflict-Resolution Experience — Design Spec

**Status:** Approved 2026-07-09. Design gate for the per-platform
conflict-UI sprints (NextUI Tool PAK, Sprint 1.5 — the reference
implementation; Android, Sprint 3.2; any future desktop client).
**Approved decisions:** group-by-game resolution (§7.1); shared
`conflict_ui.sh` controller + `pal_ui_*` contract (§7.2); `.conflict` v2 is
the standard with **no** back-compat reader (§3/§7.3); first implementation
= NextUI Tool PAK on the Brick (§7.4); `keep_newest` offered but
clock-guarded, manual default (§7.5). Same gate shape as
`docs/design/save-format-canonicalization.md`.

**Owner intent:** the conflict *engine* is finished and tested but has no
front-end on any platform, and Sprint 2.0 (cross-device canonicalization)
made real two-device divergence the normal case rather than a unit-test.
Design the experience ONCE so each platform renders the same model
natively. First reference implementation targets the TrimUI Brick (the
available device).

## 1. What already exists (we are designing presentation, not mechanics)

The resolution **engine** is `src/core/conflict_handler.sh` — complete,
and covered by `test_conflict_handler.sh`, `test_conflict_ops.sh`,
`test_conflict_flow.sh`, `test_conflict_resolution_flow.sh`,
`test_two_device_conflict.sh`, and the Sprint 2.0
`test_canonicalization_flow.sh` (`.rtc` conflicts). Its public surface:

| Function | Role |
|---|---|
| `ch_handle_pull_conflict` | on a diverged pull: preserve local, accept remote as canonical, commit + push artifacts |
| `ch_list_conflicts` / `ch_count_conflicts` | enumerate unresolved `.conflict` files |
| `ch_list_conflicts_detailed` / `ch_get_conflict_info` | per-conflict metadata (devices, timestamps, active version, trying-modified) |
| `ch_list_local_files` | every preserved `.local` with device attribution |
| `ch_try_version` | copy remote|local into the device's live save slot so the user can LOAD it in the game |
| `ch_get_active_version` / `ch_is_trying` / `ch_is_trying_modified` | which version is currently loaded; was it played-on since |
| `ch_promote_trying` | accept a tried-and-then-modified version as the resolution |
| `ch_resolve` / `ch_resolve_all` | commit a resolution: `keep_remote` \| `keep_local` \| `keep_newest` \| `prompt` |
| `ch_clear_try_markers` | abandon an in-progress try |

**Everything the UI needs already exists as callable primitives.** The
gap is purely presentation + a controller that sequences these calls.

### On-repo artifacts (the true cross-platform interface)

These live in the user's saves repo, so *every* platform's UI reads/writes
the same bytes:

- `<repo_path>.<device>.local` — a preserved losing version (raw save
  bytes). Repo canonical is the winning version.
- `<repo_path>.conflict` — JSON metadata (schema below).
- `.continuity/trying/<repo_path with / → _>` — a local, gitignored marker
  written during a try: `version=<remote|local>`, `checksum=<md5 at try
  time>`, `device_path=<abs>`.

## 2. Design principles (non-negotiable)

1. **Never lose either version.** The invariant the engine guarantees; the
   UI must not offer any path that violates it. "Resolve" chooses which
   version is *canonical*, never deletes the other until the user confirms.
2. **You cannot judge a save by its name or size.** Which file is "further
   along" is only knowable by loading it. **Try is a first-class verb**,
   not an advanced option — the primary path is "load this one, go play,
   come back and decide," backed by `ch_try_version` / `ch_promote_trying`
   and the played-on-since detection (`ch_is_trying_modified`, the "Pokémon
   scenario").
3. **Honest about uncertainty.** Timestamps are device wall clocks and are
   not trustworthy (roadmap gap review: clock-set-backwards, plausibly-
   wrong clocks). The UI shows device + time as *context*, never decides
   for the user by default. Default resolution is manual (`prompt`).
4. **Group by game identity, not by file.** Sprint 2.0 made `.rtc` a
   save-class sibling that travels with its game's SRAM. A user thinks
   "Pokémon has a conflict," not "two files conflict." The UI groups all
   conflicted files sharing a canonical identity (`<system>/<basename>`,
   any of `.srm`/`.rtc`) into one decision.
5. **Degrade to one line and four buttons; scale up to list + detail.**
   The Brick floor is `show2.elf` (one text line) + `/dev/input/js0`
   (B/A/Y/X). The abstract model must express every flow as a sequence of
   single-line prompts, and the SAME states render as a list+detail UI on
   Android/desktop.
6. **Resolution is offline-safe.** Choosing a resolution while offline
   queues the commit and pushes on connectivity return (already supported).

## 3. Normative contract A — the `.conflict` schema (v2)

Two `.conflict` shapes exist in the **code** today — `ch_preserve_conflict`
writes `{_schema_version, file, remote_device, remote_timestamp,
local_device, local_timestamp, status}`, and `cold_start.sh`'s inline
preservation writes `{canonical, local_device, timestamp, source}` (which
`ch_get_conflict_info` cannot fully parse). But **no real repo has ever
contained either shape**: a `.conflict` is produced only when two devices
diverge on the same save, and the fleet is a single Brick, so every
`.conflict` to date exists in tests. `.conflict` files are also *ephemeral*
— resolution deletes them — not durable archival data like saves.

**Decision (owner, 2026-07-09):** v2 is THE schema. No backward-compatible
reader — there is no shipped conflict data to be compatible with, so a
tolerant reader would defend a format that never existed. Both producers
(`ch_preserve_conflict` and `cold_start.sh`'s inline preservation) emit v2
and their tests update to match; the v2-writing daemon ships as one unit
with the fleet, so any `.conflict` a UI ever reads is v2 by construction.

```json
{
  "_schema_version": "2.0",
  "file": "<canonical repo path, e.g. gb/Pokemon Crystal.srm>",
  "identity": "<system>/<basename>   (the game group key)",
  "class": "srm | rtc",
  "remote_device": "<name or 'unknown'>",
  "remote_timestamp": "<ISO8601 or empty>",
  "local_device": "<name>",
  "local_timestamp": "<ISO8601 or empty>",
  "source": "pull | cold_start",
  "status": "unresolved | resolved"
}
```

`remote_*` stays nullable (`unknown`/empty) — cold-start preservation
genuinely has no remote counterpart device, and `keep_newest` already
refuses to guess on a missing timestamp (§4).

## 4. Normative contract B — resolution state machine

Per conflict *group* (game identity), the state a UI drives:

```
           ┌──────────────┐  try(remote|local)   ┌───────────────┐
           │  UNRESOLVED  │ ───────────────────► │    TRYING     │
           │ (both kept)  │ ◄─────────────────── │  (version X    │
           └──────┬───────┘   cancel-try          │  in live slot)│
                  │                                └──────┬────────┘
  keep(remote|local) │                                    │ played-on-since?
  keep_newest*       │                                    ▼
                  ▼                              ┌───────────────────┐
           ┌──────────────┐   promote-tried     │ TRYING-MODIFIED   │
           │   RESOLVED   │ ◄────────────────── │ (a NEW third      │
           │ (.local +    │                      │  version exists)  │
           │  .conflict   │                      └───────────────────┘
           │  removed,    │
           │  committed)  │
           └──────────────┘
```

Operations map 1:1 onto `ch_*`. Guards (normative):

- `keep_newest` is **refused** when either timestamp is missing/implausible
  (engine already does this) — the UI must present this refusal as a
  fall-back to manual choice, never as an error dead-end.
- **TRYING-MODIFIED must never be silently discarded.** If the user tried a
  version, played, and thereby created a third version, "resolve to
  remote/local" must first surface "you have unsaved progress on the tried
  version — keep it?" (`ch_promote_trying`).
- A group with both `.srm` and `.rtc` conflicts resolves as a unit: the
  chosen side's `.srm` and `.rtc` are both promoted; never a Frankenstein
  (device-A `.srm` + device-B `.rtc`).

## 5. Interaction spec (guiding — one model, per-tier realization)

### Entry points — the "you have conflicts" signal

Conflicts are discovered by the daemon (`ch_handle_pull_conflict` during
boot/stale/poll), so the signal must be **passive and persistent** (the
user is not watching when it happens):

- **Persistent red dot** on-device (ties to Sprint 1.4 notifications — a
  conflict dot persists until resolved, unlike transient sync dots).
- **Daily digest** already lists conflicts ("⚠ Conflicts recorded") in the
  saves repo — the async, off-device channel. Design keeps this as the
  at-a-glance summary; it links to on-device resolution.
- **Tool entry** — the platform's Continuity surface (Brick PAK tap,
  Android app, desktop tray) opens the resolution flow; count badged.

### Abstract screens (every platform implements these four states)

1. **List** — N conflicted games: `<game> — <deviceA> vs <deviceB>`.
   Empty state = "No conflicts. Everything's in sync."
2. **Detail** — one game: the two sides (device, timestamp-as-context,
   which is currently *canonical/active*), and the verbs: **Try this**,
   **Keep this**, **Back**.
3. **Try** — "Loaded <version>. Go play; come back here to keep it or try
   the other." On return, if played-on: "You made progress on this version
   — Keep it / Discard and pick again."
4. **Confirm** — "Keep <deviceX>'s <game>? The other version stays in
   history and can be recovered." → commit via `ch_resolve`/`ch_promote_trying`.

### Brick-first realization (the floor: one line + B/A/Y/X)

`show2.elf` renders one line; input is `/dev/input/js0` (B=0, A=1, Y=2,
X=3, per field notes). Each screen is a single line with a button legend:

- List: `Conflicts (2/3): Pokemon Crystal   A=open  Y=next  B=exit`
- Detail: `Crystal: brick-a 14:02 | deck-b 09:11   A=try  X=keep  Y=other  B=back`
- Try handoff: `Loaded brick-a's Crystal. Play, then reopen Continuity.`
- Return: `Crystal (played on brick-a's copy)  A=keep this  Y=pick again`
- Confirm: `Keep brick-a's Crystal? deck-b's stays recoverable.  A=yes  B=no`

Timestamps shown as clock-time context only; never "(newer)".

### Android / desktop realization (same states, richer widgets)

- List = a RecyclerView / table; Detail = a two-pane comparison; Try =
  launches/points at the emulator then returns; Confirm = a native dialog.
- Android reimplements the state machine natively (Kotlin) but reads/writes
  the SAME on-repo artifacts (§3) and honors the SAME guards (§4). No shared
  code with the shell tier — the *contract* is shared, not the language.

## 6. Normative contract C — the shell PAL rendering contract

Shell platforms (NextUI, Onion, RetroDeck) should NOT each rewrite the
controller. Proposed: a shared, platform-agnostic controller module plus a
thin per-platform rendering contract.

- **`src/core/conflict_ui.sh`** (new, BusyBox-ash) — the state machine of
  §4/§5 driving `ch_*`; contains zero platform I/O.
- **`pal_ui_*` contract** the controller calls, each PAL implements:
  - `pal_ui_menu <title> <item...>` → prints chosen index (or `cancel`).
  - `pal_ui_message <text>` → show, wait for acknowledge.
  - `pal_ui_confirm <text>` → `yes`/`no`.
  - `pal_ui_handoff <text>` → show the "go play, come back" message and
    yield (platform decides how the user returns).
  - NextUI implements these over `show2.elf` + `js0` (single-line, button
    legend); RetroDeck over a CLI/desktop-notification pair; the **test
    PAL** implements them as scripted queues so the whole controller is
    unit-testable headless (no hardware), exactly like the sync phases.
- `pal_validate` grows an OPTIONAL check: a platform that advertises
  conflict UI must define the `pal_ui_*` set (platforms without it fall
  back to the digest-only, resolve-on-another-device path).

This makes the Brick/Onion/RetroDeck conflict UIs one tested controller +
small rendering shims, and Android the one native reimplementation.

## 7. Open decisions (for approval)

1. **Group-by-game vs per-file resolution.** Recommend **group-by-game**:
   a game's `.srm` + `.rtc` are one progress unit and must resolve to the
   same side. (Per-file is simpler but can Frankenstein a save.)
2. **Shared `conflict_ui.sh` controller + `pal_ui_*` contract vs.
   per-platform-from-scratch.** Recommend **shared controller** — it is the
   PAL philosophy (one core, thin platform shims) and makes the UI
   headless-testable. Cost: designing the `pal_ui_*` surface carefully.
3. **`.conflict` schema v2 normalization** (§3). **Resolved (owner):** v2
   is the standard; both writers emit it; **no** back-compat reader — no
   real repo has ever held a `.conflict` (conflicts need two devices; the
   fleet is one), so compatibility would defend data that never existed.
4. **First implementation = NextUI Tool PAK (Sprint 1.5), Brick-validated.**
   Recommend **yes** (Brick is available). This turns 1.5 from "Planned"
   into "implements this design."
5. **`keep_newest` in the UI at all?** Recommend **offer it, clearly
   guarded** (labeled "by device clock — may be wrong"), default stays
   manual. Alternative: hide it entirely and only ever show device+time.

## 8. Acceptance criteria for the sprints this design gates

- The controller (`conflict_ui.sh`) drives every §4 state and honors every
  §4 guard, proven headless under the test PAL (both privilege passes) —
  including the trying-modified "third version" path and the group
  resolution of `.srm`+`.rtc` together.
- `.conflict` v2 emitted by BOTH producers (`ch_preserve_conflict` and
  `cold_start.sh`) and read by `ch_get_conflict_info`; both writers and
  their existing tests are updated to v2 (no compatibility shim).
- Brick realization validated on hardware (B1): a real two-device conflict
  surfaces the dot, the PAK opens the list, a try loads a version into the
  live slot, play-on is detected, and resolution commits + pushes.
- No path deletes the losing version before an explicit confirm; offline
  resolution queues and pushes on recovery.

## 9. Out of scope

- Automatic/heuristic conflict resolution (no "smart merge" of save bytes —
  saves are opaque; the user decides). `keep_newest` stays clock-based and
  guarded, not "smart."
- Three-plus-way conflicts across >2 devices in a single screen — the model
  supports N `.local` files, but the first UI sprints target the two-device
  case; N-way list rendering is a follow-up.
- Cross-CORE save reconciliation (out of scope project-wide).
- The Android native implementation itself (its own sprint; this spec is
  the contract it implements).
