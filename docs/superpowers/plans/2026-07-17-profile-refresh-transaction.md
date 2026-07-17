# Profile Refresh Transaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move one profile’s credential-to-outcome refresh lifecycle behind a pure, mockable transaction interface while preserving every current provider, identity, auth, backoff, Grok, and cache behaviour.

**Architecture:** `ProfileRefresh.run(input, ports, emit)` coordinates one accepted refresh using stable profile ID/generation and injected credential, HTTP, cache, and clock ports. Internal provider adapters own credential interpretation, request construction, multi-request aggregation, and parser dispatch; `ProfileController` retains global scheduling and mechanically applies current-generation transitions.

**Tech Stack:** Qt 6 QML, Plasma executable DataSource, QML JavaScript libraries, `XMLHttpRequest`, Node.js ESM/VM fixture tests, existing shell and Qt Quick regression tests.

## Global Constraints

- Follow `docs/superpowers/specs/2026-07-17-profile-refresh-transaction-design.md` exactly.
- Preserve current user-visible errors, auth hold/suspension, token-rotation recovery, 429 backoff, timeout/network distinction, and Grok partial-success behaviour.
- Preserve provider credential formats, URLs, headers, parser selection, and response-cache calls.
- Leave `queueProfileRefresh`, `drainOneRefresh`, `staggerRefreshAll`, `dueProfiles`, and refresh timers in `ProfileController`.
- Do not absorb response-cache envelope/queue/watchdog/path logic (I005), profile reconciliation (I003), or persisted visibility configuration (I004).
- Never carry a mutable profile array index through an asynchronous callback.
- Record each settled HTTP exchange exactly once, even when its generation later becomes stale.
- Add no network access or new dependency to tests.
- Keep QML JavaScript compatible with `.pragma library`; do not introduce promises or TypeScript.
- Run tests serially or with at most two threads.
- Existing `qmltestrunner` exits `1` silently on this planning host. Do not claim Qt tests pass without explicit passing output in a functioning Qt environment.

---

## File Structure

### Create

- `contents/ui/js/ProfileRefreshProviders.js` — internal provider/auth/request/aggregation adapters.
- `contents/ui/js/ProfileRefresh.js` — public one-profile transaction coordinator.
- `tests/helpers/load-qml-js.mjs` — reusable QML-JS VM loader for injected imports.
- `tests/helpers/mock-refresh-ports.mjs` — deterministic credential/HTTP/cache/clock mock.
- `tests/test-profile-refresh-providers.mjs` — fixture-driven provider adapter tests.
- `tests/test-profile-refresh.mjs` — transaction, identity, retry, and failure tests.
- `tests/test-profile-refresh-controller.mjs` — source-contract regression for the thin controller seam.

### Modify

- `contents/ui/ProfileController.qml` — production ports, transition application, standard/Grok migration, and old lifecycle deletion.
- `contents/ui/js/QuotaParsers.js` — no parser algorithm change; expose only existing functions to tests through the loader.
- `README.md` only if the implementation changes documented diagnostics; no change is expected.

---

### Task 1: Characterise Provider Adapters Through Fixtures

**Files:**
- Create: `tests/helpers/load-qml-js.mjs`
- Create: `contents/ui/js/ProfileRefreshProviders.js`
- Create: `tests/test-profile-refresh-providers.mjs`
- Reference: `contents/ui/ProfileController.qml:1235-1385, 1490-1664`
- Reference: `contents/ui/js/QuotaParsers.js`
- Fixture: `fixture-examples/*.json`

**Interfaces:**
- Consumes: current `QuotaParsers` and `QuotaCommon` functions.
- Produces: `Providers.prepare(profile, credentialText)` returning `{ auth, requests, finalize(exchanges) }`.

- [ ] **Step 1: Add a reusable QML-JS loader**

Create `tests/helpers/load-qml-js.mjs`:

```js
import { readFileSync } from "node:fs"

export function loadQmlJs(path, injected, exportedNames) {
    const source = readFileSync(path, "utf8")
        .replace(/^\s*\.pragma library\s*$/gm, "")
        .replace(/^\s*\.import[^\n]*$/gm, "")
    const names = Object.keys(injected || {})
    const exports = {}
    const exportCode = exportedNames
        .map(name => `exports.${name} = ${name};`)
        .join("\n")
    new Function(...names, "exports", source + "\n" + exportCode)(
        ...names.map(name => injected[name]), exports
    )
    return exports
}
```

- [ ] **Step 2: Write failing provider fixture tests**

Create `tests/test-profile-refresh-providers.mjs`. Load `QuotaCommon.js`, `QuotaParsers.js`, and the missing provider module, then assert this interface:

```js
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const QC = loadQmlJs(join(root, "contents/ui/js/QuotaCommon.js"), {}, [
    "makeWindow", "parseResetMs"
])
const QP = loadQmlJs(join(root, "contents/ui/js/QuotaParsers.js"), { QC }, [
    "parseClaude", "parseCodex", "parseGrok", "parseMinimax", "parseZai", "parseKimi"
])
const Providers = loadQmlJs(
    join(root, "contents/ui/js/ProfileRefreshProviders.js"), { QC, QP },
    ["prepare"]
)

function fixture(name) {
    return readFileSync(join(root, "fixture-examples", name), "utf8")
}
function okExchange(request, body) {
    return {
        key: request.key, endpoint: request.endpoint, url: request.url,
        status: 200, responseText: body, fromTimeout: false
    }
}

const claude = Providers.prepare(
    { id: "c", provider: "claude" },
    JSON.stringify({ claudeAiOauth: { accessToken: "claude-token",
                                      rateLimitTier: "default_claude_pro" } })
)
assert.equal(claude.auth.token, "claude-token")
assert.equal(claude.requests.length, 1)
assert.equal(claude.requests[0].headers.Authorization, "Bearer claude-token")
assert.equal(claude.requests[0].headers["anthropic-beta"], "oauth-2025-04-20")
assert.equal(claude.finalize([
    okExchange(claude.requests[0], fixture("2026-07-02-claude.json"))
]).kind, "success")

const codex = Providers.prepare(
    { id: "o", provider: "codex" },
    JSON.stringify({ tokens: { access_token: "codex-token", account_id: "acct" } })
)
assert.equal(codex.requests[0].headers["ChatGPT-Account-Id"], "acct")
assert.equal(codex.finalize([
    okExchange(codex.requests[0], fixture("2026-07-13-codex-wham-usage.json"))
]).kind, "success")

const grok = Providers.prepare(
    { id: "g", provider: "grok" },
    JSON.stringify({ accounts: { main: { key: "grok-token",
        expires_at: "2099-01-01T00:00:00Z", create_time: "2026-01-01T00:00:00Z" } } })
)
assert.equal(grok.requests.length, 2)
assert.deepEqual(grok.requests.map(r => r.headers.Authorization),
                 ["Bearer grok-token", "Bearer grok-token"])
const grokBodies = {
    default: fixture("2026-07-13-grok-billing-default.json"),
    credits: fixture("2026-07-13-grok-billing-credits.json")
}
for (const order of [[0, 1], [1, 0]]) {
    const exchanges = order.map(i => okExchange(grok.requests[i],
        grokBodies[grok.requests[i].key]))
    const outcome = grok.finalize(exchanges)
    assert.equal(outcome.kind, "success")
    assert.ok(outcome.usageResult.windows.length > 0)
}
const monthlyOnly = grok.finalize([
    okExchange(grok.requests[0], grokBodies.default),
    { ...okExchange(grok.requests[1], ""), status: 500 }
])
assert.equal(monthlyOnly.kind, "success")

const minimax = Providers.prepare(
    { id: "m", provider: "minimax", resourceUrl: "https://api.minimax.io" },
    JSON.stringify({ oauth: { access_token: "mini-token" } })
)
assert.equal(minimax.finalize([
    okExchange(minimax.requests[0], fixture("2026-07-14-minimax-coding-plan-remains.json"))
]).kind, "success")

console.log("All profile refresh provider tests passed.")
```

- [ ] **Step 3: Run the provider test and verify it fails**

```bash
node tests/test-profile-refresh-providers.mjs
```

Expected: FAIL with `ENOENT` for `ProfileRefreshProviders.js`.

- [ ] **Step 4: Implement the provider adapter module**

Create `contents/ui/js/ProfileRefreshProviders.js` with:

```js
.pragma library
.import "QuotaCommon.js" as QC
.import "QuotaParsers.js" as QP

function prepare(profile, credentialText) {
    var credentials = parseCredentials(profile, credentialText)
    var auth = extractAuth(profile.provider, credentials, profile)
    if (!auth.token)
        return failedPreparation("auth_error", auth)
    var effective = effectiveProvider(profile, auth)
    var requests = buildRequests(profile, effective, auth)
    return {
        auth: auth,
        effectiveProvider: effective,
        requests: requests,
        finalize: function(exchanges) {
            return finalizeProvider(effective, exchanges, profile, auth)
        }
    }
}
```

Move the behaviour of these existing functions into private helpers without changing their algorithms:

```text
ProfileController.extractAuth             lines 1235-1273
ProfileController.pickGrokToken           lines 1275-1300
ProfileController.extractOpencodeAuth     lines 1302-1337
ProfileController.effectiveProvider       lines 1339-1342
ProfileController.usageUrl                lines 1344-1352
```

Replace `cfgValue("opencodeAccountIndex", 0)` with `profile.opencodeAccountIndex || 0`; the controller transaction snapshot supplies that field. `buildRequests()` must reproduce current headers/URLs exactly. `finalizeProvider()` must classify HTTP status before JSON/provider parsing, reproduce Grok dual-response/partial-success rules from `finishGrokPart()`, and preserve `result.planName || auth.planName || profile.planName` before returning success.

Return semantic outcomes only:

```js
{ kind: "success", usageResult: result }
{ kind: "auth_error", status: status }
{ kind: "rate_limited", status: 429 }
{ kind: "transport_error", status: status, fromTimeout: boolean }
{ kind: "parse_error", detail: string }
```

- [ ] **Step 5: Complete provider coverage**

Add inline Z.ai, Kimi, OpenCode account-selection, missing-token, malformed-credential, non-200, malformed-JSON, and Grok-default-failure cases. Verify request keys/endpoints/headers and parser results; do not call the network.

- [ ] **Step 6: Run provider and existing visibility tests**

```bash
node tests/test-profile-refresh-providers.mjs
node tests/test-visibility.mjs
```

Expected: both exit `0` with passing footers.

- [ ] **Step 7: Commit provider adapters**

```bash
git add contents/ui/js/ProfileRefreshProviders.js \
        tests/helpers/load-qml-js.mjs tests/test-profile-refresh-providers.mjs
git commit -m "refactor(I002): add fixture-tested refresh provider adapters"
```

---

### Task 2: Build the Transaction Core and Mock Ports

**Files:**
- Create: `contents/ui/js/ProfileRefresh.js`
- Create: `tests/helpers/mock-refresh-ports.mjs`
- Create: `tests/test-profile-refresh.mjs`
- Modify: `tests/test-profile-refresh-providers.mjs` only if shared fixtures are extracted

**Interfaces:**
- Consumes: `Providers.prepare()` from Task 1.
- Produces: `ProfileRefresh.run(input, ports, emit) -> accepted`.

- [ ] **Step 1: Create a deterministic mock port**

Create `tests/helpers/mock-refresh-ports.mjs`:

```js
export function mockRefreshPorts({ now = 1_800_000_000_000,
                                   credentialText = "{}",
                                   credentialAccepted = true } = {}) {
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
            credentialCallbacks.shift().callback(result)
        },
        finishHttp(index, result) {
            const request = httpCallbacks[index].request
            httpCallbacks[index].callback({
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
```

- [ ] **Step 2: Write failing transaction tests**

Create `tests/test-profile-refresh.mjs` using the QML-JS loader and mock. Cover at minimum:

```js
const input = {
    profile: {
        id: "claude-1", provider: "claude", credPath: "/tmp/auth.json",
        authFailCount: 0, authSuspended: false, lastFailedToken: "",
        backoffMultiplier: 1, error: ""
    },
    generation: 7,
    manual: false,
    policy: {
        authRetryHoldMs: 300000,
        maxBackoffIntervalMs: 3600000,
        maxAuthAutoAttempts: 2,
        baseRefreshIntervalMs: 300000
    }
}
const transitions = []
const accepted = Refresh.run(input, mock.ports, t => transitions.push(t))
assert.equal(accepted, true)
assert.deepEqual(transitions.map(t => t.type), ["started"])
assert.equal(transitions[0].profileId, "claude-1")
assert.equal(transitions[0].generation, 7)
```

Then drive credential and HTTP callbacks and assert one `credentials` transition precedes exactly one terminal transition. The credential patch must contain the resolved token/account/resource/slot/plan fields; a manual read or rotated token must also clear prior auth failure state before HTTP. Add cases for busy credential port (`accepted === false`, no transition), valid stdout with non-zero executable exit, missing/malformed credentials, first/second auth failures, unchanged suspended token, rotated token, manual retry, 429 ceiling, timeout/network distinction, malformed response, duplicate callback, cache once, both Grok completion orders, and input immutability.

- [ ] **Step 3: Verify the transaction test fails for the missing module**

```bash
node tests/test-profile-refresh.mjs
```

Expected: FAIL with `ENOENT` for `ProfileRefresh.js`.

- [ ] **Step 4: Implement the transaction coordinator**

Create `contents/ui/js/ProfileRefresh.js`:

```js
.pragma library
.import "ProfileRefreshProviders.js" as Providers

function run(input, ports, emit) {
    if (!input || !input.profile || !input.profile.id)
        return false

    var profile = cloneObject(input.profile)
    var profileId = profile.id
    var generation = input.generation
    var manual = !!input.manual
    var terminal = false
    var credentialRequest = {
        profileId: profileId,
        generation: generation,
        path: profile.credPath || "",
        isFlatFile: !!profile.isFlatFile
    }

    var accepted = ports.readCredentials(credentialRequest, onCredentials)
    if (!accepted) return false

    emit({
        type: "started", profileId: profileId, generation: generation,
        patch: startedPatch(profile, manual)
    })
    return true

    function onCredentials(readResult) {
        if (terminal) return
        var preparation
        try {
            if (!readResult || String(readResult.stdout || "").length < 2)
                return finish(authFailure(profile, "", input.policy, ports.now()))
            // Preserve current behaviour: valid stdout is parsed even when the
            // executable adapter reports a non-zero exit code.
            preparation = Providers.prepare(profile, String(readResult.stdout))
        } catch (error) {
            return finish(authFailure(profile, "", input.policy, ports.now()))
        }
        if (preparation.kind === "auth_error")
            return finish(authFailure(profile, "", input.policy, ports.now()))
        if (!manual && profile.authSuspended
                && preparation.auth.token === profile.lastFailedToken) {
            return finish(suspendedOutcome(profile, input.policy, ports.now()))
        }
        // A successful manual credential read, or a rotated token, clears the
        // previous auth failure state before HTTP just as the current callback does.
        var retryProfile = credentialStateAfterRead(
            profile, preparation.auth, manual)
        emit({
            type: "credentials",
            profileId: profileId,
            generation: generation,
            patch: credentialPatch(retryProfile)
        })
        dispatch(preparation, retryProfile)
    }

    function dispatch(preparation, retryProfile) {
        var pending = preparation.requests.length
        var exchanges = []
        for (var i = 0; i < preparation.requests.length; i++) {
            (function(providerRequest) {
                var request = cloneObject(providerRequest)
                request.profileId = profileId
                request.generation = generation
                request.provider = profile.provider || ""
                request.opencodeSlot = preparation.auth.opencodeSlot
                    || profile.opencodeSlot || ""
                var settled = false
                ports.requestHttp(request, function(exchange) {
                    if (settled || terminal) return
                    settled = true
                    exchanges.push(exchange)
                    ports.recordExchange(exchange)
                    pending--
                    if (pending === 0)
                        finish(outcomeFor(preparation.finalize(exchanges), retryProfile,
                                          preparation.auth.token, input.policy, ports.now()))
                })
            })(preparation.requests[i])
        }
    }

    function finish(outcome) {
        if (terminal) return
        terminal = true
        outcome.profileId = profileId
        outcome.generation = generation
        emit(outcome)
    }
}
```

Implement private pure helpers `cloneObject`, `startedPatch`, `credentialStateAfterRead`, `credentialPatch`, `authFailure`, `suspendedOutcome`, `rateLimitOutcome`, `successOutcome`, `transportOutcome`, and `outcomeFor`. `credentialStateAfterRead` merges the resolved access token/account/resource/slot/plan fields and clears auth count/suspension/hold/failed-token/backoff when a valid manual read succeeds or the token differs from `lastFailedToken`; `credentialPatch` emits those fields before HTTP, and the cleared local state is the basis for any subsequent outcome. Preserve exact current field calculations from `noteAuthFailure`, `noteRateLimited`, and `clearFailureStatePatch`.

- [ ] **Step 5: Run all transaction/provider tests**

```bash
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
```

Expected: both exit `0`; no test performs network or Plasma I/O.

- [ ] **Step 6: Commit the transaction core**

```bash
git add contents/ui/js/ProfileRefresh.js \
        tests/helpers/mock-refresh-ports.mjs tests/test-profile-refresh.mjs
git commit -m "refactor(I002): add mockable profile refresh transaction"
```

---

### Task 3: Adapt Production Ports and Switch the Controller

**Files:**
- Modify: `contents/ui/ProfileController.qml:1-40, 1100-1178, 1690-1895`
- Create: `tests/test-profile-refresh-controller.mjs`

**Interfaces:**
- Consumes: `ProfileRefresh.run()` from Task 2.
- Produces: production `readRefreshCredentials`, `requestRefreshHttp`, `recordRefreshExchange`, and `applyRefreshTransition` adapters, with all accepted refreshes entering the new transaction.

- [ ] **Step 1: Write the failing controller-seam source test**

Create `tests/test-profile-refresh-controller.mjs` and assert:

```js
assert.match(src, /import "js\/ProfileRefresh\.js" as ProfileRefresh/)
assert.match(src, /function readRefreshCredentials\(/)
assert.match(src, /function requestRefreshHttp\(/)
assert.match(src, /function recordRefreshExchange\(/)
assert.match(src, /function applyRefreshTransition\(/)
assert.match(src, /ProfileRefresh\.run\(/)
assert.match(src, /findProfileIndex\(transition\.profileId\)/)
assert.match(src, /refreshGeneration !== transition\.generation/)
```

Also retain assertions that queue/due/timer functions still exist.

- [ ] **Step 2: Run the source test and verify it fails**

```bash
node tests/test-profile-refresh-controller.mjs
```

Expected: FAIL because no transaction import or production ports exist.

- [ ] **Step 3: Import the transaction and add the start wrapper**

Add:

```qml
import "js/ProfileRefresh.js" as ProfileRefresh
```

Add `startProfileRefresh(idx, manual)` that clones the current profile, adds `opencodeAccountIndex` from configuration, allocates a generation, and invokes:

```qml
return ProfileRefresh.run({
    profile: snapshot,
    generation: generation,
    manual: !!manual,
    policy: {
        authRetryHoldMs: authRetryHoldMs,
        maxBackoffIntervalMs: maxBackoffIntervalMs,
        maxAuthAutoAttempts: maxAuthAutoAttempts,
        baseRefreshIntervalMs: refreshIntervalMs(snapshot.provider)
    }
}, {
    readCredentials: readRefreshCredentials,
    requestHttp: requestRefreshHttp,
    recordExchange: recordRefreshExchange,
    now: function() { return Date.now() }
}, applyRefreshTransition)
```

Change `drainOneRefresh()` to call `startProfileRefresh(idx, item.manual)` instead of `loadCredentials()`; keep all queue rotation and hold checks unchanged.

- [ ] **Step 4: Make credential DataSource a thin port**

Replace source-name-to-profile-ID pending entries with source-name-to-request/callback entries containing `profileId`, `generation`, and `callback`. `readRefreshCredentials(request, callback)` performs only current capacity/HOME/path/shell safety checks, stores the entry, connects the source, and returns boolean.

`credReader.onNewData` must only disconnect, remove the pending entry, invoke its callback with `{ stdout, stderr, exitCode }`, and kick the queue. Remove provider/auth/retry/fetch decisions from this callback only after Tasks 4–5 migrate callers.

- [ ] **Step 5: Add generic HTTP/cache ports**

`requestRefreshHttp(request, callback)` creates one XHR, copies `request.method/url/headers/timeoutMs`, and settles once with the exchange shape from the spec. It contains no provider/status/JSON policy.

`recordRefreshExchange(exchange)` uses `exchange.profileId`, `provider`, `opencodeSlot`, `endpoint`, URL, status, and body to call existing `cacheResponse()` without waiting for cache persistence. The transaction decorates each provider request with stable identity/generation and profile metadata before handing it to the HTTP port; the port copies that metadata into the exchange.

- [ ] **Step 6: Add current-generation transition application**

`applyRefreshTransition(transition)` must resolve by ID. For `started`, store `refreshGeneration` and apply its patch. For every later transition—including `credentials`—return unless `profiles[idx].refreshGeneration === transition.generation`, then apply its patch. Map structured error metadata to the existing translated strings; for success, re-read visibility and apply normalised usage through a narrowed `applyUsageResult(idx, usageResult, patch)`.

- [ ] **Step 7: Run controller source and pure tests**

```bash
node tests/test-profile-refresh-controller.mjs
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
```

Expected: all exit `0` while the old provider fetch functions remain temporarily available for Tasks 4–5.

- [ ] **Step 8: Commit production ports**

```bash
git add contents/ui/ProfileController.qml tests/test-profile-refresh-controller.mjs
git commit -m "refactor(I002): add production refresh transaction ports"
```

---

### Task 4: Remove the Standard-provider Legacy Lifecycle

**Files:**
- Modify: `contents/ui/ProfileController.qml:1130-1484, 1794-1895`
- Modify: `tests/test-profile-refresh-controller.mjs`

**Interfaces:**
- Consumes: transaction and production ports from Tasks 2–3.
- Produces: no duplicate standard-provider credential/request/parser lifecycle in `ProfileController`; the transaction path switched in Task 3 remains authoritative.

- [ ] **Step 1: Tighten the controller test to reject standard-provider lifecycle policy**

Add assertions that `ProfileController.qml` contains no direct standard-provider XHR header/URL/parser dispatch and no `fetchUsage()` function after this task:

```js
assert.doesNotMatch(src, /function fetchUsage\s*\(/)
assert.doesNotMatch(src, /QP\.parse(Claude|Codex|Minimax|Zai|Kimi)\s*\(/)
assert.doesNotMatch(src, /anthropic-beta|ChatGPT-Account-Id/)
```

- [ ] **Step 2: Verify the tightened test fails**

```bash
node tests/test-profile-refresh-controller.mjs
```

Expected: FAIL on existing `fetchUsage()` and provider branches.

- [ ] **Step 3: Remove standard-provider lifecycle from the controller**

Delete `fetchUsage()` and move/delete controller copies of `extractAuth`, `extractOpencodeAuth`, `effectiveProvider`, and `usageUrl` once no non-refresh caller uses them. Remove credential callback parsing/auth decisions now handled by the transaction.

Keep `applyUsageResult()` only as the live visibility/store adapter; it must not select provider, classify status, compute retry, or parse JSON.

- [ ] **Step 4: Verify standard-provider fixture/failure behaviour**

Run:

```bash
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
node tests/test-visibility.mjs
```

Expected: all exit `0`; controller source has no standard-provider lifecycle policy.

- [ ] **Step 5: Commit standard-provider migration**

```bash
git add contents/ui/ProfileController.qml tests/test-profile-refresh-controller.mjs
git commit -m "refactor(I002): route standard providers through refresh transaction"
```

---

### Task 5: Remove the Grok Legacy Lifecycle and Live State

**Files:**
- Modify: `contents/ui/ProfileController.qml:369-490, 1490-1664`
- Modify: `tests/test-profile-refresh-controller.mjs`
- Modify: `tests/test-profile-refresh.mjs` for any missing Grok ordering case

**Interfaces:**
- Consumes: provider adapter aggregation and transaction ports.
- Produces: no duplicate Grok lifecycle and no live-profile `grok*` fields; the transaction path switched in Task 3 remains authoritative.

- [ ] **Step 1: Add failing Grok deletion assertions**

Require no functions `fetchGrok`, `grokGet`, or `finishGrokPart`, no `grokFetchGen`, and no transient fields `grokPending`, `grokDefaultSettled`, `grokCreditsSettled`, `grokFinalized`, `grokDefaultBody`, `grokCreditsBody`, status/timeout flags, or `grokAuthFailed`.

- [ ] **Step 2: Verify the source test fails**

```bash
node tests/test-profile-refresh-controller.mjs
```

Expected: FAIL on existing Grok functions and profile fields.

- [ ] **Step 3: Delete controller Grok lifecycle**

Remove Grok transient fields from blank profile creation/reconciliation carry lists. Delete `fetchGrok`, `grokGet`, and `finishGrokPart`. Do not delete Grok provider metadata needed by discovery or UI.

- [ ] **Step 4: Verify behaviour through the transaction seam**

Ensure `tests/test-profile-refresh.mjs` asserts:

- both request legs always launch;
- both carry the same token snapshot;
- completion order does not affect result;
- duplicate callback cannot double-cache/finalize;
- credits failure with default success returns monthly-only success;
- default 429 returns rate-limited;
- default auth failure without body returns auth error;
- exactly one terminal transition is emitted.

- [ ] **Step 5: Run Grok and controller gates**

```bash
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
```

Expected: all exit `0`; no Grok transaction state remains on profiles.

- [ ] **Step 6: Commit Grok migration**

```bash
git add contents/ui/ProfileController.qml \
        tests/test-profile-refresh.mjs tests/test-profile-refresh-controller.mjs
git commit -m "refactor(I002): move Grok dual refresh into transaction"
```

---

### Task 6: Delete Old Lifecycle Choreography and Run Full Verification

**Files:**
- Modify: `contents/ui/ProfileController.qml`
- Modify: `tests/test-profile-refresh-controller.mjs`
- Verify: all tests and design acceptance criteria

**Interfaces:**
- Consumes: completed standard and Grok migrations.
- Produces: one transaction seam with only global scheduling and store adaptation in the controller.

- [ ] **Step 1: Add final deletion-test assertions**

The source contract must require global scheduling functions and reject old lifecycle functions/provider policy:

```js
for (const name of [
    "queueProfileRefresh", "drainOneRefresh", "staggerRefreshAll",
    "refreshAll", "refreshProfile", "dueProfiles"
]) assert.match(src, new RegExp(`function ${name}\\s*\\(`))

for (const name of [
    "loadCredentials", "noteAuthFailure", "noteRateLimited",
    "clearFailureStatePatch", "extractAuth", "pickGrokToken",
    "extractOpencodeAuth", "effectiveProvider", "usageUrl",
    "fetchUsage", "fetchGrok", "grokGet", "finishGrokPart"
]) assert.doesNotMatch(src, new RegExp(`function ${name}\\s*\\(`))
```

Also assert `ProfileRefresh.run`, stable ID/generation checks, thin port functions, and existing `cacheResponse()` remain.

- [ ] **Step 2: Remove dead imports/functions/fields/comments**

Delete any now-unused controller lifecycle helper, `QuotaParsers.js` import, old generation fields (`usageFetchGen`, `grokFetchGen`), and stale B001/B008/B033 comments. Retain one generic `refreshGeneration` and comments documenting the transaction seam.

- [ ] **Step 3: Run the complete serial suite**

```bash
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
node tests/test-visibility.mjs
for test in \
  tests/test-quota-presentation.mjs \
  tests/test-quota-presentation-wiring.mjs \
  tests/test-main-quota-presentation.mjs
do
  if [ -f "$test" ]; then node "$test"; fi
done
node tests/test-account-card-layout.mjs
node tests/test-card-typography.mjs
node tests/test-main-layout.mjs
bash tests/test-path-utils.sh
bash tests/test-cache-response.sh
bash tests/test-discovery.sh
```

Do not hide failures from tests that exist. The three quota-presentation commands are conditional only because I001 may not yet be implemented; if their files exist, run each normally and require exit `0`.

In a functioning Qt environment, also run:

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_card_layout.qml -import contents/ui -o -,txt
```

Expected: every present Node/shell test passes; Qt output explicitly reports zero failures.

- [ ] **Step 4: Run direct seam and whitespace checks**

```bash
if rg -n '\b(fetchUsage|fetchGrok|grokGet|finishGrokPart|noteAuthFailure|noteRateLimited)\s*\(' \
  contents/ui/ProfileController.qml
then
  echo "old refresh lifecycle remains" >&2
  exit 1
fi
git diff --check
```

Expected: the guard finds no lifecycle matches and `git diff --check` returns no output.

- [ ] **Step 5: Review behaviour-preservation checklist**

Verify tests prove every acceptance criterion in the design: stable identity/generation, exactly-once terminal outcome/cache recording, all providers, Grok order/partial success, auth hold/suspension/rotation/manual retry, 429 ceiling, timeout/network distinction, current visibility re-read, and no input mutation.

- [ ] **Step 6: Commit final cleanup**

```bash
git add contents/ui/ProfileController.qml tests/test-profile-refresh-controller.mjs
git commit -m "refactor(I002): remove shallow refresh lifecycle choreography"
```

---

## Implementation Completion Gate

Before marking any implementation task done:

1. Run its dedicated red/green tests and inspect explicit output.
2. Confirm no mutable profile index crosses a callback.
3. Confirm each exchange and terminal transition is once-only.
4. Confirm response-cache internals remain untouched behind the port.
5. Run the complete serial suite after Tasks 4–6.
6. Review against `docs/superpowers/specs/2026-07-17-profile-refresh-transaction-design.md`.
7. Obtain explicit Qt test output in a functioning environment before claiming Qt coverage.

--- SUMMARY ---

- **Task 1:** characterise all provider auth/request/parser behaviour through fixtures and internal adapters.
- **Task 2:** implement the pure transaction coordinator and deterministic mock ports.
- **Task 3:** adapt current credential, XHR, cache, clock, and store mechanisms as thin production ports, then switch all accepted refreshes to the transaction.
- **Task 4:** delete the now-unused standard-provider controller lifecycle.
- **Task 5:** delete the now-unused Grok lifecycle and live-profile transaction state.
- **Task 6:** enforce the seam, remove old lifecycle choreography, and run complete verification.
- Implementation remains out of scope for the current planning/ingestion work.
