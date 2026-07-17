#!/usr/bin/env node
/**
 * P1.M2.E1.T003–T004 / I002 Tasks 3–4 — ProfileController refresh transaction seam.
 *
 * Source-contract only (no Plasma/Qt runtime). Asserts the transaction import,
 * thin production ports, generation-guarded transition application, global
 * queue/due/timer scheduling, and that standard-provider credential/request/
 * parser lifecycle is gone from the controller (transaction authoritative).
 * Grok legacy remains until T005.
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

// Transition application re-reads visibility on success
{
    const m = src.match(/function applyRefreshTransition\s*\([^)]*\)\s*\{/)
    assert.ok(m, "applyRefreshTransition present")
    const body = extractBalanced(src, m.index + m[0].length - 1)
    assert.match(body, /type\s*===\s*["']started["']|transition\.type\s*===\s*["']started["']/)
    assert.match(body, /["']success["']/)
    assert.match(body, /applyUsageResult/)
    console.log("ok: applyRefreshTransition handles started/success + applyUsageResult")
}

// applyUsageResult still re-reads live visibility (B034)
{
    const applyIdx = src.indexOf("function applyUsageResult")
    assert.ok(applyIdx >= 0, "applyUsageResult present")
    const applyBody = src.slice(applyIdx, applyIdx + 1200)
    assert.match(applyBody, /registryVisibilityAdapter\s*\(/)
    assert.match(applyBody, /visibleWindowsJson/)
    assert.match(applyBody, /\.specFor\(/)
    console.log("ok: applyUsageResult re-reads live visibility")
}

// refreshGeneration is a live profile field
assert.match(src, /refreshGeneration/)

// --- Task 4: no standard-provider XHR / header / URL / parser lifecycle ---
// Transaction path is authoritative for Claude, Codex, MiniMax, Z.ai, Kimi, OpenCode.
assert.doesNotMatch(src, /function fetchUsage\s*\(/)
assert.doesNotMatch(src, /QP\.parse(Claude|Codex|Minimax|Zai|Kimi)\s*\(/)
assert.doesNotMatch(src, /anthropic-beta|ChatGPT-Account-Id/)
// Auth/URL helpers that only served the standard fetch path
assert.doesNotMatch(src, /function extractAuth\s*\(/)
assert.doesNotMatch(src, /function extractOpencodeAuth\s*\(/)
assert.doesNotMatch(src, /function usageUrl\s*\(/)
console.log("ok: no standard-provider lifecycle (fetchUsage/headers/parsers/auth/url)")

// applyUsageResult remains as live visibility/store adapter only
assert.match(src, /function applyUsageResult\s*\(/)
assert.match(src, /function effectiveProvider\s*\(/)

// Grok legacy retained until T005 (do not require deletion yet)
assert.match(src, /function fetchGrok\s*\(/)
assert.match(src, /function grokGet\s*\(/)
assert.match(src, /function finishGrokPart\s*\(/)

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
