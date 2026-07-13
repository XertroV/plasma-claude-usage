# Multi-Profile Panel Redesign — Implementation Plan

> **Goal:** Panel-first multi-profile quota dashboard with live timers, profile discovery, MiniMax, configurable windows.

**Architecture:** `discover-profiles.sh` → `ProfileController` (fetch/parse) → `PanelView` / `ExpandedView` rows. Parsers in `js/QuotaParsers.js`.

## Tasks (completed in initial landing)

- [x] Task 1: `contents/scripts/discover-profiles.sh` + `tests/test-discovery.sh`
- [x] Task 2: `js/QuotaCommon.js`, `js/QuotaParsers.js` (Claude Fable, MiniMax, all providers)
- [x] Task 3: `ProfileController.qml` — staggered fetch, Claude 15min/10min floor, 429 backoff
- [x] Task 4: `components/ProviderRow.qml`, `QuotaSlot.qml`, `QuotaChip.qml`, `PanelView.qml`
- [x] Task 5: `ExpandedView.qml`, KCM keys in `main.xml` + `configGeneral.qml`
- [x] Task 6: `main.qml` shell, MiniMax fixture, install

## Follow-ups

- [ ] Live test on panel after `kquitapp6 plasmashell && kstart plasmashell`
- [ ] KCM profile table UI (currently JSON text areas)
- [ ] Per-profile visible window picker (currently global JSON list)
- [ ] Codex banked credit detail endpoint