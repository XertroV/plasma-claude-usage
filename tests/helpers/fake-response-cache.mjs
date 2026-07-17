/**
 * Deterministic runtime adapter for ResponseCachePipeline.create(runtime).
 * Captures clock, process, watchdog, and log effects without Plasma/fs/network.
 */
export function createFakeResponseCache(Pipeline, initialSettings = {}, times = []) {
    const settings = {
        enabled: true,
        configuredRoot: "",
        homeDir: "/home/tester",
        cacheScript: "/widget/contents/scripts/cache-response.sh",
        payloadChunkSize: 8192,
        watchdogMs: 12000,
        maxAttempts: 2,
        ...initialSettings
    }
    const clock = [...times]
    const effects = {
        commands: [],
        disconnects: [],
        clockReads: [],
        watchdogStarts: [],
        watchdogStops: 0,
        logs: []
    }
    let pipeline
    const runtime = {
        settings: () => ({ ...settings }),
        nowMs() {
            if (!clock.length) throw new Error("fake clock exhausted")
            const value = clock.shift()
            effects.clockReads.push(value)
            return value
        },
        startCommand(sourceName, command) {
            effects.commands.push({ sourceName, command })
        },
        disconnectCommand(sourceName) {
            effects.disconnects.push(sourceName)
        },
        startWatchdog(milliseconds) {
            effects.watchdogStarts.push(milliseconds)
        },
        stopWatchdog() {
            effects.watchdogStops += 1
        },
        log(message) {
            effects.logs.push(String(message))
        }
    }
    pipeline = Pipeline.create(runtime)
    return {
        settings,
        effects,
        recordExchange(exchange) { pipeline.recordExchange(exchange) },
        finish(sourceName, result = { exitCode: 0, stderr: "" }) {
            pipeline.commandFinished(sourceName, result)
        },
        fireWatchdog() { pipeline.watchdogFired() },
        state() { return pipeline.stateForTests() }
    }
}
