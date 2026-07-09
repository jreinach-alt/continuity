# Ideal OS – NextUI Platform Audit Reference

## Spec Metadata
- **Version:** 1.0
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** None

## Purpose

This document captures a current-state audit of NextUI as a candidate base platform for Ideal OS.

The goal is to document what NextUI appears to provide today, how its repository is structured, where Ideal OS can hook in, and which assumptions should be validated before implementation begins.

This is a reference document for planning. It is not a commitment to preserve every current NextUI behavior.

---

## Audit Summary

### High-Level Conclusion

NextUI remains the strongest current base platform for Ideal OS because it already provides:

- TrimUI Brick support
- active maintenance
- a package-oriented extension model
- working launcher/emulator/runtime integration
- WiFi-aware tooling and community distribution channels

However, NextUI is not organized like a traditional application framework.

It behaves more like:

- a runtime filesystem overlay
- a build/staging environment
- a PAK-driven extension ecosystem

Ideal OS should therefore be designed as a **runtime layer plus modular services** on top of NextUI, rather than as a deep rewrite of a conventional source tree.

---

## Current Repository Shape

The visible root structure of the NextUI repository suggests a lightweight platform-oriented project.

Observed root-level items include:

- `.github/`
- `.vscode/`
- `skeleton/`
- `workspace/`
- `makefile`
- `makefile.native`
- `makefile.toolchain`
- `PAKS.md`
- `README.md`
- `commits.sh`
- `todo.txt`

### Interpretation

This indicates that NextUI is organized around:

- build tooling
- runtime filesystem scaffolding
- deployment assets
- platform packaging

It does **not** resemble a classic monorepo with clearly separated product modules such as launcher, updater, session manager, and sync service.

Implication for Ideal OS:

Ideal OS should preserve the platform layer and add its own modular architecture beside it, not assume the base already provides clean application boundaries.

---

## Current Platform Positioning

NextUI describes itself as:

- a custom firmware based on MinUI
- rebuilt around a new emulator engine core
- targeted at the TrimUI Brick and Smart Pro family

Observed feature claims include:

- game switcher menu
- native WiFi support
- game art/media support
- dynamic CPU scaling
- Bluetooth audio
- overlays
- shaders
- time tracking
- LED control
- display controls
- OpenGL/GPU-based rendering

### Implication

NextUI already solves much of the difficult platform integration work that Ideal OS would otherwise need to rebuild.

Ideal OS should avoid duplicating:

- base device integration
- WiFi stack integration
- core emulator launching behavior
- package-discovery concepts already native to NextUI

---

## PAK System Audit

NextUI’s PAK system is one of the most important architectural findings from this audit.

### What a PAK is

A PAK is a folder with a `.pak` extension containing a `launch.sh` script.

NextUI distinguishes two primary PAK categories:

- emulator PAKs in `Emus`
- tool PAKs in `Tools`

These folders live at the SD card root.

### Important Update Constraint

NextUI’s documentation explicitly warns that extra PAKs should **not** be stored in the hidden `.system` folder because that folder is replaced during updates.

### Implication for Ideal OS

This strongly suggests that Ideal OS features should be designed with one of two models:

#### Model A – Core Runtime + Optional Feature PAKs

Examples:

- `Ideal Session.pak`
- `Ideal Sync.pak`
- `Ideal Updater.pak`

#### Model B – Core services embedded in the platform overlay, with auxiliary tools delivered as PAKs

Recommended initial approach:

- keep critical OS services in the core runtime
- use PAKs for admin tools, diagnostics, utilities, optional add-ons, and community extensions

This reduces the risk of core features being treated like removable apps.

---

## Pak Store Ecosystem Audit

The NextUI Pak Store is preinstalled with NextUI and is launched from the `Tools` menu.

It supports community-distributed PAKs that are versioned and described using `pak.json` metadata.

Required pak metadata includes:

- name
- version
- type
- description
- author
- repo URL
- release filename
- platforms

### Implication for Ideal OS

The Pak Store ecosystem provides a ready-made distribution channel for:

- optional utilities
- diagnostics tools
- theme packs
- community enhancements

It may also be useful for distributing non-core Ideal OS packages or testing tools.

However, the Ideal OS core platform should not depend on community Pak Store semantics for essential platform services.

---

## Update Path Audit

NextUI currently supports updating through:

- documented install/update instructions
- on-device updater tooling in the ecosystem
- package-style extension distribution

A separate NextUI Updater PAK exists and has been described as working on the TrimUI Brick.

### Key Interpretation

NextUI already has practical on-device update behavior, but Ideal OS’s OTA architecture is more advanced and opinionated.

Ideal OS requires:

- channel manifests
- release manifests
- migration handling
- installed-state tracking
- clearer package orchestration

### Recommendation

Reuse where useful:

- network download helpers
- package placement conventions
- proven on-device update UX patterns

Replace where necessary:

- orchestration logic
- manifest format
- migration and rollback behavior

---

## Filesystem and SD Layout Assumptions

The PAK documentation shows that NextUI expects SD-root structures including:

- `Emus/`
- `Tools/`
- hidden `.system/`

The ecosystem around NextUI also assumes ROM- and tool-centric SD card organization.

### Implication for Ideal OS

Ideal OS should extend the existing on-device layout, not break it.

Recommended approach:

- preserve user-facing SD root structure expected by NextUI
- place Ideal OS runtime data into a dedicated namespace

Suggested runtime namespace:

```text
/ideal/
  session/
  sync/
  tasks/
  notifications/
  updater/
```

This avoids collisions and keeps Ideal OS-owned state obvious.

---

## Launcher and Runtime Hook Points

Based on the visible project shape and documented features, the likely runtime insertion points for Ideal OS are:

- boot / startup initialization
- launcher startup
- emulator launch wrapper
- power-event handling
- WiFi-aware background service entry points
- tool/PAK launch integration

### Implication

Ideal OS should not assume a clean internal API already exists for these lifecycle points.

Instead, the project should explicitly define wrapper layers for:

- session creation around game launch
- scheduler initialization after boot
- sync and updater registration once network is available
- notification policy evaluation at launcher and power-event boundaries

---

## Areas Where NextUI Already Overlaps Ideal OS Goals

Observed NextUI capabilities already cover or partially cover:

- game switcher
- media/boxart support
- WiFi features
- overlays and shaders
- tracking/telemetry-like behavior
- performance-oriented dynamic CPU scaling

### Ideal OS Implication

These areas need **audit-first implementation**, not blind replacement.

For each overlapping feature, Ideal OS should decide one of:

- inherit unchanged
- wrap
- extend
- replace

Example:

#### Game Switcher

NextUI already has a game switcher.

Ideal OS should evaluate whether it can be used as:

- a UI shell for the Session Manager, or
- a reference implementation to replace cleanly

The differentiator is not the existence of a switcher, but whether it is backed by durable session persistence and resume-stack semantics.

---

## CrossMix Role After NextUI Audit

This audit further supports the earlier conclusion that CrossMix should remain a donor/reference project only.

CrossMix appears most useful for:

- tuned emulator configs
- curated defaults
- tool bundles
- practical UX conventions

It does not appear to be the better base for Ideal OS’s deeper architectural goals.

---

## Updated Base Strategy

### Recommended Platform Strategy

Use NextUI as:

- the hardware and runtime platform layer
- the source of current Brick-compatible operational assumptions
- the source of existing package and community integration patterns

Build Ideal OS as:

- a namespaced runtime layer
- a set of modular services
- a launcher/session/sync/task architecture that sits above platform assumptions

### Recommended Service Placement

Core services should live in the Ideal OS runtime layer:

- Session Manager
- Sync Engine
- Notification Policy Engine
- Background Task Scheduler
- OTA Orchestrator

Optional utilities and diagnostics may be delivered as PAKs where appropriate.

---

## Risks and Open Questions

### 1. Boot Flow Visibility

The public repo surface does not fully expose the exact runtime lifecycle from web inspection alone.

This must be confirmed locally during implementation.

### 2. Launcher Boundaries

It is not yet proven whether NextUI’s launcher can be safely wrapped versus needing partial replacement.

### 3. Update Hooks

The exact boundaries between core update logic and optional updater tools need local validation.

### 4. PAK Suitability for Core Services

PAKs are clearly good for tools and extensions, but Ideal OS should avoid depending on removable PAK semantics for foundational services unless the startup model proves safe.

---

## Practical Recommendations for Claude Code

Before major feature work begins, Claude should:

1. map the local runtime boot flow of NextUI
2. identify where launcher init occurs
3. identify how emulator launch is wrapped
4. identify power-event hook points
5. confirm how PAK discovery works on-device
6. confirm what update path replaces `.system/`
7. preserve all existing user-facing SD root assumptions during early development

---

## Recommendation

The audit confirms that NextUI is still the best current base for Ideal OS, but it changes *how* Ideal OS should be built.

Ideal OS should not treat NextUI as a modular application framework. It should treat it as:

- a current, Brick-capable runtime platform
- a filesystem and packaging convention
- a community extension ecosystem

Ideal OS should then layer its own architecture above that platform with a clearly namespaced runtime and carefully chosen integration points.

