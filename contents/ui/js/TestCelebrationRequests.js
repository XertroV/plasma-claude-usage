.pragma library

var MAX_AGE_MS = 15000
var MAX_FUTURE_SKEW_MS = 2000
var MAX_NONCE_LENGTH = 128

function createRequest(nowMs, nonceFactory) {
    return {
        version: 1,
        type: "test-celebration",
        createdAtMs: nowMs,
        nonce: nonceFactory()
    }
}

function serializeRequest(request) {
    return JSON.stringify(request)
}

function copiedPrunedState(state, nowMs) {
    var pruned = Object.create(null)
    var key
    var value
    var cutoff = nowMs - MAX_AGE_MS - MAX_FUTURE_SKEW_MS
    var source = state || {}

    for (key in source) {
        if (!Object.prototype.hasOwnProperty.call(source, key))
            continue
        value = source[key]
        if (typeof value === "number" && isFinite(value) && value >= cutoff)
            pruned[key] = value
    }
    return pruned
}

function rejected(reason, state) {
    return {
        accepted: false,
        reason: reason,
        request: null,
        state: state
    }
}

function consume(raw, state, nowMs) {
    var nextState = copiedPrunedState(state, nowMs)
    var request

    if (typeof raw !== "string" || raw.trim().length === 0)
        return rejected("empty", nextState)

    try {
        request = JSON.parse(raw)
    } catch (error) {
        return rejected("malformed", nextState)
    }

    if (!request || typeof request !== "object" || request.version !== 1 || request.type !== "test-celebration")
        return rejected("schema", nextState)
    if (typeof request.nonce !== "string" || request.nonce.length === 0 || request.nonce.length > MAX_NONCE_LENGTH)
        return rejected("nonce", nextState)
    if (typeof request.createdAtMs !== "number" || !isFinite(request.createdAtMs))
        return rejected("timestamp", nextState)
    if (nowMs - request.createdAtMs > MAX_AGE_MS)
        return rejected("stale", nextState)
    if (request.createdAtMs - nowMs > MAX_FUTURE_SKEW_MS)
        return rejected("future", nextState)
    if (Object.prototype.hasOwnProperty.call(nextState, request.nonce))
        return rejected("replay", nextState)

    nextState[request.nonce] = nowMs
    return {
        accepted: true,
        reason: "",
        request: request,
        state: nextState
    }
}

function eligibleProfileIds(profiles, limits) {
    var eligible = []
    var source = profiles || []
    var cardLimits = limits || {}
    var maximum = Math.max(Number(cardLimits.compactMaxCards) || 0, Number(cardLimits.fullMaxCards) || 0)
    var i
    var profile

    maximum = Math.max(0, Math.floor(maximum))
    for (i = 0; i < source.length && eligible.length < maximum; ++i) {
        profile = source[i]
        if (profile && profile.enabled !== false && profile.id)
            eligible.push(profile.id)
    }
    return eligible
}

function selectProfileId(profiles, limits, randomFn) {
    var ids = eligibleProfileIds(profiles, limits)
    var random
    var index

    if (ids.length === 0)
        return ""

    random = randomFn()
    if (typeof random !== "number" || !isFinite(random) || random < 0)
        random = 0
    else if (random >= 1)
        random = 1

    index = random === 1 ? ids.length - 1 : Math.floor(random * ids.length)
    return ids[index]
}
