#!/usr/bin/env node
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const Motion = loadQmlJs(join(here, "../contents/ui/js/CelebrationMotion.js"), {}, ["at"])

const idle = {
    scale: 1, translateX: 0, washOpacity: 0, glyphOpacity: 0,
    glyphScale: 0.78, glyphY: 0, borderMix: 0, borderWidth: 1
}
assert.deepEqual(Motion.at(0, false), idle)
assert.deepEqual(Motion.at(1, false), idle)
assert.deepEqual(Motion.at(-2, false), idle)
assert.deepEqual(Motion.at(8, false), idle)
assert.deepEqual(Motion.at(Number.NaN, false), idle)

const anticipation = Motion.at(0.1, false)
const peak = Motion.at(0.38, false)
const accent = Motion.at(0.5, false)
const resolve = Motion.at(0.82, false)
assert.ok(anticipation.scale < 1, "anticipation should gather before the peak")
assert.ok(peak.scale > 1.035 && peak.washOpacity >= 0.65)
assert.ok(peak.glyphOpacity >= 0.95 && peak.borderMix >= 0.95)
assert.ok(accent.scale < peak.scale && accent.washOpacity < peak.washOpacity)
assert.ok(resolve.scale < accent.scale && resolve.washOpacity < accent.washOpacity)
assert.ok(resolve.glyphOpacity < accent.glyphOpacity)

for (let step = 0; step <= 100; step++) {
    const p = step / 100
    const full = Motion.at(p, false)
    const reduced = Motion.at(p, true)
    assert.ok(full.scale <= 1.045, `scale bounded at ${p}`)
    assert.ok(Math.abs(full.translateX) <= 4, `translation bounded at ${p}`)
    assert.ok(full.washOpacity >= 0 && full.washOpacity <= 1)
    assert.ok(full.glyphOpacity >= 0 && full.glyphOpacity <= 1)
    assert.ok(full.borderMix >= 0 && full.borderMix <= 1)
    assert.equal(reduced.scale, 1, `reduced scale neutral at ${p}`)
    assert.equal(reduced.translateX, 0, `reduced translation neutral at ${p}`)
    assert.equal(reduced.washOpacity, full.washOpacity)
    assert.equal(reduced.glyphOpacity, full.glyphOpacity)
    assert.equal(reduced.borderMix, full.borderMix)
}
assert.ok(Motion.at(0.38, true).washOpacity > 0.6)
assert.ok(Motion.at(0.38, true).glyphOpacity > 0.9)

console.log("All celebration motion tests passed.")
