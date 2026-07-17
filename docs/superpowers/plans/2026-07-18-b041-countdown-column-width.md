# B041 Countdown Column Width Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make each quota-row countdown consume its natural bounded width so reclaimed space expands the pace bar.

**Architecture:** Keep the existing `QuotaRow` child order and layout responsibilities intact. Change only the countdown label’s preferred-width hint from a fixed four-grid-unit slot to `implicitWidth`, while strengthening the Node structural regression so it identifies the semantic period, percentage, pace-bar, and countdown blocks rather than relying on global width-expression searches.

**Tech Stack:** QML / Qt Quick Layouts, KDE Plasma Components and Kirigami, Node.js ES modules, Qt 6 QML tests, `qmllint`.

## Global Constraints

- Preserve the quota-row structure: fixed period → fill-width pace bar → fixed percentage → natural countdown.
- Preserve the countdown’s `Layout.maximumWidth: Kirigami.Units.gridUnit * 5`, `elide: Text.ElideRight`, and `horizontalAlignment: Text.AlignRight` constraints.
- Preserve both two-grid-unit preferred widths for the period and percentage labels.
- Preserve `PaceBar` as the only `Layout.fillWidth: true` quota-row child.
- Do not change card flow, card widths, countdown formatting, pace-bar bounds, row spacing, typography, tooltip, accessibility, controller code, or provider data.
- Follow RED → GREEN TDD and retain evidence that the new regression fails against the pre-change QML.
- Limit builds and tests to two threads where a tool supports parallelism.

---

## File Structure

- Modify `tests/test-card-typography.mjs`: add small brace-aware QML block helpers and semantic assertions for the period label, pace bar, percentage label, and countdown label.
- Modify `tests/tst_card_layout.qml`: replace the obsolete equal-countdown-left-edge invariant with differing natural left edges and equal right edges.
- Modify `contents/ui/QuotaRow.qml`: use the countdown label’s `implicitWidth` as its preferred width; retain all existing constraints and behaviour.

### Task 1: Use Natural Countdown Width

**Files:**
- Modify: `tests/test-card-typography.mjs`
- Modify: `tests/tst_card_layout.qml`
- Modify: `contents/ui/QuotaRow.qml`

**Interfaces:**
- Consumes: the existing ordered `QuotaRow` children (`PlasmaComponents.Label`, `PaceBar`, `PlasmaComponents.Label`, `PlasmaComponents.Label`) and Qt Quick Layout attached properties.
- Produces: a countdown label with `Layout.preferredWidth: implicitWidth`, bounded by the existing five-grid-unit maximum, and a semantic regression test that protects all neighbouring layout invariants.

- [ ] **Step 1: Add brace-aware QML object extraction to the Node regression**

Insert these helpers after the existing `count()` function in `tests/test-card-typography.mjs`:

```js
function objectBlocks(source, typeName) {
    const blocks = []
    const marker = `${typeName} {`
    let searchFrom = 0

    while (true) {
        const start = source.indexOf(marker, searchFrom)
        if (start === -1) return blocks

        const braceStart = source.indexOf("{", start)
        let depth = 0
        let end = braceStart
        for (; end < source.length; end++) {
            if (source[end] === "{") depth++
            if (source[end] === "}") {
                depth--
                if (depth === 0) break
            }
        }
        blocks.push(source.slice(start, end + 1))
        searchFrom = end + 1
    }
}

function findObjectBlock(source, typeName, semanticNeedle) {
    return objectBlocks(source, typeName)
        .find(block => block.includes(semanticNeedle)) || ""
}
```

Replace the current global quota-column assertion:

```js
assert(quotaRow.includes("Layout.preferredWidth: Kirigami.Units.gridUnit * 2")
       && quotaRow.includes("Layout.preferredWidth: Kirigami.Units.gridUnit * 4")
       && count(quotaRow, "elide: Text.ElideRight") === 2,
    "quota columns remain fixed and elided for compact cards")
```

with semantic block bindings and assertions:

```js
const periodLabel = findObjectBlock(quotaRow, "PlasmaComponents.Label",
    "text: rowRoot.periodLabel")
const paceBar = findObjectBlock(quotaRow, "PaceBar",
    "usagePercent: isSkeleton ? 0 : rowRoot.usagePct")
const percentageLabel = findObjectBlock(quotaRow, "PlasmaComponents.Label",
    "Math.round(rowRoot.usagePct) + \"%\"")
const countdownLabel = findObjectBlock(quotaRow, "PlasmaComponents.Label",
    "QC.formatCountdown(windowData.resetAtMs, nowMs)")

assert(periodLabel.includes("Layout.preferredWidth: Kirigami.Units.gridUnit * 2")
       && periodLabel.includes("elide: Text.ElideRight"),
    "period column remains fixed and elided")
assert(paceBar.includes("Layout.fillWidth: true"),
    "pace bar receives remaining quota-row width")
assert(percentageLabel.includes("Layout.preferredWidth: Kirigami.Units.gridUnit * 2")
       && percentageLabel.includes("horizontalAlignment: Text.AlignRight"),
    "percentage column remains fixed and right-aligned")
assert(countdownLabel.includes("Layout.preferredWidth: implicitWidth")
       && countdownLabel.includes("Layout.maximumWidth: Kirigami.Units.gridUnit * 5")
       && countdownLabel.includes("elide: Text.ElideRight")
       && countdownLabel.includes("horizontalAlignment: Text.AlignRight"),
    "countdown uses its natural bounded width and remains right-aligned")
assert(count(quotaRow, "Layout.fillWidth: true") === 2,
    "only the quota row and pace bar opt into fill width")
```

This structure ensures the countdown assertions cannot be accidentally satisfied by the period or percentage labels.

- [ ] **Step 2: Run the focused regression to prove RED**

Run:

```bash
node tests/test-card-typography.mjs
```

Expected: exactly one failure, `countdown uses its natural bounded width and remains right-aligned`, because `QuotaRow.qml` still contains `Layout.preferredWidth: Kirigami.Units.gridUnit * 4`. All new neighbouring-column assertions should pass.

- [ ] **Step 3: Update the runtime geometry invariant**

In `test_rightSideQuotaInformationRemainsAligned()` in `tests/tst_card_layout.qml`, replace the countdown left-edge comparison:

```qml
compare(firstTime[0].mapToItem(view, 0, 0).x,
        secondTime[0].mapToItem(view, 0, 0).x)
```

with natural-width and right-edge checks:

```qml
compare(firstPct[0].width, secondPct[0].width)
var firstTimeX = firstTime[0].mapToItem(view, 0, 0).x
var secondTimeX = secondTime[0].mapToItem(view, 0, 0).x
compare(firstTime[0].width, firstTime[0].implicitWidth)
compare(secondTime[0].width, secondTime[0].implicitWidth)
verify(firstTime[0].width !== secondTime[0].width,
       "different countdown lengths should consume different natural widths")
verify(Math.abs((firstTimeX + firstTime[0].width)
                - (secondTimeX + secondTime[0].width)) < 1,
       "countdown right edges should align within one pixel")
```

This matches the approved layout semantics: the percentage slots retain equal fixed widths; countdown labels take their exact natural widths; and countdown right edges remain aligned within one physical pixel, allowing harmless subpixel text-metric differences.

- [ ] **Step 4: Make the minimal production change**

In the final countdown `PlasmaComponents.Label` in `contents/ui/QuotaRow.qml`, replace:

```qml
Layout.preferredWidth: Kirigami.Units.gridUnit * 4
```

with:

```qml
Layout.preferredWidth: implicitWidth
```

Do not alter any other property in the block.

- [ ] **Step 5: Run focused GREEN verification**

Run:

```bash
node tests/test-card-typography.mjs
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    /usr/lib/qt6/bin/qmltestrunner \
    -input tests/tst_card_layout.qml -import contents/ui -o -,txt
```

Expected: the Node regression exits 0 with `All card typography tests passed.` and the Qt runtime suite reports all tests passed, including the natural-width/right-edge geometry invariant.

- [ ] **Step 6: Run the complete mechanical verification suite**

Run the repository’s three shell suites, all Node suites, Qt QML runtime geometry tests, QML lint, and whitespace validation:

```bash
set -e
for test_file in tests/test-*.sh; do
    bash "$test_file"
done
for test_file in tests/test-*.mjs; do
    node "$test_file"
done
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    /usr/lib/qt6/bin/qmltestrunner \
    -input tests/tst_card_layout.qml -import contents/ui -o -,txt
find contents/ui -path '*/node_modules' -prune -o -name '*.qml' -print0 \
    | xargs -0 -n1 qmllint
git diff --check
```

Expected: every shell and Node suite exits 0; all Qt QML tests pass; every QML file passes `qmllint`; `git diff --check` emits no output.

- [ ] **Step 7: Visually validate constrained quota rows**

Render the existing deterministic card-layout visual fixture (or the project’s established `plasmoidviewer` fixture) at minimum card width with multiple data rows and skeleton rows. Inspect the resulting image and confirm:

- ordinary countdowns have no four-grid-unit leading blank region;
- pace bars are visibly wider than the pre-change layout;
- period and percentage columns stay aligned;
- long countdowns remain bounded and right-elided;
- neither data nor skeleton content clips or overflows.

Record the capture path and inspection result in the task/review evidence. Any visible clipping, overlap, or horizontal overflow is a failure requiring correction before review.

- [ ] **Step 8: Commit the tested implementation**

Run:

```bash
git add tests/test-card-typography.mjs tests/tst_card_layout.qml contents/ui/QuotaRow.qml
git commit -m "fix(B041): tighten countdown column width"
```

Expected: one implementation commit containing only the semantic structural regression, the corrected runtime geometry invariant, and the one-line QML layout change.

- [ ] **Step 9: Run an independent review/fix gate**

Ask a fresh reviewer to inspect the committed B041 range against the approved design and verify:

- the structural test binds the actual countdown block;
- RED evidence is specific to the old fixed width;
- the five-grid-unit cap, right elision, and right alignment remain intact;
- fixed period/percentage columns and fill-width pace bar remain intact;
- no unrelated behaviour or files changed;
- all mechanical and visual evidence is credible.

Fix every accepted blocker or major finding, rerun affected checks, commit fixes, and repeat independent review until no accepted blocker or major issue remains.

- [ ] **Step 10: Rebase, verify integration, automerge, and close B041**

From the main checkout, rebase the worktree branch onto the current `main`, rerun the complete mechanical suite from Step 5, then fast-forward merge, mark B041 done, and clean up the branch/worktree only after checking for valuable untracked or ignored files:

```bash
git -C .worktrees/B041-countdown-column-width rebase main
# Rerun Step 5 inside the worktree.
git merge --ff-only fix/B041-countdown-column-width
bl done B041
git -C .worktrees/B041-countdown-column-width status --porcelain --ignored
git worktree remove .worktrees/B041-countdown-column-width
git branch -d fix/B041-countdown-column-width
```

Expected: rebase and fast-forward merge succeed; B041 is done; final `main` verification passes; no valuable scratch artifacts are discarded; the temporary worktree and branch are removed.

--- SUMMARY ---

- Add semantic, brace-aware regression coverage for the four quota-row layout children.
- Update runtime geometry coverage to require natural-width left edges and aligned right edges.
- Prove RED specifically against the fixed four-grid-unit countdown slot.
- Change only the countdown preferred width to `implicitWidth`, preserving its cap, elision, and alignment.
- Run focused, full mechanical, runtime, lint, and visual checks.
- Pass an independent review/fix loop, rebase onto current `main`, verify integration, automerge, close B041, and safely clean up the worktree.
