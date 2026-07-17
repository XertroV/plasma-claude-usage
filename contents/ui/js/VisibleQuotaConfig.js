.pragma library

/**
 * Pure visible-quota configuration core (I004 / P1.M4.E1.T001–T002).
 *
 * Public seam:
 *   configuration({ persisted, event }) -> { persisted, changed, providers }
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
 *
 * Editor document (private):
 *   { maps: { provider: { windowId: boolean } } }
 */

// ---------------------------------------------------------------------------
// Private: built-in KCM catalogue (order is part of the projection contract)
// ---------------------------------------------------------------------------

// Labels match configGeneral.qml; IDs/defaultVisible match QuotaParsers.js.
var CATALOG = [
    {
        provider: "claude",
        title: "Claude",
        windows: [
            { id: "5h", label: "5h", defaultVisible: true },
            { id: "weekly", label: "7d", defaultVisible: true },
            { id: "weekly_fable", label: "Fable", defaultVisible: false },
            { id: "weekly_oracle", label: "Oracle", defaultVisible: false },
            { id: "weekly_opus", label: "Opus", defaultVisible: false },
            { id: "weekly_sonnet", label: "Sonnet", defaultVisible: false },
            { id: "weekly_oauth_apps", label: "OAuth apps", defaultVisible: false }
        ]
    },
    {
        provider: "codex",
        title: "Codex",
        windows: [
            { id: "session", label: "session", defaultVisible: true },
            { id: "weekly", label: "weekly", defaultVisible: true },
            { id: "credits", label: "credits $", defaultVisible: false },
            { id: "extra_spk_7d", label: "Spark / 7d", defaultVisible: false }
        ]
    },
    {
        provider: "grok",
        title: "Grok",
        windows: [
            { id: "session", label: "session (product %)", defaultVisible: true },
            { id: "weekly", label: "mo ($ allowance)", defaultVisible: true },
            { id: "on_demand", label: "on-demand", defaultVisible: false }
        ]
    },
    {
        provider: "zai",
        title: "Z.ai",
        windows: [
            { id: "session", label: "5h", defaultVisible: true },
            { id: "weekly", label: "mo", defaultVisible: true }
        ]
    },
    {
        provider: "minimax",
        title: "MiniMax",
        windows: [
            { id: "5h/general", label: "5h/general", defaultVisible: true },
            { id: "wk/general", label: "7d/general", defaultVisible: true }
        ]
    },
    {
        provider: "kimi",
        title: "Kimi",
        windows: [
            { id: "session", label: "5h", defaultVisible: true },
            { id: "weekly", label: "7d", defaultVisible: true },
            { id: "total_quota", label: "total quota", defaultVisible: false }
        ]
    }
]

// ---------------------------------------------------------------------------
// Public: KCM configuration projection / edit
// ---------------------------------------------------------------------------

/**
 * Project and optionally edit visible-window configuration for the KCM.
 *
 * Inspection (no event): changed:false, original persisted text, checkbox projection.
 * Supported events: set | resetProvider | resetAll.
 * Writes are never eager — only accepted events return changed:true + serialised form.
 */
function configuration(input) {
    var request = input || {}
    var original = persistedText(request.persisted)
    var editor = editorDocument(decodePersisted(request.persisted))
    if (request.event !== undefined) {
        var edited = applyEditorEvent(editor, request.event)
        if (!edited.accepted)
            return configurationResult(editor, original, false)
        editor = edited.document
        return configurationResult(editor, serializeEditor(editor), true)
    }
    return configurationResult(editor, original, false)
}

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
// Private: editor document, events, serialisation
// ---------------------------------------------------------------------------

function catalogForProvider(provider) {
    for (var i = 0; i < CATALOG.length; i++) {
        if (CATALOG[i].provider === provider)
            return CATALOG[i]
    }
    return null
}

/**
 * Convert private runtime policy into a KCM editor document of per-provider
 * Boolean maps. Reproduces current KCM hydrateVisibleByProvider migration.
 */
function editorDocument(policy) {
    var maps = {}
    if (!policy || typeof policy !== "object")
        return { maps: maps }

    if (policy.mode === "defaults")
        return { maps: maps }

    // Strict global allowlist → full known maps only when provider has a match
    if (policy.mode === "strict") {
        var listIds = policy.ids || {}
        for (var pi = 0; pi < CATALOG.length; pi++) {
            var cat = CATALOG[pi]
            var pm = {}
            var any = false
            for (var wi = 0; wi < cat.windows.length; wi++) {
                var wid = cat.windows[wi].id
                var on = !!listIds[wid]
                pm[wid] = on
                if (on) any = true
            }
            if (any)
                maps[cat.provider] = pm
        }
        return { maps: maps }
    }

    // Sparse global map → matching keys copied sparsely to relevant providers
    if (policy.mode === "overrides") {
        var gm = policy.values || {}
        for (var gi = 0; gi < CATALOG.length; gi++) {
            var gcat = CATALOG[gi]
            var gpm = {}
            var gany = false
            for (var gwi = 0; gwi < gcat.windows.length; gwi++) {
                var gid = gcat.windows[gwi].id
                if (gm.hasOwnProperty(gid)) {
                    gpm[gid] = !!gm[gid]
                    gany = true
                }
            }
            if (gany)
                maps[gcat.provider] = gpm
        }
        return { maps: maps }
    }

    // Per-provider strict / sparse maps (unknown providers retained)
    if (policy.mode === "providers") {
        var bp = policy.byProvider || {}
        for (var prov in bp) {
            if (!bp.hasOwnProperty(prov)) continue
            var entry = bp[prov]
            if (!entry || typeof entry !== "object") continue
            var m = {}
            if (entry.mode === "strict") {
                var ids = entry.ids || {}
                for (var k in ids) {
                    if (!ids.hasOwnProperty(k)) continue
                    if (ids[k]) m[k] = true
                }
                // Materialize missing known IDs as false (unchecked)
                var cat2 = catalogForProvider(prov)
                if (cat2) {
                    for (var ci = 0; ci < cat2.windows.length; ci++) {
                        var cid = cat2.windows[ci].id
                        if (!m.hasOwnProperty(cid))
                            m[cid] = false
                    }
                }
            } else if (entry.mode === "overrides") {
                var values = entry.values || {}
                for (var k2 in values) {
                    if (!values.hasOwnProperty(k2)) continue
                    m[k2] = !!values[k2]
                }
            } else {
                continue
            }
            if (objectKeyCount(m) > 0)
                maps[prov] = m
        }
        return { maps: maps }
    }

    return { maps: maps }
}

/**
 * Apply a KCM edit event to an editor document immutably.
 * Returns { accepted, document? }. Malformed events → accepted:false.
 */
function applyEditorEvent(editor, event) {
    if (!event || typeof event !== "object" || Array.isArray(event))
        return { accepted: false }

    var type = event.type
    if (type === "set") {
        var provider = event.provider
        var windowId = event.windowId
        if (typeof provider !== "string" || !provider)
            return { accepted: false }
        if (windowId === undefined || windowId === null || windowId === "")
            return { accepted: false }

        var maps = cloneEditorMaps(editor.maps)
        var cat = catalogForProvider(provider)
        var m = maps[provider] ? cloneOwn(maps[provider]) : {}

        // First edit for an empty provider map: seed all known catalogue defaults
        if (objectKeyCount(m) === 0 && cat) {
            for (var i = 0; i < cat.windows.length; i++) {
                var w = cat.windows[i]
                m[w.id] = w.defaultVisible !== false
            }
        }
        m[windowId] = !!event.visible

        // Collapse to defaults when every known ID matches and no unknown keys
        if (cat && providerMapMatchesDefaults(m, cat))
            delete maps[provider]
        else
            maps[provider] = m

        return { accepted: true, document: { maps: maps } }
    }

    if (type === "resetProvider") {
        var rp = event.provider
        if (typeof rp !== "string" || !rp)
            return { accepted: false }
        var maps2 = cloneEditorMaps(editor.maps)
        delete maps2[rp]
        return { accepted: true, document: { maps: maps2 } }
    }

    if (type === "resetAll")
        return { accepted: true, document: { maps: {} } }

    return { accepted: false }
}

function providerMapMatchesDefaults(m, cat) {
    if (!cat || !m) return true
    for (var i = 0; i < cat.windows.length; i++) {
        var w = cat.windows[i]
        var def = w.defaultVisible !== false
        if (m.hasOwnProperty(w.id)) {
            if (!!m[w.id] !== def) return false
        }
    }
    // Extra keys not in catalog count as customization
    for (var k in m) {
        if (!m.hasOwnProperty(k)) continue
        var known = false
        for (var j = 0; j < cat.windows.length; j++) {
            if (cat.windows[j].id === k) { known = true; break }
        }
        if (!known) return false
    }
    return true
}

function serializeEditor(editor) {
    var out = {}
    var anyProv = false
    var maps = (editor && editor.maps) ? editor.maps : {}
    for (var prov in maps) {
        if (!maps.hasOwnProperty(prov)) continue
        var m = maps[prov]
        if (!m || typeof m !== "object") continue
        var pm = {}
        var anyKey = false
        for (var k in m) {
            if (!m.hasOwnProperty(k)) continue
            pm[k] = !!m[k]
            anyKey = true
        }
        if (anyKey) {
            out[prov] = pm
            anyProv = true
        }
    }
    return anyProv ? JSON.stringify(out) : "[]"
}

function configurationResult(editor, persisted, changed) {
    var maps = (editor && editor.maps) ? editor.maps : {}
    var providers = []
    for (var i = 0; i < CATALOG.length; i++) {
        var cat = CATALOG[i]
        var map = maps[cat.provider]
        var windows = []
        for (var j = 0; j < cat.windows.length; j++) {
            var w = cat.windows[j]
            var checked
            if (map && map.hasOwnProperty(w.id))
                checked = !!map[w.id]
            else
                checked = w.defaultVisible !== false
            windows.push({
                id: w.id,
                label: w.label,
                checked: checked
            })
        }
        providers.push({
            provider: cat.provider,
            title: cat.title,
            canReset: !!(map && objectKeyCount(map) > 0),
            windows: windows
        })
    }
    return {
        persisted: persisted,
        changed: !!changed,
        providers: providers
    }
}

function cloneEditorMaps(src) {
    var out = {}
    if (!src) return out
    for (var prov in src) {
        if (!src.hasOwnProperty(prov)) continue
        out[prov] = cloneOwn(src[prov])
    }
    return out
}

function persistedText(persisted) {
    if (persisted === undefined || persisted === null)
        return "[]"
    if (typeof persisted === "string")
        return persisted
    try {
        return JSON.stringify(persisted)
    } catch (e) {
        return "[]"
    }
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
 * for column visibility. Order matches the historical OpenCode slot/profile mapping.
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
