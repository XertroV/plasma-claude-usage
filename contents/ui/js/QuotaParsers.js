.pragma library
.import "QuotaCommon.js" as QC

var MS_5H = 5 * 3600000
var MS_1D = 86400000
var MS_7D = 7 * 86400000
var MS_30D = 30 * 86400000

function emptyResult() {
    return { planName: "", bankedResets: 0, windows: [] }
}

function scopedModelSlug(entry) {
    var scope = entry.scope || {}
    var model = scope.model || {}
    var name = (model.display_name || model.id || "").toString().trim().toLowerCase()
    if (!name) return ""
    return name.replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "")
}

function parseClaude(data) {
    var r = emptyResult()
    var five = data.five_hour || {}
    var seven = data.seven_day || {}

    if (five.utilization != null) {
        r.windows.push(QC.makeWindow("5h", "5h", five.utilization, QC.parseResetMs(five.resets_at), MS_5H, "primary", true))
    }
    if (seven.utilization != null) {
        r.windows.push(QC.makeWindow("weekly", "7d", seven.utilization, QC.parseResetMs(seven.resets_at), MS_7D, "primary", true))
    }

    var legacy = ["opus", "sonnet", "oauth_apps"]
    for (var li = 0; li < legacy.length; li++) {
        var key = "seven_day_" + legacy[li]
        var obj = data[key]
        if (obj && obj.utilization != null) {
            var lid = "weekly_" + legacy[li]
            var lbl = legacy[li] === "oauth_apps" ? "OAuth" : legacy[li].charAt(0).toUpperCase() + legacy[li].slice(1)
            r.windows.push(QC.makeWindow(lid, lbl, obj.utilization, QC.parseResetMs(obj.resets_at), MS_7D, "extra", false))
        }
    }

    if (data && typeof data === "object") {
        for (var prop in data) {
            if (!data.hasOwnProperty(prop)) continue
            if (prop.indexOf("seven_day_") !== 0) continue
            var model = prop.substring("seven_day_".length)
            if (!model || legacy.indexOf(model) >= 0) continue
            var val = data[prop]
            if (val && val.utilization != null) {
                var wid = "weekly_" + model
                var exists = false
                for (var e = 0; e < r.windows.length; e++) {
                    if (r.windows[e].id === wid) { exists = true; break }
                }
                if (!exists) {
                    var disp = model.charAt(0).toUpperCase() + model.slice(1)
                    r.windows.push(QC.makeWindow(wid, disp, val.utilization, QC.parseResetMs(val.resets_at), MS_7D, "extra", false))
                }
            }
        }
    }

    var limits = data.limits || []
    for (var i = 0; i < limits.length; i++) {
        var entry = limits[i]
        if (entry.group !== "weekly") continue
        var slug = scopedModelSlug(entry)
        if (!slug) continue
        var id = "weekly_" + slug
        var dup = false
        for (var d = 0; d < r.windows.length; d++) {
            if (r.windows[d].id === id) { dup = true; break }
        }
        if (dup) continue
        var dn = (entry.scope && entry.scope.model && entry.scope.model.display_name) || slug
        r.windows.push(QC.makeWindow(id, dn, entry.percent || 0, QC.parseResetMs(entry.resets_at), MS_7D, "extra", false))
    }

    var oauth = (data && data.claudeAiOauth) ? data.claudeAiOauth : null
    if (!oauth && data && data.rateLimitTier) {
        var tier = data.rateLimitTier
        var planMap = {
            "default_claude_pro": "Pro",
            "default_claude_max_5x": "Max 5x",
            "default_claude_max_20x": "Max 20x"
        }
        r.planName = planMap[tier] || tier
    }
    return r
}

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

function pushCodexWindow(windows, id, label, win, defaultPeriodSec, role) {
    var pct = (win && win.used_percent != null) ? Number(win.used_percent) : 0
    var secs = (win && win.limit_window_seconds) ? Number(win.limit_window_seconds) : defaultPeriodSec
    var resetMs = (win && win.reset_at) ? Number(win.reset_at) * 1000 : 0
    windows.push(QC.makeWindow(id, label, pct, resetMs, secs * 1000, role, role === "primary"))
}

function parseCodex(data) {
    var r = emptyResult()
    var rateLimit = data.rate_limit || {}
    var primary = rateLimit.primary_window || null
    var secondary = rateLimit.secondary_window || null
    var primaryOk = codexWindowHasData(primary)
    var secondaryOk = codexWindowHasData(secondary)

    if (primaryOk && secondaryOk) {
        pushCodexWindow(r.windows, "session", QC.formatWindowDuration(primary.limit_window_seconds || 18000), primary, 18000, "primary")
        pushCodexWindow(r.windows, "weekly", QC.formatWindowDuration(secondary.limit_window_seconds || 604800), secondary, 604800, "primary")
    } else if (primaryOk) {
        var pSec = Number(primary.limit_window_seconds) || 18000
        if (pSec >= 86400) {
            pushCodexWindow(r.windows, "weekly", QC.formatWindowDuration(pSec), primary, 604800, "primary")
        } else {
            pushCodexWindow(r.windows, "session", QC.formatWindowDuration(pSec), primary, 18000, "primary")
        }
    } else if (secondaryOk) {
        pushCodexWindow(r.windows, "weekly", QC.formatWindowDuration(secondary.limit_window_seconds || 604800), secondary, 604800, "primary")
    }

    var extras = data.additional_rate_limits || []
    for (var i = 0; i < extras.length; i++) {
        var entry = extras[i]
        var rawName = entry.limit_name || entry.metered_feature || ("limit" + i)
        var short = shortCodexLabel(rawName)
        var rl = entry.rate_limit || {}
        var wins = []
        if (codexWindowHasData(rl.primary_window)) wins.push(rl.primary_window)
        if (codexWindowHasData(rl.secondary_window)) wins.push(rl.secondary_window)
        for (var j = 0; j < wins.length; j++) {
            var win = wins[j]
            var wSec = Number(win.limit_window_seconds) || 0
            var lbl = wSec > 0 ? (short + "/" + QC.formatWindowDuration(wSec)) : short
            var pct = win.used_percent != null ? Number(win.used_percent) : 0
            var id = "extra_" + lbl.replace(/[^a-zA-Z0-9]/g, "_")
            pushCodexWindow(r.windows, id, lbl, win, wSec || 18000, "extra")
            r.windows[r.windows.length - 1].usagePercent = isNaN(pct) ? 0 : pct
            r.windows[r.windows.length - 1].defaultVisible = false
            r.windows[r.windows.length - 1].visible = false
        }
    }

    var banked = data.rate_limit_reset_credits || null
    if (banked && banked.available_count != null) {
        r.bankedResets = Number(banked.available_count) || 0
    }

    var credits = data.credits || {}
    if (!credits.unlimited && credits.balance) {
        var bal = parseFloat(credits.balance)
        if (!isNaN(bal) && bal > 0) {
            r.windows.push(QC.makeWindow("credits", "credits $" + bal.toFixed(2), 0, 0, 0, "extra", false))
        }
    }

    if (data.plan_type) {
        var plan = data.plan_type
        r.planName = "Codex / " + plan.charAt(0).toUpperCase() + plan.slice(1)
    }
    return r
}

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

function formatDollars(n) {
    var v = Number(n) || 0
    if (Math.abs(v - Math.round(v)) < 0.005) return String(Math.round(v))
    return v.toFixed(2)
}

function parseGrok(defaultBody, creditsBody) {
    var r = emptyResult()
    var defaultCfg = (defaultBody && defaultBody.config) ? defaultBody.config : (defaultBody || {})
    var creditsCfg = (creditsBody && creditsBody.config) ? creditsBody.config : (creditsBody || {})

    var period = creditsCfg.currentPeriod || creditsCfg.current_period || null
    var periodType = (period && period.type) ? String(period.type) : "USAGE_PERIOD_TYPE_WEEKLY"
    var periodLabel = "7d"
    var upper = periodType.toUpperCase()
    // Match quotas period_type_label order: WEEK before DAY (WEEKDAY etc.).
    // Note: "DAILY" does not contain substring "DAY" — check both.
    if (upper.indexOf("WEEK") >= 0) periodLabel = "7d"
    else if (upper.indexOf("MONTH") >= 0) periodLabel = "mo"
    else if (upper.indexOf("DAILY") >= 0 || upper.indexOf("DAY") >= 0) periodLabel = "1d"
    // else unknown stays "7d"

    var periodStart = period && period.start ? QC.parseResetMs(period.start) : 0
    if (!periodStart && (creditsCfg.billingPeriodStart || creditsCfg.billing_period_start))
        periodStart = QC.parseResetMs(creditsCfg.billingPeriodStart || creditsCfg.billing_period_start)
    var periodEnd = period && period.end ? QC.parseResetMs(period.end) : 0
    if (!periodEnd && (creditsCfg.billingPeriodEnd || creditsCfg.billing_period_end))
        periodEnd = QC.parseResetMs(creditsCfg.billingPeriodEnd || creditsCfg.billing_period_end)

    // Prefer measured duration from start/end when valid; else type constants.
    // B014: daily must not keep MS_7D (breaks time-percent/pace).
    var periodMs = 0
    if (periodStart > 0 && periodEnd > periodStart)
        periodMs = periodEnd - periodStart
    else if (periodLabel === "mo")
        periodMs = MS_30D
    else if (periodLabel === "1d")
        periodMs = MS_1D
    else
        periodMs = MS_7D

    var weeklyPct = null
    var products = creditsCfg.productUsage || creditsCfg.product_usage || []
    if (products && products.length) {
        for (var i = 0; i < products.length; i++) {
            var prod = products[i]
            var name = prod.product || "product"
            var pct = prod.usagePercent != null ? Number(prod.usagePercent)
                    : (prod.usage_percent != null ? Number(prod.usage_percent) : null)
            if (pct == null || isNaN(pct)) continue
            var short = name === "GrokBuild" ? "build" : name
            var disp = periodLabel + "/" + short
            if (weeklyPct === null) {
                weeklyPct = pct
                r.windows.push(QC.makeWindow("session", disp, pct, periodEnd, periodMs, "primary", true))
            } else {
                r.windows.push(QC.makeWindow("extra_" + short, disp, pct, periodEnd, periodMs, "extra", false))
            }
        }
    }
    if (weeklyPct === null) {
        var overall = creditsCfg.creditUsagePercent != null ? Number(creditsCfg.creditUsagePercent)
                    : (creditsCfg.credit_usage_percent != null ? Number(creditsCfg.credit_usage_percent) : null)
        if (overall != null && !isNaN(overall)) {
            r.windows.push(QC.makeWindow("session", periodLabel, overall, periodEnd, periodMs, "primary", true))
        }
    }

    var monthEnd = defaultCfg.billingPeriodEnd ? QC.parseResetMs(defaultCfg.billingPeriodEnd) : 0
    var monthMs = MS_30D
    var limitDollars = grokCentsToDollars(defaultCfg.monthlyLimit || defaultCfg.monthly_limit)
    var usedDollars = grokCentsToDollars(defaultCfg.used)
    if (limitDollars > 0 || usedDollars > 0) {
        var monthPct = limitDollars > 0 ? (usedDollars / limitDollars) * 100 : 0
        // Label "mo"; $ detail via tooltip from raw used/limit if needed later
        r.windows.push(QC.makeWindow("weekly", "mo",
            Math.min(100, monthPct), monthEnd, monthMs, "primary", true))
        r.windows[r.windows.length - 1].tooltipExtra =
            "$" + formatDollars(usedDollars) + "/$" + formatDollars(limitDollars)
    }

    var odCap = grokCentsToDollars(creditsCfg.onDemandCap || creditsCfg.on_demand_cap || defaultCfg.onDemandCap || defaultCfg.on_demand_cap)
    var odUsed = grokCentsToDollars(creditsCfg.onDemandUsed || creditsCfg.on_demand_used || defaultCfg.onDemandUsed || defaultCfg.on_demand_used)
    if (odCap > 0) {
        r.windows.push(QC.makeWindow("on_demand", "on-demand", Math.min(100, (odUsed / odCap) * 100), 0, 0, "extra", false))
    }

    if (creditsBody) {
        var unified = creditsCfg.isUnifiedBillingUser || creditsCfg.is_unified_billing_user
        r.planName = unified ? "Grok Build" : "Grok"
    } else {
        r.planName = "Grok Build"
    }
    return r
}

function shortMinimaxName(name) {
    var s = name || ""
    if (s.indexOf("MiniMax-") === 0) s = s.substring(8)
    if (s.indexOf("minimax-") === 0) s = s.substring(8)
    if (s.indexOf("coding-plan-") === 0) s = "c-plan-" + s.substring(12)
    return s
}

function parseMinimax(data) {
    var r = emptyResult()
    r.planName = "MiniMax Coding Plan"
    var models = data.model_remains || []
    var isCoding = function(name) {
        var n = (name || "").toLowerCase()
        return n.indexOf("minimax-m") === 0 || n.indexOf("coding-plan") === 0
    }
    for (var mi = 0; mi < models.length; mi++) {
        if (isCoding(models[mi].model_name)) {
            r.planName = models[mi].model_name
            break
        }
    }

    for (var i = 0; i < models.length; i++) {
        var m = models[i]
        var short = shortMinimaxName(m.model_name)
        var isPrimaryModel = (m.model_name === "general")
        var endMs = QC.parseResetMs(m.end_time)
        var wkEndMs = QC.parseResetMs(m.weekly_end_time)

        if (Number(m.current_interval_total_count) > 0) {
            var limit = Number(m.current_interval_total_count)
            var remaining = Math.max(0, Math.min(limit, Number(m.current_interval_usage_count)))
            var used = limit - remaining
            var pct = limit > 0 ? (used / limit) * 100 : 0
            var id5 = "5h/" + short
            r.windows.push(QC.makeWindow(id5, id5, pct, endMs, MS_5H, isPrimaryModel ? "primary" : "extra", isPrimaryModel))
        } else if (m.current_interval_remaining_percent != null) {
            var ipct = Math.min(100, Number(m.current_interval_remaining_percent))
            r.windows.push(QC.makeWindow("5h/" + short, "5h/" + short, 100 - ipct, endMs, MS_5H, isPrimaryModel ? "primary" : "extra", isPrimaryModel))
        }

        if (Number(m.current_weekly_total_count) > 0) {
            var wlimit = Number(m.current_weekly_total_count)
            var wrem = Math.max(0, Math.min(wlimit, Number(m.current_weekly_usage_count)))
            var wused = wlimit - wrem
            var wpct = wlimit > 0 ? (wused / wlimit) * 100 : 0
            // id keeps wk/ for config stability; label is canonical 7d/
            r.windows.push(QC.makeWindow("wk/" + short, "7d/" + short, wpct, wkEndMs, MS_7D, isPrimaryModel ? "primary" : "extra", isPrimaryModel))
        } else if (m.current_weekly_remaining_percent != null) {
            var wp = Math.min(100, Number(m.current_weekly_remaining_percent))
            r.windows.push(QC.makeWindow("wk/" + short, "7d/" + short, 100 - wp, wkEndMs, MS_7D, isPrimaryModel ? "primary" : "extra", isPrimaryModel))
        }
    }
    return r
}

function parseZai(data) {
    var r = emptyResult()
    var container = data.data || data
    var limits = container.limits || []
    for (var i = 0; i < limits.length; i++) {
        var entry = limits[i]
        if (entry.type === "TOKENS_LIMIT") {
            r.windows.push(QC.makeWindow("session", "5h", entry.percentage || 0, QC.parseResetMs(entry.nextResetTime), MS_5H, "primary", true))
        } else if (entry.type === "TIME_LIMIT") {
            r.windows.push(QC.makeWindow("weekly", "mo", entry.percentage || 0, QC.parseResetMs(entry.nextResetTime), MS_30D, "primary", true))
        }
    }
    var planName = container.planName || container.packageName || ""
    if (planName) r.planName = planName.charAt(0).toUpperCase() + planName.slice(1)
    else r.planName = "Z.ai"
    return r
}

function parseKimi(data) {
    var r = emptyResult()
    r.planName = "Kimi"
    var usage = data.usage || {}
    if (usage.limit > 0) {
        r.windows.push(QC.makeWindow("weekly", "7d", ((usage.used || 0) / usage.limit) * 100,
            QC.parseResetMs(usage.reset_at || usage.resetAt || usage.reset_time || usage.resetTime), MS_7D, "primary", true))
    }

    var limits = data.limits || []
    var sessionLimit = null
    for (var i = 0; i < limits.length; i++) {
        var entry = limits[i]
        var w = entry.window || {}
        var duration = w.duration || 0
        var unit = (w.timeUnit || w.time_unit || "").toUpperCase()
        var minutes = unit === "MINUTE" ? duration : unit === "HOUR" ? duration * 60 : unit === "DAY" ? duration * 1440 : 0
        if (minutes >= 120 && minutes <= 480) { sessionLimit = entry; break }
    }
    if (!sessionLimit && limits.length > 0) sessionLimit = limits[0]
    if (sessionLimit) {
        var detail = sessionLimit.detail || {}
        var pct = detail.limit > 0 ? ((detail.used || 0) / detail.limit) * 100 : 0
        r.windows.push(QC.makeWindow("session", "5h", pct, QC.parseResetMs(sessionLimit.reset_at || sessionLimit.resetAt), MS_5H, "primary", true))
    }

    var tq = data.totalQuota || {}
    if (tq.used != null && Number(tq.used) > 0) {
        r.windows.push(QC.makeWindow("total_quota", "total", 100, 0, MS_30D, "extra", false))
    }
    return r
}