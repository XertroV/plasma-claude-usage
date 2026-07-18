#!/usr/bin/env node
/**
 * Structural contract for the Settings test-celebration runtime consumer.
 *
 * This test reads source only. It never executes bridge output as shell syntax.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")

function read(relativePath) {
    return readFileSync(join(root, relativePath), "utf8")
}

// Preserve offsets while hiding strings and comments from structural searches.
function codeMask(source) {
    let masked = ""
    let state = "code"
    let quote = ""
    let escaped = false
    let regexClass = false

    for (let index = 0; index < source.length; index++) {
        const character = source[index]
        const next = source[index + 1]

        if (state === "lineComment") {
            if (character === "\n") {
                state = "code"
                masked += "\n"
            } else masked += " "
            continue
        }
        if (state === "blockComment") {
            if (character === "*" && next === "/") {
                masked += "  "
                index++
                state = "code"
            } else masked += character === "\n" ? "\n" : " "
            continue
        }
        if (state === "string") {
            masked += character === "\n" ? "\n" : " "
            if (escaped) escaped = false
            else if (character === "\\") escaped = true
            else if (character === quote) state = "code"
            continue
        }
        if (state === "regex") {
            masked += character === "\n" ? "\n" : " "
            if (escaped) escaped = false
            else if (character === "\\") escaped = true
            else if (character === "[") regexClass = true
            else if (character === "]") regexClass = false
            else if (character === "/" && !regexClass) state = "code"
            continue
        }
        if (character === "/" && next === "/") {
            masked += "  "
            index++
            state = "lineComment"
        } else if (character === "/" && next === "*") {
            masked += "  "
            index++
            state = "blockComment"
        } else if (character === "\"" || character === "'") {
            masked += " "
            state = "string"
            quote = character
            escaped = false
        } else if (character === "/") {
            let previous = index - 1
            while (previous >= 0 && /\s/.test(source[previous])) previous--
            if (previous < 0 || /[([{:,;=!?&|]/.test(source[previous])) {
                masked += " "
                state = "regex"
                escaped = false
                regexClass = false
            } else masked += character
        } else masked += character
    }
    return masked
}

function matchingBrace(masked, opening, description) {
    let depth = 0
    for (let index = opening; index < masked.length; index++) {
        if (masked[index] === "{") depth++
        else if (masked[index] === "}" && --depth === 0) return index
    }
    assert.fail(`unterminated block for ${description}`)
}

function blockAt(source, marker) {
    const masked = codeMask(source)
    const start = masked.indexOf(marker)
    assert.notEqual(start, -1, `missing ${marker}`)
    const opening = masked.indexOf("{", start + marker.length)
    assert.notEqual(opening, -1, `missing block for ${marker}`)
    const closing = matchingBrace(masked, opening, marker)
    return source.slice(start, closing + 1)
}

function hasTopLevelId(masked, opening, closing, id) {
    const escapedId = id.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    const idPattern = new RegExp(`\\bid\\s*:\\s*${escapedId}\\b`, "g")
    idPattern.lastIndex = opening + 1
    let depth = 1
    let cursor = opening + 1
    let match

    while ((match = idPattern.exec(masked)) !== null && match.index < closing) {
        for (; cursor < match.index; cursor++) {
            if (masked[cursor] === "{") depth++
            else if (masked[cursor] === "}") depth--
        }
        if (depth === 1) return true
    }
    return false
}

function componentBlock(source, type, id) {
    const masked = codeMask(source)
    const escapedType = type.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    const componentPattern = new RegExp(`\\b${escapedType}\\s*\\{`, "g")
    const matches = []
    let match

    while ((match = componentPattern.exec(masked)) !== null) {
        const opening = masked.indexOf("{", match.index)
        const closing = matchingBrace(masked, opening, `${type} candidate`)
        if (hasTopLevelId(masked, opening, closing, id))
            matches.push(source.slice(match.index, closing + 1))
        // Keep traversing lexical starts within this component. Skipping to its
        // closing brace would hide nested Timer/DataSource candidates in root Items.
        componentPattern.lastIndex = opening + 1
    }

    assert.equal(matches.length, 1,
        `expected exactly one ${type} component with id ${id}, found ${matches.length}`)
    return matches[0]
}

function functionBlock(source, name) {
    return blockAt(source, `function ${name}(`)
}

function position(block, text, description) {
    const found = block.indexOf(text)
    assert.notEqual(found, -1, `missing ${description}`)
    return found
}

function validate(controller, main, cardsView) {
    // One source of truth feeds both the selector and the two mounted card views.
    assert.match(controller, /import "js\/TestCelebrationRequests\.js" as TestCelebrationRequests/)
    assert.match(controller, /readonly property int compactCardLimit:\s*8\b/)
    assert.match(controller, /readonly property int fullCardLimit:\s*12\b/)
    const compactCards = componentBlock(main, "CardsView", "cardsCompact")
    const fullCards = componentBlock(main, "CardsView", "cardsFull")
    assert.match(codeMask(compactCards), /\bmaxCards:\s*root\.usageController\.compactCardLimit\b/)
    assert.match(codeMask(fullCards), /\bmaxCards:\s*root\.usageController\.fullCardLimit\b/)
    assert.match(cardsView, /visible:\s*index\s*<\s*cardsRoot\.maxCards\b/)
    assert.match(cardsView, /cardsRoot\.cards\.length\s*>\s*cardsRoot\.maxCards\b/)

    // Polling is periodic and guard-first before the executable source is connected.
    const poll = functionBlock(controller, "pollTestCelebration")
    assert.match(controller, /property bool testCelebrationPollBusy:\s*false\b/)
    const guardAt = position(poll, "if (testCelebrationPollBusy) return", "poll busy guard")
    const setBusyAt = position(poll, "testCelebrationPollBusy = true", "poll busy assignment")
    const commandAt = position(poll, "var command =", "bridge command construction")
    const connectAt = position(poll, "testCelebrationSource.connectSource(command)", "source connection")
    assert.ok(guardAt < setBusyAt && setBusyAt < commandAt && commandAt < connectAt,
        "poll must guard, set busy, construct command, then connect in that order")
    assert.match(poll, /bash\s+"\s*\+\s*QuotaReset\.shellQuote\(testCelebrationBridgeScript\)\s*\+\s*" take"/)
    assert.match(poll, /catch\s*\([^)]*\)[\s\S]*testCelebrationPollBusy\s*=\s*false/)

    const pollTimer = componentBlock(controller, "Timer", "testCelebrationPollTimer")
    const interval = Number(pollTimer.match(/interval:\s*(\d+)/)?.[1])
    assert.equal(interval, 900)
    assert.ok(interval >= 750)
    assert.match(pollTimer, /running:\s*true/)
    assert.match(pollTimer, /repeat:\s*true/)
    assert.match(pollTimer, /onTriggered:\s*controller\.pollTestCelebration\(\)/)

    // The installed-relative bridge path is resolved, and the dedicated executable
    // completion always releases its source and busy guard before inspecting output.
    assert.match(controller, /Qt\.resolvedUrl\("\.\.\/scripts\/test-celebration-bridge\.sh"\)/)
    const source = componentBlock(controller, "Plasma5Support.DataSource", "testCelebrationSource")
    assert.match(source, /engine:\s*"executable"/)
    assert.match(source, /connectedSources:\s*\[\]/)
    const completion = blockAt(source, "onNewData:")
    const disconnectAt = position(completion, "disconnectSource(sourceName)", "source disconnect")
    const releaseAt = position(completion, "controller.testCelebrationPollBusy = false", "busy release")
    const emptyAt = position(completion, 'if (String(stdout).trim() === "") return', "exact empty-output guard")
    const consumeAt = position(completion, "controller.consumeTestCelebration(String(stdout))", "request consumption")
    assert.ok(disconnectAt < releaseAt && releaseAt < emptyAt && emptyAt < consumeAt,
        "completion must disconnect, release busy, ignore exactly empty output, then consume")

    // Non-empty data crosses only the pure request consumer. Replay state is always
    // replaced; accepted requests randomly select an eligible public card and invoke
    // the existing generation seam directly. Empty eligibility is an acknowledged no-op.
    const consume = functionBlock(controller, "consumeTestCelebration")
    assert.match(consume, /TestCelebrationRequests\.consume\(\s*raw,\s*testCelebrationReplayState,\s*Date\.now\(\)\)/)
    assert.match(consume, /TestCelebrationRequests\.selectProfileId\(\s*publicProfileList,\s*\{[\s\S]*compactMaxCards:\s*compactCardLimit[\s\S]*fullMaxCards:\s*fullCardLimit[\s\S]*\},\s*(?:Math\.random|function\s*\()/)
    const pureConsumeAt = position(consume, "TestCelebrationRequests.consume(", "pure consumer call")
    const replayAt = position(consume, "testCelebrationReplayState = result.state", "replay-state update")
    const acceptedAt = position(consume, "if (!result.accepted) return", "accepted guard")
    const selectAt = position(consume, "TestCelebrationRequests.selectProfileId(", "eligible random selection")
    const noIdAt = position(consume, "if (!selectedId) return", "empty-selection guard")
    const triggerCalls = [...codeMask(consume).matchAll(/\btriggerCardCelebration\s*\([^)]*\)/g)]
    assert.equal(triggerCalls.length, 1,
        "consume must contain exactly one direct celebration trigger")
    assert.equal(triggerCalls[0][0], "triggerCardCelebration(selectedId)",
        "consume trigger must use the eligible selected id")
    const triggerAt = triggerCalls[0].index
    assert.ok(pureConsumeAt < replayAt && replayAt < acceptedAt && acceptedAt < selectAt
              && selectAt < noIdAt && noIdAt < triggerAt,
        "consume must update replay state and pass accepted/no-id guards before triggering")
    assert.doesNotMatch(consume, /handleQuotaResets|detectResets|Notification|notify|logQuotaReset|resetLog|console\.(?:log|warn|error)/i)

    // Existing bindings fan one generation out to both mounted compact/full cards.
    assert.match(compactCards, /celebrateProfileId:\s*root\.usageController/)
    assert.match(compactCards, /celebrateGeneration:\s*root\.usageController/)
    assert.match(fullCards, /celebrateProfileId:\s*root\.usageController/)
    assert.match(fullCards, /celebrateGeneration:\s*root\.usageController/)
}

function replaced(source, oldText, newText, description) {
    assert.ok(source.includes(oldText), `mutant setup missing ${description}`)
    return source.replace(oldText, newText)
}

const controller = read("contents/ui/ProfileController.qml")
const main = read("contents/ui/main.qml")
const cardsView = read("contents/ui/CardsView.qml")

validate(controller, main, cardsView)

// Representative source mutants prove the structural validator rejects the
// concrete false-positive classes this contract is intended to prevent.
const mutants = [
    ["target id nested below wrong DataSource id", replaced(controller,
        "id: testCelebrationSource\n        engine:",
        "id: wrongCelebrationSource\n        Item { id: testCelebrationSource }\n        engine:", "test source id"), main,
        /expected exactly one Plasma5Support\.DataSource component with id testCelebrationSource, found 0/],
    ["connect before busy guard", replaced(controller,
        "function pollTestCelebration() {\n        if (testCelebrationPollBusy)",
        "function pollTestCelebration() {\n        testCelebrationSource.connectSource(command)\n        if (testCelebrationPollBusy)", "poll guard"), main,
        /poll must guard, set busy, construct command, then connect in that order/],
    ["inverted empty-output predicate", replaced(controller,
        'if (String(stdout).trim() === "") return',
        "if (String(stdout).trim()) return", "empty-output guard"), main,
        /missing exact empty-output guard/],
    ["trigger before accepted/no-id guards", replaced(controller,
        "testCelebrationReplayState = result.state\n        if (!result.accepted) return",
        'testCelebrationReplayState = result.state\n        triggerCardCelebration("premature")\n        if (!result.accepted) return', "accepted guard"), main,
        /consume must contain exactly one direct celebration trigger/],
    ["limits outside CardsView components", controller,
        "// maxCards: root.usageController.compactCardLimit\n"
        + "// maxCards: root.usageController.fullCardLimit\n"
        + replaced(replaced(main,
            "maxCards: root.usageController.compactCardLimit", "maxCards: 8", "compact limit binding"),
            "maxCards: root.usageController.fullCardLimit", "maxCards: 12", "full limit binding"),
        /maxCards:\\s\*root\\\.usageController\\\.compactCardLimit/]
]
for (const [name, mutantController, mutantMain, expectedFailure] of mutants) {
    assert.throws(() => validate(mutantController, mutantMain, cardsView),
        expectedFailure, `validator accepted mutant or rejected it for the wrong reason: ${name}`)
}

console.log("All test-celebration controller wiring tests passed.")
