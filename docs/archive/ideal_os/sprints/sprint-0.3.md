# Sprint 0.3 — NextUI Source Analysis and Component Mapping

## Phase

Phase 0 — Foundation

## Approved

<!-- The orchestrator or user sets this date when the spec is approved. -->
<!-- Agents MUST NOT begin implementation until this field contains a date. -->
**2026-03-11**

## Status

`complete`

Status definitions:
- `not-started` — Spec is being drafted or under review. No implementation allowed.
- `approved` — Spec is locked and approved for implementation. Set the Approved date above.
- `in-progress` — Actively implementing.
- `complete` — All acceptance criteria met and verified.

## Goal

Produce a complete, file-level analysis of the NextUI source tree — documenting every component's purpose, its disposition (keep/wrap/branch/rewrite), the build system, and the existing update mechanism — so that Phase 1 (Build Pipeline) and Phase 2 (OTA) can begin with full understanding of the codebase.

## Reference Specs

- `docs/architecture/ideal_os_platform_component_audit_matrix.md` — High-level disposition decisions (Keep/Wrap/Branch/Rewrite/Reject)
- `docs/implementation/ideal_os_fork_and_harvest_plan.md` — Integration strategy
- `docs/architecture/ideal_os_ota_update_architecture_spec.md` — OTA design goals (context for update mechanism analysis)
- `docs/architecture/ideal_os_nextui_platform_audit_reference.md` — Platform component overview

## Scope

### In Scope

- [ ] Walk the full NextUI source tree (`upstream/nextui/src/`) and produce a file-level component map
- [ ] Disposition every component against the audit matrix — but **remove nothing**
- [ ] Document the build system: makefiles, toolchain requirements, cross-compilation targets, artifact output
- [ ] Document NextUI's existing update mechanism: how updates are packaged, delivered, and applied
- [ ] Produce the component manifest (`upstream/nextui/manifest.md`)
- [ ] Produce build system analysis (`upstream/nextui/notes/build-system-analysis.md`)
- [ ] Produce update mechanism analysis (`upstream/nextui/notes/update-mechanism-analysis.md`)

### Out of Scope

- Removing, stripping, or modifying any NextUI source files
- Boot flow tracing (Sprint 0.4)
- Conflict analysis and integration boundary definitions (consolidated into Sprint 0.4)
- Writing any Ideal OS code or scripts
- Setting up CI/CD (Sprint 0.5)
- Cross-compiling or building NextUI (Phase 1)
- Answering every open question from the audit matrix — flag unknowns, don't guess

## Files to Create or Modify

| Action | Path | Description |
|--------|------|-------------|
| Create | `upstream/nextui/manifest.md` | File-level component map with disposition for every major directory and file |
| Create | `upstream/nextui/notes/build-system-analysis.md` | Build toolchain, makefile structure, cross-compilation targets, artifact outputs |
| Create | `upstream/nextui/notes/update-mechanism-analysis.md` | How NextUI packages, delivers, and applies updates |

## Acceptance Criteria

All must pass for the sprint to be considered complete.

1. **Component manifest exists:** `upstream/nextui/manifest.md` exists and covers every top-level directory and significant file under `upstream/nextui/src/`.
2. **Disposition assigned:** Every component in the manifest has a disposition (Keep / Wrap / Branch / Rewrite) that is consistent with the audit matrix. Where the audit matrix doesn't cover a specific file, a reasoned disposition is provided.
3. **No gaps in workspace coverage:** All directories under `workspace/all/`, `workspace/tg5040/`, `workspace/tg5050/`, and `workspace/desktop/` are documented. `workspace/_unmaintained/` is documented at summary level (what platforms exist, that they are inactive) but individual legacy platform directories do not require deep analysis.
4. **Skeleton documented:** The `skeleton/` directory tree is mapped — what each subdirectory contains and how it relates to the runtime filesystem.
5. **Build system documented:** `upstream/nextui/notes/build-system-analysis.md` describes the makefile structure, cross-compilation toolchain (compiler, flags, targets), build dependencies, and what artifacts are produced.
6. **Update mechanism documented:** `upstream/nextui/notes/update-mechanism-analysis.md` describes how NextUI currently handles updates — packaging format, delivery mechanism, apply process, and what Ideal OS can reuse vs. must replace.
7. **Open questions flagged:** Any component where the disposition cannot be confidently determined from source reading alone is flagged as an open question with a brief explanation of what device-level validation is needed.
8. **No source modifications:** Zero changes to any file under `upstream/nextui/src/`. This sprint is read-only against the NextUI source.

## Test Plan

### Automated Tests

This sprint produces only documentation — no code. No automated tests are required.

### Validation Checks

| Check | Method | Validates |
|-------|--------|-----------|
| Manifest completeness | Compare manifest entries against `ls` of source tree | AC 1, 3 |
| Disposition consistency | Cross-reference manifest dispositions against audit matrix | AC 2 |
| No source modifications | `git diff upstream/nextui/src/` shows no changes | AC 8 |

### Manual Validation (if device-dependent)

- [ ] Update mechanism analysis may flag questions that require device-level testing (e.g., "does the updater check signatures?"). These should be logged as open questions, not blocked on.

## Dependencies

- Sprint 0.1 (repo structure exists) — Complete
- Sprint 0.2 (shared data contracts) — Complete
- NextUI source present in `upstream/nextui/src/` — Complete (verified)

## Deliverable Details

### Manifest Structure (`upstream/nextui/manifest.md`)

The manifest should be organized by directory, with each entry containing:

```markdown
### `workspace/all/nextui/` — Main Launcher

**Purpose:** Primary UI shell — game browsing, launching, settings navigation.
**Key files:** `main.c` (3362 lines), `Makefile`
**Disposition:** Branch
**Rationale:** Too central to use as-is. Ideal OS needs session-aware UI, resume stack integration, notification display. Will be branched and incrementally modified.
**Open questions:** Where does the launcher read its game list from? How is the UI rendered (SDL, framebuffer, custom)?
```

This format is a guide, not rigid — adapt as needed for clarity.

### Build System Analysis Structure

Should cover:
- Top-level makefile orchestration (`makefile`, `makefile.toolchain`, `makefile.native`)
- Per-component build (how individual binaries in `workspace/` are compiled)
- Cross-compilation setup (toolchain path, target architecture, sysroot)
- Desktop build variant (`.env_desktop`, `makefile.native`)
- Build artifacts — what gets produced and where
- Dependencies — external libraries, headers, system requirements

### Update Mechanism Analysis Structure

Should cover:
- How NextUI releases are currently distributed (GitHub releases, SD card images, etc.)
- What the update package format looks like (zip, tarball, raw files)
- How updates are applied on-device (script, binary, manual copy)
- What `.system` replacement behavior means for Ideal OS
- What parts of the existing updater code live in the source tree
- Reuse assessment — what Ideal OS can build on vs. what needs replacing

## Notes

- This sprint has no code deliverables and no automated tests. The "implementation" is structured analysis and documentation.
- Read source files systematically — don't try to understand every line of C, focus on structure, purpose, and interfaces.
- The audit matrix provides high-level guidance but operates at the component level. This sprint's job is to go one level deeper — to individual directories and key files.
- Device-dependent questions (e.g., "does this binary get stripped?", "what does this do at runtime?") should be flagged as open questions for later validation, not blocked on.
