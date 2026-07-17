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

if (failed) {
    console.error(`\n${failed} failure(s)`)
    process.exit(1)
}
console.log("\nAll account card layout tests passed.")
