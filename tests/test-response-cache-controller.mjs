import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const adapterPath = join(root, "contents/ui/LocalResponseCache.qml")
const adapter = readFileSync(adapterPath, "utf8")

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

// --- controller migration / deletion contract (T004) ---
const controller = readFileSync(
    join(root, "contents/ui/ProfileController.qml"), "utf8")
assert.match(controller, /LocalResponseCache\s*\{/)
assert.match(controller,
    /function recordRefreshExchange\s*\(exchange\)\s*\{\s*responseCache\.recordExchange\(exchange\)\s*\}/s)
for (const name of [
    "pad2", "pad3", "profileSlug", "responseCacheRoot",
    "buildResponseCachePaths", "cfgBool", "enqueueCacheWrite",
    "drainCacheWriteQueue", "launchCacheWrite", "onCacheWriteWatchdogFired",
    "absoluteCacheRoot", "nextPendingPayloadPath",
    "enqueuePayloadFileCacheWrite", "cacheResponse"
]) {
    assert.doesNotMatch(controller, new RegExp(`function ${name}\\s*\\(`))
}
for (const field of [
    "_cacheWriteQueue", "_cacheWriteBusy", "_cacheWriteSeq",
    "_cacheWriteInFlightCmd", "_cacheWriteInFlightSource",
    "_cacheWriteAttempt", "cacheWriteWatchdogMs", "cacheWriteMaxAttempts",
    "_cachePendingSeq", "cachePayloadChunkSize"
]) assert.doesNotMatch(controller, new RegExp(`\\b${field}\\b`))
assert.doesNotMatch(controller, /id:\s*cacheWriter\b|id:\s*cacheWriteWatchdog\b/)
assert.doesNotMatch(controller, /readonly property string cacheScript/)

// I002 once-only: ports.recordExchange(exchange) before preparation.finalize
const refresh = readFileSync(
    join(root, "contents/ui/js/ProfileRefresh.js"), "utf8")
const cacheIndex = refresh.indexOf("ports.recordExchange(exchange)")
const finalizeIndex = refresh.indexOf("preparation.finalize", cacheIndex)
assert.ok(cacheIndex >= 0 && finalizeIndex > cacheIndex)

console.log("Response cache adapter/controller contract passed.")
