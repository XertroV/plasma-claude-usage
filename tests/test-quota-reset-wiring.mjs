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

// Kcfg + KCM
assert.match(mainXml, /name="notifyOnQuotaReset"/)
assert.match(mainXml, /name="logQuotaResets"/)
assert.match(configQml, /property bool cfg_notifyOnQuotaReset/)
assert.match(configQml, /property bool cfg_logQuotaResets/)
assert.match(configQml, /cfg_notifyOnQuotaReset/)
assert.match(configQml, /cfg_logQuotaResets/)

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
