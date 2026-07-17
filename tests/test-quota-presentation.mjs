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
