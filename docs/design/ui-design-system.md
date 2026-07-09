# Continuity UI Design System — Cross-Platform Spec

**Status:** Approved 2026-07-09 (all four §7 decisions accepted: normative
status semantics; color-never-alone; scope = interaction/IA/content now
with visual deferred; gates the platform UI sprints). The umbrella design
gate for every platform's user-facing surface (NextUI PAK 1.5, RetroDeck
2.1/2.2, Onion 3.1, Android 3.2, any future desktop). The conflict-
resolution experience (`docs/design/conflict-resolution-experience.md`) is
the first flow that slots *under* this system. No claim here overrides that
doc; this defines the shared language it and every other surface speak.

**Goal:** make Continuity feel like *one product* whether the user is
looking at a single line of text on a TrimUI Brick, a desktop window on a
Steam Deck, or a Material app on an Android handheld — **without** pretending
those are the same UI. Uniformity of *model, vocabulary, and status
semantics*; native rendering per platform.

## 1. The capability tiers (design to the spectrum, not one screen)

Continuity's surfaces span a wide capability range. Every screen is
specified once as an abstract state and rendered per tier:

| Tier | Platforms | Rendering primitive | Constraint |
|---|---|---|---|
| **0 — Line** | NextUI, Onion | `show2.elf`-class single text line + buttons (B/A/Y/X) | ~1 line, ~64 chars, no scrollback, 4 buttons |
| **1 — Text** | RetroDeck (CLI/notify), headless | multi-line text / desktop notifications | a few lines, a pointer, maybe a prompt |
| **2 — Graphical** | RetroDeck (desktop), Android | native toolkit (Material / GTK-ish) | lists, panes, dialogs, color |

**Tier 0 is the floor and the discipline.** If a flow can't be expressed as
a sequence of single-line prompts + four buttons, it's too complex —
simplify the model, don't special-case the Brick. Richer tiers *add
affordances* (see-at-once lists, side-by-side compare), never *add steps
the floor can't reach.*

## 2. Shared information architecture (what every surface exposes)

Every Continuity surface presents the same things in the same priority
order, however it renders them:

1. **Sync status** — last sync time, pending/queued count, online/offline.
   The default/home view.
2. **Conflicts** — the one urgent item; badged count; entry into the
   conflict-resolution flow (that doc owns the flow, this owns its framing
   and status language).
3. **Linked devices** — who else syncs this repo (from
   `.continuity/devices/`), last-seen.
4. **Actions** — Sync now; Resolve; Unlink this device.
5. **Diagnostics** — build stamp + the last failure, always self-naming
   (the observability requirement: every failure names itself on-screen
   with the build stamp).

A tier decides *how many of these are visible at once* (Tier 2: all, in a
dashboard; Tier 0: one at a time, status first, conflicts surfaced by a
persistent indicator), never *which exist*.

## 3. Status semantics (normative — the strongest uniformity lever)

Continuity already speaks green/yellow/red on NextUI (colored dots via
`pal_on_sync_result`). Make that mapping **normative across all platforms**
so a color means the same thing everywhere:

| State | Meaning | Word (always shown) | Persistence |
|---|---|---|---|
| **Green** | Synced / pushed — you're safe | `Synced` | transient |
| **Yellow** | Queued / offline — will sync when able | `Queued` / `Offline` | transient |
| **Red** | Conflict or error — needs you | `Conflict` / `Error` | **persistent until resolved** |

- **Color is never the only signal.** Every status carries a **word (and,
  where the tier allows, a glyph)** — colorblind users, the ~8% who can't
  distinguish the Brick's red/green dots, and grayscale panels all still
  read it. This makes the existing NextUI dot behavior a small change:
  pair every dot with its word. *(This is the one behavioral tweak this
  system asks of already-built code.)*
- **Red is the only persistent state.** Sync success/queued are transient
  notifications; a conflict/error stays visible until acted on. This is the
  cross-platform version of the "persistent red dot" the conflict-UX design
  relies on as its passive entry point.

## 4. Interaction vocabulary (normative words, per platform rendering)

One set of verbs, identical wording everywhere (localization aside):

- **Sync now** — force a push/pull.
- **Resolve** — enter conflict resolution.
- **Try** — load a save version to inspect it in the game (conflict-UX §5).
- **Keep** — choose the canonical version.
- **Unlink** — remove this device's registration + credentials.

Nouns: a **save** (never "file"), a **conflict** (per *game*, per the
group-by-game decision), a **device** (by its enrolled name). Voice: short,
honest, self-naming on failure; no git jargon surfaced to users ("save
reaches the cloud when you take a break", not "push rejected, will
reconcile" — that's a log line, not UI copy).

## 5. The degradation contract (one flow, three renderings)

Worked example — the conflict list (owned in flow by the conflict-UX doc,
in *form* here):

- **Tier 2 (Android/desktop):** a list of conflicted games, each a row with
  the two devices + a "Resolve" affordance; tap → detail pane.
- **Tier 1 (RetroDeck notify/CLI):** a desktop notification "2 save
  conflicts — open Continuity to resolve"; the CLI prints a numbered list.
- **Tier 0 (Brick/Onion):** `Conflicts (1/2): Pokemon Crystal  A=open
  Y=next  B=exit` — one line, paged by button.

The **state** ("N conflicts, currently viewing item i, actions available")
is identical; only the rendering differs. Every multi-item view defines its
Tier-0 paging (`Y=next`) and its Tier-2 list form.

## 6. How this binds to the code

- **Shell tiers (0/1)** render the design system through the **`pal_ui_*`
  contract** defined in the conflict-UX design (§6 there): `pal_ui_menu`,
  `pal_ui_message`, `pal_ui_confirm`, `pal_ui_handoff`. This design system
  is what those primitives must *look and read like* (status words, verb
  names, one-line paging). The shared `conflict_ui.sh` controller is the
  first consumer; a future `status_ui.sh` (home/status/devices) is the
  second, and reuses the same `pal_ui_*` surface.
- **Graphical tier (2)** implements the same IA, status semantics, and
  vocabulary in the native toolkit — no shared code, shared *contract*
  (same as the conflict-UX Android story).
- **This system does not add new PAL requirements beyond `pal_ui_*`.** It
  constrains what those primitives render, and asks one tweak of existing
  code: pair every status color with its word (§3).

## 7. Decisions (all accepted 2026-07-09)

1. **Normative status semantics (§3)** — lock green/yellow/red + the words
   `Synced`/`Queued`/`Offline`/`Conflict`/`Error` across all platforms?
   Recommend **yes** — it's the cheapest, highest-impact uniformity.
2. **Color-never-alone rule (§3)** — require a word (+ glyph where possible)
   with every status, i.e. a small change to NextUI's `pal_on_sync_result`
   to pair each dot with a word? Recommend **yes** (accessibility + grayscale
   + the Brick's tiny dots).
3. **Scope of "design system" now** — interaction + IA + status/content
   language (this doc), with **visual** specifics (spacing, type, Material
   theming) deferred to the first Tier-2 sprint that needs them? Recommend
   **yes** — no Tier-2 surface is built yet, so pixel-level design now would
   be speculative.
4. **Gate status** — does this umbrella gate the platform UI sprints (1.5,
   2.1/2.2, 3.1, 3.2) the way the conflict-UX design does? Recommend
   **yes** — each UI sprint declares which tier it targets and conforms to
   §§2–5; the conflict-UX design nests under it.

## 8. Out of scope

- Pixel-level visual design (type scale, spacing, Material theme) — deferred
  to the first Tier-2 platform sprint (§7.3).
- Localization/i18n mechanics (the vocabulary is defined in English; the
  *structure* is localization-ready, the tooling is later).
- The conflict-resolution *flow* itself — owned by
  `docs/design/conflict-resolution-experience.md`; this doc governs its
  framing, status language, and rendering tiers only.
- Enrollment/onboarding UX (the `setup.json` import + web experience,
  Sprint 4.1) — related but a separate surface; this system's IA/status/
  vocabulary apply to it when it's specced.
