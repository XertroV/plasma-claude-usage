# B040 Loading Counter Footer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the active source-loading counter from its disruptive row above the cards to the right of the footer’s Updated/Loading status.

**Architecture:** Keep the existing controller-derived loading state and count. Remove only the full representation’s loading-only header row, add a dedicated counter label between the footer status and Configure button, and protect placement with source-structural mutation tests.

**Tech Stack:** Qt 6 QML, KDE Plasma Components, Kirigami, Node.js regression scripts, Qt Test, `qmllint`.

## Global Constraints

- Footer semantic order is `Refresh → Updated/Loading status → active loading counter → Configure`.
- Initial loading displays `Loading… 0/N`; later refreshes display `Updated: … 0/N`.
- The counter is visible exactly when `root.isLoading` is true.
- Preserve controller loading-state/count derivation and compact-representation behaviour.
- Preserve discovery-error status, status-label elision, footer button behaviour, and card scrolling.
- Starting or ending loading must not insert or remove a row above the cards.

---

### Task 1: Relocate the Full-Representation Loading Counter

**Files:**
- Modify: `tests/test-main-layout.mjs`
- Modify: `contents/ui/main.qml`
- Modify: `contents/ui/CardsView.qml`

**Interfaces:**
- Consumes: `root.isLoading`, `root.loadingCountText`, `root.profilesDone`, and `root.profilesTotal` from `main.qml`.
- Produces: footer direct-child order `Refresh button → status label → loadingCounter label → Configure button`.

- [ ] **Step 1: Add the failing footer-placement regression**

In `tests/test-main-layout.mjs`, update `footerControlBlocks()` to extract two consecutive labels:

```javascript
function footerControlBlocks(footer) {
    const refreshStart = footer.indexOf("PlasmaComponents.Button {")
    const refreshButton = objectBlockAt(footer, refreshStart)
    const statusStart = footer.indexOf(
        "PlasmaComponents.Label {",
        refreshStart + refreshButton.length
    )
    const statusLabel = objectBlockAt(footer, statusStart)
    const counterStart = footer.indexOf(
        "PlasmaComponents.Label {",
        statusStart + statusLabel.length
    )
    const loadingCounter = objectBlockAt(footer, counterStart)
    const configureStart = footer.indexOf(
        "PlasmaComponents.Button {",
        counterStart + loadingCounter.length
    )
    const configureButton = objectBlockAt(footer, configureStart)
    return { refreshButton, statusLabel, loadingCounter, configureButton }
}
```

Update `footerHasSemanticOrder()` and add a placement helper:

```javascript
function footerHasSemanticOrder(footer) {
    if (directChildTypes(footer).join("|")
        !== "PlasmaComponents.Button|PlasmaComponents.Label|PlasmaComponents.Label|PlasmaComponents.Button") {
        return false
    }
    const controls = footerControlBlocks(footer)
    return controls.refreshButton.includes('icon.name: "view-refresh"')
        && controls.refreshButton.includes('root.i18nObj.tr("Refresh")')
        && controls.statusLabel.includes('root.i18nObj.tr("Updated:")')
        && controls.statusLabel.includes("Layout.fillWidth: true")
        && controls.loadingCounter.includes("id: loadingCounter")
        && controls.loadingCounter.includes("visible: root.isLoading")
        && controls.loadingCounter.includes("root.loadingCountText")
        && controls.configureButton.includes('icon.name: "configure"')
        && controls.configureButton.includes('root.i18nObj.tr("Configure…")')
}

function counterLivesOnlyInFooter(fullRepresentation) {
    const scroll = fullRepresentation.indexOf("PlasmaComponents.ScrollView {")
    const updated = fullRepresentation.indexOf('root.i18nObj.tr("Updated:")')
    const footerStart = fullRepresentation.lastIndexOf("RowLayout {", updated)
    const footer = objectBlockAt(fullRepresentation, footerStart)
    return scroll >= 0
        && !fullRepresentation.slice(0, scroll).includes("root.loadingCountText")
        && footer.includes("id: loadingCounter")
        && footer.includes("root.loadingCountText")
}
```

Change the semantic assertion to:

```javascript
assert(footerHasSemanticOrder(footerBlock),
    "footer direct children are Refresh, status, loading counter, then Configure")
assert(counterLivesOnlyInFooter(fullSource),
    "loading counter lives in the footer without a header row")
```

Update the spacer mutation so it still inserts before `statusLabel`, then add the old-placement mutation:

```javascript
const fullWithCounterAboveCards = fullSource
    .replace(footerControls.loadingCounter, "")
    .replace("PlasmaComponents.ScrollView {",
        footerControls.loadingCounter + "\n            PlasmaComponents.ScrollView {")
assert(!counterLivesOnlyInFooter(fullWithCounterAboveCards),
    "counter-placement check detects the counter moved above the cards")
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
node tests/test-main-layout.mjs
```

Expected: the footer semantic-order and footer-only-placement assertions fail because the current counter is a separate row before the `ScrollView`.

- [ ] **Step 3: Apply the minimal QML relocation**

Delete the loading-only `RowLayout` immediately before `fullScroll` in `contents/ui/main.qml`:

```qml
RowLayout {
    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing
    visible: root.isLoading

    Item {
        Layout.fillWidth: true
    }
    PlasmaComponents.Label {
        visible: root.isLoading
        text: root.loadingCountText || (root.profilesDone + "/" + Math.max(root.profilesTotal, 1))
        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
        color: Kirigami.Theme.disabledTextColor
    }
}
```

Add this direct footer child immediately after the existing status label and before Configure:

```qml
PlasmaComponents.Label {
    id: loadingCounter
    visible: root.isLoading
    text: root.loadingCountText || (root.profilesDone + "/" + Math.max(root.profilesTotal, 1))
    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
    color: Kirigami.Theme.disabledTextColor
}
```

In `contents/ui/CardsView.qml`, replace the stale closing comment with:

```qml
// Loading count lives in host chrome, not as a stray Flow item.
```

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
node tests/test-main-layout.mjs
```

Expected: all main-layout assertions pass, including footer order and the negative old-placement mutation.

- [ ] **Step 5: Run complete mechanical verification**

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

Expected: all shell and Node suites pass; Qt QML totals report zero failures; all lint commands and the diff check exit 0.

- [ ] **Step 6: Render and inspect loading and stable layouts**

Run the worktree with `plasmoidviewer -a .`. Capture an actively loading full representation and inspect the footer and card top edge.

Expected while loading:

```text
Refresh    Updated: … / Loading…    0/N    Configure
```

Confirm there is no loading row above the cards, no card displacement, no footer collision, and the counter sits between status and Configure. Confirm the stable state hides only the counter and leaves the cards’ top edge unchanged.

- [ ] **Step 7: Commit the implementation**

```bash
git add contents/ui/main.qml contents/ui/CardsView.qml tests/test-main-layout.mjs
git commit -m "fix(B040): move loading counter into footer"
```

- [ ] **Step 8: Review, fix, and integrate**

Launch a fresh `openai-codex/gpt-5.5-terra` reviewer against the design and implementation. Fix every accepted meaningful finding, recommit, and rereview until PASS. Safely rebase onto current `main`, rerun complete verification, fast-forward merge, run `bl done B040`, inspect ignored/untracked worktree files, and clean the worktree and branch.

--- SUMMARY ---

- Add a RED/GREEN regression proving the loading counter belongs only in the footer.
- Remove the loading-only row above the cards and insert a dedicated counter after the footer status.
- Preserve initial/loading/update text, compact behaviour, and controller state.
- Run complete tests, lint, visual inspection, independent review, automerge, backlog closure, and safe cleanup.
