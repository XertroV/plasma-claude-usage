# Response Cache Pipeline Design

**Backlog source:** I005 — Isolate the response-cache pipeline
**Date:** 17 July 2026
**Status:** Approved for autonomous implementation planning; no product implementation is included in this document.

## Problem

`ProfileController.qml` currently owns response-cache policy and mechanics from the refresh call site down to the final shell command. Its public-looking call has five positional values, while eleven helpers/properties plus a `Plasma5Support.DataSource` and `Timer` own:

- cache enablement and configured-root resolution;
- provider/profile/endpoint filename metadata;
- history and latest paths;
- response truncation, JSON parsing, and envelope serialisation;
- private pending-payload names and chunked shell commands;
- serial command ordering;
- executable-source uniqueness;
- watchdog retry, late-completion rejection, failure logging, and queue recovery.

`tests/test-cache-response.sh` begins only at `cache-response.sh`, after all of that behaviour has already happened. B023 showed that process invocation could leak or exceed argument limits; B024 showed that an executable source that never completes can wedge the queue. The shell adapter is tested, but the controller-owned pipeline is not.

I002 deliberately leaves this implementation behind `recordExchange(exchange)`. I003 leaves cache outside the profile registry. I005 therefore deepens exactly this seam without absorbing refresh transaction/provider parsing, registry policy, or the shell’s atomic-file implementation.

## Goals

- Give refresh callers one small fire-and-forget interface: `recordExchange(exchange)`.
- Place enablement, metadata, envelope, paths, staging, serial queueing, watchdog, completion, and cleanup choreography behind one deep response-cache module.
- Provide a local Plasma production adapter and a deterministic fake adapter at the same seam.
- Exercise envelope, path, queue, retry, stale-completion, failure, and disabled-cache behaviour without Plasma or filesystem access.
- Preserve once-only exchange recording order and cache stale refresh generations before any generation-based mutation rejection.
- Preserve per-profile/provider/endpoint metadata, history/latest ownership, payload staging, command quoting/invocation, bounded retry, and error recovery.
- Delete cache state and policy from `ProfileController.qml` after migration.

## Non-goals

- Change I002 request settlement, provider adapters, parsing, auth/backoff policy, or generation checks.
- Change I003 profile registry/reconciliation or I004 visibility configuration.
- Change provider URLs, headers, response bodies, or the I002 exchange shape.
- Rewrite `cache-response.sh`, its atomic `mktemp`/`mv` writes, or its successful-write cleanup rule.
- Change cache file format, directory layout, the 200,000-character truncation backstop, or default/configured root behaviour.
- Introduce a queue-length cap or new overflow/drop policy. The current FIFO has no capacity limit; the bounded behaviour that must be preserved is two watchdog attempts per command.
- Make refresh completion wait for disk persistence or report cache failures to the UI.
- Encrypt provider responses or remove the existing residual exposure of one staged chunk in an executable command string.
- Implement this design during planning/ingestion.

## Exact Current Lifecycle and Ordering

### Refresh-side ordering

For a standard provider, `settleUsage()` has a once-only `settled` guard, then calls `cacheResponse(cacheProf, endpoint, url, status, responseText)` before resolving the current row/generation and before parsing or mutating usage. For Grok, each leg has its own once-only guard and performs the same call before its profile-ID/generation check. Consequences:

1. each settled HTTP leg is offered to cache at most once;
2. failed, timed-out, network-error, malformed, and successful responses are all offered;
3. a response from a stale generation is still offered;
4. cache persistence is fire-and-forget and does not delay parsing or profile mutation;
5. for Grok, default and credits exchanges enter the cache in actual settlement order.

I002 preserves those facts through its `ports.recordExchange(exchange)` call before provider finalisation and controller generation rejection. I005 consumes that exchange and must not move the call.

### Cache-disabled ordering

`cacheResponse()` checks `cfgBool("cacheResponses", true)` first. When disabled it returns before validating profile metadata, reading the clock, creating paths/envelopes, allocating a pending name, or changing queue state. The new interface must remain a true no-op at the same point.

### Metadata and envelope

For an enabled exchange, current code:

1. snapshots `{ id, provider, opencodeSlot }` before request settlement;
2. derives effective provider as `opencodeSlot || "anthropic"` for OpenCode and `provider` otherwise;
3. preserves the request adapter's endpoint slug exactly, then sanitises provider, profile ID, and endpoint for filenames to ASCII letters/digits plus `.`, `_`, `-`; every other character becomes `-`, repeated hyphens collapse, edge hyphens trim, and empty becomes `unknown`;
4. performs the first independent clock read in `buildResponseCachePaths()` (`new Date()`) and uses only that local time for:
   - `responses/YYYY/MM/DD/HHMMSS-mmm-provider-profile-endpoint.json`;
   - `latest/provider-profile-endpoint.json` (which contains no timestamp);
5. converts null/undefined response text to `""` and otherwise to `String(responseText)`;
6. truncates after 200,000 JavaScript string characters and sets `truncated: true`;
7. parses non-empty text as JSON; valid JSON is stored in `body` with `raw: null`, while invalid text is stored in `raw` with `body: null`; empty text stores both as `null`;
8. performs the second independent clock read in `cacheResponse()` (`new Date()`) and uses only it for `savedAt`/`savedAtMs`;
9. serialises this exact envelope:

```js
{
    savedAt: now.toISOString(),
    savedAtMs: now.getTime(),
    provider: effectiveProvider,
    profileId: profileId,
    endpoint: endpoint || "",
    url: url || "",
    httpStatus: status || 0,
    body: body,
    raw: raw,
    truncated: truncated
}
```

The current call chain performs one further clock read after serialising the envelope: `enqueuePayloadFileCacheWrite()` calls `nextPendingPayloadPath()`, which increments the pending sequence and then calls `Date.now()` for the pending filename. The exact ownership and order are therefore three independent reads: (1) history-path local date/time, (2) envelope timestamp, then (3) pending-filename epoch milliseconds. I005's pure pipeline owns when those reads occur and invokes `runtime.nowMs()` three times in that order; the local adapter owns the wall-clock effect. The reads must not be coalesced, reused, or reordered, because doing so can change history placement at a local-date boundary, persisted envelope time, or pending-name identity.

### Current endpoint-slug contract

The endpoint value arrives from I002's request adapter and is persisted unchanged in the envelope; its sanitised form is also part of both cache filenames. Current `endpointSlugForProvider()` and `grokEndpointSlug()` source establishes this exhaustive cache-producing contract:

| Provider/effective-provider or request leg | Exact endpoint slug |
| --- | --- |
| Claude, Anthropic alias, OpenCode default/missing slot, OpenCode `anthropic`, and `anthropic-accounts` | `oauth-usage` |
| Codex, OpenAI alias, and OpenCode `openai` | `wham-usage` |
| Z.ai and OpenCode `zai-coding-plan` → `zai` | `quota-limit` |
| Kimi and OpenCode `kimi-for-coding` → `kimi` | `coding-usages` |
| MiniMax and OpenCode `minimax-coding-plan` → `minimax` | `coding-plan-remains` |
| Grok default `/v1/billing` leg | `billing` |
| Grok `/v1/billing?format=credits` leg | `billing-credits` |

OpenCode's current credential priority maps `anthropic` (plus the `anthropic-accounts` profile key), `openai`, `minimax-coding-plan`, `zai-coding-plan`, and `kimi-for-coding` to the effective-provider slots shown above; an absent slot falls back to `anthropic`. The direct provider aliases in the endpoint selector are Claude/Anthropic and Codex/OpenAI. Gemini has no current credential extraction/request leg, so it produces no settled exchange and no endpoint slug; this plan must not invent one. Shared exact fixtures must be asserted both where provider requests are built and where cache paths/envelopes are built, so either side changing cannot silently move cache files.

### Root and pending-path resolution

The configured override is trimmed and passed through `QuotaCommon.expandToAbsolute(override, homeDir)`. If HOME is not ready, `~/x` becomes `$HOME/x`; other overrides remain as supplied. With no override, the root is `<homeDir>/.cache/plasma-claude-usage` or `$HOME/.cache/plasma-claude-usage`.

Pending payload paths require a local absolute root. `$HOME/`, `${HOME}/`, and `~/` resolve against `homeDir`; without HOME they fall back to `/tmp/plasma-claude-usage-cache`. Other roots remain unchanged. Pending names use the third clock value, after the history-path and envelope reads:

```text
<pending-root>/pending/p-<third Date.now()>-<sequence modulo 1000000>.json
```

### Staging and command ordering

The serial queue contains shell command strings, not exchange jobs. One exchange synchronously appends a contiguous command group:

1. first/empty staging command creates the pending directory under `umask 077` and creates/truncates the file;
2. each later 8,192-character chunk appends with `printf %s`;
3. the final command invokes `bash cache-response.sh <history> <latest> <pending>`.

Every user/config/body/path value is passed through the existing single-quote shell quoting. The JSON body never appears as the `cache-response.sh` payload argument; only its pending path does. Because JavaScript finishes appending one group before another callback can run, exchange groups do not interleave in the queue.

### Serial queue, bounded attempts, and watchdog

The FIFO has no length cap. It launches one command at a time. A launch:

- marks busy;
- stores the exact in-flight command;
- increments sequence modulo 100,000;
- prefixes `CACHE_WRITE_SEQ=<seq>` so Plasma does not collapse identical command sources;
- stores that source identity;
- restarts a 12,000 ms watchdog;
- connects the executable source.

Normal completion disconnects the source first. If the source is no longer the stored in-flight identity, it is a late completion and is ignored without draining twice. A current completion stops the watchdog, clears busy/in-flight/attempt state, logs a non-zero exit, and drains the next command. Non-zero exits are not retried.

A watchdog expiry clears in-flight identity before disconnecting, so any resulting late callback cannot double-complete. It retries the same command once (`cacheWriteMaxAttempts === 2`, counting the original). After a second stall it logs a drop and advances. Therefore retry is bounded and later queue work recovers. This command-level retry may repeat a successful append whose completion was lost; I005 preserves that behaviour rather than silently redesigning persistence semantics.

### Shell ownership

`cache-response.sh` reads payload from a path, writes history first, then latest when enabled, and removes the staged payload only after both writes succeed. Each destination write is atomic within its target directory via restrictive `umask 077`, `mktemp`, write, and `mv -f`. Failed writes retain the staged payload for a possible retry. These atomic-file and cleanup details remain shell-owned.

## Alternatives Considered

### Alternative A — Move the whole cluster into one QML object

Create `LocalResponseCache.qml` with `recordExchange()` and copy every helper/state field into it.

**Advantages:** smallest migration; naturally owns `DataSource` and `Timer`; controller deletion test passes.

**Costs:** queue, path, and envelope tests still require a QML runtime; shell-source callbacks remain hard to drive deterministically; the second adapter would only fake the outer method, not verify production pipeline policy. This moves code but does not deepen the test seam enough.

### Alternative B — Pure pipeline core plus local and fake adapters (chosen)

Create a QML-compatible pure JavaScript factory for policy/state, wrap it in a local Plasma adapter, and test it through a deterministic fake adapter. `ProfileController` and I002 know only `recordExchange(exchange)`.

**Advantages:** one-method caller interface; all complex policy is testable without Plasma/filesystem; executable/timer details stay local; the same state machine drives production and fake adapters; shell atomic implementation remains unchanged; the deletion test removes complexity rather than relocating it into callers.

**Costs:** an internal runtime-adapter interface is required for clock, settings, process, timer, disconnect, and logging. The adapter must carefully route callback identity back into the pure state machine.

### Alternative C — Push envelope and queueing into `cache-response.sh`

Pass exchange metadata/body to a long-lived or per-response shell process and make shell own paths/envelope/staging/queue.

**Advantages:** filesystem policy is concentrated in shell; less QML/JavaScript state.

**Costs:** recreates B023’s argv/stdin/process-lifetime risks; a shell process cannot naturally preserve the Plasma executable-source watchdog semantics; provider/profile metadata and JSON encoding cross a much larger process interface; fake tests no longer exercise the production state machine. It also expands the shell atomic-file implementation beyond I005’s allowed scope.

## Chosen Deep Module and Interfaces

### Public cache seam

Both production and fake adapters satisfy one interface:

```js
responseCache.recordExchange(exchange) -> undefined
```

The exchange is the I002 settled-exchange object:

```js
{
    key: string,
    profileId: string,
    generation: number,
    provider: string,
    opencodeSlot: string,
    endpoint: string,
    url: string,
    status: number,
    responseText: string,
    fromTimeout: boolean
}
```

I005 reads only `profileId`, `provider`, `opencodeSlot`, `endpoint`, `url`, `status`, and `responseText`. It intentionally ignores `generation`, `key`, and `fromTimeout`: generation must not suppress stale recording, request key does not belong in the stable cache format, and timeout classification belongs to I002 rather than the cache envelope.

`recordExchange()` returns no persistence result, throws no error to the caller, and never waits for a command. Disabled or malformed input is logged/no-op inside the module, preserving refresh independence.

### Pure pipeline implementation

Create `contents/ui/js/ResponseCachePipeline.js`:

```js
.pragma library

function create(runtime) -> pipeline

pipeline = {
    recordExchange: function(exchange),
    commandFinished: function(sourceName, result),
    watchdogFired: function(),
    stateForTests: function()
}
```

Only `recordExchange` is the caller interface. The other methods are the internal control interface used by the local/fake adapters to deliver executable and timer events. `stateForTests()` returns a copy of queue/busy/in-flight/attempt/sequence state and is not used by production callers.

The runtime-adapter interface is:

```js
runtime = {
    settings: function() {
        return {
            enabled: boolean,
            configuredRoot: string,
            homeDir: string,
            cacheScript: string,
            payloadChunkSize: 8192,
            watchdogMs: 12000,
            maxAttempts: 2
        }
    },
    nowMs: function() -> number,
    startCommand: function(sourceName, command),
    disconnectCommand: function(sourceName),
    startWatchdog: function(milliseconds),
    stopWatchdog: function(),
    log: function(message)
}
```

The module owns settings interpretation, slugs, the ordering and destinations of three clock reads, envelope, paths, pending names, command construction, FIFO state, retry policy, source identity, late-completion rejection, and advancement. The runtime performs clock/process/timer/log effects only; it does not decide when a clock value is consumed, what to cache, or how failures change queue state.

### Local production adapter

Create `contents/ui/LocalResponseCache.qml`. It exposes bound properties:

```qml
property bool enabled
property string configuredRoot
property string homeDir
readonly property string cacheScript
function recordExchange(exchange)
```

It creates one `ResponseCachePipeline.create(runtime)` instance, implements runtime methods with a `Plasma5Support.DataSource`, one single-shot `Timer`, `Date.now()`, and `console.log`, and forwards `onNewData` to `pipeline.commandFinished(sourceName, { exitCode, stderr })`. It contains no envelope/path/queue decisions.

`ProfileController.qml` owns one child:

```qml
LocalResponseCache {
    id: responseCache
    enabled: controller.cfgBool("cacheResponses", true)
    configuredRoot: String(controller.cfgValue("responseCachePath", "") || "")
    homeDir: controller.homeDir
}
```

Its I002 production cache port becomes:

```qml
function recordRefreshExchange(exchange) {
    responseCache.recordExchange(exchange)
}
```

### Deterministic fake adapter

Create `tests/helpers/fake-response-cache.mjs`. `createFakeResponseCache(Pipeline, settings, times)` returns an object with the same public `recordExchange(exchange)` method plus test controls:

- captured `commands`, `disconnects`, watchdog starts/stops, and logs;
- `finish(sourceName, result)` to drive a completion;
- `fireWatchdog()` to drive expiry;
- `state()` to inspect a copied state snapshot.

The fake adapter implements the exact runtime interface. Tests therefore exercise the same envelope/path/command/queue implementation as production, not a rewritten model.

## Payload and Envelope Ownership

- I002 owns settlement once-only semantics and the exchange object.
- `ResponseCachePipeline.js` owns conversion from exchange to persisted envelope, including effective provider, truncation, parse/raw choice, timestamps, JSON serialisation, and path/filename selection.
- `ResponseCachePipeline.js` owns pending payload names, 8,192-character command chunks, command order, quoting, and invocation arguments.
- `LocalResponseCache.qml` owns Plasma process/timer effects only.
- `cache-response.sh` owns reading the staged payload, atomic history/latest writes, successful-write unlink, and failed-write retention.
- History is immutable-by-name in normal operation; latest is the convenience overwrite for the same effective-provider/profile/endpoint tuple. The shell writes history before latest.

## Queue, Watchdog, and Error Semantics

The pure state machine preserves these invariants:

1. one in-flight command at a time;
2. exchange command groups append contiguously in `recordExchange` call order;
3. no queue-length cap or overflow drop;
4. attempt starts at one for each dequeued command;
5. a watchdog retries only the current command, at most once;
6. every launch gets a new `CACHE_WRITE_SEQ` source;
7. source identity is cleared before watchdog disconnect;
8. stale/late completion disconnects but cannot stop the current watchdog or drain twice;
9. current completion advances regardless of exit code, logging non-zero results;
10. second watchdog expiry drops only that command and then advances;
11. envelope/config/serialisation errors are caught and logged without changing existing queued work;
12. cache failure never changes refresh outcome.

## Stale-generation Recording

The cache module does not accept a current-generation predicate. I002 calls `recordExchange()` immediately after its request-level once guard and before provider finalisation or controller/store generation rejection. `generation` may be present for diagnostics but cannot gate persistence. Tests must drive an exchange labelled with an obsolete generation and prove it still produces one command group.

## Data Flow

```text
I002 HTTP port settles one request exactly once
        │
        ├── recordExchange(exchange)       (before stale-generation rejection)
        │       │
        │       └── LocalResponseCache     production adapter
        │               │
        │               └── ResponseCachePipeline.js
        │                       ├── disabled → no-op
        │                       ├── metadata + envelope + paths
        │                       ├── pending staging commands
        │                       └── serial FIFO + watchdog
        │                               │
        │                               └── Plasma executable DataSource
        │                                       │
        │                                       └── cache-response.sh
        │                                               ├── history atomic write
        │                                               ├── latest atomic write
        │                                               └── pending unlink on success
        │
        └── I002 provider finalisation and ID/generation mutation guard
```

Tests replace `LocalResponseCache` effects with `createFakeResponseCache` while retaining the same pure pipeline implementation.

## Security

- Continue single-quote escaping every shell-derived value, including configured paths and payload chunks.
- Keep the full JSON envelope out of the `cache-response.sh` argv; its third argument remains a pending path.
- Preserve 8,192-character chunking so no single executable source approaches `ARG_MAX` for a 200,000-character response.
- Preserve `umask 077` before pending directory/file creation and inside atomic destination writes.
- Preserve path sanitisation for provider/profile/endpoint filename components.
- Never place access tokens or request headers in the exchange/cache envelope.
- Cache bodies remain sensitive local data by design. The current chunk command can transiently expose one quoted chunk in a process command/source; eliminating that requires a different process transport and is explicitly out of scope for this behaviour-preserving refactor.
- Preserve the `/tmp/plasma-claude-usage-cache` fallback when HOME is unresolved, avoiding a literal `$HOME` directory. Permissions on created files remain restrictive.

## Invariants

1. `recordExchange(exchange)` is the only interface known to refresh/controller callers.
2. Disabled cache performs no clock, path, serialisation, sequence, queue, process, or timer work.
3. Every request-level settled exchange reaches `recordExchange` at most once because I002 owns the settlement guard.
4. Every offered exchange, including stale generations and failures, is transformed at most once.
5. Effective provider, profile ID, exact provider/leg endpoint slug, URL, status, body/raw, truncation, and timestamps retain current envelope meaning.
6. History/latest paths retain current layout and sanitisation; the endpoint-slug fixture exhaustively locks Claude/Anthropic, Codex/OpenAI, Z.ai, Kimi, MiniMax, both Grok legs, and every current OpenCode credential alias/fallback.
7. Enabled valid recording consumes exactly three independent clock values in order: history path, envelope timestamp, pending filename; disabled or malformed recording consumes none.
8. One exchange’s staging and script commands remain contiguous and FIFO relative to other exchanges.
9. Only one command is in flight.
10. Retry is bounded to two launches per stalled command; non-zero completion is logged and not retried.
11. A late completion cannot complete or drain a newer in-flight command.
12. Refresh parsing/mutation never waits for cache persistence.
13. The shell remains the sole owner of atomic history/latest writes and staged-file removal after success.
14. The pure pipeline does not read profile registry state, provider parsers, or refresh generation validity.
15. The fake and local adapters satisfy the same one-method public seam and the same runtime effect interface.

## Testing Strategy

### Pure pipeline and fake-adapter tests

Add `tests/test-response-cache-pipeline.mjs` and drive the public `recordExchange()` through `tests/helpers/fake-response-cache.mjs`. Cover:

- disabled mode is a complete no-op;
- default/configured/HOME-unresolved roots;
- an exhaustive shared endpoint fixture, asserted against I002 provider requests and I005 cache paths/envelopes, for Claude/Anthropic, Codex/OpenAI, Z.ai, Kimi, MiniMax, Grok default/credits, OpenCode missing-slot fallback, and OpenCode `anthropic`/`openai`/`minimax-coding-plan`/`zai-coding-plan`/`kimi-for-coding` aliases;
- exact slug/path layout with three distinct injected clock values, asserting the first only in the history path, the second only in `savedAt`/`savedAtMs`, the third only in the pending filename, and exactly three calls in that order;
- OpenCode effective provider from `opencodeSlot`;
- valid JSON body, invalid raw body, empty body, JSON primitive, and 200,001-character truncation;
- envelope metadata and absence of generation/token/header fields;
- 8,192-character chunk boundaries, empty payload, shell quoting, and path-only final script invocation;
- two exchanges enqueue contiguous command groups in call order;
- normal current completion, non-zero completion, and queue advancement;
- 12-second watchdog, one retry with a fresh source, second-stall drop, and later-work recovery;
- late completion after watchdog cannot double-drain;
- launch/pending sequence increments plus source-level assertions that their modulo constants remain 100,000 and 1,000,000;
- stale-generation-labelled exchange is still recorded;
- malformed/no-profile exchange logs/no-ops without damaging queued work.

### Local adapter/controller source contract

Add `tests/test-response-cache-controller.mjs` to prove:

- `ProfileController.qml` instantiates `LocalResponseCache` and forwards I002’s `recordRefreshExchange(exchange)` directly;
- no cache path/envelope/staging/queue/watchdog helper or cache `DataSource`/`Timer` remains in the controller;
- `LocalResponseCache.qml` imports the pure pipeline and owns one executable `DataSource` plus one watchdog `Timer`;
- the adapter forwards completion source identity and exit metadata to the core;
- `cache-response.sh` remains the final command target.

### Shell/regression gates

Keep and run `bash tests/test-cache-response.sh` for atomic history/latest writes, optional latest, stdin/path payloads, HOME expansion, large payloads, staged cleanup, and path-only final argv. Keep `bash tests/test-path-utils.sh` and all present I002/I003/visibility/layout/discovery tests as regression gates. Add no network access.

## Migration Sequence

1. Characterise envelope, roots, paths, staging commands, and disabled behaviour through failing fake-adapter tests.
2. Implement the pure preparation half of `ResponseCachePipeline.js`.
3. Characterise FIFO, completion identity, watchdog retry/drop, and recovery; implement the state machine in the same module.
4. Add `LocalResponseCache.qml` as the Plasma runtime adapter and source-contract tests.
5. Bind the adapter in `ProfileController.qml`, forward I002’s existing `recordRefreshExchange(exchange)`, and switch production to the module.
6. Delete controller cache helpers/properties/DataSource/Timer and the now-unused parser/path imports only when source search proves they have no other caller.
7. Run fake, shell, path, I002, I003, visibility, layout, discovery, and Qt gates; review the deletion test.

## Acceptance Criteria

- One settled I002 exchange crosses only `recordExchange(exchange)` into the response-cache module.
- Local production and deterministic fake adapters satisfy that same seam.
- Cache-disabled behaviour is a true no-op and remains enabled by default.
- Standard, Grok, failed, timeout/network, malformed, and stale-generation exchanges remain eligible for once-only recording in settlement order.
- Per-profile/effective-provider/endpoint metadata, URL/status, body/raw/truncation envelope semantics, timestamps, and path layout are unchanged; exact provider/leg endpoint fixtures and the three-read clock order/destinations are test-locked.
- Payloads are staged in 8,192-character quoted commands under `umask 077`; final script invocation carries paths only.
- FIFO command ordering, unique executable sources, one in-flight command, 12-second watchdog, two-attempt bound, late-completion rejection, non-zero logging, and queue recovery are test-covered.
- History and latest remain shell-owned atomic writes; pending payload is removed only after both succeed.
- Pure tests drive queue/error behaviour without Plasma, filesystem, or network access.
- `ProfileController.qml` contains no cache root/path/envelope/staging/queue/watchdog/process implementation after migration.
- I002 refresh/provider parsing, I003 registry, I004 visibility, and `cache-response.sh` atomic implementation remain outside the module.
- Existing cache/path and all present regression tests pass; Qt results are claimed only with explicit output from a functioning environment.
- No product code is changed during planning/ingestion.

## Deletion Test

Delete `ResponseCachePipeline.js` and `LocalResponseCache.qml` after the migration. To retain behaviour, callers would have to regain enablement/root resolution, effective-provider metadata, sanitised history/latest naming, envelope truncation/parsing, pending-file chunking, shell quoting, FIFO/in-flight state, executable-source uniqueness, watchdog retry/drop, stale-completion identity, and failure recovery. The complexity reappears across `ProfileController`, I002’s cache port, and tests. The module therefore earns its seam through depth and locality rather than acting as a pass-through.

--- SUMMARY ---

- Preserve I002’s once-only `recordExchange(exchange)` ordering before stale-generation rejection and keep refresh completion independent of disk writes.
- Choose a pure `ResponseCachePipeline.js` state machine behind a one-method seam, with `LocalResponseCache.qml` and a deterministic fake adapter supplying the same effects.
- Move envelope, paths, staging, FIFO, bounded two-attempt watchdog recovery, and completion identity out of `ProfileController`; keep shell atomic writes/cleanup unchanged.
- Test disabled, metadata, truncation, quoting, ordering, retry/drop, late completion, stale generation, and error recovery without Plasma or filesystem access.
- Implement only after prerequisite I002 and I003 terminal tasks; this intake creates design, plan, and backlog decomposition but no product changes.
