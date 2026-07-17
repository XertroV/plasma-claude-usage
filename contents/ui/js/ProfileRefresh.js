.pragma library
.import "ProfileRefreshProviders.js" as Providers

/**
 * Pure one-profile refresh transaction.
 *
 * ProfileRefresh.run(input, ports, emit) -> accepted
 *
 * Emits: one "started", at most one "credentials", exactly one terminal
 * (success | auth_error | auth_suspended | rate_limited | transport_error | parse_error).
 * Does not mutate input; carries only stable profileId + generation across async seams.
 */

function cloneObject(obj) {
    if (!obj || typeof obj !== "object")
        return obj
    var out = {}
    for (var k in obj) {
        if (Object.prototype.hasOwnProperty.call(obj, k))
            out[k] = obj[k]
    }
    return out
}

function startedPatch(profile, manual) {
    var patch = {
        loading: true,
        error: "",
        credLoadManual: !!manual
    }
    if (manual) {
        // Manual refresh: lift suspension/holds so dual-fetch re-runs with
        // freshly catted credentials after token renewal (B029/B033)
        patch.authSuspended = false
        patch.autoRefreshHoldUntilMs = 0
    }
    return patch
}

function clearFailureStatePatch() {
    return {
        authFailCount: 0,
        authSuspended: false,
        autoRefreshHoldUntilMs: 0,
        lastFailedToken: "",
        backoffMultiplier: 1
    }
}

/**
 * Merge resolved auth into a local profile snapshot after a valid credential body.
 * Clears auth failure state only when a non-empty token comes from a manual read
 * or differs from lastFailedToken (token rotation).
 */
function credentialStateAfterRead(profile, auth, manual) {
    var next = cloneObject(profile)
    var a = auth || {}
    next.accessToken = a.token || ""
    next.accountId = a.accountId || ""
    if (a.resourceUrl)
        next.resourceUrl = a.resourceUrl
    next.opencodeSlot = a.opencodeSlot || next.opencodeSlot || ""
    next.planName = a.planName || next.planName || ""
    next.credLoadManual = false
    if (a.token && (manual || a.token !== (profile.lastFailedToken || ""))) {
        var clear = clearFailureStatePatch()
        next.authFailCount = clear.authFailCount
        next.authSuspended = clear.authSuspended
        next.autoRefreshHoldUntilMs = clear.autoRefreshHoldUntilMs
        next.lastFailedToken = clear.lastFailedToken
        next.backoffMultiplier = clear.backoffMultiplier
    }
    return next
}

function credentialPatch(retryProfile) {
    return {
        accessToken: retryProfile.accessToken || "",
        accountId: retryProfile.accountId || "",
        resourceUrl: retryProfile.resourceUrl || "https://api.minimax.io",
        opencodeSlot: retryProfile.opencodeSlot || "",
        planName: retryProfile.planName || "",
        credLoadManual: false,
        authFailCount: retryProfile.authFailCount || 0,
        authSuspended: !!retryProfile.authSuspended,
        autoRefreshHoldUntilMs: retryProfile.autoRefreshHoldUntilMs || 0,
        lastFailedToken: retryProfile.lastFailedToken || "",
        backoffMultiplier: retryProfile.backoffMultiplier || 1
    }
}

function authFailure(profile, tokenSnapshot, policy, nowMs) {
    var count = (profile.authFailCount || 0) + 1
    var maxAttempts = (policy && policy.maxAuthAutoAttempts) || 2
    var holdMs = (policy && policy.authRetryHoldMs) || 300000
    var errorText = tokenSnapshot ? "Token expired" : "Not logged in"
    var patch = {
        loading: false,
        error: errorText,
        authFailCount: count,
        lastFetchMs: nowMs,
        lastFailedToken: tokenSnapshot !== undefined && tokenSnapshot !== null
            ? tokenSnapshot
            : (profile.accessToken || "")
    }
    if (count >= maxAttempts) {
        patch.authSuspended = true
        patch.autoRefreshHoldUntilMs = 0
    } else {
        patch.authSuspended = false
        patch.autoRefreshHoldUntilMs = nowMs + holdMs
    }
    return {
        type: "auth_error",
        patch: patch,
        error: {
            code: tokenSnapshot ? "token_expired" : "not_logged_in",
            message: errorText,
            status: tokenSnapshot ? 401 : 0
        }
    }
}

function suspendedOutcome(profile, policy, nowMs) {
    var msg = profile.error || "Token expired"
    return {
        type: "auth_suspended",
        patch: {
            loading: false,
            lastFetchMs: nowMs,
            error: msg
        },
        error: {
            code: "auth_suspended",
            message: msg
        }
    }
}

function rateLimitOutcome(profile, policy, nowMs) {
    var mult = (profile.backoffMultiplier || 1) * 2
    var base = (policy && policy.baseRefreshIntervalMs) || 300000
    var maxBackoff = (policy && policy.maxBackoffIntervalMs) || 3600000
    var wait = Math.min(base * mult, maxBackoff)
    var maxMult = Math.max(1, Math.ceil(maxBackoff / Math.max(base, 1)))
    if (mult > maxMult)
        mult = maxMult
    return {
        type: "rate_limited",
        patch: {
            loading: false,
            error: "Rate limited",
            backoffMultiplier: mult,
            lastFetchMs: nowMs,
            autoRefreshHoldUntilMs: nowMs + wait
        },
        error: {
            code: "rate_limited",
            message: "Rate limited",
            status: 429
        }
    }
}

function successOutcome(profile, usageResult, nowMs) {
    var clear = clearFailureStatePatch()
    return {
        type: "success",
        patch: {
            loading: false,
            error: "",
            lastFetchMs: nowMs,
            authFailCount: clear.authFailCount,
            authSuspended: clear.authSuspended,
            autoRefreshHoldUntilMs: clear.autoRefreshHoldUntilMs,
            lastFailedToken: clear.lastFailedToken,
            backoffMultiplier: clear.backoffMultiplier
        },
        usageResult: usageResult
    }
}

function transportOutcome(providerOutcome, nowMs) {
    var status = (providerOutcome && providerOutcome.status) || 0
    var fromTimeout = !!(providerOutcome && providerOutcome.fromTimeout)
    var detail
    if (status === 0)
        detail = fromTimeout ? "timeout" : "network error"
    else
        detail = String(status)
    var message = "API error (" + detail + ")"
    return {
        type: "transport_error",
        patch: {
            loading: false,
            error: message,
            lastFetchMs: nowMs
        },
        error: {
            code: status === 0 ? (fromTimeout ? "timeout" : "network") : "http",
            message: message,
            status: status,
            fromTimeout: fromTimeout
        }
    }
}

function parseErrorOutcome(providerOutcome, nowMs) {
    return {
        type: "parse_error",
        patch: {
            loading: false,
            error: "Parse error",
            lastFetchMs: nowMs
        },
        error: {
            code: "parse",
            message: "Parse error",
            detail: providerOutcome && providerOutcome.detail
                ? String(providerOutcome.detail)
                : ""
        }
    }
}

function outcomeFor(providerOutcome, retryProfile, tokenSnapshot, policy, nowMs) {
    var kind = providerOutcome && providerOutcome.kind
    if (kind === "success")
        return successOutcome(retryProfile, providerOutcome.usageResult, nowMs)
    if (kind === "auth_error")
        return authFailure(retryProfile, tokenSnapshot, policy, nowMs)
    if (kind === "rate_limited")
        return rateLimitOutcome(retryProfile, policy, nowMs)
    if (kind === "transport_error")
        return transportOutcome(providerOutcome, nowMs)
    if (kind === "parse_error")
        return parseErrorOutcome(providerOutcome, nowMs)
    return parseErrorOutcome({ detail: "unknown outcome: " + kind }, nowMs)
}

/**
 * @param {object} input - { profile, generation, manual, policy }
 * @param {object} ports - { readCredentials, requestHttp, recordExchange, now }
 * @param {function} emit - transition callback
 * @returns {boolean} accepted
 */
function run(input, ports, emit) {
    if (!input || !input.profile || !input.profile.id)
        return false
    if (!ports || typeof ports.readCredentials !== "function")
        return false

    var profile = cloneObject(input.profile)
    var profileId = profile.id
    var generation = input.generation
    var manual = !!input.manual
    var policy = input.policy || {}
    var terminal = false
    var credentialRequest = {
        profileId: profileId,
        generation: generation,
        path: profile.credPath || "",
        isFlatFile: !!profile.isFlatFile
    }

    var accepted = ports.readCredentials(credentialRequest, onCredentials)
    if (!accepted)
        return false

    emit({
        type: "started",
        profileId: profileId,
        generation: generation,
        patch: startedPatch(profile, manual)
    })
    return true

    function onCredentials(readResult) {
        if (terminal)
            return
        var preparation
        try {
            // Preserve current behaviour: valid stdout is parsed even when the
            // executable adapter reports a non-zero exit code.
            if (!readResult || String(readResult.stdout || "").length < 2)
                return finish(authFailure(profile, "", policy, ports.now()))
            preparation = Providers.prepare(
                profile, String(readResult.stdout), ports.now())
        } catch (error) {
            return finish(authFailure(profile, "", policy, ports.now()))
        }

        // Detect suspension against the pre-credential profile snapshot.
        var unchangedSuspendedToken = !manual && profile.authSuspended
            && preparation.auth && preparation.auth.token
            && preparation.auth.token === profile.lastFailedToken

        // Every syntactically valid credential body updates auth metadata and
        // clears credLoadManual before any terminal outcome. A valid token from
        // a manual read, or a rotated token, additionally clears auth failures.
        var retryProfile = credentialStateAfterRead(
            profile, preparation.auth, manual)
        emit({
            type: "credentials",
            profileId: profileId,
            generation: generation,
            patch: credentialPatch(retryProfile)
        })

        if (!preparation.auth || !preparation.auth.token
                || preparation.kind === "auth_error")
            return finish(authFailure(retryProfile, "", policy, ports.now()))
        if (unchangedSuspendedToken)
            return finish(suspendedOutcome(retryProfile, policy, ports.now()))
        dispatch(preparation, retryProfile)
    }

    function dispatch(preparation, retryProfile) {
        var requests = preparation.requests || []
        if (requests.length === 0) {
            return finish(authFailure(retryProfile, "", policy, ports.now()))
        }
        var pending = requests.length
        var exchanges = []
        for (var i = 0; i < requests.length; i++) {
            (function(providerRequest) {
                var request = cloneObject(providerRequest)
                request.profileId = profileId
                request.generation = generation
                request.provider = profile.provider || ""
                request.opencodeSlot = (preparation.auth && preparation.auth.opencodeSlot)
                    || profile.opencodeSlot || ""
                if (providerRequest.headers)
                    request.headers = cloneObject(providerRequest.headers)
                var settled = false
                ports.requestHttp(request, function(exchange) {
                    if (settled || terminal)
                        return
                    settled = true
                    exchanges.push(exchange)
                    ports.recordExchange(exchange)
                    pending--
                    if (pending === 0) {
                        var providerOutcome = preparation.finalize(exchanges)
                        finish(outcomeFor(
                            providerOutcome,
                            retryProfile,
                            preparation.auth.token,
                            policy,
                            ports.now()
                        ))
                    }
                })
            })(requests[i])
        }
    }

    function finish(outcome) {
        if (terminal)
            return
        terminal = true
        outcome.profileId = profileId
        outcome.generation = generation
        emit(outcome)
    }
}
