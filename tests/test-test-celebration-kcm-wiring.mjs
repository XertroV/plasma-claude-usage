#!/usr/bin/env node
/**
 * Structural wiring checks for the Settings test-celebration producer.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const configQml = readFileSync(join(root, "contents/ui/configGeneral.qml"), "utf8")
const requestsJs = readFileSync(join(root, "contents/ui/js/TestCelebrationRequests.js"), "utf8")

function functionBody(source, name) {
    const declaration = new RegExp(`function\\s+${name}\\s*\\(`)
    const match = declaration.exec(source)
    assert.ok(match, `missing ${name}()`)

    const openingBrace = source.indexOf("{", match.index + match[0].length)
    assert.notEqual(openingBrace, -1, `missing body for ${name}()`)

    let depth = 0
    let quote = ""
    let escaped = false
    let lineComment = false
    let blockComment = false

    for (let i = openingBrace; i < source.length; ++i) {
        const current = source[i]
        const next = source[i + 1]

        if (lineComment) {
            if (current === "\n") lineComment = false
            continue
        }
        if (blockComment) {
            if (current === "*" && next === "/") {
                blockComment = false
                ++i
            }
            continue
        }
        if (quote) {
            if (escaped) escaped = false
            else if (current === "\\") escaped = true
            else if (current === quote) quote = ""
            continue
        }
        if (current === "/" && next === "/") {
            lineComment = true
            ++i
            continue
        }
        if (current === "/" && next === "*") {
            blockComment = true
            ++i
            continue
        }
        if (current === '"' || current === "'") {
            quote = current
            continue
        }
        if (current === "{") ++depth
        else if (current === "}" && --depth === 0)
            return source.slice(openingBrace + 1, i)
    }

    assert.fail(`unterminated body for ${name}()`)
}

assert.match(configQml, /import "js\/TestCelebrationRequests\.js" as TestCelebrationRequests/)
assert.match(
    configQml,
    /readonly property string testCelebrationBridgeScript:\s*\{[\s\S]*Qt\.resolvedUrl\("\.\.\/scripts\/test-celebration-bridge\.sh"\)[\s\S]*file:\/\//
)
assert.match(
    configQml,
    /QQC2\.Button\s*\{[\s\S]{0,500}?text:\s*tr\("Send test celebration"\)[\s\S]{0,500}?onClicked:\s*configPage\.sendTestCelebration\(\)/
)

const producer = functionBody(configQml, "sendTestCelebration")
assert.match(producer, /QuotaReset\.formatNotification\s*\(/)
assert.match(producer, /windowId:\s*"5h"/)
assert.match(producer, /windowLabel:\s*"5h"/)
assert.match(producer, /kind:\s*"natural"/)
assert.match(producer, /Preview from Settings — no reset was logged\./)
assert.match(producer, /TestCelebrationRequests\.createRequest\s*\(/)
assert.match(producer, /TestCelebrationRequests\.serializeRequest\s*\(/)
assert.match(producer, /Date\.now\s*\(\)/)
assert.match(producer, /Math\.random\s*\(\)/)
assert.match(producer, /shellQuote\s*\(payload\)/)
assert.match(producer, /shellQuote\s*\(testCelebrationBridgeScript\)/)
assert.match(producer, /\| bash [\s\S]* write/)
assert.match(producer, /testCelebrationWriter\.connectSource\s*\(/)

const notificationTry = producer.indexOf("try {")
const notificationSend = producer.indexOf("sendEvent()")
const notificationCatch = producer.indexOf("catch", notificationSend)
const writerTry = producer.indexOf("try {", notificationCatch)
const writerConnect = producer.indexOf("testCelebrationWriter.connectSource", writerTry)
assert.ok(notificationTry >= 0 && notificationSend > notificationTry, "notification must have its own try")
assert.ok(notificationCatch > notificationSend, "notification attempt must be caught")
assert.ok(writerTry > notificationCatch && writerConnect > writerTry, "writer must have a separate try")
assert.match(producer.slice(writerConnect), /catch[\s\S]*console\.log/)

assert.match(configQml, /function shellQuote\s*\([^)]+\)\s*\{[\s\S]*?replace\(\/'\/g, "'\\\\''"\)/)
const shellQuote = value => "'" + String(value).replace(/'/g, "'\\''") + "'"
const requestModule = {}
vm.runInNewContext(requestsJs.replace(/^\.pragma library\s*$/m, ""), requestModule)
const arbitraryRequest = requestModule.createRequest(123456789, function() {
    return "single'quote newline\n unicode— shell;$()"
})
const arbitraryPayload = requestModule.serializeRequest(arbitraryRequest)
const shellCommand = "printf %s " + shellQuote(arbitraryPayload)
const roundTrip = await import("node:child_process").then(({ execFileSync }) =>
    execFileSync("bash", ["-c", shellCommand], { encoding: "utf8" }))
assert.equal(roundTrip, arbitraryPayload, "shell quoting must preserve arbitrary serialized JSON")

for (const forbidden of [
    "handleQuotaResets",
    "buildLogCommand",
    "logQuotaResetEnvelopes",
    "log-reset.sh"
]) {
    assert.equal(producer.includes(forbidden), false, `sendTestCelebration() must not reference ${forbidden}`)
}

const compatibility = functionBody(configQml, "sendTestQuotaResetNotification")
assert.match(compatibility, /sendTestCelebration\s*\(\)/)

assert.match(
    configQml,
    /Plasma5Support\.DataSource\s*\{[\s\S]{0,300}?id:\s*testCelebrationWriter[\s\S]{0,1200}?engine:\s*"executable"[\s\S]{0,1200}?onNewData:[\s\S]{0,1200}?disconnectSource\s*\(sourceName\)[\s\S]{0,1200}?console\.log/
)
assert.match(configQml, /id:\s*testCelebrationWriter[\s\S]{0,1800}?exitCode/)
assert.match(configQml, /id:\s*testCelebrationWriter[\s\S]{0,1800}?stderr/)
assert.match(configQml, /id:\s*testCelebrationWriter[\s\S]{0,1800}?error/)

console.log("All Settings test-celebration wiring tests passed.")
