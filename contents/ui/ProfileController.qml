import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support
import "js/QuotaCommon.js" as QC
import "js/QuotaParsers.js" as QP

Item {
    id: controller

    property var plasmoid
    property var i18n
    property var profiles: []
    property bool discovering: false
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

    readonly property string cacheScript: {
        var u = Qt.resolvedUrl("../scripts/cache-response.sh").toString()
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

    function visibleWindowIds() {
        return parseJsonConfig(cfgValue("visibleWindowsJson", "[]"), [])
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
        discoverSource.connectSource("bash " + shellQuote(discoverScript))
    }

    function resolveCustomCredPath(entry) {
        if (!entry) return ""
        if (entry.credPath)
            return entry.credPath
        // B009: path is often a config *directory* — resolve auth file by provider
        return QC.defaultCredPathForProvider(entry.provider, entry.path)
    }

    function blankProfileRow(meta, visIds) {
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
            grokFetchGen: 0,
            grokPending: 0,
            grokDefaultBody: null,
            grokCreditsBody: null,
            grokDefaultStatus: 0,
            grokDefaultFromTimeout: false,
            grokAuthFailed: false,
            usageFetchGen: 0,
            backoffMultiplier: 1,
            lastFetchMs: 0,
            authFailCount: 0,
            authSuspended: false,
            autoRefreshHoldUntilMs: 0,
            lastFailedToken: "",
            visibleWindowIds: visIds
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

        var visIds = visibleWindowIds()
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
            var row = blankProfileRow(meta, visIds)
            row.enabled = isProfileEnabled(meta)
            if (meta.displayNameHint && row.displayName === QC.defaultProfileLabel(meta.provider, meta.profileKey))
                row.displayName = meta.displayNameHint
            var prev = prevById[meta.id]
            if (prev) {
                // Keep live usage + auth; refresh labels / visibility from config
                var keepKeys = [
                    "loading", "error", "planName", "bankedResets", "windows",
                    "lastUpdate", "accessToken", "accountId", "resourceUrl",
                    "opencodeSlot", "grokFetchGen", "grokPending", "grokDefaultBody",
                    "grokCreditsBody", "grokDefaultStatus", "grokDefaultFromTimeout",
                    "grokAuthFailed", "usageFetchGen", "backoffMultiplier", "lastFetchMs",
                    "authFailCount", "authSuspended", "autoRefreshHoldUntilMs",
                    "lastFailedToken"
                ]
                for (var ki = 0; ki < keepKeys.length; ki++) {
                    var k = keepKeys[ki]
                    if (prev[k] !== undefined)
                        row[k] = Array.isArray(prev[k]) ? prev[k].slice() : prev[k]
                }
                // Re-apply window visibility from new config
                if (row.windows && row.windows.length) {
                    row.windows = QC.applyVisibility(row.windows, visIds.length ? visIds : null)
                    for (var wi = 0; wi < row.windows.length; wi++)
                        QC.updateTimePercent(row.windows[wi], nowMs)
                }
            }
            rows.push(row)
        }
        profiles = rows
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
        var visIds = visibleWindowIds()
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
            copy.visibleWindowIds = visIds
            if (copy.windows && copy.windows.length) {
                copy.windows = QC.applyVisibility(copy.windows, visIds.length ? visIds : null)
                for (var wi = 0; wi < copy.windows.length; wi++)
                    QC.updateTimePercent(copy.windows[wi], nowMs)
            }
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

    function updateProfile(idx, patch) {
        if (idx < 0 || idx >= profiles.length) return
        var copy = []
        for (var i = 0; i < profiles.length; i++)
            copy.push(i === idx ? cloneProfile(profiles[i]) : profiles[i])
        var p = copy[idx]
        for (var k in patch) {
            if (patch.hasOwnProperty(k)) p[k] = patch[k]
        }
        copy[idx] = p
        profiles = copy
        dataEpoch++
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
            // Only dequeue if loadCredentials accepted the job
            if (!loadCredentials(idx, { manual: !!item.manual })) {
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

    function pad2(n) {
        n = Math.floor(Number(n) || 0)
        return n < 10 ? "0" + n : String(n)
    }

    function pad3(n) {
        n = Math.floor(Number(n) || 0) % 1000
        if (n < 10) return "00" + n
        if (n < 100) return "0" + n
        return String(n)
    }

    function profileSlug(id) {
        var s = String(id || "unknown")
        var out = ""
        for (var i = 0; i < s.length; i++) {
            var c = s.charAt(i)
            if ((c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
                    || (c >= "0" && c <= "9") || c === "." || c === "_" || c === "-") {
                out += c
            } else {
                out += "-"
            }
        }
        while (out.indexOf("--") >= 0)
            out = out.replace("--", "-")
        while (out.length && out.charAt(0) === "-")
            out = out.substring(1)
        while (out.length && out.charAt(out.length - 1) === "-")
            out = out.substring(0, out.length - 1)
        return out || "unknown"
    }

    function responseCacheRoot() {
        var override = String(cfgValue("responseCachePath", "") || "").trim()
        if (override) {
            var abs = QC.expandToAbsolute(override, homeDir)
            if (abs) return abs
            // home not ready: keep $HOME token for cache-response.sh resolve_path
            if (override.indexOf("~/") === 0)
                return "$HOME/" + override.substring(2)
            return override
        }
        if (homeDir)
            return homeDir.replace(/\/+$/, "") + "/.cache/plasma-claude-usage"
        return "$HOME/.cache/plasma-claude-usage"
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

    function buildResponseCachePaths(profile, endpointSlug) {
        var root = responseCacheRoot().replace(/\/+$/, "")
        var now = new Date()
        var y = now.getFullYear()
        var mo = pad2(now.getMonth() + 1)
        var d = pad2(now.getDate())
        var hms = pad2(now.getHours()) + pad2(now.getMinutes()) + pad2(now.getSeconds())
        var ms3 = pad3(now.getMilliseconds())
        var provider = profileSlug(effectiveProvider(profile) || profile.provider || "unknown")
        var slug = profileSlug(profile.id)
        var ep = profileSlug(endpointSlug || "response")
        var base = hms + "-" + ms3 + "-" + provider + "-" + slug + "-" + ep + ".json"
        return {
            hist: root + "/responses/" + y + "/" + mo + "/" + d + "/" + base,
            latest: root + "/latest/" + provider + "-" + slug + "-" + ep + ".json"
        }
    }

    function cfgBool(key, fallback) {
        var v = cfgValue(key, fallback)
        if (v === true || v === 1 || v === "true" || v === "1") return true
        if (v === false || v === 0 || v === "false" || v === "0") return false
        return !!fallback
    }

    property var _cacheWriteQueue: []
    property bool _cacheWriteBusy: false
    property int _cacheWriteSeq: 0

    function enqueueCacheWrite(cmd) {
        _cacheWriteQueue = _cacheWriteQueue.concat([cmd])
        drainCacheWriteQueue()
    }

    function drainCacheWriteQueue() {
        if (_cacheWriteBusy) return
        if (!_cacheWriteQueue.length) return
        var next = _cacheWriteQueue[0]
        _cacheWriteQueue = _cacheWriteQueue.slice(1)
        _cacheWriteBusy = true
        // Unique env prefix so Plasma never collapses identical command strings
        _cacheWriteSeq = (_cacheWriteSeq + 1) % 100000
        cacheWriter.connectSource("CACHE_WRITE_SEQ=" + _cacheWriteSeq + " " + next)
    }

    function cacheResponse(profile, endpointSlug, url, httpStatus, responseText) {
        if (!cfgBool("cacheResponses", true))
            return
        if (!profile)
            return
        try {
            var paths = buildResponseCachePaths(profile, endpointSlug)
            var rawText = responseText === undefined || responseText === null ? "" : String(responseText)
            // Keep argv under ARG_MAX; usage JSON is small, but error HTML can be huge
            var maxRaw = 200000
            var truncated = false
            if (rawText.length > maxRaw) {
                rawText = rawText.substring(0, maxRaw)
                truncated = true
            }
            var body = null
            var raw = null
            if (rawText.length) {
                try {
                    body = JSON.parse(rawText)
                } catch (e) {
                    body = null
                    raw = rawText
                }
            }
            var now = new Date()
            var envelope = {
                savedAt: now.toISOString(),
                savedAtMs: now.getTime(),
                provider: effectiveProvider(profile) || profile.provider || "",
                profileId: profile.id || "",
                endpoint: endpointSlug || "",
                url: url || "",
                httpStatus: httpStatus || 0,
                body: body,
                raw: raw,
                truncated: truncated
            }
            var payload = JSON.stringify(envelope)
            var cmd = "bash " + shellQuote(cacheScript)
                + " " + shellQuote(paths.hist)
                + " " + shellQuote(paths.latest)
                + " " + shellQuote(payload)
            enqueueCacheWrite(cmd)
        } catch (e) {
            console.log("Claude Usage: cacheResponse error", e)
        }
    }

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

    // Returns true if a credential read was started (or skipped as held).
    // Returns false if caller should re-queue (busy / home not ready / already loading).
    function loadCredentials(idx, opts) {
        opts = opts || {}
        var manual = !!opts.manual
        if (idx < 0 || idx >= profiles.length) return true
        var p = profiles[idx]
        if (!p) return true
        // Avoid stacking concurrent loads for the same row (B001/B002)
        if (p.loading) return false
        if (!manual && isAutoRefreshHeld(p, Date.now())) return true
        // Cap concurrent cats; map-by-sourceName is safe, but keep load gentle
        if (pendingCredCount() >= maxCredInflight)
            return false
        // Wait for HOME probe before expanding ~/ or $HOME paths (B006)
        var needsHome = false
        var rawPath = String(p.credPath || "")
        if (rawPath.indexOf("~/") === 0 || rawPath === "~"
                || rawPath.indexOf("$HOME") === 0 || rawPath.indexOf("${HOME}") === 0)
            needsHome = true
        if (needsHome && !homeReady)
            return false

        var cmd = catCommand(p.credPath, p.id)
        if (!cmd)
            return false

        var patch = { loading: true, error: "" }
        if (manual) {
            // Manual refresh may retry after OAuth/billing fixes (B029)
            patch.authSuspended = false
            patch.autoRefreshHoldUntilMs = 0
        }
        updateProfile(idx, patch)
        p = profiles[idx]
        console.log("Claude Usage: loadCredentials", p.id, p.provider, "manual=", manual, "cmd=", cmd)

        // B001: key pending work by full sourceName → profile id (not array index)
        var map = {}
        var prev = credReader._pendingBySource
        if (prev) {
            for (var k in prev) {
                if (prev.hasOwnProperty(k)) map[k] = prev[k]
            }
        }
        map[cmd] = p.id
        credReader._pendingBySource = map
        credReader.connectSource(cmd)
        return true
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

    function extractAuth(provider, creds, profile) {
        var auth = { token: "", accountId: "", resourceUrl: "https://api.minimax.io", opencodeSlot: "", planName: "" }

        if (provider === "claude") {
            var oauth = creds.claudeAiOauth || {}
            auth.token = oauth.accessToken || ""
            var tier = oauth.rateLimitTier || "default_claude_pro"
            var planMap = {
                "default_claude_pro": "Pro",
                "default_claude_max_5x": "Max 5x",
                "default_claude_max_20x": "Max 20x"
            }
            auth.planName = planMap[tier] || tier
        } else if (provider === "codex") {
            var tokens = creds.tokens || {}
            var openai = creds.openai || {}
            auth.token = tokens.access_token || openai.access || ""
            auth.accountId = tokens.account_id || openai.accountId || ""
        } else if (provider === "grok") {
            auth.token = pickGrokToken(creds)
        } else if (provider === "minimax") {
            if (creds.oauth && creds.oauth.access_token) {
                auth.token = creds.oauth.access_token
                auth.resourceUrl = creds.oauth.resource_url || creds.resource_url || "https://api.minimax.io"
            } else if (typeof creds === "string" || (profile && profile.isFlatFile)) {
                auth.token = String(creds).trim().split("\n")[0]
            } else if (creds.key) {
                auth.token = creds.key
            }
        } else if (provider === "zai") {
            var zai = creds["zai-coding-plan"] || creds
            auth.token = zai.key || (typeof creds === "string" ? String(creds).trim() : "")
        } else if (provider === "kimi") {
            auth.token = typeof creds === "string" ? String(creds).trim() : (creds.key || creds.access || "")
        } else if (provider === "opencode") {
            auth = extractOpencodeAuth(creds, profile)
        }
        return auth
    }

    function pickGrokToken(creds) {
        var map = creds
        if (creds.accounts && typeof creds.accounts === "object" && !Array.isArray(creds.accounts)) {
            map = creds.accounts
        }
        var candidates = []
        for (var k in map) {
            if (!map.hasOwnProperty(k)) continue
            var entry = map[k]
            if (!entry || typeof entry !== "object") continue
            var token = entry.key || entry.access_token || entry.token || ""
            if (!token) continue
            var expMs = entry.expires_at ? Date.parse(entry.expires_at) : NaN
            var createMs = entry.create_time ? Date.parse(entry.create_time) : NaN
            candidates.push({ key: token, expiresAt: isNaN(expMs) ? null : expMs, createTime: isNaN(createMs) ? null : createMs })
        }
        if (candidates.length === 0) return ""
        var now = Date.now()
        candidates.sort(function(a, b) {
            var aFresh = a.expiresAt === null || a.expiresAt > now
            var bFresh = b.expiresAt === null || b.expiresAt > now
            if (aFresh !== bFresh) return aFresh ? -1 : 1
            return (b.createTime || 0) - (a.createTime || 0)
        })
        return candidates[0].key
    }

    function extractOpencodeAuth(creds, profile) {
        var auth = { token: "", accountId: "", opencodeSlot: "anthropic", planName: "OpenCode" }
        if (profile.profileKey === "anthropic-accounts" && creds.accounts && creds.accounts.length) {
            auth.token = creds.accounts[0].access || ""
            auth.opencodeSlot = "anthropic"
            return auth
        }
        var priority = [
            ["anthropic", "anthropic"],
            ["openai", "openai"],
            ["minimax-coding-plan", "minimax"],
            ["zai-coding-plan", "zai"],
            ["kimi-for-coding", "kimi"]
        ]
        for (var i = 0; i < priority.length; i++) {
            var key = priority[i][0]
            var slot = priority[i][1]
            var sub = creds[key] || {}
            var tok = sub.access || sub.key || ""
            if (tok) {
                auth.token = tok
                auth.opencodeSlot = slot
                if (slot === "openai") auth.accountId = sub.accountId || ""
                return auth
            }
        }
        return auth
    }

    function effectiveProvider(profile) {
        if (profile.provider === "opencode") return profile.opencodeSlot || "anthropic"
        return profile.provider
    }

    function usageUrl(profile) {
        var p = effectiveProvider(profile)
        if (p === "codex" || p === "openai") return "https://chatgpt.com/backend-api/wham/usage"
        if (p === "zai") return "https://api.z.ai/api/monitor/usage/quota/limit"
        if (p === "grok") return "https://cli-chat-proxy.grok.com/v1/billing"
        if (p === "kimi") return "https://api.kimi.com/coding/v1/usages"
        if (p === "minimax") return (profile.resourceUrl || "https://api.minimax.io") + "/v1/api/openplatform/coding_plan/remains"
        return "https://api.anthropic.com/api/oauth/usage"
    }

    function applyUsageResult(idx, result) {
        var p = profiles[idx]
        var vis = p.visibleWindowIds && p.visibleWindowIds.length ? p.visibleWindowIds : visibleWindowIds()
        var windows = QC.applyVisibility(result.windows, vis.length ? vis : null)
        for (var i = 0; i < windows.length; i++) {
            QC.updateTimePercent(windows[i], nowMs)
        }
        var clear = clearFailureStatePatch()
        updateProfile(idx, {
            loading: false,
            error: "",
            planName: result.planName || p.planName,
            bankedResets: result.bankedResets || 0,
            windows: windows,
            lastUpdate: Qt.formatTime(new Date(), "hh:mm:ss"),
            lastFetchMs: Date.now(),
            backoffMultiplier: clear.backoffMultiplier,
            authFailCount: clear.authFailCount,
            authSuspended: clear.authSuspended,
            autoRefreshHoldUntilMs: clear.autoRefreshHoldUntilMs,
            lastFailedToken: clear.lastFailedToken
        })
        lastGlobalUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
        var primaryCount = 0
        for (var pi = 0; pi < windows.length; pi++) {
            if (windows[pi] && windows[pi].role === "primary" && windows[pi].visible !== false)
                primaryCount++
        }
        console.log("Claude Usage: applyUsageResult idx=", idx, "windows=", windows.length, "primary=", primaryCount)
    }

    function fetchUsage(idx) {
        var p = profiles[idx]
        if (!p || !p.accessToken) {
            noteAuthFailure(idx, tr("Not logged in"), "")
            return
        }
        var ep = effectiveProvider(p)
        if (ep === "grok") {
            fetchGrok(idx)
            return
        }

        var url = usageUrl(p)
        var epSlug = endpointSlugForProvider(ep)
        // Snapshot identity for caching + stale-response guard (B008)
        var profileId = p.id
        var gen = allocFetchGen()
        var tokenSnapshot = p.accessToken
        var cacheProf = { id: p.id, provider: p.provider, opencodeSlot: p.opencodeSlot }
        updateProfile(idx, { usageFetchGen: gen })

        var settled = false
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.timeout = 25000
        xhr.setRequestHeader("Content-Type", "application/json")
        if (ep === "zai") {
            xhr.setRequestHeader("Authorization", p.accessToken)
        } else {
            xhr.setRequestHeader("Authorization", "Bearer " + p.accessToken)
        }
        if (ep === "claude" || ep === "anthropic") {
            xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")
        } else if (ep === "codex" || ep === "openai") {
            if (p.accountId) xhr.setRequestHeader("ChatGPT-Account-Id", p.accountId)
        }

        function resolveIdx() {
            var curIdx = findProfileIndex(profileId)
            if (curIdx < 0) return -1
            var cur = profiles[curIdx]
            if (!cur || cur.usageFetchGen !== gen) return -1
            return curIdx
        }

        function settleUsage(status, responseText, fromTimeout) {
            if (settled) return
            settled = true
            cacheResponse(cacheProf, epSlug, url, status || 0, responseText || "")
            var curIdx = resolveIdx()
            if (curIdx < 0) return
            var cur = profiles[curIdx]
            if (status === 200) {
                try {
                    var data = JSON.parse(responseText || "")
                    var result = emptyUsage()
                    if (ep === "claude" || ep === "anthropic") result = QP.parseClaude(data)
                    else if (ep === "codex" || ep === "openai") result = QP.parseCodex(data)
                    else if (ep === "minimax") result = QP.parseMinimax(data)
                    else if (ep === "zai") result = QP.parseZai(data)
                    else if (ep === "kimi") result = QP.parseKimi(data)
                    if (!result.planName && cur.planName) result.planName = cur.planName
                    console.log("Claude Usage: API ok", ep, "windows=", (result.windows || []).length)
                    applyUsageResult(curIdx, result)
                } catch (e) {
                    console.log("Claude Usage: parse error", e)
                    updateProfile(curIdx, { loading: false, error: "Parse error", lastFetchMs: Date.now() })
                }
            } else if (status === 429) {
                noteRateLimited(curIdx)
            } else if (status === 401 || status === 403) {
                noteAuthFailure(curIdx, tr("Token expired"), tokenSnapshot)
            } else if (status === 0) {
                // B025: only label timeout when ontimeout fired
                var detail = fromTimeout ? "timeout" : "network error"
                updateProfile(curIdx, {
                    loading: false,
                    error: tr("API error") + " (" + detail + ")",
                    lastFetchMs: Date.now()
                })
            } else {
                updateProfile(curIdx, {
                    loading: false,
                    error: tr("API error") + " (" + status + ")",
                    lastFetchMs: Date.now()
                })
            }
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            settleUsage(xhr.status || 0, xhr.responseText || "", false)
        }
        xhr.ontimeout = function() {
            settleUsage(0, "", true)
        }
        xhr.send()
    }

    function emptyUsage() {
        return { planName: "", bankedResets: 0, windows: [] }
    }

    function fetchGrok(idx) {
        var p = profiles[idx]
        var profileId = p.id
        var tokenSnapshot = p.accessToken
        var gen = allocFetchGen()
        updateProfile(idx, {
            grokFetchGen: gen,
            grokPending: 2,
            grokDefaultBody: null,
            grokCreditsBody: null,
            grokDefaultStatus: 0,
            grokDefaultFromTimeout: false,
            grokAuthFailed: false
        })
        grokGet(profileId, gen, "https://cli-chat-proxy.grok.com/v1/billing", function(ok, body, status, fromTimeout) {
            var curIdx = findProfileIndex(profileId)
            if (curIdx < 0) return
            var patch = { grokDefaultStatus: status, grokDefaultFromTimeout: !!fromTimeout }
            if (ok) patch.grokDefaultBody = body
            else if (status === 401 || status === 403) patch.grokAuthFailed = true
            finishGrokPart(profileId, gen, patch, tokenSnapshot)
        })
        grokGet(profileId, gen, "https://cli-chat-proxy.grok.com/v1/billing?format=credits", function(ok, body) {
            var patch = {}
            if (ok) patch.grokCreditsBody = body
            finishGrokPart(profileId, gen, patch, tokenSnapshot)
        })
    }

    function grokGet(profileId, gen, url, callback) {
        var idx = findProfileIndex(profileId)
        if (idx < 0) return
        var p = profiles[idx]
        var epSlug = grokEndpointSlug(url)
        var cacheProf = { id: p.id, provider: p.provider, opencodeSlot: p.opencodeSlot }
        var settled = false
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.timeout = 25000
        xhr.setRequestHeader("Authorization", "Bearer " + p.accessToken)
        xhr.setRequestHeader("Accept", "application/json")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("x-grok-client-version", "0.2.93")
        xhr.setRequestHeader("x-grok-client-surface", "grok-build")

        function settleGrok(status, responseText, fromTimeout) {
            if (settled) return
            settled = true
            // Always cache the HTTP exchange, even if this generation is stale
            cacheResponse(cacheProf, epSlug, url, status || 0, responseText || "")
            var curIdx = findProfileIndex(profileId)
            if (curIdx < 0) return
            if (!profiles[curIdx] || profiles[curIdx].grokFetchGen !== gen) return
            if (status === 200) {
                try { callback(true, JSON.parse(responseText || ""), status, fromTimeout) }
                catch (e) { callback(false, null, status, fromTimeout) }
            } else {
                callback(false, null, status || 0, fromTimeout)
            }
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            settleGrok(xhr.status || 0, xhr.responseText || "", false)
        }
        xhr.ontimeout = function() {
            settleGrok(0, "", true)
        }
        xhr.send()
    }

    function finishGrokPart(profileId, gen, patch, tokenSnapshot) {
        var idx = findProfileIndex(profileId)
        if (idx < 0) return
        var p = profiles[idx]
        if (!p || p.grokFetchGen !== gen) return
        patch.grokPending = Math.max(0, (p.grokPending || 2) - 1)
        updateProfile(idx, patch)
        idx = findProfileIndex(profileId)
        if (idx < 0) return
        var cur = profiles[idx]
        if (!cur || cur.grokPending > 0) return
        p = cur
        if (p.grokAuthFailed || p.grokDefaultStatus === 401 || p.grokDefaultStatus === 403) {
            noteAuthFailure(idx, tr("Token expired"), tokenSnapshot)
            return
        }
        if (p.grokDefaultStatus === 429) {
            noteRateLimited(idx)
            return
        }
        if (!p.grokDefaultBody) {
            var detail
            if (p.grokDefaultStatus === 0)
                detail = p.grokDefaultFromTimeout ? "timeout" : "network error"
            else
                detail = String(p.grokDefaultStatus || "error")
            updateProfile(idx, {
                loading: false,
                error: p.error || (tr("API error") + " (" + detail + ")"),
                lastFetchMs: Date.now()
            })
            return
        }
        try {
            var result = QP.parseGrok(p.grokDefaultBody, p.grokCreditsBody)
            applyUsageResult(idx, result)
        } catch (e) {
            updateProfile(idx, { loading: false, error: "Parse error", lastFetchMs: Date.now() })
        }
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
            disconnectSource(sourceName)
            try {
                var list = JSON.parse(stdout)
                mergeDiscovered(list)
            } catch (e) {
                console.log("Claude Usage: discovery parse error", e)
                discovering = false
            }
        }
    }

    Plasma5Support.DataSource {
        id: cacheWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var exitCode = data["exit code"] !== undefined ? data["exit code"] : data["exitCode"]
            var stderr = data["stderr"] || ""
            disconnectSource(sourceName)
            _cacheWriteBusy = false
            if (exitCode && exitCode !== 0)
                console.log("Claude Usage: cache write failed exit=", exitCode, stderr)
            drainCacheWriteQueue()
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

    Plasma5Support.DataSource {
        id: credReader
        engine: "executable"
        connectedSources: []
        // B001: sourceName → profileId (never array index)
        property var _pendingBySource: ({})

        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            var exitCode = data["exit code"] !== undefined ? data["exit code"] : data["exitCode"]
            disconnectSource(sourceName)

            var map = credReader._pendingBySource || {}
            var pendingId = map[sourceName] || ""
            // Remove this source from the pending map
            var nextMap = {}
            for (var k in map) {
                if (map.hasOwnProperty(k) && k !== sourceName)
                    nextMap[k] = map[k]
            }
            credReader._pendingBySource = nextMap

            // Fallback: parse cu-id from tagged command if map missed (should not happen)
            if (!pendingId && sourceName.indexOf("cu-id=") >= 0) {
                var m = sourceName.match(/cu-id=([^']+)/)
                if (m) pendingId = m[1]
            }

            var idx = findProfileIndex(pendingId)
            if (idx < 0 || idx >= profiles.length) {
                // Stale after rediscover/merge — drop, do not apply to wrong row
                console.log("Claude Usage: drop stale cred reply for", pendingId || sourceName)
                kickRefreshQueue()
                return
            }

            console.log("Claude Usage: credentials stdout len=", stdout.length, "exit=", exitCode, "id=", pendingId)

            if (stdout.length < 2) {
                noteAuthFailure(idx, tr("Not logged in"), "")
                kickRefreshQueue()
                return
            }
            try {
                var creds
                var prof = profiles[idx]
                var trimmed = stdout.trim()
                if (prof.isFlatFile && trimmed.indexOf("{") !== 0) {
                    creds = trimmed
                } else {
                    creds = JSON.parse(trimmed)
                }
                var auth = extractAuth(prof.provider, creds, prof)
                console.log("Claude Usage: auth token len=", (auth.token || "").length, "provider=", prof.provider, "plan=", auth.planName)
                var authPatch = {
                    accessToken: auth.token,
                    accountId: auth.accountId || "",
                    resourceUrl: auth.resourceUrl,
                    opencodeSlot: auth.opencodeSlot || prof.opencodeSlot,
                    planName: auth.planName || prof.planName
                }
                // Token/credential changed → lift auto-refresh suspension (B029)
                if (auth.token && auth.token !== prof.lastFailedToken) {
                    var clear = clearFailureStatePatch()
                    authPatch.authFailCount = clear.authFailCount
                    authPatch.authSuspended = clear.authSuspended
                    authPatch.autoRefreshHoldUntilMs = clear.autoRefreshHoldUntilMs
                    authPatch.lastFailedToken = clear.lastFailedToken
                    authPatch.backoffMultiplier = clear.backoffMultiplier
                }
                updateProfile(idx, authPatch)
                if (!auth.token) {
                    noteAuthFailure(idx, tr("Not logged in"), "")
                    kickRefreshQueue()
                    return
                }
                // Suspended with unchanged token: re-probe creds only, skip usage API (B029)
                prof = profiles[idx]
                if (prof.authSuspended && auth.token === prof.lastFailedToken) {
                    updateProfile(idx, {
                        loading: false,
                        lastFetchMs: Date.now(),
                        error: prof.error || tr("Token expired")
                    })
                    console.log("Claude Usage: auth still suspended, skip API", prof.id)
                    kickRefreshQueue()
                    return
                }
                fetchUsage(idx)
                // Next profile can start cat while XHR runs (loading still true on this row)
                kickRefreshQueue()
            } catch (e) {
                console.log("Claude Usage: credential parse error", e)
                noteAuthFailure(idx, tr("Not logged in"), "")
                kickRefreshQueue()
            }
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