.pragma library
.import "QuotaCommon.js" as QC

/**
 * Pure profile registry — identity, schema, snapshots, and transitions.
 * Task 1 (P1.M3.E1.T001): schema, public projection, patch, usageResult.
 * Task 2 (P1.M3.E1.T002): discovery/custom reconciliation.
 * Task 3 (P1.M3.E1.T003): shared KCM editConfig for enabled/name/custom.
 * Task 5 (P1.M3.E1.T005): configurationChanged + setHidden impact/effects.
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

/** Metadata fields rebuilt from sources/config. */
var METADATA_FIELDS = [
    "id", "provider", "profileKey", "configDir", "credPath", "isFlatFile",
    "displayName", "enabled", "visibleWindowSpec"
]

/** Default non-live values for blank rows (derived once from LIVE_FIELDS schema). */
var BLANK_LIVE_DEFAULTS = {
    loading: false,
    error: "",
    planName: "",
    bankedResets: 0,
    windows: [],
    lastUpdate: "",
    accessToken: "",
    accountId: "",
    resourceUrl: "https://api.minimax.io",
    opencodeSlot: "",
    refreshGeneration: 0,
    backoffMultiplier: 1,
    lastFetchMs: 0,
    authFailCount: 0,
    authSuspended: false,
    autoRefreshHoldUntilMs: 0,
    lastFailedToken: "",
    credLoadManual: false
}
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
    // Accept real arrays and QML array-like lists (length + index access)
    if (!windows || typeof windows.length !== "number" || windows.length < 0)
        return []
    var out = []
    var n = windows.length
    for (var i = 0; i < n; i++) {
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

// ---------------------------------------------------------------------------
// Discovery / custom reconciliation (P1.M3.E1.T002)
// ---------------------------------------------------------------------------

function parseJsonConfig(raw, fallback) {
    if (raw === undefined || raw === null || raw === "")
        return fallback
    if (typeof raw !== "string") {
        // Already-parsed values (tests / future callers)
        if (raw === fallback)
            return fallback
        return raw
    }
    try {
        return JSON.parse(raw)
    } catch (e) {
        return fallback
    }
}

function isLegacySingleInstance(config) {
    var multi = config && config.multiProfileMode
    // Default multi-profile (B004). Legacy only when explicitly false-like.
    if (multi === false || multi === "false" || multi === 0 || multi === "0")
        return true
    return false
}

function legacyProfileMatches(meta, config) {
    if (!meta)
        return false
    var credPath = (config && config.credentialsPath) || ""
    if (credPath)
        return QC.pathsEqual(meta.credPath, credPath)

    var provider = (config && config.provider) || "claude"
    if (provider === "opencode") {
        var sub = (config && config.opencodeSubProvider) || "anthropic"
        if (sub === "kimi")
            return meta.provider === "kimi"
        if (sub === "zai")
            return meta.provider === "zai"
        if (sub === "openai")
            return meta.provider === "codex"
        if (sub === "anthropic") {
            return meta.provider === "claude"
                || (meta.provider === "opencode" && meta.profileKey === "anthropic-accounts")
        }
        return meta.provider === "opencode"
    }
    if (provider === "claude")
        return meta.provider === "claude"
    return meta.provider === provider
}

function filterDiscoveredProfiles(discovered, config) {
    var src = discovered || []
    if (!isLegacySingleInstance(config)) {
        var copy = []
        for (var i = 0; i < src.length; i++)
            copy.push(src[i])
        return copy
    }
    var out = []
    for (var j = 0; j < src.length; j++) {
        if (legacyProfileMatches(src[j], config))
            out.push(src[j])
    }
    // Legacy single-profile: without explicit credentialsPath, keep one canonical match
    var explicitCred = (config && config.credentialsPath) || ""
    if (out.length > 1 && !explicitCred) {
        out.sort(function (a, b) {
            var pa = String((a && (a.credPath || a.configDir)) || "")
            var pb = String((b && (b.credPath || b.configDir)) || "")
            if (pa.length !== pb.length)
                return pa.length - pb.length
            return pa < pb ? -1 : (pa > pb ? 1 : 0)
        })
        out = [out[0]]
    }
    return out
}

function resolveCustomCredPath(entry) {
    if (!entry)
        return ""
    if (entry.credPath)
        return entry.credPath
    return QC.defaultCredPathForProvider(entry.provider, entry.path)
}

function materializeCustomMeta(entry, index) {
    if (!entry || !entry.path || !entry.provider)
        return null
    var resolvedCred = resolveCustomCredPath(entry)
    var isFlat = !!entry.isFlatFile
    if (entry.provider === "kimi" && resolvedCred === entry.path)
        isFlat = true
    return {
        id: entry.id || (entry.provider + "-custom-" + index),
        provider: entry.provider,
        profileKey: entry.profileKey || "custom",
        configDir: entry.path,
        credPath: resolvedCred,
        // discovery evidence only — never copied into runtime rows
        credInode: "custom:" + (entry.id || index),
        isFlatFile: isFlat,
        displayNameHint: entry.displayName || ""
    }
}

function profileDisplayName(meta, config) {
    if (isLegacySingleInstance(config)) {
        var legacyName = (config && config.displayName) || ""
        if (legacyName)
            return legacyName
    }
    var names = parseJsonConfig(config && config.profileDisplayNamesJson, {})
    if (names && meta && meta.id && names[meta.id])
        return names[meta.id]
    return QC.defaultProfileLabel(meta && meta.provider, meta && meta.profileKey)
}

function isProfileEnabled(metaOrId, config) {
    var id = metaOrId && typeof metaOrId === "object" ? metaOrId.id : metaOrId
    if (!id)
        return true
    var enabled = parseJsonConfig(config && config.enabledProfilesJson, [])
    if (!enabled || !Array.isArray(enabled) || enabled.length === 0)
        return true
    return enabled.indexOf(id) >= 0
}

/**
 * Blank internal row from central schema. Does not copy credInode.
 */
function blankRow(meta) {
    var row = {
        id: (meta && meta.id) || "",
        provider: (meta && meta.provider) || "",
        profileKey: (meta && meta.profileKey) || "",
        configDir: (meta && meta.configDir) || "",
        credPath: (meta && meta.credPath) || "",
        isFlatFile: !!(meta && meta.isFlatFile),
        displayName: "",
        enabled: true,
        visibleWindowSpec: null
    }
    for (var i = 0; i < LIVE_FIELDS.length; i++) {
        var k = LIVE_FIELDS[i]
        if (k === "windows")
            row.windows = []
        else if (BLANK_LIVE_DEFAULTS.hasOwnProperty(k))
            row[k] = BLANK_LIVE_DEFAULTS[k]
        else
            row[k] = null
    }
    return row
}

function buildPrevById(profiles) {
    var map = {}
    var list = profiles || []
    for (var i = 0; i < list.length; i++) {
        var p = list[i]
        if (p && p.id)
            map[p.id] = p
    }
    return map
}

function preserveLiveFields(row, prev) {
    if (!prev)
        return
    for (var i = 0; i < LIVE_FIELDS.length; i++) {
        var k = LIVE_FIELDS[i]
        if (prev[k] === undefined)
            continue
        if (k === "windows")
            row.windows = cloneWindows(prev.windows)
        else
            row[k] = prev[k]
    }
}

function applyVisibilityToRow(row, config, visibility, nowMs, effects) {
    if (!visibility || typeof visibility.specFor !== "function")
        return
    try {
        var spec = visibility.specFor(row, config && config.visibleWindowsJson)
        row.visibleWindowSpec = spec
        if (row.windows && row.windows.length
                && typeof visibility.apply === "function") {
            var applied = visibility.apply(row.windows, spec, nowMs)
            row.windows = cloneWindows(applied)
        }
    } catch (e) {
        if (effects) {
            effects.push({
                type: "warning",
                code: "visibility_adapter_failure",
                profileId: row.id
            })
        }
    }
}

/**
 * Build ordered unique source metas: filtered discovery + customs (multi only).
 * Emits duplicate_id warnings; first ID wins.
 */
function collectSourceMetas(candidates, config, effects) {
    var merged = filterDiscoveredProfiles(candidates || [], config)

    // Later empty-discovery fallback (legacy only, explicit credentialsPath)
    if (merged.length === 0 && isLegacySingleInstance(config)) {
        var legacyCred = (config && config.credentialsPath) || ""
        if (legacyCred) {
            var configuredProvider = (config && config.provider) || "claude"
            merged.push({
                id: "legacy-" + configuredProvider,
                provider: configuredProvider,
                profileKey: "legacy",
                configDir: "",
                credPath: legacyCred,
                credInode: "legacy",
                isFlatFile: false
            })
        }
    }

    // Customs are multi-profile only (B004)
    if (!isLegacySingleInstance(config)) {
        var custom = parseJsonConfig(config && config.customProfilesJson, [])
        if (Array.isArray(custom)) {
            for (var c = 0; c < custom.length; c++) {
                var meta = materializeCustomMeta(custom[c], c)
                if (meta)
                    merged.push(meta)
            }
        }
    }

    var unique = []
    var seen = {}
    for (var i = 0; i < merged.length; i++) {
        var m = merged[i]
        if (!m || !m.id)
            continue
        if (seen[m.id]) {
            effects.push({
                type: "warning",
                code: "duplicate_id",
                profileId: m.id
            })
            continue
        }
        seen[m.id] = true
        unique.push(m)
    }
    return unique
}

/**
 * Discovery reconciliation: deterministic rows, live preservation, effects.
 * input: { state, event: { type:"discovered", candidates }, config, visibility, nowMs }
 */
function discoveredTransition(state, event, input) {
    var config = (input && input.config) ? input.config : {}
    var visibility = input && input.visibility
    var nowMs = input && input.nowMs
    var effects = []
    var candidates = (event && event.candidates) ? event.candidates : []

    var sources = collectSourceMetas(candidates, config, effects)
    var prevById = buildPrevById(state.profiles)
    var rows = []

    for (var i = 0; i < sources.length; i++) {
        var meta = sources[i]
        var row = blankRow(meta)
        row.displayName = profileDisplayName(meta, config)
        row.enabled = isProfileEnabled(meta, config)

        // Prefer explicit custom displayNameHint when no cfg rename
        if (meta.displayNameHint
                && row.displayName === QC.defaultProfileLabel(meta.provider, meta.profileKey))
            row.displayName = meta.displayNameHint

        var prev = prevById[meta.id]
        if (prev) {
            preserveLiveFields(row, prev)
            applyVisibilityToRow(row, config, visibility, nowMs, effects)
        } else if (visibility && typeof visibility.specFor === "function") {
            // Still resolve visibility spec for new rows (windows empty → no apply)
            try {
                row.visibleWindowSpec = visibility.specFor(row, config && config.visibleWindowsJson)
            } catch (eNew) {
                effects.push({
                    type: "warning",
                    code: "visibility_adapter_failure",
                    profileId: row.id
                })
            }
        }

        rows.push(row)
    }

    // Any enabled empty row → one refreshAll (manual), matching controller staggerRefreshAll
    var needFetch = false
    for (var ri = 0; ri < rows.length; ri++) {
        if (rows[ri].enabled === false)
            continue
        if (!rows[ri].windows || rows[ri].windows.length === 0) {
            needFetch = true
            break
        }
    }
    if (needFetch)
        effects.push({ type: "refreshAll", manual: true })

    return resultFor({ profiles: rows }, effects, true)
}

// ---------------------------------------------------------------------------
// Configuration impact + hide/show (P1.M3.E1.T005)
// ---------------------------------------------------------------------------

/** Keys that force full rediscovery (highest precedence). */
var REDISCOVER_CONFIG_KEYS = {
    multiProfileMode: true,
    credentialsPath: true,
    provider: true,
    opencodeSubProvider: true,
    customProfilesJson: true
}

/** Keys that re-read enabled membership on current rows. */
var MEMBERSHIP_CONFIG_KEYS = {
    enabledProfilesJson: true
}

/** Keys that re-apply names / window visibility only. */
var SOFT_CONFIG_KEYS = {
    profileDisplayNamesJson: true,
    visibleWindowsJson: true,
    displayName: true
}

/**
 * Classify config keys with precedence rediscover > membership > soft.
 * Returns { impact: "rediscover"|"membership"|"soft"|null }.
 */
function classifyConfigKeys(keys) {
    var list = keys || []
    var hasRediscover = false
    var hasMembership = false
    var hasSoft = false
    var anyKnown = false
    for (var i = 0; i < list.length; i++) {
        var k = list[i]
        if (!k)
            continue
        if (REDISCOVER_CONFIG_KEYS[k]) {
            hasRediscover = true
            anyKnown = true
        } else if (MEMBERSHIP_CONFIG_KEYS[k]) {
            hasMembership = true
            anyKnown = true
        } else if (SOFT_CONFIG_KEYS[k]) {
            hasSoft = true
            anyKnown = true
        }
    }
    if (!anyKnown)
        return { impact: null }
    if (hasRediscover)
        return { impact: "rediscover" }
    if (hasMembership)
        return { impact: "membership" }
    // hasSoft must be true here
    return { impact: "soft" }
}

function discoverOnLoadEnabled(config) {
    var v = config && config.discoverOnLoad
    if (v === false || v === "false" || v === 0 || v === "0")
        return false
    return true
}

/**
 * Soft name application: only overwrite when a live override is present.
 * Soft name removal does not revert to default until rediscovery.
 */
function softDisplayName(profile, config) {
    if (!profile)
        return ""
    if (isLegacySingleInstance(config)) {
        var legacyName = (config && config.displayName) || ""
        if (legacyName)
            return legacyName
        return profile.displayName
    }
    var names = parseJsonConfig(config && config.profileDisplayNamesJson, {})
    if (names && profile.id && names[profile.id])
        return names[profile.id]
    return profile.displayName
}

/**
 * configurationChanged: classify keys, rediscover or soft/membership reapply.
 * Rediscover / empty-registry discover preserve current rows until discovery completes.
 */
function configurationChangedTransition(state, event, input) {
    var classification = classifyConfigKeys(event && event.keys)
    if (!classification.impact)
        return resultFor(state, [], false)

    var config = (input && input.config) ? input.config : {}
    var visibility = input && input.visibility
    var nowMs = input && input.nowMs
    var effects = []

    if (classification.impact === "rediscover") {
        effects.push({ type: "discover" })
        // Preserve state until discovery completes (accepted:false → no epoch bump)
        return resultFor(state, effects, false)
    }

    // Membership/soft cannot rebind rows that do not exist yet
    if (!state.profiles || state.profiles.length === 0) {
        if (!discoverOnLoadEnabled(config))
            return resultFor(state, [], false)
        effects.push({ type: "discover" })
        return resultFor(state, effects, false)
    }

    var patchMembership = classification.impact === "membership"
    var rows = []
    var becameEnabled = []

    for (var i = 0; i < state.profiles.length; i++) {
        var p = state.profiles[i]
        if (!p || !p.id)
            continue
        // state already cloneState'd — mutate the clone in place
        p.displayName = softDisplayName(p, config)
        applyVisibilityToRow(p, config, visibility, nowMs, effects)
        if (patchMembership) {
            var wasOn = p.enabled !== false
            var nowOn = isProfileEnabled(p.id, config)
            p.enabled = nowOn
            if (!wasOn && nowOn
                    && (!p.windows || p.windows.length === 0)
                    && !p.loading)
                becameEnabled.push(p.id)
        }
        rows.push(p)
    }

    if (becameEnabled.length)
        effects.push({ type: "refresh", ids: becameEnabled, manual: true })

    return resultFor({ profiles: rows }, effects, true)
}

/**
 * setHidden: shared enablement serialisation + immediate membership + optional refresh.
 */
function setHiddenTransition(state, event, input) {
    var profileId = event && event.profileId ? String(event.profileId) : ""
    if (!profileId)
        return resultFor(state, [], false)

    var idx = findProfileIndex(state.profiles, profileId)
    if (idx < 0)
        return resultFor(state, [], false)

    var config = (input && input.config) ? input.config : {}
    var wantEnabled = !event.hidden

    // Known IDs: current rows + allowlist extras (preserve mid-discover entries)
    var knownIds = []
    var seen = {}
    for (var i = 0; i < state.profiles.length; i++) {
        var pid = state.profiles[i] && state.profiles[i].id
        if (!pid || seen[pid])
            continue
        seen[pid] = true
        knownIds.push(pid)
    }
    var enabledList = parseEnabledList(config && config.enabledProfilesJson)
    for (var e = 0; e < enabledList.length; e++) {
        var eid = enabledList[e]
        if (!eid || eid === "__none__" || seen[eid])
            continue
        seen[eid] = true
        knownIds.push(eid)
    }
    if (!seen[profileId]) {
        knownIds.push(profileId)
        seen[profileId] = true
    }

    var map = materializeEnabledMap(enabledList, knownIds)
    map[profileId] = wantEnabled
    var json = serializeEnabledMap(map, knownIds)

    var target = state.profiles[idx]
    var wasOn = target.enabled !== false
    target.enabled = wantEnabled

    var effects = [{
        type: "persist",
        values: { enabledProfilesJson: json }
    }]

    // Re-enabling an empty/non-loading row emits targeted refresh
    if (!wasOn && wantEnabled
            && (!target.windows || target.windows.length === 0)
            && !target.loading) {
        effects.push({ type: "refresh", ids: [profileId], manual: true })
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
    if (event.type === "discovered")
        return discoveredTransition(state, event, input)
    if (event.type === "configurationChanged")
        return configurationChangedTransition(state, event, input)
    if (event.type === "setHidden")
        return setHiddenTransition(state, event, input)
    return resultFor(state, [], false)
}

// ---------------------------------------------------------------------------
// KCM configuration editing (P1.M3.E1.T003)
// ---------------------------------------------------------------------------

/** Config keys owned by editConfig (cloned; never mutate caller input). */
var EDIT_CONFIG_KEYS = [
    "multiProfileMode", "provider", "opencodeSubProvider", "credentialsPath",
    "displayName", "discoverOnLoad", "enabledProfilesJson",
    "profileDisplayNamesJson", "customProfilesJson", "customProfileNextId",
    "visibleWindowsJson"
]

function cloneEditConfig(config) {
    var out = {}
    var src = config || {}
    for (var i = 0; i < EDIT_CONFIG_KEYS.length; i++) {
        var k = EDIT_CONFIG_KEYS[i]
        if (src.hasOwnProperty(k))
            out[k] = src[k]
    }
    // Ensure keys used by editors always exist with safe defaults
    if (out.enabledProfilesJson === undefined)
        out.enabledProfilesJson = "[]"
    if (out.profileDisplayNamesJson === undefined)
        out.profileDisplayNamesJson = "{}"
    if (out.customProfilesJson === undefined)
        out.customProfilesJson = "[]"
    if (out.customProfileNextId === undefined || out.customProfileNextId === null
            || out.customProfileNextId === "")
        out.customProfileNextId = 0
    else
        out.customProfileNextId = Number(out.customProfileNextId) || 0
    return out
}

function normalizeKnownIds(knownProfiles) {
    var ids = []
    var seen = {}
    var list = knownProfiles || []
    for (var i = 0; i < list.length; i++) {
        var item = list[i]
        var id = item && typeof item === "object" ? item.id : item
        id = id === undefined || id === null ? "" : String(id)
        if (!id || seen[id] || id === "__none__")
            continue
        seen[id] = true
        ids.push(id)
    }
    return ids
}

function parseEnabledList(raw) {
    var enabled = parseJsonConfig(raw, [])
    if (!enabled || !Array.isArray(enabled))
        return []
    return enabled
}

function parseNamesMap(raw) {
    var names = parseJsonConfig(raw, {})
    if (!names || typeof names !== "object" || Array.isArray(names))
        return {}
    var out = {}
    for (var k in names) {
        if (!names.hasOwnProperty(k))
            continue
        if (names[k])
            out[k] = String(names[k])
    }
    return out
}

function parseCustomList(raw) {
    var customs = parseJsonConfig(raw, [])
    if (!customs || !Array.isArray(customs))
        return []
    var out = []
    for (var i = 0; i < customs.length; i++) {
        var e = customs[i]
        if (!e || typeof e !== "object")
            continue
        out.push(cloneObject(e))
    }
    return out
}

/**
 * Materialize id → enabled from allowlist/sentinel against known IDs.
 * [] → all on; ["__none__"] (or empty after filtering) with length>0 raw → all off
 * when the only meaningful sentinel is present; otherwise allowlist membership.
 */
function materializeEnabledMap(enabledList, knownIds) {
    var map = {}
    var list = enabledList || []
    // Empty array = all enabled
    if (!list.length) {
        for (var i = 0; i < knownIds.length; i++)
            map[knownIds[i]] = true
        return map
    }
    var hasNone = false
    var allow = {}
    for (var j = 0; j < list.length; j++) {
        var eid = list[j]
        if (eid === "__none__") {
            hasNone = true
            continue
        }
        if (eid)
            allow[eid] = true
    }
    // Pure sentinel (or only __none__) → all off
    var allowCount = 0
    for (var ak in allow) {
        if (allow.hasOwnProperty(ak))
            allowCount++
    }
    if (hasNone && allowCount === 0) {
        for (var k = 0; k < knownIds.length; k++)
            map[knownIds[k]] = false
        return map
    }
    for (var n = 0; n < knownIds.length; n++)
        map[knownIds[n]] = !!allow[knownIds[n]]
    return map
}

/**
 * Serialise enabled map → [] / ["__none__"] / allowlist.
 * knownIds order is preserved in partial allowlists.
 */
function serializeEnabledMap(enabledMap, knownIds) {
    var list = []
    var allOn = true
    for (var i = 0; i < knownIds.length; i++) {
        var id = knownIds[i]
        if (enabledMap[id])
            list.push(id)
        else
            allOn = false
    }
    if (allOn || knownIds.length === 0)
        return "[]"
    if (list.length === 0)
        return JSON.stringify(["__none__"])
    return JSON.stringify(list)
}

function highestCustomSuffix(customs) {
    // Baseline 0 so first allocation with empty list + nextId 0 yields 1
    // (matches prior KCM customIdSeq default of 1).
    var max = 0
    var list = customs || []
    for (var i = 0; i < list.length; i++) {
        var id = String((list[i] && list[i].id) || "")
        var m = id.match(/-custom-(\d+)$/)
        if (!m)
            continue
        var n = parseInt(m[1], 10)
        if (!isNaN(n) && n > max)
            max = n
    }
    return max
}

function allocateCustomNextId(persistedNextId, customs) {
    var persisted = Number(persistedNextId) || 0
    var highest = highestCustomSuffix(customs)
    return Math.max(persisted, highest + 1)
}

function editConfigResult(config, patch) {
    return {
        config: config,
        patch: patch || {}
    }
}

function setEnabledEdit(config, knownIds, event) {
    var profileId = event && event.profileId ? String(event.profileId) : ""
    if (!profileId)
        return editConfigResult(config, {})

    var ids = knownIds.slice()
    var seen = {}
    for (var i = 0; i < ids.length; i++)
        seen[ids[i]] = true
    if (!seen[profileId]) {
        ids.push(profileId)
        seen[profileId] = true
    }

    var enabledList = parseEnabledList(config.enabledProfilesJson)
    var map = materializeEnabledMap(enabledList, ids)
    map[profileId] = !!event.enabled
    var json = serializeEnabledMap(map, ids)
    config.enabledProfilesJson = json
    return editConfigResult(config, { enabledProfilesJson: json })
}

function setNameEdit(config, event) {
    var profileId = event && event.profileId ? String(event.profileId) : ""
    if (!profileId)
        return editConfigResult(config, {})

    var names = parseNamesMap(config.profileDisplayNamesJson)
    var trimmed = event.name === undefined || event.name === null
        ? ""
        : String(event.name).replace(/^\s+|\s+$/g, "")
    if (trimmed)
        names[profileId] = trimmed
    else
        delete names[profileId]
    var json = JSON.stringify(names)
    config.profileDisplayNamesJson = json
    return editConfigResult(config, { profileDisplayNamesJson: json })
}

function addCustomEdit(config, knownIds, event) {
    var provider = event && event.provider ? String(event.provider) : ""
    var path = event && event.path !== undefined && event.path !== null
        ? String(event.path).replace(/^\s+|\s+$/g, "")
        : ""
    if (!provider || !path)
        return editConfigResult(config, {})

    var customs = parseCustomList(config.customProfilesJson)
    var nextId = allocateCustomNextId(config.customProfileNextId, customs)
    var explicitCred = event.credPath !== undefined && event.credPath !== null
        ? String(event.credPath).replace(/^\s+|\s+$/g, "")
        : ""
    var credPath = explicitCred
        ? explicitCred
        : QC.defaultCredPathForProvider(provider, path)
    var displayName = event.displayName !== undefined && event.displayName !== null
        ? String(event.displayName).replace(/^\s+|\s+$/g, "")
        : ""

    var entry = {
        id: provider + "-custom-" + nextId,
        provider: provider,
        path: path,
        credPath: credPath
    }
    if (displayName)
        entry.displayName = displayName

    customs.push(entry)
    config.customProfilesJson = JSON.stringify(customs)
    config.customProfileNextId = nextId + 1

    var patch = {
        customProfilesJson: config.customProfilesJson,
        customProfileNextId: config.customProfileNextId
    }

    // Seed enablement: when not all-on, force the new custom on
    var ids = knownIds.slice()
    var seen = {}
    for (var i = 0; i < ids.length; i++)
        seen[ids[i]] = true
    if (!seen[entry.id]) {
        ids.push(entry.id)
        seen[entry.id] = true
    }
    // Also include any existing custom ids from the list
    for (var c = 0; c < customs.length; c++) {
        var cid = customs[c] && customs[c].id
        if (cid && !seen[cid]) {
            ids.push(cid)
            seen[cid] = true
        }
    }

    var enabledList = parseEnabledList(config.enabledProfilesJson)
    if (enabledList.length > 0) {
        var map = materializeEnabledMap(enabledList, ids)
        map[entry.id] = true
        var enJson = serializeEnabledMap(map, ids)
        config.enabledProfilesJson = enJson
        patch.enabledProfilesJson = enJson
    }

    if (displayName) {
        var names = parseNamesMap(config.profileDisplayNamesJson)
        names[entry.id] = displayName
        var namesJson = JSON.stringify(names)
        config.profileDisplayNamesJson = namesJson
        patch.profileDisplayNamesJson = namesJson
    }

    return editConfigResult(config, patch)
}

function removeCustomEdit(config, event) {
    var profileId = event && event.profileId ? String(event.profileId) : ""
    if (!profileId)
        return editConfigResult(config, {})

    var customs = parseCustomList(config.customProfilesJson)
    var next = []
    var found = false
    for (var i = 0; i < customs.length; i++) {
        if (customs[i] && customs[i].id === profileId) {
            found = true
            continue
        }
        next.push(customs[i])
    }
    if (!found)
        return editConfigResult(config, {})

    // Never decrement customProfileNextId
    var json = JSON.stringify(next)
    config.customProfilesJson = json
    return editConfigResult(config, { customProfilesJson: json })
}

/**
 * KCM configuration-edit entry point.
 * input: { config, knownProfiles, event }
 * result: { config, patch } — callers write only patch keys to cfg.
 *
 * Events: setEnabled | setName | addCustom | removeCustom
 */
function editConfig(input) {
    var config = cloneEditConfig(input && input.config)
    var knownIds = normalizeKnownIds(input && input.knownProfiles)
    var event = input && input.event ? input.event : {}

    if (event.type === "setEnabled")
        return setEnabledEdit(config, knownIds, event)
    if (event.type === "setName")
        return setNameEdit(config, event)
    if (event.type === "addCustom")
        return addCustomEdit(config, knownIds, event)
    if (event.type === "removeCustom")
        return removeCustomEdit(config, event)
    return editConfigResult(config, {})
}
