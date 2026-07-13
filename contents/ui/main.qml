import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // Translations
    Translations {
        id: i18n
        currentLanguage: Plasmoid.configuration.language || "system"
    }

    property real sessionUsagePercent: 0
    property real weeklyUsagePercent: 0
    // Per-model weekly limits from limits[] array (weekly_scoped) - list of {name, percent} objects
    property var weeklyModelLimits: []
    // Additional rate limits (Codex Spark, etc.) - list of {name, percent} objects
    property var additionalLimits: []
    property string lastUpdate: ""
    property string planName: ""
    property string sessionReset: ""
    property string weeklyReset: ""
    property string errorMsg: ""
    property string accessToken: ""
    property bool isLoading: false
    property var sessionResetTime: null
    property var weeklyResetTime: null
    property real sessionPeriodMs: 5 * 60 * 60 * 1000  // default 5 hours
    property real weeklyPeriodMs: 7 * 24 * 60 * 60 * 1000  // default 7 days
    // Writable labels set by parsers (dynamic window durations for Codex / Grok)
    property string sessionLabel: i18n.tr("Session (5hr)")
    property string weeklyLabel: i18n.tr("Weekly (7day)")
    property bool hasSessionWindow: false
    property bool hasWeeklyWindow: false
    property int bankedResets: 0
    // Grok dual-fetch scratch (default monthly + format=credits weekly)
    property var grokDefaultBody: null
    property var grokCreditsBody: null
    property int grokFetchPending: 0
    property int grokFetchGen: 0
    property int grokDefaultStatus: 0
    readonly property bool isKimi: provider === "opencode" && opencodeSubProvider === "kimi"
    readonly property bool isGrok: provider === "grok"
    readonly property bool hideModelSection: provider === "zai" || isKimi || isGrok

    readonly property string provider: Plasmoid.configuration.provider || "claude"
    readonly property string opencodeSubProvider: Plasmoid.configuration.opencodeSubProvider || "anthropic"
    readonly property int opencodeAccountIndex: Plasmoid.configuration.opencodeAccountIndex || 0
    readonly property string usageApiUrl: {
        if (provider === "codex") return "https://chatgpt.com/backend-api/wham/usage"
        if (provider === "zai") return "https://api.z.ai/api/monitor/usage/quota/limit"
        if (provider === "grok") return "https://cli-chat-proxy.grok.com/v1/billing"
        if (provider === "opencode") {
            if (opencodeSubProvider === "zai") return "https://api.z.ai/api/monitor/usage/quota/limit"
            if (opencodeSubProvider === "openai") return "https://chatgpt.com/backend-api/wham/usage"
            if (opencodeSubProvider === "kimi") return "https://api.kimi.com/coding/v1/usages"
            return "https://api.anthropic.com/api/oauth/usage"  // anthropic + others
        }
        return "https://api.anthropic.com/api/oauth/usage"
    }
    readonly property string displayName: Plasmoid.configuration.displayName || (function() {
        if (provider === "codex") return "Codex"
        if (provider === "zai") return "Z.ai"
        if (provider === "grok") return "Grok"
        if (provider === "opencode") {
            var names = { "anthropic": "Claude", "openai": "Codex", "zai": "Z.ai", "kimi": "Kimi", "gemini": "Gemini" }
            return (names[opencodeSubProvider] || opencodeSubProvider) + " (OC)"
        }
        return "Claude"
    })()
    property string accountId: ""
    property real sessionTimePercent: 0
    property real weeklyTimePercent: 0
    property bool modelSectionExpanded: false
    property real requiredPace: 0

    // Data source for reading credentials file
    Plasma5Support.DataSource {
        id: fileReader
        engine: "executable"
        connectedSources: []

        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            disconnectSource(sourceName)

            console.log("Claude Usage: Got credentials, length:", stdout.length)

            if (stdout.length > 10) {
                try {
                    var creds = JSON.parse(stdout)

                    if (root.provider === "codex") {
                        parseCodexCredentials(creds)
                    } else if (root.provider === "zai") {
                        parseZaiCredentials(creds)
                    } else if (root.provider === "grok") {
                        parseGrokCredentials(creds)
                    } else if (root.provider === "opencode") {
                        parseOpencodeCredentials(creds)
                    } else {
                        parseClaudeCredentials(creds)
                    }
                } catch (e) {
                    console.log("Claude Usage: Failed to parse credentials:", e)
                    root.errorMsg = "Not logged in"
                    root.isLoading = false
                }
            } else {
                console.log("Claude Usage: No credentials file found")
                root.errorMsg = "Not logged in"
                root.isLoading = false
            }
        }
    }

    function parseClaudeCredentials(creds) {
        var oauth = creds.claudeAiOauth || {}
        root.accessToken = oauth.accessToken || ""

        var tier = oauth.rateLimitTier || "default_claude_pro"
        var planMap = {
            "default_claude_pro": "Pro",
            "default_claude_max_5x": "Max 5x",
            "default_claude_max_20x": "Max 20x"
        }
        root.planName = planMap[tier] || tier

        console.log("Claude Usage: Token found, plan:", root.planName)

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function parseCodexCredentials(creds) {
        // Support both native ~/.codex/auth.json and OpenCode auth.json formats
        var tokens = creds.tokens || {}
        var openai = creds.openai || {}
        root.accessToken = tokens.access_token || openai.access || ""
        root.accountId = tokens.account_id || openai.accountId || ""

        // Try to extract plan from id_token JWT payload
        var idToken = tokens.id_token || ""
        if (idToken) {
            try {
                var parts = idToken.split(".")
                if (parts.length >= 2) {
                    var payload = JSON.parse(Qt.atob(parts[1]))
                    var plan = payload.plan_type || ""
                    if (plan) {
                        root.planName = plan.charAt(0).toUpperCase() + plan.slice(1)
                    }
                }
            } catch (e) {
                console.log("Claude Usage: Could not parse Codex id_token:", e)
            }
        }

        console.log("Claude Usage: Codex token found, plan:", root.planName)

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function parseZaiCredentials(creds) {
        // OpenCode auth.json format: { "zai-coding-plan": { "type": "api", "key": "..." } }
        var zai = creds["zai-coding-plan"] || {}
        root.accessToken = zai.key || ""

        console.log("Claude Usage: Z.ai token found, length:", root.accessToken.length)

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    // Grok Build ~/.grok/auth.json: map of account keys → { key, expires_at, create_time, ... }
    // Prefer newest non-expired entry; if all expired, still return newest so API can 401 cleanly.
    function parseGrokCredentials(creds) {
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
            candidates.push({
                key: token,
                expiresAt: isNaN(expMs) ? null : expMs,
                createTime: isNaN(createMs) ? null : createMs
            })
        }

        if (candidates.length === 0) {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
            return
        }

        var now = Date.now()
        candidates.sort(function(a, b) {
            var aFresh = a.expiresAt === null || a.expiresAt > now
            var bFresh = b.expiresAt === null || b.expiresAt > now
            if (aFresh !== bFresh) return aFresh ? -1 : 1
            var ac = a.createTime === null ? 0 : a.createTime
            var bc = b.createTime === null ? 0 : b.createTime
            if (ac !== bc) return bc - ac
            var ae = a.expiresAt === null ? 0 : a.expiresAt
            var be = b.expiresAt === null ? 0 : b.expiresAt
            return be - ae
        })

        root.accessToken = candidates[0].key
        root.planName = "Grok Build"
        console.log("Claude Usage: Grok token found, length:", root.accessToken.length)

        if (root.accessToken) {
            fetchGrokUsage()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function parseOpencodeCredentials(creds) {
        var sub = root.opencodeSubProvider || "anthropic"

        if (sub === "anthropic") {
            // anthropic-accounts.json: { accounts: [{ access, expires, ... }] }
            if (creds.accounts && Array.isArray(creds.accounts)) {
                var accountIndex = root.opencodeAccountIndex || 0
                if (accountIndex < creds.accounts.length) {
                    root.accessToken = creds.accounts[accountIndex].access || ""
                    console.log("Claude Usage: OpenCode anthropic account", accountIndex, "token length:", root.accessToken.length)
                }
            } else {
                // Fallback: auth.json with { anthropic: { access, expires } }
                root.accessToken = (creds.anthropic || {}).access || ""
                console.log("Claude Usage: OpenCode anthropic fallback token length:", root.accessToken.length)
            }
        } else {
            // auth.json: { "<sub>": { access: "..." } } or { "<sub>": { key: "..." } }
            // Kimi credentials are stored under "kimi-for-coding" key in OpenCode's auth.json
            var lookupKey = sub === "kimi" ? "kimi-for-coding" : sub
            var subCreds = creds[lookupKey] || creds[sub] || {}
            root.accessToken = subCreds.access || subCreds.key || ""
            console.log("Claude Usage: OpenCode", sub, "token length:", root.accessToken.length)
        }

        if (root.accessToken) {
            fetchUsageFromApi()
        } else {
            root.errorMsg = i18n.tr("Not logged in")
            root.isLoading = false
        }
    }

    function loadCredentials() {
        root.isLoading = true
        root.errorMsg = ""
        root.bankedResets = 0
        var credPath = Plasmoid.configuration.credentialsPath || ""
        if (credPath === "") {
            var defaultPath
            if (root.provider === "codex") defaultPath = "$HOME/.codex/auth.json"
            else if (root.provider === "zai") defaultPath = "$HOME/.local/share/opencode/auth.json"
            else if (root.provider === "grok") defaultPath = "$HOME/.grok/auth.json"
            else if (root.provider === "opencode") {
                // Anthropic gets the multi-account file; all others use auth.json
                if (root.opencodeSubProvider === "anthropic")
                    defaultPath = "$HOME/.config/opencode/anthropic-accounts.json"
                else
                    defaultPath = "$HOME/.local/share/opencode/auth.json"
            }
            else defaultPath = "$HOME/.claude/.credentials.json"
            fileReader.connectSource("cat " + defaultPath + " 2>/dev/null")
        } else {
            // Shell-quote user-provided path to prevent command injection
            var safePath = "'" + credPath.replace(/'/g, "'\\''") + "'"
            fileReader.connectSource("cat " + safePath + " 2>/dev/null")
        }
    }

    function fetchUsageFromApi() {
        // Grok needs two billing endpoints; use dedicated dual-fetch.
        if (root.provider === "grok") {
            fetchGrokUsage()
            return
        }

        var xhr = new XMLHttpRequest()
        xhr.open("GET", usageApiUrl)
        xhr.setRequestHeader("Content-Type", "application/json")

        var isZai = root.provider === "zai" || (root.provider === "opencode" && root.opencodeSubProvider === "zai")
        if (isZai) {
            // Z.ai API uses raw API key without "Bearer" prefix
            xhr.setRequestHeader("Authorization", root.accessToken)
        } else {
            xhr.setRequestHeader("Authorization", "Bearer " + root.accessToken)
        }

        var isAnthropic = root.provider === "claude" || (root.provider === "opencode" && root.opencodeSubProvider === "anthropic")
        var isCodex = root.provider === "codex" || (root.provider === "opencode" && root.opencodeSubProvider === "openai")
        if (isAnthropic) {
            xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20")
        } else if (isCodex) {
            if (root.accountId) {
                xhr.setRequestHeader("ChatGPT-Account-Id", root.accountId)
            }
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                root.isLoading = false

                if (xhr.status === 200) {
                    try {
                        var data = JSON.parse(xhr.responseText)

                        var sub = root.provider === "opencode" ? root.opencodeSubProvider : root.provider
                        if (sub === "codex" || sub === "openai") {
                            parseCodexUsage(data)
                        } else if (sub === "zai") {
                            parseZaiUsage(data)
                        } else if (sub === "kimi") {
                            parseKimiUsage(data)
                        } else {
                            parseClaudeUsage(data)
                        }

                        root.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
                        root.errorMsg = ""

                        console.log("Claude Usage: API success - session:", root.sessionUsagePercent, "weekly:", root.weeklyUsagePercent)
                    } catch (e) {
                        console.log("Claude Usage: JSON parse error:", e)
                        root.errorMsg = "Parse error"
                    }
                } else if (xhr.status === 401) {
                    root.errorMsg = i18n.tr("Token expired")
                    console.log("Claude Usage: 401 Unauthorized")
                } else {
                    root.errorMsg = i18n.tr("API error") + " (" + xhr.status + ")"
                    console.log("Claude Usage: API error:", xhr.status, xhr.statusText)
                }
            }
        }

        xhr.send()
    }

    // Grok Build: default monthly $ allowance + ?format=credits weekly product %.
    // Use a generation counter so overlapping refreshes ignore stale XHR callbacks.
    function fetchGrokUsage() {
        root.grokFetchGen += 1
        var gen = root.grokFetchGen
        root.grokDefaultBody = null
        root.grokCreditsBody = null
        root.grokFetchPending = 2
        root.grokDefaultStatus = 0
        root.errorMsg = ""
        var base = "https://cli-chat-proxy.grok.com/v1/billing"
        grokGet(base, gen, function(ok, body, status) {
            if (gen !== root.grokFetchGen) return
            root.grokDefaultStatus = status
            if (ok) root.grokDefaultBody = body
            else if (status === 401 || status === 403) root.errorMsg = i18n.tr("Token expired")
            finishGrokFetch(gen)
        })
        grokGet(base + "?format=credits", gen, function(ok, body, status) {
            if (gen !== root.grokFetchGen) return
            if (ok) root.grokCreditsBody = body
            finishGrokFetch(gen)
        })
    }

    function grokGet(url, gen, callback) {
        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        xhr.timeout = 25000
        xhr.setRequestHeader("Authorization", "Bearer " + root.accessToken)
        xhr.setRequestHeader("Accept", "application/json")
        xhr.setRequestHeader("Content-Type", "application/json")
        xhr.setRequestHeader("x-grok-client-version", "0.2.93")
        xhr.setRequestHeader("x-grok-client-surface", "grok-build")
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if (gen !== root.grokFetchGen) return
            if (xhr.status === 200) {
                try {
                    callback(true, JSON.parse(xhr.responseText), xhr.status)
                } catch (e) {
                    console.log("Claude Usage: Grok JSON parse error:", e)
                    callback(false, null, xhr.status)
                }
            } else {
                console.log("Claude Usage: Grok API error:", url, xhr.status, xhr.statusText)
                callback(false, null, xhr.status || 0)
            }
        }
        xhr.ontimeout = function() {
            if (gen !== root.grokFetchGen) return
            console.log("Claude Usage: Grok API timeout:", url)
            callback(false, null, 0)
        }
        xhr.send()
    }

    function finishGrokFetch(gen) {
        if (gen !== root.grokFetchGen) return
        root.grokFetchPending = Math.max(0, root.grokFetchPending - 1)
        if (root.grokFetchPending > 0) return

        root.isLoading = false
        // Default monthly body is required; credits is best-effort.
        if (!root.grokDefaultBody) {
            if (root.errorMsg === "") {
                var st = root.grokDefaultStatus
                root.errorMsg = st ? (i18n.tr("API error") + " (" + st + ")") : (i18n.tr("API error") + " (timeout)")
            }
            return
        }
        // Reject error-only payloads (HTTP 200 with error, no config).
        if (root.grokDefaultBody.error && !root.grokDefaultBody.config) {
            var em = (root.grokDefaultBody.error && root.grokDefaultBody.error.message)
                || root.grokDefaultBody.message || "billing error"
            root.errorMsg = String(em)
            return
        }
        try {
            parseGrokUsage(root.grokDefaultBody, root.grokCreditsBody)
            if (!root.hasSessionWindow && !root.hasWeeklyWindow && root.additionalLimits.length === 0) {
                root.errorMsg = "No usage data"
                return
            }
            root.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
            root.errorMsg = ""
            console.log("Claude Usage: Grok success - session:", root.sessionUsagePercent, "weekly:", root.weeklyUsagePercent)
        } catch (e) {
            console.log("Claude Usage: Grok parse error:", e)
            root.errorMsg = "Parse error"
        }
    }

    // Prefer whole-day labels for exact day multiples (604800s → "7d" not "168h").
    // Mirrors quotas format_window_duration (src/providers/codex.rs).
    function formatWindowDuration(seconds) {
        var s = Math.floor(Number(seconds) || 0)
        if (s >= 86400 && s % 86400 === 0) return (s / 86400) + "d"
        if (s >= 3600 && s % 3600 === 0) return (s / 3600) + "h"
        if (s > 0) return s + "s"
        return "0h"
    }

    // Match quotas: only emit a window when reset or usage is present.
    // Do NOT treat bare limit_window_seconds as presence (zeroed secondary shells).
    function codexWindowHasData(win) {
        if (!win || typeof win !== "object") return false
        return (Number(win.reset_at) > 0) || (Number(win.used_percent) > 0)
    }

    function shortCodexLabel(name) {
        var raw = name || ""
        var stripped = raw.replace(/^GPT-5\.3-/i, "").replace(/^gpt-5\.3-/i, "")
        var parts = stripped.toLowerCase().split("-")
        var last = parts.length ? parts[parts.length - 1] : stripped.toLowerCase()
        var label = last.substring(0, 10)
        return label === "spark" ? "spk" : label
    }

    function applyWindowSlot(slot, win, defaultPeriodSec) {
        var pct = (win && win.used_percent != null) ? Number(win.used_percent) : 0
        var secs = (win && win.limit_window_seconds) ? Number(win.limit_window_seconds) : defaultPeriodSec
        var resetAt = (win && win.reset_at) ? new Date(Number(win.reset_at) * 1000) : null
        var label = formatWindowDuration(secs)

        if (slot === "session") {
            root.hasSessionWindow = true
            root.sessionUsagePercent = pct
            root.sessionPeriodMs = secs * 1000
            root.sessionLabel = label
            if (resetAt) {
                root.sessionResetTime = resetAt
                root.sessionReset = secs >= 86400
                    ? Qt.formatDateTime(resetAt, "MMM d, hh:mm")
                    : Qt.formatTime(resetAt, "hh:mm")
                updateSessionTimePercent()
            } else {
                root.sessionResetTime = null
                root.sessionReset = ""
                root.sessionTimePercent = 0
            }
        } else {
            root.hasWeeklyWindow = true
            root.weeklyUsagePercent = pct
            root.weeklyPeriodMs = secs * 1000
            root.weeklyLabel = label
            if (resetAt) {
                root.weeklyResetTime = resetAt
                root.weeklyReset = Qt.formatDateTime(resetAt, "MMM d, hh:mm")
                updateWeeklyTimePercent()
            } else {
                root.weeklyResetTime = null
                root.weeklyReset = ""
                root.weeklyTimePercent = 0
            }
        }
    }

    function clearSessionSlot() {
        root.hasSessionWindow = false
        root.sessionUsagePercent = 0
        root.sessionResetTime = null
        root.sessionReset = ""
        root.sessionTimePercent = 0
        root.sessionPeriodMs = 5 * 60 * 60 * 1000
        root.sessionLabel = i18n.tr("Session (5hr)")
    }

    function clearWeeklySlot() {
        root.hasWeeklyWindow = false
        root.weeklyUsagePercent = 0
        root.weeklyResetTime = null
        root.weeklyReset = ""
        root.weeklyTimePercent = 0
        root.weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
        root.weeklyLabel = i18n.tr("Weekly (7day)")
    }

    function parseClaudeUsage(data) {
        var fiveHour = data.five_hour || {}
        var sevenDay = data.seven_day || {}
        var sevenDayOpus = data.seven_day_opus || {}

        root.hasSessionWindow = true
        root.hasWeeklyWindow = true
        root.sessionLabel = i18n.tr("Session (5hr)")
        root.weeklyLabel = i18n.tr("Weekly (7day)")
        root.sessionPeriodMs = 5 * 60 * 60 * 1000
        root.weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
        root.sessionUsagePercent = fiveHour.utilization || 0
        root.weeklyUsagePercent = sevenDay.utilization || 0
        root.additionalLimits = []
        root.bankedResets = 0

        // Parse per-model weekly limits from limits[] array (weekly_scoped entries)
        var modelLimits = []
        var limits = data.limits || []
        for (var i = 0; i < limits.length; i++) {
            var entry = limits[i]
            if (entry.kind === "weekly_scoped" && entry.scope && entry.scope.model) {
                var modelName = entry.scope.model.display_name || entry.scope.model.id || "Unknown"
                modelLimits.push({ name: modelName, percent: entry.percent || 0 })
            }
        }

        // Fallback: use legacy top-level fields if limits[] had no weekly_scoped entries
        if (modelLimits.length === 0) {
            if (sevenDayOpus && sevenDayOpus.utilization) {
                modelLimits.push({ name: "Opus", percent: sevenDayOpus.utilization })
            }
        }
        root.weeklyModelLimits = modelLimits

        if (fiveHour.resets_at) {
            root.sessionResetTime = new Date(fiveHour.resets_at)
            root.sessionReset = Qt.formatTime(root.sessionResetTime, "hh:mm")
            updateSessionTimePercent()
        } else {
            root.sessionResetTime = null
            root.sessionReset = ""
            root.sessionTimePercent = 0
        }
        if (sevenDay.resets_at) {
            root.weeklyResetTime = new Date(sevenDay.resets_at)
            root.weeklyReset = Qt.formatDateTime(root.weeklyResetTime, "MMM d, hh:mm")
            updateWeeklyTimePercent()
        } else {
            root.weeklyResetTime = null
            root.weeklyReset = ""
            root.weeklyTimePercent = 0
        }
        updateRequiredPace()
    }

    function parseCodexUsage(data) {
        var rateLimit = data.rate_limit || {}
        var primary = rateLimit.primary_window || null
        var secondary = rateLimit.secondary_window || null
        var primaryOk = codexWindowHasData(primary)
        var secondaryOk = codexWindowHasData(secondary)

        root.weeklyModelLimits = []
        root.bankedResets = 0
        clearSessionSlot()
        clearWeeklySlot()

        // Classic Plus shape: primary ~5h + secondary ~7d.
        // Pro (live 2026-07): single primary of 604800s with secondary=null —
        // previously mis-labeled as "Session (5hr)" with weekly stuck at 0%
        // and "168h" if duration was formatted as hours only.
        if (primaryOk && secondaryOk) {
            applyWindowSlot("session", primary, 18000)
            applyWindowSlot("weekly", secondary, 604800)
        } else if (primaryOk) {
            var pSec = Number(primary.limit_window_seconds) || 18000
            if (pSec >= 86400) {
                applyWindowSlot("weekly", primary, 604800)
            } else {
                applyWindowSlot("session", primary, 18000)
            }
        } else if (secondaryOk) {
            applyWindowSlot("weekly", secondary, 604800)
        }

        // Additional rate limits (e.g. GPT-5.3-Codex-Spark) — emit each window
        // with data (mirrors quotas push_rate_limit_windows per extra).
        var extras = data.additional_rate_limits || []
        var parsed = []
        for (var i = 0; i < extras.length; i++) {
            var entry = extras[i]
            var rawName = entry.limit_name || entry.metered_feature || ("Limit " + i)
            var short = shortCodexLabel(rawName)
            var rl = entry.rate_limit || {}
            var wins = []
            if (codexWindowHasData(rl.primary_window)) wins.push(rl.primary_window)
            if (codexWindowHasData(rl.secondary_window)) wins.push(rl.secondary_window)
            if (wins.length === 0) continue
            for (var j = 0; j < wins.length; j++) {
                var win = wins[j]
                var wSec = Number(win.limit_window_seconds) || 0
                var label = wSec > 0 ? (short + "/" + formatWindowDuration(wSec)) : short
                var pct = win.used_percent != null ? Number(win.used_percent) : 0
                parsed.push({ name: label, percent: isNaN(pct) ? 0 : pct })
            }
        }
        root.additionalLimits = parsed

        // Banked full-rate-limit resets (summary count from usage payload).
        var banked = data.rate_limit_reset_credits || null
        if (banked && banked.available_count != null) {
            root.bankedResets = Number(banked.available_count) || 0
        }

        // Credits balance as additional row when present and non-zero.
        var credits = data.credits || {}
        if (!credits.unlimited && credits.balance) {
            var bal = parseFloat(credits.balance)
            if (!isNaN(bal) && bal > 0) {
                root.additionalLimits = root.additionalLimits.concat([
                    { name: "credits $" + bal.toFixed(2), percent: 0 }
                ])
            }
        }

        // Plan name from API (prefer over JWT when present)
        if (data.plan_type) {
            var plan = data.plan_type
            root.planName = "Codex / " + plan.charAt(0).toUpperCase() + plan.slice(1)
        }
        updateRequiredPace()
    }

    // xAI amounts are USD cents as {val: number|string}. Return whole dollars (float).
    function grokCentsToDollars(v) {
        if (v == null) return 0
        var cents = 0
        if (typeof v === "object") {
            if (v.val != null) cents = Number(v.val)
        } else {
            cents = Number(v)
        }
        if (isNaN(cents)) return 0
        return Math.abs(cents) / 100.0
    }

    function parseGrokUsage(defaultBody, creditsBody) {
        var defaultCfg = (defaultBody && defaultBody.config) ? defaultBody.config : (defaultBody || {})
        var creditsCfg = (creditsBody && creditsBody.config) ? creditsBody.config : (creditsBody || {})

        clearSessionSlot()
        clearWeeklySlot()
        root.weeklyModelLimits = []
        root.additionalLimits = []
        root.bankedResets = 0

        // Weekly product usage from ?format=credits → session slot (shorter window)
        var period = creditsCfg.currentPeriod || creditsCfg.current_period || null
        var periodType = (period && period.type) ? String(period.type) : "USAGE_PERIOD_TYPE_WEEKLY"
        var periodLabel = "weekly"
        var upper = periodType.toUpperCase()
        if (upper.indexOf("WEEK") >= 0) periodLabel = "weekly"
        else if (upper.indexOf("MONTH") >= 0) periodLabel = "monthly"
        else if (upper.indexOf("DAY") >= 0) periodLabel = "daily"
        else periodLabel = "period"

        var periodStart = period && period.start ? new Date(period.start) : null
        var periodEnd = period && period.end ? new Date(period.end) : null
        if (!periodStart && creditsCfg.billingPeriodStart)
            periodStart = new Date(creditsCfg.billingPeriodStart)
        if (!periodEnd && creditsCfg.billingPeriodEnd)
            periodEnd = new Date(creditsCfg.billingPeriodEnd)

        var periodMs = 7 * 24 * 60 * 60 * 1000
        if (periodStart && periodEnd && !isNaN(periodStart.getTime()) && !isNaN(periodEnd.getTime())) {
            periodMs = Math.max(1000, periodEnd.getTime() - periodStart.getTime())
        }

        var weeklyPct = null
        var productLabel = periodLabel
        var products = creditsCfg.productUsage || creditsCfg.product_usage || []
        if (products && products.length) {
            for (var i = 0; i < products.length; i++) {
                var prod = products[i]
                var name = prod.product || "product"
                var pct = prod.usagePercent != null ? Number(prod.usagePercent)
                        : (prod.usage_percent != null ? Number(prod.usage_percent) : null)
                if (pct == null || isNaN(pct)) continue
                var short = name === "GrokBuild" ? "build" : name
                if (weeklyPct === null) {
                    weeklyPct = pct
                    productLabel = periodLabel + "/" + short
                } else {
                    root.additionalLimits = root.additionalLimits.concat([
                        { name: periodLabel + "/" + short, percent: pct }
                    ])
                }
            }
        }
        if (weeklyPct === null) {
            var overall = creditsCfg.creditUsagePercent != null ? Number(creditsCfg.creditUsagePercent)
                        : (creditsCfg.credit_usage_percent != null ? Number(creditsCfg.credit_usage_percent) : null)
            if (overall != null && !isNaN(overall)) {
                weeklyPct = overall
                productLabel = periodLabel
            }
        }

        if (weeklyPct !== null) {
            root.hasSessionWindow = true
            root.sessionUsagePercent = weeklyPct
            root.sessionPeriodMs = periodMs
            root.sessionLabel = productLabel
            if (periodEnd && !isNaN(periodEnd.getTime())) {
                root.sessionResetTime = periodEnd
                root.sessionReset = Qt.formatDateTime(periodEnd, "MMM d, hh:mm")
                updateSessionTimePercent()
            }
        }

        // Monthly $ allowance from default billing → weekly slot (as %)
        var monthStart = defaultCfg.billingPeriodStart ? new Date(defaultCfg.billingPeriodStart) : null
        var monthEnd = defaultCfg.billingPeriodEnd ? new Date(defaultCfg.billingPeriodEnd) : null
        var monthMs = 30 * 24 * 60 * 60 * 1000
        if (monthStart && monthEnd && !isNaN(monthStart.getTime()) && !isNaN(monthEnd.getTime())) {
            monthMs = Math.max(1000, monthEnd.getTime() - monthStart.getTime())
        }

        var limitDollars = grokCentsToDollars(defaultCfg.monthlyLimit || defaultCfg.monthly_limit)
        var usedDollars = grokCentsToDollars(defaultCfg.used)
        if (limitDollars > 0 || usedDollars > 0) {
            var monthPct = limitDollars > 0 ? (usedDollars / limitDollars) * 100 : 0
            root.hasWeeklyWindow = true
            root.weeklyUsagePercent = Math.min(100, monthPct)
            root.weeklyPeriodMs = monthMs
            root.weeklyLabel = "monthly $" + formatDollars(usedDollars) + "/$" + formatDollars(limitDollars)
            if (monthEnd && !isNaN(monthEnd.getTime())) {
                root.weeklyResetTime = monthEnd
                root.weeklyReset = Qt.formatDateTime(monthEnd, "MMM d, hh:mm")
                updateWeeklyTimePercent()
            }
        }

        // On-demand cap if set
        var odCap = grokCentsToDollars(creditsCfg.onDemandCap || creditsCfg.on_demand_cap
                    || defaultCfg.onDemandCap || defaultCfg.on_demand_cap)
        var odUsed = grokCentsToDollars(creditsCfg.onDemandUsed || creditsCfg.on_demand_used
                    || defaultCfg.onDemandUsed || defaultCfg.on_demand_used)
        if (odCap > 0) {
            root.additionalLimits = root.additionalLimits.concat([
                { name: "on-demand $" + formatDollars(odUsed) + "/$" + formatDollars(odCap),
                  percent: Math.min(100, (odUsed / odCap) * 100) }
            ])
        }

        var prepaid = grokCentsToDollars(creditsCfg.prepaidBalance || creditsCfg.prepaid_balance)
        if (prepaid > 0) {
            root.additionalLimits = root.additionalLimits.concat([
                { name: "balance $" + formatDollars(prepaid), percent: 0 }
            ])
        }

        // Only overwrite plan from credits when credits body is present.
        if (creditsBody) {
            var unified = creditsCfg.isUnifiedBillingUser || creditsCfg.is_unified_billing_user
            root.planName = unified ? "Grok Build" : "Grok"
        } else if (!root.planName) {
            root.planName = "Grok Build"
        }
        updateRequiredPace()
    }

    function formatDollars(n) {
        var v = Number(n) || 0
        // Whole dollars when clean; otherwise two decimals (e.g. $29.31).
        if (Math.abs(v - Math.round(v)) < 0.005) return String(Math.round(v))
        return v.toFixed(2)
    }

    function parseZaiUsage(data) {
        // Response: { data: { limits: [...], planName: "..." } } or { limits: [...] }
        var container = data.data || data
        var limits = container.limits || []

        clearSessionSlot()
        clearWeeklySlot()
        root.sessionLabel = i18n.tr("Tokens (5hr)")
        root.weeklyLabel = i18n.tr("Monthly (MCP)")
        root.bankedResets = 0

        // Find limit entries by type
        var tokenLimit = null
        var timeLimit = null
        for (var i = 0; i < limits.length; i++) {
            if (limits[i].type === "TOKENS_LIMIT") tokenLimit = limits[i]
            else if (limits[i].type === "TIME_LIMIT") timeLimit = limits[i]
        }

        // TOKENS_LIMIT = 5hr rolling token usage → session slot
        if (tokenLimit) {
            root.hasSessionWindow = true
            root.sessionUsagePercent = tokenLimit.percentage || 0
            root.sessionPeriodMs = 5 * 60 * 60 * 1000
            if (tokenLimit.nextResetTime) {
                root.sessionResetTime = new Date(tokenLimit.nextResetTime)
                root.sessionReset = Qt.formatTime(root.sessionResetTime, "hh:mm")
                updateSessionTimePercent()
            }
        }

        // TIME_LIMIT = monthly MCP tool usage → weekly slot (repurposed)
        if (timeLimit) {
            root.hasWeeklyWindow = true
            root.weeklyUsagePercent = timeLimit.percentage || 0
            root.weeklyPeriodMs = 30 * 24 * 60 * 60 * 1000  // monthly
            if (timeLimit.nextResetTime) {
                root.weeklyResetTime = new Date(timeLimit.nextResetTime)
                root.weeklyReset = Qt.formatDateTime(root.weeklyResetTime, "MMM d, hh:mm")
                updateWeeklyTimePercent()
            }
        }

        // No per-model breakdown for Z.ai
        root.weeklyModelLimits = []
        root.additionalLimits = []

        // Plan name from response
        var planName = container.planName || container.packageName || data.plan_type || ""
        if (planName) {
            root.planName = planName.charAt(0).toUpperCase() + planName.slice(1)
        } else if (!root.planName) {
            root.planName = "Z.ai"
        }
    }

    function parseKimiUsage(data) {
        root.hasSessionWindow = true
        root.hasWeeklyWindow = true
        root.sessionLabel = i18n.tr("Session (5hr)")
        root.weeklyLabel = i18n.tr("Weekly (7day)")
        root.sessionPeriodMs = 5 * 60 * 60 * 1000
        root.weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
        root.bankedResets = 0

        // Primary usage object → weekly slot
        var usage = data.usage || {}
        if (usage.limit > 0) {
            root.weeklyUsagePercent = (usage.used || 0) / usage.limit * 100
        } else {
            root.weeklyUsagePercent = 0
        }

        var resetAt = usage.reset_at || usage.resetAt || usage.reset_time || usage.resetTime || ""
        if (resetAt) {
            root.weeklyResetTime = new Date(resetAt)
            root.weeklyReset = Qt.formatDateTime(root.weeklyResetTime, "MMM d, hh:mm")
            updateWeeklyTimePercent()
        }

        // Limits array → find session-level (~5 hour) window
        var limits = data.limits || []
        var sessionLimit = null
        for (var i = 0; i < limits.length; i++) {
            var entry = limits[i]
            var w = entry.window || {}
            var duration = w.duration || 0
            var unit = (w.timeUnit || w.time_unit || "").toUpperCase()
            var minutes = unit === "MINUTE" ? duration
                        : unit === "HOUR"   ? duration * 60
                        : unit === "DAY"    ? duration * 1440
                        : 0
            // Accept windows in the 2–8 hour range as "session"
            if (minutes >= 120 && minutes <= 480) {
                sessionLimit = entry
                break
            }
        }
        // Fallback: use first limit entry if no 5h window found
        if (!sessionLimit && limits.length > 0) sessionLimit = limits[0]

        if (sessionLimit) {
            var detail = sessionLimit.detail || {}
            if (detail.limit > 0) {
                root.sessionUsagePercent = (detail.used || 0) / detail.limit * 100
            }
            var sReset = sessionLimit.reset_at || sessionLimit.resetAt || ""
            if (sReset) {
                root.sessionResetTime = new Date(sReset)
                root.sessionReset = Qt.formatTime(root.sessionResetTime, "hh:mm")
                updateSessionTimePercent()
            }
        } else {
            root.sessionUsagePercent = 0
        }

        root.weeklyModelLimits = []
        root.additionalLimits = []
        root.planName = "Kimi"
        updateRequiredPace()
        console.log("Claude Usage: Kimi session:", root.sessionUsagePercent, "weekly:", root.weeklyUsagePercent)
    }

    function refresh() {
        loadCredentials()
    }

    // Compact representation (panel) - shows both percentages
    compactRepresentation: Item {
        Layout.minimumWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2
        Layout.minimumHeight: Kirigami.Units.iconSizes.medium
        Layout.preferredWidth: usageRow.implicitWidth + Kirigami.Units.largeSpacing * 2

        MouseArea {
            anchors.fill: parent
            onClicked: root.expanded = !root.expanded
        }

        RowLayout {
            id: usageRow
            anchors.centerIn: parent
            spacing: Kirigami.Units.smallSpacing

            // Claude icon
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                source: Qt.resolvedUrl("../icons/claude.svg")
                Layout.rightMargin: Kirigami.Units.smallSpacing
            }

            // Error state
            PlasmaComponents.Label {
                visible: root.errorMsg !== ""
                text: "⚠"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }

            // Normal state — hide slots that have no window (e.g. Codex Pro 7d-only)
            Rectangle {
                visible: root.errorMsg === "" && root.hasSessionWindow
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getSessionColor()
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === "" && root.hasSessionWindow
                text: Math.round(root.sessionUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === "" && root.hasSessionWindow && root.hasWeeklyWindow
                text: "|"
                opacity: 0.5
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
            }

            Rectangle {
                visible: root.errorMsg === "" && root.hasWeeklyWindow
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: getWeeklyColor()
            }

            PlasmaComponents.Label {
                visible: root.errorMsg === "" && root.hasWeeklyWindow
                text: Math.round(root.weeklyUsagePercent) + "%"
                font.pixelSize: Kirigami.Theme.defaultFont.pixelSize
                font.bold: true
            }

            // Error text
            PlasmaComponents.Label {
                visible: root.errorMsg !== ""
                text: root.errorMsg
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.negativeTextColor
            }
        }
    }

    // Full representation (popup)
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.minimumHeight: Kirigami.Units.gridUnit * 16
        Layout.preferredWidth: Kirigami.Units.gridUnit * 16
        Layout.preferredHeight: Kirigami.Units.gridUnit * 18

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.mediumSpacing

            // Header
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: root.displayName + " " + i18n.tr("Usage")
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.3
                }
                Item { Layout.fillWidth: true }
                Rectangle {
                    Layout.preferredWidth: planLabel.implicitWidth + Kirigami.Units.smallSpacing * 2
                    Layout.preferredHeight: planLabel.implicitHeight + Kirigami.Units.smallSpacing
                    radius: 3
                    color: Kirigami.Theme.highlightColor
                    PlasmaComponents.Label {
                        id: planLabel
                        anchors.centerIn: parent
                        text: root.planName
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.highlightedTextColor
                    }
                }
            }

            // Error message
            Rectangle {
                visible: root.errorMsg !== ""
                Layout.fillWidth: true
                Layout.preferredHeight: errorColumn.implicitHeight + Kirigami.Units.largeSpacing
                radius: 5
                color: Kirigami.Theme.negativeBackgroundColor

                ColumnLayout {
                    id: errorColumn
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.smallSpacing

                    PlasmaComponents.Label {
                        text: "⚠ " + root.errorMsg
                        color: Kirigami.Theme.negativeTextColor
                        font.bold: true
                    }
                    PlasmaComponents.Label {
                        text: root.provider === "codex" ? "Run 'codex login' to log in"
                            : root.provider === "grok" ? "Run 'grok login' to log in"
                            : root.provider === "zai" ? "Configure Z.ai credentials"
                            : i18n.tr("Run 'claude' to log in")
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.negativeTextColor
                    }
                }
            }

            // Separator
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Banked Codex rate-limit resets (from rate_limit_reset_credits)
            PlasmaComponents.Label {
                visible: root.bankedResets > 0
                text: "Banked resets: " + root.bankedResets
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.neutralTextColor
            }

            // Session Usage
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.hasSessionWindow
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: root.sessionLabel
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: root.sessionUsagePercent.toFixed(1) + "%"
                        color: getSessionColor()
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.sessionUsagePercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getSessionColor()
                    }
                }

                // Time elapsed bar
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.sessionResetTime !== null
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        height: 5
                        radius: 2
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min(root.sessionTimePercent / 100, 1)
                            height: parent.height
                            radius: 2
                            color: getSessionColor()
                        }
                    }

                    PlasmaComponents.Label {
                        text: root.sessionTimePercent.toFixed(0) + "%"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: getSessionColor()
                        Layout.preferredWidth: implicitWidth
                    }
                }

                PlasmaComponents.Label {
                    visible: root.sessionReset !== ""
                    text: i18n.tr("Resets at:") + " " + root.sessionReset + (root.sessionResetTime ? " (" + formatTimeRemaining(root.sessionResetTime) + ")" : "")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
            }

            // Weekly Usage
            ColumnLayout {
                Layout.fillWidth: true
                visible: root.hasWeeklyWindow
                spacing: Kirigami.Units.smallSpacing

                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents.Label {
                        text: root.weeklyLabel
                        font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        text: root.weeklyUsagePercent.toFixed(1) + "%"
                        color: getWeeklyColor()
                        font.bold: true
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 10
                    radius: 5
                    color: Kirigami.Theme.backgroundColor
                    border.color: Kirigami.Theme.disabledTextColor
                    border.width: 1
                    Rectangle {
                        width: parent.width * Math.min(root.weeklyUsagePercent / 100, 1)
                        height: parent.height
                        radius: 5
                        color: getWeeklyColor()
                    }
                }

                // Time elapsed bar
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.weeklyResetTime !== null
                    spacing: Kirigami.Units.smallSpacing

                    Rectangle {
                        Layout.fillWidth: true
                        height: 5
                        radius: 2
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min(root.weeklyTimePercent / 100, 1)
                            height: parent.height
                            radius: 2
                            color: getWeeklyColor()
                        }
                    }

                    PlasmaComponents.Label {
                        text: root.weeklyTimePercent.toFixed(0) + "%"
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: getWeeklyColor()
                        Layout.preferredWidth: implicitWidth
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: root.weeklyReset !== ""

                    PlasmaComponents.Label {
                        text: i18n.tr("Resets:") + " " + root.weeklyReset + (root.weeklyResetTime ? " (" + formatTimeRemaining(root.weeklyResetTime) + ")" : "")
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: Kirigami.Theme.disabledTextColor
                    }
                    Item { Layout.fillWidth: true }
                    PlasmaComponents.Label {
                        // Pace assumes Claude-like session/weekly coupling; hide for Grok
                        // and single-window Codex Pro (no session budget).
                        visible: root.weeklyResetTime !== null && root.weeklyUsagePercent < 100
                                 && root.hasSessionWindow && !root.isGrok
                        text: i18n.tr("Pace:") + " " + formatPaceShort()
                        font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        color: getPaceRequiredColor(root.requiredPace)
                    }
                }

            }

            // Separator (hidden for providers with no model breakdown, unless extras exist)
            Rectangle {
                visible: !root.hideModelSection || root.additionalLimits.length > 0
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            // Model breakdown (collapsible) - hidden for z.ai / kimi / grok unless extras
            RowLayout {
                Layout.fillWidth: true
                visible: !root.hideModelSection || root.additionalLimits.length > 0

                MouseArea {
                    Layout.fillWidth: true
                    Layout.preferredHeight: modelHeaderLabel.implicitHeight
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.modelSectionExpanded = !root.modelSectionExpanded

                    RowLayout {
                        anchors.fill: parent
                        PlasmaComponents.Label {
                            id: modelHeaderLabel
                            text: (root.modelSectionExpanded ? "▾ " : "▸ ")
                                + (root.additionalLimits.length > 0 && root.weeklyModelLimits.length === 0
                                    ? "Extra limits"
                                    : i18n.tr("By Model (Weekly)"))
                            font.bold: true
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                        }
                        Item { Layout.fillWidth: true }
                    }
                }
            }

            // Per-model weekly limits (Claude weekly_scoped entries)
            Repeater {
                model: root.modelSectionExpanded && !root.hideModelSection ? root.weeklyModelLimits : []

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents.Label {
                        text: modelData.name
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 60
                        height: 8
                        radius: 3
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min(modelData.percent / 100, 1)
                            height: parent.height
                            radius: 3
                            color: getUsageColor(modelData.percent)
                        }
                    }
                    PlasmaComponents.Label {
                        text: modelData.percent.toFixed(0) + "%"
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }

            // Additional rate limits (Codex Spark, etc.)
            Repeater {
                model: root.modelSectionExpanded ? root.additionalLimits : []

                RowLayout {
                    Layout.fillWidth: true

                    PlasmaComponents.Label {
                        text: modelData.name
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.preferredWidth: 60
                        height: 8
                        radius: 3
                        color: Kirigami.Theme.backgroundColor
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        Rectangle {
                            width: parent.width * Math.min(modelData.percent / 100, 1)
                            height: parent.height
                            radius: 3
                            color: getUsageColor(modelData.percent)
                        }
                    }
                    PlasmaComponents.Label {
                        text: modelData.percent.toFixed(0) + "%"
                        Layout.preferredWidth: 40
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }

            // No model data message
            PlasmaComponents.Label {
                visible: root.modelSectionExpanded && !root.hideModelSection && root.weeklyModelLimits.length === 0 && root.additionalLimits.length === 0
                text: i18n.tr("No model breakdown available")
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                color: Kirigami.Theme.disabledTextColor
                font.italic: true
            }

            // Footer
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Kirigami.Theme.disabledTextColor
                opacity: 0.3
            }

            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: root.lastUpdate !== "" ? i18n.tr("Updated:") + " " + root.lastUpdate : i18n.tr("Loading...")
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.disabledTextColor
                }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Button {
                    icon.name: "view-refresh"
                    text: i18n.tr("Refresh")
                    onClicked: refresh()
                }
            }
        }
    }

    Timer {
        id: refreshTimer
        interval: (Plasmoid.configuration.refreshInterval || 1) * 60000
        running: true
        repeat: true
        onTriggered: loadCredentials()
    }

    Timer {
        id: timePercentTimer
        interval: 60000
        running: root.sessionResetTime !== null || root.weeklyResetTime !== null
        repeat: true
        onTriggered: {
            updateSessionTimePercent()
            updateWeeklyTimePercent()
            updateRequiredPace()
        }
    }

    function updateSessionTimePercent() {
        if (!root.sessionResetTime) return
        var now = new Date()
        var resetMs = root.sessionResetTime.getTime()
        var periodMs = root.sessionPeriodMs > 0 ? root.sessionPeriodMs : (5 * 60 * 60 * 1000)
        var startMs = resetMs - periodMs
        var elapsed = now.getTime() - startMs
        root.sessionTimePercent = Math.max(0, Math.min(100, (elapsed / periodMs) * 100))
    }

    function updateWeeklyTimePercent() {
        if (!root.weeklyResetTime) return
        var now = new Date()
        var resetMs = root.weeklyResetTime.getTime()
        var periodMs = root.weeklyPeriodMs
        var startMs = resetMs - periodMs
        var elapsed = now.getTime() - startMs
        root.weeklyTimePercent = Math.max(0, Math.min(100, (elapsed / periodMs) * 100))
    }

    function getPaceColor(usagePercent, timePercent) {
        if (timePercent < 1) timePercent = 1
        var pace = usagePercent / timePercent
        if (pace < 0.8) return Kirigami.Theme.positiveTextColor
        if (pace < 1.1) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function updateRequiredPace() {
        if (!root.weeklyResetTime) {
            root.requiredPace = 0
            return
        }
        var ratio = Plasmoid.configuration.sessionWeeklyRatio || 10
        var remainingWeekly = 100 - root.weeklyUsagePercent
        if (remainingWeekly <= 0) {
            root.requiredPace = 0
            return
        }
        var hoursNeeded = (remainingWeekly / ratio) * 5
        var now = new Date()
        var hoursRemaining = (root.weeklyResetTime.getTime() - now.getTime()) / 3600000
        if (hoursRemaining <= 0) {
            root.requiredPace = 999
            return
        }
        root.requiredPace = hoursNeeded / hoursRemaining
    }

    function formatPace() {
        var fmt = Plasmoid.configuration.paceFormat || "percent"
        var ratio = Plasmoid.configuration.sessionWeeklyRatio || 10
        var remainingWeekly = 100 - root.weeklyUsagePercent
        var hoursNeeded = Math.max(0, (remainingWeekly / ratio) * 5)
        var hoursRemaining = 0
        if (root.weeklyResetTime) {
            hoursRemaining = Math.max(0, (root.weeklyResetTime.getTime() - new Date().getTime()) / 3600000)
        }
        var sessionsNeeded = hoursNeeded / 5
        var sessionsRemaining = hoursRemaining / 5

        if (fmt === "sessions") {
            return i18n.tr("Pace:") + " " + sessionsNeeded.toFixed(1) + " / " + sessionsRemaining.toFixed(1)
        } else if (fmt === "hours") {
            return i18n.tr("Pace:") + " " + hoursNeeded.toFixed(1) + i18n.tr("h") + " / " + hoursRemaining.toFixed(1) + i18n.tr("h")
        }
        return i18n.tr("Pace:") + " " + Math.round(root.requiredPace * 100) + "%"
    }

    function formatPaceShort() {
        var fmt = Plasmoid.configuration.paceFormat || "percent"
        var ratio = Plasmoid.configuration.sessionWeeklyRatio || 10
        var remainingWeekly = 100 - root.weeklyUsagePercent
        var hoursNeeded = Math.max(0, (remainingWeekly / ratio) * 5)
        var hoursRemaining = 0
        if (root.weeklyResetTime) {
            hoursRemaining = Math.max(0, (root.weeklyResetTime.getTime() - new Date().getTime()) / 3600000)
        }
        var sessionsNeeded = hoursNeeded / 5
        var sessionsRemaining = hoursRemaining / 5

        if (fmt === "sessions") {
            return sessionsNeeded.toFixed(1) + " / " + sessionsRemaining.toFixed(1)
        } else if (fmt === "hours") {
            return hoursNeeded.toFixed(0) + i18n.tr("h") + " / " + hoursRemaining.toFixed(0) + i18n.tr("h")
        }
        return Math.round(root.requiredPace * 100) + "%"
    }

    function getPaceRequiredColor(pace) {
        if (pace < 0.5) return Kirigami.Theme.positiveTextColor
        if (pace < 0.85) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function getUsageColor(percent) {
        if (percent < 50) return Kirigami.Theme.positiveTextColor
        if (percent < 80) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    // Capacity mode: green when under pace, warns as you go over
    function capacityPaceColor(pace) {
        if (pace <= 1.0) return Kirigami.Theme.positiveTextColor
        if (pace < 2.0) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    // Efficiency mode: margins widen the further you are from the end of the period.
    // Early on you can be way off pace and still course-correct; near the end you can't.
    function efficiencyPaceColor(pace, timePercent) {
        var remaining = 1.0 - Math.min(timePercent, 100) / 100
        // Upper green: how far over pace is still fine? Wide early, tight at end.
        var upperGreen  = 1.0 + remaining * 1.0   // 2.0x early → 1.0x at end
        // Upper orange: above this = red
        var upperOrange = 1.0 + remaining * 3.0   // 4.0x early → 1.0x at end
        // Lower blue: so far under that quota will likely be wasted
        var lowerBlue   = 0.25 * remaining        // 0.25 early → 0 at end
        if (pace < lowerBlue)   return Kirigami.Theme.activeTextColor
        if (pace <= upperGreen) return Kirigami.Theme.positiveTextColor
        if (pace < upperOrange) return Kirigami.Theme.neutralTextColor
        return Kirigami.Theme.negativeTextColor
    }

    function getSessionColor() {
        if (root.sessionTimePercent > 0) {
            var timeP = Math.max(1, root.sessionTimePercent)
            var pace = root.sessionUsagePercent / timeP
            var mode = Plasmoid.configuration.sessionColorMode || "capacity"
            return mode === "efficiency" ? efficiencyPaceColor(pace, timeP) : capacityPaceColor(pace)
        }
        return getUsageColor(root.sessionUsagePercent)
    }

    function getWeeklyColor() {
        if (root.weeklyTimePercent > 0) {
            var timeP = Math.max(1, root.weeklyTimePercent)
            var pace = root.weeklyUsagePercent / timeP
            var mode = Plasmoid.configuration.weeklyColorMode || "efficiency"
            return mode === "efficiency" ? efficiencyPaceColor(pace, timeP) : capacityPaceColor(pace)
        }
        return getUsageColor(root.weeklyUsagePercent)
    }

    function formatTimeRemaining(resetTime) {
        if (!resetTime) return ""
        var now = new Date()
        var diff = resetTime.getTime() - now.getTime()
        if (diff <= 0) return ""

        var hours = Math.floor(diff / (1000 * 60 * 60))
        var minutes = Math.floor((diff % (1000 * 60 * 60)) / (1000 * 60))

        if (hours > 24) {
            var days = Math.floor(hours / 24)
            hours = hours % 24
            return days + i18n.tr("d") + " " + hours + i18n.tr("h")
        } else if (hours > 0) {
            return hours + i18n.tr("h") + " " + minutes + i18n.tr("m")
        } else {
            return minutes + i18n.tr("m")
        }
    }

    Component.onCompleted: {
        console.log("Claude Usage: Widget loaded")
        loadCredentials()
    }

    Plasmoid.icon: "claude-usage"
    toolTipMainText: root.displayName + " " + i18n.tr("Usage")
    toolTipSubText: {
        if (root.errorMsg !== "") return root.errorMsg
        var parts = []
        if (root.hasSessionWindow)
            parts.push(root.sessionLabel + ": " + Math.round(root.sessionUsagePercent) + "%")
        if (root.hasWeeklyWindow)
            parts.push(root.weeklyLabel + ": " + Math.round(root.weeklyUsagePercent) + "%")
        if (root.bankedResets > 0)
            parts.push("resets×" + root.bankedResets)
        return parts.length ? parts.join(" | ") : i18n.tr("Loading...")
    }
}
