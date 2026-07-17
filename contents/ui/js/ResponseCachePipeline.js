.pragma library

/**
 * Pure response-cache preparation and serial FIFO/watchdog state machine.
 * Runtime adapters supply clock, process, timer, and log effects only.
 *
 * Characterised from ProfileController.qml cache cluster (B023/B024).
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

function effectiveProvider(exchange) {
    if (exchange.provider === "opencode")
        return exchange.opencodeSlot || "anthropic"
    return exchange.provider
}

function cacheRoot(settings) {
    var override = String(settings.configuredRoot || "").trim()
    var homeDir = settings.homeDir || ""
    if (override) {
        var abs = expandToAbsolute(override, homeDir)
        if (abs) return abs
        // home not ready: keep $HOME token for cache-response.sh resolve_path
        if (override.indexOf("~/") === 0)
            return "$HOME/" + override.substring(2)
        return override
    }
    if (homeDir)
        return String(homeDir).replace(/\/+$/, "") + "/.cache/plasma-claude-usage"
    return "$HOME/.cache/plasma-claude-usage"
}

function absoluteCacheRoot(settings) {
    var root = cacheRoot(settings).replace(/\/+$/, "")
    var homeDir = settings.homeDir || ""
    if (root.indexOf("$HOME/") === 0) {
        if (homeDir)
            return String(homeDir).replace(/\/+$/, "") + "/" + root.substring("$HOME/".length)
        return "/tmp/plasma-claude-usage-cache"
    }
    if (root.indexOf("${HOME}/") === 0) {
        if (homeDir)
            return String(homeDir).replace(/\/+$/, "") + "/" + root.substring("${HOME}/".length)
        return "/tmp/plasma-claude-usage-cache"
    }
    if (root.charAt(0) === "~" && root.length > 1 && root.charAt(1) === "/") {
        if (homeDir)
            return String(homeDir).replace(/\/+$/, "") + root.substring(1)
        return "/tmp/plasma-claude-usage-cache"
    }
    return root
}

function buildPaths(settings, exchange, pathTimeMs) {
    var root = cacheRoot(settings).replace(/\/+$/, "")
    var now = new Date(pathTimeMs)
    var y = now.getFullYear()
    var mo = pad2(now.getMonth() + 1)
    var d = pad2(now.getDate())
    var hms = pad2(now.getHours()) + pad2(now.getMinutes()) + pad2(now.getSeconds())
    var ms3 = pad3(now.getMilliseconds())
    var provider = slug(effectiveProvider(exchange) || exchange.provider || "unknown")
    var profile = slug(exchange.profileId)
    var ep = slug(exchange.endpoint || "response")
    var base = hms + "-" + ms3 + "-" + provider + "-" + profile + "-" + ep + ".json"
    return {
        hist: root + "/responses/" + y + "/" + mo + "/" + d + "/" + base,
        latest: root + "/latest/" + provider + "-" + profile + "-" + ep + ".json"
    }
}

function buildEnvelope(exchange, saveTimeMs) {
    var rawText = exchange.responseText === undefined || exchange.responseText === null
        ? ""
        : String(exchange.responseText)
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
    var now = new Date(saveTimeMs)
    return {
        savedAt: now.toISOString(),
        savedAtMs: now.getTime(),
        provider: effectiveProvider(exchange) || exchange.provider || "",
        profileId: exchange.profileId || "",
        endpoint: exchange.endpoint || "",
        url: exchange.url || "",
        httpStatus: exchange.status || 0,
        body: body,
        raw: raw,
        truncated: truncated
    }
}

function buildCommands(settings, paths, pendingPath, payload) {
    var pendingDir = pendingPath.substring(0, pendingPath.lastIndexOf("/"))
    var text = payload === undefined || payload === null ? "" : String(payload)
    var chunkSize = settings.payloadChunkSize > 0 ? settings.payloadChunkSize : 8192
    var cmds = []

    // umask 077 so staged bodies are not world-readable while pending
    if (text.length === 0) {
        cmds.push("umask 077; mkdir -p -- " + shellQuote(pendingDir)
                  + " && : > " + shellQuote(pendingPath))
    } else {
        var first = true
        for (var i = 0; i < text.length; i += chunkSize) {
            var end = i + chunkSize
            if (end > text.length)
                end = text.length
            var chunk = text.substring(i, end)
            if (first) {
                cmds.push("umask 077; mkdir -p -- " + shellQuote(pendingDir)
                          + " && printf %s " + shellQuote(chunk)
                          + " > " + shellQuote(pendingPath))
                first = false
            } else {
                cmds.push("umask 077; printf %s " + shellQuote(chunk)
                          + " >> " + shellQuote(pendingPath))
            }
        }
    }

    cmds.push("bash " + shellQuote(settings.cacheScript)
              + " " + shellQuote(paths.hist)
              + " " + shellQuote(paths.latest)
              + " " + shellQuote(pendingPath))
    return cmds
}

function create(runtime) {
    var queue = []
    var busy = false
    var inFlightCommand = ""
    var inFlightSource = ""
    var attempt = 0
    var launchSequence = 0
    var pendingSequence = 0

    function nextPendingPath(settings, pendingTimeMs) {
        pendingSequence = (pendingSequence + 1) % 1000000
        var dir = absoluteCacheRoot(settings) + "/pending"
        return dir + "/p-" + pendingTimeMs + "-" + pendingSequence + ".json"
    }

    function launch(command) {
        busy = true
        inFlightCommand = command
        launchSequence = (launchSequence + 1) % 100000
        inFlightSource = "CACHE_WRITE_SEQ=" + launchSequence + " " + command
        runtime.startWatchdog(runtime.settings().watchdogMs || 12000)
        runtime.startCommand(inFlightSource, command)
    }

    function drain() {
        if (busy) return
        if (!queue.length) return
        var next = queue[0]
        queue = queue.slice(1)
        attempt = 1
        launch(next)
    }

    function enqueueCommands(commands) {
        queue = queue.concat(commands)
        drain()
    }

    function recordExchange(exchange) {
        var s = runtime.settings()
        if (!s.enabled) return
        if (!exchange || !exchange.profileId) {
            runtime.log("Claude Usage: response cache ignored exchange without profileId")
            return
        }
        try {
            // Preserve current independent clock ownership/order exactly:
            // history path first, envelope second, pending filename third.
            var paths = buildPaths(s, exchange, runtime.nowMs())
            var envelope = buildEnvelope(exchange, runtime.nowMs())
            var pendingPath = nextPendingPath(s, runtime.nowMs())
            var commands = buildCommands(s, paths, pendingPath,
                                        JSON.stringify(envelope))
            enqueueCommands(commands)
        } catch (error) {
            runtime.log("Claude Usage: response cache error " + String(error))
        }
    }

    function commandFinished(sourceName, result) {
        runtime.disconnectCommand(sourceName)
        if (sourceName !== inFlightSource) return
        runtime.stopWatchdog()
        busy = false
        inFlightCommand = ""
        inFlightSource = ""
        attempt = 0
        var exitCode = result && result.exitCode !== undefined ? result.exitCode : 0
        if (exitCode)
            runtime.log("Claude Usage: cache write failed exit=" + exitCode
                        + " " + String((result && result.stderr) || ""))
        drain()
    }

    function watchdogFired() {
        if (!busy) return
        var command = inFlightCommand
        var source = inFlightSource
        var stalledAttempt = attempt
        runtime.log("Claude Usage: cache write stalled (onNewData never fired), attempt="
                    + stalledAttempt + " seq=" + launchSequence)
        // Clear in-flight identity before disconnect so late completion cannot double-drain.
        inFlightSource = ""
        inFlightCommand = ""
        busy = false
        if (source) {
            try { runtime.disconnectCommand(source) }
            catch (error) { /* current disconnect failures are ignored */ }
        }
        var maxAttempts = runtime.settings().maxAttempts || 2
        if (command && stalledAttempt < maxAttempts) {
            attempt = stalledAttempt + 1
            launch(command)
            return
        }
        if (command)
            runtime.log("Claude Usage: cache write dropped after stall, attempts="
                        + stalledAttempt)
        attempt = 0
        drain()
    }

    function stateForTests() {
        return {
            queue: queue.slice(0),
            busy: busy,
            inFlightCommand: inFlightCommand,
            inFlightSource: inFlightSource,
            attempt: attempt,
            launchSequence: launchSequence,
            pendingSequence: pendingSequence
        }
    }

    return {
        recordExchange: recordExchange,
        commandFinished: commandFinished,
        watchdogFired: watchdogFired,
        stateForTests: stateForTests
    }
}
