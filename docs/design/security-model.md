# Continuity — Security Model

**Status:** Reviewed 2026-07-07 (Phase 1 complete, single-device
fleet live). This document states what the system protects, what it
deliberately does not, and where every credential byte lives. Future
changes touching anything here require re-review (see CLAUDE.md Model
Regimen — security-model changes are a Fable-class escalation).

## Assets

1. **The user's GitHub PAT** — fine-grained, scoped to ONE private
   saves repo, Contents read/write only.
2. **Save data** — SRAM files and opaque save states. Progress, not
   secrets; integrity and availability matter more than
   confidentiality.
3. **The device's execution integrity** — the PAK runs as root on the
   handheld (everything on these devices does).

## Trust boundaries

```
[SD card / device]  ──TLS──►  [github.com]  ◄──TLS──  [other devices]
   the PAT lives here            the saves repo (private)
   physical possession           GitHub account security
   = the boundary                = the boundary

[public project repo] ──TLS──► [device OTA]
   push access to the channel branch = code on every device
```

## Where the PAT lives (complete inventory)

- `setup.json` at the SD root — the delivery vehicle. Deleted on
  successful enrollment (and ONLY on success, so retries survive).
- `.continuity/credentials` inside the repo clone — the working copy,
  chmod 0600 (a no-op on exFAT; meaningful on ext4 platforms).
  Git-ignored via `.continuity/.gitignore`; never committed, never
  pushed.
- Injected into git at invocation time by
  `.continuity/git_credential_helper.sh`, which embeds the credentials
  file PATH, not the token. The remote URL never carries credentials.
- Nowhere else. Enforced by review + tests:
  - preflight masks it to a length (`pat=present(N chars)`) and its
    tests assert the literal token never appears in the report;
  - enrollment logs the repo URL with userinfo stripped, and preflight
    WARNS if a user embeds credentials in `repo_url` (the `pat` field
    is the only sanctioned channel);
  - `GIT_TERMINAL_PROMPT=0` everywhere — git can never interactively
    echo/prompt for it.

## Threats and positions

| Threat | Position |
|---|---|
| **Lost/stolen SD card or device** | Attacker gets the PAT → read/write of ONE private saves repo. No other repos, no account access. Recovery: revoke the PAT (GitHub → instant). This is the accepted, designed worst case. |
| **MITM on device traffic** | All git transport is HTTPS verified against the pinned Mozilla CA bundle shipped in the PAK (never the build host's bundle). A wrong device clock breaks validation loudly — preflight names it. |
| **Malicious OTA** | OTA fetches the PUBLIC project repo anonymously over TLS. `checksums.txt` and the CRLF scan verify INTEGRITY (torn/corrupt copies), not authenticity — they live in the same repo they describe. Authenticity reduces entirely to write access on **main** (devices follow `release/channels.json` there; the pinned-commit design also means an attacker must land a manifest change, not just any branch push): protect the GitHub account (2FA) and protect main. The legacy branch fallback widens this to any branch matching a device's channel name until it is removed in Phase 2. `CONTINUITY_OTA=0` disables the mechanism. Signed manifests are a known possible upgrade if the project ever has multiple maintainers. |
| **Malicious content in the saves repo** (a compromised second device) | Save files are opaque bytes — never parsed, never executed. Filenames DO flow through shell code: all expansions are quoted (spaced/apostrophe names are harness-tested), nothing `eval`s them, and git-output parsing is NUL-delimited. Residual: `find -name` patterns built from basenames could glob within the same directory — bounded to the user's own repo content, accepted. |
| **Compromised build/CI** | CI verifies the committed PAK byte-for-byte against its manifest and runs the shipped busybox through its validation matrix. The CA bundle is fetched from curl.se at build time — a poisoned build HOST could still ship a bad bundle; builds from this container use the pristine upstream source, and the bundle bytes are diffable in git history. |
| **Local log exposure** | Logs live on the same card as the credentials file — no privilege boundary between them on-device. Policy is therefore about REMOTE copies: logs never leave the device, and no log line may contain the PAT (tested). |

## Non-goals (explicit)

- **Encryption at rest on the card.** The card is physical possession;
  the PAT's single-repo scope is the containment. Encrypting saves
  would break the "user owns their data in plain git" principle.
- **Protecting saves from the repo owner.** The user can rewrite their
  own history; conflict artifacts are a safety net against accidents,
  not an audit trail against themselves.
- **Sandboxing on-device.** Everything on these handhelds runs as
  root; we inherit that reality rather than pretend otherwise.

## Known accepted risks

1. **busybox wget reachability probe** (`pal_is_online` fallback after
   ping) does TLS WITHOUT certificate verification. It transfers
   nothing and gates nothing security-relevant — git performs all real
   transfers with full verification. Accepted; do not reuse this probe
   for anything that fetches content.
2. **OTA authenticity = GitHub account security** (above). Accepted
   for a single-maintainer personal project; revisit before any
   multi-user distribution.
3. **exFAT has no permission bits** — `chmod 0600` on the credentials
   file is advisory there. The card itself is the boundary; on ext4
   platforms (RetroDeck) the mode is real.

## Review checklist for future changes

- New log line near credentials/URLs? Strip userinfo; never print the
  PAT; add a masking test.
- New git-output parsing? `-z`/NUL-delimited, tested with
  `Name (USA).ext` and apostrophes (field-notes rule).
- New network fetch? Full TLS verification against the shipped bundle
  — the wget probe is not a precedent.
- New binary in the PAK? checksums.txt entry + validation matrix +
  fail-open posture decision (see busybox/git precedents).
- Anything touching enrollment, credentials, or OTA trust: Fable-class
  review per the Model Regimen.
