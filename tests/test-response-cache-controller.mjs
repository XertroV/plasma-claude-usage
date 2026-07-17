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

console.log("Response cache adapter/controller contract passed.")
