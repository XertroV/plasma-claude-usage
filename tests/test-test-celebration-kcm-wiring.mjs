#!/usr/bin/env node
/**
 * Proportionate structural checks for the Settings celebration producer.
 * Behaviour of the shared formatter and shellQuote seams is exercised by
 * test-quota-reset-events.mjs; this file checks only QML wiring and isolation.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const configQml = readFileSync(join(root, "contents/ui/configGeneral.qml"), "utf8")

// Position-preserving mask for QML's embedded JavaScript. It hides literals,
// comments, and regex bodies so decoys and braces in /[}]/ do not affect scans.
function codeMask(source) {
    const out = source.split("")
    let state = "code"
    let quote = ""
    let escaped = false
    let regexClass = false
    let prior = "start"
    const blank = i => { if (source[i] !== "\n" && source[i] !== "\r") out[i] = " " }
    for (let i = 0; i < source.length; ++i) {
        const c = source[i]
        const n = source[i + 1]
        if (state === "line") {
            if (c === "\n") state = "code"
            else blank(i)
            continue
        }
        if (state === "block") {
            blank(i)
            if (c === "*" && n === "/") { blank(++i); state = "code" }
            continue
        }
        if (state === "string") {
            blank(i)
            if (escaped) escaped = false
            else if (c === "\\") escaped = true
            else if (c === quote) { state = "code"; prior = "value" }
            continue
        }
        if (state === "regex") {
            blank(i)
            if (escaped) escaped = false
            else if (c === "\\") escaped = true
            else if (c === "[") regexClass = true
            else if (c === "]") regexClass = false
            else if (c === "/" && !regexClass) {
                while (/[A-Za-z]/.test(source[i + 1] || "")) blank(++i)
                state = "code"
                prior = "value"
            }
            continue
        }
        if (c === "/" && n === "/") { blank(i); blank(++i); state = "line"; continue }
        if (c === "/" && n === "*") { blank(i); blank(++i); state = "block"; continue }
        if (c === '"' || c === "'" || c === "`") {
            blank(i); quote = c; escaped = false; state = "string"; continue
        }
        if (c === "/" && prior !== "value" && prior !== "close") {
            blank(i); escaped = false; regexClass = false; state = "regex"; continue
        }
        if (/\s/.test(c)) continue
        if (/[A-Za-z0-9_$]/.test(c)) {
            let end = i + 1
            while (/[A-Za-z0-9_$]/.test(source[end] || "")) ++end
            const token = source.slice(i, end)
            prior = /^(return|throw|case|delete|void|typeof|new|in|of|yield|await)$/.test(token)
                ? "operator" : "value"
            i = end - 1
        } else if (c === ")" || c === "]" || c === "}") prior = "close"
        else if (c === ".") prior = "value"
        else prior = "operator"
    }
    return out.join("")
}

function matching(source, open, left = "{", right = "}") {
    const mask = codeMask(source)
    assert.equal(mask[open], left, `expected ${left} at ${open}`)
    let depth = 0
    for (let i = open; i < mask.length; ++i) {
        if (mask[i] === left) ++depth
        else if (mask[i] === right && --depth === 0) return i
    }
    assert.fail(`unterminated ${left}${right} scope`)
}

function bracedAfter(source, start, label) {
    const open = codeMask(source).indexOf("{", start)
    assert.notEqual(open, -1, `missing ${label} body`)
    const close = matching(source, open)
    return { start: open, end: close + 1, bodyStart: open + 1, bodyEnd: close,
        body: source.slice(open + 1, close), full: source.slice(open, close + 1) }
}

function functionRange(source, name) {
    const found = new RegExp(`\\bfunction\\s+${name}\\s*\\(`).exec(codeMask(source))
    assert.ok(found, `missing ${name}()`)
    return bracedAfter(source, found.index + found[0].length, `${name}()`)
}

function objectRanges(source, type) {
    const ranges = []
    const mask = codeMask(source)
    const pattern = new RegExp(`\\b${type.replaceAll(".", "\\.")}\\s*\\{`, "g")
    let found
    while ((found = pattern.exec(mask))) {
        const range = bracedAfter(source, found.index, type)
        ranges.push(range)
        pattern.lastIndex = range.end
    }
    return ranges
}

function objectById(source, type, id) {
    const matches = objectRanges(source, type).filter(range =>
        new RegExp(`\\bid\\s*:\\s*${id}\\b`).test(codeMask(range.body)))
    assert.equal(matches.length, 1, `expected one ${type} id ${id}`)
    return matches[0]
}

function propertyFunction(source, name) {
    const found = new RegExp(`\\b${name}\\s*:\\s*function\\s*\\([^)]*\\)`).exec(codeMask(source))
    assert.ok(found, `missing ${name} callback`)
    return bracedAfter(source, found.index + found[0].length, name)
}

function splitTopLevel(source) {
    const mask = codeMask(source)
    const parts = []
    let start = 0
    let braces = 0
    let brackets = 0
    let parens = 0
    for (let i = 0; i <= mask.length; ++i) {
        if (mask[i] === "{") ++braces
        else if (mask[i] === "}") --braces
        else if (mask[i] === "[") ++brackets
        else if (mask[i] === "]") --brackets
        else if (mask[i] === "(") ++parens
        else if (mask[i] === ")") --parens
        if ((mask[i] === "," && !braces && !brackets && !parens) || i === mask.length) {
            parts.push(source.slice(start, i).trim())
            start = i + 1
        }
    }
    return parts
}

function callRanges(source, callee) {
    const ranges = []
    const mask = codeMask(source)
    const pattern = new RegExp(`${callee}\\s*\\(`, "g")
    let found
    while ((found = pattern.exec(mask))) {
        const open = mask.indexOf("(", found.index)
        const close = matching(source, open, "(", ")")
        ranges.push({ start: found.index, end: close + 1, args: source.slice(open + 1, close) })
        pattern.lastIndex = close + 1
    }
    return ranges
}

function objectProperties(expression, label) {
    const mask = codeMask(expression)
    const open = mask.search(/\S/)
    assert.equal(mask[open], "{", `${label} must be an object literal`)
    const close = matching(expression, open)
    assert.equal(mask.slice(close + 1).trim(), "", `${label} must contain only its object`)
    const properties = new Map()
    for (const entry of splitTopLevel(expression.slice(open + 1, close))) {
        const property = /^\s*([A-Za-z_$][\w$]*)\s*:/.exec(codeMask(entry))
        assert.ok(property, `${label} contains an unsupported property`)
        assert.equal(properties.has(property[1]), false, `${label} must not duplicate ${property[1]}`)
        properties.set(property[1], entry.slice(property[0].length).trim())
    }
    return properties
}

function topLevelTries(source) {
    const mask = codeMask(source)
    const tries = []
    let depth = 0
    for (let i = 0; i < mask.length; ++i) {
        if (mask[i] === "{") { ++depth; continue }
        if (mask[i] === "}") { --depth; continue }
        if (depth || mask.slice(i, i + 3) !== "try" || /[\w$]/.test(mask[i - 1] || "")
                || /[\w$]/.test(mask[i + 3] || "")) continue
        const tryOpen = mask.indexOf("{", i + 3)
        const tryClose = matching(source, tryOpen)
        const catchAt = mask.slice(tryClose + 1).search(/\bcatch\b/) + tryClose + 1
        assert.ok(catchAt > tryClose, "top-level try must have catch")
        const catchOpen = mask.indexOf("{", catchAt)
        const catchClose = matching(source, catchOpen)
        tries.push({ start: i, end: catchClose + 1,
            tryBody: source.slice(tryOpen + 1, tryClose),
            catchBody: source.slice(catchOpen + 1, catchClose), full: source.slice(i, catchClose + 1) })
        i = catchClose
    }
    return tries
}

function normalize(source) { return codeMask(source).replace(/\s+/g, " ").trim() }
function replaceBody(source, range, body) {
    return source.slice(0, range.bodyStart) + body + source.slice(range.bodyEnd)
}

function validate(source) {
    assert.match(source, /^import "js\/QuotaResetEvents\.js" as QuotaReset$/m)
    assert.match(source, /^import "js\/TestCelebrationRequests\.js" as TestCelebrationRequests$/m)
    assert.match(source, /Qt\.resolvedUrl\("\.\.\/scripts\/test-celebration-bridge\.sh"\)/)

    const buttons = objectRanges(source, "QQC2.Button").filter(range =>
        /text:\s*tr\("Send test celebration"\)/.test(range.body))
    assert.equal(buttons.length, 1, "expected one test-celebration button")
    assert.match(codeMask(buttons[0].body), /onClicked:\s*configPage\.sendTestCelebration\(\)/)

    const producerRange = functionRange(source, "sendTestCelebration")
    const producer = producerRange.body
    const producerCode = codeMask(producer)
    const attempts = topLevelTries(producer)
    assert.equal(attempts.length, 2, "notification and writer attempts must be sibling top-level try/catches")
    const [notification, writer] = attempts
    assert.match(codeMask(notification.catchBody), /console\.log/)
    assert.match(codeMask(writer.catchBody), /console\.log/)

    const helperCalls = callRanges(notification.tryBody, "QuotaReset\\.formatSettingsPreviewNotification")
    assert.equal(helperCalls.length, 1, "notification attempt must directly call the pure preview helper once")
    assert.equal(helperCalls[0].args.trim(), "", "preview helper takes no arguments")
    const previewDeclaration = /\bvar\s+preview\s*=\s*QuotaReset\.formatSettingsPreviewNotification\s*\(\s*\)/
        .exec(codeMask(notification.tryBody))
    assert.ok(previewDeclaration, "preview helper result must be declared as preview")

    const creates = callRanges(notification.tryBody, "testResetNotificationComponent\\.createObject")
    assert.equal(creates.length, 1, "notification attempt must create exactly one notification")
    assert.ok(previewDeclaration.index < creates[0].start, "preview declaration must precede notification use")
    const createArgs = splitTopLevel(creates[0].args)
    assert.equal(createArgs.length, 2, "createObject must receive parent and properties")
    const properties = objectProperties(createArgs[1], "notification properties")
    assert.equal(normalize(properties.get("title") || ""), "String(preview.title)",
        "notification title must directly use preview.title")
    assert.equal(normalize(properties.get("text") || ""), "String(preview.text)",
        "notification text must directly use preview.text")
    assert.match(codeMask(notification.tryBody), /\.sendEvent\s*\(\)/)
    assert.doesNotMatch(codeMask(notification.tryBody), /testCelebrationWriter\.connectSource/)

    const writerCode = codeMask(writer.tryBody)
    assert.match(writerCode, /TestCelebrationRequests\.createRequest\s*\(/)
    assert.match(writerCode, /TestCelebrationRequests\.serializeRequest\s*\(/)
    assert.match(writerCode, /Date\.now\s*\(\)/)
    assert.match(writerCode, /Math\.random\s*\(\)/)
    const expectedCommand = `"printf %s " + QuotaReset.shellQuote(payload)
        + " | bash " + QuotaReset.shellQuote(testCelebrationBridgeScript) + " write"`
    const command = /\bvar\s+command\s*=([\s\S]*?)\btestCelebrationWriter\.connectSource\s*\(([^)]*)\)/
        .exec(writer.tryBody)
    assert.ok(command, "writer must build and connect its command")
    assert.equal(command[1].replace(/\s+/g, " ").trim().replace(/;$/, ""),
        expectedCommand.replace(/\s+/g, " ").trim(),
        "writer command must directly use shared shellQuote for payload and bridge")
    assert.equal(command[2].trim(), "command", "connectSource must receive command")

    for (const forbidden of ["handleQuotaResets", "buildLogCommand", "logQuotaResetEnvelopes"])
        assert.doesNotMatch(producerCode, new RegExp(`\\b${forbidden}\\s*\\(`))
    assert.doesNotMatch(producer, /["']log-reset\.sh["']/)

    const wrapper = functionRange(source, "sendTestQuotaResetNotification")
    assert.equal(normalize(wrapper.body).replace(/;$/, ""), "sendTestCelebration()",
        "compatibility wrapper must delegate only")

    assert.doesNotMatch(producerCode, /(?<!QuotaReset\.)\bshellQuote\s*\(/,
        "producer must not use a local shellQuote")
    assert.doesNotMatch(codeMask(source), /\bfunction\s+shellQuote\s*\(/,
        "configGeneral must not define shellQuote")
    const discovery = functionRange(source, "runDiscover")
    assert.match(discovery.body.replace(/\s+/g, " "),
        /discoverSource\.connectSource\("bash " \+ QuotaReset\.shellQuote\(discoverScript\)\)/,
        "discovery command must preserve semantics through shared shellQuote")

    const dataSource = objectById(source, "Plasma5Support.DataSource", "testCelebrationWriter")
    assert.match(dataSource.body, /engine:\s*"executable"/)
    const completion = propertyFunction(dataSource.body, "onNewData")
    const completionCode = codeMask(completion.body)
    for (const field of ["exit code", "exit status", "stderr", "error", "errorString"])
        assert.ok(completion.body.includes(`["${field}"]`), `writer must read ${field} locally`)
    const disconnect = /disconnectSource\s*\(sourceName\)/.exec(completionCode)
    const failure = /\bif\s*\(/.exec(completionCode)
    assert.ok(disconnect && failure && disconnect.index < failure.index,
        "writer must disconnect before local failure handling")
    assert.match(completionCode, /console\.log/)
}

function mutateNestedWriter(source) {
    const range = functionRange(source, "sendTestCelebration")
    const attempts = topLevelTries(range.body)
    const body = range.body.slice(0, attempts[0].end - 1) + "\n" + attempts[1].full
        + range.body.slice(attempts[0].end - 1, attempts[1].start) + range.body.slice(attempts[1].end)
    return replaceBody(source, range, body)
}
function mutateDisconnected(source) {
    return source.replace("testCelebrationWriter.connectSource(command)",
        "testCelebrationWriter.connectSource(payload)")
}
function mutateDataSourceBleed(source) {
    return source.replace("id: testCelebrationWriter", "id: decoyWriter")
        .replace("id: discoverSource", "id: testCelebrationWriter")
}
function mutateWrapper(source) {
    const range = functionRange(source, "sendTestQuotaResetNotification")
    return replaceBody(source, range, "sendTestCelebration(); buildLogCommand()")
}
function mutateCommentDecoy(source) {
    const range = functionRange(source, "sendTestCelebration")
    const body = range.body.replace(
        /var preview = QuotaReset\.formatSettingsPreviewNotification\(\)/,
        'var preview = null\n            // QuotaReset.formatSettingsPreviewNotification()')
    return replaceBody(source, range, body)
}
function mutateRegexBrace(source) {
    const range = functionRange(source, "sendTestCelebration")
    return replaceBody(source, range, range.body + "\nvar brace = /[}]/; buildLogCommand()")
}
function mutateDuplicateProperty(source) {
    return source.replace("title: String(preview.title),",
        'title: String(preview.title),\n                title: "wrong",')
}

const mutants = {
    "nested-writer": mutateNestedWriter,
    "disconnected-command": mutateDisconnected,
    "datasource-bleed": mutateDataSourceBleed,
    "wrapper-side-effect": mutateWrapper,
    "comment-string-decoy": mutateCommentDecoy,
    "regex-brace-truncation": mutateRegexBrace,
    "duplicate-notification-property": mutateDuplicateProperty
}

const selected = process.env.TEST_KCM_WIRING_MUTANT
if (selected) {
    assert.ok(mutants[selected], `unknown mutant ${selected}`)
    validate(mutants[selected](configQml))
    assert.fail(`representative mutant ${selected} was accepted`)
}

validate(configQml)
for (const [name, mutate] of Object.entries(mutants))
    assert.throws(() => validate(mutate(configQml)), undefined,
        `representative mutant ${name} must be rejected by the normal validator`)

console.log(`All Settings test-celebration wiring tests passed (including ${Object.keys(mutants).length} mutation guards).`)
