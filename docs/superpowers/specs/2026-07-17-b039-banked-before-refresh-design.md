# B039: Banked Resets Before Refresh

## Goal

On account cards that show banked resets (currently most visible on Codex cards), place the banked-reset badge immediately before the per-account refresh control.

The header control order must be:

1. Account name and optional inline error
2. Optional banked-reset badge
3. Refresh control, or its in-place loading spinner
4. Details control

## Current Cause

`contents/ui/AccountCard.qml` declares `refreshSlot` before the conditional banked-reset label. `RowLayout` renders direct children in declaration order, so banked resets appear to the right of Refresh.

## Design

Move the existing banked-reset `PlasmaComponents.Label` block immediately before `refreshSlot`. Do not change the controls themselves or introduce a nested layout.

This preserves:

- The badge’s existing visibility condition, text, colour, hover target, and tooltip.
- The refresh slot’s fixed dimensions, spinner substitution, click behaviour, accessibility metadata, and tooltip.
- The details control as the final header control.
- The shrinkable name/error text slot and its elision behaviour.
- Existing spacing supplied by `headerRow`.

Cards without banked resets continue to show the refresh control directly after the name/error text slot.

## Alternatives Rejected

- **Nested control layout:** unnecessary structure and potential spacing/width changes for a declaration-order fix.
- **Extracted controls component:** excessive abstraction for one local ordering invariant.

## Regression Coverage

Extend `tests/test-account-card-layout.mjs` to inspect the bounded `headerRow` block and bind each relevant direct-child block semantically. It must assert:

- The banked-reset label precedes `refreshSlot`.
- `refreshSlot` precedes `detailBtn`.
- A mutation that swaps banked resets and Refresh fails the semantic-order check.
- Existing B038 inline-error and fixed-control assertions continue to pass.

The test must fail against the current order before production QML is changed.

## Validation

- Run the focused regression test RED, then GREEN.
- Run all shell, Node, and Qt QML tests.
- Run Qt 6 `qmllint` on project QML.
- Run `git diff --check`.
- Render the plasmoid and inspect a Codex card with a banked-reset badge, confirming the visual order and no clipping or control displacement.
- Run an independent gpt55 review/fix loop to PASS before merging.

## Scope

No provider-specific data, refresh behaviour, banked-reset calculation, typography, card sizing, or other header functionality changes.

--- SUMMARY ---

- Reorder existing header siblings to `name/error → banked resets → refresh/spinner → details`.
- Preserve all control behaviour and geometry.
- Add a semantic regression test with a negative swapped-order mutation.
- Validate mechanically, visually, and through independent review before merging.
