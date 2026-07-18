#!/usr/bin/env node
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const Requests = loadQmlJs(
    join(root, "contents/ui/js/TestCelebrationRequests.js"), {},
    [
        "MAX_AGE_MS",
        "MAX_FUTURE_SKEW_MS",
        "createRequest",
        "serializeRequest",
        "consume",
        "eligibleProfileIds",
        "selectProfileId"
    ])

const NOW = Date.parse("2026-07-18T06:00:00.000Z")

// Creation uses the exact versioned schema and injected nonce source.
{
    let nonceCalls = 0
    const request = Requests.createRequest(NOW, () => {
        nonceCalls += 1
        return "nonce-1"
    })
    assert.deepEqual(request, {
        version: 1,
        type: "test-celebration",
        createdAtMs: NOW,
        nonce: "nonce-1"
    })
    assert.equal(nonceCalls, 1)
    assert.equal(
        Requests.serializeRequest(request),
        `{"version":1,"type":"test-celebration","createdAtMs":${NOW},"nonce":"nonce-1"}`
    )
    assert.deepEqual(request, {
        version: 1,
        type: "test-celebration",
        createdAtMs: NOW,
        nonce: "nonce-1"
    }, "serialisation does not mutate its input")
}

function validRequest(overrides = {}) {
    return {
        version: 1,
        type: "test-celebration",
        createdAtMs: NOW,
        nonce: "nonce-valid",
        ...overrides
    }
}

function consumeRequest(request, state = {}, nowMs = NOW) {
    return Requests.consume(JSON.stringify(request), state, nowMs)
}

// Validation emits explicit reasons.
{
    assert.equal(Requests.consume("", {}, NOW).reason, "empty")
    assert.equal(Requests.consume("   ", {}, NOW).reason, "empty")
    assert.equal(Requests.consume("{not-json", {}, NOW).reason, "malformed")
    assert.equal(consumeRequest(validRequest({ version: 2 })).reason, "schema")
    assert.equal(consumeRequest(validRequest({ type: "other" })).reason, "schema")
    assert.equal(Requests.consume("null", {}, NOW).reason, "schema")
    assert.equal(consumeRequest(validRequest({ nonce: undefined })).reason, "nonce")
    assert.equal(consumeRequest(validRequest({ nonce: "" })).reason, "nonce")
    assert.equal(consumeRequest(validRequest({ nonce: "n".repeat(128) })).accepted, true)
    assert.equal(consumeRequest(validRequest({ nonce: "n".repeat(129) })).reason, "nonce")
    assert.equal(consumeRequest(validRequest({ createdAtMs: "123" })).reason, "timestamp")
    assert.equal(
        Requests.consume(
            '{"version":1,"type":"test-celebration","createdAtMs":1e400,"nonce":"nonce-non-finite"}',
            {},
            NOW
        ).reason,
        "timestamp"
    )
    assert.equal(consumeRequest(validRequest({ createdAtMs: null })).reason, "timestamp")
    assert.equal(consumeRequest(validRequest({ createdAtMs: undefined })).reason, "timestamp")
}

// Freshness and future-skew boundaries are inclusive.
{
    assert.equal(Requests.MAX_AGE_MS, 15000)
    assert.equal(Requests.MAX_FUTURE_SKEW_MS, 2000)
    assert.equal(consumeRequest(validRequest({ createdAtMs: NOW - 15000 })).accepted, true)
    assert.equal(consumeRequest(validRequest({ createdAtMs: NOW - 15001 })).reason, "stale")
    assert.equal(consumeRequest(validRequest({ createdAtMs: NOW + 2000 })).accepted, true)
    assert.equal(consumeRequest(validRequest({ createdAtMs: NOW + 2001 })).reason, "future")
}

// Consumption accepts once, rejects replay, prunes copied replay state, and leaves inputs intact.
{
    const replayRetentionMs = Requests.MAX_AGE_MS + Requests.MAX_FUTURE_SKEW_MS
    const first = Requests.createRequest(NOW, () => "nonce-1")
    const initialState = {
        recent: NOW - replayRetentionMs,
        stale: NOW - replayRetentionMs - 1,
        invalid: "not-a-timestamp"
    }
    const initialSnapshot = { ...initialState }
    const accepted = Requests.consume(JSON.stringify(first), initialState, NOW)
    assert.equal(accepted.accepted, true)
    assert.deepEqual(accepted.request, first)
    assert.notEqual(accepted.state, initialState)
    assert.deepEqual({ ...accepted.state }, { recent: NOW - replayRetentionMs, "nonce-1": NOW })
    assert.deepEqual(initialState, initialSnapshot, "consume does not mutate replay state")

    const replayState = { "nonce-1": NOW, stale: NOW - replayRetentionMs - 1 }
    const replaySnapshot = { ...replayState }
    const replay = Requests.consume(JSON.stringify(first), replayState, NOW)
    assert.equal(replay.accepted, false)
    assert.equal(replay.reason, "replay")
    assert.equal(replay.request, null)
    assert.deepEqual({ ...replay.state }, { "nonce-1": NOW })
    assert.deepEqual(replayState, replaySnapshot)

    assert.deepEqual(
        { ...Requests.consume("bad-json", { stale: NOW - replayRetentionMs - 1, recent: NOW }, NOW).state },
        { recent: NOW },
        "state is pruned even when the payload is rejected"
    )
}

// A request accepted at maximum future skew remains replay-protected through its full freshness window.
{
    const futureRequest = validRequest({
        createdAtMs: NOW + Requests.MAX_FUTURE_SKEW_MS,
        nonce: "future-boundary"
    })
    const accepted = consumeRequest(futureRequest, {}, NOW)
    assert.equal(accepted.accepted, true)

    const lastFreshNow = NOW + Requests.MAX_AGE_MS + Requests.MAX_FUTURE_SKEW_MS
    const replay = consumeRequest(futureRequest, accepted.state, lastFreshNow)
    assert.equal(replay.reason, "replay")

    const stale = consumeRequest(futureRequest, replay.state, lastFreshNow + 1)
    assert.equal(stale.reason, "stale")
}

// Replay state treats nonce strings as data even when they name Object prototype properties.
{
    for (const nonce of ["__proto__", "constructor"]) {
        const request = validRequest({ nonce })
        const accepted = consumeRequest(request)
        assert.equal(accepted.accepted, true)
        assert.equal(Object.prototype.hasOwnProperty.call(accepted.state, nonce), true)
        assert.equal(accepted.state[nonce], NOW)
        assert.equal(consumeRequest(request, accepted.state).reason, "replay")
    }
}

const profiles = Array.from({ length: 15 }, (_, index) => ({
    id: `profile-${index}`,
    enabled: true,
    marker: index
}))
profiles[2].enabled = false
profiles[5].id = ""
const profileSnapshot = JSON.parse(JSON.stringify(profiles))
const limits = { compactMaxCards: 8, fullMaxCards: 12 }
const limitsSnapshot = { ...limits }

// Eligibility filters first, then applies the union card limit.
{
    const expected = profiles
        .filter(profile => profile.enabled !== false && profile.id)
        .slice(0, 12)
        .map(profile => profile.id)
    assert.deepEqual(Requests.eligibleProfileIds(profiles, limits), expected)
    assert.ok(expected.includes("profile-13"), "disabled/id-less earlier rows do not consume card slots")
    assert.ok(!expected.includes("profile-14"), "the thirteenth enabled/id-bearing row is overflow-only")
    assert.deepEqual(Requests.eligibleProfileIds([], limits), [])
    assert.deepEqual(Requests.eligibleProfileIds([{ id: "off", enabled: false }], limits), [])
    assert.deepEqual(
        Requests.eligibleProfileIds([
            { id: "disabled-first", enabled: false },
            ...Array.from({ length: 13 }, (_, index) => ({ id: `enabled-${index}`, enabled: true }))
        ], { compactMaxCards: 8, fullMaxCards: 12 }),
        Array.from({ length: 12 }, (_, index) => `enabled-${index}`),
        "disabled rows before the limit do not exclude later enabled rows"
    )
    assert.deepEqual(profiles, profileSnapshot, "eligibility does not mutate profiles")
    assert.deepEqual(limits, limitsSnapshot, "eligibility does not mutate limits")
}

// Selection is deterministic with injected randomness and clamps every required edge.
{
    const selectable = [{ id: "a" }, { id: "b" }, { id: "c" }]
    const selectionLimits = { compactMaxCards: 3, fullMaxCards: 2 }
    assert.equal(Requests.selectProfileId(selectable, selectionLimits, () => 0), "a")
    assert.equal(Requests.selectProfileId(selectable, selectionLimits, () => 0.999), "c")
    assert.equal(Requests.selectProfileId(selectable, selectionLimits, () => -0.5), "a")
    assert.equal(Requests.selectProfileId(selectable, selectionLimits, () => 1), "c")
    assert.equal(Requests.selectProfileId(selectable, selectionLimits, () => 99), "c")
    assert.equal(Requests.selectProfileId(selectable, selectionLimits, () => Number.NaN), "a")
    assert.equal(Requests.selectProfileId([], selectionLimits, () => 0.5), "")
    assert.deepEqual(selectable, [{ id: "a" }, { id: "b" }, { id: "c" }])
}

console.log("All test-celebration request tests passed.")
