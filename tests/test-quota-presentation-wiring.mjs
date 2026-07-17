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
