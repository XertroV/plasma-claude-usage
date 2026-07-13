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
    property int nowMs: Date.now()

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
        var p = String(path).replace(/\/+$/, "")
        if (p.indexOf("/.claude/") >= 0 || p.indexOf("/.claude-") >= 0) {
            p = p.replace(/\/\.credentials\.json$/, "")
        }
        return p
    }

    function pathsEqual(a, b) {
        if (!a || !b) return false
        return String(a) === String(b) || normalizePath(a) === normalizePath(b)
    }

    function isLegacySingleInstance() {
        if (cfgValue("credentialsPath", "")) return true
        if (cfgValue("displayName", "")) return true
        var provider = cfgValue("provider", "claude")
        if (provider !== "claude") return true
        if (provider === "opencode") {
            var sub = cfgValue("opencodeSubProvider", "anthropic")
            if (sub !== "anthropic") return true
        }
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
        var enabled = parseJsonConfig(cfgValue("enabledProfilesJson", "[]"), [])
        if (!enabled || enabled.length === 0) return true
        return enabled.indexOf(meta.id) >= 0
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

    function discoverProfiles() {
        discovering = true
        discoverSource.connectSource("bash " + shellQuote(discoverScript))
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
        for (var c = 0; c < custom.length; c++) {
            var entry = custom[c]
            if (!entry || !entry.path || !entry.provider) continue
            merged.push({
                id: entry.id || (entry.provider + "-custom-" + c),
                provider: entry.provider,
                profileKey: entry.profileKey || "custom",
                configDir: entry.path,
                credPath: entry.credPath || entry.path,
                credInode: "custom:" + c,
                isFlatFile: !!entry.isFlatFile
            })
        }

        var visIds = visibleWindowIds()
        var rows = []
        for (var i = 0; i < merged.length; i++) {
            var meta = merged[i]
            if (!isProfileEnabled(meta)) continue
            rows.push({
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
                backoffMultiplier: 1,
                lastFetchMs: 0,
                visibleWindowIds: visIds
            })
        }
        profiles = rows
        discovering = false
        staggerRefreshAll()
    }

    function findProfileIndex(id) {
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i].id === id) return i
        }
        return -1
    }

    function updateProfile(idx, patch) {
        var copy = profiles.slice()
        var p = copy[idx]
        for (var k in patch) {
            if (patch.hasOwnProperty(k)) p[k] = patch[k]
        }
        copy[idx] = p
        profiles = copy
    }

    function staggerRefreshAll() {
        staggerIndex = 0
        if (profiles.length > 0) staggerRefresh.start()
    }

    function refreshAll() {
        staggerRefreshAll()
    }

    function refreshProfile(profileId) {
        var idx = findProfileIndex(profileId)
        if (idx < 0) return
        loadCredentials(idx)
    }

    function shellQuote(path) {
        return "'" + String(path).replace(/'/g, "'\\''") + "'"
    }

    function loadCredentials(idx) {
        var p = profiles[idx]
        updateProfile(idx, { loading: true, error: "" })
        var path = p.credPath
        credReader.connectSource("cat " + shellQuote(path) + " 2>/dev/null")
        credReader._pendingIdx = idx
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
        updateProfile(idx, {
            loading: false,
            error: "",
            planName: result.planName || p.planName,
            bankedResets: result.bankedResets || 0,
            windows: windows,
            lastUpdate: Qt.formatTime(new Date(), "hh:mm:ss"),
            lastFetchMs: Date.now(),
            backoffMultiplier: 1
        })
        lastGlobalUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
    }

    function fetchUsage(idx) {
        var p = profiles[idx]
        if (!p.accessToken) {
            updateProfile(idx, { loading: false, error: tr("Not logged in") })
            return
        }
        var ep = effectiveProvider(p)
        if (ep === "grok") {
            fetchGrok(idx)
            return
        }

        var xhr = new XMLHttpRequest()
        xhr.open("GET", usageUrl(p))
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

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var cur = profiles[idx]
            if (!cur) return
            if (xhr.status === 200) {
                try {
                    var data = JSON.parse(xhr.responseText)
                    var result = emptyUsage()
                    if (ep === "claude" || ep === "anthropic") result = QP.parseClaude(data)
                    else if (ep === "codex" || ep === "openai") result = QP.parseCodex(data)
                    else if (ep === "minimax") result = QP.parseMinimax(data)
                    else if (ep === "zai") result = QP.parseZai(data)
                    else if (ep === "kimi") result = QP.parseKimi(data)
                    if (!result.planName && cur.planName) result.planName = cur.planName
                    applyUsageResult(idx, result)
                } catch (e) {
                    updateProfile(idx, { loading: false, error: "Parse error" })
                }
            } else if (xhr.status === 429) {
                var mult = (cur.backoffMultiplier || 1) * 2
                updateProfile(idx, { loading: false, error: tr("Rate limited"), backoffMultiplier: Math.min(mult, 6) })
            } else if (xhr.status === 401) {
                updateProfile(idx, { loading: false, error: tr("Token expired") })
            } else {
                updateProfile(idx, { loading: false, error: tr("API error") + " (" + xhr.status + ")" })
            }
        }
        xhr.send()
    }

    function emptyUsage() {
        return { planName: "", bankedResets: 0, windows: [] }
    }

    function fetchGrok(idx) {
        var p = profiles[idx]
        var gen = (p.grokFetchGen || 0) + 1
        updateProfile(idx, { grokFetchGen: gen, grokPending: 2, grokDefaultBody: null, grokCreditsBody: null, grokDefaultStatus: 0 })
        grokGet(idx, gen, "https://cli-chat-proxy.grok.com/v1/billing", function(ok, body, status) {
            var patch = { grokDefaultStatus: status }
            if (ok) patch.grokDefaultBody = body
            else if (status === 401 || status === 403) patch.error = tr("Token expired")
            finishGrokPart(idx, gen, patch)
        })
        grokGet(idx, gen, "https://cli-chat-proxy.grok.com/v1/billing?format=credits", function(ok, body) {
            var patch = {}
            if (ok) patch.grokCreditsBody = body
            finishGrokPart(idx, gen, patch)
        })
    }

    function grokGet(idx, gen, url, callback) {
        var p = profiles[idx]
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.timeout = 25000
        xhr.setRequestHeader("Authorization", "Bearer " + p.accessToken)
        xhr.setRequestHeader("Accept", "application/json")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("x-grok-client-version", "0.2.93")
        xhr.setRequestHeader("x-grok-client-surface", "grok-build")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (profiles[idx].grokFetchGen !== gen) return
            if (xhr.status === 200) {
                try { callback(true, JSON.parse(xhr.responseText), xhr.status) }
                catch (e) { callback(false, null, xhr.status) }
            } else {
                callback(false, null, xhr.status || 0)
            }
        }
        xhr.ontimeout = function() { callback(false, null, 0) }
        xhr.send()
    }

    function finishGrokPart(idx, gen, patch) {
        var p = profiles[idx]
        if (!p || p.grokFetchGen !== gen) return
        patch.grokPending = Math.max(0, (p.grokPending || 2) - 1)
        updateProfile(idx, patch)
        var cur = profiles[idx]
        if (!cur || cur.grokPending > 0) return
        p = cur
        if (!p.grokDefaultBody) {
            updateProfile(idx, { loading: false, error: p.error || tr("API error") })
            return
        }
        try {
            var result = QP.parseGrok(p.grokDefaultBody, p.grokCreditsBody)
            applyUsageResult(idx, result)
        } catch (e) {
            updateProfile(idx, { loading: false, error: "Parse error" })
        }
    }

    function tickWindows() {
        nowMs = Date.now()
        var copy = profiles.slice()
        var changed = false
        for (var i = 0; i < copy.length; i++) {
            var wins = copy[i].windows
            if (!wins || !wins.length) continue
            var newWins = []
            for (var j = 0; j < wins.length; j++) {
                var w = {}
                for (var key in wins[j]) w[key] = wins[j][key]
                QC.updateTimePercent(w, nowMs)
                newWins.push(w)
            }
            copy[i].windows = newWins
            changed = true
        }
        if (changed) profiles = copy
    }

    function dueProfiles() {
        var due = []
        var now = Date.now()
        for (var i = 0; i < profiles.length; i++) {
            var p = profiles[i]
            var interval = refreshIntervalMs(p.provider) * (p.backoffMultiplier || 1)
            if (!p.lastFetchMs || (now - p.lastFetchMs) >= interval) due.push(p.id)
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
        id: credReader
        engine: "executable"
        connectedSources: []
        property int _pendingIdx: -1

        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            disconnectSource(sourceName)
            var idx = credReader._pendingIdx
            credReader._pendingIdx = -1
            if (idx < 0 || idx >= profiles.length) return

            if (stdout.length < 2) {
                updateProfile(idx, { loading: false, error: tr("Not logged in") })
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
                updateProfile(idx, {
                    accessToken: auth.token,
                    accountId: auth.accountId || "",
                    resourceUrl: auth.resourceUrl,
                    opencodeSlot: auth.opencodeSlot || prof.opencodeSlot,
                    planName: auth.planName || prof.planName
                })
                fetchUsage(idx)
            } catch (e) {
                updateProfile(idx, { loading: false, error: tr("Not logged in") })
            }
        }
    }

    property int staggerIndex: 0

    Timer {
        id: staggerRefresh
        interval: 2000
        repeat: true
        onTriggered: {
            if (controller.staggerIndex >= controller.profiles.length) {
                stop()
                return
            }
            controller.loadCredentials(controller.staggerIndex)
            controller.staggerIndex++
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
            var due = controller.dueProfiles()
            for (var i = 0; i < due.length; i++) {
                var idx = controller.findProfileIndex(due[i])
                if (idx >= 0) controller.loadCredentials(idx)
            }
        }
    }

}