#!/usr/bin/env node
/**
 * P1.M2.E1.T003–T006 / I002 — ProfileController production refresh seam.
 *
 * Source-contract only (no Plasma/Qt runtime). Asserts the transaction import,
 * thin production ports, generation-guarded transition application, retained
 * global queue/due/timer scheduling, deletion of old lifecycle choreography
 * (standard + Grok + auth helpers), and that accepted refreshes enter
 * ProfileRefresh.run.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const src = readFileSync(join(root, "contents/ui/ProfileController.qml"), "utf8")

// --- transaction import + production ports ---
assert.match(src, /import "js\/ProfileRefresh\.js" as ProfileRefresh/)
assert.match(src, /function readRefreshCredentials\s*\(/)
assert.match(src, /function requestRefreshHttp\s*\(/)
assert.match(src, /function recordRefreshExchange\s*\(/)
assert.match(src, /function applyRefreshTransition\s*\(/)
assert.match(src, /function startProfileRefresh\s*\(/)
assert.match(src, /ProfileRefresh\.run\s*\(/)

// Stable ID + generation seam
assert.match(src, /findProfileIndex\(transition\.profileId\)/)
assert.match(src, /refreshGeneration !== transition\.generation/)

// Accepted queue items enter the transaction (not loadCredentials)
assert.match(src, /startProfileRefresh\(\s*idx\s*,\s*(?:!!)?item\.manual\s*\)/)

// Global scheduling retained
for (const name of [
    "queueProfileRefresh",
    "drainOneRefresh",
    "staggerRefreshAll",
    "refreshAll",
    "refreshProfile",
    "dueProfiles"
]) {
    assert.match(src, new RegExp(`function ${name}\\s*\\(`), `${name} retained`)
}

// Thin credential port: capacity/HOME/path only — no provider/auth/retry policy
{
    const m = src.match(/function readRefreshCredentials\s*\([^)]*\)\s*\{/)
    assert.ok(m, "readRefreshCredentials present")
    const start = m.index
    const body = extractBalanced(src, start + m[0].length - 1)
    assert.doesNotMatch(body, /extractAuth|fetchUsage|fetchGrok|noteAuthFailure|QP\.parse/)
    assert.doesNotMatch(body, /anthropic-beta|ChatGPT-Account-Id|cli-chat-proxy/)
    assert.match(body, /pendingCredCount|maxCredInflight/)
    assert.match(body, /catCommand|homeReady/)
    console.log("ok: readRefreshCredentials is thin (capacity/HOME/path only)")
}

// Thin HTTP port: XHR plumbing only — no provider/status/JSON policy
{
    const m = src.match(/function requestRefreshHttp\s*\([^)]*\)\s*\{/)
    assert.ok(m, "requestRefreshHttp present")
    const start = m.index
    const body = extractBalanced(src, start + m[0].length - 1)
    assert.doesNotMatch(body, /extractAuth|fetchUsage|fetchGrok|noteAuthFailure|noteRateLimited|QP\.parse/)
    assert.doesNotMatch(body, /anthropic-beta|ChatGPT-Account-Id|parseClaude|parseCodex|parseGrok/)
    assert.match(body, /XMLHttpRequest/)
    assert.match(body, /fromTimeout/)
    console.log("ok: requestRefreshHttp is thin (XHR only)")
}

// Transition application routes through registry (I003 Task 4)
{
    const m = src.match(/function applyRefreshTransition\s*\([^)]*\)\s*\{/)
    assert.ok(m, "applyRefreshTransition present")
    const body = extractBalanced(src, m.index + m[0].length - 1)
    assert.match(body, /type\s*===\s*["']started["']|transition\.type\s*===\s*["']started["']/)
    assert.match(body, /["']success["']/)
    assert.match(body, /Registry\.transition\s*\(/)
    assert.match(body, /type:\s*"usageResult"/)
    assert.match(body, /type:\s*"patch"/)
    assert.match(body, /applyRegistryResult\s*\(/)
    assert.doesNotMatch(body, /applyUsageResult\s*\(/)
    console.log("ok: applyRefreshTransition routes started/success via registry")
}

// Success path injects production visibility adapter + live config snapshot
{
    assert.match(src, /function applyRegistryResult\s*\(/)
    assert.match(src, /function registryConfigSnapshot\s*\(/)
    assert.match(src, /function registryVisibilityAdapter\s*\(/)
    assert.match(src, /visibleWindowsJson/)
    console.log("ok: registry adapter + live config snapshot present")
}

// refreshGeneration is a live profile field
assert.match(src, /refreshGeneration/)

// Task 5: no Grok dual-fetch lifecycle or live-profile transaction state
for (const name of ["fetchGrok", "grokGet", "finishGrokPart"]) {
    assert.doesNotMatch(src, new RegExp(`function ${name}\\s*\\(`),
        `${name} must be deleted`)
}
assert.doesNotMatch(src, /\bgrokFetchGen\b/, "no grokFetchGen on profiles")
for (const field of [
    "grokPending",
    "grokDefaultSettled",
    "grokCreditsSettled",
    "grokFinalized",
    "grokDefaultBody",
    "grokCreditsBody",
    "grokDefaultStatus",
    "grokCreditsStatus",
    "grokDefaultFromTimeout",
    "grokCreditsFromTimeout",
    "grokAuthFailed"
]) {
    assert.doesNotMatch(src, new RegExp(`\\b${field}\\b`),
        `no transient Grok field ${field}`)
}
console.log("ok: Grok legacy lifecycle and live transaction state removed")

// Task 6: final seam — global scheduling retained; old lifecycle deleted
for (const name of [
    "loadCredentials",
    "noteAuthFailure",
    "noteRateLimited",
    "clearFailureStatePatch",
    "extractAuth",
    "pickGrokToken",
    "extractOpencodeAuth",
    "usageUrl",
    "fetchUsage",
    "fetchGrok",
    "grokGet",
    "finishGrokPart",
    "endpointSlugForProvider",
    "grokEndpointSlug"
]) {
    assert.doesNotMatch(src, new RegExp(`function ${name}\\s*\\(`),
        `${name} must be deleted`)
}
// No standard-provider policy / parser dispatch left in the controller
assert.doesNotMatch(src, /import\s+"js\/QuotaParsers\.js"\s+as\s+QP/)
assert.doesNotMatch(src, /QP\.parse(Claude|Codex|Minimax|Zai|Kimi|Grok)\s*\(/)
assert.doesNotMatch(src, /anthropic-beta|ChatGPT-Account-Id/)
// Old generation fields gone; one generic refreshGeneration remains
assert.doesNotMatch(src, /\busageFetchGen\b/, "no usageFetchGen on profiles")
assert.match(src, /\brefreshGeneration\b/)
// Response-cache path still reachable (via thin record port)
assert.match(src, /function recordRefreshExchange\s*\(/)
assert.match(src, /responseCache\.recordExchange|cacheResponse\s*\(/)
// Still-used cache metadata helper until I005 fully relocates callers
assert.match(src, /function effectiveProvider\s*\(/)
console.log("ok: old lifecycle choreography deleted; transaction seam enforced")

console.log("All profile refresh controller seam tests passed.")

/** Extract `{ ... }` body starting at the opening brace index. */
function extractBalanced(text, openBraceIdx) {
    if (text.charAt(openBraceIdx) !== "{")
        throw new Error("expected '{' at " + openBraceIdx)
    let depth = 0
    for (let i = openBraceIdx; i < text.length; i++) {
        const c = text.charAt(i)
        if (c === "{") depth++
        else if (c === "}") {
            depth--
            if (depth === 0)
                return text.slice(openBraceIdx, i + 1)
        }
    }
    throw new Error("unbalanced braces from " + openBraceIdx)
}
