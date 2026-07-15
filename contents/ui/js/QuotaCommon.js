.pragma library

var MS_HOUR = 3600000
var MS_DAY = 86400000

function formatWindowDuration(seconds) {
    var s = Math.floor(Number(seconds) || 0)
    if (s >= 86400 && s % 86400 === 0) return (s / 86400) + "d"
    if (s >= 3600 && s % 3600 === 0) return (s / 3600) + "h"
    if (s > 0) return s + "s"
    return "0h"
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
    // Bootstrap / single-instance placeholders — do not show "Z.ai-legacy"
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

function applyVisibility(windows, visibleIds) {
    if (!windows) return []
    var forced = {}
    if (visibleIds && visibleIds.length) {
        for (var i = 0; i < visibleIds.length; i++) forced[visibleIds[i]] = true
    }
    var out = []
    for (var j = 0; j < windows.length; j++) {
        var w = windows[j]
        var copy = {}
        for (var k in w) copy[k] = w[k]
        if (visibleIds && visibleIds.length) {
            copy.visible = !!forced[w.id]
        } else {
            copy.visible = w.defaultVisible !== false
        }
        out.push(copy)
    }
    return out
}