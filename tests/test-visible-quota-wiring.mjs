#!/usr/bin/env node
/**
 * P1.M4.E1.T003/T004 — source contracts for the visible-quota seam:
 *   - KCM projects/edits via VQ.configuration(); writes only when changed:true
 *   - Production visibility adapter delegates to VQ.specFor()/apply()
 *   - Opaque specs are not inspected outside VisibleQuotaConfig.js
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const kcm = readFileSync(join(root, "contents/ui/configGeneral.qml"), "utf8")
const controller = readFileSync(
    join(root, "contents/ui/ProfileController.qml"), "utf8")
const registry = readFileSync(
    join(root, "contents/ui/js/ProfileRegistry.js"), "utf8")

// --- KCM seam (P1.M4.E1.T003) ---
assert.match(kcm, /import "js\/VisibleQuotaConfig\.js" as VQ/)
assert.match(kcm, /property var visibleQuotaConfiguration:/)
assert.match(kcm, /function projectVisibleQuotaConfiguration\s*\(/)
assert.match(kcm, /function editVisibleQuotaConfiguration\s*\(/)
assert.match(kcm, /VQ\.configuration\s*\(/)
assert.match(kcm, /if \(result\.changed\)/)
assert.match(kcm, /cfg_visibleWindowsJson\s*=\s*result\.persisted/)
assert.match(kcm, /visibleQuotaConfiguration\.providers/)
assert.match(kcm, /editVisibleQuotaConfiguration\s*\(\s*\{/)
assert.doesNotMatch(kcm,
    /function\s+(hydrateVisibleByProvider|pushVisibleJson|setWindowVisible|resetProviderWindowDefaults)\s*\(/)
// Local catalogue / hydration / edit choreography must be gone
for (const name of [
    "providerWindowCatalog", "visibleByProvider", "hydrateVisibleByProvider",
    "catalogForProvider", "pushVisibleJson", "isWindowChecked",
    "setWindowVisible", "providerMapMatchesDefaults",
    "resetWindowDefaults", "resetProviderWindowDefaults"
]) {
    assert.equal(kcm.includes(name), false, `${name} deleted from KCM`)
}

console.log("Visible quota KCM wiring passed.")

// --- Runtime adapter (P1.M4.E1.T004) ---
assert.match(controller, /import "js\/VisibleQuotaConfig\.js" as VQ/)
assert.match(controller, /function\s+registryVisibilityAdapter\s*\(/)
assert.match(controller, /specFor:\s*function\s*\(profile,\s*persisted\)/)
assert.match(controller, /return VQ\.specFor\(profile,\s*persisted\)/)
assert.match(controller, /apply:\s*function\s*\(windows,\s*spec,\s*nowMs\)/)
assert.match(controller, /var projected\s*=\s*VQ\.apply\(windows,\s*spec\)/)
assert.match(controller, /QC\.updateTimePercent\(projected\[i\],\s*nowMs\)/)
assert.doesNotMatch(controller,
    /QC\.(parseVisibleWindowsConfig|visibilityProviderKey|visibilitySpecForProvider|applyVisibility)\s*\(/)
assert.match(registry, /visibility\.specFor\s*\(/)
assert.match(registry, /visibility\.apply\s*\(/)

// Live config re-read on accepted usage path (via registry usageResult + config snapshot)
assert.match(controller, /function\s+applyUsageResult\s*\(/)
assert.match(controller, /function\s+registryConfigSnapshot\s*\(/)
assert.match(controller, /type:\s*"usageResult"/)
assert.match(controller,
    /visibleWindowsJson:\s*cfgValue\(\s*["']visibleWindowsJson["']\s*,\s*["']\[]["']\s*\)/)
assert.match(controller, /registryVisibilityAdapter\s*\(/)
assert.match(controller, /Registry\.transition\s*\(/)

const forbiddenSpecReads = []
for (const [name, source] of [
    ["ProfileController.qml", controller],
    ["ProfileRegistry.js", registry],
    ["configGeneral.qml", kcm]
]) {
    for (const match of source.matchAll(/\bspec\s*\.\s*[A-Za-z_$][\w$]*/g))
        forbiddenSpecReads.push(`${name}:${match[0]}`)
}
assert.deepEqual(forbiddenSpecReads, [],
                 "opaque visibility spec inspected outside VisibleQuotaConfig.js")

// Time percentages must stay outside VisibleQuotaConfig
const vq = readFileSync(
    join(root, "contents/ui/js/VisibleQuotaConfig.js"), "utf8")
assert.doesNotMatch(vq, /timePercent|updateTimePercent|computeTimePercent/)

console.log("Visible quota runtime wiring passed.")

// --- Deletion / sole-seam enforcement (P1.M4.E1.T005) ---
const common = readFileSync(
    join(root, "contents/ui/js/QuotaCommon.js"), "utf8")
for (const name of [
    "isWindowBoolMap", "parseVisibleWindowsConfig", "visibilityProviderKey",
    "visibilitySpecForProvider", "applyVisibility"
]) {
    assert.doesNotMatch(common, new RegExp(`function\\s+${name}\\s*\\(`),
                        `${name} deleted from QuotaCommon`)
}
for (const name of [
    "providerWindowCatalog", "visibleByProvider", "hydrateVisibleByProvider",
    "catalogForProvider", "pushVisibleJson", "isWindowChecked",
    "setWindowVisible", "providerMapMatchesDefaults",
    "resetWindowDefaults", "resetProviderWindowDefaults"
]) {
    assert.equal(kcm.includes(name), false, `${name} deleted from KCM`)
}
assert.match(controller, /registryVisibilityAdapter\s*\(/)
assert.match(controller, /VQ\.specFor\s*\(/)
assert.match(controller, /VQ\.apply\s*\(/)
assert.doesNotMatch(controller,
    /\.mode\s*===\s*"(?:defaults|globalAllowlist|globalMap|perProvider)"/)
assert.doesNotMatch(common, /function\s+objectKeyCount\s*\(/)

console.log("Visible quota deletion seam passed.")
