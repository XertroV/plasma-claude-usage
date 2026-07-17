# Quota Presentation Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace shallow quota selectors with one pure presentation interface so every explicitly selected quota is shown equally across cards, detail, compact cards, row hover, and applet tooltip.

**Architecture:** Add `QuotaPresentation.presentProfile(profile, options)`, which returns ordered presentation rows containing the raw window, resolved label, and resolved colour mode. Migrate rendering callers to that interface, retain time/theme calculations in `QuotaRow`, remove role-based detail grouping and obsolete compact-sync state, then delete the old selector choreography.

**Tech Stack:** Qt 6 QML/Qt Quick, Plasma/Kirigami, QML JavaScript libraries, Node.js ESM regression tests, Qt Quick Test.

## Global Constraints

- Follow `docs/superpowers/specs/2026-07-17-quota-presentation-policy-design.md` exactly.
- `visible === false` is the only hidden state; missing visibility remains visible.
- Primary, extra, missing, and unknown roles receive identical presentation treatment.
- Preserve `profile.windows` ordering and duplicate rows.
- Do not mutate controller-owned profiles or windows.
- Do not change persisted visibility JSON, provider parsing, discovery, credentials, refresh, or cache behaviour.
- Keep loading, error, countdown, pacing, and Plasma theme behaviour intact.
- Add no runtime or development dependency.
- Keep QML JavaScript compatible with the repository’s existing `.pragma library` style.
- Run tests serially or with at most two threads.
- The existing Qt Quick test currently exits `1` without diagnostics on the planning host even under offscreen/Xvfb. Do not claim it passed unless a functioning Qt test environment produces an explicit passing result; retain Node wiring tests as required local gates, not as a false substitute for the Qt test.

---

## File Structure

### Create

- `contents/ui/js/QuotaPresentation.js` — the sole quota-presentation policy interface.
- `tests/test-quota-presentation.mjs` — pure interface tests.
- `tests/tst_quota_presentation.qml` — functional account-card and detail rendering tests.
- `tests/test-main-quota-presentation.mjs` — source-contract test for Plasmoid-only compact-sync and tooltip integration.
- `tests/test-quota-presentation-wiring.mjs` — final seam/deletion regression across all rendering callers.

### Modify

- `contents/ui/QuotaRow.qml` — consume a presentation row instead of deriving presentation policy.
- `contents/ui/AccountCard.qml` — repeat `presentProfile().rows`.
- `contents/ui/DetailWindow.qml` — render one role-independent quota list.
- `contents/ui/main.qml` — remove obsolete fixed-window compact-sync state and route tooltip/sync through the presentation interface.
- `contents/ui/js/QuotaCommon.js` — remove obsolete `visibleWindows`, `primaryWindows`, and `extraWindows` selectors after all callers migrate.
- `tests/test-visibility.mjs` — remove its direct export/assertion for the deleted presentation selector while retaining configuration tests.

---

### Task 1: Define the Pure Quota-presentation Interface

**Files:**
- Create: `contents/ui/js/QuotaPresentation.js`
- Create: `tests/test-quota-presentation.mjs`
- Reference: `contents/ui/js/QuotaCommon.js:169-303`

**Interfaces:**
- Consumes: `QC.displayWindowLabel(window)` and `QC.colorModeForWindow(window, sessionMode, weeklyMode)`.
- Produces: `presentProfile(profile, { sessionColorMode, weeklyColorMode }) -> { rows }` where each row is `{ windowData, label, colorMode }`.

- [ ] **Step 1: Write the failing pure-interface test**

Create `tests/test-quota-presentation.mjs`:

```js
#!/usr/bin/env node
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))

function qmlJsSource(path) {
    return readFileSync(path, "utf8")
        .replace(/^\s*\.pragma library\s*$/gm, "")
        .replace(/^\s*\.import[^\n]*$/gm, "")
}

function loadQuotaCommon() {
    const exports = {}
    const src = qmlJsSource(join(here, "../contents/ui/js/QuotaCommon.js"))
    new Function("exports", src + `
        exports.displayWindowLabel = displayWindowLabel;
        exports.colorModeForWindow = colorModeForWindow;
    `)(exports)
    return exports
}

function loadQuotaPresentation(QC) {
    const exports = {}
    const src = qmlJsSource(join(here, "../contents/ui/js/QuotaPresentation.js"))
    new Function("QC", "exports", src + `
        exports.presentProfile = presentProfile;
    `)(QC, exports)
    return exports
}

const QC = loadQuotaCommon()
const { presentProfile } = loadQuotaPresentation(QC)

assert.deepEqual(presentProfile(null, {}).rows, [])
assert.deepEqual(presentProfile({}, {}).rows, [])
assert.deepEqual(presentProfile({ windows: "bad" }, {}).rows, [])

const windows = [
    null,
    { id: "5h", label: "5h", role: "primary", visible: true, periodMs: 18_000_000 },
    { id: "weekly_fable", label: "Fable", role: "extra", visible: true },
    { id: "hidden", label: "Hidden", role: "primary", visible: false },
    { id: "unknown", label: "Unknown", role: "other" },
    { id: "weekly_fable", label: "Duplicate", role: "extra", visible: true }
]
const profile = { id: "claude", windows }
const before = JSON.stringify(profile)
const result = presentProfile(profile, {
    sessionColorMode: "efficiency",
    weeklyColorMode: "capacity"
})

assert.deepEqual(result.rows.map(row => row.windowData.id),
                 ["5h", "weekly_fable", "unknown", "weekly_fable"])
assert.deepEqual(result.rows.map(row => row.label),
                 ["5h", "Fable", "Unknown", "Fable"])
assert.equal(result.rows[0].colorMode, "efficiency")
assert.equal(result.rows[1].colorMode, "capacity")
assert.equal(result.rows[2].colorMode, "capacity")
assert.notEqual(result.rows[1], result.rows[3])
assert.equal(result.rows[0].windowData, windows[1])
assert.equal(JSON.stringify(profile), before)

const defaults = presentProfile({ windows: [windows[1], windows[2]] }, {}).rows
assert.deepEqual(defaults.map(row => row.colorMode), ["capacity", "efficiency"])

console.log("All quota presentation tests passed.")
```

- [ ] **Step 2: Run the test and verify it fails for the missing module**

Run:

```bash
node tests/test-quota-presentation.mjs
```

Expected: FAIL with `ENOENT` for `contents/ui/js/QuotaPresentation.js`.

- [ ] **Step 3: Implement the minimal pure module**

Create `contents/ui/js/QuotaPresentation.js`:

```js
.pragma library
.import "QuotaCommon.js" as QC

function presentProfile(profile, options) {
    var rows = []
    if (!profile || !Array.isArray(profile.windows))
        return { rows: rows }

    var modes = options || {}
    for (var i = 0; i < profile.windows.length; i++) {
        var windowData = profile.windows[i]
        if (!windowData || windowData.visible === false)
            continue
        rows.push({
            windowData: windowData,
            label: QC.displayWindowLabel(windowData),
            colorMode: QC.colorModeForWindow(
                windowData,
                modes.sessionColorMode,
                modes.weeklyColorMode
            )
        })
    }
    return { rows: rows }
}
```

- [ ] **Step 4: Run the pure test and existing visibility test**

Run:

```bash
node tests/test-quota-presentation.mjs
node tests/test-visibility.mjs
```

Expected: both print their `All ... tests passed.` footer and exit `0`.

- [ ] **Step 5: Commit the interface**

```bash
git add contents/ui/js/QuotaPresentation.js tests/test-quota-presentation.mjs
git commit -m "feat(I001): add quota presentation interface"
```

---

### Task 2: Migrate QuotaRow and AccountCard

**Files:**
- Modify: `contents/ui/QuotaRow.qml:9-108`
- Modify: `contents/ui/AccountCard.qml:1-22, 213-240`
- Create: `tests/tst_quota_presentation.qml`
- Test: `tests/test-account-card-layout.mjs`

**Interfaces:**
- Consumes: `QuotaPresentation.presentProfile()` from Task 1.
- Produces: `QuotaRow.presentationRow` and an account-card repeater that renders every presentation row.

- [ ] **Step 1: Add the failing functional account-card test**

Create `tests/tst_quota_presentation.qml`:

```qml
import QtQuick
import QtTest
import "../contents/ui"

TestCase {
    name: "QuotaPresentation"

    Component {
        id: cardComponent
        AccountCard {
            width: 500
            nowMs: 1773709200000
        }
    }

    function profileWithExtra() {
        return {
            id: "claude",
            displayName: "Claude",
            enabled: true,
            loading: false,
            error: "",
            lastFetchMs: 1773709200000,
            windows: [
                { id: "5h", label: "5h", usagePercent: 37,
                  resetAtMs: 1773716460000, periodMs: 18000000,
                  role: "primary", visible: true },
                { id: "weekly_fable", label: "Fable", usagePercent: 42,
                  resetAtMs: 1773899200000, periodMs: 604800000,
                  role: "extra", visible: true }
            ]
        }
    }

    function descendantsMatching(root, predicate, seen) {
        var visited = seen || []
        if (!root || visited.indexOf(root) >= 0)
            return []
        visited.push(root)
        var found = predicate(root) ? [root] : []
        var children = root.children || []
        for (var i = 0; i < children.length; i++)
            found = found.concat(descendantsMatching(children[i], predicate, visited))
        if (root.contentItem)
            found = found.concat(descendantsMatching(root.contentItem, predicate, visited))
        return found
    }

    function labelsWithText(root, text) {
        return descendantsMatching(root, function(item) {
            return typeof item.text !== "undefined" && item.text === text
        })
    }

    function test_cardTreatsSelectedExtraAsNormalRow() {
        var card = createTemporaryObject(cardComponent, null,
                                         { profile: profileWithExtra() })
        verify(card !== null)
        wait(0)
        verify(typeof card.quotaPresentation !== "undefined",
               "card exposes the shared presentation snapshot")
        compare(card.quotaPresentation.rows.length, 2)
        compare(labelsWithText(card, "5h").length, 1)
        compare(labelsWithText(card, "Fable").length, 1)
        compare(labelsWithText(card, "37%").length, 1)
        compare(labelsWithText(card, "42%").length, 1)
    }
}
```

- [ ] **Step 2: Run the Qt test before migration**

Run in a functioning Qt test environment:

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_quota_presentation.qml \
  -import contents/ui -o -,txt
```

Expected before migration in a functioning Qt environment: FAIL because `AccountCard` has no `quotaPresentation` property. If the host exits `1` without output, record the environment limitation rather than claiming this red result; the Task 5 wiring test remains the executable local proof that the caller crosses the new seam.

- [ ] **Step 3: Change QuotaRow to consume `presentationRow`**

In `contents/ui/QuotaRow.qml`, replace the caller-owned `windowData` and `colorMode` properties with:

```qml
property var presentationRow: null
property double nowMs: Date.now()
property string mode: "data"   // data | skeleton
property bool compact: true

readonly property var windowData: presentationRow
        ? presentationRow.windowData : null
readonly property string colorMode: presentationRow
        ? presentationRow.colorMode : "capacity"
readonly property bool isSkeleton: mode === "skeleton" || !windowData
readonly property string periodLabel: isSkeleton
        ? "··" : (presentationRow.label || "")
```

Keep the existing `computeTimePercent`, `windowPaceColor`, `formatCountdown`, `tooltipExtra`, and theme-dependent rendering. In the row hover tooltip, replace `QC.displayWindowLabel(windowData)` with `rowRoot.periodLabel`.

- [ ] **Step 4: Route AccountCard through the presentation module**

Add this import to `contents/ui/AccountCard.qml`:

```qml
import "js/QuotaPresentation.js" as QP
```

Replace `quotaRows` with:

```qml
readonly property var quotaPresentation: QP.presentProfile(profile, {
    sessionColorMode: sessionColorMode,
    weeklyColorMode: weeklyColorMode
})
readonly property var quotaRows: quotaPresentation.rows
```

In the `QuotaRow` delegate, replace `windowData:` and `colorMode:` bindings with:

```qml
presentationRow: modelData
nowMs: cardRoot.nowMs
mode: modelData ? "data" : "skeleton"
compact: true
opacity: (modelData && cardRoot.refreshing) ? 0.75 : 1
```

- [ ] **Step 5: Run account-card gates**

Run:

```bash
node tests/test-quota-presentation.mjs
node tests/test-account-card-layout.mjs
node tests/test-card-typography.mjs
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_quota_presentation.qml \
  -import contents/ui -o -,txt
```

Expected: all Node tests exit `0`; the Qt test explicitly reports the selected-extra account-card test as passing in a functioning Qt environment.

- [ ] **Step 6: Commit the reusable row/card migration**

```bash
git add contents/ui/QuotaRow.qml contents/ui/AccountCard.qml \
        tests/tst_quota_presentation.qml
git commit -m "refactor(I001): route quota cards through presentation rows"
```

---

### Task 3: Unify Detail Quota Rendering

**Files:**
- Modify: `contents/ui/DetailWindow.qml:1-7, 202-251`
- Modify: `tests/tst_quota_presentation.qml`

**Interfaces:**
- Consumes: `QuotaRow.presentationRow` from Task 2 and `QuotaPresentation.presentProfile()` from Task 1.
- Produces: one role-independent detail quota list labelled `Quotas`.

- [ ] **Step 1: Add the failing detail test**

Add this component and test to `tests/tst_quota_presentation.qml`:

```qml
Component {
    id: detailComponent
    DetailWindow {
        visible: false
        nowMs: 1773709200000
    }
}

function test_detailUsesOneEqualQuotaList() {
    var profile = profileWithExtra()
    var detail = createTemporaryObject(detailComponent, null,
                                       { profile: profile, profiles: [profile] })
    verify(detail !== null)
    wait(0)
    compare(labelsWithText(detail, "Quotas").length, 1)
    compare(labelsWithText(detail, "Primary").length, 0)
    compare(labelsWithText(detail, "Extra limits").length, 0)
    compare(labelsWithText(detail, "5h").length, 1)
    compare(labelsWithText(detail, "Fable").length, 1)
    compare(labelsWithText(detail, "37%").length, 1)
    compare(labelsWithText(detail, "42%").length, 1)
}
```

- [ ] **Step 2: Run the Qt test and verify the new detail expectations fail**

Run:

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_quota_presentation.qml \
  -import contents/ui -o -,txt
```

Expected in a functioning Qt environment: FAIL because detail still shows `Primary`/`Extra limits` and has no `Quotas` heading.

- [ ] **Step 3: Replace role-separated detail lists**

Add:

```qml
import "js/QuotaPresentation.js" as QP
```

Inside `Window`, add:

```qml
readonly property var quotaPresentation: QP.presentProfile(profile, {
    sessionColorMode: sessionColorMode,
    weeklyColorMode: weeklyColorMode
})
```

Replace the Primary/Extra blocks with:

```qml
PlasmaComponents.Label {
    text: tr("Quotas")
    font.bold: true
}

ColumnLayout {
    Layout.fillWidth: true
    spacing: Kirigami.Units.smallSpacing

    Repeater {
        model: detailWin.quotaPresentation.rows
        QuotaRow {
            required property var modelData
            Layout.fillWidth: true
            presentationRow: modelData
            nowMs: detailWin.nowMs
            mode: "data"
            compact: false
        }
    }

    PlasmaComponents.Label {
        visible: detailWin.quotaPresentation.rows.length === 0
        text: profile && profile.loading ? tr("Loading...") : "—"
        color: Kirigami.Theme.disabledTextColor
    }
}
```

- [ ] **Step 4: Run detail and pure-interface tests**

Run:

```bash
node tests/test-quota-presentation.mjs
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_quota_presentation.qml \
  -import contents/ui -o -,txt
```

Expected: Node test exits `0`; Qt output explicitly reports both account-card and detail tests passing.

- [ ] **Step 5: Commit the detail migration**

```bash
git add contents/ui/DetailWindow.qml tests/tst_quota_presentation.qml
git commit -m "refactor(I001): unify detail quota presentation"
```

---

### Task 4: Clean Compact Sync and Migrate the Applet Tooltip

**Files:**
- Modify: `contents/ui/main.qml:1-40, 130-299, 533-560`
- Create: `tests/test-main-quota-presentation.mjs`

**Interfaces:**
- Consumes: `QuotaPresentation.presentProfile()` from Task 1.
- Produces: role-independent tooltip rows and compact loading diagnostics without obsolete fixed-window state.

- [ ] **Step 1: Write the failing main-wiring test**

Create `tests/test-main-quota-presentation.mjs`:

```js
#!/usr/bin/env node
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(here, "../contents/ui/main.qml"), "utf8")

function functionBlock(name) {
    const start = src.indexOf(`function ${name}(`)
    assert.notEqual(start, -1, `${name} exists`)
    const opening = src.indexOf("{", start)
    let depth = 0
    for (let i = opening; i < src.length; i++) {
        if (src[i] === "{") depth++
        if (src[i] === "}") depth--
        if (depth === 0) return src.slice(start, i + 1)
    }
    assert.fail(`${name} has a complete body`)
}

assert.match(src, /import "js\/QuotaPresentation\.js" as QP/)
const sync = functionBlock("syncCompactFromController")
const tooltip = functionBlock("tooltipText")
assert.match(sync, /QP\.presentProfile\(/)
assert.match(sync, /presentation\.rows\.length/)
assert.match(tooltip, /QP\.presentProfile\(/)
assert.match(tooltip, /presentation\.rows/)
assert.doesNotMatch(tooltip, /QC\.(primaryWindows|extraWindows|visibleWindows)/)

for (const obsolete of [
    "sessionUsagePercent", "weeklyUsagePercent",
    "sessionTimePercent", "weeklyTimePercent",
    "hasSessionWindow", "hasWeeklyWindow",
    "getSessionColor", "getWeeklyColor", "primaryWindowsFor"
]) {
    assert.equal(src.includes(obsolete), false, `${obsolete} is removed`)
}

const compact = src.slice(src.indexOf("compactRepresentation:"),
                          src.indexOf("fullRepresentation:"))
assert.match(compact, /CardsView\s*\{/)
assert.match(compact, /profiles:\s*root\.profileList/)

console.log("All main quota-presentation wiring tests passed.")
```

- [ ] **Step 2: Run the wiring test and verify it fails**

Run:

```bash
node tests/test-main-quota-presentation.mjs
```

Expected: FAIL because `main.qml` does not import `QuotaPresentation.js` and still contains obsolete scalar state.

- [ ] **Step 3: Import the module and simplify compact sync**

Add:

```qml
import "js/QuotaPresentation.js" as QP
```

Remove root properties:

```qml
sessionUsagePercent
weeklyUsagePercent
sessionTimePercent
weeklyTimePercent
hasSessionWindow
hasWeeklyWindow
```

In `syncCompactFromController()`, replace all primary/scalar branches with:

```qml
var presentation = QP.presentProfile(p, {
    sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity",
    weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
})
var quotaRowCount = presentation.rows.length
```

Use `quotaRowCount === 0` in the no-data loading condition and log `rows=quotaRowCount`. In the no-profile branch, remove assignments to the deleted scalar properties.

Delete the now-unused functions `getUsageColor`, `capacityPaceColor`, `efficiencyPaceColor`, `getSessionColor`, `getWeeklyColor`, and `primaryWindowsFor` from `main.qml`. Do not change the existing `CardsView` compact renderer.

- [ ] **Step 4: Route tooltip formatting through presentation rows**

Inside `tooltipText()`, replace the `QC.primaryWindows(p)` loop with:

```qml
var presentation = QP.presentProfile(p, {
    sessionColorMode: Plasmoid.configuration.sessionColorMode || "capacity",
    weeklyColorMode: Plasmoid.configuration.weeklyColorMode || "efficiency"
})
var rows = presentation.rows
for (var j = 0; j < rows.length; j++) {
    var row = rows[j]
    var windowData = row.windowData
    var cd = QC.formatCountdown(windowData.resetAtMs, root.nowMs)
    parts.push(row.label + " " + Math.round(windowData.usagePercent || 0) + "%"
        + (cd ? " (" + cd + ")" : ""))
}
```

Preserve banked-reset, error, loading, and empty-profile formatting.

- [ ] **Step 5: Run main integration gates**

Run:

```bash
node tests/test-main-quota-presentation.mjs
node tests/test-main-layout.mjs
node tests/test-quota-presentation.mjs
```

Expected: all three exit `0` with passing footers.

- [ ] **Step 6: Commit compact-sync/tooltip migration**

```bash
git add contents/ui/main.qml tests/test-main-quota-presentation.mjs
git commit -m "refactor(I001): unify compact sync and tooltip quota policy"
```

---

### Task 5: Enforce the Seam and Delete Old Selectors

**Files:**
- Modify: `contents/ui/js/QuotaCommon.js:262-303`
- Modify: `tests/test-visibility.mjs:10-40, 132-141`
- Create: `tests/test-quota-presentation-wiring.mjs`
- Verify: all project tests

**Interfaces:**
- Consumes: migrated callers from Tasks 2–4.
- Produces: deletion of the old selector interface and a regression gate that prevents call-site policy from returning.

- [ ] **Step 1: Write the failing seam/deletion test**

Create `tests/test-quota-presentation-wiring.mjs`:

```js
#!/usr/bin/env node
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
function read(path) {
    return readFileSync(join(here, "..", path), "utf8")
}

const callers = [
    "contents/ui/AccountCard.qml",
    "contents/ui/DetailWindow.qml",
    "contents/ui/main.qml"
]
for (const path of callers) {
    const src = read(path)
    assert.match(src, /QuotaPresentation\.js/, `${path} imports presentation module`)
    assert.doesNotMatch(src,
        /QC\.(primaryWindows|extraWindows|visibleWindows|colorModeForWindow|displayWindowLabel)\s*\(/,
        `${path} does not recreate presentation policy`)
}

const row = read("contents/ui/QuotaRow.qml")
assert.match(row, /property var presentationRow/)
assert.doesNotMatch(row, /QC\.displayWindowLabel\s*\(/)

const detail = read("contents/ui/DetailWindow.qml")
assert.doesNotMatch(detail, /tr\("Primary"\)|tr\("Extra limits"\)/)
assert.match(detail, /tr\("Quotas"\)/)

const common = read("contents/ui/js/QuotaCommon.js")
assert.doesNotMatch(common,
    /function\s+(primaryWindows|extraWindows|visibleWindows)\s*\(/)

console.log("All quota-presentation seam tests passed.")
```

- [ ] **Step 2: Run the seam test and verify it fails while selectors remain**

Run:

```bash
node tests/test-quota-presentation-wiring.mjs
```

Expected: FAIL because `QuotaCommon.js` still defines the old selectors and `tests/test-visibility.mjs` still relies on `visibleWindows`.

- [ ] **Step 3: Delete obsolete selector functions**

Remove these complete functions from `contents/ui/js/QuotaCommon.js`:

```js
visibleWindows(profile)
primaryWindows(profile)
extraWindows(profile)
```

Retain `colorModeForWindow()` and `displayWindowLabel()` because they are low-level implementation dependencies of `QuotaPresentation.js`, not caller policy.

- [ ] **Step 4: Keep visibility configuration tests focused**

In `tests/test-visibility.mjs`:

- Remove `exports.visibleWindows = visibleWindows;` from the VM export block.
- Remove `visibleWindows: visibleQuotaWindows` from destructuring.
- In the “show extra without hiding primaries” case, retain the `windowsVisible(cOut)` assertion and delete only the direct `visibleQuotaWindows(...)` assertion. Equivalent presentation coverage now lives in `tests/test-quota-presentation.mjs`.

The resulting case must be:

```js
{
    const cfg = parseVisibleWindowsConfig(JSON.stringify({
        claude: { weekly_fable: true }
    }))
    const cOut = applyVisibility(claudeWins, visibilitySpecForProvider(cfg, "claude"))
    assert(windowsVisible(cOut).join(",") === "5h,weekly,weekly_fable",
        "show fable + keep defaults")
}
```

- [ ] **Step 5: Run all repository tests**

Run serially:

```bash
node tests/test-quota-presentation.mjs
node tests/test-quota-presentation-wiring.mjs
node tests/test-main-quota-presentation.mjs
node tests/test-visibility.mjs
node tests/test-account-card-layout.mjs
node tests/test-card-typography.mjs
node tests/test-main-layout.mjs
bash tests/test-path-utils.sh
bash tests/test-cache-response.sh
bash tests/test-discovery.sh
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_card_layout.qml \
  -import contents/ui -o -,txt
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_quota_presentation.qml \
  -import contents/ui -o -,txt
```

Expected: every Node and shell test exits `0`; both Qt commands explicitly report zero failures in a functioning Qt test environment. If this host still exits `1` silently for the unchanged baseline Qt test, record that environment failure and obtain a passing Qt result elsewhere before claiming complete rendering verification.

- [ ] **Step 6: Inspect the deletion test directly**

Run:

```bash
rg -n '\b(primaryWindows|extraWindows|visibleWindows)\s*\(' contents/ui
```

Expected: no old selector calls or function definitions. Legitimate persisted-configuration names such as `visibleWindowsJson`, `visibleWindowsConfig`, and `visibleWindowIds` remain in scope and must not be renamed. Regression tests may name the deleted selectors only to assert their absence; historical prose comments in `contents/ui` must be updated or removed rather than left stale.

- [ ] **Step 7: Commit selector deletion and final gates**

```bash
git add contents/ui/js/QuotaCommon.js tests/test-visibility.mjs \
        tests/test-quota-presentation-wiring.mjs
git commit -m "refactor(I001): remove shallow quota selectors"
```

---

## Implementation Completion Gate

Before marking implementation tasks done:

1. Verify each task’s dedicated tests after its commit.
2. Run the full serial suite from Task 5.
3. Confirm `git diff --check` is clean.
4. Confirm rendering callers contain no old selector calls.
5. Verify a selected extra appears in card, detail, compact card, row hover, and applet tooltip.
6. Verify `visible === false` removes the same quota from every surface.
7. Review against `docs/superpowers/specs/2026-07-17-quota-presentation-policy-design.md`.

--- SUMMARY ---

- **Task 1:** create and unit-test the single pure presentation interface.
- **Task 2:** make `QuotaRow` and account cards consume presentation rows.
- **Task 3:** replace detail’s Primary/Extra split with one equal quota list.
- **Task 4:** remove obsolete compact-sync selectors and migrate applet tooltip formatting.
- **Task 5:** enforce the seam, delete old selectors, and run the full regression suite.
- Implementation remains out of scope for the current planning/ingestion work.
