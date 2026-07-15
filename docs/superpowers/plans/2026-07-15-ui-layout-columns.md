# UI Layout — Panel Cards Implementation Plan

> Spec: `docs/superpowers/specs/2026-07-15-ui-layout-columns-design.md` (rev 2 — panel cards).  
> Worktree + PIRFL as before.

**Goal:** Panel-first account cards with auto-flow layout; daily quotas on panel; floating detail window for paths/extras/settings; no popup-centric UX.

**Worktree:**

```bash
grep -qxF '.worktrees/' .gitignore || echo '.worktrees/' >> .gitignore
git worktree add .worktrees/ui-layout-columns -b feat/ui-layout-columns
cd .worktrees/ui-layout-columns
```

---

## PIRFL loops

| Loop | Deliverable |
|------|-------------|
| L1 | `QuotaCommon.js` labels + period class (from rev 1 classification) |
| L2 | Parser label pass (ids stable) |
| L3 | `AccountCard` + `QuotaRow` + Flow panel host + skeletons |
| L4 | Detail `Window` (⋯) + deprioritize fullRepresentation popup |
| L5 | Visual pass (wide/narrow panel), delete-or-sync dead paths |
| Final | Review-and-fix PASS |

---

## Task 1: Classification helpers

**File:** `contents/ui/js/QuotaCommon.js`

- Period bands, `assignWindowColumn` / class helpers (for color + label only; not global table)
- `displayWindowLabel`, unify `formatPeriodLabel` / `formatWindowDuration`
- `primaryWindows(profile)`, `extraWindows(profile)` filters

**Verify:** Grok id `session` + 7d period → weekly class; fixture matrix labels.

---

## Task 2: Parser labels

**File:** `contents/ui/js/QuotaParsers.js`

- Canonical display labels; MiniMax id `wk/*` keep, label `7d/*`

---

## Task 3: Panel cards + flow

**Files:**

- Add `contents/ui/AccountCard.qml`
- Add `contents/ui/QuotaRow.qml` (or slim `QuotaSlot` into row)
- Rewrite `contents/ui/main.qml` `compactRepresentation` to Flow of AccountCards
- Touch `PanelView.qml` / `ProviderRow.qml`: delete or reimplement as card

**Behavior:**

- `preferredRepresentation: compactRepresentation`
- Card: header (name, ↻, ⋯), primary quota rows, skeleton modes
- Flow: min card width, equal-width fill per row
- No click → Plasma popup for daily use
- Kirigami spacing only

**Verify:** plasmoidviewer / installed panel; multi-profile without popup; skeleton stable.

---

## Task 4: Detail window

**Files:**

- Add `contents/ui/DetailWindow.qml`
- Wire ⋯ from AccountCard; optional shared `selectedProfileId` on root

**Content:** paths, all quotas, refresh, configure action  
**Not:** Plasma fullRepresentation popup as primary

**fullRepresentation:** minimal stub or open detail; do not rebuild table popup.

**Verify:** Window draggable on Wayland/X11; survives unhover; shows configDir/credPath.

---

## Task 5: Polish

- Extras: default not expanded on panel; optional chips later
- Screenshots under `screenshots/`
- Grep dead ExpandedView usage; keep only if stub needs it

---

## Out of scope

- KCM profile deep-link perfection
- Persisting detail window geometry (nice-to-have)
- Fetch/auth changes
