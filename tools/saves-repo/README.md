# Saves-repo companion files

Files in this directory are installed into the USER'S SAVES REPO (the
private repo Continuity syncs into), not shipped in the PAK.

## Daily saves-digest email

GitHub has no native "daily commit digest" email. The substitute is a
scheduled Action in the saves repo that files the digest as a GitHub
issue — GitHub's own notification system then emails it to the repo
owner. No SMTP, no secrets, no third-party services holding anything.

Install (one time, in the saves repo):

1. `saves-digest.yml`  → `.github/workflows/saves-digest.yml`
2. `build_digest.sh`   → `.github/scripts/build_digest.sh`

Behavior:

- Runs daily (13:00 UTC by default — edit the cron line to taste) and
  can be fired manually from the Actions tab for a test run.
- Emails ONLY on days where saves, save states, or conflict artifacts
  were actually archived; device registrations and other housekeeping
  commits never trigger it.
- Digest groups files by the device that pushed them (Continuity's
  `device:` commit trailer), lists state backups separately, and
  flags conflict artifacts with a "both versions preserved" note.
- Yesterday's digest issue is auto-closed when a new one is filed, so
  exactly one stays open.
- Requires GitHub notification emails to be on (Settings →
  Notifications → Watching → Email) — owners watch their own repos by
  default.

`build_digest.sh` is exercised by this project's test suite
(`tests/unit/tools/test_saves_digest.sh`) against Continuity's real
commit format, including spaced filenames and the
only-fire-on-activity gate. If you change the script, change it HERE
and re-copy — the saves repo's copy is a deployment, not a fork.

If you'd rather receive a standalone email (not a GitHub notification),
swap the last workflow step for an SMTP action (e.g.
dawidd6/action-send-mail) with an app-password secret — the digest
generation is unchanged. Trade-off: you hold SMTP credentials as repo
secrets, which the zero-secret issue route avoids.
