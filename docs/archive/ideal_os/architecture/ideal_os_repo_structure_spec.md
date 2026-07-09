# Ideal OS – Repository Structure Specification

## Spec Metadata
- **Version:** 1.1
- **Last reviewed:** Sprint 0.1
- **Status:** active
- **Sections with known open questions:** Missing `src/tasks/`, `src/sync/`, `src/notifications/` from source layout; missing corresponding `runtime/` and `config/` paths (see consistency audit items RS-1 through RS-3)

## Purpose

This document defines the canonical repository layout for Ideal OS.

The goals are to:

- prevent ad hoc folder creation
- separate upstream base code from Ideal OS customizations
- make Claude Code contributions predictable
- support OTA packaging and update delivery from the start
- keep runtime files, source files, assets, and release artifacts clearly separated

This structure should be treated as a contract. New top-level folders should not be created unless this document is updated first.

---

## Repository Principles

### 1. Upstream Isolation

Anything inherited from NextUI or other upstream sources should live in clearly marked locations.

Do not mix:

- upstream code
- Ideal OS code
- build outputs
- release artifacts

### 2. OTA-First Layout

The repository must support incremental updates, packaging, and version manifests without reorganizing the tree later.

OTA support is a first-class architectural concern, not a post-launch feature.

### 3. Predictable Paths

If Claude needs to add a launcher module, emulator config, session file handler, or update manifest, there should be exactly one obvious place to put it.

### 4. Runtime/Data Separation

Files used at build time should be separate from files used on-device at runtime.

### 5. Stable Public Interfaces

Subsystems should interact through stable interfaces and documented folders, not by scattering direct edits throughout the repo.

---

## Canonical Top-Level Layout

```text
ideal-os/
├── README.md
├── LICENSE
├── docs/
├── upstream/
├── src/
├── config/
├── assets/
├── runtime/
├── packages/
├── scripts/
├── tools/
├── tests/
├── release/
└── .github/
```

---

## Top-Level Folder Definitions

### `docs/`

Project documentation and design specs.

Examples:

- project charter
- feature specification
- architecture overview
- repo structure spec
- boot animation spec
- OTA design
- release checklist

Suggested layout:

```text
docs/
├── architecture/
├── product/
├── implementation/
└── release/
```

---

### `upstream/`

Contains tracked references to upstream projects.

Purpose:

- preserve imported NextUI source and notes
- document what was inherited vs replaced
- reduce confusion during merges or rebases

Suggested layout:

```text
upstream/
├── nextui/
│   ├── patches/
│   ├── notes/
│   └── manifest.md
└── references/
    ├── crossmix-notes.md
    ├── minui-notes.md
    └── portmaster-notes.md
```

Notes:

- Do not place active Ideal OS custom code here
- Use this folder for source tracking, patch notes, and upstream analysis

---

### `src/`

Primary source code for Ideal OS-specific logic.

This is where new development should happen.

Suggested layout:

```text
src/
├── launcher/
├── session/
├── library/
├── emulation/
├── system/
├── updater/
├── tasks/
├── sync/
├── notifications/
└── common/
```

Module definitions:

- `launcher/` → UI flow, home screen, game switcher, navigation
- `session/` → suspend/resume logic, resume stack, session persistence
- `library/` → ROM discovery, favorites, recents, collections, search index
- `emulation/` → launch orchestration, core selection, runtime wrappers
- `system/` → power hooks, device integration glue, brightness/volume integration
- `updater/` → OTA manifest parsing, update checks, package validation, patch apply flow
- `tasks/` → background task scheduler, queue management, eligibility evaluation, power-event orchestration
- `sync/` → cloud sync engine, artifact index, change detection, provider adapters
- `notifications/` → notification policy engine, tier classification, guardian alerts
- `common/` → shared helpers, logging, config readers, game identity model, event bus, utility code

Rule:

All new Ideal OS logic belongs in `src/` unless it is pure documentation, test content, or build tooling.

---

### `config/`

Static configuration shipped with the OS.

Suggested layout:

```text
config/
├── emulators/
│   ├── systems/
│   ├── cores/
│   └── hotkeys/
├── ui/
├── power/
├── portmaster/
├── updater/
├── tasks/
├── sync/
└── notifications/
```

Examples:

- default emulator core selection by platform
- shader defaults
- hotkey mappings
- UI behavior flags
- OTA server endpoints or channels

Important:

Do not store generated runtime data here. This folder is for version-controlled defaults only.

---

### `assets/`

Static user-facing media.

Suggested layout:

```text
assets/
├── boot/
├── branding/
├── themes/
├── icons/
└── boxart-placeholders/
```

Examples:

- TrimUI-to-Ideal boot animation assets
- Ideal OS logo
- starfield backgrounds
- UI icons
- default fallback artwork

---

### `runtime/`

On-device runtime layout templates and persistent data schemas.

This folder documents how runtime files are organized on the device.

Suggested layout:

```text
runtime/
├── filesystem/
│   ├── overlay/
│   ├── userdata/
│   └── migrations/
├── sessions/
│   └── schema/
├── library/
│   └── schema/
├── updater/
│   ├── schema/
│   └── staging/
├── tasks/
│   └── queues/
├── sync/
│   └── queue/
├── notifications/
│   └── logs/
└── events/
```

Examples:

- session metadata schema
- library database schema
- migration rules between releases
- OTA staging folder layout

Important:

This is not a dumping ground for local dev files. It defines runtime structure and migration expectations.

---

### `packages/`

Buildable package definitions.

Purpose:

- organize what becomes installable/updateable units
- support full image generation and OTA patch generation

Suggested layout:

```text
packages/
├── base/
├── launcher/
├── session-manager/
├── library/
├── assets/
├── updater/
├── task-scheduler/
├── cloud-sync/
└── notifications/
```

Why this matters:

If OTA is a real goal, updates should eventually map to package boundaries or at least package-like release units.

This reduces the need to replace the entire image just to update one subsystem.

---

### `scripts/`

Build and automation scripts.

Suggested layout:

```text
scripts/
├── setup/
├── build/
├── package/
├── ota/
└── release/
```

Examples:

- dev environment bootstrap
- package builder
- release bundling
- OTA manifest generation
- checksum/signature generation

Rule:

Shell glue and CI-oriented scripts go here. Do not bury release automation inside random tool folders.

---

### `tools/`

Developer utilities that are not part of the shipping OS.

Examples:

- ROM library simulators
- session inspection tools
- metadata migration helpers
- packaging validators
- screenshot or asset conversion tools

Suggested layout:

```text
tools/
├── dev/
├── diagnostics/
└── migration/
```

---

### `tests/`

Automated and manual test assets.

Suggested layout:

```text
tests/
├── unit/
├── integration/
├── fixtures/
└── manual/
```

Examples:

- session lifecycle tests
- library indexing tests
- OTA manifest validation tests
- sample metadata fixtures
- device test checklist

---

### `release/`

Generated release outputs and release metadata definitions.

Suggested layout:

```text
release/
├── manifests/
├── channels/
├── notes/
└── artifacts/
```

Examples:

- stable/beta channel manifests
- release notes
- generated package indexes
- OTA payload descriptors

Important:

This folder may contain generated files or templates, but it should not become a second copy of `packages/`. It describes what gets shipped, not the source for how it is built.

---

### `.github/`

CI workflows, issue templates, pull request templates, release pipelines.

Suggested layout:

```text
.github/
├── workflows/
├── ISSUE_TEMPLATE/
└── PULL_REQUEST_TEMPLATE.md
```

---

## Recommended Internal Module Boundaries

Claude should respect these module boundaries.

### Launcher Module

Path:

```text
src/launcher/
```

Responsibilities:

- home screen
- recent games view
- favorites view
- collections view
- game switcher UI
- settings entry points

Should not directly implement:

- emulator save state logic
- low-level power handling
- OTA patch application

---

### Session Module

Path:

```text
src/session/
```

Responsibilities:

- create session record
- save state on suspend
- restore session
- maintain resume stack
- prune expired sessions

Owns runtime schemas under:

```text
runtime/sessions/
```

---

### Library Module

Path:

```text
src/library/
```

Responsibilities:

- ROM scan
- metadata ingestion
- favorites
- recents
- collections
- optional search

Owns runtime schemas under:

```text
runtime/library/
```

---

### Updater Module

Path:

```text
src/updater/
```

Responsibilities:

- check for updates
- read channel manifests
- compare installed vs available versions
- validate payloads
- stage and apply updates
- trigger migrations if required

Owns default settings under:

```text
config/updater/
```

Owns runtime schemas under:

```text
runtime/updater/
```

---

## OTA-First Design Considerations

Yes — this is exactly where the repo structure needs to go.

If OTA matters, the repository must be structured so updates can be generated, validated, and applied without rethinking the tree later.

### OTA Requirements to Support Early

#### 1. Versioned Manifests

Need a clear place for release manifests.

Recommended paths:

```text
release/manifests/
release/channels/
```

Examples:

- `stable.json`
- `beta.json`
- `2601.1.json`

#### 2. Update Package Boundaries

Subsystems should be grouped so they can be packaged independently where practical.

Candidate update units:

- launcher
- session manager
- library
- assets
- updater

#### 3. Migration Support

When a new release changes session or library schema, the OS will need migration logic.

Recommended path:

```text
runtime/filesystem/migrations/
tools/migration/
```

#### 4. Channel Awareness

Testing will be easier if you support:

- stable
- beta
- dev

from the beginning.

Recommended config location:

```text
config/updater/channels/
```

#### 5. Staging Area

OTA updates often need a temporary on-device staging path before activation.

Document this under:

```text
runtime/updater/schema/
```

---

## Suggested OTA Flow

Conceptual flow:

```text
Check channel manifest
→ Compare installed stardate to available stardate
→ Download package(s)
→ Verify checksum/signature
→ Stage payload
→ Apply update
→ Run migrations if needed
→ Reboot into updated system
```

This means OTA is not just a script. It is a full subsystem and should be treated that way in the source tree.

---

## Naming Rules for Claude Code

To prevent random folder sprawl, use these rules:

### Rule 1

Do not create a new top-level folder without first updating this spec.

### Rule 2

Do not place new source code in `upstream/`, `assets/`, or `release/`.

### Rule 3

Do not place generated files in `src/` or `config/`.

### Rule 4

Do not place runtime data examples in arbitrary markdown docs; store schemas under `runtime/`.

### Rule 5

If functionality belongs to launcher, session, library, emulation, system, updater, tasks, sync, notifications, or common, place it in that module first unless there is a documented reason not to.

---

## Initial Folder Skeleton

Recommended starting layout:

```text
ideal-os/
├── README.md
├── docs/
│   ├── architecture/
│   ├── implementation/
│   ├── product/
│   └── release/
├── upstream/
│   ├── nextui/
│   └── references/
├── src/
│   ├── launcher/
│   ├── session/
│   ├── library/
│   ├── emulation/
│   ├── system/
│   ├── updater/
│   ├── tasks/
│   ├── sync/
│   ├── notifications/
│   └── common/
├── config/
│   ├── emulators/
│   ├── ui/
│   ├── power/
│   ├── portmaster/
│   ├── updater/
│   ├── tasks/
│   ├── sync/
│   └── notifications/
├── assets/
│   ├── boot/
│   ├── branding/
│   ├── themes/
│   └── icons/
├── runtime/
│   ├── filesystem/
│   ├── sessions/
│   ├── library/
│   ├── updater/
│   │   ├── schema/
│   │   └── staging/
│   ├── tasks/
│   ├── sync/
│   ├── notifications/
│   └── events/
├── packages/
│   ├── base/
│   ├── launcher/
│   ├── session-manager/
│   ├── library/
│   ├── assets/
│   ├── updater/
│   ├── task-scheduler/
│   ├── cloud-sync/
│   └── notifications/
├── scripts/
│   ├── setup/
│   ├── build/
│   ├── package/
│   ├── ota/
│   └── release/
├── tools/
│   ├── dev/
│   ├── diagnostics/
│   └── migration/
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── fixtures/
│   └── manual/
├── release/
│   ├── manifests/
│   ├── channels/
│   ├── notes/
│   └── artifacts/
└── .github/
    └── workflows/
```

---

## Recommendation

For Ideal OS, the repository should be designed from day one as:

- a curated handheld OS project
- a modular codebase
- an OTA-capable release system

So yes, your instinct is right:

OTA should absolutely influence the repo structure now, not later.

That will make device testing dramatically easier and will reduce the pain of pushing frequent changes to your TrimUI Brick during development.

