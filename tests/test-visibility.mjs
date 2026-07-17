#!/usr/bin/env node
/**
 * P1.M4.E1.T001 — runtime visibility through VisibleQuotaConfig.specFor()/apply().
 * Characterises legacy/global/per-provider formats, OpenCode identity, immutability,
 * dynamic windows, foreign opaque specs, and malformed input safety.
 */
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const VQ = loadQmlJs(
    join(root, "contents/ui/js/VisibleQuotaConfig.js"), {},
    ["specFor", "apply"]
)

function visibleIds(windows) {
    return windows.filter(window => window.visible !== false)
        .map(window => window.id)
}

const claudeWindows = [
    { id: "5h", label: "5h", defaultVisible: true, visible: false },
    { id: "weekly", label: "7d", defaultVisible: true },
    { id: "weekly_fable", label: "Fable", defaultVisible: false }
]
const grokWindows = [
    { id: "session", label: "7d/build", defaultVisible: true },
    { id: "weekly", label: "mo", defaultVisible: true }
]

// --- empty / defaults ---
for (const raw of [null, undefined, "", "[]", "{}", [], {}]) {
    assert.deepEqual(
        visibleIds(VQ.apply(claudeWindows, VQ.specFor({ provider: "claude" }, raw))),
        ["5h", "weekly"]
    )
}

// --- legacy global allowlist ---
assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" }, '["5h"]'))),
    ["5h"]
)
assert.deepEqual(
    visibleIds(VQ.apply(grokWindows,
        VQ.specFor({ provider: "grok" }, '["5h"]'))),
    []
)

// --- sparse global map ---
assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" },
            '{"5h":true,"weekly":false}'))),
    ["5h"]
)

// --- sparse per-provider map ---
assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" },
            '{"claude":{"weekly_fable":true}}'))),
    ["5h", "weekly", "weekly_fable"]
)
assert.deepEqual(
    visibleIds(VQ.apply(grokWindows,
        VQ.specFor({ provider: "grok" },
            '{"claude":{"weekly":false}}'))),
    ["session", "weekly"]
)

// --- strict per-provider array ---
assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" },
            '{"claude":["5h"]}'))),
    ["5h"]
)

// --- provider identity (incl. OpenCode slot / profileKey) ---
const identityCases = [
    [{ provider: "claude" }, "claude"],
    [{ provider: "codex" }, "codex"],
    [{ provider: "opencode", opencodeSlot: "anthropic" }, "claude"],
    [{ provider: "opencode", opencodeSlot: "openai" }, "codex"],
    [{ provider: "opencode", opencodeSlot: "kimi" }, "kimi"],
    [{ provider: "opencode", opencodeSlot: "zai" }, "zai"],
    [{ provider: "opencode", opencodeSlot: "future" }, "opencode"],
    [{ provider: "opencode", profileKey: "anthropic-accounts" }, "claude"],
    [{ provider: "opencode", profileKey: "openai" }, "codex"],
    [{ provider: "opencode", profileKey: "codex-work" }, "codex"],
    [{ provider: "opencode", profileKey: "kimi" }, "kimi"],
    [{ provider: "opencode", profileKey: "z-ai" }, "zai"],
    [{ provider: "opencode" }, "claude"]
]
for (const [profile, key] of identityCases) {
    const raw = JSON.stringify({ [key]: { dynamic: false } })
    const out = VQ.apply(
        [{ id: "dynamic", defaultVisible: true }],
        VQ.specFor(profile, raw)
    )
    assert.equal(out[0].visible, false, JSON.stringify(profile))
}

// --- immutability, order/duplicates, ignore stale visible, foreign/malformed ---
const source = [
    { id: "future", defaultVisible: false, visible: true, nested: { keep: true } },
    { id: "dup", defaultVisible: true },
    { id: "dup", defaultVisible: true }
]
const before = JSON.stringify(source)
const configured = VQ.apply(source, VQ.specFor(
    { provider: "claude" },
    '{"claude":{"future":true,"dup":false}}'
))
assert.deepEqual(visibleIds(configured), ["future"])
assert.equal(JSON.stringify(source), before)
assert.notEqual(configured, source)
assert.notEqual(configured[0], source[0])
assert.equal(configured[0].nested, source[0].nested)
assert.equal(configured.length, 3)
assert.deepEqual(VQ.apply("bad", VQ.specFor(null, "bad json")), [])
const foreignSpec = Object.freeze({
    implementationDetail: Object.freeze({ mode: "strict", weekly: false })
})
assert.deepEqual(VQ.apply(
    [null, { id: "x", defaultVisible: true }], foreignSpec),
    [{ id: "x", defaultVisible: true, visible: true }])

console.log("All visibility tests passed.")
