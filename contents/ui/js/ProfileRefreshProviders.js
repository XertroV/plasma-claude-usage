.pragma library
.import "QuotaCommon.js" as QC
.import "QuotaParsers.js" as QP

/**
 * Provider adapters for one-profile refresh: credential interpretation,
 * request construction, multi-request aggregation, and parser dispatch.
 * Pure data + functions — no XHR, no profile mutation, no Date.now().
 *
 * prepare(profile, credentialText, nowMs) ->
 *   { auth, effectiveProvider, requests, finalize(exchanges) }
 */

function emptyAuth() {
    return {
        token: "",
        accountId: "",
        resourceUrl: "https://api.minimax.io",
        opencodeSlot: "",
        planName: ""
    }
}

function emptyUsage() {
    return { planName: "", bankedResets: 0, windows: [] }
}

function failedPreparation(kind, auth) {
    var a = auth || emptyAuth()
    return {
        auth: a,
        effectiveProvider: "",
        requests: [],
        finalize: function() {
            return { kind: kind, status: 0 }
        }
    }
}

function parseCredentials(profile, credentialText) {
    var trimmed = String(credentialText || "").trim()
    if (!trimmed)
        throw new Error("empty credentials")
    if (profile && profile.isFlatFile && trimmed.indexOf("{") !== 0)
        return trimmed
    return JSON.parse(trimmed)
}

// Moved from ProfileController.extractAuth — algorithms unchanged except
// Grok now receives nowMs and OpenCode uses profile.opencodeAccountIndex.
function extractAuth(provider, creds, profile, nowMs) {
    var auth = emptyAuth()

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
        auth.token = pickGrokToken(creds, nowMs)
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

function pickGrokToken(creds, nowMs) {
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
    if (candidates.length === 0) return ""
    var now = (typeof nowMs === "number" && !isNaN(nowMs)) ? nowMs : 0
    candidates.sort(function(a, b) {
        var aFresh = a.expiresAt === null || a.expiresAt > now
        var bFresh = b.expiresAt === null || b.expiresAt > now
        if (aFresh !== bFresh) return aFresh ? -1 : 1
        return (b.createTime || 0) - (a.createTime || 0)
    })
    return candidates[0].key
}

function extractOpencodeAuth(creds, profile) {
    var auth = {
        token: "",
        accountId: "",
        resourceUrl: "https://api.minimax.io",
        opencodeSlot: "anthropic",
        planName: "OpenCode"
    }
    // B007: honor profile.opencodeAccountIndex (from controller snapshot) for multi-account file
    if (profile && profile.profileKey === "anthropic-accounts" && creds.accounts && creds.accounts.length) {
        var n = creds.accounts.length
        var idx = parseInt(profile.opencodeAccountIndex || 0, 10)
        if (isNaN(idx) || idx < 0)
            idx = 0
        if (idx >= n)
            idx = n - 1
        var acct = creds.accounts[idx] || {}
        auth.token = acct.access || ""
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

function effectiveProvider(profile, auth) {
    if (profile && profile.provider === "opencode") {
        return (auth && auth.opencodeSlot) || profile.opencodeSlot || "anthropic"
    }
    return (profile && profile.provider) || ""
}

function usageUrl(profile, ep, auth) {
    if (ep === "codex" || ep === "openai") return "https://chatgpt.com/backend-api/wham/usage"
    if (ep === "zai") return "https://api.z.ai/api/monitor/usage/quota/limit"
    if (ep === "grok") return "https://cli-chat-proxy.grok.com/v1/billing"
    if (ep === "kimi") return "https://api.kimi.com/coding/v1/usages"
    if (ep === "minimax") {
        var base = (auth && auth.resourceUrl) || (profile && profile.resourceUrl) || "https://api.minimax.io"
        return base + "/v1/api/openplatform/coding_plan/remains"
    }
    return "https://api.anthropic.com/api/oauth/usage"
}

function endpointSlugForProvider(ep) {
    if (ep === "codex" || ep === "openai") return "wham-usage"
    if (ep === "zai") return "quota-limit"
    if (ep === "kimi") return "coding-usages"
    if (ep === "minimax") return "coding-plan-remains"
    if (ep === "grok") return "billing"
    return "oauth-usage"
}

function baseHeaders(ep, auth) {
    var headers = { "Content-Type": "application/json" }
    if (ep === "zai") {
        headers.Authorization = auth.token
    } else {
        headers.Authorization = "Bearer " + auth.token
    }
    if (ep === "claude" || ep === "anthropic") {
        headers["anthropic-beta"] = "oauth-2025-04-20"
    } else if (ep === "codex" || ep === "openai") {
        if (auth.accountId)
            headers["ChatGPT-Account-Id"] = auth.accountId
    }
    return headers
}

function grokHeaders(auth) {
    return {
        Authorization: "Bearer " + auth.token,
        Accept: "application/json",
        "Content-Type": "application/json",
        "Cache-Control": "no-cache",
        Pragma: "no-cache",
        "x-grok-client-version": "0.2.93",
        "x-grok-client-surface": "grok-build"
    }
}

function buildRequests(profile, ep, auth) {
    if (ep === "grok") {
        var hdrs = grokHeaders(auth)
        var defaultUrl = "https://cli-chat-proxy.grok.com/v1/billing"
        var creditsUrl = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
        return [
            {
                key: "default",
                endpoint: "billing",
                url: defaultUrl,
                method: "GET",
                headers: hdrs,
                timeoutMs: 25000
            },
            {
                key: "credits",
                endpoint: "billing-credits",
                url: creditsUrl,
                method: "GET",
                headers: hdrs,
                timeoutMs: 25000
            }
        ]
    }
    return [
        {
            key: "default",
            endpoint: endpointSlugForProvider(ep),
            url: usageUrl(profile, ep, auth),
            method: "GET",
            headers: baseHeaders(ep, auth),
            timeoutMs: 25000
        }
    ]
}

function exchangeByKey(exchanges, key) {
    if (!exchanges) return null
    for (var i = 0; i < exchanges.length; i++) {
        if (exchanges[i] && exchanges[i].key === key)
            return exchanges[i]
    }
    return null
}

function applyPlanNameFallback(result, auth, profile) {
    result.planName = result.planName || (auth && auth.planName) || (profile && profile.planName) || ""
    return result
}

function finalizeStandard(ep, exchanges, profile, auth) {
    var exchange = exchangeByKey(exchanges, "default")
    if (!exchange && exchanges && exchanges.length)
        exchange = exchanges[0]
    if (!exchange)
        return { kind: "transport_error", status: 0, fromTimeout: false }

    var status = exchange.status || 0
    if (status === 200) {
        try {
            var data = JSON.parse(exchange.responseText || "")
            var result = emptyUsage()
            if (ep === "claude" || ep === "anthropic")
                result = QP.parseClaude(data)
            else if (ep === "codex" || ep === "openai")
                result = QP.parseCodex(data)
            else if (ep === "minimax")
                result = QP.parseMinimax(data)
            else if (ep === "zai")
                result = QP.parseZai(data)
            else if (ep === "kimi")
                result = QP.parseKimi(data)
            else
                return { kind: "parse_error", detail: "unknown provider: " + ep }
            applyPlanNameFallback(result, auth, profile)
            return { kind: "success", usageResult: result }
        } catch (e) {
            return { kind: "parse_error", detail: String(e) }
        }
    }
    if (status === 429)
        return { kind: "rate_limited", status: 429 }
    if (status === 401 || status === 403)
        return { kind: "auth_error", status: status }
    if (status === 0)
        return { kind: "transport_error", status: 0, fromTimeout: !!exchange.fromTimeout }
    return { kind: "transport_error", status: status, fromTimeout: false }
}

/**
 * Grok dual-fetch aggregation, matching finishGrokPart / grokGet behaviour:
 * - body only accepted when status === 200 AND JSON.parse succeeds
 * - malformed default JSON at HTTP 200 → API-error (transport_error status 200)
 * - malformed credits with valid default → monthly-only success
 * - auth fail without default body → auth_error; with body → partial success
 * - only parseGrok exception after valid default JSON → parse_error
 */
function finalizeGrok(exchanges, profile, auth) {
    var defEx = exchangeByKey(exchanges, "default")
    var credEx = exchangeByKey(exchanges, "credits")

    var defaultStatus = defEx ? (defEx.status || 0) : 0
    var creditsStatus = credEx ? (credEx.status || 0) : 0
    var defaultFromTimeout = !!(defEx && defEx.fromTimeout)

    var defaultBody = null
    var creditsBody = null
    if (defEx && defEx.status === 200) {
        try {
            defaultBody = JSON.parse(defEx.responseText || "")
        } catch (e1) {
            defaultBody = null
        }
    }
    if (credEx && credEx.status === 200) {
        try {
            creditsBody = JSON.parse(credEx.responseText || "")
        } catch (e2) {
            creditsBody = null
        }
    }

    var authFailed = defaultStatus === 401 || defaultStatus === 403
        || creditsStatus === 401 || creditsStatus === 403

    if (authFailed) {
        if (!defaultBody) {
            var authStatus = (defaultStatus === 401 || defaultStatus === 403)
                ? defaultStatus
                : creditsStatus
            return { kind: "auth_error", status: authStatus }
        }
        // Monthly body present → partial success path continues below
    }

    if (defaultStatus === 429)
        return { kind: "rate_limited", status: 429 }

    if (!defaultBody) {
        if (defaultStatus === 0)
            return { kind: "transport_error", status: 0, fromTimeout: defaultFromTimeout }
        // Includes HTTP 200 with malformed JSON → API error (200)
        return { kind: "transport_error", status: defaultStatus || 0, fromTimeout: false }
    }

    try {
        var result = QP.parseGrok(defaultBody, creditsBody)
        applyPlanNameFallback(result, auth, profile)
        return { kind: "success", usageResult: result }
    } catch (e) {
        return { kind: "parse_error", detail: String(e) }
    }
}

function finalizeProvider(ep, exchanges, profile, auth) {
    if (ep === "grok")
        return finalizeGrok(exchanges, profile, auth)
    return finalizeStandard(ep, exchanges, profile, auth)
}

function prepare(profile, credentialText, nowMs) {
    var credentials
    try {
        credentials = parseCredentials(profile, credentialText)
    } catch (e) {
        return failedPreparation("auth_error", emptyAuth())
    }
    var auth = extractAuth(profile.provider, credentials, profile, nowMs)
    if (!auth.token)
        return failedPreparation("auth_error", auth)
    var effective = effectiveProvider(profile, auth)
    var requests = buildRequests(profile, effective, auth)
    return {
        auth: auth,
        effectiveProvider: effective,
        requests: requests,
        finalize: function(exchanges) {
            return finalizeProvider(effective, exchanges, profile, auth)
        }
    }
}
