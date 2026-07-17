# B039 Banked Resets Before Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Place the optional banked-reset badge immediately before the per-account refresh/spinner slot in every account-card header.

**Architecture:** Preserve the existing flat `RowLayout` and reorder its existing direct children. Extend the established source-structural regression test to bind the banked badge, refresh slot, and details slot semantically and prove a swapped-order mutation fails.

**Tech Stack:** Qt 6 QML, KDE Plasma Components, Kirigami, Node.js regression scripts, Qt Test, `qmllint`.

## Global Constraints

- Header order is `name/error → optional banked resets → refresh/spinner → details`.
- Preserve banked badge visibility, text, colour, hover tooltip, and spacing.
- Preserve refresh/spinner dimensions, click behaviour, accessibility, and tooltip.
- Preserve inline-error elision and fixed details-control geometry.
- Do not change provider data, reset calculations, typography, or card sizing.
- Implement directly in the existing B039 worktree; do not dispatch implementation.

---

### Task 1: Reorder Account-Card Header Controls

**Files:**
- Modify: `tests/test-account-card-layout.mjs`
- Modify: `contents/ui/AccountCard.qml`

**Interfaces:**
- Consumes: `headerRow`, the banked label text expression, `refreshSlot`, and `detailBtn` in `AccountCard.qml`.
- Produces: the semantic header invariant `banked badge < refresh slot < details slot`.

- [ ] **Step 1: Add the failing semantic-order regression**

Add these helpers and bindings to `tests/test-account-card-layout.mjs` after the existing block helpers and header bindings:

```javascript
function headerControlsInOrder(headerBlock) {
    const banked = headerBlock.indexOf('text: "↻" + profile.bankedResets')
    const refresh = headerBlock.indexOf("id: refreshSlot")
    const details = headerBlock.indexOf("id: detailBtn")
    return banked >= 0 && banked < refresh && refresh < details
}

const bankedTextStart = header.indexOf('text: "↻" + profile.bankedResets')
const bankedObjectStart = header.lastIndexOf("PlasmaComponents.Label {", bankedTextStart)
const bankedLabel = objectBlockAt(header, bankedObjectStart)
const refreshObjectStart = header.lastIndexOf("Item {", refreshStart)
const refreshSlot = objectBlockAt(header, refreshObjectStart)
```

Add these assertions before the final failure block:

```javascript
assert(headerControlsInOrder(header),
    "banked resets precede Refresh, which precedes Details")

const swapMarker = "__B039_BANKED_BADGE__"
const headerWithOldOrder = header
    .replace(bankedLabel, swapMarker)
    .replace(refreshSlot, bankedLabel)
    .replace(swapMarker, refreshSlot)
assert(!headerControlsInOrder(headerWithOldOrder),
    "header-order check detects Refresh and banked resets being swapped")
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
node tests/test-account-card-layout.mjs
```

Expected: the new semantic-order assertion fails because `refreshSlot` currently precedes the banked badge. Existing B038 assertions remain green.

- [ ] **Step 3: Apply the minimal QML reorder**

In `contents/ui/AccountCard.qml`, update the header comment to:

```qml
// Header: name · inline error · banked · refresh/spinner · detail
```

Move this unchanged label block:

```qml
PlasmaComponents.Label {
    visible: showBankedBadge && profile && profile.bankedResets > 0
    text: "↻" + profile.bankedResets
    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
    color: Kirigami.Theme.highlightColor
    HoverHandler { id: bankedHover }
    QQC2.ToolTip {
        visible: bankedHover.hovered
        text: profile.bankedResets + " banked reset(s)"
    }
}
```

from after `refreshSlot` to immediately before it. Do not alter either block internally.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
node tests/test-account-card-layout.mjs
```

Expected: all account-card layout assertions pass, including the real semantic order and negative swapped-order mutation.

- [ ] **Step 5: Run the complete mechanical verification**

Run:

```bash
for f in tests/*.sh; do bash "$f"; done
for f in tests/*.mjs; do node "$f"; done
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  /usr/lib/qt6/bin/qmltestrunner \
  -input tests/tst_card_layout.qml -import contents/ui -o -,txt
for f in contents/config/*.qml contents/ui/*.qml; do
  /usr/lib/qt6/bin/qmllint "$f"
done
git diff --check
```

Expected: all shell and Node tests pass; Qt QML totals report zero failures; all lint commands and the diff check exit 0.

- [ ] **Step 6: Render and visually inspect**

Run the worktree with `plasmoidviewer -a .`, capture the active window, and inspect both the full render and a zoomed Codex-card crop.

Expected on a Codex card with banked resets:

```text
Account name / inline error    ↻N    Refresh    Details
```

Confirm no clipping, extra row, control displacement, or lost refresh/spinner behaviour.

- [ ] **Step 7: Commit the implementation**

```bash
git add contents/ui/AccountCard.qml tests/test-account-card-layout.mjs
git commit -m "fix(B039): place banked resets before refresh"
```

- [ ] **Step 8: Review, fix, and integrate**

Launch a fresh `openai-codex/gpt-5.5` reviewer against the design and implementation. Fix every accepted meaningful finding, recommit, and rereview until PASS. Then rebase safely onto current `main`, rerun the complete verification, fast-forward merge, run `bl done B039`, inspect ignored/untracked worktree files, and clean the worktree and branch.

--- SUMMARY ---

- Add a RED/GREEN semantic-order test that rejects the current Refresh-before-banked layout.
- Move the unchanged banked badge before the unchanged refresh/spinner slot.
- Run complete tests, Qt lint, visual inspection, and independent review.
- Merge to `main`, mark B039 done, and safely clean the worktree.
