#!/usr/bin/env node
/**
 * P1.M4.E1.T002 — KCM projection, editing, and idempotent persistence via
 * VisibleQuotaConfig.configuration().
 */
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const VQ = loadQmlJs(
    join(root, "contents/ui/js/VisibleQuotaConfig.js"), {},
    ["configuration", "specFor", "apply"]
)
function provider(result, id) {
    return result.providers.find(entry => entry.provider === id)
}
function checked(result, providerId, windowId) {
    return provider(result, providerId).windows
        .find(window => window.id === windowId).checked
}

const defaults = VQ.configuration({ persisted: "[]" })
assert.equal(defaults.changed, false)
assert.equal(defaults.persisted, "[]")
assert.deepEqual(defaults.providers.map(p => p.provider),
                 ["claude", "codex", "grok", "zai", "minimax", "kimi"])
assert.deepEqual(provider(defaults, "claude").windows.map(w => [w.id, w.checked]), [
    ["5h", true], ["weekly", true], ["weekly_fable", false],
    ["weekly_oracle", false], ["weekly_opus", false],
    ["weekly_sonnet", false], ["weekly_oauth_apps", false]
])
assert.deepEqual(provider(defaults, "codex").windows.map(w => [w.id, w.checked]), [
    ["session", true], ["weekly", true], ["credits", false],
    ["extra_spk_7d", false]
])
assert.deepEqual(provider(defaults, "grok").windows.map(w => [w.id, w.checked]), [
    ["session", true], ["weekly", true], ["on_demand", false]
])
assert.deepEqual(provider(defaults, "zai").windows.map(w => [w.id, w.checked]),
                 [["session", true], ["weekly", true]])
assert.deepEqual(provider(defaults, "minimax").windows.map(w => [w.id, w.checked]),
                 [["5h/general", true], ["wk/general", true]])
assert.deepEqual(provider(defaults, "kimi").windows.map(w => [w.id, w.checked]),
                 [["session", true], ["weekly", true], ["total_quota", false]])

// Parser/catalogue consistency: every built-in ID/defaultVisible must agree.
const QC = loadQmlJs(join(root, "contents/ui/js/QuotaCommon.js"), {}, [
    "formatWindowDuration", "makeWindow", "parseResetMs"
])
const QP = loadQmlJs(join(root, "contents/ui/js/QuotaParsers.js"), { QC }, [
    "parseClaude", "parseCodex", "parseGrok", "parseMinimax", "parseZai", "parseKimi"
])
const parsed = {
    claude: QP.parseClaude({
        five_hour: { utilization: 1 }, seven_day: { utilization: 2 },
        seven_day_fable: { utilization: 3 }, seven_day_oracle: { utilization: 4 },
        seven_day_opus: { utilization: 5 }, seven_day_sonnet: { utilization: 6 },
        seven_day_oauth_apps: { utilization: 7 },
        seven_day_future_model: { utilization: 8 }
    }),
    codex: QP.parseCodex({
        rate_limit: {
            primary_window: { used_percent: 1, reset_at: 1, limit_window_seconds: 18000 },
            secondary_window: { used_percent: 2, reset_at: 1, limit_window_seconds: 604800 }
        },
        additional_rate_limits: [{
            limit_name: "GPT-5.3-spark",
            rate_limit: { secondary_window: {
                used_percent: 3, reset_at: 1, limit_window_seconds: 604800
            }}
        }],
        credits: { unlimited: false, balance: "1.00" }
    }),
    grok: QP.parseGrok(
        { monthlyLimit: 10000, used: 1000, billingPeriodEnd: "2026-08-01T00:00:00Z" },
        { currentPeriod: { type: "USAGE_PERIOD_TYPE_WEEKLY",
                           end: "2026-07-24T00:00:00Z" },
          creditUsagePercent: 1, onDemandCap: 1000, onDemandUsed: 1 }),
    zai: QP.parseZai({ limits: [
        { type: "TOKENS_LIMIT", percentage: 1 },
        { type: "TIME_LIMIT", percentage: 2 }
    ]}),
    minimax: QP.parseMinimax({ model_remains: [{
        model_name: "general", current_interval_total_count: 10,
        current_interval_usage_count: 9, current_weekly_total_count: 10,
        current_weekly_usage_count: 8
    }]}),
    kimi: QP.parseKimi({
        usage: { limit: 10, used: 1 },
        limits: [{ window: { duration: 5, timeUnit: "HOUR" },
                   detail: { limit: 10, used: 1 } }],
        totalQuota: { used: 1 }
    })
}
for (const p of defaults.providers) {
    const actual = new Map(parsed[p.provider].windows.map(w => [w.id, w.defaultVisible]))
    for (const builtIn of p.windows) {
        assert.equal(actual.has(builtIn.id), true,
                     `${p.provider}/${builtIn.id} missing from parser fixture`)
        assert.equal(actual.get(builtIn.id), builtIn.checked,
                     `${p.provider}/${builtIn.id} default drift`)
    }
}
assert.equal(provider(defaults, "claude").windows.some(w =>
    w.id === "weekly_future_model"), false)
assert.equal(parsed.claude.windows.find(w =>
    w.id === "weekly_future_model").defaultVisible, false)

// Event semantics and idempotence
const hiddenWeekly = VQ.configuration({
    persisted: "[]",
    event: { type: "set", provider: "claude", windowId: "weekly", visible: false }
})
assert.equal(hiddenWeekly.changed, true)
assert.equal(checked(hiddenWeekly, "claude", "weekly"), false)
assert.deepEqual(JSON.parse(hiddenWeekly.persisted), {
    claude: {
        "5h": true, weekly: false, weekly_fable: false,
        weekly_oracle: false, weekly_opus: false,
        weekly_sonnet: false, weekly_oauth_apps: false
    }
})
const repeated = VQ.configuration({
    persisted: hiddenWeekly.persisted,
    event: { type: "set", provider: "claude", windowId: "weekly", visible: false }
})
assert.equal(repeated.persisted, hiddenWeekly.persisted)
assert.deepEqual(repeated.providers, hiddenWeekly.providers)

const restored = VQ.configuration({
    persisted: hiddenWeekly.persisted,
    event: { type: "set", provider: "claude", windowId: "weekly", visible: true }
})
assert.equal(restored.persisted, "[]")
assert.equal(provider(restored, "claude").canReset, false)

// Legacy migration and unknown preservation
const inspectedLegacy = VQ.configuration({ persisted: '["5h","weekly"]' })
assert.equal(inspectedLegacy.changed, false)
assert.equal(inspectedLegacy.persisted, '["5h","weekly"]')
assert.equal(checked(inspectedLegacy, "claude", "5h"), true)
assert.equal(checked(inspectedLegacy, "codex", "session"), false)
assert.equal(checked(inspectedLegacy, "minimax", "5h/general"), true)

const editedLegacy = VQ.configuration({
    persisted: '["5h","weekly"]',
    event: { type: "set", provider: "claude", windowId: "weekly", visible: false }
})
const migrated = JSON.parse(editedLegacy.persisted)
assert.equal(migrated.claude.weekly, false)
assert.equal(migrated.codex.weekly, true)
assert.equal(migrated.grok.weekly, true)
assert.equal(migrated.minimax, undefined)

const rawUnknown = JSON.stringify({
    claude: { future_model: true },
    future_provider: { quota: false }
})
const editedUnknown = VQ.configuration({
    persisted: rawUnknown,
    event: { type: "set", provider: "codex", windowId: "weekly", visible: false }
})
const unknownOut = JSON.parse(editedUnknown.persisted)
assert.equal(unknownOut.claude.future_model, true)
assert.equal(unknownOut.future_provider.quota, false)
assert.equal(unknownOut.codex.weekly, false)

const resetProvider = VQ.configuration({
    persisted: editedUnknown.persisted,
    event: { type: "resetProvider", provider: "claude" }
})
assert.equal(JSON.parse(resetProvider.persisted).claude, undefined)
assert.equal(JSON.parse(resetProvider.persisted).future_provider.quota, false)
const resetAll = VQ.configuration({
    persisted: editedUnknown.persisted,
    event: { type: "resetAll" }
})
assert.equal(resetAll.persisted, "[]")

// Invalid / strict-provider behaviour
const invalid = VQ.configuration({ persisted: "{" })
assert.equal(invalid.changed, false)
assert.equal(invalid.persisted, "{")
assert.deepEqual(invalid.providers, defaults.providers)
const invalidEvent = VQ.configuration({
    persisted: rawUnknown,
    event: { type: "set", provider: "", windowId: "weekly", visible: false }
})
assert.equal(invalidEvent.changed, false)
assert.equal(invalidEvent.persisted, rawUnknown)

const strict = VQ.configuration({ persisted: '{"claude":["5h"]}' })
assert.equal(checked(strict, "claude", "5h"), true)
assert.equal(checked(strict, "claude", "weekly"), false)
assert.equal(checked(strict, "claude", "weekly_fable"), false)

console.log("All visible quota configuration tests passed.")
