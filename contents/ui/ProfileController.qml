import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support
import "js/QuotaCommon.js" as QC
import "js/QuotaParsers.js" as QP
import "js/VisibleQuotaConfig.js" as VQ
import "js/ProfileRefresh.js" as ProfileRefresh
import "js/ProfileRegistry.js" as Registry

Item {
    id: controller

    property var plasmoid
    property var i18n
    property var profiles: []
    // Safe 12-field public snapshots for views (built by registry; no secrets)
    property var publicProfileList: []
    property bool discovering: false
    // User-visible discovery failure (parse/exit/path); empty when OK (B017)
    property string discoveryError: ""
    property string lastGlobalUpdate: ""
    // Must be double/real — QML int is 32-bit and overflows Date.now() (~1.7e12)
    property double nowMs: Date.now()
    // Bumped on every profile mutation so UI can re-sync reliably
    property int dataEpoch: 0

    // Staggered refresh queue: [{ id, manual }, ...] — used by refresh-all and autoRefresh (B002)
    property var refreshQueue: []
    // Monotonic fetch generation — never reset on merge, so stale XHR cannot collide (B008)
    property int nextFetchGen: 1
    // Resolved $HOME for safe path expansion (B006) — never trust user path in shell
    property string homeDir: ""
    property bool homeReady: false

    // Auth cool-down between auto retries after OAuth/401 failures (B029)
    readonly property int authRetryHoldMs: 5 * 60 * 1000
    // Absolute ceiling for 429-backed refresh interval (B013)
    readonly property int maxBackoffIntervalMs: 60 * 60 * 1000
    // Auto auth failures before suspending usage API until token change or manual (B029)
    readonly property int maxAuthAutoAttempts: 2
    // Max concurrent credential cat processes (B001: parallel OK when keyed by sourceName)
    readonly property int maxCredInflight: 3

    function allocFetchGen() {
        var g = nextFetchGen
        nextFetchGen = g + 1
        return g
    }

    Component.onCompleted: {
        // Fixed command — no user input (B006)
        homeProbe.connectSource("printf %s \"$HOME\"")
    }

    readonly property string discoverScript: {
        var u = Qt.resolvedUrl("../scripts/discover-profiles.sh").toString()
        if (u.indexOf("file://") === 0) return u.substring(7)
        return u
    }

    function tr(text) { return i18n ? i18n.tr(text) : text }

    function cfgValue(key, fallback) {
        if (!plasmoid || !plasmoid.configuration) return fallback
        var v = plasmoid.configuration[key]
        return (v === undefined || v === null) ? fallback : v
    }

    function parseJsonConfig(raw, fallback) {
        if (!raw || raw === "") return fallback
        try { return JSON.parse(raw) } catch (e) { return fallback }
    }

    function normalizePath(path) {
        if (!path) return ""
        var p = QC.expandUserPath(path)
        if (p.indexOf("/.claude/") >= 0 || p.indexOf("/.claude-") >= 0
                || p.indexOf("$HOME/.claude/") >= 0 || p.indexOf("$HOME/.claude-") >= 0) {
            p = p.replace(/\/\.credentials\.json$/, "")
        }
        return p
    }

    function pathsEqual(a, b) {
        return QC.pathsEqual(a, b)
    }

    /**
     * Multi-profile dashboard is the default (B004).
     * Legacy single-profile mode only when multiProfileMode is explicitly false.
     * (Old trap: any credentialsPath / displayName / non-claude provider forced legacy.)
     */
    function isLegacySingleInstance() {
        var multi = cfgValue("multiProfileMode", true)
        // Kcfg bool may arrive as string in some Plasma paths
        if (multi === false || multi === "false" || multi === 0 || multi === "0")
            return true
        return false
    }

    function legacyProfileMatches(meta) {
        var credPath = cfgValue("credentialsPath", "")
        if (credPath) return pathsEqual(meta.credPath, credPath)

        var provider = cfgValue("provider", "claude")
        if (provider === "opencode") {
            var sub = cfgValue("opencodeSubProvider", "anthropic")
            if (sub === "kimi") return meta.provider === "kimi"
            if (sub === "zai") return meta.provider === "zai"
            if (sub === "openai") return meta.provider === "codex"
            if (sub === "anthropic") {
                return meta.provider === "claude"
                    || (meta.provider === "opencode" && meta.profileKey === "anthropic-accounts")
            }
            return meta.provider === "opencode"
        }
        if (provider === "claude") return meta.provider === "claude"
        return meta.provider === provider
    }

    function filterDiscoveredProfiles(discovered) {
        if (!isLegacySingleInstance()) return discovered
        var out = []
        for (var i = 0; i < discovered.length; i++) {
            if (legacyProfileMatches(discovered[i])) out.push(discovered[i])
        }
        // B004: legacy is single-profile — if no credentialsPath, keep one canonical match
        if (out.length > 1 && !cfgValue("credentialsPath", "")) {
            out.sort(function(a, b) {
                var pa = String(a.credPath || a.configDir || "")
                var pb = String(b.credPath || b.configDir || "")
                if (pa.length !== pb.length) return pa.length - pb.length
                return pa < pb ? -1 : (pa > pb ? 1 : 0)
            })
            out = [out[0]]
        }
        return out
    }

    function profileDisplayName(meta) {
        if (isLegacySingleInstance()) {
            var legacyName = cfgValue("displayName", "")
            if (legacyName) return legacyName
        }
        var names = parseJsonConfig(cfgValue("profileDisplayNamesJson", "{}"), {})
        if (names[meta.id]) return names[meta.id]
        return QC.defaultProfileLabel(meta.provider, meta.profileKey)
    }

    function isProfileEnabled(meta) {
        var id = meta && typeof meta === "object" ? meta.id : meta
        if (!id) return true
        var enabled = parseJsonConfig(cfgValue("enabledProfilesJson", "[]"), [])
        if (!enabled || enabled.length === 0) return true
        return enabled.indexOf(id) >= 0
    }

    /**
     * Hide/show a profile on the panel (B032). Persists via enabledProfilesJson
     * (same allowlist as KCM "On" checkboxes). Empty JSON = all visible.
     * Immediate in-memory patch for snappy UI; config watch re-merges membership.
     */
    function setProfileHidden(profileId, hidden) {
        if (!profileId || !plasmoid || !plasmoid.configuration) return

        var enabledList = parseJsonConfig(cfgValue("enabledProfilesJson", "[]"), [])
        if (!Array.isArray(enabledList)) enabledList = []

        var allIds = []
        var seen = {}
        for (var i = 0; i < profiles.length; i++) {
            var pid = profiles[i] && profiles[i].id
            if (!pid || seen[pid]) continue
            seen[pid] = true
            allIds.push(pid)
        }
        // Preserve allowlist entries not currently loaded (e.g. mid-discover)
        for (var e = 0; e < enabledList.length; e++) {
            var eid = enabledList[e]
            if (!eid || eid === "__none__" || seen[eid]) continue
            seen[eid] = true
            allIds.push(eid)
        }
        if (!seen[profileId]) {
            allIds.push(profileId)
            seen[profileId] = true
        }

        var currentlyAllOn = enabledList.length === 0
        var wantOn = {}
        for (var a = 0; a < allIds.length; a++) {
            var id = allIds[a]
            wantOn[id] = currentlyAllOn ? true : (enabledList.indexOf(id) >= 0)
        }
        wantOn[profileId] = !hidden

        var next = []
        var anyOff = false
        for (var k = 0; k < allIds.length; k++) {
            var kid = allIds[k]
            if (wantOn[kid])
                next.push(kid)
            else
                anyOff = true
        }

        // Empty allowlist means "all on" — if every profile is hidden, use a
        // sentinel so isProfileEnabled stays false until something is re-enabled.
        var json
        if (!anyOff)
            json = "[]"
        else if (next.length === 0)
            json = JSON.stringify(["__none__"])
        else
            json = JSON.stringify(next)

        var idx = findProfileIndex(profileId)
        if (idx >= 0)
            updateProfile(idx, { enabled: !hidden })

        if (String(plasmoid.configuration.enabledProfilesJson || "") !== json)
            plasmoid.configuration.enabledProfilesJson = json
    }

    /**
     * Production visibility adapter for I003 ProfileRegistry.
     * Opaque specs from VisibleQuotaConfig; time percentages stay outside VQ.
     */
    function registryVisibilityAdapter() {
        return {
            specFor: function(profile, persisted) {
                return VQ.specFor(profile, persisted)
            },
            apply: function(windows, spec, nowMs) {
                var projected = VQ.apply(windows, spec)
                for (var i = 0; i < projected.length; i++)
                    QC.updateTimePercent(projected[i], nowMs)
                return projected
            }
        }
    }

    /**
     * Exact kcfg snapshot consumed by ProfileRegistry.transition / editConfig.
     * Always re-read live configuration (never cache visibleWindowsJson policy).
     */
    function registryConfigSnapshot() {
        return {
            multiProfileMode: cfgValue("multiProfileMode", true),
            provider: cfgValue("provider", "claude"),
            opencodeSubProvider: cfgValue("opencodeSubProvider", "anthropic"),
            credentialsPath: cfgValue("credentialsPath", ""),
            displayName: cfgValue("displayName", ""),
            discoverOnLoad: cfgValue("discoverOnLoad", true),
            enabledProfilesJson: cfgValue("enabledProfilesJson", "[]"),
            profileDisplayNamesJson: cfgValue("profileDisplayNamesJson", "{}"),
            customProfilesJson: cfgValue("customProfilesJson", "[]"),
            customProfileNextId: cfgValue("customProfileNextId", 0),
            visibleWindowsJson: cfgValue("visibleWindowsJson", "[]")
        }
    }

    /**
     * Single registry result adapter: assign internal/public arrays once on
     * accepted state change, then interpret effects (discover/refresh/persist/warning).
     */
    function applyRegistryResult(result) {
        if (!result)
            return false
        if (result.accepted) {
            if (result.state && result.state.profiles)
                profiles = result.state.profiles
            publicProfileList = result.publicProfiles || []
            dataEpoch++
        }
        var effects = result.effects || []
        for (var i = 0; i < effects.length; i++) {
            var effect = effects[i]
            if (!effect || !effect.type)
                continue
            switch (effect.type) {
            case "discover":
                discoverProfiles()
                break
            case "refreshAll":
                staggerRefreshAll()
                break
            case "refresh":
                var ids = effect.ids || []
                for (var j = 0; j < ids.length; j++) {
                    if (ids[j])
                        queueProfileRefresh(ids[j], effect.manual !== false)
                }
                kickRefreshQueue()
                break
            case "persist":
                if (effect.values && plasmoid && plasmoid.configuration) {
                    var vals = effect.values
                    for (var key in vals) {
                        if (!vals.hasOwnProperty(key))
                            continue
                        // Only assign keys the configuration object actually owns
                        if (plasmoid.configuration[key] !== undefined)
                            plasmoid.configuration[key] = vals[key]
                    }
                }
                break
            case "warning":
                console.log("Claude Usage: registry warning",
                            effect.code || "", effect.profileId || "")
                break
            }
        }
        return !!result.accepted
    }

    /** Rebuild publicProfileList from the current internal profiles store. */
    function syncPublicProfileList() {
        publicProfileList = Registry.publicProfiles({ profiles: profiles })
    }

    /**
     * Stable ID patch through the registry (optional generation precondition).
     * Rejects patches that carry windows — those must use usageResult.
     */
    function registryPatch(profileId, patch, expectedGeneration) {
        if (!profileId || !patch)
            return false
        var event = {
            type: "patch",
            profileId: profileId,
            patch: patch
        }
        if (expectedGeneration !== undefined && expectedGeneration !== null)
            event.expectedGeneration = expectedGeneration
        return applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: event,
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))
    }

    function refreshIntervalMs(provider) {
        if (provider === "claude") {
            var cm = cfgValue("claudeRefreshMinutes", 15)
            if (cm < 10) cm = 10
            return cm * 60000
        }
        return cfgValue("refreshInterval", 5) * 60000
    }

    function bootstrapLegacyProfiles() {
        if (!isLegacySingleInstance() || profiles.length > 0) return

        var credPath = cfgValue("credentialsPath", "")
        var provider = cfgValue("provider", "claude")
        var effectiveProvider = provider
        var isFlat = false

        if (credPath) {
            if (credPath.indexOf("/.kimi-for-coding") >= 0 || credPath.indexOf("/.api-zai") >= 0
                    || credPath.indexOf("/.minimax") >= 0) {
                isFlat = true
            }
            if (provider === "opencode") {
                var subCfg = cfgValue("opencodeSubProvider", "anthropic")
                if (subCfg === "kimi") effectiveProvider = "kimi"
                else if (subCfg === "zai") effectiveProvider = "zai"
                else if (subCfg === "openai") effectiveProvider = "codex"
                else if (subCfg === "anthropic") effectiveProvider = "claude"
            }
            mergeDiscovered([{
                id: "legacy-config",
                provider: effectiveProvider,
                profileKey: "legacy",
                configDir: "",
                credPath: credPath,
                credInode: "legacy-config",
                isFlatFile: isFlat
            }])
            return
        } else if (provider === "codex") {
            credPath = "$HOME/.codex/auth.json"
        } else if (provider === "zai") {
            // Parity with pre-refactor + OpenCode layout (not a bare ~/.api-zai file)
            credPath = "$HOME/.local/share/opencode/auth.json"
            isFlat = false
            effectiveProvider = "zai"
        } else if (provider === "opencode") {
            var sub = cfgValue("opencodeSubProvider", "anthropic")
            if (sub === "kimi") {
                credPath = "$HOME/.kimi-for-coding"
                isFlat = true
                effectiveProvider = "kimi"
            } else if (sub === "zai") {
                credPath = "$HOME/.local/share/opencode/auth.json"
                isFlat = false
                effectiveProvider = "zai"
            } else if (sub === "openai") {
                credPath = "$HOME/.codex/auth.json"
                effectiveProvider = "codex"
            } else if (sub === "anthropic") {
                credPath = "$HOME/.config/opencode/anthropic-accounts.json"
                effectiveProvider = "claude"
            } else {
                credPath = "$HOME/.local/share/opencode/auth.json"
            }
        } else if (provider === "grok") {
            // Prefer default grok path; discovery/filter will match grok-N when present
            credPath = "$HOME/.grok/auth.json"
            effectiveProvider = "grok"
        } else {
            return
        }

        mergeDiscovered([{
            id: "legacy-bootstrap",
            provider: effectiveProvider,
            profileKey: "legacy",
            configDir: "",
            credPath: credPath,
            credInode: "legacy-bootstrap",
            isFlatFile: isFlat
        }])
    }

    function discoverProfiles() {
        discovering = true
        discoveryError = ""
        discoverSource.connectSource("bash " + shellQuote(discoverScript))
    }

    /** Set discoveryError from exit/stderr and stop the discovering spinner (B017). */
    function failDiscovery(shortMsg, exitCode, stderr) {
        var snip = String(stderr || "").replace(/\s+/g, " ").trim()
        if (snip.length > 120)
            snip = snip.substring(0, 117) + "..."
        var msg = shortMsg || "Discovery failed"
        // Common install/runtime hints when stderr is unhelpful
        if (!snip) {
            if (exitCode === 127)
                snip = "command not found"
            else if (exitCode && exitCode !== 0)
                snip = "exit " + exitCode
        }
        discoveryError = snip ? (msg + ": " + snip) : msg
        discovering = false
        dataEpoch++
        console.log("Claude Usage: discovery failed —", discoveryError)
    }

    function resolveCustomCredPath(entry) {
        if (!entry) return ""
        if (entry.credPath)
            return entry.credPath
        // B009: path is often a config *directory* — resolve auth file by provider
        return QC.defaultCredPathForProvider(entry.provider, entry.path)
    }

    function blankProfileRow(meta, visSpec) {
        return {
            id: meta.id,
            provider: meta.provider,
            profileKey: meta.profileKey || "",
            configDir: meta.configDir || "",
            credPath: meta.credPath || "",
            isFlatFile: !!meta.isFlatFile,
            displayName: profileDisplayName(meta),
            enabled: true,
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
            usageFetchGen: 0,
            // Generic refresh generation for ProfileRefresh transaction (I002)
            refreshGeneration: 0,
            backoffMultiplier: 1,
            lastFetchMs: 0,
            authFailCount: 0,
            authSuspended: false,
            autoRefreshHoldUntilMs: 0,
            lastFailedToken: "",
            credLoadManual: false,
            visibleWindowSpec: visSpec === undefined ? null : visSpec
        }
    }

    function mergeDiscovered(discovered) {
        var custom = parseJsonConfig(cfgValue("customProfilesJson", "[]"), [])
        var merged = filterDiscoveredProfiles(discovered.slice())
        if (merged.length === 0 && isLegacySingleInstance()) {
            var legacyCred = cfgValue("credentialsPath", "")
            if (legacyCred) {
                merged.push({
                    id: "legacy-" + cfgValue("provider", "claude"),
                    provider: cfgValue("provider", "claude"),
                    profileKey: "legacy",
                    configDir: "",
                    credPath: legacyCred,
                    credInode: "legacy",
                    isFlatFile: false
                })
            }
        }
        // Customs are multi-profile only (B004) — legacy single stays one row
        if (!isLegacySingleInstance()) {
            for (var c = 0; c < custom.length; c++) {
                var entry = custom[c]
                if (!entry || !entry.path || !entry.provider) continue
                var resolvedCred = resolveCustomCredPath(entry)
                var isFlat = !!entry.isFlatFile
                if (entry.provider === "kimi" && resolvedCred === entry.path)
                    isFlat = true
                merged.push({
                    id: entry.id || (entry.provider + "-custom-" + c),
                    provider: entry.provider,
                    profileKey: entry.profileKey || "custom",
                    configDir: entry.path,
                    credPath: resolvedCred,
                    credInode: "custom:" + (entry.id || c),
                    isFlatFile: isFlat,
                    // Prefer explicit entry.displayName when no cfg rename
                    displayNameHint: entry.displayName || ""
                })
            }
        }

        // Live visibility snapshot for this reconciliation (B034 / I004)
        var visAdapter = registryVisibilityAdapter()
        var rawVis = cfgValue("visibleWindowsJson", "[]")
        // Preserve fetch/auth state across rediscover / config reapply (B003)
        var prevById = {}
        for (var pi = 0; pi < profiles.length; pi++) {
            if (profiles[pi] && profiles[pi].id)
                prevById[profiles[pi].id] = profiles[pi]
        }

        var rows = []
        for (var i = 0; i < merged.length; i++) {
            var meta = merged[i]
            // Keep hidden (disabled) profiles in the list with enabled:false so the
            // details page can unhide them without a full rediscover (B032).
            var rowVis = visAdapter.specFor(meta, rawVis)
            var row = blankProfileRow(meta, rowVis)
            row.enabled = isProfileEnabled(meta)
            if (meta.displayNameHint && row.displayName === QC.defaultProfileLabel(meta.provider, meta.profileKey))
                row.displayName = meta.displayNameHint
            var prev = prevById[meta.id]
            if (prev) {
                // Keep live usage + auth; refresh labels / visibility from config
                var keepKeys = [
                    "loading", "error", "planName", "bankedResets", "windows",
                    "lastUpdate", "accessToken", "accountId", "resourceUrl",
                    "opencodeSlot", "usageFetchGen", "refreshGeneration",
                    "backoffMultiplier", "lastFetchMs",
                    "authFailCount", "authSuspended", "autoRefreshHoldUntilMs",
                    "lastFailedToken", "credLoadManual"
                ]
                for (var ki = 0; ki < keepKeys.length; ki++) {
                    var k = keepKeys[ki]
                    if (prev[k] !== undefined)
                        row[k] = Array.isArray(prev[k]) ? prev[k].slice() : prev[k]
                }
                // Re-apply window visibility from live config (B034 / I004 seam)
                row.visibleWindowSpec = visAdapter.specFor(row, rawVis)
                if (row.windows && row.windows.length)
                    row.windows = visAdapter.apply(row.windows, row.visibleWindowSpec, nowMs)
            }
            rows.push(row)
        }
        profiles = rows
        syncPublicProfileList()
        discoveryError = ""
        discovering = false
        dataEpoch++
        console.log("Claude Usage: merged", rows.length, "profile(s)")
        // Only kick fetches for enabled rows that still need data
        var needFetch = false
        for (var ri = 0; ri < rows.length; ri++) {
            if (rows[ri].enabled === false) continue
            if (!rows[ri].windows || rows[ri].windows.length === 0) {
                needFetch = true
                break
            }
        }
        if (needFetch || rows.length === 0)
            staggerRefreshAll()
        else {
            // Ensure empty new rows still load
            for (var rj = 0; rj < rows.length; rj++) {
                if (rows[rj].enabled === false) continue
                if (!rows[rj].windows || rows[rj].windows.length === 0)
                    queueProfileRefresh(rows[rj].id, true)
            }
            kickRefreshQueue()
        }
    }

    /**
     * Re-apply config after KCM Apply (B003) or details Hidden toggle (B032).
     * - rediscover: full discoverProfiles (merge preserves fetch state)
     * - membership: re-read enabled flags on current rows; rediscover only if empty
     * - soft: names + window visibility only on current rows
     */
    function reapplyConfig(opts) {
        opts = opts || {}
        if (opts.rediscover || opts.forceFull) {
            console.log("Claude Usage: reapplyConfig → rediscover")
            if (isLegacySingleInstance() && profiles.length === 0)
                bootstrapLegacyProfiles()
            discoverProfiles()
            return
        }

        if (profiles.length === 0) {
            if (isLegacySingleInstance())
                bootstrapLegacyProfiles()
            if (cfgValue("discoverOnLoad", true) !== false)
                discoverProfiles()
            return
        }

        // Soft (+ optional membership): names, window visibility, and enabled flags.
        // Membership is in-place so Hidden can toggle without a full rediscover (B032).
        // Always apply soft fields so multi-key Apply (On + rename) does not drop names.
        // B034/I004: live visibility snapshot — not a stale global list or cached policy.
        var visAdapter = registryVisibilityAdapter()
        var rawVis = cfgValue("visibleWindowsJson", "[]")
        var names = parseJsonConfig(cfgValue("profileDisplayNamesJson", "{}"), {})
        var patchMembership = !!opts.membership
        var rows = []
        var becameEnabled = []
        for (var j = 0; j < profiles.length; j++) {
            var p = profiles[j]
            if (!p || !p.id) continue
            var copy = cloneProfile(p)
            if (isLegacySingleInstance()) {
                var legacyName = cfgValue("displayName", "")
                if (legacyName) copy.displayName = legacyName
            } else if (names && names[p.id]) {
                copy.displayName = names[p.id]
            }
            // else keep existing displayName (custom displayNameHint / prior label)
            copy.visibleWindowSpec = visAdapter.specFor(copy, rawVis)
            if (copy.windows && copy.windows.length)
                copy.windows = visAdapter.apply(copy.windows, copy.visibleWindowSpec, nowMs)
            if (patchMembership) {
                var wasOn = p.enabled !== false
                var nowOn = isProfileEnabled(p.id)
                copy.enabled = nowOn
                if (!wasOn && nowOn
                        && (!copy.windows || copy.windows.length === 0)
                        && !copy.loading)
                    becameEnabled.push(copy.id)
            }
            rows.push(copy)
        }

        profiles = rows
        syncPublicProfileList()
        dataEpoch++
        console.log("Claude Usage: reapplyConfig",
                    patchMembership ? "membership+soft" : "soft",
                    "patched", rows.length, "profile(s)")
        if (patchMembership && becameEnabled.length) {
            for (var bi = 0; bi < becameEnabled.length; bi++)
                queueProfileRefresh(becameEnabled[bi], true)
            kickRefreshQueue()
        }
    }

    function findProfileIndex(id) {
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i].id === id) return i
        }
        return -1
    }

    function cloneProfile(src) {
        var p = {}
        if (!src) return p
        for (var k in src) {
            if (!src.hasOwnProperty(k)) continue
            // Shallow-copy arrays so windows/list fields get a new reference
            if (Array.isArray(src[k])) p[k] = src[k].slice()
            else p[k] = src[k]
        }
        return p
    }

    /**
     * Keys kept only on controller.profiles for API auth / fetch state (B012).
     * Never copy these into UI-facing profileList / CardsView / DetailWindow trees.
     */
    function isUiSecretKey(k) {
        return k === "accessToken"
            || k === "accountId"
            || k === "resourceUrl"
            || k === "lastFailedToken"
    }

    /**
     * Deep-enough UI snapshot of one profile: new object + window shells, no secrets.
     * Fetch still uses controller.profiles (with tokens) via refreshProfile(id).
     */
    function toUiProfile(src) {
        var row = {}
        if (!src) return row
        for (var ck in src) {
            if (!src.hasOwnProperty(ck)) continue
            if (isUiSecretKey(ck)) continue
            if (ck === "windows" && Array.isArray(src[ck])) {
                var wcopy = []
                for (var wi = 0; wi < src[ck].length; wi++) {
                    var ww = {}
                    var sw = src[ck][wi]
                    if (sw) {
                        for (var wk in sw) {
                            if (sw.hasOwnProperty(wk)) ww[wk] = sw[wk]
                        }
                    }
                    wcopy.push(ww)
                }
                row[ck] = wcopy
            } else if (Array.isArray(src[ck])) {
                row[ck] = src[ck].slice()
            } else {
                row[ck] = src[ck]
            }
        }
        return row
    }

    /**
     * Full UI-facing list (no tokens / account ids / raw API bodies).
     * Prefers the prebuilt registry publicProfileList; falls back to allowlist projection.
     */
    function publicProfiles() {
        if (publicProfileList && publicProfileList.length)
            return publicProfileList
        return Registry.publicProfiles({ profiles: profiles })
    }

    /**
     * Patch one profile by mutable array index → stable ID via registry.
     * Windows cannot be smuggled through this path (registry rejects them).
     */
    function updateProfile(idx, patch) {
        if (idx < 0 || idx >= profiles.length || !patch) return
        var p = profiles[idx]
        if (!p || !p.id) return
        // Index-only fields (legacy Grok dual-fetch scratch) may not be on the
        // registry schema; still apply via registry patch (opaque extra keys).
        registryPatch(p.id, patch)
    }

    function loadingStats() {
        var total = 0
        var done = 0
        var loading = 0
        for (var i = 0; i < profiles.length; i++) {
            var p = profiles[i]
            if (!p || p.enabled === false) continue
            total++
            if (p.loading)
                loading++
            else if (p.error || (p.windows && p.windows.length) || p.lastFetchMs)
                done++
        }
        return { total: total, done: done, loading: loading }
    }

    function effectiveRefreshIntervalMs(p) {
        var base = refreshIntervalMs(p.provider)
        var mult = p.backoffMultiplier || 1
        return Math.min(base * mult, maxBackoffIntervalMs)
    }

    function isAutoRefreshHeld(p, now) {
        if (!p) return true
        // Hold only — authSuspended still allows credential re-read so a rotated
        // token can resume without a manual click (B029). Usage API is gated later.
        if (p.autoRefreshHoldUntilMs && now < p.autoRefreshHoldUntilMs) return true
        return false
    }

    function queueProfileRefresh(profileId, manual) {
        if (!profileId) return
        var q = refreshQueue.slice()
        for (var i = 0; i < q.length; i++) {
            if (q[i].id === profileId) {
                if (manual)
                    q[i] = { id: profileId, manual: true }
                refreshQueue = q
                return
            }
        }
        q.push({ id: profileId, manual: !!manual })
        refreshQueue = q
    }

    function kickRefreshQueue() {
        if (refreshQueue.length === 0) return
        if (staggerRefresh.running) return
        // First item immediately; remainder every stagger interval (B002)
        if (drainOneRefresh() && refreshQueue.length > 0)
            staggerRefresh.start()
    }

    function drainOneRefresh() {
        // One pass over current queue length so a loading head cannot starve others
        var skippedLoading = 0
        var maxLook = refreshQueue.length
        while (refreshQueue.length > 0 && skippedLoading < maxLook) {
            var item = refreshQueue[0]
            var idx = findProfileIndex(item.id)
            if (idx < 0 || !profiles[idx]) {
                refreshQueue = refreshQueue.slice(1)
                maxLook = refreshQueue.length
                skippedLoading = 0
                continue
            }
            var p = profiles[idx]
            if (p.loading) {
                refreshQueue = refreshQueue.slice(1).concat([item])
                skippedLoading++
                continue
            }
            if (!item.manual && isAutoRefreshHeld(p, Date.now())) {
                refreshQueue = refreshQueue.slice(1)
                maxLook = refreshQueue.length
                skippedLoading = 0
                continue
            }
            // Only dequeue if the refresh transaction accepted the job
            if (!startProfileRefresh(idx, !!item.manual)) {
                // Reader busy or row already loading — rotate to end
                refreshQueue = refreshQueue.slice(1).concat([item])
                skippedLoading++
                continue
            }
            refreshQueue = refreshQueue.slice(1)
            return true
        }
        // Still have loading items — keep timer alive so we retry after they settle
        return refreshQueue.length > 0
    }

    function staggerRefreshAll() {
        staggerRefresh.stop()
        refreshQueue = []
        if (profiles.length === 0) return
        // Manual full refresh: clear per-profile auto holds so user can force retry (B029)
        // Skip hidden profiles (enabled:false) — they stay off the panel (B032).
        for (var i = 0; i < profiles.length; i++) {
            if (!profiles[i] || profiles[i].enabled === false) continue
            queueProfileRefresh(profiles[i].id, true)
        }
        kickRefreshQueue()
    }

    function refreshAll() {
        staggerRefreshAll()
    }

    function refreshProfile(profileId) {
        var idx = findProfileIndex(profileId)
        if (idx < 0) return
        // Manual single-profile refresh — queue so we don't drop when credReader busy
        queueProfileRefresh(profileId, true)
        kickRefreshQueue()
    }

    function shellQuote(path) {
        return "'" + String(path).replace(/'/g, "'\\''") + "'"
    }

    function endpointSlugForProvider(ep) {
        if (ep === "codex" || ep === "openai") return "wham-usage"
        if (ep === "zai") return "quota-limit"
        if (ep === "kimi") return "coding-usages"
        if (ep === "minimax") return "coding-plan-remains"
        if (ep === "grok") return "billing"
        return "oauth-usage"
    }

    function grokEndpointSlug(url) {
        if (String(url || "").indexOf("format=credits") >= 0)
            return "billing-credits"
        return "billing"
    }
    // B024: track in-flight write so a stuck executable engine cannot wedge the queue forever
    // Original attempt + retries; drop after this many stalls (no infinite retry)
    // B023: unique pending payload file names (separate from drain seq)
    // Chunk size for staging payload to a temp file without putting the full
    // body on a single Plasma executable argv (ARG_MAX + process-list leak).

    // B024: executable engine never called onNewData — unstick busy and optionally retry once

    /**
     * Build a unique executable source that always shell-quotes the path (B006)
     * and embeds the profile id so onNewData cannot mis-attribute (B001).
     * Format:  : 'cu-id=<profileId>'; cat '<absolute-path>' 2>/dev/null
     */
    function catCommand(path, profileId) {
        var abs = QC.expandToAbsolute(path, homeDir)
        if (!abs) {
            // Home not resolved yet for a home-relative path
            return ""
        }
        // Always quote — path may contain spaces, ;, $, etc. (literal filename only)
        var cat = "cat " + shellQuote(abs) + " 2>/dev/null"
        if (profileId) {
            // Unique sourceName per profile; shell no-op with fully quoted tag
            return ": " + shellQuote("cu-id=" + String(profileId)) + "; " + cat
        }
        return cat
    }

    function pendingCredCount() {
        var n = 0
        var m = credReader._pendingBySource
        if (!m) return 0
        for (var k in m) {
            if (m.hasOwnProperty(k) && m[k]) n++
        }
        return n
    }

    /**
     * I002 production entry: clone profile, allocate generation, run transaction.
     * Returns false when the credential port cannot start (busy / home / path)
     * so the global queue can rotate. Holds and loading are checked by drainOneRefresh.
     */
        /**
     * Thin cache port: forward settled exchange to LocalResponseCache.
     */
    function recordRefreshExchange(exchange) {
        responseCache.recordExchange(exchange)
    }

    function startProfileRefresh(idx, manual) {
        if (idx < 0 || idx >= profiles.length) return true
        var p = profiles[idx]
        if (!p) return true
        // Avoid stacking concurrent loads for the same row (B001/B002)
        if (p.loading) return false
        if (!manual && isAutoRefreshHeld(p, Date.now())) return true

        var snapshot = cloneProfile(p)
        // Providers.prepare uses profile.opencodeAccountIndex (was cfgValue in extractOpencodeAuth)
        var ocIdx = parseInt(cfgValue("opencodeAccountIndex", 0), 10)
        if (isNaN(ocIdx) || ocIdx < 0)
            ocIdx = 0
        snapshot.opencodeAccountIndex = ocIdx

        var generation = allocFetchGen()
        console.log("Claude Usage: startProfileRefresh", snapshot.id, snapshot.provider,
                    "manual=", !!manual, "gen=", generation)

        return ProfileRefresh.run({
            profile: snapshot,
            generation: generation,
            manual: !!manual,
            policy: {
                authRetryHoldMs: authRetryHoldMs,
                maxBackoffIntervalMs: maxBackoffIntervalMs,
                maxAuthAutoAttempts: maxAuthAutoAttempts,
                baseRefreshIntervalMs: refreshIntervalMs(snapshot.provider)
            }
        }, {
            readCredentials: readRefreshCredentials,
            requestHttp: requestRefreshHttp,
            recordExchange: recordRefreshExchange,
            now: function() { return Date.now() }
        }, applyRefreshTransition)
    }

    /**
     * Thin credential port: capacity / HOME / path / shell safety only.
     * Stores sourceName → { profileId, generation, callback }; no provider policy.
     */
    function readRefreshCredentials(request, callback) {
        if (!request || typeof callback !== "function")
            return false
        if (pendingCredCount() >= maxCredInflight)
            return false

        var rawPath = String(request.path || "")
        var needsHome = false
        if (rawPath.indexOf("~/") === 0 || rawPath === "~"
                || rawPath.indexOf("$HOME") === 0 || rawPath.indexOf("${HOME}") === 0)
            needsHome = true
        if (needsHome && !homeReady)
            return false

        var cmd = catCommand(request.path, request.profileId)
        if (!cmd)
            return false

        var map = {}
        var prev = credReader._pendingBySource
        if (prev) {
            for (var k in prev) {
                if (prev.hasOwnProperty(k)) map[k] = prev[k]
            }
        }
        // B001: key by full sourceName → request/callback (never array index)
        map[cmd] = {
            profileId: request.profileId,
            generation: request.generation,
            callback: callback
        }
        credReader._pendingBySource = map
        console.log("Claude Usage: readRefreshCredentials", request.profileId,
                    "gen=", request.generation, "cmd=", cmd)
        credReader.connectSource(cmd)
        return true
    }

    /**
     * Thin HTTP port: one XHR from a request spec, once-only settlement.
     * No provider/status/JSON/auth/retry policy.
     */
    function requestRefreshHttp(request, callback) {
        if (!request || typeof callback !== "function")
            return
        var method = request.method || "GET"
        var url = request.url || ""
        var headers = request.headers || {}
        var timeoutMs = request.timeoutMs > 0 ? request.timeoutMs : 25000
        var settled = false
        var xhr = new XMLHttpRequest()
        xhr.open(method, url)
        xhr.timeout = timeoutMs
        for (var h in headers) {
            if (headers.hasOwnProperty(h) && headers[h] !== undefined && headers[h] !== null)
                xhr.setRequestHeader(h, headers[h])
        }

        function settle(status, responseText, fromTimeout) {
            if (settled) return
            settled = true
            callback({
                key: request.key,
                profileId: request.profileId,
                generation: request.generation,
                provider: request.provider,
                opencodeSlot: request.opencodeSlot,
                endpoint: request.endpoint,
                url: url,
                status: status || 0,
                responseText: responseText || "",
                fromTimeout: !!fromTimeout
            })
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            settle(xhr.status || 0, xhr.responseText || "", false)
        }
        xhr.ontimeout = function() {
            settle(0, "", true)
        }
        xhr.send()
    }

    /**
     * Map transaction error metadata to existing translated UI strings.
     */
    function translateRefreshError(transition, fallback) {
        var err = transition && transition.error ? transition.error : {}
        var code = err.code || ""
        if (code === "not_logged_in") return tr("Not logged in")
        if (code === "token_expired") return tr("Token expired")
        if (code === "rate_limited") return tr("Rate limited")
        if (code === "timeout") return tr("API error") + " (timeout)"
        if (code === "network") return tr("API error") + " (network error)"
        if (code === "http") return tr("API error") + " (" + (err.status || 0) + ")"
        if (code === "parse") return "Parse error"
        if (code === "auth_suspended")
            return fallback || tr("Token expired")
        // Fallback: re-translate known English patches from ProfileRefresh.js
        var msg = fallback !== undefined && fallback !== null ? String(fallback) : ""
        if (msg === "Not logged in") return tr("Not logged in")
        if (msg === "Token expired") return tr("Token expired")
        if (msg === "Rate limited") return tr("Rate limited")
        if (msg === "Parse error") return "Parse error"
        if (msg.indexOf("API error (") === 0) {
            var detail = msg.substring("API error (".length, msg.length - 1)
            if (detail === "timeout") return tr("API error") + " (timeout)"
            if (detail === "network error") return tr("API error") + " (network error)"
            return tr("API error") + " (" + detail + ")"
        }
        return msg || tr("API error")
    }

    /**
     * Mechanical store adapter for ProfileRefresh transitions.
     * Resolves by stable profile ID + generation (never by mutable array index across async).
     * Success → registry usageResult (visibility/time inside the registry);
     * started/credentials/failures → registry patch.
     */
    function applyRefreshTransition(transition) {
        if (!transition || !transition.profileId)
            return
        var idx = findProfileIndex(transition.profileId)
        if (idx < 0)
            return
        var p = profiles[idx]
        if (!p)
            return

        if (transition.type === "started") {
            var started = {}
            var sp = transition.patch || {}
            for (var sk in sp) {
                if (sp.hasOwnProperty(sk))
                    started[sk] = sp[sk]
            }
            started.refreshGeneration = transition.generation
            // No expectedGeneration: started *assigns* the generation for this run
            applyRegistryResult(Registry.transition({
                state: { profiles: profiles },
                event: {
                    type: "patch",
                    profileId: transition.profileId,
                    patch: started
                },
                config: registryConfigSnapshot(),
                visibility: registryVisibilityAdapter(),
                nowMs: nowMs
            }))
            return
        }

        // credentials + all terminal outcomes require a current generation
        if (p.refreshGeneration !== transition.generation) {
            console.log("Claude Usage: drop stale transition", transition.type,
                        transition.profileId, "gen=", transition.generation,
                        "cur=", p.refreshGeneration)
            return
        }

        if (transition.type === "credentials") {
            applyRegistryResult(Registry.transition({
                state: { profiles: profiles },
                event: {
                    type: "patch",
                    profileId: transition.profileId,
                    expectedGeneration: transition.generation,
                    patch: transition.patch || {}
                },
                config: registryConfigSnapshot(),
                visibility: registryVisibilityAdapter(),
                nowMs: nowMs
            }))
            return
        }

        if (transition.type === "success") {
            if (transition.usageResult) {
                var successPatch = {}
                var us = transition.patch || {}
                for (var uk in us) {
                    if (us.hasOwnProperty(uk) && uk !== "windows")
                        successPatch[uk] = us[uk]
                }
                successPatch.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
                if (successPatch.lastFetchMs === undefined)
                    successPatch.lastFetchMs = Date.now()
                var usageAccepted = applyRegistryResult(Registry.transition({
                    state: { profiles: profiles },
                    event: {
                        type: "usageResult",
                        profileId: transition.profileId,
                        expectedGeneration: transition.generation,
                        usageResult: transition.usageResult,
                        patch: successPatch
                    },
                    config: registryConfigSnapshot(),
                    visibility: registryVisibilityAdapter(),
                    nowMs: nowMs
                }))
                if (usageAccepted)
                    lastGlobalUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
                var wins = transition.usageResult.windows || []
                var primaryCount = 0
                for (var pi = 0; pi < wins.length; pi++) {
                    if (wins[pi] && wins[pi].role === "primary")
                        primaryCount++
                }
                console.log("Claude Usage: usageResult", transition.profileId,
                            "accepted=", usageAccepted,
                            "windows=", wins.length, "primary=", primaryCount)
            } else {
                // Defensive: never leave loading stuck if a success lacks a body
                var emptyPatch = {}
                var es = transition.patch || {}
                for (var ek in es) {
                    if (es.hasOwnProperty(ek) && ek !== "windows")
                        emptyPatch[ek] = es[ek]
                }
                if (emptyPatch.loading === undefined)
                    emptyPatch.loading = false
                applyRegistryResult(Registry.transition({
                    state: { profiles: profiles },
                    event: {
                        type: "patch",
                        profileId: transition.profileId,
                        expectedGeneration: transition.generation,
                        patch: emptyPatch
                    },
                    config: registryConfigSnapshot(),
                    visibility: registryVisibilityAdapter(),
                    nowMs: nowMs
                }))
            }
            return
        }

        // Terminal failure / suspension: apply patch with translated error strings
        var patch = {}
        var src = transition.patch || {}
        for (var pk in src) {
            if (src.hasOwnProperty(pk) && pk !== "windows")
                patch[pk] = src[pk]
        }
        if (patch.error !== undefined)
            patch.error = translateRefreshError(transition, patch.error)
        applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: {
                type: "patch",
                profileId: transition.profileId,
                expectedGeneration: transition.generation,
                patch: patch
            },
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))

        if (transition.type === "auth_error")
            console.log("Claude Usage: auth failure via transaction", transition.profileId,
                        "count=", patch.authFailCount, "suspended=", !!patch.authSuspended)
        else if (transition.type === "rate_limited")
            console.log("Claude Usage: 429 backoff via transaction", transition.profileId,
                        "mult=", patch.backoffMultiplier)
        else if (transition.type === "auth_suspended")
            console.log("Claude Usage: auth still suspended, skip API", transition.profileId)
        else
            console.log("Claude Usage: terminal", transition.type, transition.profileId,
                        "error=", patch.error)
    }

    // Legacy alias kept until Task 4/6 delete loadCredentials; delegates to transaction.
    // Returns true if a credential read was started (or skipped as held).
    // Returns false if caller should re-queue (busy / home not ready / already loading).
    function loadCredentials(idx, opts) {
        opts = opts || {}
        return startProfileRefresh(idx, !!opts.manual)
    }

    function noteAuthFailure(idx, errorText, tokenSnapshot) {
        if (idx < 0 || idx >= profiles.length) return
        var cur = profiles[idx]
        var count = (cur.authFailCount || 0) + 1
        var now = Date.now()
        var patch = {
            loading: false,
            error: errorText || tr("Token expired"),
            authFailCount: count,
            lastFetchMs: now,
            lastFailedToken: tokenSnapshot !== undefined ? tokenSnapshot : (cur.accessToken || "")
        }
        if (count >= maxAuthAutoAttempts) {
            // Stop auto-refresh until manual refresh or credentials change (B026/B029)
            patch.authSuspended = true
            patch.autoRefreshHoldUntilMs = 0
            console.log("Claude Usage: auth suspended after", count, "failures", cur.id)
        } else {
            patch.authSuspended = false
            patch.autoRefreshHoldUntilMs = now + authRetryHoldMs
            console.log("Claude Usage: auth hold", authRetryHoldMs, "ms after fail", count, cur.id)
        }
        updateProfile(idx, patch)
    }

    function noteRateLimited(idx) {
        if (idx < 0 || idx >= profiles.length) return
        var cur = profiles[idx]
        var mult = (cur.backoffMultiplier || 1) * 2
        var base = refreshIntervalMs(cur.provider)
        var wait = Math.min(base * mult, maxBackoffIntervalMs)
        // Cap stored mult so base*mult does not keep growing past the ceiling
        var maxMult = Math.max(1, Math.ceil(maxBackoffIntervalMs / Math.max(base, 1)))
        if (mult > maxMult) mult = maxMult
        var now = Date.now()
        updateProfile(idx, {
            loading: false,
            error: tr("Rate limited"),
            backoffMultiplier: mult,
            lastFetchMs: now,
            autoRefreshHoldUntilMs: now + wait
        })
        console.log("Claude Usage: 429 backoff wait=", wait, "ms mult=", mult, cur.id)
    }

    function clearFailureStatePatch() {
        return {
            authFailCount: 0,
            authSuspended: false,
            autoRefreshHoldUntilMs: 0,
            lastFailedToken: "",
            backoffMultiplier: 1
        }
    }

    function effectiveProvider(profile) {
        if (profile.provider === "opencode") return profile.opencodeSlot || "anthropic"
        return profile.provider
    }

    /**
     * Apply normalised usage through the registry usageResult transition.
     * Optional `patch` carries loading/error/auth/backoff fields (never windows).
     * Visibility/time always run inside ProfileRegistry via the production adapter.
     * Production path is applyRefreshTransition; keep for any direct/legacy callers.
     */
    function applyUsageResult(idx, result, patch) {
        if (idx < 0 || idx >= profiles.length || !result) return
        var p = profiles[idx]
        if (!p || !p.id) return

        var out = {}
        if (patch) {
            for (var k in patch) {
                if (patch.hasOwnProperty(k) && k !== "windows")
                    out[k] = patch[k]
            }
        } else {
            var clear = clearFailureStatePatch()
            out.loading = false
            out.error = ""
            out.lastFetchMs = Date.now()
            out.backoffMultiplier = clear.backoffMultiplier
            out.authFailCount = clear.authFailCount
            out.authSuspended = clear.authSuspended
            out.autoRefreshHoldUntilMs = clear.autoRefreshHoldUntilMs
            out.lastFailedToken = clear.lastFailedToken
        }
        out.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
        if (out.lastFetchMs === undefined)
            out.lastFetchMs = Date.now()

        var gen = p.refreshGeneration
        if (gen === undefined || gen === null)
            gen = 0

        var accepted = applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: {
                type: "usageResult",
                profileId: p.id,
                expectedGeneration: gen,
                usageResult: {
                    windows: result.windows,
                    planName: result.planName,
                    bankedResets: result.bankedResets
                },
                patch: out
            },
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))
        if (accepted)
            lastGlobalUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
        var winCount = (result.windows && result.windows.length) || 0
        console.log("Claude Usage: applyUsageResult id=", p.id,
                    "accepted=", accepted, "windows=", winCount)
    }

    // B027: only advance the clock. Do NOT reassign `profiles` (or bump dataEpoch).
    // Replacing the array every second forced CardsView/Repeaters to rebuild delegates,
    // which destroyed ToolTips mid-hover. Countdown + pace bars bind to nowMs instead.
    function tickWindows() {
        nowMs = Date.now()
        // Keep stored timePercent roughly current for any non-binding consumers, but
        // mutate in place — never replace profiles/windows arrays on the tick path.
        for (var i = 0; i < profiles.length; i++) {
            var wins = profiles[i] && profiles[i].windows
            if (!wins || !wins.length) continue
            for (var j = 0; j < wins.length; j++) {
                if (wins[j])
                    QC.updateTimePercent(wins[j], nowMs)
            }
        }
        // B018 intent (notify UI of tick) is satisfied without profiles reassignment
        // or dataEpoch bump — B027 keeps tooltips stable; UI binds to nowMs instead.
    }

    function dueProfiles() {
        var due = []
        var now = Date.now()
        for (var i = 0; i < profiles.length; i++) {
            var p = profiles[i]
            if (!p || p.enabled === false) continue
            if (p.loading) continue
            // Hard cool-down (auth retry spacing or 429 hold)
            if (isAutoRefreshHeld(p, now)) continue
            // After first auth fail, next attempt is gated by hold only (~5m), not full provider interval
            if ((p.authFailCount || 0) > 0 && !p.authSuspended) {
                due.push(p.id)
                continue
            }
            // authSuspended: still re-cat on normal interval to detect token rotation (no API if same)
            var interval = effectiveRefreshIntervalMs(p)
            if (!p.lastFetchMs || (now - p.lastFetchMs) >= interval)
                due.push(p.id)
        }
        return due
    }

    Plasma5Support.DataSource {
        id: discoverSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""
            var exitCode = data["exit code"] !== undefined ? data["exit code"] : data["exitCode"]
            disconnectSource(sourceName)
            var trimmed = String(stdout).replace(/^\s+|\s+$/g, "")
            // Non-zero exit with empty/invalid body → surface to panel (B017)
            if (!trimmed) {
                if (exitCode && exitCode !== 0) {
                    failDiscovery("Discovery failed", exitCode, stderr)
                    return
                }
                // Empty stdout + success → no profiles found
                discoveryError = ""
                mergeDiscovered([])
                return
            }
            try {
                var list = JSON.parse(trimmed)
                if (!Array.isArray(list)) {
                    failDiscovery("Discovery returned invalid data", exitCode, stderr)
                    return
                }
                if (exitCode && exitCode !== 0)
                    console.log("Claude Usage: discovery exit=", exitCode, "stderr=", stderr)
                mergeDiscovered(list)
            } catch (e) {
                console.log("Claude Usage: discovery parse error", e, stderr)
                failDiscovery("Discovery failed", exitCode, stderr || String(e))
            }
        }
    }

    
    
    // Resolve $HOME once with a fixed command (B006) — never interpolate user strings here
    Plasma5Support.DataSource {
        id: homeProbe
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = (data["stdout"] || "").trim()
            disconnectSource(sourceName)
            if (stdout && stdout.charAt(0) === "/") {
                controller.homeDir = stdout
                controller.homeReady = true
                console.log("Claude Usage: homeDir=", controller.homeDir)
                // Resume any queued credential loads waiting on HOME
                controller.kickRefreshQueue()
            } else {
                console.log("Claude Usage: home probe failed, stdout=", stdout)
                // Best-effort fallback so absolute paths still work
                controller.homeReady = true
            }
        }
    }

    LocalResponseCache {
        id: responseCache
        enabled: controller.cfgValue("cacheResponses", true) !== false
                 && controller.cfgValue("cacheResponses", true) !== 0
                 && controller.cfgValue("cacheResponses", true) !== "false"
                 && controller.cfgValue("cacheResponses", true) !== "0"
        configuredRoot: String(controller.cfgValue("responseCachePath", "") || "")
        homeDir: controller.homeDir
    }

    Plasma5Support.DataSource {
        id: credReader
        engine: "executable"
        connectedSources: []
        // B001: sourceName → { profileId, generation, callback } (never array index)
        property var _pendingBySource: ({})

        // Thin credential port completion: disconnect, deliver raw stdout, kick queue.
        // Provider/auth/retry/fetch decisions live in ProfileRefresh (I002).
        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""
            var exitCode = data["exit code"] !== undefined ? data["exit code"] : data["exitCode"]
            disconnectSource(sourceName)

            var map = credReader._pendingBySource || {}
            var pending = map[sourceName] || null
            // Remove this source from the pending map
            var nextMap = {}
            for (var k in map) {
                if (map.hasOwnProperty(k) && k !== sourceName)
                    nextMap[k] = map[k]
            }
            credReader._pendingBySource = nextMap

            if (!pending || typeof pending !== "object" || typeof pending.callback !== "function") {
                console.log("Claude Usage: drop unmatched cred reply for", sourceName)
                kickRefreshQueue()
                return
            }

            console.log("Claude Usage: credentials stdout len=", stdout.length,
                        "exit=", exitCode, "id=", pending.profileId, "gen=", pending.generation)
            try {
                pending.callback({
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode
                })
            } catch (e) {
                console.log("Claude Usage: credential callback error", e)
            }
            // Next profile can start cat while XHR runs (loading still true on this row)
            kickRefreshQueue()
        }
    }

    Timer {
        id: staggerRefresh
        interval: 2000
        repeat: true
        onTriggered: {
            if (!controller.drainOneRefresh() || controller.refreshQueue.length === 0)
                stop()
        }
    }

    Timer {
        id: liveClock
        interval: 1000
        running: profiles.length > 0
        repeat: true
        onTriggered: controller.tickWindows()
    }

    Timer {
        id: autoRefresh
        interval: 60000
        running: profiles.length > 0
        repeat: true
        onTriggered: {
            // B002: enqueue due profiles and stagger; never burst loadCredentials
            var due = controller.dueProfiles()
            for (var i = 0; i < due.length; i++)
                controller.queueProfileRefresh(due[i], false)
            controller.kickRefreshQueue()
        }
    }

}