# Ideal OS – Platform Component Audit Matrix

## Spec Metadata
- **Version:** 1.0
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** None

## Purpose

This document evaluates the major platform components surrounding NextUI against the Ideal OS feature set and architectural goals.

The objective is to determine, for each component, whether Ideal OS should:

- **Keep** it unchanged
- **Wrap** it with an Ideal OS service layer
- **Branch** it into an Ideal-owned variant
- **Rewrite** it from scratch
- **Reject** it entirely

This matrix is intentionally focused on **high-leverage platform components**, not every community pak.

---

## Decision Key

### Keep
Use as-is.

### Wrap
Retain the underlying component but put an Ideal OS API/service around it.

### Branch
Fork locally because it is close but needs controlled divergence.

### Rewrite
Build a new Ideal OS-native implementation.

### Reject
Do not use.

---

## Evaluation Criteria

Each component is reviewed against:

- **Current Role** – what it does today
- **Feature Fit** – how well it matches the Ideal OS feature matrix
- **Architectural Fit** – how well it aligns with Session, Sync, OTA, Scheduler, and Notifications
- **Update Safety** – whether it fits cleanly into the Ideal OS OTA model
- **Maintenance Burden** – likely long-term cost
- **Decision** – Keep / Wrap / Branch / Rewrite / Reject

---

# Component Audit Matrix

| Component | Current Role | Feature Fit | Architectural Fit | Update Safety | Maintenance Burden | Decision | Notes |
|---|---|---:|---:|---:|---:|---|---|
| **NextUI Hardware / Device Integration** | Brick-targeted firmware integration, drivers, input, power, base platform behavior | High | High | High | Low | **Keep** | This is the strongest reason to use NextUI at all. Avoid touching unless required. |
| **NextUI WiFi / Network Platform Layer** | Enables on-device connectivity for updates, Pak Store, future sync | High | High | High | Low | **Keep** | Required by OTA, Cloud Sync, and guardian alerts. Reuse platform behavior rather than replacing. |
| **NextUI Emulator Launch Path** | Launches emulators and tools through current runtime conventions | Medium | Medium | Medium | Medium | **Wrap** | Ideal OS should hook session creation, suspend/resume, and scheduler policies around launch rather than replace immediately. |
| **NextUI Launcher Core** | Main UI shell for browsing and launching content | Medium | Medium-Low | Medium | Medium-High | **Branch** | Likely too central to replace instantly, but Ideal OS needs deep integration with session stack, sync state, notifications, and curated flows. |
| **NextUI Game Switcher** | Existing quick-switch UI behavior | Medium | Low-Medium | Medium | Medium | **Wrap / Branch** | Promising as a UI shell, but not sufficient unless backed by true session persistence and resume-stack semantics. Audit actual behavior locally before final choice. |
| **NextUI Boxart / Media Support** | Displays artwork/media in launcher context | High | High | High | Low | **Keep / Wrap** | Strong overlap with Ideal OS library goals. Likely keep, with Ideal library manager wrapping metadata flow if needed. |
| **NextUI Overlay / Shader / Display Controls** | Presentation and visual tuning features | High | Medium | High | Low | **Keep** | Aligned with curated experience. Ideal OS should define defaults, not replace implementation. |
| **NextUI Dynamic CPU Scaling / Performance Controls** | Performance optimization behavior | Medium | Medium | High | Low-Medium | **Keep / Wrap** | Useful as an internal lever. Expose only what supports curated defaults; don’t let it drive product complexity. |
| **NextUI OTA Updater Path** | Existing on-device update behavior with updater ecosystem | Medium | Medium-Low | Medium | Medium | **Branch / Rewrite** | Useful reference and possible source of download/package utilities, but Ideal OS needs manifest-driven orchestration, migration tracking, and installed-state management. |
| **NextUI PAK Runtime Conventions** | Defines how tools/emulators/extensions are delivered and launched | High | High | Medium | Low | **Keep** | Central platform assumption. Ideal OS should align with it, especially for optional tools and diagnostics. |
| **NextUI Pak Store Ecosystem** | Community distribution channel for PAKs launched from Tools menu | Medium | Medium | Medium | Low-Medium | **Wrap** | Great for optional utilities, diagnostics, themes, and community extensions. Avoid depending on it for core OS services. |
| **NextUI `.system` Update Replacement Behavior** | Internal update-replaced platform area | Low | Low | Low | Medium | **Reject as extension target** | Important constraint: do not place Ideal-owned removable or user-added components here because updates replace it. |
| **CrossMix Emulator Configs** | Historical tuned configs and curated defaults | Medium | Medium | Medium | Medium | **Harvest selectively / Branch snippets** | Still potentially useful as donor material, but only after validating against current NextUI cores and Brick behavior. |
| **CrossMix Control Mappings / UX Defaults** | Historical convenience and compatibility tuning | Low-Medium | Medium | Medium | Medium | **Harvest selectively** | Use only if it clearly improves curated defaults and doesn’t import stale assumptions. |
| **CrossMix Platform Scripts** | Legacy scripts tied to older TrimUI assumptions | Low | Low | Low | High | **Reject** | Too stale and too risky as a platform base. |
| **MinUI Architectural Philosophy** | Minimalist appliance-first design influence | High | High | High | Low | **Keep as reference only** | Important north star for UX philosophy, but not a live code dependency. |
| **Community Utility PAKs (generic)** | Optional apps and tools in Tools/Emus ecosystem | Variable | Variable | Medium | Variable | **Audit case-by-case** | Do not bulk adopt. Evaluate only when a pak directly accelerates Ideal OS goals or developer workflow. |

---

# Immediate Recommendations by Area

## 1. Keep Immediately

These should be treated as stable platform assumptions unless proven otherwise:

- NextUI hardware/device integration
- NextUI WiFi/network platform layer
- NextUI PAK runtime conventions
- NextUI boxart/media support
- NextUI overlays/shaders/display controls

---

## 2. Wrap First, Replace Later If Needed

These areas likely benefit from Ideal OS service layers around them:

- emulator launch path
- game switcher
- Pak Store access for optional tools
- performance control surfaces

---

## 3. Branch Early

These components are likely close enough to be useful, but central enough that Ideal OS should own their evolution:

- launcher core
- updater path/orchestration

---

## 4. Rewrite as Ideal OS-Native Systems

These are too central to Ideal OS identity to inherit from adjacent projects:

- Session Manager
- Cloud Sync Engine
- Notification / Guardian Alert Policy Engine
- Background Task Scheduler
- OTA manifest orchestration and migration layer

---

## 5. Reject / Avoid

Avoid these as architectural foundations:

- CrossMix platform scripts
- using `.system` as a target for Ideal-owned extensibility
- any component whose behavior conflicts with OTA safety or namespaced runtime ownership

---

# Open Questions Requiring Local Validation

The matrix above is informed by current public documentation and repo surfaces, but several decisions require local code/runtime inspection before final lock-in:

1. **Launcher boundaries**
   - Can the current NextUI launcher be cleanly branched?
   - Where does Ideal OS inject session-aware UI state?

2. **Game switcher semantics**
   - Is it only UI, or does it already preserve useful runtime state that Ideal OS can wrap?

3. **Updater internals**
   - Which parts are reusable utilities versus assumptions that conflict with manifest-based OTA?

4. **Emulator launch wrappers**
   - Where is the safest place to inject session creation, suspend/retry hooks, and sync-aware policies?

5. **Power-event handling**
   - Where should Session Manager and Task Scheduler hook without creating race conditions?

---

# Recommended Next Audit Sequence

To move from planning to implementation safely, Claude should audit these in order:

## Step 1 – Boot / Startup Flow

Map:

- boot initialization
- launcher start
- scheduler insertion point
- network initialization timing

## Step 2 – Emulator Launch Flow

Map:

- launcher selection
- wrapper script chain
- core launch
- tool launch distinction

## Step 3 – Power Event Flow

Map:

- sleep
- shutdown
- return-to-launcher
- current update/sync side effects

## Step 4 – Updater Runtime Flow

Map:

- current update packaging
- `.system` replacement behavior
- where Ideal OS installed-state and manifest logic should live

## Step 5 – PAK Discovery / Tool Integration

Map:

- discovery rules
- install paths
- how optional Ideal tools should be shipped

---

# Recommendation

The audit supports a clear strategy:

- **Keep** the current Brick-capable platform assumptions from NextUI
- **Branch** the launcher and updater paths where Ideal OS needs product ownership
- **Wrap** reusable runtime components where the underlying behavior is sound but missing Ideal semantics
- **Rewrite** the systems that define Ideal OS’s unique identity
- **Leave CrossMix behind** except for selective config harvesting when it clearly improves curated defaults

This gives Ideal OS the best balance of speed, maintainability, and architectural integrity.

