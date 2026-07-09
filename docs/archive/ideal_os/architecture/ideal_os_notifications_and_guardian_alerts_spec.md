# Ideal OS – Notification, Guardian Alerts, and Family‑Safe Reliability Specification

## Spec Metadata
- **Version:** 1.0
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** Expects events from modules that do not define them (DO-5); Cloud Sync bypasses notification architecture with own overlay (MB-9); device_id/nickname referenced but undefined (DF-6)

## Purpose

This document defines the **notification model, guardian alert system, and family‑safe reliability behavior** for Ideal OS.

Ideal OS is designed so that a parent can configure the device for a child with confidence that gameplay progress will not be easily lost.

The system should:

- protect save data
- surface meaningful issues clearly
- avoid overwhelming users with technical messages
- escalate problems only when progress may be at risk

This subsystem governs how Ideal OS communicates system health, sync status, and critical problems.

---

# Core Design Principle

**Silent when healthy. Visible when attention is needed. Escalate when progress is at risk.**

Ideal OS should minimize interruptions during gameplay and only display notifications that are meaningful to the user.

---

# Notification Tiers

Notifications are grouped into four escalation tiers.

## Tier 0 — Invisible (Healthy State)

No user-facing notifications.

Examples:

- background save sync successful
- scheduled cloud snapshot completed
- queued sync tasks waiting for WiFi

The system simply continues operating.

---

## Tier 1 — Informational

Lightweight informational messages that do not interrupt gameplay.

Displayed in:

- system status page
- settings screen
- subtle status indicator

Examples:

- "Last backup: 5 minutes ago"
- "2 items waiting for sync"
- "Cloud provider connected"

---

## Tier 2 — Local Warning

Visible message shown locally on the device.

Used when something requires attention but does not yet risk data loss.

Examples:

- cloud authentication expired
- storage quota nearing limit
- sync paused due to network loss

Typical UI behavior:

- small popup
- notification badge
- settings banner

These messages should be easy to dismiss and should not interrupt gameplay.

---

## Tier 3 — Guardian Alert

Used only when user progress may be at risk.

This tier may send notifications outside the device.

Possible delivery methods:

- email
- push notification (future)
- webhook integration (future)

Examples:

- no successful backups for several days
- repeated upload failures
- cloud storage full
- unresolved save conflict
- corrupted save detected

Guardian alerts should be **rare but meaningful**.

---

# Guardian Contact Model

Ideal OS should allow configuration of a **guardian contact** during setup.

Recommended configuration fields:

- email address
- device nickname
- guardian notification preference

Example configuration:

```
Guardian Contact
Email: parent@example.com
Device Name: Alex's Brick
Notifications: Critical Only
```

This information is used only for Tier 3 alerts.

---

# Family‑Safe Mode

Ideal OS should support a **Family‑Safe Mode** profile.

This mode optimizes the device for child use or non‑technical users.

When enabled, the OS should:

- enable cloud backups by default
- prefer "Saves Only" sync mode
- reduce destructive prompts
- auto‑retry sync failures quietly
- escalate repeated failures to guardian contact
- hide advanced configuration settings

This mode should be selectable during initial setup.

---

# Critical Alert Conditions

A guardian alert should only occur under defined conditions.

Recommended triggers:

- no successful backup for 72 hours while saves are changing
- repeated sync failures over a defined threshold
- cloud storage quota reached
- save conflict requiring manual decision
- detected corruption in save data

Non‑critical situations should never trigger guardian alerts.

Examples that should NOT escalate:

- temporary WiFi loss
- single failed upload
- background sync delay

---

# Escalation Timing

Recommended escalation schedule:

```
0–24 hours: retry silently
24–72 hours: show local warning
72+ hours: send guardian alert
```

This prevents unnecessary alerts while still protecting user progress.

---

# Notification UX Guidelines

Notifications must be understandable by non‑technical users.

Avoid technical terminology.

Examples:

Instead of:

"OAuth token refresh failed"

Use:

"Backups need attention"

Technical details should be logged internally for diagnostics.

---

# Example Local Warning

```
Backups paused

Cloud connection needs attention.

Open Settings to reconnect.
```

---

# Example Guardian Alert Email

Subject:

```
Ideal OS Backup Warning – Alex's Brick
```

Message:

```
Ideal OS has not successfully backed up game progress from Alex's Brick for 3 days.

Progress is still being saved locally, but backups are currently failing.

Please check the device settings to reconnect the cloud provider.
```

---

# Integration with Cloud Sync

The notification system should subscribe to events from the Sync Manager.

Relevant events include:

- backup completed
- upload failure
- provider disconnected
- storage quota exceeded
- conflict detected

These events determine notification tier and escalation behavior.

---

# Integration with Session Manager

Session Manager events may also trigger notifications.

Examples:

- corrupted save state detected
- resume failure
- session data invalid

These should normally remain Tier 2 warnings unless repeated failures occur.

---

# Notification Delivery Architecture

```
System Event
   ↓
Notification Policy Engine
   ↓
Tier Classification
   ↓
Local Notification
   ↓
Guardian Alert (if Tier 3)
```

The policy engine determines whether a message remains local or escalates externally.

---

# Logging

All notification events should be logged for diagnostics.

Recommended path:

```
runtime/notifications/logs/notification-events.log
```

Each record should include:

- event type
- timestamp
- notification tier
- source subsystem
- resolution status

---

# User Control

Users should be able to configure:

- guardian email
- alert frequency
- sync notification behavior

Example settings menu:

```
Notifications

Guardian Contact: parent@example.com
Alert Level: Critical Only
Cloud Sync Notifications: Enabled
```

---

# Privacy Considerations

Guardian alerts should not include:

- ROM filenames
- personal information beyond device nickname

Alerts should contain only the information needed to identify the device and issue.

---

# Development Phases

## Phase 1 – Local Notifications

- notification tiers
- local message display
- logging

---

## Phase 2 – Guardian Alerts

- email integration
- escalation rules

---

## Phase 3 – Expanded Delivery

Possible future options:

- push notifications
- webhook integrations

---

# Recommendation

The notification system should remain quiet and trustworthy.

Users should rarely see alerts, but when they do, they should clearly indicate that attention is required.

By combining silent reliability with escalation for critical failures, Ideal OS can deliver a family‑safe handheld experience where progress is protected and parents have peace of mind.

