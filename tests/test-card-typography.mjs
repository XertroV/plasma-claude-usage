#!/usr/bin/env node
/**
 * B036 regression test for readable, compact card typography.
 *
 * The card flow is deliberately dense, so compact text should sit between the
 * theme's small and default fonts rather than jumping to a fixed pixel size.
 */
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import { dirname, join } from "path"

const __dirname = dirname(fileURLToPath(import.meta.url))
const uiDir = join(__dirname, "../contents/ui")
const accountCard = readFileSync(join(uiDir, "AccountCard.qml"), "utf8")
const quotaRow = readFileSync(join(uiDir, "QuotaRow.qml"), "utf8")
const cardsView = readFileSync(join(uiDir, "CardsView.qml"), "utf8")

let failed = 0
function assert(cond, msg) {
    if (!cond) {
        console.error("FAIL:", msg)
        failed++
    } else {
        console.log("ok:", msg)
    }
}

function count(source, needle) {
    return source.split(needle).length - 1
}

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

const themeMidpoint = /Math\.round\(\s*\(\s*Kirigami\.Theme\.smallFont\.pixelSize\s*\+\s*Kirigami\.Theme\.defaultFont\.pixelSize\s*\)\s*\/\s*2\s*\)/

assert(/readonly property int contentFontPixelSize:/.test(accountCard)
       && themeMidpoint.test(accountCard),
    "account card derives readable compact text from theme fonts")
assert(count(accountCard, "font.pixelSize: cardRoot.contentFontPixelSize") === 2,
    "account name and error text use the readable card size")
assert(count(accountCard, "elide: Text.ElideRight") >= 2
       && accountCard.includes("wrapMode: Text.NoWrap")
       && accountCard.includes("maximumLineCount: 1"),
    "larger inline header text retains bounded single-line truncation")

assert(/property int textPixelSize:/.test(quotaRow)
       && /compact\s*\?/.test(quotaRow)
       && themeMidpoint.test(quotaRow)
       && /:\s*Kirigami\.Theme\.defaultFont\.pixelSize/.test(quotaRow),
    "quota rows use the theme midpoint when compact and default font otherwise")
assert(count(quotaRow, "font.pixelSize: rowRoot.textPixelSize") === 3,
    "all quota row labels share the readable text size")
const periodLabel = findObjectBlock(quotaRow, "PlasmaComponents.Label",
    "text: rowRoot.periodLabel")
const paceBar = findObjectBlock(quotaRow, "PaceBar",
    "usagePercent: isSkeleton ? 0 : rowRoot.usagePct")
const percentageLabel = findObjectBlock(quotaRow, "PlasmaComponents.Label",
    "Math.round(rowRoot.usagePct) + \"%\"")
const countdownLabel = findObjectBlock(quotaRow, "PlasmaComponents.Label",
    "QC.formatCountdown(windowData.resetAtMs, nowMs)")

assert(periodLabel.includes("Layout.preferredWidth: Math.min(implicitWidth, Kirigami.Units.gridUnit * 2)")
       && periodLabel.includes("elide: Text.ElideRight")
       && periodLabel.includes("Layout.fillWidth: false"),
    "period column stays tight and elided")
assert(paceBar.includes("Layout.fillWidth: true")
       && paceBar.includes("Layout.preferredWidth: 0"),
    "pace bar receives remaining quota-row width")
assert(percentageLabel.includes("Layout.preferredWidth: implicitWidth")
       && percentageLabel.includes("Layout.maximumWidth: Kirigami.Units.gridUnit * 1.75")
       && percentageLabel.includes("horizontalAlignment: Text.AlignRight")
       && percentageLabel.includes("Layout.fillWidth: false"),
    "percentage column is natural-width and right-aligned")
assert(countdownLabel.includes("Layout.preferredWidth: implicitWidth")
       && countdownLabel.includes("Kirigami.Units.gridUnit * 2.75")
       && countdownLabel.includes("elide: Text.ElideRight")
       && countdownLabel.includes("horizontalAlignment: Text.AlignRight")
       && countdownLabel.includes("Layout.fillWidth: false"),
    "countdown uses a thin natural width and remains right-aligned")
assert(count(quotaRow, "Layout.fillWidth: true") === 2,
    "only the quota row and pace bar opt into fill width")
assert(accountCard.includes("textPixelSize: cardRoot.contentFontPixelSize"),
    "account cards pass their compact text size to quota rows")

assert(/readonly property int contentFontPixelSize:/.test(cardsView)
       && themeMidpoint.test(cardsView),
    "card-flow status text derives the same theme-relative compact size")
assert(count(cardsView, "font.pixelSize: cardsRoot.contentFontPixelSize") === 2,
    "overflow and empty-state labels use the readable card-flow size")
assert(cardsView.includes("property int cardMinWidth: Kirigami.Units.gridUnit * 11")
       && cardsView.includes("Math.floor((avail + cardFlow.spacing)")
       && cardsView.includes("return Math.max(minWidth, w)"),
    "multi-column sizing remains grid-unit based and width bounded")
assert(cardsView.includes("maximumLineCount: 4")
       && cardsView.includes("elide: Text.ElideRight"),
    "card-flow empty text remains line-bounded and elided")

if (failed) {
    console.error(`\n${failed} failure(s)`)
    process.exit(1)
}
console.log("\nAll card typography tests passed.")
