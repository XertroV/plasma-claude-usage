#!/usr/bin/env node
/**
 * P1.M3.E1.T004 — ProfileController registry store/outcome seam.
 *
 * Source contracts: one registry result adapter, public snapshots, config
 * snapshot, I002 success → usageResult, other I002 outcomes → patch by
 * stable profile ID + generation. Raw windows must not bypass visibility.
 *
 * Also retains production visibility-adapter behaviour checks (I004 seam).
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
const mainSrc = readFileSync(join(root, "contents/ui/main.qml"), "utf8")

/** Extract `{ ... }` body starting at the opening brace index. */
function extractBalanced(text, openBraceIdx) {
    if (text.charAt(openBraceIdx) !== "{")
        throw new Error("expected '{' at " + openBraceIdx)
    let depth = 0
    for (let i = openBraceIdx; i < text.length; i++) {
        const c = text.charAt(i)
        if (c === "{") depth++
        else if (c === "}") {
            depth--
            if (depth === 0)
                return text.slice(openBraceIdx, i + 1)
        }
    }
    throw new Error("unbalanced braces from " + openBraceIdx)
}

function functionBody(src, name) {
    const m = src.match(new RegExp(`function\\s+${name}\\s*\\([^)]*\\)\\s*\\{`))
    assert.ok(m, `${name} present`)
    return extractBalanced(src, m.index + m[0].length - 1)
}

// --- Task 4 source contracts ---
{
    assert.match(controllerSrc, /import "js\/ProfileRegistry\.js" as Registry/)
    assert.match(controllerSrc, /property var publicProfileList:/)
    assert.match(controllerSrc, /function applyRegistryResult\s*\(/)
    assert.match(controllerSrc, /function registryConfigSnapshot\s*\(/)
    assert.match(controllerSrc, /type:\s*"usageResult"/)
    console.log("ok: registry import, publicProfileList, adapters, usageResult event")
}

// applyRegistryResult: single adapter assigns internal/public + effects
{
    const body = functionBody(controllerSrc, "applyRegistryResult")
    assert.match(body, /profiles\s*=/)
    assert.match(body, /publicProfileList\s*=/)
    assert.match(body, /dataEpoch/)
    assert.match(body, /effect\.type|effects\[/)
    assert.match(body, /["']discover["']/)
    assert.match(body, /["']refreshAll["']/)
    assert.match(body, /["']refresh["']/)
    assert.match(body, /["']persist["']/)
    assert.match(body, /["']warning["']/)
    console.log("ok: applyRegistryResult assigns state/public and interprets effects")
}

// registryConfigSnapshot exposes exact kcfg keys used by the registry
{
    const body = functionBody(controllerSrc, "registryConfigSnapshot")
    for (const key of [
        "multiProfileMode", "provider", "opencodeSubProvider", "credentialsPath",
        "displayName", "discoverOnLoad", "enabledProfilesJson",
        "profileDisplayNamesJson", "customProfilesJson", "customProfileNextId",
        "visibleWindowsJson"
    ]) {
        assert.match(body, new RegExp(key), `config snapshot includes ${key}`)
    }
    console.log("ok: registryConfigSnapshot covers registry config keys")
}

// I002 applyRefreshTransition routes success through usageResult, others through patch
{
    const body = functionBody(controllerSrc, "applyRefreshTransition")
    assert.match(body, /Registry\.transition\s*\(/)
    assert.match(body, /type:\s*"usageResult"/)
    assert.match(body, /type:\s*"patch"/)
    assert.match(body, /expectedGeneration/)
    assert.match(body, /profileId:\s*transition\.profileId/)
    assert.match(body, /applyRegistryResult\s*\(/)

    // Success path must not apply raw windows onto the row outside the registry
    assert.doesNotMatch(body, /\.windows\s*=\s*transition\.usageResult/)
    assert.doesNotMatch(body, /adapter\.apply\(\s*transition\.usageResult/)
    // Direct applyUsageResult bypass removed from I002 transition adapter
    assert.doesNotMatch(body, /applyUsageResult\s*\(/)
    console.log("ok: applyRefreshTransition routes I002 via registry usageResult/patch")
}

// UI sync consumes prebuilt publicProfileList (not ad-hoc secret denylist rebuild)
{
    assert.match(mainSrc, /publicProfileList/)
    assert.doesNotMatch(
        mainSrc,
        /controller\.publicProfiles\s*\(/,
        "main must consume publicProfileList, not recompute via publicProfiles()"
    )
    console.log("ok: main.qml consumes publicProfileList")
}

// Production visibility adapter still present for injection into registry
{
    assert.match(controllerSrc, /function\s+registryVisibilityAdapter\s*\(/)
    assert.match(controllerSrc, /return VQ\.specFor\(profile,\s*persisted\)/)
    assert.match(controllerSrc, /var projected\s*=\s*VQ\.apply\(windows,\s*spec\)/)
    assert.match(controllerSrc, /QC\.updateTimePercent\(projected\[i\],\s*nowMs\)/)
    assert.doesNotMatch(controllerSrc,
        /QC\.(parseVisibleWindowsConfig|visibilityProviderKey|visibilitySpecForProvider|applyVisibility)\s*\(/)
    console.log("ok: production visibility adapter injects VQ + time percent")
}

// --- Behaviour: production adapter + registry usageResult (live config) ---
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

// Accepted usageResult: live config snapshot drives VQ (cannot bypass visibility)
{
    const prior = makeInternal()
    const adapter = productionVisibilityAdapter()
    const freshWins = [
        { id: "5h", usagePercent: 20, defaultVisible: true, periodMs: 0 },
        { id: "weekly", usagePercent: 40, defaultVisible: true, periodMs: 0 },
        { id: "weekly_fable", usagePercent: 5, defaultVisible: false, periodMs: 0 }
    ]
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
    assert.equal(typeof byId.weekly.timePercent, "number")
    assert.equal(result.publicProfiles[0].accessToken, undefined)
    // Public projection is the 12-field allowlist
    assert.deepEqual(Object.keys(result.publicProfiles[0]).sort(), [
        "bankedResets", "configDir", "credPath", "displayName", "enabled", "error",
        "id", "lastFetchMs", "loading", "planName", "provider", "windows"
    ].sort())
    console.log("ok: registry usageResult applies live visibility; public is safe")
}

// Generic patch cannot smuggle raw windows past the registry
{
    const prior = makeInternal()
    const result = Registry.transition({
        state: { profiles: [prior] },
        event: {
            type: "patch",
            profileId: "claude-work",
            expectedGeneration: 7,
            patch: {
                loading: false,
                windows: [{ id: "evil", usagePercent: 99, visible: true }]
            }
        },
        config: { visibleWindowsJson: "[]" },
        visibility: productionVisibilityAdapter(),
        nowMs: 1
    })
    assert.equal(result.accepted, false)
    assert.equal(result.state.profiles[0].windows[0].id, "5h")
    console.log("ok: patch with windows rejected (no visibility bypass)")
}

// Adapter failure preserves prior windows
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

// --- Task 5: main only reports changed keys; no category knowledge ---
{
    assert.doesNotMatch(mainSrc, /configDirtyRediscover/)
    assert.doesNotMatch(mainSrc, /configDirtyMembership/)
    assert.doesNotMatch(mainSrc, /configDirtySoft/)
    assert.doesNotMatch(mainSrc, /function\s+markConfigDirty\s*\(/)
    assert.doesNotMatch(mainSrc, /function\s+flushConfigDirty\s*\(/)
    // Literal rediscover/membership/soft category strings must not drive config impact
    assert.doesNotMatch(mainSrc, /["']rediscover["']/)
    assert.doesNotMatch(mainSrc, /["']membership["']/)
    assert.doesNotMatch(mainSrc, /["']soft["']/)
    assert.match(mainSrc, /noteRegistryConfigChanged\s*\(/)
    // Main reports concrete kcfg keys, not categories
    assert.match(mainSrc, /noteRegistryConfigChanged\(\s*["']multiProfileMode["']\s*\)/)
    assert.match(mainSrc, /noteRegistryConfigChanged\(\s*["']enabledProfilesJson["']\s*\)/)
    assert.match(mainSrc, /noteRegistryConfigChanged\(\s*["']profileDisplayNamesJson["']\s*\)/)
    console.log("ok: main.qml reports keys only (no rediscover/membership/soft knowledge)")
}

// --- Task 5: controller owns coalescing + setHidden + discovery success ---
{
    assert.match(controllerSrc, /function\s+noteRegistryConfigChanged\s*\(/)
    assert.match(controllerSrc, /type:\s*"configurationChanged"/)
    assert.match(controllerSrc, /type:\s*"setHidden"/)
    assert.match(controllerSrc, /type:\s*"discovered"/)

    const hiddenBody = functionBody(controllerSrc, "setProfileHidden")
    assert.match(hiddenBody, /Registry\.transition\s*\(/)
    assert.match(hiddenBody, /type:\s*"setHidden"/)
    assert.match(hiddenBody, /applyRegistryResult\s*\(/)
    // Old allowlist hand-roll should not remain in setProfileHidden
    assert.doesNotMatch(hiddenBody, /__none__/)
    assert.doesNotMatch(hiddenBody, /updateProfile\s*\(/)

    // Discovery success routes candidates through registry; failure does not replace state
    assert.match(controllerSrc, /event:\s*\{[\s\S]*type:\s*"discovered"/)
    const failBody = functionBody(controllerSrc, "failDiscovery")
    assert.doesNotMatch(failBody, /Registry\.transition\s*\(/)
    assert.doesNotMatch(failBody, /profiles\s*=/)
    assert.match(failBody, /discoveryError\s*=/)
    console.log("ok: controller coalescing/setHidden/discovery success seam")
}

console.log("\nAll profile-registry-controller seam tests passed.")
