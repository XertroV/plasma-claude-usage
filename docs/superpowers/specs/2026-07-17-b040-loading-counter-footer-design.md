# B040 Loading Counter Footer Design

**Backlog source:** B040 — Loading source counter disrupts the header flow; show it on the RHS of the Updated label instead

**Date:** 17 July 2026

## Problem

The full representation declares a loading-only `RowLayout` above its card `ScrollView`. When loading starts, that row becomes visible and pushes the cards down; when loading ends, it disappears and the cards move back up. The loading counter is status information and does not warrant a separate header row.

The footer already owns refresh status through its `Updated: …` / `Loading…` label. The loading counter belongs beside that status.

## Desired Behaviour

The full-representation footer has this semantic order:

```text
Refresh → Updated/Loading status → active loading counter → Configure
```

- During initial loading, before a timestamp exists, it displays `Loading… 0/N`.
- During a later refresh, it displays `Updated: … 0/N`.
- The counter is visible only while `root.isLoading` is true, matching the existing top-row behaviour.
- The status label keeps `Layout.fillWidth` and right elision. On narrow widths it yields space first, keeping the short counter and buttons usable.
- Starting or finishing loading does not insert or remove a row above the cards, so card position and available vertical space remain stable.

## Architecture

### Full representation

Remove the loading-only `RowLayout` immediately before `fullScroll` in `contents/ui/main.qml`.

Add a dedicated `PlasmaComponents.Label` immediately after the existing footer status label and before the Configure button. It uses:

- `visible: root.isLoading`;
- the existing count expression, `root.loadingCountText || (root.profilesDone + "/" + Math.max(root.profilesTotal, 1))`;
- `Kirigami.Theme.smallFont.pixelSize`;
- `Kirigami.Theme.disabledTextColor`.

The existing status label continues to choose discovery error, last update, initial loading text, or an empty string. No controller or loading-state calculation changes are required.

### Compact representation

The compact representation continues passing `root.loadingCountText` to `CardsView`. This task changes only full-representation chrome.

### CardsView documentation

Update the closing comment in `CardsView.qml` to say the loading count lives in host chrome rather than specifically in a header, reflecting both compact and full hosts without changing behaviour.

## Data Flow

`ProfileController.loadingStats()` continues populating `profilesTotal`, `profilesDone`, and `profilesLoading`. `syncCompactFromController()` continues deriving `root.isLoading` and `root.loadingCountText`. The footer counter reads those existing root properties directly.

No additional state, signals, controller methods, or translations are introduced.

## Error and Edge Cases

- A discovery error remains the main status text. If loading remains active, the counter may still appear to its right, preserving current independent state reporting.
- If `loadingCountText` is empty while `isLoading` is true, the existing `profilesDone/profilesTotal` fallback guarantees visible progress text.
- At narrow widths the status label elides; the short counter remains separate and visible.
- When loading ends, only the counter label leaves the footer layout; the cards and `ScrollView` do not move.

## Testing

Extend `tests/test-main-layout.mjs` to verify:

1. No loading counter expression exists in the full-representation source before the `ScrollView`.
2. Footer direct children are semantically `Refresh button → status label → loading counter label → Configure button`.
3. The loading counter is bound to `root.isLoading`, uses the existing loading text/fallback expression, and retains small disabled styling.
4. A mutation that moves the real counter block before the `ScrollView` fails the placement check.
5. Existing spacer, button-order, card containment, and scrollbar regressions remain covered.

Run all shell and Node suites, Qt QML tests, `qmllint`, and `git diff --check`. Render an actively loading full representation and verify the cards do not gain a top row and the counter appears between status and Configure.

## Non-goals

- Changing loading-state or progress-count semantics.
- Changing the compact representation’s loading indicator.
- Redesigning footer buttons, card content, or refresh behaviour.
- Adding animations or alternate progress controls.

--- SUMMARY ---

- Remove the loading-only row above the cards, eliminating vertical layout shifts.
- Place a dedicated loading counter after the footer status label and before Configure.
- Preserve initial `Loading… 0/N`, later `Updated: … 0/N`, compact behaviour, and existing state derivation.
- Protect placement and semantic order with mutation-based regression coverage plus visual verification.
