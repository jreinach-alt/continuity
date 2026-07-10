# Android Client Architecture — Sprint 3.2 Scoping

**Status:** Approved 2026-07-09 (all five §8 decisions accepted as
recommended: `MANAGE_EXTERNAL_STORAGE` storage; lifecycle-triggered +
WorkManager background; JGit; a mandatory cross-language conformance suite;
the 3.2a/b/c breakdown). Design gate for the Android platform sprint(s). Android is a **native Kotlin reimplementation** of the
already-settled contracts, not a shell port — so this doc's job is to pin
what it must conform to, name the two genuinely Android-specific hard
problems, and propose a sprint breakdown. Validation device: the owner's
**Ayn Thor** (Android). Nests under `docs/design/ui-design-system.md` and
implements `docs/design/conflict-resolution-experience.md` +
`docs/design/save-format-canonicalization.md`.

## 1. Why Android is different (and where it's actually *easier*)

Unlike the NextUI/Onion handhelds, Android needs **no cross-compiled git**
— JGit is pure-Java, so the toolchain fight that dominated Phase 1 simply
doesn't exist here. In exchange, Android imposes **two hard problems the
shell platforms never had** — storage access and background execution
(§4) — plus one structural risk: because Android *reimplements* the sync
logic in Kotlin rather than reusing `src/core/`, that logic can **drift**
from the shell reference (§5). Those three things are the whole sprint.

## 2. The shared contracts Android MUST conform to (normative)

The **on-repo artifacts are the cross-platform interface** — Android must
produce and consume byte-identical artifacts so a save round-trips through
the Brick, Deck, and Onion untouched:

- **Canonical save layout (2.0):** `<canonical_system>/<basename>.srm`
  (raw SRAM), `.rtc` sibling, per the canonicalization spec. Name-style
  mapping (`retroarch` for Android), ROM-anchored identity, container
  sniff + **RZIP quarantine** — all reimplemented in Kotlin.
- **`.conflict` v2 schema + `.local` + trying markers** (conflict-UX §3)
  — byte-identical JSON (`_schema_version`, `identity`, `class`,
  `remote_device`/`_timestamp`, `local_device`/`_timestamp`, `source`,
  `status`), same `<path>.<device>.local` naming.
- **`.continuity/` layout:** `config.json`, `devices/<name>.json`, the
  commit-tracking + sentinel-equivalent state, the same `device:` commit
  trailer the digest and conflict handler parse.
- **Sync phases (0.4–0.8):** cold start, boot pull, runtime detection,
  stale recovery, conflict preservation — the same semantics, reimplemented.
- **Conflict UX (design §4/§5):** the resolution state machine + guards
  (group-by-identity, trying-modified "third version", `keep_newest`
  clock-guard), rendered as native **Material** (UI design system Tier 2:
  status words `Synced`/`Queued`/`Offline`/`Conflict`/`Error`,
  color-never-alone, the same interaction vocabulary).

## 3. Git & credentials — the easy part (JGit)

- **JGit** (pure-Java) handles clone/fetch/push/commit/merge over HTTPS
  with the user's fine-grained PAT — no native binary, no cross-compile,
  no `git remote-https` exec dance. This is the one area Android is
  simpler than every shell platform.
- **PAT storage:** Android Keystore-backed `EncryptedSharedPreferences`.
  The security model is unchanged — the user's PAT, scoped to one repo,
  stored on-device; scope is the boundary (security-model.md).

## 4. The two Android-specific hard problems

### 4a. Storage access (crux #1)

Modern Android's **Scoped Storage** blocks an app from freely reading
another app's (RetroArch's) save directory. Two viable models:

- **`MANAGE_EXTERNAL_STORAGE`** ("All files access") — direct `File`
  access to `/storage/emulated/0/RetroArch/saves/…`, matching the daemon
  model. Play-Store-restricted, but fine for a **sideloaded retro-handheld
  companion**. Simplest; recommended for the Ayn Thor.
- **SAF (Storage Access Framework)** — user grants a directory tree via a
  picker; access is through `DocumentFile`/`ContentResolver` URIs, not
  `File` paths. Play-compliant but slower and a larger rewrite of every
  path operation.

The choice ripples through the entire file layer (change detection, the
mapper's path handling, JGit's working tree location). **[Decision 1]**

### 4b. Background execution (crux #2)

Android kills background processes, so the shell "poll every 30s forever"
daemon isn't viable as-is. Options (combinable):

- **Foreground service** — a persistent notification lets it run
  continuously; the closest analogue to the daemon (real-time-ish sync).
- **WorkManager** — battery-friendly periodic sync (≥15-min floor) +
  expedited work on triggers; not real-time.
- **Lifecycle-triggered sync** — sync on app foreground/background and on
  known "save happened" moments; pairs with either of the above.
- **FileObserver** (roadmap mention) — only fires while the process is
  alive and is unreliable on shared storage under Scoped Storage; usable
  *inside* a foreground service, not as the primary trigger.

The retro-handheld usage pattern (play, then sync) makes
**lifecycle-triggered + WorkManager periodic** the battery-sane default,
with an optional foreground service during active play. **[Decision 2]**

## 5. The reimplementation risk — conformance (crux #3)

Reimplementing canonicalization, the `.conflict` writer, and the sync
phases in Kotlin means they can **silently diverge** from the shell
reference — and divergence breaks interop (a mis-canonicalized name or a
mis-shaped `.conflict` splits saves across devices). Per the project's
"validate against the reference, not memory" ethos (the rzip oracle, the
busybox matrix), the mitigation is a **cross-language conformance suite**:

- A shared fixture corpus (name-mapping cases, container samples, `.conflict`
  shapes) that BOTH the shell reference and the Kotlin implementation run,
  asserting **byte-identical** canonical names + `.conflict` JSON + `.local`
  bytes. This is mandatory, not optional. **[Decision 3]**

## 6. RetroArch Android specifics

- `config/platform_maps/retroarch_android.json` → **v2** (`save_name_style:
  retroarch`, `save_container`, `rom_roots`), like onion/retrodeck —
  **validated against the Ayn Thor's real RetroArch config + save
  filenames** (the "byte claims tested against real files" rule; Sprint
  2.0's real-repo sweep is the precedent). The map already carries the
  RetroArch full-folder system names (`Nintendo - Game Boy`, …).
- Confirm on-device: RetroArch's actual save path (user-configurable), and
  whether RetroArch Android has save compression on (those `.srm`
  quarantine per 2.0 Decision 1A).

## 7. Proposed sprint breakdown (a mini-phase, like NextUI Phase 1)

Android is too big for one sprint. Proposed:

- **3.2a — Android sync core + enrollment (parity with RetroDeck 2.1):**
  canonicalization + the sync phases in Kotlin, JGit, the storage model
  (§4a), the background model (§4b), enrollment + PAT storage. Gated by the
  conformance suite (§5) + on-Thor sync + a cross-device round-trip with
  the Brick/Deck (the 2.3 protocol, extended to a third device).
- **3.2b — Android conflict UI:** native Material reimplementation of the
  conflict-UX state machine, reading/writing the same `.conflict`/`.local`
  artifacts; interop-tested (an Android-written conflict resolves on the
  Brick and vice versa).
- **3.2c — polish:** status UI, notifications, log, WorkManager tuning.

Each is spec-gated and owner-merged, same methodology as the shell sprints.

## 8. Decisions (accepted 2026-07-09, as recommended)

1. **Storage model (§4a):** `MANAGE_EXTERNAL_STORAGE` (direct, sideload) vs
   SAF (Play-compliant, URI). Recommend **MANAGE_EXTERNAL_STORAGE** — it's a
   sideloaded companion on a retro handheld; direct file access matches the
   daemon model and keeps the path/mapper layer simple.
2. **Background model (§4b):** recommend **lifecycle-triggered + WorkManager
   periodic**, optional foreground service during active play — battery-sane
   and matches how a handheld is used. (Foreground-service-only is more
   daemon-faithful but noisier.)
3. **Conformance suite (§5):** recommend **mandatory** — a shared
   cross-language fixture corpus asserting byte-identical canonical output.
   Non-negotiable for interop, given Kotlin can't reuse `src/core/`.
4. **Sprint breakdown (§7):** recommend the **3.2a/b/c split**, sync-parity
   first. (Alternative: one big 3.2 — riskier to review/validate.)
5. **Toolchain/model:** JGit confirmed (pure-Java, no cross-compile). The
   Kotlin work is mostly **Opus**; the byte-level canonicalization/RZIP
   parity is the one place to consider **Fable** if it gets hairy (it's the
   same class as the shell codec work).

## 9. Out of scope / risks

- **The two cruxes (storage + background) are the real risk** — flag them
  up front; they, not the sync logic, will dominate 3.2a.
- **Play Store distribution** — sideload first; SAF/Play-compliance is a
  later concern if it's ever published.
- **Save-state sync** — out of scope project-wide.
- **A shared Kotlin core across future JVM platforms** — premature; one
  Android client first.
