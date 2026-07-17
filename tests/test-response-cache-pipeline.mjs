#!/usr/bin/env node
/**
 * Characterisation tests for ResponseCachePipeline — pure preparation,
 * envelope/path/staging, FIFO advancement, serial watchdog retry/drop, and
 * queue recovery via the fake adapter. No Plasma, filesystem, shell, or network.
 */
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"
import { createFakeResponseCache } from "./helpers/fake-response-cache.mjs"
import { RESPONSE_CACHE_ENDPOINT_CASES } from "./fixtures/response-cache-endpoints.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const Pipeline = loadQmlJs(
    join(root, "contents/ui/js/ResponseCachePipeline.js"), {},
    ["create", "buildCommands"])

const PATH_TIME = Date.parse("2026-07-17T10:11:12.013Z")
const SAVE_TIME = Date.parse("2026-07-17T10:11:12.014Z")
const PENDING_TIME = Date.parse("2026-07-17T10:11:12.015Z")

// History paths use local wall-clock fields (Date#getHours etc.), not UTC.
// Derive expected path components from the same epoch so TZ=UTC is not required.
function pad2(n) {
    n = Math.floor(Number(n) || 0)
    return n < 10 ? "0" + n : String(n)
}
function pad3(n) {
    n = Math.floor(Number(n) || 0) % 1000
    if (n < 10) return "00" + n
    if (n < 100) return "0" + n
    return String(n)
}
function localHistoryStamp(ms) {
    const d = new Date(ms)
    const y = d.getFullYear()
    const mo = pad2(d.getMonth() + 1)
    const day = pad2(d.getDate())
    const hms = pad2(d.getHours()) + pad2(d.getMinutes()) + pad2(d.getSeconds())
    const ms3 = pad3(d.getMilliseconds())
    return { y, mo, day, hms, ms3, dir: y + "/" + mo + "/" + day, stamp: hms + "-" + ms3 }
}
const PATH_STAMP = localHistoryStamp(PATH_TIME)

const exchange = {
    key: "usage", profileId: "open/code one", generation: 3,
    provider: "opencode", opencodeSlot: "anthropic",
    endpoint: "oauth-usage", url: "https://example.test/usage",
    status: 200, responseText: '{"ok":true}', fromTimeout: false
}

// --- caller interface: recordExchange only on public fake seam -----------
{
    const fake = createFakeResponseCache(Pipeline, {}, [])
    assert.equal(typeof fake.recordExchange, "function")
    assert.equal(fake.recordExchange.length, 1)
    // fake exposes test controls; production caller only uses recordExchange
    assert.deepEqual(
        Object.keys(fake).filter(k => typeof fake[k] === "function").sort(),
        ["finish", "fireWatchdog", "recordExchange", "state"].sort()
    )
    // pure pipeline factory returns recordExchange as the only caller method
    // plus internal completion/watchdog/test controls
    const bare = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    bare.recordExchange(exchange)
    assert.equal(bare.effects.commands.length, 1)
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
    assert.match(queuedText, new RegExp(
        "responses/" + PATH_STAMP.dir + "/" + PATH_STAMP.stamp
        + "-anthropic-open-code-one-oauth-usage\\.json"))
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
        const stamp = localHistoryStamp(PATH_TIME + i * 10)
        assert.match(all, new RegExp(
            "responses/" + stamp.dir + "/" + stamp.stamp + "-"
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
    // Use far-apart local calendar days so path components cannot leak into envelope.
    const tPath = Date.parse("2026-01-02T03:04:05.006Z")
    const tSave = Date.parse("2026-08-09T10:11:12.123Z")
    const tPend = 999000111222
    const pathStamp = localHistoryStamp(tPath)
    const saveStamp = localHistoryStamp(tSave)
    const fake = createFakeResponseCache(Pipeline, {}, [tPath, tSave, tPend])
    fake.recordExchange(exchange)
    const text = allCommandStrings(fake).join("\n")
    assert.deepEqual(fake.effects.clockReads, [tPath, tSave, tPend])
    assert.match(text, new RegExp(
        "responses/" + pathStamp.dir + "/" + pathStamp.stamp + "-"))
    // path clock owns history date; save clock must not rewrite the path directory
    if (pathStamp.dir !== saveStamp.dir)
        assert.doesNotMatch(text, new RegExp("responses/" + saveStamp.dir + "/"))
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
// Envelope stringify is always non-empty through recordExchange; exercise the
// empty branch of buildCommands directly, and prove recordExchange never uses it.
{
    const fake = createFakeResponseCache(Pipeline, {}, [PATH_TIME, SAVE_TIME, PENDING_TIME])
    fake.recordExchange(baseExchange({ responseText: "" }))
    const cmds = allCommandStrings(fake)
    // empty response still produces non-empty envelope JSON → printf, not `: >`
    assert.ok(cmds.some(c => c.indexOf("printf %s ") >= 0))
    assert.ok(!cmds.some(c => /&& : > /.test(c)))

    const settings = {
        cacheScript: "/widget/contents/scripts/cache-response.sh",
        payloadChunkSize: 8192
    }
    const paths = {
        hist: "/home/tester/.cache/plasma-claude-usage/responses/2026/07/17/x.json",
        latest: "/home/tester/.cache/plasma-claude-usage/latest/x.json"
    }
    const pending = "/home/tester/.cache/plasma-claude-usage/pending/p-1-1.json"
    const emptyCmds = Pipeline.buildCommands(settings, paths, pending, "")
    assert.equal(emptyCmds.length, 2)
    assert.match(emptyCmds[0],
        /umask 077; mkdir -p -- '\/home\/tester\/\.cache\/plasma-claude-usage\/pending' && : > '\/home\/tester\/\.cache\/plasma-claude-usage\/pending\/p-1-1\.json'/)
    assert.doesNotMatch(emptyCmds[0], /printf %s/)
    assert.match(emptyCmds[1],
        /^bash '\/widget\/contents\/scripts\/cache-response\.sh' '.*' '.*' '.*'$/)
    assert.ok(emptyCmds[1].indexOf("{") < 0, "final argv remains path-only for empty payload")
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

// --- Task 2: serial watchdog, late-completion rejection, queue recovery ----

{
    // idle watchdog is a no-op
    const idle = createFakeResponseCache(Pipeline, {}, [])
    idle.fireWatchdog()
    assert.deepEqual(idle.effects.commands, [])
    assert.deepEqual(idle.effects.disconnects, [])
    assert.deepEqual(idle.effects.logs, [])
    assert.equal(idle.effects.watchdogStops, 0)
    assert.deepEqual(idle.state(), {
        queue: [], busy: false, inFlightCommand: "", inFlightSource: "",
        attempt: 0, launchSequence: 0, pendingSequence: 0
    })
}

{
    // core: one retry, late first-source rejection, second-stall drop, advance
    const stalled = createFakeResponseCache(Pipeline, {}, [
        PATH_TIME, SAVE_TIME, PENDING_TIME,
        PATH_TIME + 1000, SAVE_TIME + 1000, PENDING_TIME + 1000
    ])
    stalled.recordExchange({ ...exchange, profileId: "first" })
    stalled.recordExchange({ ...exchange, profileId: "second" })
    const firstSource = stalled.effects.commands[0].sourceName
    const firstCommand = stalled.effects.commands[0].command
    assert.equal(stalled.effects.commands.length, 1)
    assert.equal(stalled.state().attempt, 1)
    assert.equal(stalled.effects.watchdogStarts[0], 12000)

    stalled.fireWatchdog()
    assert.equal(stalled.effects.disconnects.at(-1), firstSource)
    assert.equal(stalled.effects.commands.length, 2)
    assert.equal(stalled.effects.commands[1].command, firstCommand)
    assert.notEqual(stalled.effects.commands[1].sourceName, firstSource)
    assert.equal(stalled.state().attempt, 2)
    // each retried launch restarts at exactly 12,000 ms
    assert.equal(stalled.effects.watchdogStarts[1], 12000)
    assert.equal(stalled.effects.watchdogStarts.length, 2)
    assert.match(stalled.effects.logs.join("\n"),
        /cache write stalled \(onNewData never fired\), attempt=1 seq=1/)

    // late completion of the original stalled launch cannot double-drain
    const stateAfterRetry = stalled.state()
    const cmdsAfterRetry = stalled.effects.commands.length
    const stopsAfterRetry = stalled.effects.watchdogStops
    stalled.finish(firstSource)
    assert.equal(stalled.effects.commands.length, cmdsAfterRetry)
    assert.equal(stalled.state().attempt, 2)
    assert.equal(stalled.state().busy, true)
    assert.equal(stalled.state().inFlightSource, stateAfterRetry.inFlightSource)
    assert.equal(stalled.state().inFlightCommand, stateAfterRetry.inFlightCommand)
    assert.deepEqual(stalled.state().queue, stateAfterRetry.queue)
    assert.equal(stalled.effects.watchdogStops, stopsAfterRetry)
    assert.equal(stalled.effects.disconnects.at(-1), firstSource)

    stalled.fireWatchdog()
    assert.equal(stalled.state().attempt, 1)
    assert.match(stalled.effects.logs.join("\n"), /dropped after stall, attempts=2/)
    assert.notEqual(stalled.effects.commands.at(-1).command, firstCommand)
    // two launches maximum for the stalled command (original + one retry)
    const launchesOfFirst = stalled.effects.commands
        .filter(c => c.command === firstCommand).length
    assert.equal(launchesOfFirst, 2)
    // second-stall drop restarts watchdog for the next dequeued command
    assert.equal(stalled.effects.watchdogStarts.at(-1), 12000)
    assert.ok(stalled.effects.watchdogStarts.length >= 3)
}

{
    // after second-stall drop, every later queued command can complete → idle/empty
    const rec = createFakeResponseCache(Pipeline, {}, [
        PATH_TIME, SAVE_TIME, PENDING_TIME,
        PATH_TIME + 1000, SAVE_TIME + 1000, PENDING_TIME + 1000
    ])
    rec.recordExchange({ ...exchange, profileId: "first" })
    rec.recordExchange({ ...exchange, profileId: "second" })
    const firstCommand = rec.effects.commands[0].command
    rec.fireWatchdog() // retry
    rec.fireWatchdog() // drop first command, drain next
    assert.equal(rec.state().busy, true)
    assert.notEqual(rec.state().inFlightCommand, firstCommand)

    finishAll(rec)
    const end = rec.state()
    assert.equal(end.busy, false)
    assert.equal(end.queue.length, 0)
    assert.equal(end.inFlightCommand, "")
    assert.equal(end.inFlightSource, "")
    assert.equal(end.attempt, 0)
    // second exchange group still ran (no queue-length cap/drop of later work)
    const launched = rec.effects.commands.map(c => c.command).join("\n")
    assert.match(launched, /first/)
    assert.match(launched, /second/)
    assert.ok(!rec.effects.logs.some(l => /queue.*(cap|overflow|full|drop.*length)/i.test(l)))
}

{
    // normal completion stops watchdog once and advances exactly one command
    const fake = createFakeResponseCache(Pipeline, {}, clocks(2))
    fake.recordExchange(baseExchange({ profileId: "a", responseText: '{"n":1}' }))
    fake.recordExchange(baseExchange({ profileId: "b", responseText: '{"n":2}' }))
    const src0 = fake.effects.commands[0].sourceName
    const cmd0 = fake.effects.commands[0].command
    const queueLen0 = fake.state().queue.length
    assert.equal(fake.effects.commands.length, 1)
    assert.equal(fake.effects.watchdogStarts.length, 1)
    assert.equal(fake.effects.watchdogStarts[0], 12000)

    fake.finish(src0)
    assert.equal(fake.effects.watchdogStops, 1)
    assert.equal(fake.effects.disconnects[0], src0)
    assert.equal(fake.effects.commands.length, 2)
    assert.notEqual(fake.effects.commands[1].command, cmd0)
    assert.equal(fake.state().queue.length, queueLen0 - 1)
    assert.equal(fake.state().attempt, 1)
    assert.equal(fake.effects.watchdogStarts.length, 2)
    assert.equal(fake.effects.watchdogStarts[1], 12000)
    // no retry of the completed command
    assert.equal(
        fake.effects.commands.filter(c => c.command === cmd0).length, 1)
}

{
    // non-zero completion logs and advances without retry
    const fake = createFakeResponseCache(Pipeline, {}, clocks(1))
    fake.recordExchange(baseExchange({ profileId: "nz", responseText: '{"ok":true}' }))
    const src = fake.effects.commands[0].sourceName
    const cmd = fake.effects.commands[0].command
    const beforeLen = fake.effects.commands.length
    fake.finish(src, { exitCode: 7, stderr: "nope" })
    assert.ok(fake.effects.logs.some(l =>
        l === "Claude Usage: cache write failed exit=7 nope"
        || /cache write failed exit=7/.test(l)))
    // advanced to next in group (or idle if last); never re-launched same cmd
    assert.equal(
        fake.effects.commands.filter(c => c.command === cmd).length, 1)
    assert.ok(fake.effects.commands.length >= beforeLen)
    if (fake.state().busy) {
        assert.notEqual(fake.state().inFlightCommand, cmd)
        assert.equal(fake.state().attempt, 1)
    }
    finishAll(fake)
    assert.equal(fake.state().busy, false)
    assert.equal(
        fake.effects.commands.filter(c => c.command === cmd).length, 1)
}

{
    // stale arbitrary source: disconnect only; current source/watchdog/queue unchanged
    const fake = createFakeResponseCache(Pipeline, {}, clocks(1))
    fake.recordExchange(exchange)
    const before = fake.state()
    const cmdsBefore = fake.effects.commands.length
    const startsBefore = fake.effects.watchdogStarts.length
    const stopsBefore = fake.effects.watchdogStops
    const logsBefore = fake.effects.logs.slice()
    fake.finish("CACHE_WRITE_SEQ=42 totally-stale", { exitCode: 1, stderr: "x" })
    assert.equal(fake.effects.disconnects.at(-1), "CACHE_WRITE_SEQ=42 totally-stale")
    assert.equal(fake.effects.commands.length, cmdsBefore)
    assert.equal(fake.effects.watchdogStarts.length, startsBefore)
    assert.equal(fake.effects.watchdogStops, stopsBefore)
    assert.equal(fake.state().busy, before.busy)
    assert.equal(fake.state().inFlightSource, before.inFlightSource)
    assert.equal(fake.state().inFlightCommand, before.inFlightCommand)
    assert.equal(fake.state().attempt, before.attempt)
    assert.deepEqual(fake.state().queue, before.queue)
    assert.deepEqual(fake.effects.logs, logsBefore)
}

{
    // launch/pending sequences increment from zero; modulo constants via source
    const fake = createFakeResponseCache(Pipeline, {}, clocks(3))
    assert.equal(fake.state().launchSequence, 0)
    assert.equal(fake.state().pendingSequence, 0)

    fake.recordExchange(baseExchange({ profileId: "s1" }))
    assert.equal(fake.state().pendingSequence, 1)
    assert.equal(fake.state().launchSequence, 1)
    assert.match(fake.state().inFlightSource, /^CACHE_WRITE_SEQ=1 /)

    fake.recordExchange(baseExchange({ profileId: "s2" }))
    assert.equal(fake.state().pendingSequence, 2)
    // still only first command in flight until completion
    assert.equal(fake.state().launchSequence, 1)

    // contiguous FIFO groups: at enqueue time, full s1 group precedes s2
    const enqueued = [fake.effects.commands[0].command, ...fake.state().queue]
    const enqText = enqueued.join("\n")
    const iFirst = enqText.indexOf("s1")
    const iSecond = enqText.indexOf("s2")
    assert.ok(iFirst >= 0 && iSecond > iFirst)
    // no s2 command may appear before the last s1 command in the group
    const lastS1 = enqText.lastIndexOf("s1")
    assert.ok(lastS1 < iSecond)

    fake.finish(fake.effects.commands[0].sourceName)
    assert.equal(fake.state().launchSequence, 2)
    assert.match(fake.state().inFlightSource, /^CACHE_WRITE_SEQ=2 /)

    // source-level assertion of modulo constants without executing 1e5/1e6 commands
    const pipelineSrc = readFileSync(
        join(root, "contents/ui/js/ResponseCachePipeline.js"), "utf8")
    assert.match(pipelineSrc,
        /launchSequence\s*=\s*\(\s*launchSequence\s*\+\s*1\s*\)\s*%\s*100000/)
    assert.match(pipelineSrc,
        /pendingSequence\s*=\s*\(\s*pendingSequence\s*\+\s*1\s*\)\s*%\s*1000000/)

    finishAll(fake)
    // two exchanges only — pending seq ends at 2
    assert.equal(fake.state().pendingSequence, 2)
    // unique source identity across all launches
    const sources = fake.effects.commands.map(c => c.sourceName)
    assert.equal(new Set(sources).size, sources.length)
    for (const s of sources)
        assert.match(s, /^CACHE_WRITE_SEQ=\d+ /)
}

{
    // one in-flight command: second recordExchange must not launch while busy
    const fake = createFakeResponseCache(Pipeline, {}, clocks(2))
    fake.recordExchange(baseExchange({ profileId: "only-one" }))
    assert.equal(fake.effects.commands.length, 1)
    const qAfterFirst = fake.state().queue.length
    fake.recordExchange(baseExchange({ profileId: "queued-later" }))
    assert.equal(fake.effects.commands.length, 1)
    assert.ok(fake.state().queue.length > qAfterFirst)
    assert.equal(fake.state().busy, true)
}

console.log("All response cache pipeline tests passed.")
