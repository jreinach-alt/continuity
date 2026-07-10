# Cross-Device Validation Protocol — Brick ⇆ Deck

**Sprint 2.3 hardware validation.** This is the owner-run counterpart to
`tests/integration/test_cross_device_flow.sh`: the same claims, on the two
real devices sharing one private saves repo. The automated test proves the
mapper + engine + both real PALs headlessly; this proves the whole path on
hardware — enrollment, the daemons, real ROMs, and real SRAM bytes.

**What you are proving:** the same save on two different-platform devices.
A MinUI-named save on the TrimUI Brick becomes ONE canonical repo file and
lands on the Steam Deck under its RetroArch-native name (and the reverse),
with ROM-anchored sparse materialization both ways, and a cross-format
divergence on one game collapses to a single conflict.

Companion docs: `docs/design/save-format-canonicalization.md` (the
contract), `docs/design/nextui-format-matrix.md` (the name shapes),
`docs/platform/nextui-field-notes.md` (Brick traps — read before Brick
work; note especially the **SRAM flush timing** section: an in-game save
does NOT hit the `.srm` until you quit the game, sleep the device, or open
the MENU).

Throughout, replace `USER/saves-repo` with your private repo and pick two
real games — one shared by both devices, one exclusive to each.

---

## 0. Prerequisites

- Both devices on WiFi, clocks correct (a wrong clock breaks TLS — the
  Brick preflight says so on screen).
- One private GitHub saves repo, and a fine-grained PAT scoped to it
  (Contents: read/write). Same repo for both devices.
- Pick your test games:
  - **Shared game** present on BOTH devices — e.g. `Super Metroid (USA)`
    (SNES). Confirm the ROM exists in the Brick's `Roms/SFC/` (or
    `Roms/Super Nintendo Entertainment System (SFC)/`) and in the Deck's
    ES-DE `snes/` roms folder.
  - **Brick-only game** — a game whose ROM is on the Brick but NOT the
    Deck (e.g. a GB title the Deck lacks).
  - **Deck-only game** — a game whose ROM is on the Deck but NOT the Brick
    (e.g. a PS1 title the Brick lacks).

Keep a terminal on the Deck (`journalctl --user -u continuity -f`) and the
Brick log to hand (`/mnt/SDCARD/.continuity/continuity.log`).

---

## 1. Enroll both devices to the SAME repo

**Brick (SD-card `setup.json`):** write `setup.json` at the SD-card root
with your repo URL, PAT, and a device name, then boot:

```json
{
  "repo_url": "https://github.com/USER/saves-repo.git",
  "pat": "github_pat_xxx",
  "device_name": "brick"
}
```

On boot the daemon imports it, clones the repo, registers the device
(`.continuity/devices/brick.json` is pushed), and deletes `setup.json`.
Confirm in `.continuity/enroll.log` and in the repo's `.continuity/devices/`
on GitHub.

**Deck (CLI):**

```sh
printf '%s' 'github_pat_xxx' > /tmp/pat
src/platforms/retrodeck/enroll_retrodeck.sh \
    --repo-url https://github.com/USER/saves-repo.git \
    --device-name deck --pat-file /tmp/pat
shred -u /tmp/pat
```

Confirm the systemd unit is active (`systemctl --user status continuity`)
and `.continuity/devices/deck.json` appears on GitHub. Both devices should
now show two entries under `.continuity/devices/`.

---

## 2. Brick → Deck  (MinUI name ⇒ canonical ⇒ RetroArch name)

1. On the **Brick**, play the **shared game** and make an in-game save.
   **Then quit the game** (or open the MENU / sleep) — this is what
   actually flushes the `.srm`. The daemon's 30 s poll then commits and
   pushes it.
2. Watch `.continuity/continuity.log` for the poll → commit → push, and on
   GitHub confirm the file landed under the **canonical** name and system:
   `snes/Super Metroid (USA).srm` (raw SRAM, `.srm`, canonical system
   `snes` — NOT the Brick's `SFC/…​.sfc.sav`). A `.rtc` sibling appears too
   if the game uses RTC.
   - ✅ PASS: canonical `snes/<game>.srm` present; NO `.sfc.sav` in the repo.
3. On the **Deck**, wait for the pull (or restart the unit) and confirm the
   save materialized under its **RetroArch-native** name in the Deck's
   saves folder: `…/saves/snes/Super Metroid (USA).srm`.
4. **Byte-match** the two devices:

   ```sh
   # Brick (over SSH/ADB, or read the card): sha256sum of the source .srm
   sha256sum "/mnt/SDCARD/Saves/SFC/Super Metroid (USA).sfc.sav"
   # Deck: sha256sum of the materialized save
   sha256sum "$HOME/retrodeck/saves/snes/Super Metroid (USA).srm"
   ```

   - ✅ PASS: the two hashes are identical (same raw SRAM bytes; only the
     container name differs).
5. **Sparse check (Brick-only game):** confirm the Deck did NOT receive the
   Brick-only game's save — no such file under the Deck's saves folder,
   because the Deck has no matching ROM.
   - ✅ PASS: Brick-only save absent on the Deck.

---

## 3. Deck → Brick  (RetroArch name ⇒ canonical ⇒ MinUI name)

1. On the **Deck**, play the **shared game** (or the Deck-only game for the
   sparse half) and make an in-game save; the inotify daemon commits and
   pushes on change. Confirm on GitHub the canonical
   `snes/Super Metroid (USA).srm` updated (and, for the Deck-only PS1 game,
   `ps1/<game>.srm` appears — canonical system `ps1`, even though the
   Deck's local folder is `psx`).
2. On the **Brick**, trigger a pull (reboot, or the Tool PAK's manual
   sync). Confirm the save materialized under the **MinUI-native** name
   with the **ROM extension embedded**, reconstructed from the Brick's own
   ROM: `/mnt/SDCARD/Saves/SFC/Super Metroid (USA).sfc.sav`.
   - ✅ PASS: MinUI-native `<rom>.<ext>.sav` name on the Brick.
3. **Byte-match** again (Deck source vs Brick materialized):

   ```sh
   # Deck
   sha256sum "$HOME/retrodeck/saves/snes/Super Metroid (USA).srm"
   # Brick
   sha256sum "/mnt/SDCARD/Saves/SFC/Super Metroid (USA).sfc.sav"
   ```

   - ✅ PASS: identical hashes.
4. **Reverse sparse check (Deck-only game):** confirm the Brick did NOT
   receive the Deck-only game's save (no matching ROM on the Brick).
   - ✅ PASS: Deck-only save absent on the Brick.

---

## 4. Cross-format divergence collapses to ONE conflict

This proves canonicalization holds through the conflict path: the Brick
writes the shared game as `.sfc.sav` and the Deck writes it as `.srm`, yet
both map to the SAME canonical `snes/Super Metroid (USA).srm`, so a
genuine divergence produces ONE conflict, not two.

1. Put both devices **offline** (WiFi off).
2. On **each** device, make a DIFFERENT in-game save for the shared game
   and flush it (Brick: quit the game; Deck: the save writes on change).
   You now have two different SRAM byte-sets for one game, one per device.
3. Bring **one** device online first (say the Deck) and let it push — it
   becomes the canonical version.
4. Bring the **other** device (the Brick) online. Its push is rejected
   (histories diverged); the daemon reconciles and the conflict handler
   preserves your local version.
5. On GitHub, confirm for the shared game there is exactly **one**
   `.local` file and **one** `.conflict` file, both at the canonical path:
   - `snes/Super Metroid (USA).srm.brick.local` (your Brick bytes)
   - `snes/Super Metroid (USA).srm.conflict`
   Open the `.conflict` and confirm `"identity": "snes/Super Metroid (USA)"`
   and `"class": "srm"` — one grouped identity, NOT one entry per
   extension.
   - ✅ PASS: exactly one `.local` + one `.conflict`; canonical holds the
     first-pushed bytes, the `.local` holds the other device's bytes
     (nothing overwritten).
6. On the **Brick's** Tool PAK conflict UI, confirm the shared game shows
   as a single conflicted entry grouped by game identity, with device
   attribution (see `docs/design/conflict-resolution-experience.md`). The
   try/promote/resolve mechanics themselves are validated separately
   (Sprint 1.5); here you are only confirming the cross-device conflict is
   preserved and correctly grouped.

---

## What to capture in the report

For each of §2–§4: the on-repo canonical path (screenshot the GitHub file
list), the two `sha256sum` outputs side by side, and the relevant log
lines (`.continuity/continuity.log` on the Brick; `journalctl --user -u
continuity` on the Deck). A PASS is: canonical names on-repo, native names
on-device, identical hashes across devices, sparse skips honored, and a
single grouped conflict. Any mismatch is a defect — file it against Sprint
2.3 with the hashes and the two device paths.
