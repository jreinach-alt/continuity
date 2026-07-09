# Sprint 0.4 — Boot Flow Analysis and Integration Boundaries

## Phase

Phase 0 — Foundation

## Approved

<!-- The orchestrator or user sets this date when the spec is approved. -->
<!-- Agents MUST NOT begin implementation until this field contains a date. -->
**2026-03-11**

## Status

complete

Status definitions:
- `not-started` — Spec is being drafted or under review. No implementation allowed.
- `approved` — Spec is locked and approved for implementation. Set the Approved date above.
- `in-progress` — Actively being implemented.
- `complete` — All acceptance criteria met.

## Goal

Produce a complete trace of both NextUI boot flows (first-boot/install and normal boot), document every integration boundary where Ideal OS must hook in or replace NextUI behavior, and resolve the remaining open questions from Sprint 0.3 — so that Phase 1 (Build Pipeline) can proceed with full understanding of the boot chain and clear wrap/replace decisions.

## Reference Specs

- `upstream/nextui/manifest.md` — Component-level disposition map (Sprint 0.3 output)
- `upstream/nextui/notes/update-mechanism-analysis.md` — Update packaging and apply flow (Sprint 0.3 output)
- `docs/architecture/ideal_os_ota_update_architecture_spec.md` — OTA design goals
- `docs/architecture/ideal_os_platform_component_audit_matrix.md` — High-level disposition decisions
- `docs/implementation/ideal_os_fork_and_harvest_plan.md` — Integration strategy
- `docs/architecture/ideal_os_session_manager_technical_architecture_spec.md` — Session resume requirements (relevant to boot hook points)

## Scope

### In Scope

- [ ] Trace the **first-boot/install flow**: from SD card insertion through `.tmp_update/updater` → platform detection → `.pakz` processing → extraction → migration → first boot → forced power-off
- [ ] Trace the **normal boot flow**: from power-on through `main.sh` / `runtrimui.sh` → hardware init → daemon startup → `nextui.elf` (MainUI) main loop → suspend/resume/poweroff handling
- [ ] Document every script, binary, and config file touched in each flow — with file paths, execution order, and what each does
- [ ] Identify **Ideal OS hook points** in each flow:
  - First-boot: OTA package staging, integrity verification, migration framework
  - Normal boot: boot animation, session resume check, launcher handoff, power event integration
- [ ] Analyze **conflict zones** — NextUI subsystems that overlap with Ideal OS goals:
  - `.system/` folder: runtime layout, what lives there, how Ideal OS extends or replaces it
  - PAK store / Tools: how PAKs are discovered, launched, and managed; wrapping strategy
  - Settings persistence: where settings are stored, format, how Ideal OS coexists
  - Updater: how the install/update flow maps to Ideal OS OTA
  - Launcher (`nextui.elf`): how it's started, what it controls, where Ideal OS intercepts
- [ ] Define the **integration boundary**: a clear line showing where NextUI platform layer ends and Ideal OS core services begin, with file-level specificity
- [ ] Resolve remaining open questions from Sprint 0.3: Q6 (boot script extension for OTA), Q7 (boot handoff point)
- [ ] Produce `upstream/nextui/notes/boot-flow-analysis.md`
- [ ] Produce `upstream/nextui/notes/conflict-analysis.md`

### Out of Scope

- Removing, stripping, or modifying any NextUI source files (still read-only)
- Writing any Ideal OS code or scripts
- Setting up CI/CD (Sprint 0.5)
- Cross-compiling or building NextUI (Phase 1)
- Designing the Ideal OS boot sequence (Phase 1 — informed by this sprint's analysis)
- Runtime testing on physical hardware (flag device-dependent questions as open items)

## Files to Create or Modify

| Action | Path | Description |
|--------|------|-------------|
| Create | `upstream/nextui/notes/boot-flow-analysis.md` | Complete trace of both boot flows with hook point identification |
| Create | `upstream/nextui/notes/conflict-analysis.md` | Integration boundary analysis for all overlap zones |
| Modify | `upstream/nextui/manifest.md` | Update open questions section — resolve Q6, Q7, Q10 with findings |

## Acceptance Criteria

All must pass for the sprint to be considered complete.

1. **First-boot flow documented:** `boot-flow-analysis.md` contains a complete, ordered trace of the first-boot/install path — from `.tmp_update/updater` through forced power-off — with every script, binary, and config file listed with its path and purpose.
2. **Normal boot flow documented:** `boot-flow-analysis.md` contains a complete, ordered trace of the normal boot path — from power-on through `nextui.elf` main loop — with every script, binary, and config file listed with its path and purpose.
3. **Flows clearly separated:** The two boot flows are documented as distinct sections, not interleaved. A reader can trace either flow independently.
4. **Hook points identified:** Each flow has a "Hook Points" subsection listing specific locations where Ideal OS can inject behavior, with the file path, the mechanism (e.g., script replacement, wrapper, pre/post hook), and what Ideal OS feature it enables.
5. **Conflict zones analyzed:** `conflict-analysis.md` covers at minimum: `.system/` folder, PAK store, settings persistence, updater, and launcher. Each zone has: what NextUI does, what Ideal OS needs, the specific wrap/replace strategy, and affected files.
6. **Integration boundary defined:** `conflict-analysis.md` includes a clear boundary table or diagram showing which files/subsystems belong to the NextUI platform layer vs. Ideal OS core services.
7. **Open questions resolved:** Sprint 0.3 open questions Q6 and Q7 are answered in the conflict analysis (or explicitly flagged as requiring device validation with an explanation of what was learned).
8. **No source modifications:** Zero changes to any file under `upstream/nextui/src/`. This sprint is read-only against the NextUI source.

## Test Plan

### Automated Tests

This sprint produces only documentation — no code. No automated tests are required.

### Validation Checks

| Check | Method | Validates |
|-------|--------|-----------|
| Boot flow completeness | Cross-reference scripts listed in analysis against `skeleton/` directory listing | AC 1, 2 |
| Flow separation | Visual inspection — two distinct sections, no interleaving | AC 3 |
| Hook point specificity | Each hook point references a concrete file path and mechanism | AC 4 |
| Conflict zone coverage | Verify all 5 required zones are present in conflict analysis | AC 5 |
| Boundary clarity | Integration boundary table exists with file-level entries | AC 6 |
| Open question resolution | Q6, Q7 from manifest are addressed | AC 7 |
| No source modifications | `git diff upstream/nextui/src/` shows no changes | AC 8 |

### Manual Validation (if device-dependent)

- [ ] Some hook point feasibility may require on-device testing (e.g., "can `auto.sh` run before `nextui.elf`?"). Flag as open items — do not block on device access.

## Dependencies

- Sprint 0.1 (repo structure exists) — Complete
- Sprint 0.2 (shared data contracts) — Complete
- Sprint 0.3 (component manifest, update mechanism analysis) — Complete
- NextUI source present in `upstream/nextui/src/` — Complete (verified)

## Deliverable Details

### Boot Flow Analysis Structure (`upstream/nextui/notes/boot-flow-analysis.md`)

The document should be organized as:

```
## Overview
Brief summary: two flows, how they're triggered, key difference

## Flow 1: First Boot / Install-Update
### Trigger Condition
### Execution Sequence (ordered steps with file paths)
### File Reference Table (every file touched, its role)
### Hook Points for Ideal OS

## Flow 2: Normal Boot
### Trigger Condition
### Execution Sequence (ordered steps with file paths)
### File Reference Table (every file touched, its role)
### Hook Points for Ideal OS

## Comparison Table
Side-by-side: what's shared, what's different

## Open Questions (device-dependent)
```

### Conflict Analysis Structure (`upstream/nextui/notes/conflict-analysis.md`)

The document should be organized as:

```
## Integration Boundary
Summary table: NextUI platform layer vs. Ideal OS core services

## Conflict Zone: .system/ Folder
What NextUI does | What Ideal OS needs | Strategy | Affected files

## Conflict Zone: PAK Store and Tools
(same structure)

## Conflict Zone: Settings Persistence
(same structure)

## Conflict Zone: Updater / Install Flow
(same structure)

## Conflict Zone: Launcher (nextui.elf)
(same structure)

## Resolved Open Questions
Q6, Q7, Q10 from Sprint 0.3 — findings and conclusions
```

## Notes

- This sprint has no code deliverables and no automated tests. The "implementation" is structured analysis and documentation.
- The first-boot flow doubles as the update flow — same mechanism, same entry point. The analysis should make this explicit since it directly informs Ideal OS OTA design.
- The actual boot entry points are `main.sh` and `runtrimui.sh` in `skeleton/BOOT/trimui/app/`, not `launch.sh` or `auto.sh` (those names came from MinUI/CrossMix conventions and don't exist in the NextUI source). The analysis must trace from what actually exists.
- `main.sh` / `runtrimui.sh` are the most critical files — they're the bridge between both flows and the normal boot entry point. Give them thorough treatment.
- Device-dependent questions should be flagged for Sprint 1.2 (First Boot and Smoke Test) validation.
