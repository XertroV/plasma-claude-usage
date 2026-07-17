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

const fullStart = src.indexOf("fullRepresentation: Item {")
const fullSource = src.slice(fullStart)
const scrollStart = fullSource.indexOf("PlasmaComponents.ScrollView {")
const cardsStart = fullSource.indexOf("CardsView {", scrollStart)
const headerSource = fullSource.slice(0, scrollStart)
const scrollProperties = fullSource.slice(scrollStart, cardsStart)
const updatedIndex = fullSource.indexOf('root.i18nObj.tr("Updated:")')
const refreshIndex = fullSource.lastIndexOf('icon.name: "view-refresh"', updatedIndex)

assert(fullStart >= 0, "full representation exists")
assert(scrollStart >= 0, "full representation scroll view exists")
assert(cardsStart > scrollStart, "cards remain inside the scroll view")
assert(scrollProperties.includes("QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff"),
    "horizontal card scrollbar is disabled")
assert(!headerSource.includes('root.i18nObj.tr("AI Usage")'), "header omits the AI Usage label")
assert(!headerSource.includes('../icons/claude.svg'), "header omits the Claude logo")
assert(!headerSource.includes('icon.name: "view-refresh"'), "header omits the refresh button")
assert(refreshIndex > scrollStart, "refresh button is in the footer below the main panel")
assert(updatedIndex > refreshIndex, "Updated label is immediately to the right of Refresh")

const betweenRefreshAndUpdated = fullSource.slice(refreshIndex, updatedIndex)
assert(!betweenRefreshAndUpdated.includes("Item {"),
    "no spacer separates Refresh from Updated")
assert((betweenRefreshAndUpdated.match(/PlasmaComponents\.Label \{/g) || []).length === 1,
    "Updated is the next labelled control after Refresh")

if (failed) {
    console.error(`\n${failed} failure(s)`)
    process.exit(1)
}
console.log("\nAll main layout tests passed.")
