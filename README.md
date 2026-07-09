# Continuity

Cross-platform save sync for retro gaming handhelds. Uses git as its
transport layer — your saves live in your own private GitHub repo.

## What It Does

- Syncs SRAM saves (`.srm`/`.sav`) across devices through your private
  GitHub repository, and archives save states (`.st0`–`.st9`) as
  versioned backups
- Detects save changes automatically; commits locally when offline and
  pushes when WiFi returns
- Preserves both versions on conflict — never silently overwrites your
  progress (git history keeps every version ever synced)
- Ships its own tested toolchain (static git + HTTPS, pinned BusyBox)
  so it does not depend on whatever the firmware provides
- Updates itself over WiFi from release channels — no SD-card swaps
  after first install
- You own your data: your repo, your token, your saves. No accounts,
  no servers, no third parties

## Supported Platforms

| Platform | Device | Status |
|----------|--------|--------|
| NextUI | TrimUI Brick | **Working** — hardware-validated end to end |
| Onion OS | Anbernic / Miyoo Mini | Planned (Phase 3) |
| RetroDeck | Steam Deck | Planned (Phase 2) |
| RetroArch | Android devices | Planned (Phase 3) |

## How It Works

1. Create a private GitHub repo for your saves + a fine-grained PAT
   scoped to that one repo
2. Install Continuity on your device (drop the PAK + a `setup.json`
   on the SD card; enrollment runs on-screen at first launch)
3. Saves sync automatically — git handles versioning, history, and
   conflict preservation
4. Updates arrive over the air from `release/channels.json`
   (`stable` / `nightly`), pinned to exact verified builds

## For Developers and Agents

**Start with [CLAUDE.md](CLAUDE.md)** — the operating manual: repo
structure rules, coding standards (BusyBox ash floor), the tiered
quality gate, build/validation/delivery protocol, and the session
workflow. Then:

- [docs/platform/nextui-field-notes.md](docs/platform/nextui-field-notes.md)
  — hardware-validated trap compendium; read before ANY NextUI work
- [docs/roadmap.md](docs/roadmap.md) — phases, sprint statuses, backlog
- [docs/design/architecture.md](docs/design/architecture.md) — system design
- [docs/design/security-model.md](docs/design/security-model.md) —
  trust boundaries, PAT handling, OTA authenticity
- [release/README.md](release/README.md) — the channel/publish contract

Quality gate: `scripts/gate.sh fast` runs on every push via the
pre-push hook (~1s); `scripts/gate.sh full` (both test-suite passes +
shipped-artifact integrity) is required at PAK-bearing pushes, channel
publishes, PR creation, and session closeout. There is no remote CI —
feedback is synchronous and local, by design.

## Provenance

Continuity began as **Ideal OS**, an appliance-style operating system for
the TrimUI Brick. Building a whole OS was the wrong scope; the piece worth
shipping was the one thing nothing else did well — *never lose a save*.
This repository is that product, reseeded from a single root commit that
carries the Phase 1 tree byte-for-byte.

The full engineering record — sprints 0.1–1.9, the original pull requests,
field notes, and defect history — lives in the archived source repo:
[jreinach-alt/ideal_os](https://github.com/jreinach-alt/ideal_os). It stays
public and read-only forever, so a device that missed the migration window
still self-heals from its frozen release manifest (see
[release/README.md](release/README.md)).

## License

MIT — see [LICENSE](LICENSE).
