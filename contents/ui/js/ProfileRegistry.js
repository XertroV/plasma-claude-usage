.pragma library
.import "QuotaCommon.js" as QC

/**
 * Pure profile registry — identity, schema, snapshots, and transitions.
 * Task 1 (P1.M3.E1.T001): schema, public projection, patch, usageResult.
 * Controllers interpret effects; this module never performs I/O.
 */

/** Live fields preserved across same-ID reconciliation (post-I002). */
var LIVE_FIELDS = [
    "loading", "error", "planName", "bankedResets", "windows", "lastUpdate",
    "accessToken", "accountId", "resourceUrl", "opencodeSlot",
    "refreshGeneration", "backoffMultiplier", "lastFetchMs", "authFailCount",
    "authSuspended", "autoRefreshHoldUntilMs", "lastFailedToken", "credLoadManual"
]

/** Explicit 12-field public projection consumed by views. */
var PUBLIC_FIELDS = [
    "id", "provider", "configDir", "credPath", "displayName", "enabled",
    "loading", "error", "planName", "bankedResets", "windows", "lastFetchMs"
]

/** Metadata fields rebuilt from sources/config (declared for later tasks). */
var METADATA_FIELDS = [
    "id", "provider", "profileKey", "configDir", "credPath", "isFlatFile",
    "displayName", "enabled", "visibleWindowSpec"
]

function cloneObject(src) {
    if (!src || typeof src !== "object")
        return src
    var out = {}
    for (var k in src) {
        if (!src.hasOwnProperty(k))
            continue
        out[k] = src[k]
    }
    return out
}

function cloneWindows(windows) {
    if (!windows || !Array.isArray(windows))
        return []
    var out = []
    for (var i = 0; i < windows.length; i++) {
        var w = windows[i]
        out.push(w && typeof w === "object" ? cloneObject(w) : w)
    }
    return out
}

function cloneProfile(src) {
    if (!src || typeof src !== "object")
        return src
    var out = cloneObject(src)
    if (src.hasOwnProperty("windows"))
        out.windows = cloneWindows(src.windows)
    return out
}

function cloneState(state) {
    var profiles = (state && state.profiles) ? state.profiles : []
    var out = []
    for (var i = 0; i < profiles.length; i++)
        out.push(cloneProfile(profiles[i]))
    return { profiles: out }
}

function publicProfile(src) {
    var row = {}
    if (!src)
        return row
    for (var i = 0; i < PUBLIC_FIELDS.length; i++) {
        var key = PUBLIC_FIELDS[i]
        if (key === "windows")
            row.windows = cloneWindows(src.windows)
        else if (src.hasOwnProperty(key))
            row[key] = src[key]
        else
            row[key] = key === "windows" ? [] : (key === "enabled" ? true
                : (key === "loading" ? false
                    : (key === "bankedResets" || key === "lastFetchMs" ? 0 : "")))
    }
    return row
}

function publicProfiles(state) {
    var list = (state && state.profiles) ? state.profiles : []
    var out = []
    for (var i = 0; i < list.length; i++) {
        if (list[i])
            out.push(publicProfile(list[i]))
    }
    return out
}

function resultFor(state, effects, accepted) {
    return {
        state: state,
        publicProfiles: publicProfiles(state),
        effects: effects || [],
        accepted: !!accepted
    }
}

function findProfileIndex(profiles, profileId) {
    if (!profiles || profileId === undefined || profileId === null || profileId === "")
        return -1
    for (var i = 0; i < profiles.length; i++) {
        if (profiles[i] && profiles[i].id === profileId)
            return i
    }
    return -1
}

function generationMatches(profile, expectedGeneration) {
    if (expectedGeneration === undefined || expectedGeneration === null)
        return true
    return profile && profile.refreshGeneration === expectedGeneration
}

function applyPatchFields(target, patch, skipWindows) {
    if (!patch || typeof patch !== "object")
        return
    for (var k in patch) {
        if (!patch.hasOwnProperty(k))
            continue
        if (skipWindows && k === "windows")
            continue
        if (k === "windows")
            target.windows = cloneWindows(patch.windows)
        else
            target[k] = patch[k]
    }
}

/**
 * Generic non-usage patch by stable ID (optional generation precondition).
 * Rejects patches that carry windows or a sibling usageResult (must use usageResult event).
 */
function patchTransition(state, event) {
    if (event.usageResult !== undefined && event.usageResult !== null)
        return resultFor(state, [], false)
    var patch = event.patch
    if (patch && typeof patch === "object" && patch.hasOwnProperty("windows"))
        return resultFor(state, [], false)

    var idx = findProfileIndex(state.profiles, event.profileId)
    if (idx < 0)
        return resultFor(state, [], false)
    if (!generationMatches(state.profiles[idx], event.expectedGeneration))
        return resultFor(state, [], false)

    applyPatchFields(state.profiles[idx], patch, false)
    return resultFor(state, [], true)
}

/**
 * Dedicated refresh-success transition: generation-checked, live visibility/time
 * applied via injected adapter, prior windows preserved on adapter failure.
 */
function usageResultTransition(state, event, input) {
    // usageResult always requires an explicit matching expectedGeneration
    if (event.expectedGeneration === undefined || event.expectedGeneration === null)
        return resultFor(state, [], false)

    var idx = findProfileIndex(state.profiles, event.profileId)
    if (idx < 0)
        return resultFor(state, [], false)

    var target = state.profiles[idx]
    if (target.refreshGeneration !== event.expectedGeneration)
        return resultFor(state, [], false)

    var usageResult = event.usageResult || {}
    var patch = event.patch || {}
    var config = (input && input.config) ? input.config : {}
    var visibility = input && input.visibility
    var nowMs = input && input.nowMs
    var effects = []

    // Apply non-window terminal patch first (safe even if visibility fails)
    applyPatchFields(target, patch, true)

    // Non-window usage fields (empty planName keeps prior value, matching controller)
    if (usageResult.planName)
        target.planName = usageResult.planName
    if (usageResult.hasOwnProperty("bankedResets"))
        target.bankedResets = usageResult.bankedResets || 0

    // Visibility + time through injected adapter (I004-compatible seam)
    try {
        if (!visibility || typeof visibility.specFor !== "function"
                || typeof visibility.apply !== "function") {
            throw new Error("visibility adapter missing")
        }
        var spec = visibility.specFor(target, config.visibleWindowsJson)
        var applied = visibility.apply(usageResult.windows || [], spec, nowMs)
        target.windows = cloneWindows(applied)
    } catch (e) {
        // Preserve prior windows (already cloned into state); emit warning
        effects.push({
            type: "warning",
            code: "visibility_adapter_failure",
            profileId: event.profileId
        })
    }

    return resultFor(state, effects, true)
}

/**
 * Runtime transition entry point.
 * input: { state, event, config, visibility, nowMs }
 * result: { state, publicProfiles, effects, accepted }
 */
function transition(input) {
    var state = cloneState(input && input.state)
    var event = input && input.event ? input.event : {}
    if (event.type === "patch")
        return patchTransition(state, event)
    if (event.type === "usageResult")
        return usageResultTransition(state, event, input)
    return resultFor(state, [], false)
}
