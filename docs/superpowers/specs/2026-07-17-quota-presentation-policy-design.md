# Quota Presentation Policy Design

**Backlog source:** I001 — Collapse quota presentation policy  
**Date:** 17 July 2026  
**Status:** Approved for implementation planning; no implementation is included in this document.

## Problem

Quota presentation policy is currently split across `QuotaCommon.js` and its rendering callers. Account cards—and therefore both compact and full `CardsView` surfaces—use `visibleWindows()`, while detail and the applet tooltip compose `primaryWindows()` and `extraWindows()` differently. `main.qml` also retains obsolete compact-sync scalars derived from `primaryWindows()`. Callers resolve labels and colour modes independently.

This shallow selector choreography allowed an explicitly selected extra quota to appear in account cards while remaining absent or secondary elsewhere. A visibility-only test could pass even when a rendering caller chose the wrong selector. The interface therefore lacks locality: role, visibility, ordering, label, and colour-mode knowledge can drift at each call site.

## Goals

- Establish one deep quota-presentation module with a small, pure interface.
- Make “explicitly selected means visible everywhere” an invariant.
- Give cards, detail, compact summary, row hover, and applet tooltip the same ordered presentation rows.
- Put selection, ordering, label resolution, colour-mode choice, and fallback policy behind one seam.
- Test policy through the interface and verify that rendering callers cross that seam.
- Remove primary/extra selector choreography from rendering callers.

## Non-goals

- Change quota discovery, parsing, credentials, refresh transactions, or response caching.
- Change persisted visibility configuration or migrate its JSON format.
- Deduplicate provider windows.
- Redesign loading, error, or empty-state behaviour.
- Change pacing calculations, reset countdown logic, or Plasma theme colour calculation.
- Implement the change as part of this planning work.

## Current State

- `contents/ui/AccountCard.qml` repeats `QuotaCommon.visibleWindows(profile)`, so it already shows every selected window.
- Both compact and full representations render `CardsView`, which delegates to `AccountCard`; compact display therefore already includes selected extras.
- `contents/ui/DetailWindow.qml` renders separate Primary and Extra lists from `primaryWindows()` and `extraWindows()`.
- `contents/ui/main.qml::syncCompactFromController()` still computes unused fixed session/weekly scalar state from `primaryWindows()`; that state now affects only loading detection and diagnostic logging, not compact rendering.
- `contents/ui/main.qml` retains unused colour helpers and `primaryWindowsFor()` from the former fixed compact implementation.
- `contents/ui/main.qml::tooltipText()` includes only `primaryWindows()`.
- `contents/ui/QuotaRow.qml` derives its own label and receives a caller-selected colour mode.
- `tests/test-visibility.mjs` verifies configuration application and all-visible selection, but it does not prove that every rendering caller uses that policy.

## Chosen Architecture

Create a pure JavaScript module at `contents/ui/js/QuotaPresentation.js` with one caller-facing interface:

```js
presentProfile(profile, {
    sessionColorMode,
    weeklyColorMode
}) -> {
    rows: [
        {
            windowData,
            label,
            colorMode
        }
    ]
}
```

The options object uses the exact keys `sessionColorMode` and `weeklyColorMode`; omitted or empty values retain the existing `capacity` and `efficiency` defaults. The module may use low-level `QuotaCommon.js` helpers as implementation details. Rendering callers must not directly invoke `primaryWindows`, `extraWindows`, `visibleWindows`, `displayWindowLabel`, or `colorModeForWindow`.

This is a deep module because one small interface owns policy used by four rendering surfaces and their tests. Deleting it would force selection, ordering, label, colour-mode, and fallback knowledge back into every caller.

### Rejected alternatives

1. **Surface-specific projections** — `cardRows()`, `detailRows()`, `compactRows()`, and `tooltipRows()` would encode distinctions that the product no longer wants. The larger interface would allow policy drift.
2. **A QML presentation model** — QML reactivity would be convenient, but tooltip formatting would still need a separate path and Node tests could not exercise the real interface cleanly.
3. **Keep extending `QuotaCommon.js`** — adding another selector would preserve the shallow interface rather than concentrate presentation policy at a named seam.

## Presentation Invariants

`presentProfile()` must:

1. Return an object with a `rows` array.
2. Return an empty array for a null profile, a missing/non-array `windows` property, or an empty window list.
3. Skip null window entries.
4. Exclude a window only when `visible === false`.
5. Treat primary, extra, missing, and unknown roles equally.
6. Preserve the order of `profile.windows`; role must not regroup rows.
7. Return fresh presentation-row objects without mutating the profile or window objects.
8. Retain the original window by reference as `windowData` for live usage/reset fields.
9. Resolve each row’s label once by delegating to `QuotaCommon.displayWindowLabel()`, including its provider/id canonicalisation rules before its generic label, ID, recognised-column, and empty-text fallbacks.
10. Resolve each row’s colour mode using existing session/weekly preference semantics and defaults.
11. Exclude `nowMs` from the snapshot so countdown and pacing updates do not rebuild presentation rows each tick.

Duplicate IDs remain separate rows. The module must not silently collapse potentially distinct provider quota data.

## Module and Caller Responsibilities

### `QuotaPresentation.js`

Owns:

- selected-row filtering;
- stable ordering;
- role-independent treatment;
- label resolution;
- colour-mode selection;
- malformed-input fallbacks;
- construction of presentation rows.

Does not own:

- profile loading/error state;
- persisted visibility configuration;
- time-dependent countdowns;
- pace calculations;
- Plasma theme colour values;
- layout density.

### `QuotaRow.qml`

Exposes `property var presentationRow: null` and consumes one presentation row:

- `presentationRow.windowData` supplies usage, reset, period, and tooltip-extra data;
- `presentationRow.label` supplies visible and hover labels;
- `presentationRow.colorMode` supplies pace-bar mode.

It retains time-sensitive calculations using `nowMs` and the Plasma theme. Skeleton mode remains available without a presentation row.

### `AccountCard.qml`

Repeats `presentProfile(profile, options).rows`. Its current visible behaviour is preserved, but it no longer chooses visibility or colour policy itself.

### `DetailWindow.qml`

Repeats the same rows in one section labelled “Quotas”. The Primary and Extra sections are removed because selected extra quotas receive equal treatment.

### `main.qml` compact sync cleanup

Compact rendering already flows through `CardsView` and `AccountCard`, so it gains the shared presentation rows through the card migration without a new renderer. Remove the obsolete session/weekly scalar properties and unused colour/helper functions from the former fixed compact implementation. Update loading detection and diagnostic logging to use the selected profile’s presentation-row count.

Existing profile selection, `CardsView` layout, loading, and error behaviour remains unchanged.

### `main.qml` applet tooltip

Calls `presentProfile()` for every enabled profile and formats every returned row. Labels come from the presentation row; usage and reset countdown values come from `windowData`.

### Row hover tooltip

Uses the presentation row’s label and colour mode while retaining the existing usage, countdown, and `tooltipExtra` content.

## Data Flow

```text
ProfileController profile
        │
        ▼
QuotaPresentation.presentProfile(profile, colour preferences)
        │
        └── ordered presentation rows
              ├── AccountCard repeater
              │     └── compact and full CardsView surfaces
              ├── DetailWindow repeater
              └── Applet tooltip formatter
```

`ProfileController` remains the owner of raw profile state. QML bindings recompute the snapshot when the profile/window array or colour preferences change. The returned rows hold raw windows by reference, so existing usage/reset data remains available without copying or mutating controller state.

## Error and Edge-case Behaviour

- Null/malformed profiles produce no rows and do not throw.
- Missing `visible` means visible, matching existing configuration semantics.
- `visible === false` removes the row from every surface.
- Unknown roles remain visible and are not reclassified by callers.
- Missing labels use the established fallback chain.
- Invalid usage/reset fields continue through existing rendering fallbacks; presentation does not reinterpret provider data.
- Loading, profile errors, and no-data placeholders remain caller-owned and unchanged.
- A selected profile with more than two visible quotas continues to expand its compact account card through the existing `CardsView`/`AccountCard` layout rather than truncating or cycling rows.

## Testing Strategy

### Pure interface tests

Add a Node test that loads `QuotaCommon.js` and `QuotaPresentation.js` through the existing VM-based pattern. Verify:

- null and malformed profiles return `rows: []`;
- null windows are skipped;
- only `visible === false` hides;
- missing visibility remains visible;
- primary, extra, missing, and unknown roles are equal;
- source order is stable;
- duplicate IDs survive;
- labels and colour modes use existing semantics;
- source objects are not mutated.

### Rendering-seam tests

- Add a Qt Quick test fixture with one primary and one explicitly selected extra window.
- Instantiate account-card and detail rendering and assert both labels and percentages are visible.
- Verify detail has one quota section and no role-based split.
- Add a focused source-contract test for `main.qml` because a full Plasmoid runtime is not available in the existing Node harness. It must prove tooltip and compact-sync paths consume `presentProfile().rows`, compact rendering still delegates through `CardsView`/`AccountCard`, obsolete fixed-slot state is gone, and rendering callers no longer invoke the old selector cluster.
- Preserve `tests/test-visibility.mjs` for visibility-configuration behaviour; presentation tests cover the separate rendering seam.

## Migration Sequence

1. Add failing pure-interface tests, then introduce `QuotaPresentation.js`.
2. Adapt `QuotaRow.qml` to accept a presentation row and migrate `AccountCard.qml`.
3. Replace detail’s role-separated lists with one presentation-row list.
4. Remove obsolete fixed-window compact-sync state and helpers; use presentation-row count for loading detection and diagnostics.
5. Route applet tooltip generation through the same snapshot.
6. Add rendering/wiring regression coverage.
7. Remove unused `primaryWindows`, `extraWindows`, and `visibleWindows` selector choreography. Keep low-level `QuotaCommon` helpers only where the presentation module needs them internally.
8. Run all Node, shell, and Qt Quick tests.

## Acceptance Criteria

- Every explicitly selected quota appears in account cards, detail, compact representation, row hover, and applet tooltip.
- Hiding a quota removes it from every presentation surface.
- Role does not affect selection, ordering, label, or colour treatment.
- Compact presentation handles any number of selected rows without truncation or cycling.
- Existing primary-quota rendering, loading states, error states, countdowns, and pacing remain intact.
- No rendering caller directly chooses primary, extra, or visible selectors.
- Callers and tests cross `QuotaPresentation.presentProfile()` as the presentation seam.
- The module does not mutate controller-owned state.
- No provider, discovery, credential, refresh, cache, or persisted-configuration migration is introduced.

## Backlog Decomposition Direction

After this design is reviewed, create the project’s first focused phase/milestone/epic hierarchy and ingest atomic implementation tasks for:

1. presentation interface and pure tests;
2. reusable row/card migration;
3. detail migration;
4. compact-sync cleanup and tooltip migration;
5. cross-surface regression coverage and selector cleanup.

Each task must carry its own test cycle and be independently reviewable. Dependencies should follow that sequence without introducing unrelated work from I002–I005.

--- SUMMARY ---

- Add one pure `QuotaPresentation.presentProfile()` interface returning ordered presentation rows.
- Treat every explicitly selected quota equally across cards, detail, compact, row hover, and applet tooltip.
- Keep loading/error state and time/theme calculations outside the presentation module.
- Migrate callers incrementally, test the pure interface and rendering seam, then delete shallow selector choreography.
- Decompose implementation into five focused backlog tasks after written-spec approval; do not implement during planning.
