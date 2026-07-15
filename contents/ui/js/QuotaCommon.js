.pragma library

var MS_HOUR = 3600000
var MS_DAY = 86400000
var MS_5H = 5 * MS_HOUR
var MS_7D = 7 * MS_DAY
var MS_12H = 12 * MS_HOUR
var MS_10D = 10 * MS_DAY
var MS_45D = 45 * MS_DAY

/**
 * Expand ~/ $HOME ${HOME} to an absolute path using a resolved home directory (B006).
 * Returns "" if home-relative and homeDir is empty. Never returns a string meant for
 * unquoted shell use — callers must still shellQuote.
 */
function expandToAbsolute(path, homeDir) {
    if (!path) return ""
    var p = String(path).trim()
    if (!p) return ""
    if (p === "~") {
        return homeDir ? String(homeDir) : ""
    }
    if (p.indexOf("~/") === 0) {
        if (!homeDir) return ""
        return String(homeDir).replace(/\/+$/, "") + "/" + p.substring(2)
    }
    if (p.indexOf("${HOME}") === 0) {
        if (!homeDir) return ""
        return String(homeDir).replace(/\/+$/, "") + p.substring(7)
    }
    if (p.indexOf("$HOME") === 0) {
        if (!homeDir) return ""
        return String(homeDir).replace(/\/+$/, "") + p.substring(5)
    }
    return p
}

/**
 * Normalize ~/ and $HOME forms for path comparison (B010).
 * Does not require a resolved home directory — maps user-relative prefixes
 * to a stable "$HOME/..." token and absolute /home|Users/user/... to the same tail.
 */
function expandUserPath(path) {
    if (!path) return ""
    var p = String(path).trim()
    if (p === "~") return "$HOME"
    if (p.indexOf("~/") === 0)
        p = "$HOME/" + p.substring(2)
    if (p.indexOf("${HOME}") === 0)
        p = "$HOME" + p.substring(7)
    // Leave $HOME/... and absolute paths as-is for pathCompareKey
    return p.replace(/\/+$/, "")
}

/**
 * Stable key so ~/.claude/x, $HOME/.claude/x, and /home/u/.claude/x match.
 */
function pathCompareKey(path) {
    var p = expandUserPath(path)
    if (!p) return ""
    if (p.indexOf("$HOME/") === 0) return p.substring(6)
    if (p === "$HOME") return ""
    // /home/user/... or /Users/user/...
    if (p.indexOf("/home/") === 0 || p.indexOf("/Users/") === 0) {
        var parts = p.split("/")
        // ["", "home", "user", "rest"...]
        if (parts.length >= 4)
            return parts.slice(3).join("/")
    }
    return p
}

function pathsEqual(a, b) {
    if (!a || !b) return false
    if (String(a) === String(b)) return true
    var ka = pathCompareKey(a)
    var kb = pathCompareKey(b)
    if (ka && kb && ka === kb) return true
    // Also compare with trailing auth filenames stripped for dir-vs-file cases
    function stripAuthSuffix(s) {
        return String(s || "")
            .replace(/\/\.credentials\.json$/, "")
            .replace(/\/auth\.json$/, "")
            .replace(/\/config\.json$/, "")
    }
    var sa = stripAuthSuffix(ka)
    var sb = stripAuthSuffix(kb)
    return !!(sa && sb && sa === sb)
}

/**
 * Resolve auth file when custom profile only has a config directory (B009).
 */
function defaultCredPathForProvider(provider, configDirOrPath) {
    var dir = String(configDirOrPath || "").replace(/\/+$/, "")
    if (!dir) return ""
    // Already looks like a credentials file — keep it
    if (/\.(json)$/i.test(dir) || dir.indexOf(".credentials") >= 0)
        return dir
    switch (String(provider || "")) {
    case "claude":
        return dir + "/.credentials.json"
    case "codex":
    case "grok":
    case "opencode":
    case "zai":
        return dir + "/auth.json"
    case "minimax":
        return dir + "/config.json"
    case "kimi":
        // Flat token file is often the path itself
        return dir
    default:
        return dir
    }
}

/** Canonical period label from duration seconds (604800 → "7d", never "168h"). */
function formatPeriodLabel(seconds) {
    var s = Math.floor(Number(seconds) || 0)
    if (s <= 0) return "0h"
    // Prefer day units when exact
    if (s >= 86400 && s % 86400 === 0) {
        var days = s / 86400
        if (days === 7) return "7d"
        if (days === 30 || days === 31) return "mo"
        return days + "d"
    }
    if (s >= 3600 && s % 3600 === 0) {
        var hours = s / 3600
        if (hours === 5) return "5h"
        if (hours === 168) return "7d"
        return hours + "h"
    }
    if (s > 0) return s + "s"
    return "0h"
}

/** Alias — existing call sites use formatWindowDuration. */
function formatWindowDuration(seconds) {
    return formatPeriodLabel(seconds)
}

function normalizePeriodToken(raw) {
    var s = String(raw || "").trim().toLowerCase()
    if (!s) return ""
    if (s === "168h" || s === "weekly" || s === "week" || s === "wk" || s === "7d")
        return "7d"
    if (s === "five_hour" || s === "five-hour" || s === "5hour" || s === "5h" || s === "300m")
        return "5h"
    if (s === "monthly" || s === "month" || s === "mo" || s === "30d" || s === "31d")
        return "mo"
    if (s.indexOf("weekly/") === 0) return "7d"
    if (s.indexOf("wk/") === 0) return "7d"
    if (s.indexOf("5h/") === 0) return "5h"
    if (s.indexOf("7d/") === 0) return "7d"
    if (s.indexOf("monthly") === 0) return "mo"
    return s
}

/**
 * Classify window into period column/class.
 * Order: extra role → periodMs bands → token fallbacks.
 * Never treat bare id "session" as 5h when period is weekly/monthly.
 */
function assignWindowColumn(window) {
    if (!window) return "extra"
    if (window.role === "extra") return "extra"

    var periodMs = Number(window.periodMs) || 0
    if (periodMs > 0) {
        if (periodMs >= MS_HOUR && periodMs <= MS_12H) return "5h"
        if (periodMs > MS_12H && periodMs <= MS_10D) return "7d"
        if (periodMs > MS_10D && periodMs <= MS_45D) return "mo"
        // Outside bands with a period → treat as extra (not a standard header period)
        return "extra"
    }

    // periodMs missing/0: token/id fallbacks (credits/on-demand with no period stay extra)
    var id = String(window.id || "").toLowerCase()
    var label = String(window.label || "").toLowerCase()
    var tok = normalizePeriodToken(id) || normalizePeriodToken(label)

    if (tok === "5h" || id.indexOf("5h") === 0) return "5h"
    if (tok === "7d" || id === "weekly" || id.indexOf("wk/") === 0
            || id.indexOf("7d") === 0 || label.indexOf("weekly") === 0)
        return "7d"
    if (tok === "mo" || id.indexOf("monthly") === 0 || label.indexOf("monthly") === 0
            || id === "month" || label.indexOf("mcp") >= 0 && id === "weekly")
        return "mo"

    // Bare "session" without periodMs: only 5h if label/tokens don't say weekly
    if (id === "session") {
        if (label.indexOf("week") >= 0 || label.indexOf("7d") >= 0 || label.indexOf("month") >= 0)
            return label.indexOf("month") >= 0 ? "mo" : "7d"
        return "5h"
    }

    return "extra"
}

function isSessionClass(window) { return assignWindowColumn(window) === "5h" }
function isWeeklyClass(window) { return assignWindowColumn(window) === "7d" }
function isMonthlyClass(window) { return assignWindowColumn(window) === "mo" }

function colorModeForColumn(col, sessionMode, weeklyMode) {
    if (col === "5h") return sessionMode || "capacity"
    return weeklyMode || "efficiency"
}

function colorModeForWindow(window, sessionMode, weeklyMode) {
    return colorModeForColumn(assignWindowColumn(window), sessionMode, weeklyMode)
}

/** Short UI label for a window (chips, rows, tooltips). */
function displayWindowLabel(window) {
    if (!window) return ""
    var id = String(window.id || "")
    var label = String(window.label || "")
    var col = assignWindowColumn(window)

    // MiniMax: id wk/foo → display 7d/foo
    if (id.indexOf("wk/") === 0)
        return "7d/" + id.substring(3)
    if (label.indexOf("wk/") === 0)
        return "7d/" + label.substring(3)

    // Grok weekly/build → 7d/build
    if (label.indexOf("weekly/") === 0)
        return "7d/" + label.substring(7)
    if (id.indexOf("weekly_") === 0) {
        // extras like weekly_fable → short model name for extras; for primary use 7d
        if (window.role === "extra") {
            var rest = id.substring(7)
            if (rest) return rest.charAt(0).toUpperCase() + rest.slice(1)
        }
        return "7d"
    }

    // Plain period primaries
    if (col === "5h" && (label === "5h" || label === "5h tokens" || id === "session" || id === "5h"))
        return "5h"
    if (col === "7d" && (label === "7d" || label === "weekly" || id === "weekly" || id === "7d"))
        return "7d"
    if (col === "mo") {
        if (label.indexOf("monthly $") === 0 || label.indexOf("$") >= 0) return "mo"
        if (label.indexOf("monthly") === 0 || label === "monthly MCP" || label === "MCP") return "mo"
        if (normalizePeriodToken(label) === "mo" || label === "mo") return "mo"
        return "mo"
    }

    // Already canonical duration labels from formatPeriodLabel
    var norm = normalizePeriodToken(label)
    if (norm === "5h" || norm === "7d" || norm === "mo") return norm

    // Prefer existing short label
    if (label) return label
    if (id) return id
    return col !== "extra" ? col : ""
}

function primaryWindows(profile) {
    var out = []
    if (!profile || !profile.windows) return out
    for (var i = 0; i < profile.windows.length; i++) {
        var w = profile.windows[i]
        if (!w || w.visible === false) continue
        if (w.role === "primary" || w.role === "" || w.role === undefined)
            out.push(w)
    }
    if (out.length === 0) {
        for (var j = 0; j < profile.windows.length; j++) {
            if (profile.windows[j] && profile.windows[j].visible !== false)
                out.push(profile.windows[j])
        }
    }
    return out
}

function extraWindows(profile) {
    var out = []
    if (!profile || !profile.windows) return out
    for (var i = 0; i < profile.windows.length; i++) {
        var w = profile.windows[i]
        if (w && w.visible !== false && w.role === "extra")
            out.push(w)
    }
    return out
}

function formatCountdown(resetAtMs, nowMs) {
    if (!resetAtMs || resetAtMs <= 0) return ""
    var diff = resetAtMs - (nowMs || Date.now())
    if (diff <= 0) return "now"

    var hours = Math.floor(diff / MS_HOUR)
    var minutes = Math.floor((diff % MS_HOUR) / 60000)
    var seconds = Math.floor((diff % 60000) / 1000)
    var days = Math.floor(hours / 24)
    hours = hours % 24

    if (diff >= 48 * MS_HOUR) {
        return days + "d " + hours + "h"
    }
    if (diff >= MS_HOUR) {
        return hours + "h " + minutes + "m"
    }
    return minutes + "m " + seconds + "s"
}

function updateTimePercent(window, nowMs) {
    if (!window || !window.resetAtMs || !window.periodMs) {
        if (window) window.timePercent = 0
        return 0
    }
    var resetMs = window.resetAtMs
    var periodMs = window.periodMs > 0 ? window.periodMs : MS_HOUR
    var startMs = resetMs - periodMs
    var elapsed = (nowMs || Date.now()) - startMs
    var pct = Math.max(0, Math.min(100, (elapsed / periodMs) * 100))
    window.timePercent = pct
    return pct
}

function capacityPaceColor(pace, theme) {
    if (pace <= 1.0) return theme.positiveTextColor
    if (pace < 2.0) return theme.neutralTextColor
    return theme.negativeTextColor
}

function efficiencyPaceColor(pace, timePercent, theme) {
    var remaining = 1.0 - Math.min(timePercent, 100) / 100
    var upperGreen = 1.0 + remaining * 1.0
    var upperOrange = 1.0 + remaining * 3.0
    var lowerBlue = 0.25 * remaining
    if (pace < lowerBlue) return theme.activeTextColor
    if (pace <= upperGreen) return theme.positiveTextColor
    if (pace < upperOrange) return theme.neutralTextColor
    return theme.negativeTextColor
}

function usageColor(percent, theme) {
    if (percent < 50) return theme.positiveTextColor
    if (percent < 80) return theme.neutralTextColor
    return theme.negativeTextColor
}

function windowPaceColor(window, colorMode, theme) {
    var timeP = Math.max(1, window.timePercent || 0)
    if (timeP > 0 && window.usagePercent >= 0) {
        var pace = window.usagePercent / timeP
        return colorMode === "efficiency"
            ? efficiencyPaceColor(pace, timeP, theme)
            : capacityPaceColor(pace, theme)
    }
    return usageColor(window.usagePercent, theme)
}

function defaultProfileLabel(provider, profileKey) {
    var names = {
        claude: "Claude",
        codex: "Codex",
        grok: "Grok",
        minimax: "MiniMax",
        zai: "Z.ai",
        kimi: "Kimi",
        opencode: "OpenCode"
    }
    var base = names[provider] || provider
    if (!profileKey || profileKey === "") return base
    if (profileKey === "anthropic-accounts") return base + " Anthropic"
    if (profileKey === "local-share") return base
    if (profileKey === "legacy" || profileKey.indexOf("legacy") === 0) return base
    return base + "-" + profileKey
}

function makeWindow(id, label, usagePercent, resetAtMs, periodMs, role, defaultVisible) {
    return {
        id: id,
        label: label,
        usagePercent: Number(usagePercent) || 0,
        resetAtMs: resetAtMs || 0,
        periodMs: periodMs || 0,
        role: role || "primary",
        defaultVisible: defaultVisible !== false,
        visible: defaultVisible !== false,
        timePercent: 0
    }
}

function parseResetMs(value) {
    if (!value) return 0
    if (typeof value === "number") {
        return value < 1e12 ? value * 1000 : value
    }
    var d = new Date(value)
    return isNaN(d.getTime()) ? 0 : d.getTime()
}

/**
 * Count own keys on a plain object (QML/JS-safe).
 */
function objectKeyCount(obj) {
    var n = 0
    if (!obj || typeof obj !== "object" || Array.isArray(obj)) return 0
    for (var k in obj) {
        if (obj.hasOwnProperty(k)) n++
    }
    return n
}

/**
 * True if value looks like a per-window bool map (not an array / not nested provider map).
 * Nested provider maps have object values; window maps have boolean (or 0/1) values.
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

/**
 * Normalize visibleWindowsJson into a structured config.
 *
 * Formats:
 *  - [] or {} or null → defaults for every provider
 *  - ["5h","weekly"] → legacy global allowlist (only those ids, all providers)
 *  - {"claude":{"5h":true,"weekly":false}, "grok":{"session":true}} → per-provider overrides
 *  - {"5h":true,"weekly":false} → treat as global override map (all providers)
 *
 * Returns:
 *  { mode: "defaults"|"globalAllowlist"|"globalMap"|"perProvider",
 *    globalAllowlist: string[],
 *    globalMap: object|null,
 *    byProvider: { provider: { windowId: bool } } }
 */
function parseVisibleWindowsConfig(raw) {
    var empty = {
        mode: "defaults",
        globalAllowlist: [],
        globalMap: null,
        byProvider: {}
    }
    if (raw === undefined || raw === null || raw === "") return empty

    var parsed = raw
    if (typeof raw === "string") {
        var s = raw.trim()
        if (!s || s === "[]" || s === "{}") return empty
        try { parsed = JSON.parse(s) } catch (e) { return empty }
    }

    if (Array.isArray(parsed)) {
        if (!parsed.length) return empty
        return {
            mode: "globalAllowlist",
            globalAllowlist: parsed.slice(),
            globalMap: null,
            byProvider: {}
        }
    }

    if (!parsed || typeof parsed !== "object") return empty

    // Flat window map applied to all providers
    if (isWindowBoolMap(parsed)) {
        if (objectKeyCount(parsed) === 0) return empty
        return {
            mode: "globalMap",
            globalAllowlist: [],
            globalMap: parsed,
            byProvider: {}
        }
    }

    // Per-provider maps (values are objects or arrays)
    var byProvider = {}
    var any = false
    for (var prov in parsed) {
        if (!parsed.hasOwnProperty(prov)) continue
        var entry = parsed[prov]
        if (entry === undefined || entry === null) continue
        if (Array.isArray(entry)) {
            // Per-provider allowlist array → bool map (true only for listed)
            if (!entry.length) continue
            var am = {}
            for (var i = 0; i < entry.length; i++) am[entry[i]] = true
            // Mark as strict allowlist via special key
            am.__allowlist = true
            byProvider[prov] = am
            any = true
        } else if (typeof entry === "object") {
            if (objectKeyCount(entry) === 0) continue
            byProvider[prov] = entry
            any = true
        }
    }
    if (!any) return empty
    return {
        mode: "perProvider",
        globalAllowlist: [],
        globalMap: null,
        byProvider: byProvider
    }
}

/**
 * Map profile.provider (+ OpenCode slot / profileKey) to the config key used for column visibility.
 * OpenCode rows inherit the underlying parser's window ids, so share that provider's toggles.
 *
 * @param provider - profile.provider
 * @param opencodeSlot - resolved slot after auth (anthropic/openai/kimi/zai) when known
 * @param profileKey - discovery key e.g. "anthropic-accounts" (used before auth loads)
 */
function visibilityProviderKey(provider, opencodeSlot, profileKey) {
    var p = provider || ""
    if (p === "opencode") {
        var slot = opencodeSlot || ""
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
    return p
}

/**
 * Resolve the visibility spec for one provider from a parseVisibleWindowsConfig() result.
 * Returns:
 *  - null → use each window's defaultVisible
 *  - string[] → strict allowlist (legacy)
 *  - object map {id:bool} → overrides; missing keys fall back to defaultVisible
 *    (unless map.__allowlist === true, then missing = hidden)
 */
function visibilitySpecForProvider(cfg, provider) {
    if (!cfg || cfg.mode === "defaults") return null
    if (cfg.mode === "globalAllowlist") {
        return (cfg.globalAllowlist && cfg.globalAllowlist.length) ? cfg.globalAllowlist : null
    }
    if (cfg.mode === "globalMap") {
        return cfg.globalMap && objectKeyCount(cfg.globalMap) ? cfg.globalMap : null
    }
    if (cfg.mode === "perProvider") {
        var m = cfg.byProvider && cfg.byProvider[provider]
        if (!m || objectKeyCount(m) === 0) return null
        return m
    }
    return null
}

/**
 * Apply visibility to a windows array.
 *
 * @param windows - array of window objects
 * @param spec - null | string[] (allowlist) | {id:bool} (overrides)
 *               For override maps, unlisted ids keep defaultVisible unless __allowlist.
 */
function applyVisibility(windows, spec) {
    if (!windows) return []
    var mode = "defaults" // defaults | allowlist | map
    var forced = {}
    var allowlistStrict = false

    if (spec === undefined || spec === null) {
        mode = "defaults"
    } else if (Array.isArray(spec)) {
        if (spec.length) {
            mode = "allowlist"
            for (var i = 0; i < spec.length; i++) forced[spec[i]] = true
        } else {
            mode = "defaults"
        }
    } else if (typeof spec === "object") {
        if (objectKeyCount(spec) === 0) {
            mode = "defaults"
        } else {
            mode = "map"
            allowlistStrict = !!spec.__allowlist
            for (var k in spec) {
                if (!spec.hasOwnProperty(k) || k === "__allowlist") continue
                forced[k] = !!spec[k]
            }
            // Empty after stripping meta → defaults
            if (objectKeyCount(forced) === 0 && !allowlistStrict)
                mode = "defaults"
        }
    }

    var out = []
    for (var j = 0; j < windows.length; j++) {
        var w = windows[j]
        var copy = {}
        for (var ck in w) copy[ck] = w[ck]
        if (mode === "allowlist") {
            copy.visible = !!forced[w.id]
        } else if (mode === "map") {
            // forced[id] only set for explicitly configured keys
            if (forced[w.id] !== undefined)
                copy.visible = !!forced[w.id]
            else if (allowlistStrict)
                copy.visible = false
            else
                copy.visible = w.defaultVisible !== false
        } else {
            copy.visible = w.defaultVisible !== false
        }
        out.push(copy)
    }
    return out
}
