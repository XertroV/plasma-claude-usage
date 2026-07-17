#!/usr/bin/env node
/**
 * P1.M4.E1.T004 — production visibility adapter + registry usageResult contracts.
 *
 * Residual: ProfileController does not yet call ProfileRegistry.transition()
 * (full I003 controller integration incomplete). This suite:
 *  1) Source-contracts the controller adapter body and live-config re-read.
 *  2) Proves the production adapter shape (VQ.specFor/apply + QC.updateTimePercent)
 *     works as the injected registry visibility adapter with live config snapshots.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")

const controllerSrc = readFileSync(
    join(root, "contents/ui/ProfileController.qml"), "utf8")

// --- source contracts: production adapter + live config on usageResult path ---
{
    assert.match(controllerSrc, /function\s+registryVisibilityAdapter\s*\(/)
    assert.match(controllerSrc, /return VQ\.specFor\(profile,\s*persisted\)/)
    assert.match(controllerSrc, /var projected\s*=\s*VQ\.apply\(windows,\s*spec\)/)
    assert.match(controllerSrc, /QC\.updateTimePercent\(projected\[i\],\s*nowMs\)/)
    assert.doesNotMatch(controllerSrc,
        /QC\.(parseVisibleWindowsConfig|visibilityProviderKey|visibilitySpecForProvider|applyVisibility)\s*\(/)

    // applyUsageResult must build a live config snapshot before adapter.specFor
    const applyIdx = controllerSrc.indexOf("function applyUsageResult")
    assert.ok(applyIdx >= 0, "applyUsageResult present")
    const applyBody = controllerSrc.slice(applyIdx, applyIdx + 900)
    assert.match(applyBody, /registryVisibilityAdapter\s*\(/)
    assert.match(applyBody, /cfgValue\(\s*["']visibleWindowsJson["']/)
    assert.match(applyBody, /\.specFor\(/)
    assert.match(applyBody, /\.apply\(/)
    // Live raw config is read in applyUsageResult, not a stale row field alone
    assert.match(applyBody, /rawVis/)
    console.log("ok: controller production adapter + live config source contracts")
}

const VQ = loadQmlJs(
    join(root, "contents/ui/js/VisibleQuotaConfig.js"), {},
    ["specFor", "apply"]
)
const QC = loadQmlJs(
    join(root, "contents/ui/js/QuotaCommon.js"), {},
    ["updateTimePercent", "computeTimePercent"]
)
const Registry = loadQmlJs(
    join(root, "contents/ui/js/ProfileRegistry.js"),
    { QC: loadQmlJs(join(root, "contents/ui/js/QuotaCommon.js"), {}, [
        "pathsEqual", "defaultCredPathForProvider", "defaultProfileLabel"
    ]) },
    ["transition", "publicProfiles"]
)

/** Mirror of ProfileController.registryVisibilityAdapter() for Node tests. */
function productionVisibilityAdapter() {
    return {
        specFor(profile, persisted) {
            return VQ.specFor(profile, persisted)
        },
        apply(windows, spec, nowMs) {
            const projected = VQ.apply(windows, spec)
            for (let i = 0; i < projected.length; i++)
                QC.updateTimePercent(projected[i], nowMs)
            return projected
        }
    }
}

function makeInternal(overrides) {
    return Object.assign({
        id: "claude-work", provider: "claude", profileKey: "work",
        configDir: "/home/u/.claude-work",
        credPath: "/home/u/.claude-work/.credentials.json",
        isFlatFile: false, displayName: "Work", enabled: true,
        loading: true, error: "", planName: "Pro", bankedResets: 0,
        windows: [{
            id: "5h", usagePercent: 10, visible: true,
            defaultVisible: true, resetsAt: null, periodMs: 0
        }],
        lastUpdate: "10:00", lastFetchMs: 100,
        accessToken: "secret", accountId: "secret-account",
        resourceUrl: "secret-url", opencodeSlot: "",
        refreshGeneration: 7, backoffMultiplier: 1,
        authFailCount: 0, authSuspended: false,
        autoRefreshHoldUntilMs: 0, lastFailedToken: "secret-old",
        credLoadManual: false
    }, overrides || {})
}

// --- accepted usageResult: live config snapshot drives VQ, not stale allowlist ---
{
    const prior = makeInternal()
    const adapter = productionVisibilityAdapter()
    const freshWins = [
        { id: "5h", usagePercent: 20, defaultVisible: true, periodMs: 0 },
        { id: "weekly", usagePercent: 40, defaultVisible: true, periodMs: 0 },
        { id: "weekly_fable", usagePercent: 5, defaultVisible: false, periodMs: 0 }
    ]
    // Live config: only weekly visible (strict per-provider allowlist)
    const liveJson = JSON.stringify({ claude: ["weekly"] })

    const result = Registry.transition({
        state: { profiles: [prior] },
        event: {
            type: "usageResult",
            profileId: "claude-work",
            expectedGeneration: 7,
            usageResult: {
                windows: freshWins,
                planName: "Max",
                bankedResets: 1
            },
            patch: { loading: false, error: "", lastFetchMs: 999 }
        },
        config: { visibleWindowsJson: liveJson },
        visibility: adapter,
        nowMs: 1_700_000_000_000
    })

    assert.equal(result.accepted, true)
    assert.equal(result.effects.length, 0, "no adapter failure")
    const wins = result.state.profiles[0].windows
    assert.equal(wins.length, 3)
    const byId = Object.fromEntries(wins.map(w => [w.id, w]))
    assert.equal(byId["5h"].visible, false, "live allowlist hides 5h")
    assert.equal(byId.weekly.visible, true, "live allowlist shows weekly")
    assert.equal(byId.weekly_fable.visible, false, "unlisted hidden under strict")
    // Time percent is composed by the production adapter (may be 0 without reset data)
    assert.equal(typeof byId.weekly.timePercent, "number")
    assert.equal(result.publicProfiles[0].accessToken, undefined)
    console.log("ok: registry usageResult re-reads live visibility via production adapter")
}

// --- second commit with different live config must re-evaluate (no cached policy) ---
{
    const prior = makeInternal({
        windows: [
            { id: "5h", usagePercent: 1, visible: false, defaultVisible: true },
            { id: "weekly", usagePercent: 2, visible: true, defaultVisible: true }
        ],
        loading: false,
        refreshGeneration: 8
    })
    const adapter = productionVisibilityAdapter()
    const winsIn = [
        { id: "5h", usagePercent: 30, defaultVisible: true },
        { id: "weekly", usagePercent: 50, defaultVisible: true }
    ]

    const r1 = Registry.transition({
        state: { profiles: [prior] },
        event: {
            type: "usageResult",
            profileId: "claude-work",
            expectedGeneration: 8,
            usageResult: { windows: winsIn, planName: "Pro" },
            patch: { loading: false }
        },
        config: { visibleWindowsJson: '["5h"]' },
        visibility: adapter,
        nowMs: 1000
    })
    assert.equal(r1.accepted, true)
    assert.equal(r1.state.profiles[0].windows.find(w => w.id === "5h").visible, true)
    assert.equal(r1.state.profiles[0].windows.find(w => w.id === "weekly").visible, false)

    // Bump generation as a real refresh would; new live config flips visibility
    r1.state.profiles[0].refreshGeneration = 9
    const r2 = Registry.transition({
        state: r1.state,
        event: {
            type: "usageResult",
            profileId: "claude-work",
            expectedGeneration: 9,
            usageResult: { windows: winsIn, planName: "Pro" },
            patch: { loading: false }
        },
        config: { visibleWindowsJson: '["weekly"]' },
        visibility: adapter,
        nowMs: 2000
    })
    assert.equal(r2.accepted, true)
    assert.equal(r2.state.profiles[0].windows.find(w => w.id === "5h").visible, false)
    assert.equal(r2.state.profiles[0].windows.find(w => w.id === "weekly").visible, true)
    console.log("ok: successive usageResults honour latest live visibleWindowsJson")
}

// --- adapter failure still preserves prior windows (registry safety unchanged) ---
{
    const prior = makeInternal({
        windows: [{ id: "5h", usagePercent: 10, visible: true, defaultVisible: true }]
    })
    const boom = {
        specFor() { throw new Error("boom") },
        apply() { throw new Error("boom") }
    }
    const result = Registry.transition({
        state: { profiles: [prior] },
        event: {
            type: "usageResult",
            profileId: "claude-work",
            expectedGeneration: 7,
            usageResult: {
                windows: [{ id: "weekly", usagePercent: 90, defaultVisible: true }],
                planName: "Max"
            },
            patch: { loading: false, error: "" }
        },
        config: { visibleWindowsJson: "[]" },
        visibility: boom,
        nowMs: 1
    })
    assert.equal(result.accepted, true)
    assert.equal(result.state.profiles[0].windows[0].id, "5h")
    assert.ok(result.effects.some(e => e && e.type === "warning"))
    console.log("ok: adapter failure safety retained")
}

// --- opaque production specs: registry must not need to inspect properties ---
{
    const adapter = productionVisibilityAdapter()
    const profile = { provider: "claude" }
    const opaque = adapter.specFor(profile, '{"claude":{"weekly":false}}')
    // Callers may only pass the result through; apply must work without external reads
    const out = adapter.apply(
        [
            { id: "5h", defaultVisible: true },
            { id: "weekly", defaultVisible: true }
        ],
        opaque,
        0
    )
    assert.equal(out.find(w => w.id === "5h").visible, true)
    assert.equal(out.find(w => w.id === "weekly").visible, false)
    console.log("ok: opaque production specs apply without caller inspection")
}

// Residual documentation for parent merge notes
console.log(
    "residual: ProfileController still applies usage via applyUsageResult " +
    "rather than ProfileRegistry.transition(); adapter factory is ready to inject."
)
console.log("\nAll profile-registry-controller visibility seam tests passed.")
