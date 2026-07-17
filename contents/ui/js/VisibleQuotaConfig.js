.pragma library

/**
 * Pure visible-quota configuration core (I004 / P1.M4.E1.T001).
 *
 * Public runtime seam:
 *   specFor(profile, persisted) -> opaqueSpec
 *   apply(windows, opaqueSpec)  -> clonedWindows
 *
 * Private policy shapes (not part of the public interface):
 *   { mode: "defaults" }
 *   { mode: "strict", ids: { windowId: true } }
 *   { mode: "overrides", values: { windowId: boolean } }
 *   { mode: "providers", byProvider: { provider: strictOrOverridesPolicy } }
 *
 * Opaque runtime spec:
 *   { provider: string, policy: <policy> }
 */

// ---------------------------------------------------------------------------
// Public: runtime
// ---------------------------------------------------------------------------

/**
 * Build an opaque visibility spec for one profile from persisted JSON/text.
 * Callers may only retain the result and pass it to apply().
 */
function specFor(profile, persisted) {
    var policy = decodePersisted(persisted)
    return {
        provider: canonicalProvider(profile),
        policy: policy
    }
}

/**
 * Apply an opaque visibility spec to a windows array.
 * Returns shallow clones with recalculated `visible`. Does not mutate input.
 * Foreign / invalid specs are treated as defaults without property inspection.
 */
function apply(windows, spec) {
    if (!Array.isArray(windows)) return []
    var usable = validSpec(spec) ? spec : {
        provider: "",
        policy: defaultsPolicy()
    }
    var selected = policyForProvider(usable.policy, usable.provider)
    var out = []
    for (var i = 0; i < windows.length; i++) {
        var source = windows[i]
        if (!source || typeof source !== "object" || Array.isArray(source))
            continue
        var copy = cloneOwn(source)
        copy.visible = effectiveVisible(source, selected)
        out.push(copy)
    }
    return out
}

// ---------------------------------------------------------------------------
// Private: policy model
// ---------------------------------------------------------------------------

function defaultsPolicy() {
    return { mode: "defaults" }
}

/**
 * True if value looks like a per-window bool map (not an array / not nested
 * provider map). Nested provider maps have object values; window maps have
 * boolean (or scalar) values.
 */
function isWindowBoolMap(obj) {
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return false
    var saw = false
    for (var k in obj) {
        if (!obj.hasOwnProperty(k)) continue
        saw = true
        var v = obj[k]
        if (typeof v === "object" && v !== null) return false
    }
    return saw
}

function objectKeyCount(obj) {
    var n = 0
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return 0
    for (var k in obj) {
        if (obj.hasOwnProperty(k)) n++
    }
    return n
}

/**
 * Convert a flat window map into strict (when __allowlist) or sparse overrides.
 * __allowlist is never retained on the private policy.
 */
function mapToPolicy(map) {
    if (!map || typeof map !== "object") return defaultsPolicy()
    if (map.__allowlist) {
        var ids = {}
        for (var k in map) {
            if (!map.hasOwnProperty(k) || k === "__allowlist") continue
            if (map[k]) ids[k] = true
        }
        return { mode: "strict", ids: ids }
    }
    var values = {}
    var any = false
    for (var k2 in map) {
        if (!map.hasOwnProperty(k2) || k2 === "__allowlist") continue
        values[k2] = !!map[k2]
        any = true
    }
    if (!any) return defaultsPolicy()
    return { mode: "overrides", values: values }
}

/**
 * Decode visibleWindowsJson (string or already-parsed) into a private policy.
 *
 * Forms (exact runtime meaning preserved from QuotaCommon):
 *  - null/undefined/""/[]/{}  → defaults
 *  - ["5h","weekly"]          → strict global allowlist
 *  - {"5h":true,"weekly":false} → sparse global overrides
 *  - {"claude":{"weekly":false}} → per-provider sparse
 *  - {"claude":["5h"]}        → per-provider strict
 * Invalid JSON / unsupported roots fall back to defaults without throwing.
 */
function decodePersisted(persisted) {
    if (persisted === undefined || persisted === null || persisted === "")
        return defaultsPolicy()

    var parsed = persisted
    if (typeof persisted === "string") {
        var s = persisted.trim()
        if (!s || s === "[]" || s === "{}") return defaultsPolicy()
        try {
            parsed = JSON.parse(s)
        } catch (e) {
            return defaultsPolicy()
        }
    }

    if (Array.isArray(parsed)) {
        if (!parsed.length) return defaultsPolicy()
        var ids = {}
        for (var i = 0; i < parsed.length; i++)
            ids[parsed[i]] = true
        return { mode: "strict", ids: ids }
    }

    if (!parsed || typeof parsed !== "object")
        return defaultsPolicy()

    // Flat window map applied to all providers
    if (isWindowBoolMap(parsed)) {
        if (objectKeyCount(parsed) === 0) return defaultsPolicy()
        return mapToPolicy(parsed)
    }

    // Per-provider maps / arrays
    var byProvider = {}
    var any = false
    for (var prov in parsed) {
        if (!parsed.hasOwnProperty(prov)) continue
        var entry = parsed[prov]
        if (entry === undefined || entry === null) continue
        if (Array.isArray(entry)) {
            if (!entry.length) continue
            var pIds = {}
            for (var j = 0; j < entry.length; j++)
                pIds[entry[j]] = true
            byProvider[prov] = { mode: "strict", ids: pIds }
            any = true
        } else if (typeof entry === "object") {
            if (objectKeyCount(entry) === 0) continue
            byProvider[prov] = mapToPolicy(entry)
            any = true
        }
        // non-object nested scalars ignored
    }
    if (!any) return defaultsPolicy()
    return { mode: "providers", byProvider: byProvider }
}

/**
 * Map profile.provider (+ OpenCode slot / profileKey) to the config key used
 * for column visibility. Order matches existing QuotaCommon.visibilityProviderKey.
 */
function canonicalProvider(profile) {
    var provider = ""
    var slot = ""
    var profileKey = ""
    if (profile && typeof profile === "object") {
        provider = profile.provider || ""
        slot = profile.opencodeSlot || ""
        profileKey = profile.profileKey || ""
    }
    if (provider !== "opencode")
        return provider

    if (!slot && profileKey) {
        var pk = String(profileKey)
        if (pk.indexOf("anthropic") >= 0) slot = "anthropic"
        else if (pk.indexOf("openai") >= 0 || pk.indexOf("codex") >= 0) slot = "openai"
        else if (pk.indexOf("kimi") >= 0) slot = "kimi"
        else if (pk.indexOf("zai") >= 0 || pk.indexOf("z-ai") >= 0) slot = "zai"
    }
    if (!slot) slot = "anthropic"
    if (slot === "openai") return "codex"
    if (slot === "anthropic") return "claude"
    if (slot === "kimi") return "kimi"
    if (slot === "zai") return "zai"
    return "opencode"
}

function policyForProvider(policy, provider) {
    if (!policy || typeof policy !== "object")
        return defaultsPolicy()
    if (policy.mode === "defaults")
        return policy
    if (policy.mode === "strict" || policy.mode === "overrides")
        return policy
    if (policy.mode === "providers") {
        var selected = policy.byProvider && policy.byProvider[provider]
        if (!selected || typeof selected !== "object")
            return defaultsPolicy()
        return selected
    }
    return defaultsPolicy()
}

/**
 * Effective visibility for one window under a selected (non-providers) policy.
 * Ignores any incoming window.visible; defaults use defaultVisible !== false.
 */
function effectiveVisible(source, selected) {
    var def = source.defaultVisible !== false
    if (!selected || typeof selected !== "object" || selected.mode === "defaults")
        return def
    if (selected.mode === "strict") {
        var ids = selected.ids
        if (!ids || typeof ids !== "object") return false
        return !!ids[source.id]
    }
    if (selected.mode === "overrides") {
        var values = selected.values
        if (!values || typeof values !== "object") return def
        // Explicit override (including false); missing keys keep defaultVisible
        if (values[source.id] !== undefined)
            return !!values[source.id]
        return def
    }
    return def
}

function validSpec(spec) {
    if (!spec || typeof spec !== "object" || Array.isArray(spec))
        return false
    if (typeof spec.provider !== "string")
        return false
    var policy = spec.policy
    if (!policy || typeof policy !== "object" || Array.isArray(policy))
        return false
    var m = policy.mode
    return m === "defaults" || m === "strict"
        || m === "overrides" || m === "providers"
}

function cloneOwn(source) {
    var copy = {}
    for (var k in source) {
        if (source.hasOwnProperty(k))
            copy[k] = source[k]
    }
    return copy
}
