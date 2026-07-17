#!/usr/bin/env node
/**
 * P1.M4.E1.T004 — source contracts: production visibility adapter delegates to
 * VisibleQuotaConfig.specFor()/apply(); opaque specs are not inspected outside
 * VisibleQuotaConfig.js; ProfileRegistry retains the injected adapter seam.
 *
 * Residual (pre-T003): KCM still owns local visibility choreography; KCM-side
 * wiring assertions land with Task 3 / T005. This file covers runtime only.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const controller = readFileSync(
    join(root, "contents/ui/ProfileController.qml"), "utf8")
const registry = readFileSync(
    join(root, "contents/ui/js/ProfileRegistry.js"), "utf8")
const kcm = readFileSync(
    join(root, "contents/ui/configGeneral.qml"), "utf8")

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

// Live config re-read on accepted usage path (controller still owns applyUsageResult
// until full I003 registry integration wires transition()).
assert.match(controller, /function\s+applyUsageResult\s*\(/)
assert.match(controller,
    /cfgValue\(\s*["']visibleWindowsJson["']\s*,\s*["']\[]["']\s*\)/)
assert.match(controller, /adapter\.specFor\(\s*p\s*,\s*rawVis\s*\)/)
assert.match(controller, /adapter\.apply\(\s*result\.windows/)

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
