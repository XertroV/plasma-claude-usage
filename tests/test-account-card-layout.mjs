#!/usr/bin/env node
/**
 * B038 regression test: profile errors stay inside the fixed header row.
 */
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import { dirname, join } from "path"

const __dirname = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(__dirname, "../contents/ui/AccountCard.qml"), "utf8")

let failed = 0
function assert(cond, msg) {
    if (!cond) {
        console.error("FAIL:", msg)
        failed++
    } else {
        console.log("ok:", msg)
    }
}

function objectBlockAt(source, start) {
    const openingBrace = source.indexOf("{", start)
    if (start < 0 || openingBrace < 0) return ""

    let depth = 0
    for (let i = openingBrace; i < source.length; i++) {
        if (source[i] === "{") depth++
        if (source[i] === "}") depth--
        if (depth === 0) return source.slice(start, i + 1)
    }
    return ""
}

function directChildTypes(objectBlock) {
    const types = []
    let depth = 1
    for (const line of objectBlock.split("\n").slice(1)) {
        const trimmed = line.trim()
        if (depth === 1) {
            const match = trimmed.match(/^([A-Za-z][A-Za-z0-9_.]*)\s*\{$/)
            if (match) types.push(match[1])
        }
        depth += (line.match(/\{/g) || []).length
        depth -= (line.match(/\}/g) || []).length
    }
    return types
}

function headerControlsInOrder(headerBlock) {
    const banked = headerBlock.indexOf('text: "↻" + profile.bankedResets')
    const refresh = headerBlock.indexOf("id: refreshSlot")
    const details = headerBlock.indexOf("id: detailBtn")
    return banked >= 0 && banked < refresh && refresh < details
}

const contentStart = src.indexOf("ColumnLayout {")
const contentCol = objectBlockAt(src, contentStart)
const headerStart = contentCol.indexOf("RowLayout {")
const header = objectBlockAt(contentCol, headerStart)
const textSlotStart = header.indexOf("id: headerTextSlot")
const nameStart = header.indexOf("id: nameLabel")
const errorStart = header.indexOf("id: errorLabel")
const refreshStart = header.indexOf("id: refreshSlot")
const errorObjectStart = header.lastIndexOf("PlasmaComponents.Label {", errorStart)
const errorLabel = objectBlockAt(header, errorObjectStart)
const bankedTextStart = header.indexOf('text: "↻" + profile.bankedResets')
const bankedObjectStart = header.lastIndexOf("PlasmaComponents.Label {", bankedTextStart)
const bankedLabel = objectBlockAt(header, bankedObjectStart)
const refreshObjectStart = header.lastIndexOf("Item {", refreshStart)
const refreshSlot = objectBlockAt(header, refreshObjectStart)

assert(contentCol !== "", "account card content column exists")
assert(directChildTypes(contentCol).join("|") === "RowLayout|ColumnLayout",
    "content column has only the header and quota rows (no separate error row)")
assert(header.includes("id: headerRow"), "profile header row has a stable identity")
assert(textSlotStart >= 0 && header.includes("Layout.fillWidth: true")
       && header.includes("Layout.minimumWidth: 0"),
    "header text slot takes only the space left by fixed controls")
assert(nameStart >= 0 && errorStart > nameStart && refreshStart > errorStart,
    "inline error follows the profile name and precedes refresh/overflow controls")
assert(errorLabel.includes("Kirigami.Theme.negativeTextColor"),
    "inline error uses the theme error colour")
assert(errorLabel.includes("elide: Text.ElideRight")
       && errorLabel.includes("wrapMode: Text.NoWrap")
       && errorLabel.includes("maximumLineCount: 1"),
    "inline error is safely constrained to one elided line")
assert(errorLabel.includes("Accessible.name:")
       && errorLabel.includes("Accessible.ignored:")
       && errorLabel.includes("QQC2.ToolTip"),
    "inline error preserves full text for accessibility and hover")
assert(header.includes("id: refreshSlot")
       && header.includes("Layout.preferredWidth: Kirigami.Units.iconSizes.small")
       && header.includes("id: detailBtn")
       && header.includes("Layout.preferredWidth: implicitWidth"),
    "refresh/loading and overflow controls retain fixed layout slots")
assert(headerControlsInOrder(header),
    "banked resets precede Refresh, which precedes Details")

const swapMarker = "__B039_BANKED_BADGE__"
const headerWithOldOrder = header
    .replace(bankedLabel, swapMarker)
    .replace(refreshSlot, bankedLabel)
    .replace(swapMarker, refreshSlot)
assert(!headerControlsInOrder(headerWithOldOrder),
    "header-order check detects Refresh and banked resets being swapped")

// I001 Task 2: presentation seam — every selected quota (including extras) is a normal row
assert(src.includes('import "js/QuotaPresentation.js" as QP'),
    "account card imports the quota presentation module")
assert(src.includes("readonly property var quotaPresentation: QP.presentProfile(profile,"),
    "account card exposes the shared presentation snapshot")
assert(src.includes("readonly property var quotaRows: quotaPresentation.rows"),
    "account card repeats presentation rows rather than role-filtered windows")
assert(src.includes("presentationRow: modelData"),
    "account card feeds each presentation row into QuotaRow")
assert(!src.includes("QC.visibleWindows(")
       && !src.includes("QC.colorModeForWindow(")
       && !src.includes("QC.primaryWindows(")
       && !src.includes("QC.extraWindows("),
    "account card does not recreate presentation policy with shallow selectors")
assert(!src.includes("role: \"extra\"")
       && !src.includes("role === \"extra\"")
       && !src.includes('role == "extra"'),
    "account card does not special-case extra roles when rendering rows")

const quotaRowSrc = readFileSync(join(__dirname, "../contents/ui/QuotaRow.qml"), "utf8")
assert(quotaRowSrc.includes("property var presentationRow"),
    "QuotaRow consumes a presentation row")
assert(quotaRowSrc.includes("presentationRow.label"),
    "QuotaRow label comes from the presentation interface")
assert(quotaRowSrc.includes("presentationRow.colorMode"),
    "QuotaRow colour mode comes from the presentation interface")
assert(!quotaRowSrc.includes("QC.displayWindowLabel("),
    "QuotaRow does not resolve labels via QuotaCommon policy")

// Pure-interface proof: selected extra is an equal presentation row (not secondary)
const presentationSrc = readFileSync(
    join(__dirname, "../contents/ui/js/QuotaPresentation.js"), "utf8")
    .replace(/^\s*\.pragma library\s*$/gm, "")
    .replace(/^\s*\.import[^\n]*$/gm, "")
const commonSrc = readFileSync(
    join(__dirname, "../contents/ui/js/QuotaCommon.js"), "utf8")
    .replace(/^\s*\.pragma library\s*$/gm, "")
    .replace(/^\s*\.import[^\n]*$/gm, "")
const QC = {}
new Function("exports", commonSrc + `
    exports.displayWindowLabel = displayWindowLabel;
    exports.colorModeForWindow = colorModeForWindow;
`)(QC)
const QP = {}
new Function("QC", "exports", presentationSrc + `
    exports.presentProfile = presentProfile;
`)(QC, QP)
const extraProfile = {
    id: "claude",
    windows: [
        { id: "5h", label: "5h", role: "primary", visible: true, periodMs: 18_000_000 },
        { id: "weekly_fable", label: "Fable", role: "extra", visible: true }
    ]
}
const presented = QP.presentProfile(extraProfile, {
    sessionColorMode: "capacity",
    weeklyColorMode: "efficiency"
})
assert(presented.rows.length === 2, "selected extra is included as a normal presentation row")
assert(presented.rows[0].label === "5h" && presented.rows[1].label === "Fable",
    "presentation labels treat primary and extra equally")
assert(presented.rows[0].colorMode === "capacity"
       && presented.rows[1].colorMode === "efficiency",
    "colour modes resolve from presentation interface, not caller role checks")
assert(presented.rows[0].windowData === extraProfile.windows[0]
       && presented.rows[1].windowData === extraProfile.windows[1],
    "presentation rows retain original window data by reference")

if (failed) {
    console.error(`\n${failed} failure(s)`)
    process.exit(1)
}
console.log("\nAll account card layout tests passed.")
