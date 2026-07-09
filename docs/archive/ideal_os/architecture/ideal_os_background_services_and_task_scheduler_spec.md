# Ideal OS – Background Services and Task Scheduler Specification

## Spec Metadata
- **Version:** 1.0
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** Power event orchestration ownership vs Session Manager and Cloud Sync (MB-2); no other spec acknowledges the scheduler (MB-4); dual sync queue with Cloud Sync (MB-5); boot flow ownership (MB-7); forward-dependency on Notification System (DO-9)

## Purpose

This document defines how Ideal OS manages background activity across core subsystems.

Ideal OS includes several features that want to do work outside the immediate foreground play experience, including:

- Cloud Sync
- OTA Updates
- Session housekeeping
- Metadata scraping
- Notification delivery
- Future maintenance jobs

Without coordination, these subsystems could compete for:

- WiFi access
- disk I/O
- CPU time
- battery
- power event timing

The Task Scheduler exists to make background work predictable, safe, and appliance-friendly.

---

## Core Design Principle

**Foreground play always wins.**

If the user is actively playing a game, background work should either pause, defer, or operate within strict limits.

Ideal OS should feel responsive and trustworthy, not busy.

---

## Goals

The scheduler must:

- coordinate all background-capable subsystems
- prevent resource contention during gameplay
- prioritize save protection and user data integrity
- integrate with notification policy
- support graceful handling of sleep, shutdown, and reboot
- provide predictable retry behavior
- expose clear rules for when tasks may run

---

## Non-Goals

The first implementation does not need:

- a distributed job system
- arbitrary user-created automation
- real-time preemptive scheduling guarantees
- aggressive parallel execution

The focus is reliability and user experience, not maximum throughput.

---

## Managed Subsystems

The scheduler should coordinate at least these subsystems:

### 1. Cloud Sync

Examples:

- upload changed saves
- flush sync queue on shutdown
- check remote state on startup

### 2. OTA Updater

Examples:

- check for updates
- download update manifests
- download packages
- validate staged payloads

### 3. Session Manager

Examples:

- session pruning
- stale session cleanup
- session metadata compaction

### 4. Library / Metadata

Examples:

- scrape boxart
- scrape metadata
- rebuild search index

### 5. Notification Delivery

Examples:

- queue guardian email
- retry failed notification delivery

### 6. Future Maintenance Services

Examples:

- cache cleanup
- storage health checks
- migration tasks

---

## Scheduling Philosophy

Background tasks should be classified by urgency and allowed runtime conditions.

Recommended model:

```text
Task
→ Priority
→ Allowed Conditions
→ Resource Budget
→ Retry Policy
→ Notification Policy
```

This keeps behavior deterministic.

---

## Task Classes

### Class A – Critical Data Protection

Highest priority. These tasks protect user progress.

Examples:

- write save-related sync queue metadata
- suspend current session on sleep/power event
- persist critical session state
- enqueue failed sync state for retry

Rules:

- may run during gameplay only if lightweight
- may preempt lower-priority work
- should be optimized for atomicity and speed

---

### Class B – Important User Safety Tasks

Important, but not as urgent as immediate state protection.

Examples:

- upload changed save files in background
- send guardian alert after threshold reached
- validate update manifest already downloaded

Rules:

- prefer launcher/idle states
- should defer when gameplay is active unless operating within strict resource limits

---

### Class C – Convenience Tasks

Helpful, but safe to defer.

Examples:

- OTA check
- metadata scraping
- boxart downloads
- search index refresh

Rules:

- do not run during active gameplay unless explicitly allowed later
- run primarily on launcher, idle, charging, or WiFi-connected states

---

### Class D – Maintenance Tasks

Lowest priority housekeeping.

Examples:

- log rotation
- cache cleanup
- stale artifact pruning

Rules:

- run only when system is idle or during controlled maintenance windows

---

## System States

The scheduler should make decisions based on a small set of device states.

### Active Gameplay

A game is currently running in the foreground.

Rules:

- only Class A tasks allowed by default
- Class B tasks only if explicitly marked low-impact
- Class C and D tasks deferred

---

### Launcher Foreground

User is in the launcher or settings.

Rules:

- Class A and B tasks allowed
- Class C tasks allowed if bandwidth/CPU limits respected
- Class D tasks allowed opportunistically

---

### Idle

No active game and no recent user interaction.

Rules:

- all classes may run according to budgets

---

### Sleep Pending

Power button pressed or sleep transition initiated.

Rules:

- prioritize Class A state protection tasks
- allow short bounded save-flush operations
- allow short bounded sync flush if configured
- cancel or defer OTA and scraping tasks

---

### Shutdown Pending

System preparing for shutdown.

Rules:

- prioritize session/state persistence
- allow bounded sync flush
- do not begin long-running downloads
- record durable queue state for later retry

---

### Boot / Startup

System just started.

Rules:

- restore essential state first
- allow lightweight sync and update checks later in startup sequence
- do not overload startup path with non-essential jobs

---

### Charging + WiFi

Best state for larger background work.

Rules:

- preferred for OTA downloads, metadata scraping, and large sync jobs

---

## Resource Budgets

Each task should declare a rough resource profile.

Suggested dimensions:

- CPU impact: low / medium / high
- disk I/O: low / medium / high
- network usage: low / medium / high
- blocking risk: low / medium / high

Example:

```text
Save Sync Upload
CPU: low
Disk: low
Network: medium
Blocking: low
```

Example:

```text
OTA Package Download
CPU: low
Disk: medium
Network: high
Blocking: medium
```

The scheduler should avoid overlapping tasks that compete heavily for the same resource class.

---

## Concurrency Rules

Recommended initial policy:

- one network-heavy task at a time
- one disk-heavy task at a time
- multiple lightweight local tasks allowed if non-conflicting

Examples:

Allowed:

- session cleanup + notification log write

Not allowed:

- OTA package download + cloud save upload + metadata scrape image download at the same time

This conservative model is appropriate for early stability.

---

## Task Lifecycle

Each background task should move through a clear lifecycle.

```text
created
→ queued
→ eligible
→ running
→ completed
```

Failure path:

```text
running
→ failed
→ retry_scheduled
→ queued
```

Cancelled/deferred path:

```text
eligible
→ deferred
→ queued
```

---

## Task Metadata Schema

Suggested task record fields:

- task\_id
- subsystem
- task\_type
- priority\_class
- created\_at
- last\_attempt\_at
- retry\_count
- state
- required\_conditions
- resource\_profile
- user\_visible\_if\_delayed

Example:

```json
{
  "_schema_version": "1.0",
  "task_id": "sync-upload-20260310-001",
  "subsystem": "sync",
  "task_type": "upload_artifact",
  "priority_class": "B",
  "state": "queued",
  "required_conditions": ["wifi"],
  "resource_profile": {
    "cpu": "low",
    "disk": "low",
    "network": "medium"
  },
  "retry_count": 0,
  "user_visible_if_delayed": false
}
```

---

## Canonical Scheduler Responsibilities

The scheduler should own:

- task queue management
- eligibility evaluation
- conflict detection
- retry timing
- bounded execution windows for power events
- notification escalation hooks

The scheduler should not own subsystem-specific business logic.

Example:

- the Sync Manager decides *what* needs upload
- the scheduler decides *when* upload may run

---

## Power Event Policy

Power events are where scheduler behavior matters most.

**Ownership:** The Task Scheduler is the sole orchestrator of power-event sequences (sleep and shutdown). Other modules (Session Manager, Cloud Sync, Notification System) register as participants with defined priority ordering. They do not independently listen for OS-level power events — the scheduler calls them in sequence and enforces timeouts.

Participant priority order:
1. **Session Manager** — `persist_on_power_event()` — always first, critical priority
2. **Cloud Sync** — `flush_on_power_event()` — bounded timeout, skippable
3. **Notification System** — `record_deferred_warnings()` — fast, non-blocking

The scheduler receives power events from `src/system/` and executes the pipeline. If a participant exceeds its timeout, the scheduler proceeds to the next participant.

### Sleep Button Pressed

Allowed sequence:

1. Session Manager persists critical gameplay state
2. Sync Manager may attempt bounded flush of save queue
3. Notification system may record deferred warning if flush not completed
4. Device enters sleep

Rules:

- bounded timeout required
- user should be able to skip non-critical waiting
- critical state writes always outrank uploads

---

### Shutdown

Allowed sequence:

1. persist session and queue state
2. optionally attempt bounded sync flush
3. write retry metadata for unfinished tasks
4. shut down

Rules:

- do not start OTA downloads
- do not start scraping
- do not keep device alive indefinitely

---

## Notification Integration

The scheduler should integrate directly with the notification policy engine.

Examples:

- repeated sync task failures escalate from invisible retry to local warning
- prolonged queued critical tasks may trigger local warning
- threshold-crossing data protection failures may trigger guardian alert

Important principle:

A delayed task is not automatically a user-facing problem. Only risk to user progress should escalate.

---

## Retry Policy

Tasks should support retries, but retries must be bounded and classified.

Recommended retry styles:

### Immediate Retry

For transient lightweight issues.

Example:

- temporary file lock while writing local metadata

### Backoff Retry

For network or provider failures.

Example:

- cloud upload failed
- notification email provider unavailable

### Deferred Retry

For condition-based failures.

Example:

- WiFi unavailable
- device not charging for large OTA download

Recommended backoff model:

```text
attempt 1 → retry in 5 min
attempt 2 → retry in 15 min
attempt 3 → retry in 1 hr
attempt 4+ → retry every 6 hr or next eligible state
```

---

## Eligibility Conditions

Tasks may require conditions such as:

- WiFi connected
- launcher active
- idle
- charging
- battery above threshold
- no game running
- storage available

Example:

```json
{
  "required_conditions": ["wifi", "launcher_or_idle"],
  "preferred_conditions": ["charging"]
}
```

The scheduler should support both required and preferred conditions.

---

## Bounded Execution Windows

Some tasks should run only in short windows.

Examples:

- shutdown sync flush: 2–5 seconds
- startup remote sync check: lightweight only
- background save upload during launcher use: modest bandwidth cap

This ensures background work never dominates the appliance experience.

---

## Queue Separation

Recommended initial implementation separates queues logically by subsystem, while the scheduler maintains final arbitration.

Suggested layout:

```text
runtime/tasks/
├── scheduler-state.json
├── queues/
│   ├── sync.json
│   ├── updater.json
│   ├── session.json
│   ├── library.json
│   └── notifications.json
└── logs/
    └── task-events.log
```

This helps debugging while preserving central control.

---

## Suggested Arbitration Rules

If multiple eligible tasks exist, scheduler should choose in this order:

1. Class A critical data protection
2. Class B important user safety
3. Class C convenience
4. Class D maintenance

Within a class, break ties by:

1. oldest queued criticality timestamp
2. user-risk if delayed
3. smallest bounded task first when conditions are unstable

This helps finish valuable work quickly.

---

## Startup Policy

Startup should remain fast and predictable.

Recommended startup sequence:

1. restore minimal scheduler state
2. restore essential session state
3. allow launcher to become responsive
4. enqueue or evaluate non-essential background tasks
5. run only lightweight checks initially

Do not perform heavy OTA downloads or metadata scraping during early startup.

---

## Failure Handling

If a task fails repeatedly:

- preserve its metadata
- classify the reason
- attach notification policy if needed
- avoid blocking unrelated work unless required

Example:

A failed Google Drive upload should not block local session cleanup or a local notification write.

However, repeated sync failure may trigger notification escalation.

---

## Logging and Diagnostics

Recommended path:

```text
runtime/tasks/logs/task-events.log
```

Recommended event types:

- task-created
- task-queued
- task-started
- task-completed
- task-failed
- task-retry-scheduled
- task-deferred
- task-cancelled
- scheduler-state-changed

This will be invaluable during development and device testing.

---

## Developer Controls

Advanced diagnostics should allow:

- view queued tasks
- inspect last failure per subsystem
- manually trigger task processing
- temporarily disable non-critical background work

These controls should be hidden from normal users.

---

## Initial Implementation Phases

### Phase 1 – Core Scheduler

- define task record schema
- define queue layout
- implement eligibility evaluation
- implement conservative single-task arbitration

### Phase 2 – Sync and Session Integration

- integrate Cloud Sync tasks
- integrate Session Manager power-event tasks
- enforce shutdown/sleep bounded windows

### Phase 3 – OTA and Notification Integration

- integrate OTA checks/downloads
- integrate guardian alert delivery retries
- add task-based escalation hooks

### Phase 4 – Library and Maintenance Work

- integrate metadata scraping
- integrate search index rebuilds
- integrate cleanup jobs

### Phase 5 – Hardening

- improve diagnostics
- add preferred condition logic
- tune retry and arbitration policies

---

## Canonical Paths Summary

```text
src/tasks/
src/tasks/scheduler/
src/tasks/policy/
src/tasks/queue/
src/tasks/conditions/
runtime/tasks/
runtime/tasks/queues/
runtime/tasks/logs/
config/tasks/
```

---

## Recommendation

Ideal OS should implement a centralized but conservative task scheduler that:

- protects gameplay first
- gives save protection work highest priority
- defers convenience work intelligently
- integrates tightly with notification and power-event policy
- keeps the system feeling quiet, fast, and reliable

This scheduler is the coordination layer that allows OTA, cloud sync, and session continuity to coexist without compromising the appliance experience.

