#!/usr/bin/env node
/**
 * Structural wiring checks for the Settings test-celebration producer.
 *
 * This intentionally parses only the brace-balanced QML/JavaScript scopes
 * needed by the wiring contract; it is not a general QML parser.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const configQml = readFileSync(join(root, "contents/ui/configGeneral.qml"), "utf8")

// QML embeds JavaScript. This masker preserves every source position while
// hiding comments, strings and the regex literals used by these wiring scopes.
// Regex-vs-division is decided from the preceding significant token: a slash
// after a value/closing delimiter is division; at expression starts it is regex.
function codeMask(source) {
    const masked = source.split("")
    let state = "code"
    let quote = ""
    let escaped = false
    let regexClass = false
    let previousToken = "start"

    function blank(index) {
        if (source[index] !== "\n" && source[index] !== "\r") masked[index] = " "
    }

    function regexCanStart() {
        return previousToken !== "value" && previousToken !== "close"
    }

    for (let i = 0; i < source.length; ++i) {
        const current = source[i]
        const next = source[i + 1]

        if (state === "line-comment") {
            if (current === "\n") state = "code"
            else blank(i)
            continue
        }
        if (state === "block-comment") {
            blank(i)
            if (current === "*" && next === "/") {
                blank(i + 1)
                state = "code"
                ++i
            }
            continue
        }
        if (state === "string") {
            blank(i)
            if (escaped) escaped = false
            else if (current === "\\") escaped = true
            else if (current === quote) {
                state = "code"
                previousToken = "value"
            }
            continue
        }
        if (state === "regex") {
            blank(i)
            if (escaped) escaped = false
            else if (current === "\\") escaped = true
            else if (current === "[" && !regexClass) regexClass = true
            else if (current === "]" && regexClass) regexClass = false
            else if (current === "/" && !regexClass) {
                while (/[A-Za-z]/.test(source[i + 1] || "")) {
                    blank(i + 1)
                    ++i
                }
                state = "code"
                previousToken = "value"
            }
            continue
        }
        if (current === "/" && next === "/") {
            blank(i)
            blank(i + 1)
            state = "line-comment"
            ++i
            continue
        }
        if (current === "/" && next === "*") {
            blank(i)
            blank(i + 1)
            state = "block-comment"
            ++i
            continue
        }
        if (current === '"' || current === "'" || current === "`") {
            blank(i)
            quote = current
            escaped = false
            state = "string"
            continue
        }
        if (current === "/" && regexCanStart()) {
            blank(i)
            escaped = false
            regexClass = false
            state = "regex"
            continue
        }
        if (/\s/.test(current)) continue
        if (/[A-Za-z0-9_$]/.test(current)) {
            let end = i + 1
            while (/[A-Za-z0-9_$]/.test(source[end] || "")) ++end
            const token = source.slice(i, end)
            previousToken = /^(return|throw|case|delete|void|typeof|new|in|of|yield|await)$/.test(token)
                ? "operator" : "value"
            i = end - 1
            continue
        }
        if (current === ")" || current === "]" || current === "}") previousToken = "close"
        else if (current === ".") previousToken = "value"
        else previousToken = "operator"
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
    const declaration = new RegExp(`\\bfunction\\s+${name}\\s*\\(`).exec(codeMask(source))
    assert.ok(declaration, `missing ${name}()`)
    return bracedRangeAfter(source, declaration.index + declaration[0].length, `${name}()`)
}

function rootFunctionRange(source, name) {
    const masked = codeMask(source)
    const pattern = new RegExp(`\\bfunction\\s+${name}\\s*\\(`, "g")
    const candidates = []
    let match
    while ((match = pattern.exec(masked)) !== null) {
        let depth = 0
        for (let i = 0; i < match.index; ++i) {
            if (masked[i] === "{") ++depth
            else if (masked[i] === "}") --depth
        }
        if (depth !== 1) continue
        const parametersOpening = masked.indexOf("(", match.index)
        const parametersClosing = matchingDelimiter(source, parametersOpening, "(", ")")
        const body = bracedRangeAfter(source, parametersClosing + 1, `${name}()`)
        candidates.push({
            ...body,
            parameter: source.slice(parametersOpening + 1, parametersClosing).trim(),
            declarationStart: match.index
        })
        pattern.lastIndex = body.end
    }
    assert.equal(candidates.length, 1, `expected one root ${name}()`)
    return candidates[0]
}

function callRange(source, calleePattern, label) {
    const masked = codeMask(source)
    const pattern = new RegExp(`${calleePattern}\\s*\\(`, "g")
    const calls = []
    let match
    while ((match = pattern.exec(masked)) !== null) {
        const opening = masked.indexOf("(", match.index)
        const closing = matchingDelimiter(source, opening, "(", ")")
        calls.push({
            start: match.index,
            end: closing + 1,
            args: source.slice(opening + 1, closing)
        })
        pattern.lastIndex = closing + 1
    }
    assert.equal(calls.length, 1, `expected one ${label}`)
    return calls[0]
}

function splitTopLevel(source) {
    const masked = codeMask(source)
    const parts = []
    let start = 0
    let braces = 0
    let brackets = 0
    let parentheses = 0
    for (let i = 0; i <= masked.length; ++i) {
        const current = masked[i]
        if (current === "{") ++braces
        else if (current === "}") --braces
        else if (current === "[") ++brackets
        else if (current === "]") --brackets
        else if (current === "(") ++parentheses
        else if (current === ")") --parentheses
        if ((current === "," && braces === 0 && brackets === 0 && parentheses === 0)
                || i === masked.length) {
            parts.push(source.slice(start, i).trim())
            start = i + 1
        }
    }
    return parts
}

function objectProperties(expression, label) {
    const masked = codeMask(expression)
    const opening = skipWhitespace(masked, 0)
    assert.equal(masked[opening], "{", `${label} must be an object literal`)
    const closing = matchingDelimiter(expression, opening, "{", "}")
    assert.equal(masked.slice(closing + 1).trim(), "", `${label} must contain only its object literal`)
    const properties = new Map()
    for (const entry of splitTopLevel(expression.slice(opening + 1, closing))) {
        const entryMask = codeMask(entry)
        const property = /^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*:/.exec(entryMask)
        assert.ok(property, `${label} contains an unsupported property`)
        assert.equal(properties.has(property[1]), false, `${label} must not duplicate ${property[1]}`)
        properties.set(property[1], entry.slice(property[0].length).trim())
    }
    return properties
}

function literalEquals(expression, expected) {
    const trimmed = expression.trim()
    return trimmed === `"${expected}"` || trimmed === `'${expected}'`
}

function expressionGuaranteesName(expression, name) {
    const masked = codeMask(expression)
    const reference = new RegExp(`\\b${name}\\b`)
    let braces = 0
    let brackets = 0
    let parentheses = 0
    let question = -1
    for (let i = 0; i < masked.length; ++i) {
        if (masked[i] === "{") ++braces
        else if (masked[i] === "}") --braces
        else if (masked[i] === "[") ++brackets
        else if (masked[i] === "]") --brackets
        else if (masked[i] === "(") ++parentheses
        else if (masked[i] === ")") --parentheses
        else if (masked[i] === "?" && !braces && !brackets && !parentheses) question = i
        else if (masked[i] === ":" && question >= 0 && !braces && !brackets && !parentheses) {
            return reference.test(masked.slice(question + 1, i))
                && reference.test(masked.slice(i + 1))
        }
    }
    return reference.test(masked)
}

function topLevelVarInitializers(source) {
    const masked = codeMask(source)
    const declarations = []
    let braces = 0
    let brackets = 0
    let parentheses = 0
    for (let i = 0; i < masked.length; ++i) {
        if (masked[i] === "{") ++braces
        else if (masked[i] === "}") --braces
        else if (masked[i] === "[") ++brackets
        else if (masked[i] === "]") --brackets
        else if (masked[i] === "(") ++parentheses
        else if (masked[i] === ")") --parentheses
        if (braces || brackets || parentheses || !isWordAt(masked, i, "var")) continue
        const match = /^var\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=/.exec(masked.slice(i))
        if (match) declarations.push({ name: match[1], start: i, valueStart: i + match[0].length })
    }
    return declarations.map((declaration, index) => ({
        ...declaration,
        value: source.slice(
            declaration.valueStart,
            declarations[index + 1]?.start ?? source.length
        ).trim().replace(/;$/, "")
    }))
}

function propertyFunctionRange(source, propertyName) {
    const declaration = new RegExp(`\\b${propertyName}\\s*:\\s*function\\s*\\([^)]*\\)`).exec(codeMask(source))
    assert.ok(declaration, `missing ${propertyName} callback`)
    return bracedRangeAfter(source, declaration.index + declaration[0].length, `${propertyName} callback`)
}

function objectRanges(source, typeName) {
    const ranges = []
    const masked = codeMask(source)
    const pattern = new RegExp(`\\b${typeName.replaceAll(".", "\\.")}\\s*\\{`, "g")
    let match
    while ((match = pattern.exec(masked)) !== null) {
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
    const declaration = declarationPattern.exec(codeMask(source))
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

function executableMatch(source, pattern) {
    const flags = pattern.flags.indexOf("g") >= 0 ? pattern.flags : pattern.flags + "g"
    const scanner = new RegExp(pattern.source, flags)
    const masked = codeMask(source)
    let match
    while ((match = scanner.exec(source)) !== null) {
        const firstRawCodeOffset = match[0].search(/\S/)
        if (firstRawCodeOffset >= 0 && masked[match.index + firstRawCodeOffset] !== " ") return match
        if (match[0].length === 0) ++scanner.lastIndex
    }
    return null
}

function assertExecutableMatch(source, pattern, message) {
    const match = executableMatch(source, pattern)
    assert.ok(match, message)
    return match
}

function replaceRange(source, range, replacementBody) {
    return source.slice(0, range.bodyStart) + replacementBody + source.slice(range.bodyEnd)
}

function validateConfig(source) {
    assertExecutableMatch(
        source,
        /^import "js\/TestCelebrationRequests\.js" as TestCelebrationRequests$/m,
        "request module must be imported in executable QML"
    )

    const bridge = propertyBlockRange(
        source,
        /readonly property string testCelebrationBridgeScript\s*:/,
        "testCelebrationBridgeScript"
    )
    assertExecutableMatch(
        bridge.body,
        /Qt\.resolvedUrl\("\.\.\/scripts\/test-celebration-bridge\.sh"\)/,
        "bridge path must be passed to Qt.resolvedUrl"
    )
    assertExecutableMatch(bridge.body, /u\.indexOf\("file:\/\/"\)/, "bridge path must handle file URLs")

    const testButtons = objectRanges(source, "QQC2.Button").filter(range =>
        executableMatch(range.body, /text:\s*tr\("Send test celebration"\)/))
    assert.equal(testButtons.length, 1, "expected one test-celebration button")
    assertExecutableMatch(
        testButtons[0].body,
        /onClicked:\s*configPage\.sendTestCelebration\(\)/,
        "test button must execute sendTestCelebration()"
    )

    const producerRange = functionRange(source, "sendTestCelebration")
    const producer = producerRange.body
    const producerCode = codeMask(producer)
    const formatterCall = callRange(
        producer,
        "QuotaReset\\.formatNotification",
        "QuotaReset.formatNotification() call"
    )
    const formatterArgs = splitTopLevel(formatterCall.args)
    assert.equal(formatterArgs.length, 2, "formatter call must have exactly two arguments")
    const eventsMask = codeMask(formatterArgs[0])
    const eventsOpening = skipWhitespace(eventsMask, 0)
    assert.equal(eventsMask[eventsOpening], "[", "formatter events argument must be an array literal")
    const eventsClosing = matchingDelimiter(formatterArgs[0], eventsOpening, "[", "]")
    assert.equal(eventsMask.slice(eventsClosing + 1).trim(), "", "formatter events argument must contain only its array")
    const events = splitTopLevel(formatterArgs[0].slice(eventsOpening + 1, eventsClosing))
    assert.equal(events.length, 1, "formatter must receive exactly one event")
    const eventProperties = objectProperties(events[0], "formatter event")
    assert.ok(literalEquals(eventProperties.get("windowId") || "", "5h"),
        "formatter event must use the five-hour window id")
    assert.ok(literalEquals(eventProperties.get("windowLabel") || "", "5h"),
        "formatter event must use the five-hour label")
    assert.ok(literalEquals(eventProperties.get("kind") || "", "natural"),
        "formatter event must be natural")
    assert.match(producerCode, /TestCelebrationRequests\.createRequest\s*\(/)
    assert.match(producerCode, /TestCelebrationRequests\.serializeRequest\s*\(/)
    assert.match(producerCode, /Date\.now\s*\(\)/)
    assert.match(producerCode, /Math\.random\s*\(\)/)

    const attempts = topLevelTryStatements(producer)
    assert.equal(
        attempts.length,
        2,
        "notification and writer try/catch attempts must be sibling top-level statements"
    )
    const [notificationAttempt, writerAttempt] = attempts
    const notificationCode = codeMask(notificationAttempt.tryBody)
    const writerCode = codeMask(writerAttempt.tryBody)
    const notificationCall = callRange(
        notificationAttempt.tryBody,
        "testResetNotificationComponent\\.createObject",
        "notification attempt must create the notification in executable code"
    )
    const notificationArgs = splitTopLevel(notificationCall.args)
    assert.equal(notificationArgs.length, 2, "notification creation must have parent and properties")
    const notificationProperties = objectProperties(notificationArgs[1], "notification properties")
    const textExpression = notificationProperties.get("text") || ""
    const variables = topLevelVarInitializers(notificationAttempt.tryBody)
    const suffixes = variables.filter(variable =>
        literalEquals(variable.value, "Preview from Settings — no reset was logged."))
    assert.equal(suffixes.length, 1, "notification must declare the exact preview suffix once")
    const suffix = suffixes[0]
    assert.ok(suffix.start < notificationCall.start, "preview suffix must be declared before notification use")
    const directSuffixUse = new RegExp(`^\\s*(?:String\\s*\\(\\s*)?${suffix.name}(?:\\s*\\))?\\s*$`)
    let suffixUsed = directSuffixUse.test(codeMask(textExpression))
    if (!suffixUsed) {
        const textVariable = variables.find(variable =>
            variable.start < notificationCall.start
            && new RegExp(`^\\s*(?:String\\s*\\(\\s*)?${variable.name}(?:\\s*\\))?\\s*$`)
                .test(codeMask(textExpression)))
        suffixUsed = !!textVariable
            && expressionGuaranteesName(textVariable.value, suffix.name)
    }
    assert.ok(suffixUsed, "notification text must directly use the preview suffix")
    assert.match(notificationCode, /\.sendEvent\s*\(\)/, "notification attempt must execute sendEvent()")
    assert.doesNotMatch(notificationCode, /testCelebrationWriter\.connectSource/)
    assert.match(codeMask(notificationAttempt.catchBody), /console\.log/)
    assert.match(writerCode, /TestCelebrationRequests\.createRequest\s*\(/)
    assert.match(writerCode, /testCelebrationWriter\.connectSource\s*\(/)
    assert.match(codeMask(writerAttempt.catchBody), /console\.log/)

    const commandDeclaration = /\bvar\s+command\s*=/.exec(writerCode)
    assert.ok(commandDeclaration, "writer attempt must construct command")
    const connectCall = /testCelebrationWriter\.connectSource\s*\(([^)]*)\)/.exec(
        writerCode.slice(commandDeclaration.index + commandDeclaration[0].length)
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

    for (const forbiddenCall of [
        "handleQuotaResets",
        "buildLogCommand",
        "logQuotaResetEnvelopes"
    ]) {
        assert.equal(
            new RegExp(`\\b${forbiddenCall}\\s*\\(`).test(producerCode),
            false,
            `sendTestCelebration() must not reference ${forbiddenCall}`
        )
    }
    assert.equal(
        executableMatch(producer, /["']log-reset\.sh["']/),
        null,
        "sendTestCelebration() must not reference log-reset.sh"
    )

    const compatibility = functionRange(source, "sendTestQuotaResetNotification")
    const normalizedCompatibility = codeMask(compatibility.body).replace(/\s+/g, "").replace(/;$/, "")
    assert.equal(
        normalizedCompatibility,
        "sendTestCelebration()",
        "compatibility wrapper must contain only sendTestCelebration()"
    )

    const writerSource = objectRangeById(source, "Plasma5Support.DataSource", "testCelebrationWriter")
    assertExecutableMatch(writerSource.body, /engine:\s*"executable"/, "writer must use the executable engine")
    const completion = propertyFunctionRange(writerSource.body, "onNewData")
    assertExecutableMatch(completion.body, /data\["exit code"\]/, "writer callback must read exit code in its own block")
    assertExecutableMatch(completion.body, /data\["exit status"\]/, "writer callback must read exit status in its own block")
    assertExecutableMatch(completion.body, /data\["stderr"\]/, "writer callback must read stderr in its own block")
    assertExecutableMatch(completion.body, /data\["error"\]/, "writer callback must read executable error in its own block")
    assertExecutableMatch(completion.body, /data\["errorString"\]/, "writer callback must read executable errorString in its own block")

    const completionCode = codeMask(completion.body)
    const disconnect = /disconnectSource\s*\(sourceName\)/.exec(completionCode)
    assert.ok(disconnect, "writer completion must disconnect its source")
    const outcomeBranches = topLevelIfStatements(completion.body)
    assert.equal(outcomeBranches.length, 1, "writer completion must have one scoped outcome branch")
    const outcome = outcomeBranches[0]
    assert.ok(disconnect.index < outcome.start, "writer completion must disconnect before outcome reporting")
    const outcomeConditionCode = normalizeWhitespace(codeMask(outcome.condition))
    const outcomeBodyCode = codeMask(outcome.body)
    assert.match(
        outcomeConditionCode,
        /exitCode !== undefined && Number\(exitCode\) !== 0/,
        "writer failure condition must include non-zero exit code"
    )
    assert.match(
        outcomeConditionCode,
        /exitStatus !== undefined && Number\(exitStatus\) !== 0/,
        "writer failure condition must include non-zero exit status"
    )
    assert.match(outcomeConditionCode, /\|\|\s*error/, "writer failure condition must include executable error")
    assert.match(outcomeBodyCode, /console\.log/, "writer failures must be reported conditionally")
    assert.match(outcomeBodyCode, /stderr/, "writer failure report must include stderr")
    assert.match(outcomeBodyCode, /error/, "writer failure report must include executable error text")
    assert.equal(
        (completionCode.match(/console\.log/g) || []).length,
        (outcomeBodyCode.match(/console\.log/g) || []).length,
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

function commentStringDecoyMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const operationalNotification = /var n = testResetNotificationComponent\.createObject\([\s\S]*?\n            if \(n\)\n                n\.sendEvent\(\)/
    const mutatedBody = producerRange.body.replace(
        operationalNotification,
        'var notificationDecoy = "testResetNotificationComponent.createObject("\n'
            + "            // .sendEvent()"
    )
    assert.notEqual(mutatedBody, producerRange.body, "comment/string decoy mutation must apply")
    return replaceRange(source, producerRange, mutatedBody)
}

function regexBraceTruncationMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const mutatedBody = producerRange.body
        + "\n        var braceMatcher = /[}]/\n"
        + "        buildLogCommand()\n    "
    return replaceRange(source, producerRange, mutatedBody)
}

function unsafeShellQuoteDecoyMutation(source) {
    const shellQuote = rootFunctionRange(source, "shellQuote")
    return replaceRange(source, shellQuote, String.raw`
        var expectedText = "return \"'\" + String(path).replace(/'/g, \"'\\\\''\") + \"'\""
        // return "'" + String(path).replace(/'/g, "'\\''") + "'"
        return "'" + String(path) + "'"
    `)
}

function nestedShellQuoteDecoyMutation(source) {
    const shellQuote = rootFunctionRange(source, "shellQuote")
    return replaceRange(source, shellQuote, String.raw`
        function shellQuote(path) {
            return "'" + String(path).replace(/'/g, "'\\''") + "'"
        }
        return "'" + String(path) + "'"
    `)
}

function detachedNaturalFixtureMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const fixture = `{
                    windowId: "5h",
                    windowLabel: "5h",
                    kind: "natural",
                    unexpected: false,
                    previousUsagePercent: 87,
                    expectedResetAtMs: 0
                }`
    const wrongFixture = fixture
        .replace('windowId: "5h"', 'windowId: "wrong_window"')
        .replace('windowLabel: "5h"', 'windowLabel: "wrong label"')
        .replace('kind: "natural"', 'kind: "unexpected"')
    const mutatedBody = producerRange.body.replace(
        fixture,
        wrongFixture
    )
    assert.notEqual(mutatedBody, producerRange.body, "detached fixture mutation must apply")
    return replaceRange(source, producerRange, "\n        var detachedNaturalFixture = " + fixture + mutatedBody)
}

function duplicateFixturePropertiesMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const mutatedBody = producerRange.body.replace(
        'kind: "natural",',
        'kind: "natural",\n                    windowId: "wrong_window",\n                    windowLabel: "wrong label",\n                    kind: "unexpected",'
    )
    assert.notEqual(mutatedBody, producerRange.body, "duplicate fixture mutation must apply")
    return replaceRange(source, producerRange, mutatedBody)
}

function detachedPreviewSuffixMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const mutatedBody = producerRange.body.replace(
        "text: String(text)",
        'text: "Detached notification text"'
    )
    assert.notEqual(mutatedBody, producerRange.body, "detached suffix mutation must apply")
    return replaceRange(source, producerRange, mutatedBody)
}

function deadPreviewSuffixMutation(source) {
    const producerRange = functionRange(source, "sendTestCelebration")
    const mutatedBody = producerRange.body.replace(
        "text: String(text)",
        'text: String(false ? previewSuffix : "Wrong")'
    )
    assert.notEqual(mutatedBody, producerRange.body, "dead suffix mutation must apply")
    return replaceRange(source, producerRange, mutatedBody)
}

function validateShellQuote(source) {
    const shellQuote = rootFunctionRange(source, "shellQuote")
    assert.equal(shellQuote.parameter, "path", "root shellQuote() must take exactly path")
    const expectedBody = String.raw`return "'" + String(path).replace(/'/g, "'\\''") + "'"`
    assert.equal(
        normalizeWhitespace(shellQuote.body),
        expectedBody,
        "root shellQuote() must exactly implement POSIX single-quote escaping"
    )
}

function validateSource(source) {
    validateConfig(source)
    validateShellQuote(source)
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
    },
    "comment-string-decoy": {
        apply: commentStringDecoyMutation,
        rejection: /notification attempt must create the notification in executable code/
    },
    "regex-brace-truncation": {
        apply: regexBraceTruncationMutation,
        rejection: /sendTestCelebration\(\) must not reference buildLogCommand/
    },
    "unsafe-shell-quote-decoy": {
        apply: unsafeShellQuoteDecoyMutation,
        rejection: /root shellQuote\(\) must exactly implement POSIX single-quote escaping/
    },
    "nested-shell-quote-decoy": {
        apply: nestedShellQuoteDecoyMutation,
        rejection: /root shellQuote\(\) must exactly implement POSIX single-quote escaping/
    },
    "detached-natural-fixture": {
        apply: detachedNaturalFixtureMutation,
        rejection: /formatter event must use the five-hour window id/
    },
    "duplicate-fixture-properties": {
        apply: duplicateFixturePropertiesMutation,
        rejection: /formatter event must not duplicate windowId/
    },
    "detached-preview-suffix": {
        apply: detachedPreviewSuffixMutation,
        rejection: /notification text must directly use the preview suffix/
    },
    "dead-preview-suffix": {
        apply: deadPreviewSuffixMutation,
        rejection: /notification text must directly use the preview suffix/
    }
}

const selectedMutation = process.env.TEST_KCM_WIRING_MUTANT
if (selectedMutation) {
    assert.ok(mutations[selectedMutation], `unknown TEST_KCM_WIRING_MUTANT=${selectedMutation}`)
    validateSource(mutations[selectedMutation].apply(configQml))
    assert.fail(`representative mutant ${selectedMutation} was accepted`)
}

validateSource(configQml)

for (const [name, mutant] of Object.entries(mutations)) {
    assert.throws(
        () => validateSource(mutant.apply(configQml)),
        mutant.rejection,
        `representative mutant ${name} must be rejected by the same assertions`
    )
}

console.log(`All Settings test-celebration wiring tests passed (including ${Object.keys(mutations).length} mutation guards).`)
