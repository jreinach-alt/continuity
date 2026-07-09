# Ideal OS – Session Manager Technical Architecture Specification

## Spec Metadata
- **Version:** 1.0
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** Save state file paths conflict with Cloud Sync (MB-1); power event orchestration ownership (MB-2); game launch orchestration unowned (MB-3); `game_id` format mismatch (DF-1); `schema_version` convention (DF-2); emulation API dependency undefined (DO-2)

## Purpose

This document defines the technical architecture for the Ideal OS Session Manager.

The Session Manager is the subsystem that most strongly differentiates Ideal OS from a standard launcher-based handheld firmware. It is responsible for turning the TrimUI Brick into a resume-centric appliance where players can suspend games, switch contexts, and return instantly.

This subsystem should be treated as a first-class platform service.

---

## Goals

The Session Manager must:

- support instant suspend/resume behavior
- restore players to the exact gameplay context they left
- support multiple suspended games through a resume stack
- integrate with launcher navigation and game switching
- preserve session metadata across reboot where possible
- fail safely when state files are invalid or missing
- expose predictable interfaces for launcher, emulator, and power-management layers

---

## Non-Goals

The Session Manager is not initially required to:

- support every emulator core on day one
- preserve volatile emulator state that cannot be represented through save states
- allow unlimited concurrent sessions
- synchronize sessions across devices
- implement cloud backup

The first implementation should prioritize reliability over completeness.

---

## Core Concepts

### Session

A **session** represents a suspendable gameplay context for a specific title.

A session includes:

- game identity
- platform/system
- emulator/core identity
- save state reference
- last played timestamp
- session status
- optional preview metadata

---

### Active Session

An **active session** is the currently running gameplay context.

There may only be one actively running session at a time.

---

### Suspended Session

A **suspended session** is not currently running but has enough persisted state to be resumed later.

---

### Resume Stack

The **resume stack** is the ordered collection of suspended and recent sessions presented to the user for fast switching.

The resume stack should be ordered primarily by recency.

---

## Functional Requirements

### Required for Initial Implementation

- launch a game and create session context
- suspend current game on command
- persist session metadata
- resume suspended game
- resume last-played game after reboot
- maintain ordered list of suspended/recent sessions
- prune invalid sessions
- recover gracefully when state restore fails

### Strongly Recommended Early

- auto-save on sleep
- auto-save on launcher return
- game switcher integration
- session preview metadata for UI

### Future Enhancements

- per-session thumbnails/screenshots
- per-session notes/debug data
- pinned sessions
- session expiration policies by system

---

## High-Level Architecture

```text
Launcher
  ↕
Session API
  ↕
Session Manager
  ├── Session Registry
  ├── State Persistence Layer
  ├── Resume Stack Manager
  ├── Validation & Recovery
  └── Power Event Integration
  ↕
Emulator Runtime Layer
```

---

## Module Responsibilities

### 1. Session API

Path:

```text
src/session/api/
```

Purpose:

Provide stable interfaces for launcher and system code.

Example responsibilities:

- create session
- suspend current session
- resume session by ID
- list recent/suspended sessions
- discard session
- mark current session as failed

The launcher should not manipulate session files directly.

---

### 2. Session Registry

Path:

```text
src/session/registry/
```

Purpose:

Maintain authoritative metadata for all known sessions.

Responsibilities:

- assign session IDs
- record metadata
- update recency ordering
- track session status
- reconcile metadata with runtime files

---

### 3. State Persistence Layer

Path:

```text
src/session/persistence/
```

Purpose:

Manage the storage and retrieval of save state artifacts and session metadata.

**Save state file ownership:** Session Manager references emulator save states **in-place** at their native emulator paths (e.g., `/userdata/saves/snes/super_metroid.state`). It does NOT copy save states into its own store. The `state_path` field in session metadata is an absolute path to the emulator's native save location. This ensures Cloud Sync and Session Manager always reference the same file — single source of truth, no stale copies.

Session metadata files (e.g., `metadata.json`, `sessions-index.json`) are owned by the Session Manager and stored under `runtime/sessions/`.

Responsibilities:

- resolve session storage paths (reference emulator save locations in-place)
- write session metadata atomically
- validate presence of referenced save state files
- load metadata for resume

---

### 4. Resume Stack Manager

Path:

```text
src/session/stack/
```

Purpose:

Provide ordering and policy for suspended sessions.

Responsibilities:

- maintain most-recent-first ordering
- enforce max session count
- prune expired or invalid entries
- expose list for launcher UI

---

### 5. Validation & Recovery

Path:

```text
src/session/recovery/
```

Purpose:

Handle corrupt, missing, or incompatible session state.

Responsibilities:

- verify resumability before resume
- fall back to normal launch when needed
- mark broken sessions
- remove orphaned metadata/state files

---

### 6. Power Event Integration

Path:

```text
src/session/power/
```

Purpose:

Hook suspend logic into sleep, shutdown, and launcher transition events.

**Ownership note:** The Task Scheduler owns the power-event sequence (sleep/shutdown pipeline). Session Manager registers as a **priority participant** — it is always called first in the sequence. Session Manager does not independently listen for OS-level power events; it exposes a `persist_on_power_event()` callback that the scheduler invokes.

Responsibilities:

- auto-save when called by the scheduler's power-event pipeline
- coordinate timing with emulator exit/suspend flow
- avoid duplicate session writes

---

## Canonical Runtime Layout

Recommended runtime structure:

```text
runtime/sessions/
├── registry/
│   ├── sessions-index.json
│   └── last-session.json
├── active/
│   └── current-session.json
├── store/
│   └── <session-id>/
│       ├── metadata.json            # session record (state_path references emulator save in-place)
│       ├── state.preview.png        # optional future
│       └── diagnostics.json         # optional future
└── logs/
    └── session-events.log
```

---

## Data Model

### Session ID

Each session should have a unique ID.

Recommended format:

```text
<system>-<game-hash>-<timestamp>
```

Example:

```text
snes-a13fd98c-20260310T211455Z
```

This is stable enough for debugging while remaining unique.

---

### Session Metadata Schema

Example `metadata.json`:

```json
{
  "_schema_version": "1.0",
  "session_id": "snes-a13fd98c-20260310T211455Z",
  "game_id": "snes:super_metroid",
  "display_name": "Super Metroid",
  "system": "snes",
  "core": "snes9x2005_plus",
  "rom_path": "/Roms/SNES/Super Metroid.sfc",
  "state_path": "/userdata/saves/snes/super_metroid.state",
  "status": "suspended",
  "created_at": "2026-03-10T21:14:55Z",
  "updated_at": "2026-03-10T21:26:11Z",
  "last_resumed_at": "2026-03-10T21:20:03Z",
  "resume_count": 2,
  "launcher_context": {
    "last_collection": "recent",
    "last_cursor": "super_metroid"
  }
}
```

---

### Session Status Values

Recommended statuses:

- `active`
- `suspending`
- `suspended`
- `resuming`
- `failed`
- `discarded`

These statuses help prevent ambiguous transitions.

---

### Session Index Schema

Example `sessions-index.json`:

```json
{
  "_schema_version": "1.0",
  "max_sessions": 8,
  "updated_at": "2026-03-10T21:26:11Z",
  "sessions": [
    {
      "session_id": "snes-a13fd98c-20260310T211455Z",
      "status": "suspended",
      "sort_key": "2026-03-10T21:26:11Z"
    },
    {
      "session_id": "gba-b89cab42-20260310T205011Z",
      "status": "suspended",
      "sort_key": "2026-03-10T21:10:00Z"
    }
  ]
}
```

---

## State Machine

Recommended lifecycle:

```text
new
→ active
→ suspending
→ suspended
→ resuming
→ active
```

Error paths:

```text
suspending → failed
resuming → failed
```

Discard path:

```text
suspended → discarded
failed → discarded
```

---

## Session Lifecycle Flow

### Launch New Game

```text
Launcher selects game
→ Session API creates session record
→ Session Registry assigns session ID
→ Emulator launches
→ Session marked active
→ Active session pointer updated
```

### Suspend Current Game

```text
User presses suspend / opens switcher / sleep event fires
→ Session API requests suspend
→ Session marked suspending
→ emulator runtime writes save state
→ state file validated
→ metadata updated
→ session marked suspended
→ active session cleared
→ session moved to top of resume stack
```

### Resume Session

```text
Launcher selects suspended session
→ Session API validates session
→ session marked resuming
→ emulator launched with matching core
→ save state loaded
→ session marked active
→ active session pointer updated
→ session moved to top of resume stack
```

### Failed Resume

```text
Resume requested
→ state file missing or incompatible
→ session marked failed
→ launcher offers normal game launch or discard session
```

---

## Session Policies

### Maximum Session Count

The first implementation should enforce a max concurrent suspended session count.

Recommended starting value:

```text
8 sessions
```

Reasoning:

- enough to feel premium
- small enough to manage storage and UI cleanly
- reduces complexity in early builds

When limit is exceeded, policy should be:

- prune oldest resumable session, or
- require user confirmation in future versions

Initial recommendation: prune oldest suspended session automatically after safe persistence.

---

### Per-System Support Matrix

Not all systems may support resume equally well at first.

The Session Manager should allow session capability flags by system/core.

Example config location:

```text
config/emulators/systems/session-support.json
```

Example model:

```json
{
  "snes": { "suspend_supported": true },
  "gba": { "suspend_supported": true },
  "ps1": { "suspend_supported": true },
  "n64": { "suspend_supported": false }
}
```

If a system is unsupported, the launcher should hide or degrade the feature gracefully.

---

## API Surface

Suggested high-level methods:

```text
create_session(game_context)
suspend_current_session(reason)
resume_session(session_id)
get_active_session()
list_sessions(filter)
discard_session(session_id)
prune_sessions(policy)
validate_session(session_id)
restore_last_session()
```

Suggested reasons for suspend:

- `manual`
- `switcher`
- `sleep`
- `shutdown`
- `launcher_return`

These reasons are useful for analytics, debugging, and policy tuning.

---

## Atomicity and Safety

Session writes should be treated as critical state operations.

Requirements:

- write metadata atomically
- avoid partial index updates
- update active-session pointer only after success
- keep previous valid metadata until replacement commit succeeds

Recommended strategy:

- write temporary file
- fsync if practical
- rename into place

This is especially important during sleep/shutdown events.

---

## Validation Rules

Before a session is considered resumable, validate:

- metadata file exists
- state file exists
- referenced ROM path exists
- configured core exists
- schema version is supported

Optional future validation:

- ROM fingerprint matches original game
- emulator build compatibility marker

---

## Recovery Behavior

If validation fails:

- session should not crash launcher
- mark session as `failed`
- log the reason
- offer user-facing fallback where appropriate

Recommended user-facing options:

- Launch Game Normally
- Discard Broken Session
- Back

---

## Boot Integration

The Session Manager should integrate with boot flow.

Recommended behavior:

```text
Boot
→ read last-session.json
→ validate last session
→ if auto-resume enabled and session valid, offer or perform resume
→ else show launcher home
```

Configurable boot behaviors:

- auto-resume immediately
- show "Resume Last Game" tile
- resume only when user confirms

Initial recommendation:

- present **Resume Last Game** prominently
- optionally support auto-resume later

This is safer during development.

---

## Game Switcher Integration

The launcher’s game switcher should consume Session Manager data rather than invent its own model.

Game switcher should display:

- game title
- system
- last played time
- optional thumbnail in future
- session state validity

Recommended interaction:

```text
Home/Menu
→ Game Switcher
→ select suspended game
→ resume via Session API
```

---

## Power Management Integration

Session handling must coordinate with power events.

Supported events:

- sleep button
- power-off command
- launcher exit to menu

Recommended rule:

Whenever practical, suspend should be attempted before sleep/shutdown completes.

If suspend cannot complete within safe timing window:

- log timeout/failure
- preserve existing stable state
- do not corrupt prior session metadata

---

## Logging

Recommended log path:

```text
runtime/sessions/logs/session-events.log
```

Recommended event types:

- session-created
- session-activated
- session-suspend-requested
- session-suspended
- session-resume-requested
- session-resumed
- session-validation-failed
- session-discarded
- session-pruned

Logs are especially important while tuning emulator-specific behavior.

---

## Migration Considerations

Session schema will evolve over time.

The Session Manager must support schema migration.

Recommended migration ownership:

- schema definitions under `runtime/sessions/schema/`
- migration logic under `tools/migration/` and/or session migration module

A new Ideal OS release should be able to:

- detect older session schema
- migrate safely, or
- invalidate old session with clear fallback path

---

## Recommended Initial Implementation Order

### Phase 1 – Core Session Persistence

- define session metadata schema
- define session index schema
- implement create/suspend/resume/discard
- implement last-session tracking

### Phase 2 – Launcher Integration

- add Resume Last Game tile
- add session list to game switcher
- add failed-session fallback flow

### Phase 3 – Power Event Hooks

- suspend on launcher return
- suspend on sleep
- suspend on shutdown

### Phase 4 – Hardening

- atomic write improvements
- pruning policies
- better validation
- session logs and diagnostics

### Phase 5 – UX Enhancements

- thumbnails/previews
- per-session status indicators
- optional pinned sessions

---

## Canonical Paths Summary

```text
src/session/api/
src/session/registry/
src/session/persistence/
src/session/stack/
src/session/recovery/
src/session/power/
runtime/sessions/
runtime/sessions/schema/
config/emulators/systems/session-support.json
```

---

## Recommendation

The Session Manager should be implemented as a modular service with:

- a stable API
- explicit state transitions
- durable on-device metadata
- strict validation and recovery behavior
- launcher-owned presentation but session-owned truth

This subsystem is the heart of Ideal OS’s curated appliance identity and should be engineered carefully before broad UI polish work begins.

