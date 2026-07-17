#!/usr/bin/env node
/**
 * P1.M3.E1.T001 — ProfileRegistry schema, public projection, stable patching,
 * and generation-checked usageResult transition.
 */
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")

const QC = loadQmlJs(join(root, "contents/ui/js/QuotaCommon.js"), {}, [
    "pathsEqual", "defaultCredPathForProvider", "defaultProfileLabel"
])

const Registry = loadQmlJs(
    join(root, "contents/ui/js/ProfileRegistry.js"),
    { QC },
    [
        "LIVE_FIELDS",
        "PUBLIC_FIELDS",
        "transition",
        "publicProfile",
        "publicProfiles",
        "cloneState",
        "cloneWindows"
    ]
)

const EXPECTED_PUBLIC_KEYS = [
    "bankedResets", "configDir", "credPath", "displayName", "enabled", "error",
    "id", "lastFetchMs", "loading", "planName", "provider", "windows"
].sort()

function makeInternal(overrides) {
    return Object.assign({
        id: "claude-work", provider: "claude", profileKey: "work",
        configDir: "/home/u/.claude-work", credPath: "/home/u/.claude-work/.credentials.json",
        isFlatFile: false, displayName: "Work", enabled: true,
        loading: true, error: "", planName: "Pro", bankedResets: 0,
        windows: [{ id: "5h", usagePercent: 10, visible: true }],
        lastUpdate: "10:00", lastFetchMs: 100,
        accessToken: "secret", accountId: "secret-account", resourceUrl: "secret-url",
        opencodeSlot: "", refreshGeneration: 7, backoffMultiplier: 1,
        authFailCount: 0, authSuspended: false, autoRefreshHoldUntilMs: 0,
        lastFailedToken: "secret-old", credLoadManual: false
    }, overrides || {})
}

function freezeDeep(obj) {
    return JSON.parse(JSON.stringify(obj))
}

function trackingVisibility(opts) {
    const calls = { specFor: 0, apply: 0 }
    const failApply = !!(opts && opts.failApply)
    const failSpec = !!(opts && opts.failSpec)
    return {
        calls,
        adapter: {
            specFor(profile, rawVisibleConfig) {
                calls.specFor++
                if (failSpec) throw new Error("specFor boom")
                return { mode: "test", raw: rawVisibleConfig, profileId: profile && profile.id }
            },
            apply(windows, spec, nowMs) {
                calls.apply++
                if (failApply) throw new Error("apply boom")
                const out = []
                for (let i = 0; i < (windows || []).length; i++) {
                    const w = windows[i] || {}
                    out.push(Object.assign({}, w, {
                        visible: true,
                        timePercent: typeof nowMs === "number" ? nowMs % 100 : 0,
                        _specMode: spec && spec.mode
                    }))
                }
                return out
            }
        }
    }
}

function baseState(profile) {
    return { profiles: [profile] }
}

// --- LIVE / PUBLIC schema declarations ---
{
    assert.ok(Array.isArray(Registry.LIVE_FIELDS), "LIVE_FIELDS exported")
    assert.ok(Array.isArray(Registry.PUBLIC_FIELDS), "PUBLIC_FIELDS exported")
    const live = Registry.LIVE_FIELDS.slice().sort()
    for (const f of [
        "loading", "error", "planName", "bankedResets", "windows", "lastUpdate",
        "accessToken", "accountId", "resourceUrl", "opencodeSlot",
        "refreshGeneration", "backoffMultiplier", "lastFetchMs", "authFailCount",
        "authSuspended", "autoRefreshHoldUntilMs", "lastFailedToken", "credLoadManual"
    ]) {
        assert.ok(live.includes(f), "LIVE_FIELDS includes " + f)
    }
    assert.deepEqual(
        Registry.PUBLIC_FIELDS.slice().sort(),
        EXPECTED_PUBLIC_KEYS,
        "PUBLIC_FIELDS match explicit 12-field projection"
    )
    console.log("ok: schema field declarations")
}

// --- public snapshot: exact keys, no secrets, deep window copy ---
{
    const internal = makeInternal()
    const pub = Registry.publicProfile(internal)
    assert.deepEqual(Object.keys(pub).sort(), EXPECTED_PUBLIC_KEYS, "public keys exact allowlist")
    assert.equal(pub.accessToken, undefined, "no accessToken leakage")
    assert.equal(pub.accountId, undefined, "no accountId leakage")
    assert.equal(pub.resourceUrl, undefined, "no resourceUrl leakage")
    assert.equal(pub.lastFailedToken, undefined, "no lastFailedToken leakage")
    assert.equal(pub.refreshGeneration, undefined, "no refreshGeneration leakage")
    assert.notEqual(pub.windows, internal.windows, "public windows array not aliased")
    assert.notEqual(pub.windows[0], internal.windows[0], "public window object not aliased")
    assert.equal(pub.windows[0].id, "5h")
    assert.equal(pub.windows[0].usagePercent, 10)

    // mutate public window must not touch internal
    pub.windows[0].usagePercent = 99
    assert.equal(internal.windows[0].usagePercent, 10, "mutating public windows leaves internal intact")

    const pubs = Registry.publicProfiles(baseState(internal))
    assert.equal(pubs.length, 1)
    assert.deepEqual(Object.keys(pubs[0]).sort(), EXPECTED_PUBLIC_KEYS)
    console.log("ok: public snapshot allowlist + deep window copy")
}

// --- patch by ID/generation clones state and leaves input unchanged ---
{
    const internal = makeInternal()
    const inputState = baseState(internal)
    const snapshot = freezeDeep(inputState)
    const result = Registry.transition({
        state: inputState,
        event: {
            type: "patch",
            profileId: "claude-work",
            expectedGeneration: 7,
            patch: { loading: false, error: "x", planName: "Max" }
        }
    })
    assert.equal(result.accepted, true, "matching generation patch accepted")
    assert.deepEqual(inputState, snapshot, "patch leaves input state unchanged")
    assert.notEqual(result.state, inputState, "result state is a new object")
    assert.notEqual(result.state.profiles, inputState.profiles, "result profiles array cloned")
    assert.notEqual(result.state.profiles[0], inputState.profiles[0], "result profile object cloned")
    assert.equal(result.state.profiles[0].loading, false)
    assert.equal(result.state.profiles[0].error, "x")
    assert.equal(result.state.profiles[0].planName, "Max")
    assert.equal(result.state.profiles[0].accessToken, "secret", "secrets remain internal")
    assert.equal(result.publicProfiles[0].accessToken, undefined, "public omits secrets")
    assert.equal(result.publicProfiles[0].planName, "Max")
    assert.equal(result.state.profiles[0].windows[0].usagePercent, 10)
    assert.notEqual(result.state.profiles[0].windows, inputState.profiles[0].windows)
    console.log("ok: patch by ID/generation clones and does not mutate input")
}

// --- mismatched generation and unknown ID reject unchanged ---
{
    const internal = makeInternal()
    const inputState = baseState(internal)
    const snapshot = freezeDeep(inputState)

    const stale = Registry.transition({
        state: inputState,
        event: {
            type: "patch",
            profileId: "claude-work",
            expectedGeneration: 6,
            patch: { loading: false, error: "stale" }
        }
    })
    assert.equal(stale.accepted, false, "stale generation rejected")
    assert.deepEqual(inputState, snapshot, "stale patch leaves input unchanged")
    assert.equal(stale.state.profiles[0].loading, true)
    assert.equal(stale.state.profiles[0].error, "")

    const unknown = Registry.transition({
        state: inputState,
        event: {
            type: "patch",
            profileId: "missing",
            expectedGeneration: 7,
            patch: { loading: false }
        }
    })
    assert.equal(unknown.accepted, false, "unknown ID rejected")
    assert.deepEqual(inputState, snapshot, "unknown ID leaves input unchanged")
    assert.equal(unknown.state.profiles[0].loading, true)
    console.log("ok: mismatched generation / unknown ID reject")
}

// --- generic patch carrying windows or usageResult is rejected ---
{
    const internal = makeInternal()
    const inputState = baseState(internal)
    const snapshot = freezeDeep(inputState)

    const withWindows = Registry.transition({
        state: inputState,
        event: {
            type: "patch",
            profileId: "claude-work",
            expectedGeneration: 7,
            patch: {
                loading: false,
                windows: [{ id: "weekly", usagePercent: 50, visible: true }]
            }
        }
    })
    assert.equal(withWindows.accepted, false, "patch with windows rejected")
    assert.deepEqual(inputState, snapshot)
    assert.equal(withWindows.state.profiles[0].windows[0].id, "5h", "internal windows unchanged")
    assert.equal(withWindows.publicProfiles[0].windows[0].id, "5h", "public windows unchanged")

    const withUsage = Registry.transition({
        state: inputState,
        event: {
            type: "patch",
            profileId: "claude-work",
            expectedGeneration: 7,
            usageResult: { windows: [{ id: "hack" }], planName: "X" },
            patch: { loading: false }
        }
    })
    assert.equal(withUsage.accepted, false, "patch with usageResult rejected")
    assert.deepEqual(inputState, snapshot)
    assert.equal(withUsage.state.profiles[0].loading, true, "rejected patch applies nothing")
    assert.equal(withUsage.state.profiles[0].planName, "Pro")
    console.log("ok: generic patch cannot smuggle windows/usageResult")
}

// --- usageResult without expectedGeneration or stale gen rejects before visibility ---
{
    const internal = makeInternal()
    const inputState = baseState(internal)
    const snapshot = freezeDeep(inputState)
    const freshWins = [{ id: "weekly", usagePercent: 40, visible: false }]

    const trackMissing = trackingVisibility()
    const missing = Registry.transition({
        state: inputState,
        event: {
            type: "usageResult",
            profileId: "claude-work",
            // no expectedGeneration
            usageResult: { windows: freshWins, planName: "Max", bankedResets: 2 },
            patch: { loading: false, error: "" }
        },
        config: { visibleWindowsJson: '{"claude":{"weekly":true}}' },
        visibility: trackMissing.adapter,
        nowMs: 1000
    })
    assert.equal(missing.accepted, false, "usageResult without expectedGeneration rejected")
    assert.equal(trackMissing.calls.specFor, 0, "specFor not called without generation")
    assert.equal(trackMissing.calls.apply, 0, "apply not called without generation")
    assert.deepEqual(inputState, snapshot)
    assert.equal(missing.state.profiles[0].windows[0].id, "5h")

    const trackStale = trackingVisibility()
    const stale = Registry.transition({
        state: inputState,
        event: {
            type: "usageResult",
            profileId: "claude-work",
            expectedGeneration: 3,
            usageResult: { windows: freshWins, planName: "Max", bankedResets: 2 },
            patch: { loading: false, error: "" }
        },
        config: { visibleWindowsJson: '{"claude":{"weekly":true}}' },
        visibility: trackStale.adapter,
        nowMs: 1000
    })
    assert.equal(stale.accepted, false, "stale usageResult generation rejected")
    assert.equal(trackStale.calls.specFor, 0, "specFor not called for stale generation")
    assert.equal(trackStale.calls.apply, 0, "apply not called for stale generation")
    assert.deepEqual(inputState, snapshot)
    assert.equal(stale.state.profiles[0].windows[0].id, "5h")
    console.log("ok: usageResult rejects missing/stale generation before visibility")
}

// --- current-generation usageResult invokes visibility and commits adjusted windows ---
{
    const internal = makeInternal()
    const inputState = baseState(internal)
    const snapshot = freezeDeep(inputState)
    const freshWins = [{ id: "weekly", usagePercent: 40, visible: false }]
    const track = trackingVisibility()
    const rawVis = '{"claude":{"weekly":true}}'

    const result = Registry.transition({
        state: inputState,
        event: {
            type: "usageResult",
            profileId: "claude-work",
            expectedGeneration: 7,
            usageResult: {
                windows: freshWins,
                planName: "Max 5x",
                bankedResets: 3
            },
            patch: {
                loading: false,
                error: "",
                lastUpdate: "12:00",
                lastFetchMs: 999,
                backoffMultiplier: 1,
                authFailCount: 0,
                authSuspended: false,
                autoRefreshHoldUntilMs: 0,
                lastFailedToken: ""
            }
        },
        config: { visibleWindowsJson: rawVis },
        visibility: track.adapter,
        nowMs: 4242
    })

    assert.equal(result.accepted, true, "current-generation usageResult accepted")
    assert.equal(track.calls.specFor, 1, "specFor called once")
    assert.equal(track.calls.apply, 1, "apply called once")
    assert.deepEqual(inputState, snapshot, "usageResult leaves input unchanged")
    assert.equal(inputState.profiles[0].windows[0].id, "5h", "input windows untouched")

    const row = result.state.profiles[0]
    assert.equal(row.loading, false)
    assert.equal(row.error, "")
    assert.equal(row.planName, "Max 5x")
    assert.equal(row.bankedResets, 3)
    assert.equal(row.lastUpdate, "12:00")
    assert.equal(row.lastFetchMs, 999)
    assert.equal(row.windows.length, 1)
    assert.equal(row.windows[0].id, "weekly")
    assert.equal(row.windows[0].usagePercent, 40)
    assert.equal(row.windows[0].visible, true, "visibility applied")
    assert.equal(row.windows[0].timePercent, 42, "time percent from adapter/nowMs")
    assert.notEqual(row.windows, freshWins, "committed windows not aliased to input usageResult")
    assert.notEqual(row.windows[0], freshWins[0])

    const pub = result.publicProfiles[0]
    assert.deepEqual(Object.keys(pub).sort(), EXPECTED_PUBLIC_KEYS)
    assert.equal(pub.planName, "Max 5x")
    assert.equal(pub.windows[0].id, "weekly")
    assert.equal(pub.accessToken, undefined)
    assert.equal(pub.lastFailedToken, undefined)
    console.log("ok: current-generation usageResult applies visibility/time and commits")
}

// --- visibility adapter failure preserves prior windows, applies non-window terminal, warns ---
{
    const internal = makeInternal({
        windows: [{ id: "5h", usagePercent: 10, visible: true }],
        loading: true,
        error: "old",
        planName: "Pro",
        bankedResets: 0
    })
    const inputState = baseState(internal)
    const snapshot = freezeDeep(inputState)
    const track = trackingVisibility({ failApply: true })

    const result = Registry.transition({
        state: inputState,
        event: {
            type: "usageResult",
            profileId: "claude-work",
            expectedGeneration: 7,
            usageResult: {
                windows: [{ id: "weekly", usagePercent: 90, visible: true }],
                planName: "Max",
                bankedResets: 9
            },
            patch: {
                loading: false,
                error: "",
                lastUpdate: "13:00",
                lastFetchMs: 1111,
                backoffMultiplier: 1,
                authFailCount: 0,
                authSuspended: false,
                autoRefreshHoldUntilMs: 0,
                lastFailedToken: ""
            }
        },
        config: { visibleWindowsJson: "{}" },
        visibility: track.adapter,
        nowMs: 5000
    })

    assert.equal(result.accepted, true, "adapter failure still accepts non-window terminal state")
    assert.ok(track.calls.specFor >= 1 || track.calls.apply >= 1, "adapter was attempted")
    assert.deepEqual(inputState, snapshot, "adapter failure leaves input unchanged")

    const row = result.state.profiles[0]
    assert.equal(row.loading, false, "non-window terminal loading applied")
    assert.equal(row.error, "", "non-window terminal error applied")
    assert.equal(row.lastUpdate, "13:00")
    assert.equal(row.lastFetchMs, 1111)
    // prior windows preserved — not the fresh unconfigured weekly windows
    assert.equal(row.windows.length, 1)
    assert.equal(row.windows[0].id, "5h", "prior windows preserved on adapter failure")
    assert.equal(row.windows[0].usagePercent, 10)
    // plan/banked from usageResult may still apply as non-window fields
    assert.equal(row.planName, "Max")
    assert.equal(row.bankedResets, 9)

    assert.ok(Array.isArray(result.effects), "effects present")
    const warn = result.effects.find(e => e && e.type === "warning")
    assert.ok(warn, "warning effect emitted")
    assert.equal(warn.profileId, "claude-work")

    // public still safe
    assert.equal(result.publicProfiles[0].accessToken, undefined)
    assert.equal(result.publicProfiles[0].windows[0].id, "5h")
    console.log("ok: visibility adapter failure preserves windows + warns")
}

// --- unknown usageResult ID rejected without visibility ---
{
    const track = trackingVisibility()
    const result = Registry.transition({
        state: baseState(makeInternal()),
        event: {
            type: "usageResult",
            profileId: "nope",
            expectedGeneration: 7,
            usageResult: { windows: [], planName: "X" },
            patch: { loading: false }
        },
        visibility: track.adapter,
        nowMs: 1
    })
    assert.equal(result.accepted, false)
    assert.equal(track.calls.specFor, 0)
    assert.equal(track.calls.apply, 0)
    console.log("ok: unknown usageResult ID rejected without visibility")
}

// --- patch without expectedGeneration is allowed (optional for generic patch) ---
{
    const result = Registry.transition({
        state: baseState(makeInternal()),
        event: {
            type: "patch",
            profileId: "claude-work",
            patch: { loading: false, error: "e" }
        }
    })
    assert.equal(result.accepted, true, "patch without expectedGeneration accepted")
    assert.equal(result.state.profiles[0].loading, false)
    console.log("ok: optional expectedGeneration on generic patch")
}

console.log("\nAll profile-registry schema/patch/usageResult tests passed.")
