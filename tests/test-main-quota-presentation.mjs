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
