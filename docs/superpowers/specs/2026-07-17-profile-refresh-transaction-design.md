# Profile Refresh Transaction Design

**Backlog source:** I002 — Deepen the profile refresh transaction  
**Date:** 17 July 2026  
**Status:** Approved for autonomous implementation planning; no product implementation is included in this document.

## Problem

A single profile refresh currently crosses queueing, credential shell I/O, provider selection, request construction, one or two `XMLHttpRequest` lifecycles, response caching, JSON parsing, provider parsing, stale-callback checks, profile mutation, auth suspension, and 429 backoff inside `ProfileController.qml`.

The main `fetchUsage()` path is 98 lines. Grok adds a parallel lifecycle through `fetchGrok()`, `grokGet()`, and `finishGrokPart()`, with eleven transient `grok*` fields stored on the live profile. Credential completion is routed through `credReader.onNewData`, while success and failure policy is spread across `applyUsageResult()`, `noteAuthFailure()`, `noteRateLimited()`, and inline error branches.

This implementation has repeatedly failed at asynchronous seams:

- B001: credential replies were attributed by mutable array index;
- B002: refresh-all could burst or drop work;
- B008: stale XHR callbacks could update a replacement row;
- B013: 429 retry backoff needed a ceiling;
- B025: network errors were mislabelled as timeouts;
- B026/B029: auth suspension and token-rotation recovery drifted;
- B033: Grok’s two requests used inconsistent credentials or finalized incorrectly.

Fixture responses exist for Claude, Codex, Grok, and MiniMax, but no test drives them through the actual credential-to-outcome lifecycle.

## Decisions

- This is a behaviour-preserving architectural refactor.
- The deep module owns one profile’s refresh transaction, from accepted credential read through one terminal outcome.
- Global refresh queueing, refresh-all staggering, due-profile selection, and timers remain in `ProfileController`.
- The transaction core is pure QML-compatible JavaScript and is tested through injected mock ports.
- Provider-specific request and aggregation rules are internal adapters, not caller branches.
- The response-cache pipeline remains outside the module behind a narrow recording port; I005 owns cache internals.
- The profile registry/store remains outside the module; I003 may deepen it later. The transaction emits stable-ID/generation mutation intent, and the controller performs the mechanical live-row commit.

## Goals

- Establish one deep profile-refresh interface with a coherent asynchronous lifecycle.
- Preserve all current provider, auth, timeout, partial-success, cache, and backoff behaviour.
- Carry stable profile identity and one generation through every asynchronous callback.
- Remove provider branching, XHR settlement, credential parsing, retry policy, and Grok aggregation from `ProfileController`.
- Keep global scheduling outside the transaction.
- Make fixture responses cross the same transaction interface used by production.
- Provide a mock credential/HTTP/cache port that exercises success, failure, duplicate callback, and completion-order cases.
- Return explicit, testable transitions and terminal outcomes instead of mutating live profile state from nested callbacks.

## Non-goals

- Redesign user-visible error messages or retry timing.
- Change refresh intervals, stagger timing, concurrency limits, or due-profile selection.
- Change provider URLs, headers, credential formats, parser results, or Grok partial-success rules.
- Change response-cache envelope, queue, watchdog, staging, paths, or shell adapter; those belong to I005.
- Change discovery, profile reconciliation, safe snapshots, or configuration application; those belong to I003/I004.
- Add network access to tests.
- Replace `QuotaParsers.js` parser algorithms.
- Implement the design as part of this planning work.

## Current Lifecycle

### Scheduling outside the intended seam

`queueProfileRefresh()`, `drainOneRefresh()`, `staggerRefreshAll()`, `refreshAll()`, `refreshProfile()`, `dueProfiles()`, and the stagger/auto-refresh timers select one profile and decide when a transaction may start. This policy is global scheduling and remains in the controller.

### Lifecycle inside the intended seam

1. `loadCredentials(idx, { manual })` checks holds, HOME readiness, per-profile loading, and credential-reader capacity.
2. It marks the row loading and records a source-name-to-profile-ID mapping.
3. `credReader.onNewData` parses the credential file and derives provider-specific auth.
4. It applies token-rotation/auth-suspension rules.
5. `fetchUsage()` resolves provider, URL, headers, token snapshot, profile ID, and generation.
6. Standard providers run one XHR; Grok runs two XHRs with one token snapshot.
7. Every HTTP exchange is offered to `cacheResponse()`, including stale generations and failures.
8. Settlement parses JSON, dispatches `QuotaParsers`, classifies status/timeout, and computes auth/backoff behaviour.
9. A stable profile ID and generation guard resolves the current row before applying a success or failure.

That lifecycle becomes the transaction module.

## Chosen Architecture

Create two pure JavaScript modules:

- `contents/ui/js/ProfileRefresh.js` — public transaction interface and lifecycle policy;
- `contents/ui/js/ProfileRefreshProviders.js` — internal provider adapters for credential interpretation, request construction, response aggregation, and parser dispatch.

`ProfileController.qml` retains thin production ports around its existing executable credential reader, XHR capability, response-cache call, clock/translation functions, and profile store.

### Public interface

```js
ProfileRefresh.run(input, ports, emit) -> accepted
```

`accepted` is `false` only when the credential port cannot start immediately, allowing the existing queue to rotate/retry the item. When accepted, `emit()` receives one synchronous `started` transition and exactly one terminal transition.

```js
input = {
    profile: profileSnapshot,
    generation: generation,
    manual: boolean,
    policy: {
        authRetryHoldMs,
        maxBackoffIntervalMs,
        maxAuthAutoAttempts,
        baseRefreshIntervalMs
    }
}
```

The profile snapshot contains the stable ID and the existing provider/auth/retry fields needed to preserve behaviour. The module never retains or receives a mutable array index.

```js
ports = {
    readCredentials(request, callback) -> accepted,
    requestHttp(request, callback),
    recordExchange(exchange),
    now() -> epochMilliseconds
}
```

The exact credential port request and callback shapes are:

```js
credentialRequest = {
    profileId,
    generation,
    path,
    isFlatFile
}
credentialCallback({ stdout, stderr, exitCode })
```

`readCredentials()` must return `false` without invoking the callback when HOME resolution or concurrency prevents an immediate start. After returning `true`, it must invoke the callback exactly once.

`requestHttp()` receives the request specification defined below and invokes its callback exactly once with the corresponding exchange object. `recordExchange()` is fire-and-forget; refresh completion never waits for cache persistence. `now()` is the only transaction clock.

The production ports adapt current QML facilities. Tests provide a deterministic mock object with the same four methods.

`emit(transition)` receives:

```js
transition = {
    type: "started" | "success" | "auth_error" | "auth_suspended"
          | "rate_limited" | "transport_error" | "parse_error",
    profileId,
    generation,
    patch,
    usageResult, // success only
    error        // terminal failure metadata only
}
```

Every transition includes `profileId` and `generation`. `patch` is mutation intent owned by the transaction: loading/error state plus auth hold/suspension or rate-limit backoff fields. A success also includes the normalised parser result.

### Controller application seam

`ProfileController` allocates one generation, stores it on the live profile, takes a profile snapshot, and invokes `ProfileRefresh.run()`.

Its transition handler performs only:

1. find the current row by stable profile ID;
2. reject the transition when its generation no longer matches;
3. apply `patch` mechanically;
4. on success, re-read the current visibility configuration, apply it to `usageResult.windows`, update time percentages, and commit those live-config-dependent fields.

Re-reading visibility at success time preserves current B034 behaviour without making refresh depend on persisted-configuration internals. The transaction owns the success/failure and retry intent; the controller/store owns the final mechanical commit.

## Provider Adapter Interface

Provider branching is private to `ProfileRefreshProviders.js`.

```js
adapterFor(profile, credentials) -> {
    auth,
    requests,
    finalize(exchanges) -> providerOutcome
}
```

Each request is data, not an XHR object:

```js
{
    key,
    endpoint,
    url,
    method: "GET",
    headers,
    timeoutMs: 25000
}
```

Each exchange returned by the HTTP port is:

```js
{
    key,
    endpoint,
    url,
    status,
    responseText,
    fromTimeout
}
```

Adapters preserve current behaviour:

- **Claude/Anthropic:** OAuth token, Anthropic beta header, `parseClaude`.
- **Codex/OpenAI:** bearer token, optional account-ID header, `parseCodex`.
- **MiniMax:** OAuth/flat/key credentials, resource URL, `parseMinimax`.
- **Z.ai:** raw authorization header, `parseZai`.
- **Kimi:** bearer token, `parseKimi`.
- **OpenCode:** existing account selection and slot priority, then delegate to the effective provider adapter.
- **Grok:** select one fresh token, build default and credits requests with identical token/header snapshots, settle in any order, parse monthly-only partial success when credits fail, and call `parseGrok` exactly once.

Unknown/effective-provider failure produces an explicit parse/configuration outcome rather than falling through caller branches.

## Transaction Invariants

1. A mutable profile array index never crosses an asynchronous seam.
2. Every credential request, HTTP request, exchange, and transition carries one stable profile ID and generation.
3. A transaction emits at most one terminal transition.
4. Duplicate XHR callbacks cannot duplicate cache recording or completion for that request.
5. Every settled HTTP exchange is passed once to `recordExchange()`, even if the controller later rejects the generation as stale.
6. Standard providers make one request; Grok always attempts both request legs on every accepted refresh.
7. All Grok legs share the same credential snapshot.
8. Grok completion order cannot change the final outcome.
9. JSON/provider parse errors are distinct from transport errors.
10. Status `0` is a timeout only when `fromTimeout === true`; otherwise it is a network error.
11. Status 401/403 preserves current auth failure count, hold, suspension, manual reset, and token-rotation semantics.
12. Status 429 preserves current exponential multiplier, provider base interval, ceiling, and hold-until calculation.
13. A successful outcome resets auth failure, suspension, hold, failed-token, and backoff state.
14. A manual transaction clears auth suspension/hold before credential evaluation, matching current forced-retry behaviour.
15. An automatically suspended profile with the unchanged failed token performs credential re-read but skips HTTP.
16. The transaction does not mutate the input profile or parser fixture objects.
17. `emit()` receives a coherent terminal outcome only after all required provider exchanges settle.

## Data Flow

```text
ProfileController queue selects stable profile ID
        │
        ├── allocate/store generation
        └── ProfileRefresh.run(snapshot, production ports, emit)
                 │
                 ├── credential port
                 │      └── provider adapter extracts auth
                 │
                 ├── provider adapter builds 1..N request specs
                 │      └── HTTP port returns exchanges
                 │             └── cache port records each exchange
                 │
                 ├── provider adapter aggregates/parses fixtures/responses
                 └── transaction emits one terminal outcome
                                │
                                └── controller resolves ID + generation
                                      ├── stale: drop mutation
                                      └── current: commit patch/result
```

## Production Port Responsibilities

### Credential port

Retain the safe executable-engine implementation details:

- HOME/path expansion and shell quoting;
- maximum credential-read concurrency;
- source-name-to-transaction callback mapping;
- stale source cleanup;
- flat-file versus JSON body delivery.

It returns raw credential text and exit metadata. Provider credential parsing and auth policy move into the transaction/provider modules.

### HTTP port

Create XHR from a request specification, set headers and timeout, and return one exchange through a once-only settlement guard. It does not interpret provider, status, JSON, auth, or retry policy.

### Cache port

Forward an exchange to the existing `cacheResponse()` interface. It does not expose cache queue/path/watchdog implementation to the transaction.

### Store/transition adapter

Remain in `ProfileController` until I003 provides a deeper registry. It resolves stable identity/generation and applies transaction-owned mutation intent.

## Error and Retry Behaviour

The refactor preserves current visible strings and timing. The transaction returns structured metadata; the controller’s thin translation adapter maps it to the existing text:

- missing/invalid credentials → “Not logged in”;
- 401/403 → “Token expired”;
- 429 → “Rate limited”;
- status 0 + timeout event → “API error (timeout)”;
- status 0 without timeout event → “API error (network error)”;
- other status → “API error (<status>)”;
- invalid JSON/provider result → “Parse error”.

Auth retry and rate-limit calculations use the injected clock and policy constants, so tests are deterministic.

## Testing Strategy

### Pure transaction tests

Add a Node VM loader for QML JavaScript modules and a deterministic mock port. The mock port must support:

- accepted and busy credential reads;
- credential success/failure;
- arbitrary HTTP completion order;
- timeout versus network status 0;
- duplicate callbacks;
- captured request headers/tokens;
- captured cache exchanges;
- controlled clock values.

### Fixture-driven provider coverage

Run the existing fixture files through the public transaction interface:

- Claude usage fixture;
- Codex usage fixture;
- Grok default plus credits fixtures, in both completion orders;
- MiniMax remains fixture.

Use minimal inline bodies for Z.ai and Kimi until dedicated sanitised fixtures exist. Verify normalised usage outcomes, request shape, and exactly-once completion.

### Failure and invariant coverage

Test:

- missing credential body;
- malformed credential JSON;
- missing token;
- first automatic auth failure hold;
- auth suspension threshold;
- unchanged suspended token skips HTTP;
- rotated token resumes and clears failure state;
- manual refresh clears suspension and retries;
- 429 multiplier and ceiling;
- timeout/network distinction;
- malformed response JSON;
- stale generation rejected by the controller transition seam;
- duplicate HTTP callback settles/caches once;
- Grok same-token dual request;
- Grok monthly-only partial success;
- Grok default failure;
- Grok auth failure;
- no input mutation.

### Controller seam regression

Add a focused source/integration contract showing that `ProfileController`:

- retains queue/due/timer functions;
- imports and calls `ProfileRefresh.run()`;
- allocates/stores one generation and applies transitions by ID/generation;
- has no provider-specific XHR, parser dispatch, `fetchUsage`, `fetchGrok`, `grokGet`, or `finishGrokPart` lifecycle;
- no longer stores transient `grok*` transaction fields on profiles;
- keeps cache internals behind the existing cache call.

Existing discovery, visibility, cache-shell, layout, and QML tests remain regression gates.

## Migration Sequence

1. Characterise current provider request/outcome behaviour through fixture and failure tests.
2. Add provider adapters and their pure tests without changing the controller path.
3. Add the transaction coordinator and mock ports; test identity, once-only settlement, auth, backoff, and Grok aggregation.
4. Adapt existing credential reader, XHR, cache, clock, and transition commit as production ports.
5. Route standard-provider refreshes through the transaction.
6. Route Grok through the same transaction and delete live-profile `grok*` state.
7. Remove old lifecycle functions and provider branches from `ProfileController` while retaining global scheduling.
8. Run the complete serial regression suite and review against this design.

## Acceptance Criteria

- One accepted profile refresh crosses `ProfileRefresh.run()` from credential read to one terminal outcome.
- Global queueing, due selection, and timers retain current behaviour outside the transaction.
- No asynchronous callback carries or applies a mutable profile array index.
- Every transition carries stable profile ID and generation; stale outcomes cannot mutate a current row.
- Claude, Codex, Grok, MiniMax, Z.ai, Kimi, and OpenCode retain current credentials, URLs, headers, parser selection, and results.
- Grok always uses one token snapshot for both legs, finalizes once in either completion order, and retains monthly-only partial success.
- Every HTTP exchange is recorded once through the cache port, including failed/stale-generation exchanges.
- Auth holds/suspension/token rotation/manual retry and 429 backoff/ceiling are unchanged.
- Timeout, network, auth, rate-limit, HTTP, and parse errors retain current visible behaviour.
- Fixture and mock tests exercise the public transaction interface without network or Plasma runtime access.
- `ProfileController` no longer owns provider-specific request, settlement, parser-dispatch, or Grok aggregation policy.
- No response-cache internals, profile-registry reconciliation, discovery, or persisted configuration are absorbed into I002.
- No product code is changed during planning/ingestion.

## Backlog Decomposition Direction

Create a second milestone under `P1 — Architecture Deepening`, with one epic and atomic tasks for:

1. provider-adapter characterisation and fixtures;
2. transaction core plus mock ports and failure policy;
3. production credential/HTTP/cache port adaptation;
4. standard-provider controller migration;
5. Grok migration and transient-state deletion;
6. lifecycle cleanup, controller seam regression, and full verification.

Tasks 4 and 5 may proceed independently after the transaction and production ports exist. The final cleanup depends on both.

--- SUMMARY ---

- Deepen one profile’s credential-to-outcome refresh lifecycle; leave global scheduling in `ProfileController`.
- Use one pure `ProfileRefresh.run(input, ports, emit)` interface with deterministic mock credential, HTTP, cache, and clock ports.
- Keep provider branching behind internal adapters and preserve every current provider/auth/backoff/Grok/cache behaviour.
- Carry stable profile ID and generation through every callback; emit one terminal mutation intent for mechanical controller commit.
- Decompose implementation into six testable backlog tasks under a new Architecture Deepening milestone; do not implement during this planning intake.
