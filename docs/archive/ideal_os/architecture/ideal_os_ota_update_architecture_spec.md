# Ideal OS – OTA Update Architecture Specification

## Spec Metadata
- **Version:** 1.0
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** schema_version convention conflicts with CLAUDE.md (DF-2); schema migration ownership split with Session Manager (MB-8); hash field naming divergence (DF-4)

## Purpose

This document defines the architecture for the Ideal OS OTA update system.

The OTA subsystem exists to make device testing, user upgrades, and long-term maintenance practical without requiring users to back up data and reflash SD cards for every release.

For Ideal OS, OTA is a core platform capability.

---

## Goals

The OTA system must:

- allow in-place upgrades from one Stardate release to another
- support frequent testing builds during development
- preserve user data wherever possible
- validate update integrity before apply
- support schema migrations when runtime data changes
- distinguish between stable, beta, and dev channels
- avoid forcing full device reflash for normal updates

---

## Non-Goals

The OTA system is not initially required to:

- support arbitrary downgrade across all past releases
- support partial recovery from every possible power-loss scenario
- update bootloader or vendor firmware in early versions
- sync user ROM collections to the cloud

These may be considered later, but they are not the initial design target.

---

## Versioning Model

Ideal OS uses Stardate versioning.

Format:

```text
Stardate YYMM.R
```

Examples:

- Stardate 2601.1
- Stardate 2601.2
- Stardate 2602.1

OTA logic should compare installed and available Stardates using a normalized internal version format.

Example internal mapping:

```text
2601.1 -> major_cycle=2601, revision=1
```

The updater should not rely on string comparison alone.

---

## Update Strategy

## Recommended Initial Model

Ideal OS should begin with a **package-oriented OTA architecture** layered on top of a full-system release model.

That means:

- releases are defined as complete system states
- updates are delivered as one or more versioned packages
- the updater decides which packages must change
- migration hooks are triggered when package or schema versions change

This is the best compromise between simplicity and future flexibility.

---

## Why Not Full Reflash OTA Only

A pure image-replacement approach would be simpler at first, but it has major drawbacks:

- larger downloads n- longer update times
- more wear on storage
- harder rollback for individual subsystems
- slower iteration during development

It also works against your goal of fast testing on-device.

---

## Why Not Fully Granular Micro-Packages Immediately

A highly granular package system would be powerful, but too complex for the first implementation.

Too many package boundaries early can create:

- dependency headaches
- fragile release coordination
- more migration complexity

So the initial package design should be **coarse but modular**.

---

## Initial Update Units

Recommended update units:

```text
base
launcher
session-manager
library
assets
updater
config
```

These map cleanly to the repository structure and to the main user-visible system areas.

---

## Update Channels

Ideal OS should support channels from the beginning.

Required channels:

- stable
- beta
- dev

Channel behavior:

### stable

Public releases intended for broad users.

### beta

Release candidates and near-production testing.

### dev

Frequent internal or experimental builds for active development.

Recommended config path:

```text
config/updater/channels/
```

Recommended release path:

```text
release/channels/
```

---

## Manifest Architecture

The OTA system should use two manifest layers.

### 1. Channel Manifest

Defines the latest release available for a channel.

Example:

```json
{
  "_schema_version": "1.0",
  "channel": "stable",
  "latest_stardate": "2601.1",
  "release_manifest": "2601.1.json"
}
```

Purpose:

- lightweight channel lookup
- fast comparison against installed version

---

### 2. Release Manifest

Defines the packages, checksums, schema versions, and migration requirements for a specific release.

Example:

```json
{
  "_schema_version": "1.0",
  "stardate": "2601.1",
  "packages": [
    {
      "name": "launcher",
      "version": "2601.1",
      "filename": "launcher-2601.1.pkg",
      "sha256": "..."
    },
    {
      "name": "session-manager",
      "version": "2601.1",
      "filename": "session-manager-2601.1.pkg",
      "sha256": "..."
    }
  ],
  "schema_versions": {
    "library": "1.0",
    "sessions": "1.0",
    "updater": "1.0"
  },
  "migrations": [
    "library-v1.0",
    "sessions-v1.0"
  ],
  "minimum_updater_version": "2601.1"
}
```

Purpose:

- define exact update contents
- validate integrity
- trigger migrations
- gate incompatible updater versions

---

## Installed System State

The device should maintain an installed-state record.

Recommended tracked values:

- installed Stardate
- current channel
- installed package versions
- runtime schema versions
- last successful update timestamp
- last failed update details

Suggested runtime path:

```text
runtime/updater/schema/installed-state.json
```

---

## OTA Flow

Recommended high-level flow:

```text
User opens Settings > Check for Updates
→ updater reads installed-state
→ updater fetches channel manifest
→ compare installed Stardate vs latest available
→ if newer release exists, fetch release manifest
→ determine required packages
→ verify compatibility rules
→ download packages to staging
→ validate checksum/signature
→ apply package updates
→ run migrations if needed
→ update installed-state
→ reboot or restart services as required
```

---

## Staging Architecture

Updates should never apply directly from the download stream.

Packages should first be downloaded into a staging area.

Recommended staging layout:

```text
runtime/updater/staging/
├── current/
├── downloaded/
├── manifests/
└── logs/
```

Purpose:

- isolate partially downloaded files
- support validation before apply
- aid diagnostics during failed updates

---

## Integrity and Trust

At minimum, all OTA payloads must support:

- SHA-256 checksum verification
- manifest/package consistency checks
- channel manifest validation

Future enhancement:

- signed manifests
- signed packages

Recommended initial order:

### Phase 1

- checksums
- HTTPS transport
- strict filename and manifest validation

### Phase 2

- detached signature verification for manifests and packages

---

## Apply Strategy

## Initial Recommendation

Use a **download → stage → apply → reboot** model.

This is simpler and safer than trying to hot-swap every running subsystem.

Recommended behavior:

- updater downloads packages
- updater validates them
- updater writes package files into target locations or package store
- updater schedules restart or reboot
- updater runs migrations at controlled point before final handoff

This gives predictable behavior for early development.

---

## Runtime Data Preservation

User data should be preserved by design.

Protected data should include:

- ROMs
- save files
- save states
- favorites
- collections
- boxart cache where practical
- updater state
- library metadata database

This is why repository and runtime separation matter.

System updates should replace code/config/assets without wiping user data.

---

## Migration System

OTA updates will eventually change runtime schemas.

Examples:

- session metadata gains new fields
- library database changes indexing format
- updater state adds rollback markers

Migration support is therefore required from the start.

### Migration Responsibilities

A migration subsystem should:

- detect schema version differences
- run ordered migrations
- log outcomes
- fail safely if migration cannot complete

Recommended paths:

```text
runtime/filesystem/migrations/
tools/migration/
```

Recommended migration metadata fields:

- migration name
- from schema version
- to schema version
- execution timestamp
- result

---

## Rollback Strategy

Rollback should be scoped realistically.

## Initial Recommendation

Support **update failure recovery**, not full arbitrary rollback.

Meaning:

- if validation fails, do not apply
- if apply fails before commit, preserve existing system state
- if migration fails, stop activation and log failure where possible

For the first release, full multi-version rollback is optional and can be deferred.

A practical early strategy is:

- keep previous manifest record
- keep backup of replaced package files where feasible
- mark failed update state
- expose recovery guidance

Future enhancement:

- A/B system partitions or dual-slot activation

That is powerful but likely too heavy for the initial implementation.

---

## Reboot and Activation Model

Some updates may require reboot; others may only require UI restart.

The updater should classify update types.

### Update Classes

#### soft-restart

Examples:

- launcher-only asset changes
- non-critical UI config changes

#### service-restart

Examples:

- library subsystem updates
- background service updates

#### full-reboot

Examples:

- base package changes
- session-manager changes
- system integration changes
- updater self-update

For the first implementation, it is acceptable to default most updates to **full reboot** for safety.

---

## Updater Self-Update

Updater self-update is a special case.

The release manifest should support a minimum updater version field.

If the installed updater is too old to safely process the manifest, the system should:

- refuse the update, or
- require an intermediate updater update path

This prevents old updater logic from misapplying newer package formats.

---

## Network Behavior

OTA checks should be explicit and user-controlled initially.

Recommended first behavior:

- manual "Check for Updates"
- optional background notification later

This avoids surprising users and simplifies debugging.

Future enhancements:

- check on boot when on Wi-Fi
- optional scheduled check
- release notes preview before update

---

## Logging and Diagnostics

The updater must produce readable logs.

Recommended log categories:

- manifest fetch
- version compare
- package download
- checksum verify
- staging
- apply
- migration
- reboot scheduling

Recommended path:

```text
runtime/updater/staging/logs/
```

Developer tooling should eventually support exporting or viewing the last update log from the device.

---

## UX Expectations

OTA must feel like an appliance feature.

User flow should be simple:

```text
Settings
→ Check for Updates
→ New version found: Stardate 2601.2
→ View summary
→ Download and Install
→ Reboot
→ Updated successfully
```

Good OTA UX includes:

- visible current Stardate
- visible current channel
- clear progress display
- concise failure messages
- recovery instructions for unrecoverable errors

---

## Development Workflow Benefits

This architecture is not only for end users.

It directly helps development by enabling:

- pushing dev-channel builds to your Brick quickly
- testing incremental changes without reflash
- validating migration behavior early
- separating packaging problems from code problems

That makes it one of the most valuable subsystems to define early.

---

## Initial Implementation Phases

### Phase 1 – Foundation

- define installed-state format
- define channel manifest format
- define release manifest format
- implement manual update check
- implement download and checksum validation

### Phase 2 – Basic Apply

- implement staging area
- implement package apply logic
- support reboot-based activation
- write update logs

### Phase 3 – Migration Support

- detect schema changes
- run ordered migrations
- record migration results

### Phase 4 – Channel Workflow

- stable/beta/dev switching
- dev build packaging
- release note display

### Phase 5 – Hardening

- updater self-update rules
- package signature verification
- failure recovery improvements
- optional rollback improvements

---

## Canonical Paths Summary

```text
src/updater/
config/updater/
runtime/updater/
runtime/filesystem/migrations/
scripts/ota/
release/manifests/
release/channels/
packages/updater/
```

---

## Recommendation

Ideal OS should treat OTA as a modular subsystem with:

- coarse package boundaries
- channel manifests
- per-release manifests
- staging and validation
- migration support
- reboot-based activation initially

This gives you a practical path to rapid on-device testing and a smooth user upgrade experience without overengineering the first release.

