.pragma library

/**
 * Detect quota-window resets between successive poll results, classify
 * natural vs unexpected timing, and format celebration / log payloads.
 *
 * Pure module — no Plasma, filesystem, or network. Runtime ports send
 * notifications and write logs.
 */

function pad2(number) {
    var n = Math.floor(Number(number) || 0)
    return n < 10 ? "0" + n : String(n)
}

function pad3(number) {
    var n = Math.floor(Number(number) || 0) % 1000
    if (n < 10) return "00" + n
    if (n < 100) return "0" + n
    return String(n)
}

function slug(value) {
    var s = String(value || "unknown")
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

function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
}

function expandToAbsolute(path, homeDir) {
    if (!path) return ""
    var p = String(path).trim()
    if (!p) return ""
    if (p === "~")
        return homeDir ? String(homeDir) : ""
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

function cacheRoot(settings) {
    var override = String((settings && settings.configuredRoot) || "").trim()
    var homeDir = (settings && settings.homeDir) || ""
    if (override) {
        var abs = expandToAbsolute(override, homeDir)
        if (abs) return abs
        if (override.indexOf("~/") === 0)
            return "$HOME/" + override.substring(2)
        return override
    }
    if (homeDir)
        return String(homeDir).replace(/\/+$/, "") + "/.cache/plasma-claude-usage"
    return "$HOME/.cache/plasma-claude-usage"
}

function effectiveProvider(profile) {
    if (!profile) return "unknown"
    if (profile.provider === "opencode")
        return profile.opencodeSlot || "anthropic"
    return profile.provider || "unknown"
}

function displayNameOf(profile) {
    if (!profile) return ""
    return profile.displayName || profile.name || profile.id || ""
}

/**
 * Lightweight per-window snapshot for before/after comparison.
 * Does not deep-copy unrelated fields.
 */
function snapshotWindows(windows) {
    var out = []
    if (!windows || !windows.length)
        return out
    for (var i = 0; i < windows.length; i++) {
        var w = windows[i]
        if (!w || !w.id)
            continue
        out.push({
            id: String(w.id),
            label: w.label || String(w.id),
            usagePercent: Number(w.usagePercent) || 0,
            resetAtMs: Number(w.resetAtMs) || 0,
            periodMs: Number(w.periodMs) || 0,
            role: w.role || ""
        })
    }
    return out
}

function indexById(windows) {
    var map = {}
    for (var i = 0; i < windows.length; i++) {
        var w = windows[i]
        if (w && w.id)
            map[w.id] = w
    }
    return map
}

function isoOrNull(ms) {
    var n = Number(ms) || 0
    if (n <= 0) return null
    try {
        return new Date(n).toISOString()
    } catch (e) {
        return null
    }
}

/**
 * Defaults for detection / classification.
 * graceMs: how close to expected resetAt counts as "natural".
 *   Default 20m so Claude's 15m poll + skew still looks natural; callers should
 *   pass max(default, refreshIntervalMs + skew).
 * minResetJumpMs: absolute floor for resetAt forward movement.
 * minPeriodJumpFraction: require jump ≥ fraction of periodMs when period known
 *   (avoids celebrating small provider clock corrections).
 * minUsageDropPercent: secondary signal when resetAt was missing previously.
 */
function mergeOptions(options) {
    var o = options || {}
    return {
        nowMs: o.nowMs !== undefined ? Number(o.nowMs) : Date.now(),
        graceMs: o.graceMs !== undefined ? Number(o.graceMs) : 20 * 60 * 1000,
        minResetJumpMs: o.minResetJumpMs !== undefined ? Number(o.minResetJumpMs) : 60 * 1000,
        minPeriodJumpFraction: o.minPeriodJumpFraction !== undefined
            ? Number(o.minPeriodJumpFraction) : 0.25,
        minUsageDropPercent: o.minUsageDropPercent !== undefined
            ? Number(o.minUsageDropPercent) : 5
    }
}

/**
 * Classify timing relative to the previous window's expected resetAtMs.
 * - natural: observed within grace of expected
 * - early: observed well before expected (unexpected early reset)
 * - late: observed well after expected (poll lag or overdue window)
 * - surprise: no prior expected reset time
 */
function classifyKind(prev, nowMs, graceMs) {
    var expected = Number(prev && prev.resetAtMs) || 0
    if (expected <= 0)
        return "surprise"
    var delta = nowMs - expected
    var grace = graceMs > 0 ? graceMs : 5 * 60 * 1000
    if (Math.abs(delta) <= grace)
        return "natural"
    if (delta < -grace)
        return "early"
    return "late"
}

/**
 * Minimum forward jump of resetAt that counts as a new period.
 * When periodMs is known, require a substantial fraction of the period so a
 * few-minute provider clock correction does not celebrate a false reset.
 */
function requiredResetJumpMs(prev, next, opts) {
    var floor = opts.minResetJumpMs > 0 ? opts.minResetJumpMs : 60 * 1000
    var period = Number(next && next.periodMs) || Number(prev && prev.periodMs) || 0
    var frac = opts.minPeriodJumpFraction
    if (!(frac > 0))
        frac = 0.25
    if (period > 0) {
        var need = Math.floor(period * frac)
        if (need > floor)
            return need
    }
    return floor
}

/**
 * Did this window roll to a new quota period between prev and next?
 */
function isWindowReset(prev, next, opts) {
    if (!prev || !next)
        return false

    var prevReset = Number(prev.resetAtMs) || 0
    var nextReset = Number(next.resetAtMs) || 0
    var prevUsage = Number(prev.usagePercent) || 0
    var nextUsage = Number(next.usagePercent) || 0
    var drop = prevUsage - nextUsage
    var significantDrop = drop >= opts.minUsageDropPercent
    var jump = nextReset - prevReset
    var needJump = requiredResetJumpMs(prev, next, opts)

    // Strongest signal: reset timestamp advanced by a period-scale jump.
    // Does not require a usage drop (second poll may already show ~0%).
    if (prevReset > 0 && nextReset > 0 && jump >= needJump)
        return true

    // First time we learn a resetAt after usage collapsed (e.g. provider
    // previously omitted the field, or first meaningful comparison).
    if (prevReset <= 0 && nextReset > 0 && significantDrop && nextUsage <= 15)
        return true

    // Soft signal: large drop to near-zero with any forward reset movement.
    // Keeps detection when periodMs is missing/wrong but usage clearly rolled.
    if (significantDrop && nextUsage < 5 && nextReset > prevReset && nextReset > 0)
        return true

    return false
}

/**
 * Compare successive window lists for one profile.
 *
 * @param {object} input
 *   prevWindows, nextWindows, profile, nowMs?, options?
 * @returns {{ events: object[], notification: {title,text}|null, envelopes: object[] }}
 */
function detectResets(input) {
    var empty = { events: [], notification: null, envelopes: [] }
    if (!input)
        return empty

    var prev = snapshotWindows(input.prevWindows)
    var next = snapshotWindows(input.nextWindows)
    // First successful poll (or empty prior state): never celebrate as a reset.
    if (!prev.length || !next.length)
        return empty

    var opts = mergeOptions({
        nowMs: input.nowMs,
        graceMs: input.graceMs,
        minResetJumpMs: input.minResetJumpMs,
        minPeriodJumpFraction: input.minPeriodJumpFraction,
        minUsageDropPercent: input.minUsageDropPercent
    })
    if (input.options) {
        var extra = mergeOptions(input.options)
        if (input.graceMs === undefined)
            opts.graceMs = extra.graceMs
        if (input.minResetJumpMs === undefined)
            opts.minResetJumpMs = extra.minResetJumpMs
        if (input.minPeriodJumpFraction === undefined)
            opts.minPeriodJumpFraction = extra.minPeriodJumpFraction
        if (input.minUsageDropPercent === undefined)
            opts.minUsageDropPercent = extra.minUsageDropPercent
        if (input.nowMs === undefined)
            opts.nowMs = extra.nowMs
    }

    var profile = input.profile || {}
    var prevMap = indexById(prev)
    var events = []

    for (var i = 0; i < next.length; i++) {
        var nw = next[i]
        var pw = prevMap[nw.id]
        if (!pw)
            continue
        if (!isWindowReset(pw, nw, opts))
            continue

        var kind = classifyKind(pw, opts.nowMs, opts.graceMs)
        var expectedMs = Number(pw.resetAtMs) || 0
        var event = {
            observedAtMs: opts.nowMs,
            provider: effectiveProvider(profile),
            profileId: profile.id || "",
            displayName: displayNameOf(profile),
            planName: profile.planName || "",
            windowId: nw.id,
            windowLabel: nw.label || nw.id,
            role: nw.role || pw.role || "",
            kind: kind,
            unexpected: kind !== "natural",
            expectedResetAtMs: expectedMs,
            previousUsagePercent: Number(pw.usagePercent) || 0,
            newUsagePercent: Number(nw.usagePercent) || 0,
            previousResetAtMs: expectedMs,
            newResetAtMs: Number(nw.resetAtMs) || 0,
            periodMs: Number(nw.periodMs) || Number(pw.periodMs) || 0,
            bankedResets: profile.bankedResets || 0,
            usageDropPercent: (Number(pw.usagePercent) || 0) - (Number(nw.usagePercent) || 0)
        }
        event.deltaMs = expectedMs > 0 ? (opts.nowMs - expectedMs) : null
        events.push(event)
    }

    if (!events.length)
        return empty

    var envelopes = []
    for (var e = 0; e < events.length; e++)
        envelopes.push(buildLogEnvelope(events[e]))

    return {
        events: events,
        notification: formatNotification(events, profile),
        envelopes: envelopes
    }
}

function buildLogEnvelope(event) {
    var observedAtMs = Number(event.observedAtMs) || Date.now()
    return {
        observedAt: isoOrNull(observedAtMs) || new Date(observedAtMs).toISOString(),
        observedAtMs: observedAtMs,
        provider: event.provider || "",
        profileId: event.profileId || "",
        displayName: event.displayName || "",
        planName: event.planName || "",
        windowId: event.windowId || "",
        windowLabel: event.windowLabel || "",
        role: event.role || "",
        kind: event.kind || "surprise",
        unexpected: !!event.unexpected,
        expectedResetAt: isoOrNull(event.expectedResetAtMs),
        expectedResetAtMs: Number(event.expectedResetAtMs) || 0,
        deltaMs: event.deltaMs === null || event.deltaMs === undefined
            ? null : Number(event.deltaMs),
        previousUsagePercent: Number(event.previousUsagePercent) || 0,
        newUsagePercent: Number(event.newUsagePercent) || 0,
        usageDropPercent: Number(event.usageDropPercent) || 0,
        previousResetAt: isoOrNull(event.previousResetAtMs),
        previousResetAtMs: Number(event.previousResetAtMs) || 0,
        newResetAt: isoOrNull(event.newResetAtMs),
        newResetAtMs: Number(event.newResetAtMs) || 0,
        periodMs: Number(event.periodMs) || 0,
        bankedResets: event.bankedResets || 0
    }
}

function kindPhrase(kind) {
    if (kind === "natural") return "right on time"
    if (kind === "early") return "earlier than expected"
    if (kind === "late") return "later than expected"
    return "unexpectedly"
}

/**
 * Fun, batched notification copy for one or more window resets on a profile.
 */
function formatNotification(events, profile) {
    if (!events || !events.length)
        return null

    var name = displayNameOf(profile) || effectiveProvider(profile) || "quota"
    var labels = []
    var anyUnexpected = false
    var kinds = {}
    for (var i = 0; i < events.length; i++) {
        var ev = events[i]
        labels.push(ev.windowLabel || ev.windowId || "?")
        if (ev.unexpected)
            anyUnexpected = true
        kinds[ev.kind || "surprise"] = true
    }

    var title = "Woo-hoo! " + name + " quota reset 🎉"
    var windowPart = labels.length === 1
        ? labels[0]
        : labels.join(" + ")

    var kindList = []
    if (kinds.natural) kindList.push("natural")
    if (kinds.early) kindList.push("early")
    if (kinds.late) kindList.push("late")
    if (kinds.surprise) kindList.push("surprise")

    var first = events[0]
    var usageBit = ""
    if (events.length === 1) {
        usageBit = " · was " + Math.round(first.previousUsagePercent) + "%"
        if (first.kind)
            usageBit += " · " + kindPhrase(first.kind)
    } else {
        usageBit = " · " + kindList.join("/")
    }

    var text = windowPart + " reset" + usageBit
    if (anyUnexpected && events.length === 1 && first.expectedResetAtMs > 0) {
        try {
            var exp = new Date(first.expectedResetAtMs)
            text += " (expected " + exp.toLocaleString() + ")"
        } catch (e) { /* ignore */ }
    }

    return { title: title, text: text }
}

function buildResetPaths(settings, event, pathTimeMs) {
    var root = cacheRoot(settings).replace(/\/+$/, "")
    var now = new Date(pathTimeMs || (event && event.observedAtMs) || Date.now())
    var y = now.getFullYear()
    var mo = pad2(now.getMonth() + 1)
    var d = pad2(now.getDate())
    var hms = pad2(now.getHours()) + pad2(now.getMinutes()) + pad2(now.getSeconds())
    var ms3 = pad3(now.getMilliseconds())
    var provider = slug((event && event.provider) || "unknown")
    var profile = slug((event && event.profileId) || "profile")
    var win = slug((event && event.windowId) || "window")
    var base = hms + "-" + ms3 + "-" + provider + "-" + profile + "-" + win + ".json"
    return {
        hist: root + "/resets/" + y + "/" + mo + "/" + d + "/" + base,
        latest: root + "/resets/latest/" + provider + "-" + profile + "-" + win + ".json",
        jsonl: root + "/resets/events.jsonl"
    }
}

/**
 * One-shot shell command: write hist + latest + append JSONL via log-reset.sh.
 * Payload is small enough for a single printf (no chunk pipeline).
 */
function buildLogCommand(settings, envelope, pathTimeMs) {
    if (!settings || !settings.logScript)
        return ""
    var event = envelope || {}
    var paths = buildResetPaths(settings, event, pathTimeMs || event.observedAtMs)
    var payload = ""
    try {
        payload = JSON.stringify(envelope)
    } catch (e) {
        return ""
    }
    return "umask 077; printf %s " + shellQuote(payload)
        + " | bash " + shellQuote(settings.logScript)
        + " " + shellQuote(paths.hist)
        + " " + shellQuote(paths.latest)
        + " " + shellQuote(paths.jsonl)
        + " -"
}
