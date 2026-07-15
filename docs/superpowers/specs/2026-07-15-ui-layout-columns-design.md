# UI Layout — Panel Cards Redesign

**Date:** 2026-07-15 (rev 2 — panel cards + detail window)  
**Status:** Draft design (supersedes rev 1 shared-column table as primary UX)  
**Scope:** Presentation only — panel-first account cards, auto-flow layout, skeleton loading, period labels, optional floating detail window. No fetch/auth redesign.

**Parity reference:** `~/src/quotas` period tokens (`5h`, `7d`, `mo`).

**Related:**  
- `docs/superpowers/specs/2026-07-14-multi-profile-panel-redesign-design.md` (data model / discovery)  
- Rev 1 of this file kept classification helpers (`assignWindowColumn`, bands, display labels) as the **token & classification** subsystem; **layout** is cards, not a global table.

---

## Product intent

| Priority | Surface | What lives there |
|----------|---------|------------------|
| **P0 — daily** | **Panel only** | Everything you regularly check: which accounts, primary quotas (bar / % / countdown), banked resets, errors/loading |
| **P1 — rare** | **Floating detail window** (draggable, not a Plasma popup) | Paths, auth file, full extras list, plan, open settings for that profile |
| **Avoid** | Plasma **popup / fullRepresentation** as day-to-day UI | Click-to-popup is not the main path |

**Regular concern on panel** = for each account:

- Identity (display name)
- Each **primary** quota window: period label (`5h` / `7d` / `mo` / product short form), pace bar, usage %, countdown to reset
- Provider badges that matter daily (e.g. Codex `↻N` banked)
- Loading / error state

**Not required on panel every minute** (detail window):

- Config dir path, credentials path
- Full extra/model limits (Fable, spk, video, …) — optional: show **collapsed chip summary** on panel if space; full list in detail
- “Open settings for this profile” affordance
- Verbose plan / billing copy

---

## Goals

1. **Panel is the product** — no need to open a popup for normal monitoring.
2. **Account cards** — one card per profile/account (named; maps to a config path / settings section).
3. **Auto-layout cards** — flow/grid fills available panel geometry efficiently (wide panel → multi-column cards; narrow/vertical → stack).
4. **Stable geometry while loading** — skeleton cards/quota rows so size does not thrash when data arrives.
5. **Canonical period tokens** — `5h`, `7d`, `mo` (synonyms normalized); labels display-only; **ids stable** for config.
6. **Kirigami spacing** only.
7. **Optional detail window** — small control opens a **Qt `Window`** (movable, independent of panel popup).

## Non-goals

- Relying on Plasma `fullRepresentation` popup for primary UX (may remain as thin fallback or disabled).
- Full KCM rewrite (settings button may open existing KCM / scroll to profile later).
- New providers / fetch changes.
- Translating `5h`/`7d`/`mo`.
- Fake 0% for missing periods.

---

## Information architecture

```
Main panel (compactRepresentation)
└── Flow / grid of AccountCards
    └── AccountCard  (profile id, displayName, path identity)
        ├── Header: name · [plan tooltip] · [↻ banked] · [⋯ detail]
        ├── Quota rows (primary only, regularly checked)
        │     label | bar | % | countdown
        ├── Optional: compact extra chips (if user enabled extras & space)
        └── Expandable “extras” on panel?  → DEFAULT OFF
              Prefer detail window for extras to keep panel height stable.
              Optional later: per-card ▸ extras if config allows.

Detail window (Qt Window, per account or switcher)
└── Full identity: displayName, provider, plan
    Paths: configDir, credPath (copy / open folder)
    All quota rows (primary + extra)
    Provider features (banked detail, etc.)
    [Configure…] → plasmoid settings (best-effort focus profile)
```

**Expandable extras on the panel:** allowed as a **secondary** option, but default recommendation is **not** expanding extras on the panel so regular height stays predictable. Daily extras that matter can be promoted to “primary” via existing visibility config, or shown as single-line chips.

---

## Layout (ASCII)

### Panel — wide (horizontal panel, multi-column flow)

Cards auto-place left→right, wrap to next band when width exhausted. Card min/max width from `gridUnit`.

```
┌──────────────────────────────── panel strip ─────────────────────────────────┐
│ ┌ Claude-w ─────────────┐ ┌ Claude-p ─────────────┐ ┌ Codex ────── ↻2 ── ⋯ ┐│
│ │ 5h  ▓▓░░ 15%  2h 14m  │ │ 5h  ▓▓░░ 39%  1h 02m  │ │ 5h  ▓▓░░ 17%  3h 40m ││
│ │ 7d  ▓▓▓▓ 89%  6d 21h  │ │ 7d  ▓▓░░ 48%  5d 10h  │ │ 7d  ▓▓░░ 10%  6d 02m ││
│ └───────────────────────┘ └───────────────────────┘ └──────────────────────┘│
│ ┌ Grok ────────────── ⋯ ┐ ┌ Z.ai ─────────────── ⋯ ┐                        │
│ │ 7d  ▓▓░░ 42%  3d 12h  │ │ 5h  ▓▓░░  8%  4h 01m  │                        │
│ │ mo  ▓▓░░  8%  12d …   │ │ mo  ▓▓░░ 31%  …       │                        │
│ └───────────────────────┘ └───────────────────────┘                        │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Panel — narrow / vertical panel (single column stack)

```
┌ panel ──────────────┐
│ ┌ Claude-w ────── ⋯┐│
│ │ 5h ▓▓ 15% 2h14m  ││
│ │ 7d ▓▓ 89% 6d21h  ││
│ └──────────────────┘│
│ ┌ Codex ── ↻2 ── ⋯ ┐│
│ │ 5h ▓▓ 17% …      ││
│ │ 7d ▓▓ 10% …      ││
│ └──────────────────┘│
└─────────────────────┘
```

### Panel — skeleton (discovery known, fetch pending)

```
│ ┌ Claude-w ────── ⋯┐│
│ │ 5h ░░ ··  —      ││
│ │ 7d ░░ ··  —      ││
│ └──────────────────┘│
│ ┌ Codex ──────── ⋯ ┐│
│ │ 5h ░░ ··  —      ││
│ │ 7d ░░ ··  —      ││
│ └──────────────────┘│
```

Card count known from discovery → reserve N cards. Each card reserves a **fixed primary row count** once known (or 2 ghost rows until first successful parse for that profile). Prefer last-known primary count per profile in-session to avoid height thrash.

### Account card structure

```
┌─ {displayName} ─────────── [↻N] [⋯] ─┐
│  {period}  [bar]  {pct}%  {countdown} │  × primary windows (only real ones)
│  …                                    │
│  (optional chips: Fable 87% · spk 49%)│  if extras visible & compact mode
└───────────────────────────────────────┘
```

- **No empty placeholder rows** for missing periods (Grok without 5h simply has no 5h row) — cards may differ in height; flow layout handles that.
- Skeleton exception: until first data, show 2 ghost rows so card min-height is stable during load.
- **⋯** opens / focuses the detail window for that account (not a Plasma popup).
- Clicking the card body does **not** open the old popup (or only if we keep a config “click opens detail”).

### Detail window (floating)

```
┌ Claude-w — details ────────────────────────────── ☐ ☒ ┐
│ Provider: Claude     Plan: Max 5x                      │
│ Config:  ~/.claude-w                                   │
│ Auth:    ~/.claude-w/.credentials.json   [Copy] [Open] │
│                                                        │
│ Primary                                                │
│   5h   ▓▓▓░░  15%   resets 2h 14m                      │
│   7d   ▓▓▓▓▓  89%   resets 6d 21h                      │
│                                                        │
│ Extra limits                                           │
│   Fable  ▓▓▓  87%                                      │
│   Opus   ▓░░  12%                                      │
│                                                        │
│              [Configure profile…]  [Refresh]           │
└────────────────────────────────────────────────────────┘
```

- `QtQuick.Window` / Plasma-friendly dialog: **movable**, independent lifetime from panel hover.
- One window with account switcher **or** one window per account (prefer **one window**, switch `profileId` — less clutter).
- Settings: `Plasmoid.internalAction("configure")` or documented best-effort; profile deep-link may be phase-2 if KCM lacks anchors.

---

## Auto-layout rules

Use a **Flow** or equivalent wrapping grid:

| Input | Behavior |
|-------|----------|
| Panel width | Columns = `max(1, floor(availableWidth / cardMinWidth))` |
| Card min width | ~ `gridUnit * 10–12` (tune with visual pass) |
| Card max width | grow equally to fill row remainder (efficient fill) |
| Panel height | Sum of flow rows; Plasma sizes applet from implicit size |
| Vertical panel | Prefer single column (width constrained) |
| Max cards | Soft cap already ~6 rows in old multi-panel; if overflow, “+N more” card opening detail list — or scroll if Plasma allows |

**Efficient fill:** last row of cards stretches to share remaining width; all cards in a row equal height (row height = max card in that row) for a clean band.

---

## Classification & labels (carried from rev 1)

Still required for consistent row labels:

- Bands: 5h `[1h,12h]`, 7d `(12h,10d]`, mo `(10d,45d]`
- `periodMs` first; id `session` ≠ 5h when period is weekly (Grok)
- Display: `5h`, `7d`, `mo`; MiniMax `wk/*` **id** stable, label `7d/*`
- `$` / long product text → tooltip on the quota row
- Color: session mode for 5h-class, weekly mode for 7d/mo-class (by class, not list index)

**No global `showMoColumn` header** — monthly is just another quota **row inside the card** when present.

---

## Plasma representation policy

| Representation | Role |
|----------------|------|
| `preferredRepresentation` | **`compactRepresentation` always** (panel) |
| `compactRepresentation` | Card flow UI (primary product) |
| `fullRepresentation` | **Deprioritized**: either omit meaningful content, or a one-line “Use panel cards; open ⋯ for details”, or redirect to detail window. Do not invest in popup table. |
| Detail | Separate `Window`, not `fullRepresentation` |

Click on panel background: no expand-to-popup. Optional middle-click / ⋯ only for detail.

---

## Skeleton & loading

| State | Panel |
|-------|--------|
| Discovering | 1–N ghost cards (from last count or 2) |
| Profile known, loading | Named card, 2 ghost quota rows |
| Partial | Some cards filled, others ghost rows |
| Error | Card header + one-line error (red), ⋯ still opens detail |
| Idle | Full primary rows |

Footer “Updated / Refresh” is **not** required on the panel (saves space); put Refresh in detail window and keep existing timer refresh. Optional tiny global status via tooltip on icon.

---

## Component sketch

| Component | Responsibility |
|-----------|----------------|
| `PanelView` / `main.qml` compact | Flow host; size hints for Plasma |
| `AccountCard.qml` | One profile: header, primary rows, optional chips, ⋯ |
| `QuotaRow.qml` | Single quota line (label, bar, %, countdown); skeleton/empty modes |
| `DetailWindow.qml` | Floating window; binds selected profile |
| `QuotaCommon.js` | Labels, class bands, `displayWindowLabel` (from rev 1) |
| `ExpandedView.qml` | Shrink or repurpose; not primary |

---

## Settings correspondence

- Account card **name** = profile `displayName` (config override JSON / discovery default).
- Card identity = `profile.id` / `configDir` — same as multi-profile redesign.
- Future KCM: list of profiles mirrors cards; out of scope to rebuild KCM now, but detail “Configure…” is the bridge.

---

## Visual acceptance

1. Wide horizontal panel: ≥2 cards per band when width allows  
2. Narrow: single column, all primary quotas readable without popup  
3. Skeleton → data without large width thrash; height may settle once per profile  
4. Grok: card with 7d + mo rows only (no empty 5h row)  
5. Codex: ↻ on header; primaries on panel  
6. ⋯ opens draggable detail with paths; window survives panel unhover  
7. No reliance on Plasma popup for daily use  

---

## Risks

| Risk | Mitigation |
|------|------------|
| Tall panel with many accounts | Cap visible cards; “+N”; encourage disabling unused profiles |
| Flow reflow when countdowns change digit width | Fixed width for % and countdown columns inside card |
| Detail `Window` vs Wayland focus | Test on Wayland; use `Qt.Window` flags appropriately |
| Users still click widget expecting popup | Tooltip: “Quotas on panel · ⋯ for details”; disable expand or make expand open detail |
| Extras “regularly concerned” for some users | Visibility config promotes windows to primary; chips optional |

---

## Success criteria

- [ ] Daily monitoring possible without opening any popup  
- [ ] Cards auto-flow and fill panel width efficiently  
- [ ] Each account shows primary quotas with `5h`/`7d`/`mo` (as applicable) on panel  
- [ ] Provider badges (banked) on card when relevant  
- [ ] Skeleton load without jarring empty→full collapse for known profile set  
- [ ] Detail window: paths + all quotas + configure affordance  
- [ ] Window ids stable; classification rules from rev 1 held  

---

## Rev 1 → rev 2 delta

| Rev 1 | Rev 2 |
|-------|-------|
| Global table headers 5h/7d/mo | Per-card quota **rows** |
| Expanded popup primary | **Panel** primary |
| `showMoColumn` freeze | N/A (row appears on card only) |
| Pace table alignment across profiles | Alignment **within** card; flow across cards |
| fullRepresentation investment | Deprioritized |
| — | Floating **detail window** + ⋯ |
| — | Auto-flow card layout |
