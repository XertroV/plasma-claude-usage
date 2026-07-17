#!/usr/bin/env node
/**
 * P1.M2.E1.T002 / I002 Task 2 — pure ProfileRefresh transaction + mock ports.
 * No network / Plasma I/O. Covers identity, auth, backoff, Grok, once-only settlement.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"
import { mockRefreshPorts } from "./helpers/mock-refresh-ports.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const NOW = 1_800_000_000_000
const CLAUDE_BODY = readFileSync(join(root, "fixture-examples/2026-07-02-claude.json"), "utf8")
const GROK_DEFAULT = readFileSync(join(root, "fixture-examples/2026-07-13-grok-billing-default.json"), "utf8")
const GROK_CREDITS = readFileSync(join(root, "fixture-examples/2026-07-13-grok-billing-credits.json"), "utf8")

const QC = loadQmlJs(join(root, "contents/ui/js/QuotaCommon.js"), {}, [
    "formatWindowDuration", "makeWindow", "parseResetMs"
])
const QP = loadQmlJs(join(root, "contents/ui/js/QuotaParsers.js"), { QC }, [
    "parseClaude", "parseCodex", "parseGrok", "parseMinimax", "parseZai", "parseKimi"
])
const Providers = loadQmlJs(
    join(root, "contents/ui/js/ProfileRefreshProviders.js"), { QC, QP },
    ["prepare"]
)
const Refresh = loadQmlJs(
    join(root, "contents/ui/js/ProfileRefresh.js"), { Providers },
    ["run"]
)

const POLICY = {
    authRetryHoldMs: 300000,
    maxBackoffIntervalMs: 3600000,
    maxAuthAutoAttempts: 2,
    baseRefreshIntervalMs: 300000
}

function claudeCreds(token = "claude-token") {
    return JSON.stringify({
        claudeAiOauth: {
            accessToken: token,
            rateLimitTier: "default_claude_pro"
        }
    })
}

function grokCreds(token = "grok-token") {
    return JSON.stringify({
        accounts: {
            main: {
                key: token,
                expires_at: "2099-01-01T00:00:00Z",
                create_time: "2026-01-01T00:00:00Z"
            }
        }
    })
}

function baseProfile(overrides = {}) {
    return Object.assign({
        id: "claude-1",
        provider: "claude",
        credPath: "/tmp/auth.json",
        authFailCount: 0,
        authSuspended: false,
        lastFailedToken: "",
        backoffMultiplier: 1,
        error: "",
        planName: "",
        accessToken: "",
        accountId: "",
        resourceUrl: "",
        opencodeSlot: "",
        autoRefreshHoldUntilMs: 0,
        isFlatFile: false
    }, overrides)
}

function baseInput(overrides = {}) {
    const profile = baseProfile(overrides.profile || {})
    const input = {
        profile,
        generation: overrides.generation !== undefined ? overrides.generation : 7,
        manual: !!overrides.manual,
        policy: Object.assign({}, POLICY, overrides.policy || {})
    }
    return input
}

function runCapture(input, mock) {
    const transitions = []
    const accepted = Refresh.run(input, mock.ports, t => transitions.push(t))
    return { accepted, transitions }
}

function terminalTypes(transitions) {
    return transitions.filter(t => t.type !== "started" && t.type !== "credentials")
        .map(t => t.type)
}

// ── Busy credential port ────────────────────────────────────────────
{
    const mock = mockRefreshPorts({ credentialAccepted: false })
    const input = baseInput()
    const { accepted, transitions } = runCapture(input, mock)
    assert.equal(accepted, false)
    assert.equal(transitions.length, 0)
    assert.equal(mock.credentialCallbacks.length, 0)
}

// ── Happy path: started → credentials → success ─────────────────────
{
    const mock = mockRefreshPorts({ now: NOW, credentialText: claudeCreds() })
    const input = baseInput()
    const profileSnap = JSON.stringify(input.profile)
    const { accepted, transitions } = runCapture(input, mock)
    assert.equal(accepted, true)
    assert.deepEqual(transitions.map(t => t.type), ["started"])
    assert.equal(transitions[0].profileId, "claude-1")
    assert.equal(transitions[0].generation, 7)
    assert.equal(transitions[0].patch.loading, true)
    assert.equal(transitions[0].patch.error, "")
    assert.equal(transitions[0].patch.credLoadManual, false)

    const credReq = mock.credentialCallbacks[0].request
    assert.equal(credReq.profileId, "claude-1")
    assert.equal(credReq.generation, 7)
    assert.equal(credReq.path, "/tmp/auth.json")

    mock.finishCredentials()
    assert.deepEqual(transitions.map(t => t.type), ["started", "credentials"])
    assert.equal(transitions[1].profileId, "claude-1")
    assert.equal(transitions[1].generation, 7)
    assert.equal(transitions[1].patch.accessToken, "claude-token")
    assert.equal(transitions[1].patch.planName, "Pro")
    assert.equal(transitions[1].patch.credLoadManual, false)

    assert.equal(mock.httpCallbacks.length, 1)
    const httpReq = mock.httpCallbacks[0].request
    assert.equal(httpReq.profileId, "claude-1")
    assert.equal(httpReq.generation, 7)
    assert.equal(httpReq.provider, "claude")
    assert.equal(httpReq.headers.Authorization, "Bearer claude-token")
    assert.equal(httpReq.headers["anthropic-beta"], "oauth-2025-04-20")

    mock.finishHttp(0, { status: 200, responseText: CLAUDE_BODY })
    assert.deepEqual(transitions.map(t => t.type), ["started", "credentials", "success"])
    const success = transitions[2]
    assert.equal(success.profileId, "claude-1")
    assert.equal(success.generation, 7)
    assert.equal(success.patch.loading, false)
    assert.equal(success.patch.error, "")
    assert.equal(success.patch.authFailCount, 0)
    assert.equal(success.patch.authSuspended, false)
    assert.equal(success.patch.backoffMultiplier, 1)
    assert.equal(success.patch.lastFetchMs, NOW)
    assert.ok(success.usageResult)
    assert.ok(success.usageResult.windows.length >= 2)
    assert.equal(mock.exchanges.length, 1)
    assert.equal(mock.exchanges[0].profileId, "claude-1")
    assert.equal(mock.exchanges[0].generation, 7)
    // input immutability
    assert.equal(JSON.stringify(input.profile), profileSnap)
}

// ── Valid stdout with non-zero executable exit still parses ─────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { accepted, transitions } = runCapture(baseInput(), mock)
    assert.equal(accepted, true)
    mock.finishCredentials({
        stdout: claudeCreds("nz-token"),
        stderr: "warn",
        exitCode: 1
    })
    assert.equal(transitions[1].type, "credentials")
    assert.equal(transitions[1].patch.accessToken, "nz-token")
    assert.equal(mock.httpCallbacks.length, 1)
    mock.finishHttp(0, { status: 200, responseText: CLAUDE_BODY })
    assert.equal(transitions[2].type, "success")
}

// ── Missing credential body → auth_error, no credentials transition ─
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: "", stderr: "", exitCode: 1 })
    assert.deepEqual(transitions.map(t => t.type), ["started", "auth_error"])
    assert.equal(transitions[1].patch.loading, false)
    assert.equal(transitions[1].patch.error, "Not logged in")
    assert.equal(transitions[1].patch.authFailCount, 1)
    assert.equal(transitions[1].patch.lastFailedToken, "")
    assert.equal(transitions[1].patch.autoRefreshHoldUntilMs, NOW + POLICY.authRetryHoldMs)
    assert.equal(mock.httpCallbacks.length, 0)
}

// ── Malformed credential JSON → credentials then auth_error ─────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: "{not-json", stderr: "", exitCode: 0 })
    // prepare catches parse error → empty auth; credentials still emitted
    assert.equal(transitions[1].type, "credentials")
    assert.equal(transitions[1].patch.accessToken, "")
    assert.equal(transitions[1].patch.credLoadManual, false)
    assert.equal(transitions[2].type, "auth_error")
    assert.equal(transitions[2].patch.error, "Not logged in")
    assert.equal(mock.httpCallbacks.length, 0)
}

// ── Syntactically valid credentials, missing token ──────────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({
        stdout: JSON.stringify({ claudeAiOauth: { accessToken: "" } }),
        stderr: "",
        exitCode: 0
    })
    assert.equal(transitions[1].type, "credentials")
    assert.equal(transitions[1].patch.accessToken, "")
    assert.equal(transitions[2].type, "auth_error")
    assert.equal(transitions[2].patch.error, "Not logged in")
    assert.equal(transitions[2].patch.authFailCount, 1)
    assert.equal(mock.httpCallbacks.length, 0)
}

// ── First auth failure (HTTP 401) holds; second suspends ─────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { authFailCount: 0 }
    }), mock)
    mock.finishCredentials({ stdout: claudeCreds("tok-a"), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 401, responseText: "nope" })
    assert.equal(transitions[2].type, "auth_error")
    assert.equal(transitions[2].patch.error, "Token expired")
    assert.equal(transitions[2].patch.authFailCount, 1)
    assert.equal(transitions[2].patch.authSuspended, false)
    assert.equal(transitions[2].patch.lastFailedToken, "tok-a")
    assert.equal(transitions[2].patch.autoRefreshHoldUntilMs, NOW + POLICY.authRetryHoldMs)
    assert.equal(mock.exchanges.length, 1)
}
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { authFailCount: 1, lastFailedToken: "tok-a" }
    }), mock)
    mock.finishCredentials({ stdout: claudeCreds("tok-a"), stderr: "", exitCode: 0 })
    // same token as lastFailedToken + not manual → does not clear fail state
    assert.equal(transitions[1].patch.authFailCount, 1)
    mock.finishHttp(0, { status: 403, responseText: "" })
    assert.equal(transitions[2].type, "auth_error")
    assert.equal(transitions[2].patch.authFailCount, 2)
    assert.equal(transitions[2].patch.authSuspended, true)
    assert.equal(transitions[2].patch.autoRefreshHoldUntilMs, 0)
    assert.equal(transitions[2].patch.lastFailedToken, "tok-a")
}

// ── Unchanged suspended token: credentials then auth_suspended, no HTTP
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: {
            authSuspended: true,
            authFailCount: 2,
            lastFailedToken: "tok-a",
            error: "Token expired"
        }
    }), mock)
    mock.finishCredentials({ stdout: claudeCreds("tok-a"), stderr: "", exitCode: 0 })
    assert.deepEqual(transitions.map(t => t.type), ["started", "credentials", "auth_suspended"])
    assert.equal(transitions[1].patch.accessToken, "tok-a")
    assert.equal(transitions[1].patch.credLoadManual, false)
    // must NOT clear suspension on credentials
    assert.equal(transitions[1].patch.authSuspended, true)
    assert.equal(transitions[1].patch.authFailCount, 2)
    assert.equal(transitions[1].patch.lastFailedToken, "tok-a")
    assert.equal(transitions[2].patch.loading, false)
    assert.equal(transitions[2].patch.lastFetchMs, NOW)
    assert.equal(transitions[2].patch.error, "Token expired")
    assert.equal(mock.httpCallbacks.length, 0)
}

// ── Rotated token clears failure and proceeds to HTTP ────────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: {
            authSuspended: true,
            authFailCount: 2,
            lastFailedToken: "tok-a",
            error: "Token expired"
        }
    }), mock)
    mock.finishCredentials({ stdout: claudeCreds("tok-b"), stderr: "", exitCode: 0 })
    assert.equal(transitions[1].type, "credentials")
    assert.equal(transitions[1].patch.accessToken, "tok-b")
    assert.equal(transitions[1].patch.authFailCount, 0)
    assert.equal(transitions[1].patch.authSuspended, false)
    assert.equal(transitions[1].patch.lastFailedToken, "")
    assert.equal(transitions[1].patch.backoffMultiplier, 1)
    assert.equal(mock.httpCallbacks.length, 1)
    mock.finishHttp(0, { status: 200, responseText: CLAUDE_BODY })
    assert.equal(transitions[2].type, "success")
}

// ── Manual retry clears suspension on started + failure state on creds
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        manual: true,
        profile: {
            authSuspended: true,
            authFailCount: 2,
            lastFailedToken: "tok-a",
            autoRefreshHoldUntilMs: NOW + 9999,
            error: "Token expired"
        }
    }), mock)
    assert.equal(transitions[0].patch.credLoadManual, true)
    assert.equal(transitions[0].patch.authSuspended, false)
    assert.equal(transitions[0].patch.autoRefreshHoldUntilMs, 0)
    mock.finishCredentials({ stdout: claudeCreds("tok-a"), stderr: "", exitCode: 0 })
    assert.equal(transitions[1].patch.authFailCount, 0)
    assert.equal(transitions[1].patch.authSuspended, false)
    assert.equal(transitions[1].patch.lastFailedToken, "")
    assert.equal(transitions[1].patch.credLoadManual, false)
    assert.equal(mock.httpCallbacks.length, 1)
    mock.finishHttp(0, { status: 200, responseText: CLAUDE_BODY })
    assert.equal(transitions[2].type, "success")
}

// ── 429 backoff multiplier + ceiling ────────────────────────────────
// Preserve stored backoffMultiplier across credential read by matching
// lastFailedToken to the live token (same as controller: clearAuth only
// when manual or token rotated away from lastFailedToken).
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { backoffMultiplier: 1, lastFailedToken: "claude-token" }
    }), mock)
    mock.finishCredentials({ stdout: claudeCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 429, responseText: "slow" })
    assert.equal(transitions[2].type, "rate_limited")
    assert.equal(transitions[2].patch.error, "Rate limited")
    assert.equal(transitions[2].patch.backoffMultiplier, 2)
    assert.equal(transitions[2].patch.autoRefreshHoldUntilMs, NOW + 300000 * 2)
    assert.equal(transitions[2].patch.lastFetchMs, NOW)
}
{
    // ceiling: base 300000, max 3600000 → maxMult = 12; start at mult 12 → *2 = 24 capped to 12
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { backoffMultiplier: 12, lastFailedToken: "claude-token" }
    }), mock)
    mock.finishCredentials({ stdout: claudeCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 429, responseText: "" })
    assert.equal(transitions[2].type, "rate_limited")
    assert.equal(transitions[2].patch.backoffMultiplier, 12)
    assert.equal(transitions[2].patch.autoRefreshHoldUntilMs, NOW + 3600000)
}

// ── Timeout vs network (status 0) ───────────────────────────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: claudeCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 0, responseText: "", fromTimeout: true })
    assert.equal(transitions[2].type, "transport_error")
    assert.equal(transitions[2].patch.error, "API error (timeout)")
    assert.equal(transitions[2].error.fromTimeout, true)
}
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: claudeCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 0, responseText: "", fromTimeout: false })
    assert.equal(transitions[2].type, "transport_error")
    assert.equal(transitions[2].patch.error, "API error (network error)")
    assert.equal(transitions[2].error.fromTimeout, false)
}
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: claudeCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 500, responseText: "err" })
    assert.equal(transitions[2].type, "transport_error")
    assert.equal(transitions[2].patch.error, "API error (500)")
}

// ── Malformed standard response → parse_error ───────────────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: claudeCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 200, responseText: "{bad" })
    assert.equal(transitions[2].type, "parse_error")
    assert.equal(transitions[2].patch.error, "Parse error")
    assert.equal(transitions[2].patch.loading, false)
    assert.equal(transitions[2].patch.lastFetchMs, NOW)
    assert.equal(mock.exchanges.length, 1)
}

// ── Duplicate HTTP callback: settle/cache once, one terminal ────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: claudeCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 200, responseText: CLAUDE_BODY })
    // re-invoke the same callback (duplicate onreadystatechange/ontimeout)
    mock.httpCallbacks[0].callback({
        key: mock.httpCallbacks[0].request.key,
        profileId: "claude-1",
        generation: 7,
        provider: "claude",
        opencodeSlot: "",
        endpoint: mock.httpCallbacks[0].request.endpoint,
        url: mock.httpCallbacks[0].request.url,
        status: 500,
        responseText: "dup",
        fromTimeout: false
    })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[2].type, "success")
    assert.equal(mock.exchanges.length, 1)
}

// ── Cache once per exchange (Grok: two legs) ────────────────────────
function grokWindowIds(usageResult) {
    return (usageResult.windows || []).map(w => w.id)
}
{
    const mock = mockRefreshPorts({ now: NOW })
    const input = baseInput({
        profile: { id: "grok-1", provider: "grok" }
    })
    const { transitions } = runCapture(input, mock)
    mock.finishCredentials({ stdout: grokCreds("g-tok"), stderr: "", exitCode: 0 })
    assert.equal(mock.httpCallbacks.length, 2, "both Grok legs always launch")
    // both legs share same token snapshot
    assert.deepEqual(
        mock.httpCallbacks.map(h => h.request.headers.Authorization),
        ["Bearer g-tok", "Bearer g-tok"]
    )
    assert.ok(mock.httpCallbacks.every(h =>
        h.request.profileId === "grok-1" && h.request.generation === 7
    ))
    // credits first, then default
    mock.finishHttp(1, { status: 200, responseText: GROK_CREDITS })
    assert.equal(terminalTypes(transitions).length, 0)
    assert.equal(mock.exchanges.length, 1)
    mock.finishHttp(0, { status: 200, responseText: GROK_DEFAULT })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[transitions.length - 1].type, "success")
    assert.equal(mock.exchanges.length, 2)
    assert.ok(transitions[transitions.length - 1].usageResult.windows.length > 0)
    const creditsFirstIds = grokWindowIds(transitions[transitions.length - 1].usageResult)
    assert.ok(creditsFirstIds.includes("weekly"), "monthly (weekly id) present")
    assert.ok(creditsFirstIds.includes("session"), "session from credits present")
}
{
    // reverse order: default first — same windows, one terminal, two exchanges
    const mock = mockRefreshPorts({ now: NOW })
    const input = baseInput({
        profile: { id: "grok-2", provider: "grok" }
    })
    const { transitions } = runCapture(input, mock)
    mock.finishCredentials({ stdout: grokCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 200, responseText: GROK_DEFAULT })
    mock.finishHttp(1, { status: 200, responseText: GROK_CREDITS })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[transitions.length - 1].type, "success")
    assert.equal(mock.exchanges.length, 2)
    const defaultFirstIds = grokWindowIds(transitions[transitions.length - 1].usageResult)
    assert.ok(defaultFirstIds.includes("weekly"))
    assert.ok(defaultFirstIds.includes("session"))
}

// ── Grok partial success (credits fail → monthly-only) ──────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { id: "grok-p", provider: "grok" }
    }), mock)
    mock.finishCredentials({ stdout: grokCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 200, responseText: GROK_DEFAULT })
    mock.finishHttp(1, { status: 500, responseText: "" })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[transitions.length - 1].type, "success")
    assert.equal(mock.exchanges.length, 2)
    const ids = grokWindowIds(transitions[transitions.length - 1].usageResult)
    assert.ok(ids.includes("weekly"), "monthly-only keeps weekly/$ slot")
    assert.ok(!ids.includes("session"), "credits failure omits session slot")
}

// ── Grok default 429 → rate_limited (both legs still recorded) ──────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { id: "grok-r", provider: "grok" }
    }), mock)
    mock.finishCredentials({ stdout: grokCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 429, responseText: "" })
    mock.finishHttp(1, { status: 429, responseText: "" })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[transitions.length - 1].type, "rate_limited")
    assert.ok(transitions[transitions.length - 1].patch.backoffMultiplier > 1)
    assert.equal(mock.exchanges.length, 2)
}

// ── Grok auth failure without body ──────────────────────────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { id: "grok-a", provider: "grok" }
    }), mock)
    mock.finishCredentials({ stdout: grokCreds("bad"), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 401, responseText: "" })
    mock.finishHttp(1, { status: 401, responseText: "" })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[transitions.length - 1].type, "auth_error")
    assert.equal(transitions[transitions.length - 1].patch.lastFailedToken, "bad")
    assert.equal(mock.exchanges.length, 2)
}

// ── Grok credits-auth fail with monthly body → partial success ──────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { id: "grok-ca", provider: "grok" }
    }), mock)
    mock.finishCredentials({ stdout: grokCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 200, responseText: GROK_DEFAULT })
    mock.finishHttp(1, { status: 401, responseText: "" })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[transitions.length - 1].type, "success")
    const ids = grokWindowIds(transitions[transitions.length - 1].usageResult)
    assert.ok(ids.includes("weekly"))
    assert.ok(!ids.includes("session"))
    assert.equal(mock.exchanges.length, 2)
}

// ── Grok duplicate callback on one leg cannot double-finalize ───────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput({
        profile: { id: "grok-d", provider: "grok" }
    }), mock)
    mock.finishCredentials({ stdout: grokCreds(), stderr: "", exitCode: 0 })
    mock.finishHttp(0, { status: 200, responseText: GROK_DEFAULT })
    // duplicate default leg
    mock.httpCallbacks[0].callback({
        key: "default",
        profileId: "grok-d",
        generation: 7,
        provider: "grok",
        opencodeSlot: "",
        endpoint: "billing",
        url: mock.httpCallbacks[0].request.url,
        status: 500,
        responseText: "",
        fromTimeout: false
    })
    mock.finishHttp(1, { status: 200, responseText: GROK_CREDITS })
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[transitions.length - 1].type, "success")
    // default recorded once + credits once
    assert.equal(mock.exchanges.length, 2)
}

// ── Invalid input rejects ───────────────────────────────────────────
{
    const mock = mockRefreshPorts()
    assert.equal(Refresh.run(null, mock.ports, () => {}), false)
    assert.equal(Refresh.run({}, mock.ports, () => {}), false)
    assert.equal(Refresh.run({ profile: {} }, mock.ports, () => {}), false)
}

// ── Exactly one terminal even if finish attempted twice ─────────────
{
    const mock = mockRefreshPorts({ now: NOW })
    const { transitions } = runCapture(baseInput(), mock)
    mock.finishCredentials({ stdout: "", stderr: "", exitCode: 0 })
    // second empty finish is not possible via ports; ensure only one terminal
    assert.equal(terminalTypes(transitions).length, 1)
    assert.equal(transitions[1].type, "auth_error")
}

console.log("All profile refresh transaction tests passed.")
