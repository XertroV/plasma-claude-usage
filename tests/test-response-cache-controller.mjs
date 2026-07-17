import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const adapterPath = join(root, "contents/ui/LocalResponseCache.qml")
const adapter = readFileSync(adapterPath, "utf8")
const pipelineSrc = readFileSync(
    join(root, "contents/ui/js/ResponseCachePipeline.js"), "utf8")

// --- local adapter: effects-only (executable DataSource + one timer) ---
assert.match(adapter, /import "js\/ResponseCachePipeline\.js" as Pipeline/)
assert.match(adapter, /property bool enabled/)
assert.match(adapter, /property string configuredRoot/)
assert.match(adapter, /property string homeDir/)
assert.match(adapter, /function recordExchange\s*\(exchange\)/)
assert.match(adapter, /Pipeline\.create\s*\(/)
assert.match(adapter, /engine:\s*"executable"/)
assert.match(adapter, /pipeline\.commandFinished\s*\(sourceName/)
assert.match(adapter, /pipeline\.watchdogFired\s*\(\)/)
assert.match(adapter, /interval:\s*12000/)
assert.match(adapter, /repeat:\s*false/)
assert.doesNotMatch(adapter, /JSON\.parse\s*\(.*responseText|function\s+profileSlug/)
// no cache policy helpers in the adapter
assert.doesNotMatch(adapter, /function\s+(buildEnvelope|buildPaths|buildCommands|slug|pad2|pad3)\s*\(/)
assert.doesNotMatch(adapter, /function\s+(enqueueCacheWrite|drainCacheWriteQueue|launchCacheWrite)\s*\(/)

// pure core owns policy; adapter does not re-implement staging/queue
assert.match(pipelineSrc, /function recordExchange\s*\(exchange\)/)
assert.match(pipelineSrc, /function commandFinished\s*\(/)
assert.match(pipelineSrc, /function watchdogFired\s*\(/)
assert.match(pipelineSrc, /return\s*\{\s*recordExchange:\s*recordExchange/)

// --- controller migration / deletion contract (T004 + T005) ---
const controller = readFileSync(
    join(root, "contents/ui/ProfileController.qml"), "utf8")
assert.match(controller, /LocalResponseCache\s*\{/)
assert.match(controller,
    /function recordRefreshExchange\s*\(exchange\)\s*\{\s*responseCache\.recordExchange\(exchange\)\s*\}/s)
// direct forwarding only — no local envelope/path/queue body
assert.doesNotMatch(controller,
    /function recordRefreshExchange\s*\(exchange\)\s*\{[^}]*JSON\.(parse|stringify)/s)
for (const name of [
    "pad2", "pad3", "profileSlug", "responseCacheRoot",
    "buildResponseCachePaths", "cfgBool", "enqueueCacheWrite",
    "drainCacheWriteQueue", "launchCacheWrite", "onCacheWriteWatchdogFired",
    "absoluteCacheRoot", "nextPendingPayloadPath",
    "enqueuePayloadFileCacheWrite", "cacheResponse"
]) {
    assert.doesNotMatch(controller, new RegExp(`function ${name}\\s*\\(`))
}
// no residual calls to deleted cache helpers (recombine seam regression)
for (const call of [
    "cacheResponse\\s*\\(",
    "enqueueCacheWrite\\s*\\(",
    "drainCacheWriteQueue\\s*\\(",
    "launchCacheWrite\\s*\\(",
    "onCacheWriteWatchdogFired\\s*\\(",
    "buildResponseCachePaths\\s*\\(",
    "nextPendingPayloadPath\\s*\\(",
    "enqueuePayloadFileCacheWrite\\s*\\("
]) {
    assert.doesNotMatch(controller, new RegExp(call))
}
for (const field of [
    "_cacheWriteQueue", "_cacheWriteBusy", "_cacheWriteSeq",
    "_cacheWriteInFlightCmd", "_cacheWriteInFlightSource",
    "_cacheWriteAttempt", "cacheWriteWatchdogMs", "cacheWriteMaxAttempts",
    "_cachePendingSeq", "cachePayloadChunkSize"
]) assert.doesNotMatch(controller, new RegExp(`\\b${field}\\b`))
assert.doesNotMatch(controller, /id:\s*cacheWriter\b|id:\s*cacheWriteWatchdog\b/)
assert.doesNotMatch(controller, /readonly property string cacheScript/)
// legacy call sites (if any remain) must use the thin port, not deleted helpers
const legacyCacheForwards = [...controller.matchAll(/recordRefreshExchange\s*\(/g)]
assert.ok(legacyCacheForwards.length >= 1,
    "controller must forward at least via recordRefreshExchange")

// I002 once-only: ports.recordExchange(exchange) before preparation.finalize
const refresh = readFileSync(
    join(root, "contents/ui/js/ProfileRefresh.js"), "utf8")
const cacheIndex = refresh.indexOf("ports.recordExchange(exchange)")
const finalizeIndex = refresh.indexOf("preparation.finalize", cacheIndex)
assert.ok(cacheIndex >= 0 && finalizeIndex > cacheIndex)

console.log("Response cache adapter/controller contract passed.")
