# Response Cache Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move response-cache envelope, path, staging, serial queue, watchdog, and process choreography behind one `recordExchange(exchange)` interface with local production and deterministic fake adapters.

**Architecture:** A QML-compatible pure JavaScript factory owns cache policy and queue state. `LocalResponseCache.qml` supplies Plasma executable/timer effects, while `tests/helpers/fake-response-cache.mjs` supplies the same runtime interface for deterministic tests; I002’s caller sees only `recordExchange(exchange)` and `cache-response.sh` retains atomic file ownership.

**Tech Stack:** Qt 6 QML, Plasma executable `DataSource`, QML JavaScript, Node.js VM tests, Bash cache adapter tests.

## Global Constraints

- Follow `docs/superpowers/specs/2026-07-17-response-cache-pipeline-design.md` exactly.
- Begin only after `P1.M2.E1.T006` and `P1.M3.E1.T006` are complete; adapt to their final `ProfileController.qml` without restoring deleted refresh/registry policy.
- Preserve I002’s request-level once guard and its call to `recordExchange(exchange)` before provider finalisation and controller/store generation rejection.
- Keep the caller interface fire-and-forget: `recordExchange(exchange) -> undefined`.
- Preserve cache-disabled true no-op behaviour, enabled-by-default configuration, exactly three independent clock reads in history-path → envelope → pending-filename order, envelope schema, 200,000-character truncation, effective-provider metadata, exact provider/leg endpoint slugs, and history/latest layout.
- Preserve 8,192-character staged commands, current shell quoting, FIFO command ordering, one in-flight command, 12,000 ms watchdog, and two launches maximum per stalled command.
- Do not add a queue-length cap, overflow policy, network access, or dependency.
- Keep `contents/scripts/cache-response.sh` responsible for atomic history/latest writes and successful-write payload cleanup; no implementation change is planned for that file.
- Do not absorb I002 refresh/provider parsing, I003 registry, I004 visibility, or shell atomic-file implementation.
- Run tests serially or with at most two threads.
- Claim Qt coverage only when a functioning environment prints explicit zero-failure output.

---

## File Structure

### Create

- `contents/ui/js/ResponseCachePipeline.js` — pure envelope/path/staging preparation and serial queue/watchdog state machine.
- `contents/ui/LocalResponseCache.qml` — local Plasma production adapter satisfying `recordExchange(exchange)`.
- `tests/helpers/fake-response-cache.mjs` — deterministic runtime/public fake adapter.
- `tests/fixtures/response-cache-endpoints.mjs` — exhaustive provider/effective-provider/leg endpoint-slug contract shared by provider and cache tests.
- `tests/test-response-cache-pipeline.mjs` — pure behaviour and state-machine tests.
- `tests/test-response-cache-controller.mjs` — production adapter and controller deletion/source contract.

### Modify

- `contents/ui/ProfileController.qml` — instantiate the local adapter, forward I002’s cache port, then delete controller-owned cache internals.
- Prerequisite `tests/test-profile-refresh-providers.mjs` — assert every supported direct/OpenCode/Grok request endpoint against the shared cache-endpoint fixture.

### Verify without modifying

- `contents/scripts/cache-response.sh` — final path-only invocation and atomic history/latest/payload-cleanup adapter.
- `tests/test-cache-response.sh` — shell behaviour regression.
- `tests/test-path-utils.sh` — path/quoting regression.
- I002/I003 test files created by prerequisite tasks.

---

### Task 1: Characterise Envelope, Paths, and Staging Through the Fake Adapter

**Files:**
- Create: `contents/ui/js/ResponseCachePipeline.js`
- Create: `tests/helpers/fake-response-cache.mjs`
- Create: `tests/test-response-cache-pipeline.mjs`
- Reference: `contents/ui/ProfileController.qml` current cache cluster
- Reference: `contents/scripts/cache-response.sh`

**Interfaces:**
- Consumes: settled I002 exchange `{ profileId, provider, opencodeSlot, endpoint, url, status, responseText }` plus ignored `{ key, generation, fromTimeout }`.
- Produces: `ResponseCachePipeline.create(runtime) -> pipeline`, where the caller-visible method is `pipeline.recordExchange(exchange) -> undefined`.
- Produces internal adapter controls: `pipeline.commandFinished(sourceName, result)`, `pipeline.watchdogFired()`, and `pipeline.stateForTests()`.
- Produces fake seam: `createFakeResponseCache(Pipeline, settings, times)` with `recordExchange`, `finish`, `fireWatchdog`, `state`, and captured effects.

- [ ] **Step 1: Add the deterministic fake runtime adapter**

Create `tests/helpers/fake-response-cache.mjs` with this complete interface:

```js
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
```

- [ ] **Step 2: Write failing public-seam characterisation tests**

Create `tests/test-response-cache-pipeline.mjs`. Reuse prerequisite I002’s `tests/helpers/load-qml-js.mjs`, load `ResponseCachePipeline.js` with exported name `create`, then drive only `fake.recordExchange()` and fake controls. Use fixed UTC clock values:

```js
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"
import { createFakeResponseCache } from "./helpers/fake-response-cache.mjs"

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

const disabled = createFakeResponseCache(Pipeline, { enabled: false }, [])
disabled.recordExchange(exchange)
assert.deepEqual(disabled.effects.commands, [])
assert.deepEqual(disabled.state(), {
    queue: [], busy: false, inFlightCommand: "", inFlightSource: "",
    attempt: 0, launchSequence: 0, pendingSequence: 0
})

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
assert.match(queuedText, /"profileId":"open\\\/code one"/)
assert.match(queuedText, /"httpStatus":200/)
assert.match(queuedText, /"body":\{"ok":true\}/)
assert.doesNotMatch(queuedText, /"generation"|"fromTimeout"|"key"/)

console.log("All response cache pipeline tests passed.")
```

Create `tests/fixtures/response-cache-endpoints.mjs` with this exact exhaustive contract (the `credentialAlias` labels document current OpenCode source keys/profile fallback; they are not persisted):

```js
export const RESPONSE_CACHE_ENDPOINT_CASES = [
    { name: "claude", provider: "claude", opencodeSlot: "", effectiveProvider: "claude", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "anthropic alias", provider: "anthropic", opencodeSlot: "", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "codex", provider: "codex", opencodeSlot: "", effectiveProvider: "codex", endpoint: "wham-usage", requestKey: "usage" },
    { name: "openai alias", provider: "openai", opencodeSlot: "", effectiveProvider: "openai", endpoint: "wham-usage", requestKey: "usage" },
    { name: "zai", provider: "zai", opencodeSlot: "", effectiveProvider: "zai", endpoint: "quota-limit", requestKey: "usage" },
    { name: "kimi", provider: "kimi", opencodeSlot: "", effectiveProvider: "kimi", endpoint: "coding-usages", requestKey: "usage" },
    { name: "minimax", provider: "minimax", opencodeSlot: "", effectiveProvider: "minimax", endpoint: "coding-plan-remains", requestKey: "usage" },
    { name: "opencode fallback", provider: "opencode", opencodeSlot: "", credentialAlias: "missing/default -> anthropic", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "opencode anthropic", provider: "opencode", opencodeSlot: "anthropic", credentialAlias: "anthropic / anthropic-accounts", effectiveProvider: "anthropic", endpoint: "oauth-usage", requestKey: "usage" },
    { name: "opencode openai", provider: "opencode", opencodeSlot: "openai", credentialAlias: "openai", effectiveProvider: "openai", endpoint: "wham-usage", requestKey: "usage" },
    { name: "opencode minimax", provider: "opencode", opencodeSlot: "minimax", credentialAlias: "minimax-coding-plan", effectiveProvider: "minimax", endpoint: "coding-plan-remains", requestKey: "usage" },
    { name: "opencode zai", provider: "opencode", opencodeSlot: "zai", credentialAlias: "zai-coding-plan", effectiveProvider: "zai", endpoint: "quota-limit", requestKey: "usage" },
    { name: "opencode kimi", provider: "opencode", opencodeSlot: "kimi", credentialAlias: "kimi-for-coding", effectiveProvider: "kimi", endpoint: "coding-usages", requestKey: "usage" },
    { name: "grok default", provider: "grok", opencodeSlot: "", effectiveProvider: "grok", endpoint: "billing", requestKey: "default" },
    { name: "grok credits", provider: "grok", opencodeSlot: "", effectiveProvider: "grok", endpoint: "billing-credits", requestKey: "credits" }
]
```

For every fixture row, record an exchange and assert exact envelope `provider`/`endpoint`, exact history and latest provider-endpoint filename components, and `oauth-usage` rather than any slash-derived alternative. In prerequisite `tests/test-profile-refresh-providers.mjs`, import the same fixture and assert the prepared requests' `{ key, endpoint }` for every supported direct provider, both Grok legs, OpenCode missing-slot fallback, `anthropic`/`anthropic-accounts`, `openai`, `minimax-coding-plan`, `zai-coding-plan`, and `kimi-for-coding`. The direct Anthropic/OpenAI alias rows lock the current endpoint selector aliases even when reached as OpenCode effective providers. Explicitly assert that no Gemini fixture/request endpoint exists because current source creates no Gemini request leg.

Extend the same test file with exact cases for:

- configured absolute root and `~/override` with/without HOME;
- provider/profile/endpoint sanitisation and `unknown` fallback;
- exactly three distinct clock values per enabled valid exchange, consumed in history-path → envelope-timestamp → pending-filename order; assert the first value only determines history date/time, the second only `savedAt`/`savedAtMs`, and the third only `p-<ms>-<seq>.json`; assert disabled and malformed exchanges consume zero clock values;
- invalid text (`body: null`, escaped `raw`), empty text (both null), and valid JSON primitive;
- 200,001-character input yielding 200,000 raw characters and `truncated: true`;
- empty payload staging branch;
- payload lengths 8,192 and 8,193 yielding exact first/append chunk counts;
- raw text containing a single quote; assert each affected chunk command contains the exact POSIX single-quote concatenation string `"'\\''"` and does not contain the unescaped raw chunk;
- final command matching `bash '<script>' '<history>' '<latest>' '<pending>'` and containing no JSON body;
- a stale `generation: 1` exchange producing the same command group as any other generation;
- missing `profileId` logging/no-op without changing prior queue state.

Use programmatic extraction/JSON reconstruction for the 200,000-character assertion rather than checking only command count. The test must never invoke shell, filesystem, Plasma, or network.

- [ ] **Step 3: Run the test and verify the missing module fails**

```bash
TZ=UTC node tests/test-response-cache-pipeline.mjs
```

Expected: non-zero exit with `ENOENT` for `contents/ui/js/ResponseCachePipeline.js`.

- [ ] **Step 4: Implement pure preparation and normal FIFO advancement**

Create `contents/ui/js/ResponseCachePipeline.js` with `.pragma library` and `create(runtime)`. Use ES5/QML-compatible `var`/function syntax. The factory state is exactly:

```js
var queue = []
var busy = false
var inFlightCommand = ""
var inFlightSource = ""
var attempt = 0
var launchSequence = 0
var pendingSequence = 0
```

Implement these private functions with the current algorithms copied exactly from the design/source:

```text
pad2(number)
pad3(number)
slug(value)
shellQuote(value)
effectiveProvider(exchange)
cacheRoot(settings)
absoluteCacheRoot(settings)
buildPaths(settings, exchange, pathTimeMs)
nextPendingPath(settings, pendingTimeMs)
buildEnvelope(exchange, saveTimeMs)
buildCommands(settings, paths, pendingPath, payload)
enqueueCommands(commands)
drain()
launch(command)
```

`recordExchange(exchange)` must execute this exact order:

```js
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
```

`buildEnvelope()` must preserve JavaScript string-length truncation at 200,000, `status || 0`, valid-JSON `body` versus invalid `raw`, and the exact persisted keys/order from the spec. `buildCommands()` must preserve `umask 077`, `mkdir -p --`, `printf %s`, first truncate/later append, default chunk size 8,192, and final path-only Bash invocation.

For this task, implement normal source identity/completion too:

```js
function launch(command) {
    busy = true
    inFlightCommand = command
    launchSequence = (launchSequence + 1) % 100000
    inFlightSource = "CACHE_WRITE_SEQ=" + launchSequence + " " + command
    runtime.startWatchdog(runtime.settings().watchdogMs || 12000)
    runtime.startCommand(inFlightSource, command)
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
```

`enqueueCommands()` concatenates the entire command group before `drain()`. `drain()` shifts one command only when idle, sets `attempt = 1`, and launches. `stateForTests()` returns copied scalars and `queue.slice(0)`; it must not expose mutable state.

- [ ] **Step 5: Run characterisation tests green**

```bash
TZ=UTC node tests/test-response-cache-pipeline.mjs
```

Expected: exit `0` and `All response cache pipeline tests passed.`

- [ ] **Step 6: Commit deterministic preparation**

```bash
git add contents/ui/js/ResponseCachePipeline.js \
        tests/helpers/fake-response-cache.mjs \
        tests/fixtures/response-cache-endpoints.mjs \
        tests/test-response-cache-pipeline.mjs \
        tests/test-profile-refresh-providers.mjs
git commit -m "refactor(I005): add deterministic response cache pipeline"
```

---

### Task 2: Add Watchdog Retry, Late-completion Rejection, and Recovery

**Files:**
- Modify: `contents/ui/js/ResponseCachePipeline.js`
- Modify: `tests/test-response-cache-pipeline.mjs`

**Interfaces:**
- Consumes: Task 1’s factory/runtime and normal completion identity.
- Produces: bounded `pipeline.watchdogFired()` state transition with two maximum launches per stalled command.

- [ ] **Step 1: Add failing queue/watchdog tests**

Append tests that record two short exchanges (six clock reads), capture the first source, and assert:

```js
const stalled = createFakeResponseCache(Pipeline, {}, [
    PATH_TIME, SAVE_TIME, PENDING_TIME,
    PATH_TIME + 1000, SAVE_TIME + 1000, PENDING_TIME + 1000
])
stalled.recordExchange({ ...exchange, profileId: "first" })
stalled.recordExchange({ ...exchange, profileId: "second" })
const firstSource = stalled.effects.commands[0].sourceName
const firstCommand = stalled.effects.commands[0].command
stalled.fireWatchdog()
assert.equal(stalled.effects.disconnects.at(-1), firstSource)
assert.equal(stalled.effects.commands.length, 2)
assert.equal(stalled.effects.commands[1].command, firstCommand)
assert.notEqual(stalled.effects.commands[1].sourceName, firstSource)
assert.equal(stalled.state().attempt, 2)

stalled.finish(firstSource)
assert.equal(stalled.effects.commands.length, 2)
assert.equal(stalled.state().attempt, 2)

stalled.fireWatchdog()
assert.equal(stalled.state().attempt, 1)
assert.match(stalled.effects.logs.join("\n"), /dropped after stall, attempts=2/)
assert.notEqual(stalled.effects.commands.at(-1).command, firstCommand)
```

Also assert:

- firing watchdog while idle is a no-op;
- normal completion stops watchdog once and advances exactly one command;
- non-zero completion logs and advances without retry;
- each retried launch restarts at exactly 12,000 ms;
- launch and pending sequences increment from zero; add source assertions for `launchSequence = (launchSequence + 1) % 100000` and `pendingSequence = (pendingSequence + 1) % 1000000` rather than executing 100,000/1,000,000 commands;
- after a second-stall drop, every later queued command can be completed and the final state is idle/empty;
- a completion for an arbitrary stale source disconnects it but leaves current source/watchdog/queue unchanged.

- [ ] **Step 2: Run the focused test and verify failure**

```bash
TZ=UTC node tests/test-response-cache-pipeline.mjs
```

Expected: FAIL because `watchdogFired()` does not yet retry/drop the in-flight command.

- [ ] **Step 3: Implement exact watchdog semantics**

Add this state transition, preserving clear-before-disconnect ordering:

```js
function watchdogFired() {
    if (!busy) return
    var command = inFlightCommand
    var source = inFlightSource
    var stalledAttempt = attempt
    runtime.log("Claude Usage: cache write stalled (onNewData never fired), attempt="
                + stalledAttempt + " seq=" + launchSequence)
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
```

Ensure `launch()` does not reset `attempt`, while `drain()` sets it to one for a newly shifted command. Export `watchdogFired` in the returned pipeline object.

- [ ] **Step 4: Run all pure pipeline tests**

```bash
TZ=UTC node tests/test-response-cache-pipeline.mjs
```

Expected: exit `0`; watchdog tests prove one retry, second-stall drop, late callback rejection, and later-work recovery.

- [ ] **Step 5: Commit queue recovery**

```bash
git add contents/ui/js/ResponseCachePipeline.js tests/test-response-cache-pipeline.mjs
git commit -m "refactor(I005): preserve cache watchdog recovery"
```

---

### Task 3: Add the Local Plasma Production Adapter

**Files:**
- Create: `contents/ui/LocalResponseCache.qml`
- Create: `tests/test-response-cache-controller.mjs`
- Verify: `contents/ui/js/ResponseCachePipeline.js`

**Interfaces:**
- Consumes: `ResponseCachePipeline.create(runtime)` from Tasks 1–2.
- Produces: QML adapter properties `enabled`, `configuredRoot`, `homeDir`, and method `recordExchange(exchange)`.

- [ ] **Step 1: Write the failing local-adapter source contract**

Create `tests/test-response-cache-controller.mjs`:

```js
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const adapterPath = join(root, "contents/ui/LocalResponseCache.qml")
const adapter = readFileSync(adapterPath, "utf8")

assert.match(adapter, /import "js\/ResponseCachePipeline\.js" as Pipeline/)
assert.match(adapter, /property bool enabled/)
assert.match(adapter, /property string configuredRoot/)
assert.match(adapter, /property string homeDir/)
assert.match(adapter, /function recordExchange\s*\(exchange\)/)
assert.match(adapter, /Pipeline\.create\s*\(/)
assert.match(adapter, /engine:\s*"executable"/)
assert.match(adapter, /pipeline\.commandFinished\s*\(sourceName/)
assert.match(adapter, /pipeline\.watchdogFired\s*\(\)/)
assert.match(adapter, /interval:\s*12000/)
assert.match(adapter, /repeat:\s*false/)
assert.doesNotMatch(adapter, /JSON\.parse\s*\(.*responseText|function\s+profileSlug/)

console.log("Response cache adapter/controller contract passed.")
```

- [ ] **Step 2: Run the source contract and verify it fails**

```bash
node tests/test-response-cache-controller.mjs
```

Expected: non-zero exit with `ENOENT` for `contents/ui/LocalResponseCache.qml`.

- [ ] **Step 3: Implement `LocalResponseCache.qml` as an effects-only adapter**

Create the component with this structure and no cache policy helpers:

```qml
import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support
import "js/ResponseCachePipeline.js" as Pipeline

Item {
    id: root

    property bool enabled: true
    property string configuredRoot: ""
    property string homeDir: ""
    readonly property int watchdogMs: 12000
    property var pipeline: null

    readonly property string cacheScript: {
        var u = Qt.resolvedUrl("../scripts/cache-response.sh").toString()
        return u.indexOf("file://") === 0 ? u.substring(7) : u
    }

    function ensurePipeline() {
        if (pipeline) return pipeline
        pipeline = Pipeline.create({
            settings: function() {
                return {
                    enabled: root.enabled,
                    configuredRoot: root.configuredRoot,
                    homeDir: root.homeDir,
                    cacheScript: root.cacheScript,
                    payloadChunkSize: 8192,
                    watchdogMs: root.watchdogMs,
                    maxAttempts: 2
                }
            },
            nowMs: function() { return Date.now() },
            startCommand: function(sourceName, command) {
                cacheWriter.connectSource(sourceName)
            },
            disconnectCommand: function(sourceName) {
                cacheWriter.disconnectSource(sourceName)
            },
            startWatchdog: function(milliseconds) {
                cacheWatchdog.interval = milliseconds
                cacheWatchdog.restart()
            },
            stopWatchdog: function() { cacheWatchdog.stop() },
            log: function(message) { console.log(message) }
        })
        return pipeline
    }

    function recordExchange(exchange) {
        ensurePipeline().recordExchange(exchange)
    }

    Component.onCompleted: ensurePipeline()

    Plasma5Support.DataSource {
        id: cacheWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var exitCode = data["exit code"] !== undefined
                    ? data["exit code"] : data["exitCode"]
            root.ensurePipeline().commandFinished(sourceName, {
                exitCode: exitCode || 0,
                stderr: data["stderr"] || ""
            })
        }
    }

    Timer {
        id: cacheWatchdog
        interval: 12000
        repeat: false
        onTriggered: root.ensurePipeline().watchdogFired()
    }
}
```

Do not disconnect in `onNewData`; the pure state machine owns disconnect-before-identity-check so local and fake adapters follow the same ordering. The unused `command` runtime parameter is intentional: the executable engine receives the full unique `sourceName`, which already contains `CACHE_WRITE_SEQ=<n> <command>`.

- [ ] **Step 4: Run adapter and pure tests**

```bash
node tests/test-response-cache-controller.mjs
TZ=UTC node tests/test-response-cache-pipeline.mjs
```

Expected: both exit `0` with passing footers.

- [ ] **Step 5: Commit the production adapter**

```bash
git add contents/ui/LocalResponseCache.qml tests/test-response-cache-controller.mjs
git commit -m "refactor(I005): add local response cache adapter"
```

---

### Task 4: Migrate the I002 Port and Delete Controller Cache Internals

**Files:**
- Modify: `contents/ui/ProfileController.qml`
- Modify: `tests/test-response-cache-controller.mjs`
- Verify: post-I002 `contents/ui/js/ProfileRefresh.js`
- Verify: post-I003 registry source/tests

**Interfaces:**
- Consumes: I002 production `recordRefreshExchange(exchange)` cache port and Task 3’s `LocalResponseCache.recordExchange(exchange)`.
- Produces: one direct forwarding function and no cache implementation/state in `ProfileController.qml`.

- [ ] **Step 1: Tighten the source contract before migration**

Append controller assertions:

```js
const controller = readFileSync(
    join(root, "contents/ui/ProfileController.qml"), "utf8")
assert.match(controller, /LocalResponseCache\s*\{/)
assert.match(controller,
    /function recordRefreshExchange\s*\(exchange\)\s*\{\s*responseCache\.recordExchange\(exchange\)\s*\}/s)
for (const name of [
    "pad2", "pad3", "profileSlug", "responseCacheRoot",
    "buildResponseCachePaths", "cfgBool", "enqueueCacheWrite",
    "drainCacheWriteQueue", "launchCacheWrite", "onCacheWriteWatchdogFired",
    "absoluteCacheRoot", "nextPendingPayloadPath",
    "enqueuePayloadFileCacheWrite", "cacheResponse"
]) {
    assert.doesNotMatch(controller, new RegExp(`function ${name}\\s*\\(`))
}
for (const field of [
    "_cacheWriteQueue", "_cacheWriteBusy", "_cacheWriteSeq",
    "_cacheWriteInFlightCmd", "_cacheWriteInFlightSource",
    "_cacheWriteAttempt", "cacheWriteWatchdogMs", "cacheWriteMaxAttempts",
    "_cachePendingSeq", "cachePayloadChunkSize"
]) assert.doesNotMatch(controller, new RegExp(`\\b${field}\\b`))
assert.doesNotMatch(controller, /id:\s*cacheWriter\b|id:\s*cacheWriteWatchdog\b/)
assert.doesNotMatch(controller, /readonly property string cacheScript/)
```

Also inspect post-I002 `ProfileRefresh.js` and assert that `ports.recordExchange(exchange)` remains before the pending/final outcome call in its once-only HTTP callback. Use string indices:

```js
const refresh = readFileSync(
    join(root, "contents/ui/js/ProfileRefresh.js"), "utf8")
const cacheIndex = refresh.indexOf("ports.recordExchange(exchange)")
const finalizeIndex = refresh.indexOf("preparation.finalize", cacheIndex)
assert.ok(cacheIndex >= 0 && finalizeIndex > cacheIndex)
```

- [ ] **Step 2: Run the tightened contract and verify it fails**

```bash
node tests/test-response-cache-controller.mjs
```

Expected: FAIL because `ProfileController.qml` still owns cache functions/state or has not instantiated the adapter.

- [ ] **Step 3: Instantiate and bind the local adapter**

Add one child under the controller root:

```qml
LocalResponseCache {
    id: responseCache
    enabled: controller.cfgValue("cacheResponses", true) !== false
             && controller.cfgValue("cacheResponses", true) !== 0
             && controller.cfgValue("cacheResponses", true) !== "false"
             && controller.cfgValue("cacheResponses", true) !== "0"
    configuredRoot: String(controller.cfgValue("responseCachePath", "") || "")
    homeDir: controller.homeDir
}
```

Do not bind to a boolean coercion that turns the strings `"false"`/`"0"` on; the expression preserves current `cfgBool()` results while allowing `cfgBool()` itself to be deleted.

Replace the post-I002 cache port body with exactly:

```qml
function recordRefreshExchange(exchange) {
    responseCache.recordExchange(exchange)
}
```

If I002 names the production cache port differently, rename only that thin port and its `ProfileRefresh.run()` wiring together to `recordRefreshExchange`; do not alter the pure transaction’s `ports.recordExchange(exchange)` interface or ordering.

- [ ] **Step 4: Delete the controller cache implementation**

Delete the cache-only functions and fields listed in Step 1, the controller `cacheWriter` `DataSource`, `cacheWriteWatchdog` `Timer`, and controller `cacheScript` property. Delete `effectiveProvider()` only if post-I002/I003 source search shows no non-cache caller. Retain shared `shellQuote()` because discovery and credential readers still use it. Retain `homeDir`/HOME probing because credential/discovery adapters still use them.

Do not change:

- I002 HTTP once guards, `recordExchange` ordering, provider parsing, or generation checks;
- I003 registry state/reconciliation;
- `contents/scripts/cache-response.sh`;
- settings UI/config keys.

- [ ] **Step 5: Run seam, pure, prerequisite, and shell tests**

```bash
node tests/test-response-cache-controller.mjs
TZ=UTC node tests/test-response-cache-pipeline.mjs
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
node tests/test-profile-registry.mjs
node tests/test-profile-registry-controller.mjs
bash tests/test-cache-response.sh
bash tests/test-path-utils.sh
```

Expected: every present command exits `0`; cache shell prints `All cache-response tests passed.` and path utilities print `path utils ok`. If an exact I002/I003 filename differs after prerequisite implementation, list `tests/test-profile-*.mjs`, run every resulting file serially, and record the concrete filenames in the implementation commit message/verification note rather than skipping them.

- [ ] **Step 6: Commit the controller migration and deletion**

```bash
git add contents/ui/ProfileController.qml tests/test-response-cache-controller.mjs
git commit -m "refactor(I005): isolate response cache from profile controller"
```

---

### Task 5: Enforce the Deletion Test and Run Full Regression Verification

**Files:**
- Modify: `tests/test-response-cache-pipeline.mjs` only for acceptance gaps found during review
- Modify: `tests/test-response-cache-controller.mjs` only for deletion-contract gaps
- Verify: all product and test paths; no planned change to shell/product behaviour

**Interfaces:**
- Consumes: completed pure pipeline, local adapter, fake adapter, and migrated controller.
- Produces: verified one-method cache seam with no accepted blocker/major against the design.

- [ ] **Step 1: Add final invariant/deletion assertions**

Ensure the two Node tests explicitly prove:

```text
caller interface: recordExchange only
cache disabled: no clock/effect/state change
stale generation: still recorded
metadata: effective provider/profile/endpoint/url/status exact
provider endpoint contract: shared exhaustive fixture locks direct aliases, every current OpenCode alias/fallback, and both Grok legs at request construction and cache path/envelope consumption
clock: exactly three independent reads per valid exchange, ordered and destination-locked to history path, envelope, and pending filename
body: parsed/raw/empty/truncated exact
paths: default/configured/HOME fallback and sanitisation exact
staging: chunk size/order/quoting/path-only final argv exact
queue: FIFO groups, one in-flight, no implicit capacity drop
watchdog: 12000 ms, two launches, late completion ignored, recovery
adapter: executable DataSource + one timer, no cache policy
controller: direct forwarding only, no cache state/helpers/process/timer
shell: history then latest, atomic writes, cleanup after success
```

Do not add source assertions for formatting or incidental local names beyond the deletion seam.

- [ ] **Step 2: Run the complete serial suite**

```bash
TZ=UTC node tests/test-response-cache-pipeline.mjs
node tests/test-response-cache-controller.mjs
for test in tests/test-*.mjs; do node "$test"; done
bash tests/test-path-utils.sh
bash tests/test-cache-response.sh
bash tests/test-discovery.sh
```

Expected: every command exits `0` with its passing footer. Running explicit response-cache tests before the loop is intentional evidence; the loop then proves repository-wide Node regressions.

In a functioning Qt environment also run:

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_card_layout.qml -import contents/ui -o -,txt
```

Expected: explicit Qt output reports zero failures. If the host reproduces the known silent `qmltestrunner` exit `1`, record it as an environment limitation and do not claim Qt pass.

- [ ] **Step 3: Run direct seam, scope, and whitespace checks**

```bash
if rg -n '\b(cacheResponse|enqueueCacheWrite|drainCacheWriteQueue|launchCacheWrite|onCacheWriteWatchdogFired|buildResponseCachePaths|nextPendingPayloadPath)\s*\(' \
  contents/ui/ProfileController.qml
then
  echo "old response-cache pipeline remains in ProfileController" >&2
  exit 1
fi
rg -n 'recordExchange\(exchange\)|LocalResponseCache' \
  contents/ui/ProfileController.qml contents/ui/LocalResponseCache.qml \
  contents/ui/js/ResponseCachePipeline.js
git diff --check
```

Expected: old-pipeline guard prints no matches and exits `0`; seam search shows the I002 forwarder, local adapter, and pure core; `git diff --check` prints nothing.

- [ ] **Step 4: Review scope against prerequisites and shell ownership**

Run:

```bash
git diff --name-only P1.M3.E1.T006..HEAD
```

If task IDs are not Git refs, substitute the recorded implementation base commit. Expected product changes are only:

```text
contents/ui/ProfileController.qml
contents/ui/LocalResponseCache.qml
contents/ui/js/ResponseCachePipeline.js
```

Expected tests/docs/backlog may also change. `contents/scripts/cache-response.sh`, I002 refresh modules, I003 registry modules, settings UI, and provider parsers must be absent from the product diff.

- [ ] **Step 5: Run independent review and fix loop**

Give a fresh reviewer the design, this plan, final diff, backlog task acceptance criteria, and source. Require issue records with severity/evidence and PASS only when no meaningful issue remains. Fix every accepted blocker/major, rerun targeted tests, and rereview changed areas until no accepted blocker/major remains.

- [ ] **Step 6: Commit only if review required test/contract fixes**

```bash
git add tests/test-response-cache-pipeline.mjs \
        tests/test-response-cache-controller.mjs \
        contents/ui/js/ResponseCachePipeline.js \
        contents/ui/LocalResponseCache.qml \
        contents/ui/ProfileController.qml
git commit -m "test(I005): enforce response cache pipeline seam"
```

Skip this commit when review makes no changes; do not create an empty commit.

---

## Implementation Completion Gate

Before marking any implementation backlog task done:

1. Run its dedicated red test and inspect the expected failure.
2. Implement only the smallest behaviour needed for that task.
3. Run its green test and prerequisite regressions with explicit output.
4. Confirm exchange recording remains before stale-generation rejection.
5. Confirm the shared endpoint fixture passes at both provider-request and cache path/envelope seams, and the three distinct clock values reach only their ordered destinations.
6. Confirm shell atomic implementation and settings UI are untouched.
7. Confirm the controller deletion test removes rather than aliases old cache state.
8. Complete independent review/fix/rereview with no accepted blocker/major.
9. Record explicit Qt status without turning a silent environment failure into a pass.

--- SUMMARY ---

- **Task 1 (2h):** create the pure pipeline, shared exhaustive endpoint fixture, and fake adapter; characterise exact provider/leg slugs, three-read clock ownership, disabled behaviour, envelope, paths, staging, metadata, truncation, and normal FIFO behaviour.
- **Task 2 (2.5h):** preserve bounded two-attempt watchdog retry, late-completion rejection, non-zero completion, and queue recovery.
- **Task 3 (2h):** add an effects-only `LocalResponseCache.qml` production adapter.
- **Task 4 (2h):** forward I002’s `recordExchange` port, migrate production, and delete cache internals from `ProfileController.qml` without touching refresh/registry/shell policy.
- **Task 5 (1.5h):** enforce the deletion test, run complete serial regression/scope checks, and complete independent review/fix/rereview.
- Total implementation estimate is exactly **10h**, gated by `P1.M2.E1.T006` and `P1.M3.E1.T006`; this planning intake does not implement product code.
