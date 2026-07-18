#!/usr/bin/env node
/**
 * Structural wiring checks for the Settings test-celebration producer.
 *
 * This intentionally parses only the brace-balanced QML/JavaScript scopes
 * needed by the wiring contract; it is not a general QML parser.
 */
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const configQml = readFileSync(join(root, "contents/ui/configGeneral.qml"), "utf8")
const requestsJs = readFileSync(join(root, "contents/ui/js/TestCelebrationRequests.js"), "utf8")

function codeMask(source) {
    const masked = source.split("")
    let quote = ""
    let escaped = false
    let lineComment = false
    let blockComment = false

    for (let i = 0; i < source.length; ++i) {
        const current = source[i]
        const next = source[i + 1]

        if (lineComment) {
            if (current === "\n") lineComment = false
            else masked[i] = " "
            continue
        }
        if (blockComment) {
            masked[i] = " "
            if (current === "*" && next === "/") {
                masked[i + 1] = " "
                blockComment = false
                ++i
            }
            continue
        }
        if (quote) {
            masked[i] = " "
            if (escaped) escaped = false
            else if (current === "\\") escaped = true
            else if (current === quote) quote = ""
            continue
        }
        if (current === "/" && next === "/") {
            masked[i] = masked[i + 1] = " "
            lineComment = true
            ++i
            continue
        }
        if (current === "/" && next === "*") {
            masked[i] = masked[i + 1] = " "
            blockComment = true
            ++i
            continue
        }
        if (current === '"' || current === "'" || current === "`") {
            masked[i] = " "
            quote = current
        }
    }
    return masked.join("")
}

function matchingDelimiter(source, openingIndex, opening, closing) {
    const masked = codeMask(source)
    assert.equal(masked[openingIndex], opening, `expected ${opening} at ${openingIndex}`)
    let depth = 0
    for (let i = openingIndex; i < masked.length; ++i) {
        if (masked[i] === opening) ++depth
        else if (masked[i] === closing && --depth === 0) return i
    }
    assert.fail(`unterminated ${opening}${closing} scope`)
}

function bracedRangeAfter(source, startIndex, label) {
    const opening = codeMask(source).indexOf("{", startIndex)
    assert.notEqual(opening, -1, `missing body for ${label}`)
    const closing = matchingDelimiter(source, opening, "{", "}")
    return {
        start: opening,
        end: closing + 1,
        bodyStart: opening + 1,
        bodyEnd: closing,
        body: source.slice(opening + 1, closing),
        full: source.slice(opening, closing + 1)
    }
}

function functionRange(source, name) {
    const declaration = new RegExp(`\\bfunction\\s+${name}\\s*\\(`).exec(source)
    assert.ok(declaration, `missing ${name}()`)
    return bracedRangeAfter(source, declaration.index + declaration[0].length, `${name}()`)
}

function propertyFunctionRange(source, propertyName) {
    const declaration = new RegExp(`\\b${propertyName}\\s*:\\s*function\\s*\\([^)]*\\)`).exec(source)
    assert.ok(declaration, `missing ${propertyName} callback`)
    return bracedRangeAfter(source, declaration.index + declaration[0].length, `${propertyName} callback`)
}

function objectRanges(source, typeName) {
    const ranges = []
    const pattern = new RegExp(`\\b${typeName.replaceAll(".", "\\.")}\\s*\\{`, "g")
    let match
    while ((match = pattern.exec(source)) !== null) {
        const range = bracedRangeAfter(source, match.index, typeName)
        ranges.push({ ...range, declarationStart: match.index })
        pattern.lastIndex = range.end
    }
    return ranges
}

function objectRangeById(source, typeName, id) {
    const candidates = objectRanges(source, typeName).filter(range =>
        new RegExp(`\\bid\\s*:\\s*${id}\\b`).test(codeMask(range.body)))
    assert.equal(candidates.length, 1, `expected one ${typeName} with id ${id}`)
    return candidates[0]
}

function propertyBlockRange(source, declarationPattern, label) {
    const declaration = declarationPattern.exec(source)
    assert.ok(declaration, `missing ${label}`)
    return bracedRangeAfter(source, declaration.index + declaration[0].length, label)
}

function isWordAt(masked, index, word) {
    if (masked.slice(index, index + word.length) !== word) return false
    const before = masked[index - 1] || ""
    const after = masked[index + word.length] || ""
    return !/[A-Za-z0-9_$]/.test(before) && !/[A-Za-z0-9_$]/.test(after)
}

function skipWhitespace(masked, index) {
    while (index < masked.length && /\s/.test(masked[index])) ++index
    return index
}

function topLevelTryStatements(source) {
    const masked = codeMask(source)
    const statements = []
    let braceDepth = 0

    for (let i = 0; i < masked.length; ++i) {
        if (masked[i] === "{") {
            ++braceDepth
            continue
        }
        if (masked[i] === "}") {
            --braceDepth
            continue
        }
        if (braceDepth !== 0 || !isWordAt(masked, i, "try")) continue

        const tryOpening = skipWhitespace(masked, i + 3)
        assert.equal(masked[tryOpening], "{", "top-level try must have a block")
        const tryClosing = matchingDelimiter(source, tryOpening, "{", "}")
        const catchIndex = skipWhitespace(masked, tryClosing + 1)
        assert.ok(isWordAt(masked, catchIndex, "catch"), "top-level try must have a catch")
        const catchOpening = masked.indexOf("{", catchIndex + 5)
        assert.notEqual(catchOpening, -1, "catch must have a block")
        const catchClosing = matchingDelimiter(source, catchOpening, "{", "}")
        statements.push({
            start: i,
            end: catchClosing + 1,
            tryBody: source.slice(tryOpening + 1, tryClosing),
            catchBody: source.slice(catchOpening + 1, catchClosing),
            catchClosing,
            full: source.slice(i, catchClosing + 1)
        })
        i = catchClosing
    }
    return statements
}

function topLevelIfStatements(source) {
    const masked = codeMask(source)
    const statements = []
    let braceDepth = 0

    for (let i = 0; i < masked.length; ++i) {
        if (masked[i] === "{") {
            ++braceDepth
            continue
        }
        if (masked[i] === "}") {
            --braceDepth
            continue
        }
        if (braceDepth !== 0 || !isWordAt(masked, i, "if")) continue

        const conditionOpening = skipWhitespace(masked, i + 2)
        assert.equal(masked[conditionOpening], "(", "top-level if must have a condition")
        const conditionClosing = matchingDelimiter(source, conditionOpening, "(", ")")
        const bodyOpening = skipWhitespace(masked, conditionClosing + 1)
        assert.equal(masked[bodyOpening], "{", "top-level if must have a block")
        const bodyClosing = matchingDelimiter(source, bodyOpening, "{", "}")
        statements.push({
            start: i,
            end: bodyClosing + 1,
            condition: source.slice(conditionOpening + 1, conditionClosing),
            body: source.slice(bodyOpening + 1, bodyClosing)
        })
        i = bodyClosing
    }
    return statements
}

function normalizeWhitespace(source) {
    return source.replace(/\s+/g, " ").trim()
}

function replaceRange(source, range, replacementBody) {
    return source.slice(0, range.bodyStart) + replacementBody + source.slice(range.bodyEnd)
}

function validateConfig(source) {
    assert.match(source, /import "js\/TestCelebrationRequests\.js" as TestCelebrationRequests/)

    const bridge = propertyBlockRange(
        source,
        /readonly property string testCelebrationBridgeScript\s*:/,
        "testCelebrationBridgeScript"
    )
    assert.match(bridge.body, /Qt\.resolvedUrl\("\.\.\/scripts\/test-celebration-bridge\.sh"\)/)
    assert.match(bridge.body, /file:\/\//)

    const testButtons = objectRanges(source, "QQC2.Button").filter(range =>
        /text:\s*tr\("Send test celebration"\)/.test(range.body))
    assert.equal(testButtons.length, 1, "expected one test-celebration button")
    assert.match(testButtons[0].body, /onClicked:\s*configPage\.sendTestCelebration\(\)/)

    const producerRange = functionRange(source, "sendTestCelebration")
    const producer = producerRange.body
    assert.match(producer, /QuotaReset\.formatNotification\s*\(/)
    assert.match(producer, /windowId:\s*"5h"/)
    assert.match(producer, /windowLabel:\s*"5h"/)
    assert.match(producer, /kind:\s*"natural"/)
    assert.match(producer, /Preview from Settings — no reset was logged\./)
    assert.match(producer, /TestCelebrationRequests\.createRequest\s*\(/)
    assert.match(producer, /TestCelebrationRequests\.serializeRequest\s*\(/)
    assert.match(producer, /Date\.now\s*\(\)/)
    assert.match(producer, /Math\.random\s*\(\)/)

    const attempts = topLevelTryStatements(producer)
    assert.equal(
        attempts.length,
        2,
        "notification and writer try/catch attempts must be sibling top-level statements"
    )
    const [notificationAttempt, writerAttempt] = attempts
    assert.match(notificationAttempt.tryBody, /testResetNotificationComponent\.createObject\s*\(/)
    assert.match(notificationAttempt.tryBody, /\.sendEvent\s*\(\)/)
    assert.doesNotMatch(notificationAttempt.tryBody, /testCelebrationWriter\.connectSource/)
    assert.match(notificationAttempt.catchBody, /console\.log/)
    assert.match(writerAttempt.tryBody, /TestCelebrationRequests\.createRequest\s*\(/)
    assert.match(writerAttempt.tryBody, /testCelebrationWriter\.connectSource\s*\(/)
    assert.match(writerAttempt.catchBody, /console\.log/)

    const commandDeclaration = /\bvar\s+command\s*=/.exec(writerAttempt.tryBody)
    assert.ok(commandDeclaration, "writer attempt must construct command")
    const connectCall = /testCelebrationWriter\.connectSource\s*\(([^)]*)\)/.exec(
        writerAttempt.tryBody.slice(commandDeclaration.index + commandDeclaration[0].length)
    )
    assert.ok(connectCall, "writer attempt must connect the constructed command")
    const commandExpression = writerAttempt.tryBody
        .slice(commandDeclaration.index + commandDeclaration[0].length)
        .slice(0, connectCall.index)
        .trim()
        .replace(/;$/, "")
    const expectedCommandExpression = `"printf %s " + shellQuote(payload)
        + " | bash " + shellQuote(testCelebrationBridgeScript) + " write"`
    assert.equal(
        normalizeWhitespace(commandExpression),
        normalizeWhitespace(expectedCommandExpression),
        "connected command must quote the payload and resolved bridge path as one safe pipeline"
    )
    assert.equal(connectCall[1].trim(), "command", "connectSource must receive the safely built command")

    for (const forbidden of [
        "handleQuotaResets",
        "buildLogCommand",
        "logQuotaResetEnvelopes",
        "log-reset.sh"
    ]) {
        assert.equal(producer.includes(forbidden), false, `sendTestCelebration() must not reference ${forbidden}`)
    }

    const compatibility = functionRange(source, "sendTestQuotaResetNotification")
    const normalizedCompatibility = compatibility.body.replace(/\s+/g, "").replace(/;$/, "")
    assert.equal(
        normalizedCompatibility,
        "sendTestCelebration()",
        "compatibility wrapper must contain only sendTestCelebration()"
    )

    const writerSource = objectRangeById(source, "Plasma5Support.DataSource", "testCelebrationWriter")
    assert.match(writerSource.body, /engine:\s*"executable"/)
    const completion = propertyFunctionRange(writerSource.body, "onNewData")
    assert.match(completion.body, /data\["exit code"\]/, "writer callback must read exit code in its own block")
    assert.match(completion.body, /data\["exit status"\]/, "writer callback must read exit status in its own block")
    assert.match(completion.body, /data\["stderr"\]/, "writer callback must read stderr in its own block")
    assert.match(completion.body, /data\["error"\]/, "writer callback must read executable error in its own block")
    assert.match(completion.body, /data\["errorString"\]/, "writer callback must read executable errorString in its own block")

    const disconnect = /disconnectSource\s*\(sourceName\)/.exec(completion.body)
    assert.ok(disconnect, "writer completion must disconnect its source")
    const outcomeBranches = topLevelIfStatements(completion.body)
    assert.equal(outcomeBranches.length, 1, "writer completion must have one scoped outcome branch")
    const outcome = outcomeBranches[0]
    assert.ok(disconnect.index < outcome.start, "writer completion must disconnect before outcome reporting")
    assert.match(
        normalizeWhitespace(outcome.condition),
        /exitCode !== undefined && Number\(exitCode\) !== 0/,
        "writer failure condition must include non-zero exit code"
    )
    assert.match(
        normalizeWhitespace(outcome.condition),
        /exitStatus !== undefined && Number\(exitStatus\) !== 0/,
        "writer failure condition must include non-zero exit status"
    )
    assert.match(outcome.condition, /\|\|\s*error/, "writer failure condition must include executable error")
    assert.match(outcome.body, /console\.log/, "writer failures must be reported conditionally")
    assert.match(outcome.body, /stderr/, "writer failure report must include stderr")
    assert.match(outcome.body, /error/, "writer failure report must include executable error text")
    assert.equal(
        (completion.body.match(/console\.log/g) || []).length,
        (outcome.body.match(/console\.log/g) || []).length,
        "writer logging must remain inside the failure condition"
    )
}

function nestedWriterMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const attempts = topLevelTryStatements(producerRange.body)
    assert.equal(attempts.length, 2, "nested-writer mutation needs two original attempts")
    const [notificationAttempt, writerAttempt] = attempts
    const mutatedBody = producerRange.body.slice(0, notificationAttempt.catchClosing)
        + "\n        " + writerAttempt.full
        + producerRange.body.slice(notificationAttempt.catchClosing, writerAttempt.start)
        + producerRange.body.slice(writerAttempt.end)
    return replaceRange(source, producerRange, mutatedBody)
}

function disconnectedCommandMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const mutatedBody = producerRange.body.replace(
        "testCelebrationWriter.connectSource(command)",
        "testCelebrationWriter.connectSource(payload)"
    )
    assert.notEqual(mutatedBody, producerRange.body, "command mutation must apply")
    return replaceRange(source, producerRange, mutatedBody)
}

function dataSourceBleedMutation(source) {
    const withoutWriterId = source.replace(
        "id: testCelebrationWriter",
        "id: decoyCelebrationWriter"
    )
    const mutated = withoutWriterId.replace("id: discoverSource", "id: testCelebrationWriter")
    assert.notEqual(mutated, source, "DataSource mutation must apply")
    return mutated
}

function sideEffectWrapperMutation(source) {
    const wrapperRange = functionRange(source, "sendTestQuotaResetNotification")
    return replaceRange(source, wrapperRange, "\n        sendTestCelebration()\n        buildLogCommand()\n    ")
}

const mutations = {
    "nested-writer": {
        apply: nestedWriterMutation,
        rejection: /sibling top-level statements/
    },
    "disconnected-command": {
        apply: disconnectedCommandMutation,
        rejection: /connectSource must receive the safely built command/
    },
    "datasource-bleed": {
        apply: dataSourceBleedMutation,
        rejection: /writer callback must read exit status in its own block/
    },
    "wrapper-side-effect": {
        apply: sideEffectWrapperMutation,
        rejection: /compatibility wrapper must contain only sendTestCelebration/
    }
}

const selectedMutation = process.env.TEST_KCM_WIRING_MUTANT
if (selectedMutation) {
    assert.ok(mutations[selectedMutation], `unknown TEST_KCM_WIRING_MUTANT=${selectedMutation}`)
    validateConfig(mutations[selectedMutation].apply(configQml))
    assert.fail(`representative mutant ${selectedMutation} was accepted`)
}

validateConfig(configQml)

for (const [name, mutant] of Object.entries(mutations)) {
    assert.throws(
        () => validateConfig(mutant.apply(configQml)),
        mutant.rejection,
        `representative mutant ${name} must be rejected by the same assertions`
    )
}

assert.match(configQml, /function shellQuote\s*\([^)]+\)\s*\{[^}]*replace\(\/'\/g, "'\\\\''"\)/)
const shellQuote = value => "'" + String(value).replace(/'/g, "'\\''") + "'"
const requestModule = {}
vm.runInNewContext(requestsJs.replace(/^\.pragma library\s*$/m, ""), requestModule)
const arbitraryRequest = requestModule.createRequest(123456789, function() {
    return "single'quote newline\n unicode— shell;$()"
})
const arbitraryPayload = requestModule.serializeRequest(arbitraryRequest)
const roundTrip = execFileSync("bash", ["-c", "printf %s " + shellQuote(arbitraryPayload)], {
    encoding: "utf8"
})
assert.equal(roundTrip, arbitraryPayload, "shell quoting must preserve arbitrary serialized JSON")

console.log("All Settings test-celebration wiring tests passed (including four mutation guards).")
