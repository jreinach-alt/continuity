# Sprint 2.1 Kickoff — RetroDeck PAL + Enrollment (Steam Deck, Opus session)

Kickoff brief for an **Opus** session bringing up the RetroDeck platform
client on the Steam Deck. Runs in parallel with Onion 3.1 (Fable) and the
UI design system; coordinate merges (§Coordination).

## TL;DR

- Bring up Continuity on **Steam Deck running RetroDeck** — a full-Linux,
  RetroArch-family platform. This is the **second real device** and the
  prerequisite for Sprint 2.3 (the Brick↔Deck cross-device test — the
  actual payoff of Sprint 2.0's canonicalization).
- **Opus, not Fable:** full Linux with **system git** — no cross-compile, no
  bundled-binary port, no exec-semantics minefield. The one thing that could
  turn Fable-class is the **Flatpak sandbox boundary** (below); expect Opus,
  escalate only if the sandbox genuinely blocks git/file access.
- **Spec-gated:** on-device recon → write the Sprint 2.1 spec → owner
  approval → implement. First action is recon + the spec, not code.
- **No core changes expected** — the whole point of the PAL is that a new
  platform is a new PAL + enrollment + config, with the sync engine
  untouched. If you find you must edit `src/core/**`, stop and flag it.

## Platform facts (confirm on-device first — don't assume)

- **RetroDeck is a Flatpak** (`net.retrodeck.retrodeck`) on SteamOS
  (Arch-based, full Linux). `bash`, `systemd --user`, and `inotifywait` are
  all available (per CLAUDE.md, RetroDeck platform code MAY use them; the
  shared **core stays BusyBox-ash-compatible**).
- **Saves** live under the Flatpak data dir —
  `~/.var/app/net.retrodeck.retrodeck/data/saves/<system>/` (already the
  informational `saves_root` in `config/platform_maps/retrodeck.json`, with
  `_saves_root_note` saying runtime uses `$CONTINUITY_SAVES_ROOT`). **ROMs**
  under `.../data/roms/<system>/` → `CONTINUITY_ROMS_ROOT` (Sprint 2.0
  ROM-anchoring).
- `retrodeck.json` is **already schema v2** (`save_name_style: retroarch`,
  `save_container: raw`) from Sprint 2.0 — **but VERIFY** the style and
  container against the Deck's REAL save filenames before trusting it (the
  project rule: format claims tested against real files; Sprint 2.0's
  real-repo byte sweep is the precedent). RetroArch's `save_file_compression`
  can produce RZIP `.srm` — if the Deck has compression ON, those saves
  quarantine (Sprint 2.0 Decision 1A); confirm the setting and note it.
- **THE key architectural question — where does the daemon run?** RetroDeck
  is sandboxed; a sync daemon needs to read the saves dir AND run git with
  network. Determine whether the daemon runs (a) on the host against the
  Flatpak's data path, (b) inside the sandbox via `flatpak-spawn`, or (c) as
  a systemd user service with the right filesystem access. This choice is
  the spine of the sprint — settle it in the spec.

## The plan (Sprint 2.1, mirrors the PAL/enrollment structure)

1. **Recon + spec:** confirm save/rom paths, real save filenames + style,
   compression setting, and the daemon-placement question above → approved
   Sprint 2.1 spec.
2. **PAL:** `src/platforms/retrodeck/pal_retrodeck.sh` — `CONTINUITY_SAVES_ROOT`,
   `CONTINUITY_ROMS_ROOT`, states root, `CONTINUITY_GIT_BIN` (system git),
   `pal_get_platform_map`, `pal_is_online`, `pal_init`, device name. May use
   bash.
3. **Enrollment:** a CLI/desktop enrollment script — detect save paths,
   clone the repo, register the device (`.continuity/devices/<name>.json`),
   store credentials at a Deck-appropriate location. Desktop flow, not
   SD-card `setup.json`.
4. **Service:** a `systemd --user` unit to run the daemon (event-driven via
   `inotifywait` is Sprint 2.2; 2.1 verifies the core sync phases work with
   the RetroDeck PAL, polling is fine to start).
5. **Validate:** `scripts/gate.sh full` green (both privilege passes);
   on-device enrollment + a real save round-trip; confirm cold-start /
   boot-pull / runtime-poll all work through the RetroDeck PAL unchanged.

## Ground rules

- **Core stays BusyBox-ash-compatible**; RetroDeck platform code may use
  bash/systemd/inotify (CLAUDE.md).
- **Format/style validated against the Deck's REAL save files**, not assumed
  — including whether compression is on (RZIP quarantine).
- **No remote CI** — the local tiered gate is the verification; `full`
  before any PR.
- **Model: Opus.** Escalate to Fable only if the Flatpak sandbox boundary
  turns into a genuine exec/namespace problem that survives two Opus
  attempts (the escalation rule).
- Develop on `claude/sprint-2.1-<slug>`; PR to `main`; **owner merges**.

## Coordination (parallel sessions)

- Owns `src/platforms/retrodeck/**`; `retrodeck.json` is already v2 (minimal
  touch — verify only). **Avoid `src/core/**`** (no core changes expected).
  Disjoint from Onion 3.1 (`src/platforms/onion/**`) and the conflict UI
  (`src/core/conflict_ui.sh`).
- **RetroDeck's conflict UI is NOT this sprint.** 2.1 is PAL + enrollment +
  the daemon skeleton. Its conflict UI (desktop notification, Tier 1/2)
  later implements the approved conflict-UX design + the UI design system.
- **This sprint gates Sprint 2.3** (Brick↔Deck cross-device). 2.3 is the
  first real proof that Sprint 2.0's "same save on two devices" works
  end-to-end — do not start it until 2.1's PAL + enrollment are on `main`.

## How to start

1. Read `CLAUDE.md`; env checks + `git config core.hooksPath .githooks`.
2. Read `docs/roadmap.md` → Sprint 2.1; this brief;
   `docs/design/save-format-canonicalization.md` +
   `docs/design/nextui-format-matrix.md` (the canonicalization contract the
   RetroDeck PAL must satisfy); `docs/design/pal.md` (the PAL interface).
3. On-device recon (§Platform facts), settle the daemon-placement question,
   then write + get approval on the Sprint 2.1 spec before implementing.
