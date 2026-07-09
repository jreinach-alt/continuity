# Ideal OS – Cloud Sync & Cross‑Device Continuity Specification

## Spec Metadata
- **Version:** 1.0
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** game_id format mismatch — bare name vs system:name (DF-1); save state file path conflicts with Session Manager (MB-1); dual sync queue with Task Scheduler (MB-5); own Background Worker conflicts with Task Scheduler coordination (DO-8); device_id never defined (DF-6)

## Purpose

This document defines the architecture and behavior of the **Ideal OS Cloud Sync system**.

The goal is to allow players to move between devices seamlessly while protecting gameplay progress and minimizing disruption.

This subsystem provides:

- automatic save backup
- optional emulator state backup
- cross-device gameplay continuity
- safe conflict resolution

Cloud Sync is designed to be **non-intrusive and appliance-friendly**.

---

# Design Goals

The system must:

• protect user progress automatically • support multiple cloud providers • work in the background with minimal UI • avoid interrupting gameplay • minimize power and bandwidth usage • safely handle sync conflicts

---

# Non Goals (Initial Release)

The first implementation does NOT require:

• real-time streaming synchronization • unlimited cross-device suspend portability • cloud ROM hosting • full device mirroring

Initial focus is **game progress protection and optional state portability**.

---

# Core Concept

The system maintains a **local artifact index** of files that should be synchronized.

Artifacts are uploaded to the user's configured cloud provider.

Artifacts may later be downloaded by another Ideal OS device.

---

# Artifact Types

Artifacts are categorized by stability and portability.

## Tier 1 – Canonical Game Saves (Required)

These are safe to sync across devices.

Examples:

• SRAM files • emulator battery saves • PSX memory cards • system save directories

These should always be synchronized.

---

## Tier 2 – Emulator Save States (Optional)

These represent mid-session snapshots.

Examples:

• RetroArch save states • emulator-specific state files

These may depend on:

• emulator version • core version • configuration

Initial implementation should treat them as **experimental**.

---

## Tier 3 – Session Metadata (Future)

Optional future artifacts:

• session manager metadata • resume stack entries • session thumbnails

These allow cross-device resume continuity.

---

# Sync Modes

The user should be able to choose a sync policy.

## Saves Only

Synchronizes:

• canonical game saves

This is the safest and recommended default.

---

## Saves + States

Synchronizes:

• game saves • emulator save states

Recommended for users running Ideal OS on multiple devices.

---

## Full Continuity (Future)

Synchronizes:

• saves • save states • session metadata

Allows seamless cross-device session continuation.

---

# Provider Architecture

Cloud providers must be implemented as adapters.

```
Sync Manager
 ├── Provider Interface
 │   ├── OneDrive Adapter
 │   └── Google Drive Adapter
```

Provider interface responsibilities:

• authenticate user • upload artifact • download artifact • list artifacts • delete artifact • fetch metadata

---

# Initial Supported Providers

Recommended starting providers:

• OneDrive • Google Drive

Both have strong SDK support and widespread user accounts.

Future providers may include:

• Dropbox • self-hosted WebDAV

---

# Local Sync Architecture

```
Sync Manager
├── Artifact Index
├── Upload Queue
├── Download Queue
├── Provider Adapter
├── Conflict Resolver
├── Power Event Hooks
└── Background Worker
```

---

# Artifact Index

The artifact index tracks all syncable files.

Suggested path:

```
runtime/sync/index.json
```

**`artifact_id` convention:** `artifact_id` is composed as `game_id + ":" + artifact_type` (e.g., `snes:super_metroid:save`). The first two colon-delimited segments are the `game_id`; the last segment is the `artifact_type`. Game names must not contain colons.

Example record:

```
{
  "_schema_version": "1.0",
  "artifact_id": "snes:super_metroid:save",
  "artifact_type": "save",
  "system": "snes",
  "game_id": "snes:super_metroid",
  "local_path": "/userdata/saves/snes/super_metroid.srm",
  "updated_at": "2026-03-10T21:25:11Z",
  "last_synced": "2026-03-10T21:24:03Z",
  "device_id": "brick-a",
  "sha256": "..."
}
```

---

# Change Detection

Artifact changes may be detected through:

• file modification time • file hashing • emulator exit hooks

Recommended approach:

Start with **mtime detection** and upgrade later if needed.

---

# Upload Queue

When a change is detected:

1. artifact marked dirty
2. artifact added to upload queue
3. background worker processes queue

Queue path:

```
runtime/sync/queue/
```

---

# Background Upload Behavior

Uploads should occur when:

• device idle • user returns to launcher • WiFi available • periodic background window

Uploads should NOT interrupt gameplay.

---

# Shutdown Sync Behavior

**Ownership note:** The Task Scheduler owns the power-event pipeline and calls Cloud Sync's `flush_on_power_event()` callback as the second participant (after Session Manager). Cloud Sync does not independently listen for power events. The scheduler enforces the timeout and skip behavior.

When the scheduler invokes the sync flush callback:

1. Check upload queue
2. Attempt fast upload flush within scheduler-allocated timeout
3. Report completion or timeout back to scheduler

The scheduler may show a "Syncing saves..." overlay via the Notification System during the flush window. The "B = Skip" behavior is handled by the scheduler's skip policy, not by Cloud Sync directly.

Timeout recommendation: 2–5 seconds.

If uploads complete earlier, the scheduler proceeds immediately.

---

# Startup Pull Behavior (Future Phase)

On boot or manual sync:

1. fetch remote manifest
2. compare artifact timestamps
3. detect newer remote artifacts

Possible actions:

• auto-download • prompt user • ignore

Never silently overwrite local progress.

---

# Conflict Resolution

Conflicts occur when:

• local version changed • remote version also changed

Initial conflict policy:

```
if remote newer and local unchanged:
    download

if local newer and remote unchanged:
    upload

if both changed:
    prompt user later
```

Future versions may offer:

• version history • keep both

---

# Metadata Requirements

Artifacts must include metadata fields:

• artifact type • system • game ID (`system:game_name` format) • ROM fingerprint (sha256) • timestamp (updated_at) • device ID • sha256 checksum

This allows accurate conflict resolution.

---

# PSX Considerations

PlayStation titles use memory card saves.

Safe artifacts:

• memory card files

Risky artifacts:

• mid-session save states

Recommended default:

Sync memory cards only.

Allow optional save-state sync with warnings.

---

# Performance Considerations

Cloud sync must avoid degrading gameplay.

Recommended safeguards:

• batch small updates • throttle background uploads • pause during active gameplay • limit bandwidth usage

---

# Security

Initial implementation should include:

• HTTPS transport • provider authentication tokens • artifact hashing

Future improvements:

• artifact encryption • zero-knowledge storage

---

# User Interface

Cloud Sync settings menu should include:

```
Cloud Sync

Provider: Google Drive
Mode: Saves Only
Last Sync: 2 minutes ago

[Check Now]
[Change Provider]
[Sync Mode]
```

---

# Example User Flows

## First Setup

User enables Cloud Sync

→ select provider → authenticate → initial upload

---

## Normal Use

Player finishes game session

→ save file modified → artifact queued → uploaded in background

---

## Shutdown

Power button pressed

→ quick sync attempt → shutdown

---

## New Device

User logs into provider

→ remote artifacts detected → downloaded → progress restored

---

# Development Phases

## Phase 1 – Local Sync Engine

• artifact index • change detection • upload queue

---

## Phase 2 – Cloud Upload

• provider adapters • background upload • shutdown flush

---

## Phase 3 – Expanded Artifacts

• favorites • collections • optional save states

---

## Phase 4 – Cross Device Pull

• remote artifact detection • safe download logic

---

## Phase 5 – Full Continuity

• session metadata • resume stack sync

---

# Canonical Paths

```
src/sync/
runtime/sync/
config/sync/
```

---

# Recommendation

Cloud Sync should start simple but be architected for expansion.

The initial focus should be:

• reliable save backup • minimal disruption • safe cross-device progress recovery

Once stability is proven, Ideal OS can expand toward seamless session portability across devices.

