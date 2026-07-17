/**
 * Deterministic credential / HTTP / cache / clock ports for ProfileRefresh tests.
 * No network or Plasma I/O — callbacks are driven explicitly by the test harness.
 */

export function mockRefreshPorts({
    now = 1_800_000_000_000,
    credentialText = "{}",
    credentialAccepted = true
} = {}) {
    const credentialCallbacks = []
    const httpCallbacks = []
    const exchanges = []
    return {
        credentialCallbacks,
        httpCallbacks,
        exchanges,
        ports: {
            now: () => now,
            readCredentials(request, callback) {
                if (!credentialAccepted) return false
                credentialCallbacks.push({ request, callback })
                return true
            },
            requestHttp(request, callback) {
                httpCallbacks.push({ request, callback })
            },
            recordExchange(exchange) {
                exchanges.push(exchange)
            }
        },
        finishCredentials(result = { stdout: credentialText, stderr: "", exitCode: 0 }) {
            const entry = credentialCallbacks.shift()
            if (!entry) throw new Error("finishCredentials: no pending credential callback")
            entry.callback(result)
        },
        finishHttp(index, result) {
            const entry = httpCallbacks[index]
            if (!entry) throw new Error("finishHttp: no pending HTTP callback at index " + index)
            const request = entry.request
            entry.callback({
                key: request.key,
                profileId: request.profileId,
                generation: request.generation,
                provider: request.provider,
                opencodeSlot: request.opencodeSlot,
                endpoint: request.endpoint,
                url: request.url,
                status: result.status,
                responseText: result.responseText || "",
                fromTimeout: !!result.fromTimeout
            })
        }
    }
}
