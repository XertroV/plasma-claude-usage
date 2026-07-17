#!/usr/bin/env node
/**
 * B035 regression test for the full-representation header/footer layout.
 */
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import { dirname, join } from "path"

const __dirname = dirname(fileURLToPath(import.meta.url))
const src = readFileSync(join(__dirname, "../contents/ui/main.qml"), "utf8")

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
    const lines = objectBlock.split("\n")
    const types = []
    let depth = 1

    for (const line of lines.slice(1)) {
        const trimmed = line.trim()
        if (depth === 1) {
            const objectMatch = trimmed.match(/^([A-Za-z][A-Za-z0-9_.]*)\s*\{$/)
            if (objectMatch) types.push(objectMatch[1])
        }
        depth += (line.match(/\{/g) || []).length
        depth -= (line.match(/\}/g) || []).length
    }
    return types
}

function cardsBlockWithin(scrollViewBlock) {
    return objectBlockAt(scrollViewBlock, scrollViewBlock.indexOf("CardsView {"))
}

function footerControlBlocks(footer) {
    const refreshStart = footer.indexOf("PlasmaComponents.Button {")
    const refreshButton = objectBlockAt(footer, refreshStart)
    const statusStart = footer.indexOf(
        "PlasmaComponents.Label {",
        refreshStart + refreshButton.length
    )
    const statusLabel = objectBlockAt(footer, statusStart)
    const configureStart = footer.indexOf(
        "PlasmaComponents.Button {",
        statusStart + statusLabel.length
    )
    const configureButton = objectBlockAt(footer, configureStart)
    return { refreshButton, statusLabel, configureButton }
}

function footerHasSemanticOrder(footer) {
    if (directChildTypes(footer).join("|")
        !== "PlasmaComponents.Button|PlasmaComponents.Label|PlasmaComponents.Button") {
        return false
    }
    const controls = footerControlBlocks(footer)
    return controls.refreshButton.includes('icon.name: "view-refresh"')
        && controls.refreshButton.includes('root.i18nObj.tr("Refresh")')
        && controls.statusLabel.includes('root.i18nObj.tr("Updated:")')
        && controls.configureButton.includes('icon.name: "configure"')
        && controls.configureButton.includes('root.i18nObj.tr("Configure…")')
}

const fullStart = src.indexOf("fullRepresentation: Item {")
const fullSource = src.slice(fullStart)
const scrollStart = fullSource.indexOf("PlasmaComponents.ScrollView {")
const headerSource = fullSource.slice(0, scrollStart)
const scrollBlock = objectBlockAt(fullSource, scrollStart)
const cardsBlock = cardsBlockWithin(scrollBlock)
const updatedIndex = fullSource.indexOf('root.i18nObj.tr("Updated:")')
const footerStart = fullSource.lastIndexOf("RowLayout {", updatedIndex)
const footerBlock = objectBlockAt(fullSource, footerStart)
const footerControls = footerControlBlocks(footerBlock)

assert(fullStart >= 0, "full representation exists")
assert(scrollStart >= 0 && scrollBlock !== "", "full representation scroll view exists")
assert(cardsBlock !== "", "cards remain inside the scroll view")
assert(scrollBlock.includes("QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff"),
    "horizontal card scrollbar is disabled")
assert(!scrollBlock.includes("QQC2.ScrollBar.vertical.policy: QQC2.ScrollBar.AlwaysOff"),
    "vertical card scrolling is not disabled")
assert(/height:\s*Math\.max\(implicitHeight,\s*fullScroll\.availableHeight\s*>\s*0/s.test(cardsBlock),
    "cards remain taller than the viewport when content overflows")
assert(!headerSource.includes('root.i18nObj.tr("AI Usage")'), "header omits the AI Usage label")
assert(!headerSource.includes('../icons/claude.svg'), "header omits the Claude logo")
assert(!headerSource.includes('icon.name: "view-refresh"'), "header omits the refresh button")
assert(footerStart >= scrollStart + scrollBlock.length
       && footerBlock.includes('root.i18nObj.tr("Updated:")'),
    "status label is in the footer below the cards")
assert(footerHasSemanticOrder(footerBlock),
    "footer direct children are Refresh, Updated, then Configure")

const footerWithSpacer = footerBlock.replace(
    footerControls.statusLabel,
    "Rectangle {\n                }\n                " + footerControls.statusLabel
)
assert(!footerHasSemanticOrder(footerWithSpacer),
    "footer-order check detects an inserted spacer")

const swapMarker = "__B035_FIRST_BUTTON__"
const footerWithButtonsSwapped = footerBlock
    .replace(footerControls.refreshButton, swapMarker)
    .replace(footerControls.configureButton, footerControls.refreshButton)
    .replace(swapMarker, footerControls.configureButton)
assert(!footerHasSemanticOrder(footerWithButtonsSwapped),
    "footer-order check detects Refresh and Configure being swapped")

const scrollWithoutCards = scrollBlock.replace(cardsBlock, "")
assert(cardsBlockWithin(scrollWithoutCards) === "",
    "scroll containment check detects cards moved outside the scroll view")

if (failed) {
    console.error(`\n${failed} failure(s)`)
    process.exit(1)
}
console.log("\nAll main layout tests passed.")
