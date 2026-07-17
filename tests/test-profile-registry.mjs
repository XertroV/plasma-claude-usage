#!/usr/bin/env node
/**
 * P1.M3.E1.T001/T002 — ProfileRegistry schema, public projection, stable patching,
 * generation-checked usageResult, and discovery/custom reconciliation.
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

// =============================================================================
// P1.M3.E1.T002 — Discovery / custom reconciliation
// =============================================================================

/** Production-shaped discovery candidate (includes credInode evidence). */
function makeCandidate(overrides) {
    return Object.assign({
        id: "claude-work",
        provider: "claude",
        profileKey: "work",
        configDir: "/home/u/.claude-work",
        credPath: "/home/u/.claude-work/.credentials.json",
        credInode: "1:100",
        isFlatFile: false
    }, overrides || {})
}

function multiConfig(overrides) {
    return Object.assign({
        multiProfileMode: true,
        provider: "claude",
        opencodeSubProvider: "anthropic",
        credentialsPath: "",
        displayName: "",
        discoverOnLoad: true,
        enabledProfilesJson: "[]",
        profileDisplayNamesJson: "{}",
        customProfilesJson: "[]",
        visibleWindowsJson: "{}"
    }, overrides || {})
}

function legacyConfig(overrides) {
    return multiConfig(Object.assign({
        multiProfileMode: false,
        provider: "claude",
        credentialsPath: ""
    }, overrides || {}))
}

function discover(opts) {
    return Registry.transition({
        state: opts.state || { profiles: [] },
        event: { type: "discovered", candidates: opts.candidates || [] },
        config: opts.config || multiConfig(),
        visibility: opts.visibility,
        nowMs: opts.nowMs
    })
}

// --- new / same-ID / removed rows ---
{
    const live = makeInternal({
        id: "claude-work",
        loading: true,
        planName: "Max",
        bankedResets: 2,
        windows: [{ id: "5h", usagePercent: 33, visible: true }],
        accessToken: "tok-live",
        refreshGeneration: 9,
        lastFetchMs: 555
    })
    const gone = makeInternal({
        id: "claude-old",
        planName: "Pro",
        windows: [{ id: "weekly", usagePercent: 1, visible: true }]
    })
    const candidates = [
        makeCandidate({
            id: "claude-work",
            profileKey: "work",
            configDir: "/home/u/.claude-work-renamed",
            credPath: "/home/u/.claude-work-renamed/.credentials.json",
            credInode: "1:200"
        }),
        makeCandidate({
            id: "claude-p",
            profileKey: "p",
            configDir: "/home/u/.claude-p",
            credPath: "/home/u/.claude-p/.credentials.json",
            credInode: "1:201"
        })
    ]
    const result = discover({
        state: { profiles: [live, gone] },
        candidates,
        config: multiConfig(),
        visibility: trackingVisibility().adapter,
        nowMs: 1000
    })
    assert.equal(result.accepted, true, "discovered accepted")
    assert.equal(result.state.profiles.length, 2, "removed + new + same → 2 rows")
    assert.equal(result.state.profiles[0].id, "claude-work")
    assert.equal(result.state.profiles[1].id, "claude-p")
    assert.equal(result.state.profiles.find(p => p.id === "claude-old"), undefined, "removed ID gone")

    const kept = result.state.profiles[0]
    assert.equal(kept.planName, "Max", "same-ID preserves live planName")
    assert.equal(kept.bankedResets, 2)
    assert.equal(kept.accessToken, "tok-live")
    assert.equal(kept.refreshGeneration, 9)
    assert.equal(kept.lastFetchMs, 555)
    assert.equal(kept.loading, true)
    assert.equal(kept.configDir, "/home/u/.claude-work-renamed", "metadata replaced")
    assert.equal(kept.credPath, "/home/u/.claude-work-renamed/.credentials.json")
    assert.equal(kept.credInode, undefined, "credInode not copied into runtime row")

    const neu = result.state.profiles[1]
    assert.equal(neu.planName, "", "new row blank planName")
    assert.equal(neu.accessToken, "")
    assert.equal(neu.refreshGeneration, 0)
    assert.deepEqual(neu.windows, [])
    assert.equal(neu.credInode, undefined)

    assert.deepEqual(
        Object.keys(result.publicProfiles[0]).sort(),
        EXPECTED_PUBLIC_KEYS,
        "public snapshot keys after discover"
    )
    assert.equal(result.publicProfiles[0].accessToken, undefined)
    console.log("ok: discovered new/same/removed rows + metadata replace")
}

// --- exact post-I002 LIVE_FIELDS preservation ---
{
    const prevWindows = [{ id: "5h", usagePercent: 12, visible: false, periodMs: 18000 }]
    const live = makeInternal({
        id: "codex-default",
        provider: "codex",
        profileKey: "",
        configDir: "/home/u/.codex",
        credPath: "/home/u/.codex/auth.json",
        loading: true,
        error: "auth?",
        planName: "Plus",
        bankedResets: 4,
        windows: prevWindows,
        lastUpdate: "11:11",
        accessToken: "secret",
        accountId: "acct",
        resourceUrl: "https://example.test",
        opencodeSlot: "openai",
        refreshGeneration: 3,
        backoffMultiplier: 2,
        lastFetchMs: 42,
        authFailCount: 1,
        authSuspended: true,
        autoRefreshHoldUntilMs: 9999,
        lastFailedToken: "bad",
        credLoadManual: true
    })
    const cand = makeCandidate({
        id: "codex-default",
        provider: "codex",
        profileKey: "default",
        configDir: "/home/u/.codex",
        credPath: "/home/u/.codex/auth.json",
        credInode: "9:9"
    })
    const result = discover({
        state: { profiles: [live] },
        candidates: [cand],
        config: multiConfig({
            profileDisplayNamesJson: JSON.stringify({ "codex-default": "Office Codex" })
        }),
        visibility: trackingVisibility().adapter,
        nowMs: 50
    })
    const row = result.state.profiles[0]
    for (const f of Registry.LIVE_FIELDS) {
        if (f === "windows") {
            assert.ok(row.windows && row.windows.length === 1, "windows preserved")
            assert.equal(row.windows[0].id, "5h")
            assert.equal(row.windows[0].usagePercent, 12)
            continue
        }
        assert.equal(row[f], live[f], "LIVE_FIELDS preserved: " + f)
    }
    assert.equal(row.displayName, "Office Codex", "name override applied as metadata")
    assert.equal(row.profileKey, "default", "metadata profileKey replaced")
    assert.equal(row.provider, "codex")
    // no pre-I002 grok transaction fields required on blank/live schema
    assert.equal(row.grokFetchGen, undefined)
    assert.equal(row.usageFetchGen, undefined)
    console.log("ok: post-I002 live-field preservation + metadata replacement")
}

// --- discovery order then custom config order ---
{
    const candidates = [
        makeCandidate({ id: "b-codex", provider: "codex", profileKey: "b",
            configDir: "/home/u/.codex-b", credPath: "/home/u/.codex-b/auth.json", credInode: "2:1" }),
        makeCandidate({ id: "a-claude", provider: "claude", profileKey: "a",
            configDir: "/home/u/.claude-a", credPath: "/home/u/.claude-a/.credentials.json", credInode: "2:2" })
    ]
    const customs = [
        { id: "custom-z", provider: "grok", path: "/home/u/.grok-z", displayName: "Zed" },
        { id: "custom-y", provider: "minimax", path: "/home/u/.minimax-y" }
    ]
    const result = discover({
        candidates,
        config: multiConfig({ customProfilesJson: JSON.stringify(customs) })
    })
    assert.deepEqual(
        result.state.profiles.map(p => p.id),
        ["b-codex", "a-claude", "custom-z", "custom-y"],
        "discovery order then custom order"
    )
    console.log("ok: discovery order followed by custom config order")
}

// --- custom default cred path + displayNameHint ---
{
    const customs = [
        { id: "custom-1", provider: "claude", path: "/home/u/.claude-extra", displayName: "Extra" },
        { id: "custom-2", provider: "kimi", path: "/home/u/.kimi-for-coding", isFlatFile: false }
    ]
    const result = discover({
        candidates: [],
        config: multiConfig({ customProfilesJson: JSON.stringify(customs) })
    })
    assert.equal(result.state.profiles.length, 2)
    const c1 = result.state.profiles[0]
    assert.equal(c1.credPath, "/home/u/.claude-extra/.credentials.json", "default cred path for claude")
    assert.equal(c1.configDir, "/home/u/.claude-extra")
    assert.equal(c1.displayName, "Extra", "displayNameHint used when no cfg rename")
    assert.equal(c1.isFlatFile, false)

    const c2 = result.state.profiles[1]
    assert.equal(c2.credPath, "/home/u/.kimi-for-coding", "kimi flat path = path itself")
    assert.equal(c2.isFlatFile, true, "kimi path==cred → flat")
    assert.equal(c2.displayName, QC.defaultProfileLabel("kimi", "custom"))
    console.log("ok: custom default credential path + displayNameHint")
}

// --- invalid custom entry ignored ---
{
    const customs = [
        null,
        { id: "no-path", provider: "claude" },
        { id: "no-provider", path: "/x" },
        { id: "good", provider: "codex", path: "/home/u/.codex-x" }
    ]
    const result = discover({
        candidates: [makeCandidate({ id: "claude-default", profileKey: "", configDir: "/home/u/.claude",
            credPath: "/home/u/.claude/.credentials.json", credInode: "3:1" })],
        config: multiConfig({ customProfilesJson: JSON.stringify(customs) })
    })
    assert.deepEqual(result.state.profiles.map(p => p.id), ["claude-default", "good"])
    console.log("ok: invalid custom entries ignored")
}

// --- first-wins duplicate ID + warning ---
{
    const candidates = [
        makeCandidate({ id: "dup", profileKey: "first", configDir: "/a", credPath: "/a/c", credInode: "4:1" }),
        makeCandidate({ id: "dup", profileKey: "second", configDir: "/b", credPath: "/b/c", credInode: "4:2" })
    ]
    const result = discover({ candidates, config: multiConfig() })
    assert.equal(result.state.profiles.length, 1)
    assert.equal(result.state.profiles[0].profileKey, "first", "first candidate wins")
    assert.equal(result.state.profiles[0].configDir, "/a")
    const warn = (result.effects || []).find(e => e && e.type === "warning" && e.code === "duplicate_id")
    assert.ok(warn, "duplicate_id warning emitted")
    assert.equal(warn.profileId, "dup")
    console.log("ok: first-wins duplicate ID + warning")
}

// --- no input / candidate / window mutation ---
{
    const win = { id: "5h", usagePercent: 7, visible: true }
    const live = makeInternal({ id: "claude-work", windows: [win], accessToken: "s" })
    const state = { profiles: [live] }
    const cand = makeCandidate({ id: "claude-work", credInode: "5:5" })
    const candidates = [cand]
    const stateSnap = freezeDeep(state)
    const candSnap = freezeDeep(candidates)
    const winSnap = freezeDeep(win)

    const track = trackingVisibility()
    const result = discover({
        state,
        candidates,
        config: multiConfig(),
        visibility: track.adapter,
        nowMs: 1234
    })
    assert.deepEqual(state, stateSnap, "input state not mutated")
    assert.deepEqual(candidates, candSnap, "candidates not mutated")
    assert.deepEqual(win, winSnap, "prior window object not mutated")
    assert.notEqual(result.state.profiles[0].windows[0], win, "result windows not aliased to input")
    // mutate result windows must not touch input
    result.state.profiles[0].windows[0].usagePercent = 99
    assert.equal(live.windows[0].usagePercent, 7)
    console.log("ok: no input/candidate/window mutation")
}

// --- refreshAll when any enabled empty row; none when all filled / disabled empty ---
{
    const emptyNew = discover({
        state: { profiles: [] },
        candidates: [makeCandidate({ id: "claude-work" })],
        config: multiConfig()
    })
    const raf = (emptyNew.effects || []).filter(e => e && e.type === "refreshAll")
    assert.equal(raf.length, 1, "one refreshAll for enabled empty")
    assert.equal(raf[0].manual, true)

    const filled = discover({
        state: {
            profiles: [makeInternal({
                id: "claude-work",
                windows: [{ id: "5h", usagePercent: 1, visible: true }]
            })]
        },
        candidates: [makeCandidate({ id: "claude-work" })],
        config: multiConfig(),
        visibility: trackingVisibility().adapter,
        nowMs: 1
    })
    assert.equal(
        (filled.effects || []).filter(e => e && e.type === "refreshAll").length,
        0,
        "no refreshAll when enabled rows have windows"
    )

    const disabledEmpty = discover({
        state: { profiles: [] },
        candidates: [makeCandidate({ id: "claude-work" })],
        config: multiConfig({
            enabledProfilesJson: JSON.stringify(["__none__"])
        })
    })
    assert.equal(disabledEmpty.state.profiles[0].enabled, false)
    assert.equal(
        (disabledEmpty.effects || []).filter(e => e && e.type === "refreshAll").length,
        0,
        "disabled empty does not refreshAll"
    )
    console.log("ok: refreshAll effect parity for enabled empty rows")
}

// --- visibility adapter invoked for preserved windows ---
{
    const live = makeInternal({
        id: "claude-work",
        windows: [{ id: "5h", usagePercent: 20, visible: false }]
    })
    const track = trackingVisibility()
    const result = discover({
        state: { profiles: [live] },
        candidates: [makeCandidate({ id: "claude-work" })],
        config: multiConfig({ visibleWindowsJson: '{"claude":{"5h":true}}' }),
        visibility: track.adapter,
        nowMs: 4242
    })
    assert.equal(track.calls.specFor, 1, "specFor for preserved row")
    assert.equal(track.calls.apply, 1, "apply for preserved windows")
    assert.equal(result.state.profiles[0].windows[0].visible, true)
    assert.equal(result.state.profiles[0].windows[0].timePercent, 42)
    console.log("ok: visibility adapter applied to preserved windows")
}

// --- legacy explicit startup legacy-config (effective provider / flat) ---
{
    // Bootstrap-shaped candidate (controller maps opencode→kimi + flat paths)
    const cand = {
        id: "legacy-config",
        provider: "kimi",
        profileKey: "legacy",
        configDir: "",
        credPath: "/home/u/.kimi-for-coding",
        credInode: "legacy-config",
        isFlatFile: true
    }
    const result = discover({
        candidates: [cand],
        config: legacyConfig({
            provider: "opencode",
            opencodeSubProvider: "kimi",
            credentialsPath: "/home/u/.kimi-for-coding",
            displayName: "My Kimi"
        })
    })
    assert.equal(result.state.profiles.length, 1)
    const row = result.state.profiles[0]
    assert.equal(row.id, "legacy-config")
    assert.equal(row.provider, "kimi", "effective provider preserved on candidate")
    assert.equal(row.isFlatFile, true)
    assert.equal(row.credPath, "/home/u/.kimi-for-coding")
    assert.equal(row.displayName, "My Kimi", "legacy displayName")
    assert.equal(row.credInode, undefined)
    console.log("ok: legacy-config effective-provider/flat rules")
}

// --- legacy default startup legacy-bootstrap paths ---
{
    const cand = {
        id: "legacy-bootstrap",
        provider: "codex",
        profileKey: "legacy",
        configDir: "",
        credPath: "$HOME/.codex/auth.json",
        credInode: "legacy-bootstrap",
        isFlatFile: false
    }
    const result = discover({
        candidates: [cand],
        config: legacyConfig({
            provider: "codex",
            credentialsPath: ""
        })
    })
    assert.equal(result.state.profiles.length, 1)
    assert.equal(result.state.profiles[0].id, "legacy-bootstrap")
    assert.equal(result.state.profiles[0].provider, "codex")
    assert.equal(result.state.profiles[0].credPath, "$HOME/.codex/auth.json")
    console.log("ok: legacy-bootstrap path semantics")
}

// --- later empty-discovery fallback legacy-${configuredProvider} ---
{
    const result = discover({
        state: { profiles: [] },
        candidates: [],
        config: legacyConfig({
            provider: "opencode",
            opencodeSubProvider: "kimi",
            credentialsPath: "/home/u/.kimi-for-coding"
        })
    })
    assert.equal(result.state.profiles.length, 1)
    const row = result.state.profiles[0]
    // Intentional quirk: ID uses configured provider, not effective kimi
    assert.equal(row.id, "legacy-opencode")
    assert.equal(row.provider, "opencode", "configured provider, not effective")
    assert.equal(row.profileKey, "legacy")
    assert.equal(row.credPath, "/home/u/.kimi-for-coding")
    assert.equal(row.isFlatFile, false)
    assert.equal(row.credInode, undefined)
    console.log("ok: empty-discovery legacy-${configuredProvider} fallback")
}

// --- legacy filters discovered candidates; customs ignored ---
{
    const candidates = [
        makeCandidate({ id: "claude-work", provider: "claude", profileKey: "work",
            credPath: "/home/u/.claude-work/.credentials.json", credInode: "6:1" }),
        makeCandidate({ id: "codex-default", provider: "codex", profileKey: "",
            configDir: "/home/u/.codex", credPath: "/home/u/.codex/auth.json", credInode: "6:2" })
    ]
    const result = discover({
        candidates,
        config: legacyConfig({
            provider: "claude",
            credentialsPath: "",
            customProfilesJson: JSON.stringify([
                { id: "custom-x", provider: "grok", path: "/home/u/.grok-x" }
            ])
        })
    })
    assert.equal(result.state.profiles.length, 1, "legacy single-profile")
    assert.equal(result.state.profiles[0].provider, "claude")
    assert.equal(result.state.profiles.find(p => p.id === "custom-x"), undefined, "customs ignored in legacy")
    console.log("ok: legacy filtering + no customs")
}

// --- legacy with explicit credentialsPath matches path only ---
{
    const candidates = [
        makeCandidate({
            id: "claude-p",
            provider: "claude",
            profileKey: "p",
            configDir: "/home/u/.claude-p",
            credPath: "/home/u/.claude-p/.credentials.json",
            credInode: "7:1"
        }),
        makeCandidate({
            id: "claude-work",
            provider: "claude",
            profileKey: "work",
            configDir: "/home/u/.claude-work",
            credPath: "/home/u/.claude-work/.credentials.json",
            credInode: "7:2"
        })
    ]
    const result = discover({
        candidates,
        config: legacyConfig({
            provider: "claude",
            credentialsPath: "/home/u/.claude-work/.credentials.json"
        })
    })
    assert.equal(result.state.profiles.length, 1)
    assert.equal(result.state.profiles[0].id, "claude-work")
    console.log("ok: legacy credentialsPath path match")
}

console.log("\nAll profile-registry schema/patch/usageResult/discovery tests passed.")
