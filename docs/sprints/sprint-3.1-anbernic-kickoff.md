# Sprint 3.1 Kickoff — Onion OS on Anbernic RG40XX V (Fable session)

Kickoff brief for a **Fable** session bringing up the Onion OS platform
client on the Anbernic **RG40XX V**. Runs in parallel with the RetroDeck
(2.1) and UI-design-system work; coordinate merges (see §Coordination).

## TL;DR

- Bring up Continuity on **Anbernic RG40XX V running Onion OS** — a
  constrained BusyBox-ash ARM handheld, the same shape as the TrimUI Brick.
- **Same architecture as the Brick** (Allwinner H700, quad Cortex-A53,
  **aarch64**), so the bundled git + busybox likely **port** rather than
  needing a new cross-compile target.
- **Why this is a Fable session:** the Fable-class core is *binary port +
  exec-semantics validation on a new userland* — the historically fragile
  part (git transport-helper re-exec; busybox `/proc/self/exe` applet
  self-exec), documented in `docs/platform/nextui-field-notes.md`. Same
  arch ≠ same userland; verify, don't assume. The rest (PAL, save paths,
  boot hook, enrollment, daemon) is Opus-class and follows the NextUI
  precedent — fine to do in the same session given the window.
- **Spec-gated:** write the Sprint 3.1 spec (scope, file table, acceptance,
  tests) and get owner approval before implementing. First action is
  on-device recon + the spec, not code.

## Device facts (confirm on-device first — do not assume)

- **RG40XX V**, Allwinner **H700** SoC, 4× Cortex-A53, **aarch64 (ARMv8-A)**
  — same family as the Brick's tg5040. RG35XX H/Plus/2024, RG28XX, RG34XX
  share this SoC.
- **First on-device recon (before any binary decision):**
  1. `uname -m` (expect `aarch64`), kernel version (`uname -r`).
  2. libc: glibc vs musl (`ldd --version` / inspect `/lib`). The Brick's
     static binaries should not care, but a partially-dynamic build would.
  3. Does the firmware already ship a usable `git` and/or `busybox`? If a
     good-enough git exists, the bundled-git problem may not exist here.
  4. Save paths, ROM paths, and the **boot/autostart hook** Onion provides
     (the NextUI equivalent of `$USERDATA_PATH/auto.sh`). Onion's launch
     model differs — find its per-boot script mechanism.
  5. **Real save filenames on the device** — Onion runs RetroArch cores, so
     saves are likely `retroarch` name-style (`<rom>.srm`), but CONFIRM
     against actual files (the project rule: byte/format claims about user
     data are tested against real files, never assumed).

## The plan (Sprint 3.1, mirrors NextUI Phase 1 structure)

1. **Recon + spec** (above) → approved Sprint 3.1 spec.
2. **Binary strategy (the Fable core):**
   - Try the Brick's shipped static aarch64 `git` + `busybox` on the
     RG40XX V directly. Validate under `qemu-aarch64-static` AND on-device
     with the **host git hidden** (`mv` during the test) and every ARM→ARM
     exec edge shimmed — the validation protocol in the field notes. Run
     `scripts/validate_busybox.sh` against the shipped busybox.
   - If they run cleanly → reuse, no rebuild. If libc/kernel/exec mismatch
     → rebuild via the existing `scripts/build_git.sh` /
     `scripts/build_busybox.sh` (already parameterized for aarch64). The
     git transport-helper re-exec and busybox applet self-exec tiers are
     the specific things to prove — they are why this is Fable.
3. **PAL:** `src/platforms/onion/pal_onion.sh` — save root, ROM root
   (`CONTINUITY_ROMS_ROOT`, Sprint 2.0), states root, git bin, platform
   map, `pal_is_online`, `pal_get_platform_map`, `pal_init`. BusyBox-ash.
4. **Platform map:** upgrade `config/platform_maps/onion.json` to **v2**
   (`save_name_style` — confirm `retroarch` against real device files —
   `save_container`, `rom_roots`), per the Sprint 2.0 canonicalization
   contract. (It was deliberately left at schema 1.0 in 2.0 pending this
   bring-up so its format facts get validated here, not asserted from
   memory.)
5. **Enrollment trigger:** `src/platforms/onion/enroll_sd_card.sh` — Onion
   SD-card `setup.json` import adapted to Onion's boot model (NextUI
   `enroll_sd_card.sh` is the template).
6. **Daemon + boot hook:** reuse the core sync engine unchanged; wire an
   Onion boot hook to start the daemon detached (`</dev/null >/dev/null
   2>&1 &`), with the vendored-interpreter fail-open self-test (NextUI
   precedent).
7. **Validate:** `scripts/gate.sh full` green (both privilege passes);
   on-device enrollment + a real save round-trip; then a **cross-device
   sync with the Brick** — which feeds directly into Sprint 2.3.

## Ground rules

- **BusyBox ash floor**; tests both privilege passes (current user +
  `nobody`).
- **Validate binaries against vendored source / under qemu with the host
  git hidden** — never trust a bare `--version`. The field-notes validation
  protocol transfers directly; read it first.
- **Format/name-style validated against the device's REAL save files**, not
  assumed (Sprint 2.0 precedent: the real-repo byte sweep).
- **No remote CI** — the local tiered gate is the verification; `full`
  before any PR.
- **Model:** Fable for the binary/exec-semantics core; the PAL/enrollment/
  daemon shell is Opus-class but fine to keep in this session.
- **ALWAYS in scope:** `docs/platform/nextui-field-notes.md` — the exec-
  semantics traps (transport-helper re-exec, `/proc/self/exe` self-exec,
  the porcelain `-z` rule, fail-open interpreter) transfer to Onion.
- Develop on `claude/sprint-3.1-<slug>`; PR to `main`; **owner merges**.

## Coordination (parallel sessions)

- Runs alongside: RetroDeck 2.1 (Deck), the UI design-system spec, and
  NextUI conflict UI 1.5. **Touch disjoint files** to keep merges clean:
  this sprint owns `src/platforms/onion/**` and `config/platform_maps/
  onion.json`; avoid editing shared `src/core/**` (the whole point of the
  PAL is that bring-up needs no core changes — if you find you *must* touch
  core, flag it, it's an architecture signal).
- **Onion's conflict UI is NOT this sprint.** This is bring-up (PAL +
  enrollment + daemon + sync), exactly like NextUI Phase 1. The Onion
  conflict UI later implements the approved conflict-UX design + the
  cross-platform UI design system, as its own sprint.
- The cross-device Brick↔Onion test is the analogue of Sprint 2.3
  (Brick↔Deck) — a shared payoff once two non-NextUI devices are up.

## How to start

1. Read `CLAUDE.md`; env checks + `git config core.hooksPath .githooks`.
2. Read `docs/roadmap.md` → Sprint 3.1; `docs/platform/nextui-field-notes.md`
   (always in scope); this brief; `docs/sprints/sprint-1.1-1.3-summary.md`
   (NextUI daemon/enrollment precedent).
3. On-device recon (§Device facts), then write + get approval on the Sprint
   3.1 spec before implementing.
