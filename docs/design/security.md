# Continuity — Security Model (SUPERSEDED)

**Status:** SUPERSEDED by `docs/design/security-model.md`
(2026-07-07 review: complete PAT inventory, OTA authenticity, threat
table, review checklist). Kept for the Sprint 0.1 historical record —
do not extend this file.
**Original date:** 2026-03-12

## Trust Architecture

### Core Principle

Continuity does not ask users to trust us. The entire security model is built on:

1. **User's repo** — they own it, they control access
2. **User's token** — they create it, they scope it, they revoke it
3. **Minimal blast radius** — worst case is someone reads your game saves

### Why Not OAuth to Cloud Providers

We deliberately avoid OAuth to OneDrive, Google Drive, Dropbox, etc. because:

1. **Trust asymmetry:** Users shouldn't have to trust a small open-source project with access to their cloud storage
2. **Liability:** We don't want to be responsible for securing OAuth tokens to major cloud providers
3. **Complexity:** OAuth on headless devices requires either a proxy backend or device authorization grant — both add infrastructure we'd have to maintain
4. **Scope creep:** Cloud provider tokens often grant broader access than needed, even with app-folder scoping

GitHub PATs scoped to a single repo containing only `.srm` files solve the problem with zero trust required beyond "I trust GitHub."

---

## Token Lifecycle

### Creation

User creates a fine-grained Personal Access Token on GitHub:
- **Resource:** Only the saves repository
- **Permission:** Contents (read and write)
- **Expiry:** 1 year (recommended)

### Storage on Device

| Platform | Location | Protection |
|----------|----------|-----------|
| NextUI | `$CONTINUITY_REPO_DIR/.continuity/credentials` | Hidden dotfile, gitignored (FAT32, no real protection) |
| Onion OS | `$CONTINUITY_REPO_DIR/.continuity/credentials` | Same |
| RetroDeck | `$CONTINUITY_REPO_DIR/.continuity/credentials` | Linux file permissions (0600), gitignored |
| Android | App internal storage | Android sandbox |

**Constrained device reality:** On FAT32 SD cards, there is no meaningful file-level protection. The PAT is effectively plaintext. This is acceptable because:
- The PAT can only access one repo
- That repo contains only game save files
- The PAT expires
- The user can revoke it instantly from GitHub

### Rotation

The daemon tracks token expiry. When within 30 days of expiry:
- Constrained devices: Show message on next sync status check via Tool PAK
- RetroDeck: Desktop notification
- Android: App notification

### Revocation

Two paths:
1. **Uninstall GitHub App** from the repo — immediately visible, one click
2. **Delete PAT** from GitHub developer settings

Either path instantly kills the device's ability to sync. No cleanup on the device needed — the local git repo still works, it just can't push/pull.

---

## Device Identity

Each device registers in `.continuity/devices/<name>.json` in the repo. This is:
- **Not a security mechanism** — it's for sync coordination and conflict attribution
- **User-chosen name** — set during enrollment (e.g., "my-brick", "my-deck")
- **Visible in the repo** — user can see all linked devices

### "Sold My Device" Scenario

1. User sells TrimUI Brick, forgets to wipe
2. Buyer has PAT on SD card, can sync to the repo
3. **Mitigation:** User notices unfamiliar commits in their repo, or notices the device in `.continuity/devices/`
4. **Fix:** Delete the PAT from GitHub settings. Done.
5. **Prevention:** Document the wipe procedure clearly. Add "Unlink Device" option to Tool PAK UI.

---

## GitHub App Scope

The Continuity GitHub App requests minimal permissions:

| Permission | Level | Why |
|-----------|-------|-----|
| Contents | Read & Write | Push/pull save files |
| Metadata | Read | Required by GitHub for all Apps |

**Not requested:**
- Issues, Pull Requests, Actions, Packages, Pages, Secrets, Environments, etc.
- No organization-level access
- No cross-repo access

The App is installed on a single repository chosen by the user. It cannot access any other repository, even if the user owns many.

---

## Attack Surface Summary

| Component | Attack Vector | Risk | Notes |
|-----------|--------------|------|-------|
| PAT on SD card | Physical access | Low | Scoped to one repo of save files |
| Git transport | MITM | None | HTTPS to github.com, certificate pinned by git |
| Local web setup | Network sniffing during enrollment | Low | One-time, local network only, PAT in POST body |
| `.continuity/` in repo | Repo collaborator | Low | Only user has access to private repo |
| BusyBox httpd | Network attack during setup | Low | Only runs briefly during enrollment, localhost preferred |

### Residual Risks (Accepted)

1. **FAT32 has no file permissions.** Anyone with physical access to the SD card can read the PAT. Accepted because the PAT's scope limits damage to game saves.
2. **Local web setup transmits PAT over HTTP (not HTTPS).** Accepted because it's local network only, runs for seconds, and is a one-time operation. Users on untrusted networks should use the SD card method.
3. **Git clone contains full history.** A stolen device has access to all previous save versions, not just current. Accepted because save file history has no security sensitivity.
