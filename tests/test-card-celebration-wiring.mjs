#!/usr/bin/env node
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const read = path => readFileSync(join(root, path), "utf8")
const card = read("contents/ui/AccountCard.qml")
const cards = read("contents/ui/CardsView.qml")
const main = read("contents/ui/main.qml")

assert.match(card, /import "js\/CelebrationMotion\.js" as CelebrationMotion/)
assert.match(card, /property bool reducedMotion:\s*false/)
assert.match(card, /property real celebrationProgress:\s*0/)
assert.match(card, /CelebrationMotion\.at\(\s*celebrationProgress,\s*reducedMotion\s*\)/)
assert.match(card, /NumberAnimation\s*\{[\s\S]*id:\s*celebrateAnim[\s\S]*property:\s*"celebrationProgress"[\s\S]*from:\s*0[\s\S]*to:\s*1/)
assert.doesNotMatch(card, /SequentialAnimation\s*\{\s*id:\s*celebrateAnim/)
assert.match(card, /celebrateAnim\.stop\(\)[\s\S]*restoreIdleChrome\(\)[\s\S]*celebrationProgress\s*=\s*0[\s\S]*celebrating\s*=\s*true[\s\S]*celebrateAnim\.start\(\)/)
assert.match(card, /Qt\.binding\(function\(\)\s*\{\s*return idleFill\s*\}\)/)
assert.match(card, /Qt\.binding\(function\(\)\s*\{\s*return idleBorder\s*\}\)/)
assert.match(card, /clip:\s*!celebrating/)
assert.match(card, /String\(profile\.id\)\s*!==\s*String\(celebrateProfileId\)/)
assert.match(card, /lastPlayedCelebrateGeneration/)
assert.match(card, /function tryPlayCelebration\s*\(/)
assert.match(card, /celebrateGeneration\s*<=\s*lastPlayedCelebrateGeneration/)
assert.match(card, /source:\s*"emblem-favorite-symbolic"/)
assert.doesNotMatch(card, /text:\s*"🎉"/)

const controller = read("contents/ui/ProfileController.qml")
assert.match(controller, /clearCelebrationPulse\.restart\(\)/)
assert.match(controller, /function clearCardCelebrationPulse\s*\(/)

assert.match(cards, /property bool reducedMotion:\s*Kirigami\.Units\.longDuration\s*<=\s*0/)
assert.match(cards, /reducedMotion:\s*cardsRoot\.reducedMotion/)
const propagated = main.match(/reducedMotion:\s*Kirigami\.Units\.longDuration\s*<=\s*0/g) || []
assert.equal(propagated.length, 2, "compact and full CardsViews propagate reduced motion")

console.log("All card celebration wiring tests passed.")
