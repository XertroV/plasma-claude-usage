# B041 Countdown Column Width Design

**Backlog source:** B041 — Countdown column reserves four grid units, wasting quota-row space

**Date:** 17 July 2026

## Problem

Each `QuotaRow` ends with a reset-countdown label whose preferred width is fixed at four grid units. With the current theme this reserves roughly 72 px, while normal `QC.formatCountdown()` output such as `5d 18h`, `2d 6h`, or `59m 3s` is substantially narrower.

The label right-aligns its text, so the unused part of the fixed slot appears as a large blank block between the percentage and countdown. Because the pace bar is the row’s fill-width child, every unused countdown pixel is taken directly from the useful bar.

## Desired Behaviour

- The reset-countdown label consumes its natural text width for ordinary values.
- Only normal `RowLayout.spacing` separates percentage and countdown content.
- Reclaimed width expands the pace bar, especially on minimum-width cards.
- Countdown values remain right-aligned.
- Unusually long countdown values remain capped at five grid units and elide on the right.
- Period and percentage columns retain their fixed widths so rows remain aligned.
- Skeleton rows and multi-row cards remain bounded without clipping or overflow.

## Architecture

In the final reset-countdown `PlasmaComponents.Label` in `contents/ui/QuotaRow.qml`, replace:

```qml
Layout.preferredWidth: Kirigami.Units.gridUnit * 4
```

with:

```qml
Layout.preferredWidth: implicitWidth
```

Keep these existing constraints unchanged:

```qml
Layout.maximumWidth: Kirigami.Units.gridUnit * 5
elide: Text.ElideRight
horizontalAlignment: Text.AlignRight
```

No manual text metrics or new properties are needed. `RowLayout` already allocates the remaining width to `PaceBar` through `Layout.fillWidth: true`, so natural countdown sizing automatically transfers reclaimed pixels to the bar.

## Layout Semantics

The quota row remains:

```text
fixed period → fill-width pace bar → fixed percentage → natural countdown
```

The row’s outer geometry, spacing, typography, colour, tooltip, and data formatting are unchanged. Countdown labels may have different left edges when text widths differ, but their right edges remain aligned by the enclosing row and `Text.AlignRight`.

## Testing

Update `tests/test-card-typography.mjs` to bind the final countdown label as a structural object block rather than searching globally for all width expressions. Assert that this block contains:

- `Layout.preferredWidth: implicitWidth`;
- `Layout.maximumWidth: Kirigami.Units.gridUnit * 5`;
- `elide: Text.ElideRight`;
- `horizontalAlignment: Text.AlignRight`.

Also assert that the period and percentage labels retain their two-grid-unit preferred widths and the pace bar remains fill-width. The test must fail against the current four-grid-unit countdown declaration before production QML changes.

Run all shell and Node suites, Qt QML runtime geometry tests, `qmllint`, and `git diff --check`. Render minimum-width cards containing multiple data rows and skeleton rows, then confirm the pace bars are visibly wider, normal countdowns no longer have a large leading blank region, and no content clips or overflows.

## Scope

This task does not change:

- `CardsView` flow or card widths;
- period or percentage column sizing;
- countdown formatting;
- pace-bar minimum/preferred dimensions;
- row spacing, typography, tooltip, or accessibility;
- controller/provider data.

--- SUMMARY ---

- Replace the countdown’s four-grid-unit preferred width with its natural `implicitWidth`.
- Retain the five-grid-unit cap, elision, right alignment, and fixed period/percentage columns.
- Let the existing fill-width pace bar receive all reclaimed space.
- Protect the exact countdown block and neighbouring column invariants with RED/GREEN regression coverage and visual validation.
