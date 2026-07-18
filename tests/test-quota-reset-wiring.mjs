#!/usr/bin/env node
/**
 * Seam wiring checks for I006: ProfileController + config + scripts.
 */
import assert from "node:assert/strict"
import { readFileSync, accessSync, constants } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")

function read(rel) {
    return readFileSync(join(root, rel), "utf8")
}

const controller = read("contents/ui/ProfileController.qml")
const configQml = read("contents/ui/configGeneral.qml")
const mainXml = read("contents/config/main.xml")
const resetJs = read("contents/ui/js/QuotaResetEvents.js")

// Controller imports + call sites
assert.match(controller, /import org\.kde\.notification as KNotification/)
assert.match(controller, /import "js\/QuotaResetEvents\.js" as QuotaReset/)
assert.match(controller, /function handleQuotaResets\s*\(/)
assert.match(controller, /function sendQuotaResetNotification\s*\(/)
assert.match(controller, /function logQuotaResetEnvelopes\s*\(/)
assert.match(controller, /prevWinsSuccess/)
assert.match(controller, /prevWinsApply/)
assert.match(controller, /handleQuotaResets\(transition\.profileId/)
assert.match(controller, /handleQuotaResets\(p\.id/)
assert.match(controller, /resetNotificationComponent/)
assert.match(controller, /resetLogWriter/)
assert.match(controller, /cfgTruthy\("notifyOnQuotaReset"/)
assert.match(controller, /cfgTruthy\("logQuotaResets"/)
// B006: RESET_LOG tag must be shell-quoted (never raw profileId in unquoted words)
assert.match(controller, /shellQuote\(tag\)/)
assert.match(controller, /: " \+ shellQuote\(tag\)/)
assert.match(controller, /resetClassifyGraceMs/)
assert.match(controller, /graceMs:\s*resetClassifyGraceMs/)
assert.match(controller, /function triggerCardCelebration\s*\(/)
assert.match(controller, /triggerCardCelebration\(profileId\)/)
assert.match(controller, /property string celebrateProfileId/)
assert.match(controller, /property int celebrateGeneration/)

const card = read("contents/ui/AccountCard.qml")
assert.match(card, /function playCelebration\s*\(/)
assert.match(card, /function restoreIdleChrome\s*\(/)
assert.match(card, /Qt\.binding\(function\(\)\s*\{\s*return idleFill\s*\}\)/)
assert.match(card, /id: celebrateAnim/)
assert.match(card, /onCelebrateGenerationChanged/)
assert.match(card, /shakeX/)
assert.match(card, /bounceScale/)
assert.match(card, /partyGlow/)

const cardsView = read("contents/ui/CardsView.qml")
assert.match(cardsView, /celebrateProfileId: cardsRoot\.celebrateProfileId/)
assert.match(cardsView, /celebrateGeneration: cardsRoot\.celebrateGeneration/)

const main = read("contents/ui/main.qml")
assert.match(main, /celebrateProfileId: root\.usageController/)
assert.match(main, /celebrateGeneration: root\.usageController/)

// Kcfg + KCM
assert.match(mainXml, /name="notifyOnQuotaReset"/)
assert.match(mainXml, /name="logQuotaResets"/)
assert.match(configQml, /property bool cfg_notifyOnQuotaReset/)
assert.match(configQml, /property bool cfg_logQuotaResets/)
assert.match(configQml, /cfg_notifyOnQuotaReset/)
assert.match(configQml, /cfg_logQuotaResets/)
assert.match(configQml, /import org\.kde\.notification as KNotification/)
assert.match(configQml, /import "js\/QuotaResetEvents\.js" as QuotaReset/)
assert.match(configQml, /function sendTestQuotaResetNotification\s*\(/)
assert.match(configQml, /Send test celebration/)
assert.match(configQml, /testResetNotificationComponent/)
assert.match(configQml, /sendTestQuotaResetNotification\(\)/)

// Pure module surface
assert.match(resetJs, /function detectResets\s*\(/)
assert.match(resetJs, /function buildLogCommand\s*\(/)
assert.match(resetJs, /function formatNotification\s*\(/)
assert.match(resetJs, /"natural"/)
assert.match(resetJs, /"early"/)
assert.match(resetJs, /"late"/)
assert.match(resetJs, /"surprise"/)

// Script exists and is executable bit optional in worktree; content contract
const script = read("contents/scripts/log-reset.sh")
assert.match(script, /events\.jsonl|JSONL/)
assert.match(script, /write_atomic/)
accessSync(join(root, "contents/scripts/log-reset.sh"), constants.R_OK)

console.log("All quota-reset wiring tests passed.")
