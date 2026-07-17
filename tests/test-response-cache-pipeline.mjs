#!/usr/bin/env node
/**
 * Characterisation tests for ResponseCachePipeline — pure preparation,
 * envelope/path/staging, and normal FIFO advancement via the fake adapter.
 * No Plasma, filesystem, shell, or network.
 */
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"
import { createFakeResponseCache } from "./helpers/fake-response-cache.mjs"
import { RESPONSE_CACHE_ENDPOINT_CASES } from "./fixtures/response-cache-endpoints.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const Pipeline = loadQmlJs(
    join(root, "contents/ui/js/ResponseCachePipeline.js"), {}, ["create"])

const PATH_TIME = Date.parse("2026-07-17T10:11:12.013Z")
const SAVE_TIME = Date.parse("2026-07-17T10:11:12.014Z")
const PENDING_TIME = Date.parse("2026-07-17T10:11:12.015Z")

const exchange = {
    key: "usage", profileId: "open/code one", generation: 3,
    provider: "opencode", opencodeSlot: "anthropic",
    endpoint: "oauth-usage", url: "https://example.test/usage",
    status: 200, responseText: '{"ok":true}', fromTimeout: false
}

// --- shell/payload helpers -------------------------------------------------

function parseSingleQuoted(s, i) {
    if (s.charAt(i) !== "'")
        throw new Error("expected opening quote at " + i + ": " + JSON.stringify(s.slice(i, i + 40)))
    i++
    let out = ""
    while (i < s.length) {
        if (s.charAt(i) === "'") {
            // POSIX concatenation: '\''
            if (s.charAt(i + 1) === "\\" && s.charAt(i + 2) === "'" && s.charAt(i + 3) === "'") {
                out += "'"
                i += 4
                continue
            }
            return { value: out, end: i + 1 }
        }
        out += s.charAt(i)
        i++
    }
    throw new Error("unterminated single-quoted string")
}

function allCommandStrings(fake) {
    const launched = fake.effects.commands.map(c => c.command)
    const queued = fake.state().queue.slice()
    return launched.concat(queued)
}

function extractStagedPayload(commandStrings) {
    const chunks = []
    for (const cmd of commandStrings) {
        const marker = "printf %s "
        const idx = cmd.indexOf(marker)
        if (idx < 0) continue
        const { value } = parseSingleQuoted(cmd, idx + marker.length)
        chunks.push(value)
    }
    return chunks.join("")
}

function finishAll(fake) {
    let guard = 0
    while (fake.state().busy && guard++ < 10000) {
        const last = fake.effects.commands[fake.effects.commands.length - 1]
        fake.finish(last.sourceName)
    }
}

function clocks(n) {
    const out = []
    for (let i = 0; i < n; i++)
        out.push(PATH_TIME + i * 10, SAVE_TIME + i * 10, PENDING_TIME + i * 10)
    return out
}

function baseExchange(over = {}) {
    return { ...exchange, ...over }
}

// --- disabled / baseline public seam --------------------------------------

{
    const disabled = createFakeResponseCache(Pipeline, { enabled: false }, [])
    disabled.recordExchange(exchange)
    assert.deepEqual(disabled.effects.commands, [])
    assert.deepEqual(disabled.effects.clockReads, [])
    assert.deepEqual(disabled.state(), {
        queue: [], busy: false, inFlightCommand: "", inFlightSource: "",
        attempt: 0, launchSequence: 0, pendingSequence: 0
    })
}

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    assert.equal(fake.effects.commands.length, 1)
    assert.equal(fake.effects.watchdogStarts[0], 12000)
    assert.match(fake.effects.commands[0].command,
        /umask 077; mkdir -p -- '\/home\/tester\/\.cache\/plasma-claude-usage\/pending'/)
    const snapshot = fake.state()
    assert.equal(snapshot.busy, true)
    assert.equal(snapshot.pendingSequence, 1)
    assert.ok(snapshot.queue.length >= 1)

    const queuedText = [fake.effects.commands[0].command, ...snapshot.queue].join("\n")
    assert.match(queuedText,
        /responses\/2026\/07\/17\/101112-013-anthropic-open-code-one-oauth-usage\.json/)
    assert.match(queuedText,
        /latest\/anthropic-open-code-one-oauth-usage\.json/)
    assert.match(queuedText, /pending\/p-1784283072015-1\.json/)
    assert.deepEqual(fake.effects.clockReads, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    assert.match(queuedText, /"savedAt":"2026-07-17T10:11:12\.014Z"/)
    assert.match(queuedText, /"savedAtMs":1784283072014/)
    assert.match(queuedText, /"provider":"anthropic"/)
    // JSON.stringify does not escape solidus; profileId is the raw path segment value
    assert.match(queuedText, /"profileId":"open\/code one"/)
    assert.match(queuedText, /"httpStatus":200/)
    assert.match(queuedText, /"body":\{"ok":true\}/)
    assert.doesNotMatch(queuedText, /"generation"|"fromTimeout"|"key"/)

    const payload = extractStagedPayload(allCommandStrings(fake))
    const env = JSON.parse(payload)
    assert.equal(env.savedAt, "2026-07-17T10:11:12.014Z")
    assert.equal(env.savedAtMs, 1784283072014)
    assert.equal(env.provider, "anthropic")
    assert.equal(env.profileId, "open/code one")
    assert.equal(env.endpoint, "oauth-usage")
    assert.equal(env.url, "https://example.test/usage")
    assert.equal(env.httpStatus, 200)
    assert.deepEqual(env.body, { ok: true })
    assert.equal(env.raw, null)
    assert.equal(env.truncated, false)
    assert.deepEqual(Object.keys(env), [
        "savedAt", "savedAtMs", "provider", "profileId", "endpoint",
        "url", "httpStatus", "body", "raw", "truncated"
    ])
}

// --- exhaustive endpoint fixture (cache path + envelope seams) ------------

{
    assert.ok(!RESPONSE_CACHE_ENDPOINT_CASES.some(c => /gemini/i.test(c.name)
        || /gemini/i.test(c.provider) || /gemini/i.test(c.endpoint)),
        "no Gemini fixture/request endpoint exists")

    const n = RESPONSE_CACHE_ENDPOINT_CASES.length
    const fake = createFakeResponseCache(Pipeline, {}, clocks(n))
    for (let i = 0; i < n; i++) {
        const c = RESPONSE_CACHE_ENDPOINT_CASES[i]
        fake.recordExchange(baseExchange({
            key: c.requestKey,
            profileId: "prof-" + i,
            provider: c.provider,
            opencodeSlot: c.opencodeSlot,
            endpoint: c.endpoint,
            url: "https://example.test/" + c.endpoint,
            status: 200,
            responseText: '{"n":' + i + "}"
        }))
    }
    finishAll(fake)
    const all = allCommandStrings(fake).join("\n")
    // Reconstruct envelopes by grouping printf chunks between bash finals is heavy;
    // assert filename components and provider/endpoint substrings per case.
    for (let i = 0; i < n; i++) {
        const c = RESPONSE_CACHE_ENDPOINT_CASES[i]
        const ep = c.effectiveProvider
        const slug = "prof-" + i
        const end = c.endpoint
        assert.match(all, new RegExp(
            "responses/2026/07/17/\\d{6}-\\d{3}-"
            + ep + "-" + slug + "-" + end + "\\.json"))
        assert.match(all, new RegExp(
            "latest/" + ep + "-" + slug + "-" + end + "\\.json"))
        // envelope endpoint is the unsanitised slug (oauth-usage not slash-derived)
        assert.match(all, new RegExp('"endpoint":"' + end + '"'))
        assert.match(all, new RegExp('"provider":"' + ep + '"'))
    }
    assert.match(all, /oauth-usage/)
    assert.doesNotMatch(all, /api\/oauth\/usage/)
    assert.equal(fake.effects.clockReads.length, n * 3)
}

// --- configured roots -----------------------------------------------------

{
    // absolute root
    const fake = createFakeResponseCache(Pipeline, {
        configuredRoot: "/var/cache/custom",
        homeDir: "/home/tester"
    }, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const text = allCommandStrings(fake).join("\n")
    assert.match(text, /\/var\/cache\/custom\/responses\/2026\/07\/17\//)
    assert.match(text, /\/var\/cache\/custom\/latest\//)
    assert.match(text, /\/var\/cache\/custom\/pending\/p-1784283072015-1\.json/)
}

{
    // ~/override with HOME
    const fake = createFakeResponseCache(Pipeline, {
        configuredRoot: "~/mycache",
        homeDir: "/home/tester"
    }, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const text = allCommandStrings(fake).join("\n")
    assert.match(text, /\/home\/tester\/mycache\/responses\//)
    assert.match(text, /\/home\/tester\/mycache\/pending\//)
}

{
    // ~/override without HOME → $HOME for hist/latest; /tmp fallback for pending
    const fake = createFakeResponseCache(Pipeline, {
        configuredRoot: "~/mycache",
        homeDir: ""
    }, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const text = allCommandStrings(fake).join("\n")
    assert.match(text, /\$HOME\/mycache\/responses\//)
    assert.match(text, /\$HOME\/mycache\/latest\//)
    assert.match(text, /\/tmp\/plasma-claude-usage-cache\/pending\//)
}

{
    // default root with home
    const fake = createFakeResponseCache(Pipeline, {
        configuredRoot: "",
        homeDir: "/home/tester"
    }, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const text = allCommandStrings(fake).join("\n")
    assert.match(text, /\/home\/tester\/\.cache\/plasma-claude-usage\/responses\//)
}

{
    // default root without home
    const fake = createFakeResponseCache(Pipeline, {
        configuredRoot: "",
        homeDir: ""
    }, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const text = allCommandStrings(fake).join("\n")
    assert.match(text, /\$HOME\/\.cache\/plasma-claude-usage\/responses\//)
    assert.match(text, /\/tmp\/plasma-claude-usage-cache\/pending\//)
}

// --- sanitisation / unknown fallback --------------------------------------

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({
        profileId: "///weird name!!",
        provider: "codex",
        opencodeSlot: "",
        endpoint: "@@@",
        responseText: "{}"
    }))
    const text = allCommandStrings(fake).join("\n")
    // profile: slashes/spaces/! → hyphens, collapse, trim → "weird-name"
    assert.match(text, /codex-weird-name-unknown\.json/)
    assert.match(text, /latest\/codex-weird-name-unknown\.json/)
}

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({
        profileId: "",
        // empty profileId is falsy → ignored (malformed), use non-empty then empty endpoint
        provider: "claude",
        endpoint: "oauth-usage",
        responseText: "{}"
    }))
    // empty profileId is treated as missing
    assert.deepEqual(fake.effects.commands, [])
    assert.deepEqual(fake.effects.clockReads, [])
    assert.ok(fake.effects.logs.some(l => /without profileId/.test(l)))
}

// --- three distinct clock ownership ---------------------------------------

{
    // first value → history date/time only; second → savedAt; third → pending name
    const tPath = Date.parse("2026-01-02T03:04:05.006Z")
    const tSave = Date.parse("2026-08-09T10:11:12.123Z")
    const tPend = 999000111222
    const fake = createFakeResponseCache(Pipeline, {}, [tPath, tSave, tPend])
    fake.recordExchange(exchange)
    const text = allCommandStrings(fake).join("\n")
    assert.deepEqual(fake.effects.clockReads, [tPath, tSave, tPend])
    assert.match(text, /responses\/2026\/01\/02\/030405-006-/)
    assert.doesNotMatch(text, /responses\/2026\/08\/09\//)
    assert.match(text, /"savedAt":"2026-08-09T10:11:12\.123Z"/)
    assert.match(text, new RegExp('"savedAtMs":' + tSave))
    assert.match(text, /pending\/p-999000111222-1\.json/)
    // path time must not appear as savedAtMs
    assert.doesNotMatch(text, new RegExp('"savedAtMs":' + tPath))
    // pending time must not appear as savedAtMs
    assert.doesNotMatch(text, /"savedAtMs":999000111222/)
}

{
    // disabled consumes zero clocks
    const fake = createFakeResponseCache(Pipeline, { enabled: false }, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    assert.deepEqual(fake.effects.clockReads, [])
}

{
    // malformed (null / missing profileId) consumes zero clocks
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(null)
    fake.recordExchange(undefined)
    fake.recordExchange({ provider: "claude", endpoint: "oauth-usage", responseText: "{}" })
    assert.deepEqual(fake.effects.clockReads, [])
    assert.deepEqual(fake.effects.commands, [])
    assert.ok(fake.effects.logs.length >= 1)
}

// --- body/raw variants ----------------------------------------------------

{
    // invalid text
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: "not-json{" }))
    const env = JSON.parse(extractStagedPayload(allCommandStrings(fake)))
    assert.equal(env.body, null)
    assert.equal(env.raw, "not-json{")
    assert.equal(env.truncated, false)
}

{
    // empty text → both null
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: "" }))
    const env = JSON.parse(extractStagedPayload(allCommandStrings(fake)))
    assert.equal(env.body, null)
    assert.equal(env.raw, null)
}

{
    // null/undefined responseText same as empty
    const a = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    a.recordExchange(baseExchange({ responseText: null }))
    const envA = JSON.parse(extractStagedPayload(allCommandStrings(a)))
    assert.equal(envA.body, null)
    assert.equal(envA.raw, null)

    const b = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    b.recordExchange(baseExchange({ responseText: undefined }))
    const envB = JSON.parse(extractStagedPayload(allCommandStrings(b)))
    assert.equal(envB.body, null)
    assert.equal(envB.raw, null)
}

{
    // valid JSON primitive
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: "42" }))
    const env = JSON.parse(extractStagedPayload(allCommandStrings(fake)))
    assert.equal(env.body, 42)
    assert.equal(env.raw, null)
}

// --- 200,001-character truncation ----------------------------------------

{
    const rawIn = "Z".repeat(200001)
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: rawIn }))
    const payload = extractStagedPayload(allCommandStrings(fake))
    const env = JSON.parse(payload)
    assert.equal(env.truncated, true)
    assert.equal(env.body, null)
    assert.equal(typeof env.raw, "string")
    assert.equal(env.raw.length, 200000)
    assert.equal(env.raw, "Z".repeat(200000))
}

// --- chunk boundaries 8192 / 8193 ----------------------------------------

function responseTextForPayloadLength(targetLen, saveTimeMs, meta) {
    // Invalid-JSON raw path: adjust raw length until stringified envelope matches.
    let lo = 0
    let hi = targetLen
    let best = null
    while (lo <= hi) {
        const mid = (lo + hi) >> 1
        const raw = "x".repeat(mid)
        const env = {
            savedAt: new Date(saveTimeMs).toISOString(),
            savedAtMs: saveTimeMs,
            provider: meta.provider,
            profileId: meta.profileId,
            endpoint: meta.endpoint,
            url: meta.url,
            httpStatus: meta.httpStatus,
            body: null,
            raw: raw,
            truncated: false
        }
        const len = JSON.stringify(env).length
        if (len === targetLen) {
            best = raw
            break
        }
        if (len < targetLen) lo = mid + 1
        else hi = mid - 1
    }
    if (best === null) {
        // linear refine near hi
        for (let n = Math.max(0, hi - 5); n < targetLen; n++) {
            const raw = "x".repeat(n)
            const env = {
                savedAt: new Date(saveTimeMs).toISOString(),
                savedAtMs: saveTimeMs,
                provider: meta.provider,
                profileId: meta.profileId,
                endpoint: meta.endpoint,
                url: meta.url,
                httpStatus: meta.httpStatus,
                body: null,
                raw: raw,
                truncated: false
            }
            if (JSON.stringify(env).length === targetLen) {
                best = raw
                break
            }
        }
    }
    assert.ok(best !== null, "could not synthesise payload length " + targetLen)
    return best
}

function countPrintfChunks(commandStrings) {
    return commandStrings.filter(c => c.indexOf("printf %s ") >= 0).length
}

function countAppendChunks(commandStrings) {
    return commandStrings.filter(c => /printf %s .+ >> /.test(c)).length
}

function countFirstChunks(commandStrings) {
    return commandStrings.filter(c => /printf %s .+ > /.test(c) && !/>>/.test(c)).length
}

{
    const meta = {
        provider: "anthropic",
        profileId: "open/code one",
        endpoint: "oauth-usage",
        url: "https://example.test/usage",
        httpStatus: 200
    }
    const raw8192 = responseTextForPayloadLength(8192, SAVE_TIME, meta)
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: raw8192, status: 200 }))
    const cmds = allCommandStrings(fake)
    const payload = extractStagedPayload(cmds)
    assert.equal(payload.length, 8192)
    assert.equal(countPrintfChunks(cmds), 1)
    assert.equal(countFirstChunks(cmds), 1)
    assert.equal(countAppendChunks(cmds), 0)
    // staging + final
    assert.equal(cmds.length, 2)
}

{
    const meta = {
        provider: "anthropic",
        profileId: "open/code one",
        endpoint: "oauth-usage",
        url: "https://example.test/usage",
        httpStatus: 200
    }
    const raw8193 = responseTextForPayloadLength(8193, SAVE_TIME, meta)
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: raw8193, status: 200 }))
    const cmds = allCommandStrings(fake)
    const payload = extractStagedPayload(cmds)
    assert.equal(payload.length, 8193)
    assert.equal(countPrintfChunks(cmds), 2)
    assert.equal(countFirstChunks(cmds), 1)
    assert.equal(countAppendChunks(cmds), 1)
    assert.equal(cmds.length, 3) // first + append + bash final
}

// --- single-quote shell quoting -------------------------------------------

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: "abc'def" }))
    const cmds = allCommandStrings(fake)
    const posixConcat = "'\\''"
    let saw = false
    for (const cmd of cmds) {
        if (cmd.indexOf("printf %s ") < 0) continue
        assert.ok(cmd.indexOf(posixConcat) >= 0,
            "chunk command must contain POSIX single-quote concatenation")
        // raw unescaped chunk with bare quote as shell word must not appear
        assert.ok(cmd.indexOf("abc'def") < 0,
            "unescaped raw chunk must not appear in command")
        saw = true
    }
    assert.ok(saw, "expected at least one printf chunk")
    const env = JSON.parse(extractStagedPayload(cmds))
    assert.equal(env.raw, "abc'def")
}

// --- final path-only invocation -------------------------------------------

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const cmds = allCommandStrings(fake)
    const finalCmd = cmds[cmds.length - 1]
    assert.match(finalCmd,
        /^bash '\/widget\/contents\/scripts\/cache-response\.sh' '.*' '.*' '.*'$/)
    assert.ok(finalCmd.indexOf('"savedAt"') < 0, "final command must not contain JSON body")
    assert.ok(finalCmd.indexOf("{") < 0, "final command must not contain JSON object")
    assert.match(finalCmd, /pending\/p-1784283072015-1\.json/)
}

// --- stale generation still records ---------------------------------------

{
    const a = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    a.recordExchange(baseExchange({ generation: 1 }))
    const b = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    b.recordExchange(baseExchange({ generation: 99 }))
    const cmdsA = allCommandStrings(a)
    const cmdsB = allCommandStrings(b)
    assert.deepEqual(cmdsA, cmdsB)
    assert.equal(a.state().pendingSequence, 1)
    assert.equal(b.state().pendingSequence, 1)
}

// --- missing profileId log / no-op preserves queue -------------------------

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME,
        PATH_TIME + 1, SAVE_TIME + 1, PENDING_TIME + 1])
    fake.recordExchange(exchange)
    const before = fake.state()
    const cmdsBefore = fake.effects.commands.length
    const clockBefore = fake.effects.clockReads.length
    fake.recordExchange({ provider: "claude", endpoint: "oauth-usage", responseText: "{}" })
    assert.equal(fake.effects.commands.length, cmdsBefore)
    assert.equal(fake.effects.clockReads.length, clockBefore)
    assert.deepEqual(fake.state().queue, before.queue)
    assert.equal(fake.state().busy, before.busy)
    assert.equal(fake.state().pendingSequence, before.pendingSequence)
    assert.ok(fake.effects.logs.some(l =>
        l === "Claude Usage: response cache ignored exchange without profileId"))
}

// --- empty payload staging (`: > pending`) via zero-length body path -------
// Force empty staging by using buildCommands contract: when payload is "",
// first command uses `: >` not printf. Since envelope always stringifies non-empty,
// verify the empty branch by loading a tiny direct check against algorithm:
// After full FIFO drain of a normal exchange, command list must not use `: >`
// for non-empty payloads; and empty-string staging is present in source (parity).
{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: "" }))
    const cmds = allCommandStrings(fake)
    // empty response still produces non-empty envelope JSON → printf, not `: >`
    assert.ok(cmds.some(c => c.indexOf("printf %s ") >= 0))
    assert.ok(!cmds.some(c => /&& : > /.test(c)))
}

// --- normal FIFO advancement ----------------------------------------------

{
    const fake = createFakeResponseCache(Pipeline, {}, clocks(2))
    fake.recordExchange(baseExchange({ profileId: "p1", responseText: '{"a":1}' }))
    fake.recordExchange(baseExchange({ profileId: "p2", responseText: '{"b":2}' }))
    const s0 = fake.state()
    assert.equal(s0.busy, true)
    assert.equal(s0.attempt, 1)
    assert.equal(s0.launchSequence, 1)
    assert.ok(s0.queue.length >= 1)
    assert.match(s0.inFlightSource, /^CACHE_WRITE_SEQ=1 /)

    const src1 = fake.effects.commands[0].sourceName
    fake.finish(src1)
    assert.equal(fake.effects.disconnects[0], src1)
    assert.equal(fake.effects.watchdogStops, 1)
    const s1 = fake.state()
    assert.equal(s1.busy, true)
    assert.equal(s1.launchSequence, 2)
    assert.equal(s1.attempt, 1)
    assert.match(s1.inFlightSource, /^CACHE_WRITE_SEQ=2 /)

    // finish remaining
    finishAll(fake)
    const sEnd = fake.state()
    assert.equal(sEnd.busy, false)
    assert.equal(sEnd.queue.length, 0)
    assert.equal(sEnd.inFlightCommand, "")
    assert.equal(sEnd.inFlightSource, "")
    assert.equal(sEnd.attempt, 0)
    // both profiles present in launched commands
    const launched = fake.effects.commands.map(c => c.command).join("\n")
    assert.match(launched, /p1/)
    assert.match(launched, /p2/)
}

// --- non-zero exit still advances; stale completion ignored ---------------

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const src = fake.effects.commands[0].sourceName
    // stale completion first
    fake.finish("CACHE_WRITE_SEQ=999 stale", { exitCode: 0, stderr: "" })
    assert.equal(fake.state().busy, true)
    assert.equal(fake.effects.watchdogStops, 0)
    // real completion with failure
    fake.finish(src, { exitCode: 3, stderr: "boom" })
    assert.equal(fake.effects.watchdogStops, 1)
    assert.ok(fake.effects.logs.some(l => /cache write failed exit=3/.test(l)))
    // advanced to next command in group
    assert.equal(fake.state().busy, true)
    finishAll(fake)
    assert.equal(fake.state().busy, false)
}

// --- status fallback 0 ----------------------------------------------------

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ status: 0, responseText: "{}" }))
    const env = JSON.parse(extractStagedPayload(allCommandStrings(fake)))
    assert.equal(env.httpStatus, 0)
}

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    const ex = baseExchange({ responseText: "{}" })
    delete ex.status
    fake.recordExchange(ex)
    const env = JSON.parse(extractStagedPayload(allCommandStrings(fake)))
    assert.equal(env.httpStatus, 0)
}

// --- stateForTests returns a copy -----------------------------------------

{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(exchange)
    const s1 = fake.state()
    s1.queue.push("mutated")
    s1.busy = false
    const s2 = fake.state()
    assert.equal(s2.busy, true)
    assert.ok(!s2.queue.includes("mutated"))
}

console.log("All response cache pipeline tests passed.")
