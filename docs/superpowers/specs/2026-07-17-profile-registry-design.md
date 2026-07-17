# Profile Registry Design

**Backlog source:** I003 — Deepen the profile registry  
**Date:** 17 July 2026  
**Status:** Approved for autonomous implementation planning; no product implementation is included in this document.

## Problem

`ProfileController.qml` currently combines profile discovery intake, legacy filtering/bootstrap, custom-profile materialisation, identity matching, row construction, live-state preservation, configuration reapplication, safe UI snapshots, refresh side effects, and the mutable profile store.

Two separate paths encode reconciliation knowledge:

- `mergeDiscovered()` builds rows from discovery/custom metadata, matches prior rows by ID, copies an explicit live-state key list, reapplies names/membership/visibility, replaces the array, and schedules refreshes.
- `reapplyConfig()` clones current rows, reapplies names/visibility and optionally membership, replaces the array, and schedules newly enabled empty rows.

`main.qml` independently classifies configuration signals as `rediscover`, `membership`, or `soft`, coalesces them, and calls the controller with those categories. `configGeneral.qml` separately parses and serialises enabled-profile allowlists, names, custom entries, and custom IDs. Safe UI projection is another controller-only denylist/copy path.

The result is a tall `ProfileController` with identity and profile lifecycle invariants spread across controller, applet shell, KCM, discovery script, and views. Changes to profile fields or configuration semantics must be repeated across merge key lists, snapshot filtering, KCM maps, and callers.

The approved 14 July design already specified:

- `ProfileRegistry` — discovered profiles, deduplication, enable/disable, and display names;
- `ProfileFetcher` — per-profile transport/retry;
- `UsageController` — orchestration between registry/fetchers and UI.

The current implementation never established that registry seam.

## Decisions

- I003 is behaviour-preserving for valid existing discovery/configuration inputs.
- Exact profile `id` remains the runtime identity key. Mutable array index never crosses the registry interface.
- The production discovery shell remains responsible for filesystem scanning, canonical paths, inode deduplication, and stable discovery IDs.
- A pure QML-compatible JavaScript module owns registry transitions and configuration edits.
- `ProfileController` remains the orchestration/store adapter until the registry is integrated; after integration it delegates row state and effects to the registry.
- I003 implementation depends on completion of `P1.M2.E1` (I002), because both substantially modify `ProfileController.qml` and the post-I002 profile schema replaces legacy Grok generation fields.
- Visibility migration/serialisation remains I004. The registry owns when visibility is reapplied through a narrow adapter, not the raw visibility format.
- Refresh lifecycle remains I002 and cache remains I005.

## Goals

- Concentrate identity, row schema, reconciliation, live-state preservation, configuration application, and safe public projection behind one seam.
- Give runtime and KCM one implementation for enabled-profile, display-name, and custom-profile semantics.
- Remove config-impact category knowledge from `main.qml`.
- Make discovery locally substitutable: production shell output and deterministic test candidates cross the same registry transition.
- Preserve current legacy/multi-profile, custom-profile, membership, naming, visibility, refresh-effect, ordering, and snapshot behaviour for valid input.
- Patch rows by stable ID with optional generation precondition, supporting I002 outcomes without index-based mutation.
- Make public profile shape explicit and deep-copy nested windows.
- Test reconciliation and configuration through the registry interface without Plasma, filesystem discovery, or network access.

## Non-goals

- Change filesystem scan targets, inode deduplication, path preference, or ID generation in `discover-profiles.sh`.
- Change provider refresh, credentials, requests, retries, or outcome semantics (I002).
- Change visible-quota JSON migration/default/edit/persistence semantics (I004).
- Change response-cache behaviour (I005).
- Change UI layout or quota presentation (I001).
- Change refresh scheduling intervals or queue mechanics.
- Redesign valid existing profile ordering, legacy selection, names, or enablement semantics.
- Implement the design during this planning intake.

## Current Behaviour to Preserve

### Discovery and source ordering

- `discover-profiles.sh` emits metadata with `id`, `provider`, `profileKey`, `configDir`, `credPath`, `credInode`, and `isFlatFile`.
- The script deduplicates by credential inode, prefers real directories, then shorter/lexicographically smaller credential paths, builds stable IDs, and sorts by provider/ID.
- Runtime discovery candidates retain script order.
- In multi-profile mode, valid custom profiles are appended in configuration order.
- In legacy mode, customs are ignored and discovered candidates are filtered to the configured provider/path; when no explicit credential path exists, one canonical shortest-path candidate is retained.
- If legacy discovery is empty and an explicit credential path exists, a synthetic legacy candidate is created.

### Identity and reconciliation

- Runtime identity is exact `id`.
- A rediscovered row with the same ID receives new source metadata/configuration but preserves current live usage/auth/refresh state.
- Removed IDs disappear.
- New rows receive the complete blank-row schema.
- Current valid production/custom inputs are unique by ID. The deep registry additionally rejects later duplicate IDs deterministically: the first candidate wins and a warning effect records the collision. This hardens malformed advanced JSON without changing valid behaviour.

### Configuration

- `enabledProfilesJson === []` means all profiles enabled.
- `enabledProfilesJson === ["__none__"]` means none enabled.
- Otherwise it is an ID allowlist.
- Display-name overrides are non-empty values keyed by profile ID.
- Custom profiles are multi-profile-only, append after discovered profiles, resolve default credential paths by provider, and receive stable non-reused IDs.
- Rediscover-impact keys: `multiProfileMode`, `credentialsPath`, `provider`, `opencodeSubProvider`, `customProfilesJson`.
- Membership-impact key: `enabledProfilesJson`.
- Soft-impact keys: `profileDisplayNamesJson`, `visibleWindowsJson`, `displayName`.
- Impact precedence is rediscover > membership > soft.
- Soft apply without a current name override preserves the existing display name, matching current behaviour; reverting a removed override to a default remains a rediscovery concern.

### Refresh effects

- After discovery reconciliation, if any enabled row lacks windows, current behaviour triggers refresh-all for enabled rows.
- Membership apply queues manual refresh only for rows that became enabled and are empty/not already loading.
- Soft apply does not refresh.

### Public projection

Views currently consume exactly:

```text
id, provider, configDir, credPath, displayName, enabled,
loading, error, planName, bankedResets, windows, lastFetchMs
```

Public projection keeps those fields, deep-copies window objects/arrays, and omits all auth tokens, account IDs, resource URLs, failed-token snapshots, generations, retry state, and internal transaction data. This intentionally narrows the internal QML object shape from the current denylist copy to an allowlist; it is not user-visible because source inspection confirms no view consumes the omitted fields.

## Chosen Architecture

Create `contents/ui/js/ProfileRegistry.js`, a pure module. It imports `QuotaCommon.js` only for existing path equality, default profile label, and default credential-path helpers. Visibility behaviour is injected rather than imported so I004 can replace it independently.

The module has two public interfaces:

```js
ProfileRegistry.transition(input) -> result
ProfileRegistry.editConfig(input) -> result
```

### Runtime transition interface

```js
input = {
    state: { profiles },
    event,
    config,
    visibility,
    nowMs
}
```

Supported events:

```js
{ type: "discovered", candidates }
{ type: "configurationChanged", keys }
{ type: "patch", profileId, expectedGeneration, patch }
{ type: "setHidden", profileId, hidden }
```

`expectedGeneration` is optional. When present, a patch is ignored unless the live row’s generic `refreshGeneration` matches. This is compatible with I002’s stable outcome application.

`config` is a snapshot of the relevant kcfg values:

```js
{
    multiProfileMode,
    provider,
    opencodeSubProvider,
    credentialsPath,
    displayName,
    discoverOnLoad,
    enabledProfilesJson,
    profileDisplayNamesJson,
    customProfilesJson,
    visibleWindowsJson
}
```

`visibility` is the I004-compatible adapter:

```js
{
    specFor(profile, visibleWindowsJson),
    apply(windows, spec, nowMs)
}
```

The production adapter initially wraps existing `QuotaCommon` visibility functions. Registry tests inject a deterministic substitute. I004 may replace the implementation without changing the registry interface.

`result` is:

```js
{
    state: { profiles },
    publicProfiles,
    effects,
    accepted
}
```

Effects are data for the controller to interpret:

```js
{ type: "discover" }
{ type: "refreshAll", manual: true }
{ type: "refresh", ids, manual: true }
{ type: "persist", values }
{ type: "warning", code, profileId }
```

The registry never starts discovery, refresh, timers, or configuration writes itself.

### KCM configuration-edit interface

```js
editConfig({ config, knownProfiles, event }) -> {
    config,
    patch
}
```

Supported events:

```js
{ type: "setEnabled", profileId, enabled }
{ type: "setName", profileId, name }
{ type: "addCustom", provider, path, credPath, displayName }
{ type: "removeCustom", profileId }
```

It owns the shared semantics for `[]`/`__none__` enablement, name trimming/removal, default credential paths, stable custom IDs, and custom enablement. KCM writes only returned `patch` values to cfg.

Visibility editing remains in the future I004 interface and is not added to `editConfig()` here.

## Internal Registry Model

### Metadata fields rebuilt from sources/config

```text
id, provider, profileKey, configDir, credPath, isFlatFile,
displayName, enabled, visibleWindowSpec
```

### Live fields preserved across same-ID reconciliation

I003 is implemented after I002. The preservation schema therefore uses post-I002 fields:

```text
loading, error, planName, bankedResets, windows, lastUpdate,
accessToken, accountId, resourceUrl, opencodeSlot,
refreshGeneration, backoffMultiplier, lastFetchMs,
authFailCount, authSuspended, autoRefreshHoldUntilMs,
lastFailedToken, credLoadManual
```

The schema is declared once in `ProfileRegistry.js`; blank-row creation, reconciliation, internal cloning, and public projection derive from that central declaration rather than separate caller lists.

### Public fields

```text
id, provider, configDir, credPath, displayName, enabled,
loading, error, planName, bankedResets, windows, lastFetchMs
```

`windows` is deep-copied one level into new row objects. No unknown internal field is copied by default.

## Transition Semantics

### `discovered`

1. Parse config with current safe fallbacks.
2. Apply legacy filtering/synthetic fallback or multi-profile custom append.
3. Resolve unique IDs in source order; first wins on malformed collision and emit warning.
4. Build metadata rows and configured visibility specs.
5. Match current rows by exact ID and preserve live fields.
6. Reapply visibility to preserved windows using injected adapter/current `nowMs`.
7. Produce explicit public snapshots.
8. Emit `refreshAll` when any enabled row is empty; otherwise no refresh effect.

Discovery success/error state remains controller orchestration, but successful candidates always cross this transition.

### `configurationChanged`

The module classifies all supplied keys and applies precedence:

- rediscover → emit `discover`, preserve state until discovery completes;
- membership/soft → clone rows, apply names/visibility and membership;
- empty registry with discovery enabled → emit `discover`;
- newly enabled empty rows → emit targeted `refresh`.

`main.qml` no longer knows or stores impact categories.

### `patch`

- Find by stable ID.
- If `expectedGeneration` is supplied and mismatched, return unchanged state with `accepted: false`.
- Clone the target/internal array, apply only the supplied patch, regenerate public snapshots, and return `accepted: true`.
- Unknown ID returns unchanged state and `accepted: false`.

### `setHidden`

- Use shared enablement rules to produce the persisted allowlist/sentinel.
- Apply membership immediately to the matching row.
- Return a `persist` effect for `enabledProfilesJson`.
- Re-enabling an empty/non-loading row emits targeted refresh.

## Controller and Caller Responsibilities

### `ProfileController.qml`

Retains:

- discovery executable adapter and discovery status/error;
- global refresh queue/timers and I002 transaction adapter;
- cfg value snapshot construction;
- interpreting registry effects;
- `profiles` and `publicProfiles` QML properties assigned from registry results.

Delegates:

- blank row construction;
- discovery/custom merge;
- live-state preservation;
- configuration impact/application;
- stable patch-by-ID;
- hide/show enablement serialization;
- safe public projection.

### `main.qml`

Removes dirty-category properties, `markConfigDirty()`, and `flushConfigDirty()`. Profile-related configuration signals notify a single controller method with the changed key; the controller/registry coalesces and classifies.

UI sync reads the controller’s already-safe `publicProfiles` property rather than calling a projection function that rebuilds caller knowledge.

### `configGeneral.qml`

Imports registry configuration editing for enabled profiles, names, and custom add/remove. It retains UI form state, discovery display, and visible-quota editing (until I004), but no longer implements allowlist/sentinel, stable custom-ID, name cleanup, or default credential-path rules independently.

### `discover-profiles.sh`

Remains the production discovery adapter unchanged. Its JSON array is one substitutable input to `transition({event:{type:"discovered"}})`.

## Rejected Alternatives

### Stateful `ProfileRegistry.qml`

A QML component could own reactive properties directly, but it would tie reconciliation tests to the currently unreliable Qt Quick test environment and make KCM reuse awkward. A pure core keeps production/QML and local tests on the same interface.

### Extract only `mergeDiscovered()` helpers

Moving row construction and copy loops into helpers would leave configuration categories, KCM semantics, snapshots, effects, and patch identity distributed. The deletion test would fail because most registry knowledge would remain at call sites.

### Use credential inode as runtime identity

The discovery script uses inode for deduplication, but current refresh/config/UI identity is exact profile ID. Switching identity to inode would change callback, custom-profile, and persisted-name/enablement semantics. I003 keeps exact ID and treats inode as discovery-adapter evidence only.

## Invariants

1. Every internal profile has one non-empty exact ID.
2. Registry state contains at most one row per ID.
3. No registry transition mutates input state, candidates, config, patches, or window objects.
4. Same-ID reconciliation preserves exactly the declared live fields and replaces source/config metadata.
5. Removed IDs disappear; new IDs receive the central blank schema.
6. Discovery/custom ordering is deterministic and preserved.
7. Runtime patching uses ID and optional generation, never array index.
8. Public snapshots contain only the explicit public allowlist.
9. Public window arrays and window objects do not alias internal arrays/objects.
10. Enablement `[]`, `__none__`, allowlist, hide/show, and KCM edit semantics are identical.
11. Name and custom-ID semantics are shared by runtime and KCM.
12. Visibility is reapplied at the same discovery/config points through the adapter.
13. Registry returns effects; it never performs I/O, timers, refresh, or cfg writes.
14. Invalid JSON uses current safe fallbacks and never throws across the interface.
15. Malformed duplicate IDs are deterministic and observable through warning effects.

## Error Handling

- Invalid names/custom/enabled JSON uses current empty/default fallback.
- Invalid custom entries without provider/path are ignored.
- Unknown patch/hide IDs return `accepted: false` and unchanged state.
- Generation mismatch returns `accepted: false` and unchanged state.
- Duplicate IDs retain first source-order row and emit a warning effect.
- Discovery process/JSON errors remain the production adapter/controller’s `discoveryError`; no registry state is replaced on failure.
- Visibility adapter failure is caught: preserve existing windows/visibility when available, emit a warning, and do not corrupt state.

## Testing Strategy

### Pure registry tests

Add deterministic Node tests for:

- blank row schema;
- new/same/removed ID reconciliation;
- post-I002 live-field preservation;
- metadata/config replacement;
- source/custom ordering;
- legacy filtering and synthetic fallback;
- custom credential path/default label;
- duplicate collision warning;
- no input mutation;
- refresh-all effect for any enabled empty row;
- soft/membership/rediscover impact and precedence;
- newly enabled targeted refresh;
- stable ID/generation patch acceptance/rejection;
- setHidden persistence and immediate state;
- explicit public allowlist and deep window copying;
- visibility adapter invocation and failure safety.

### Pure KCM config tests

Test `editConfig()` for:

- all enabled → `[]`;
- all disabled → `["__none__"]`;
- partial allowlist;
- discovered plus custom IDs;
- trimmed/removed names;
- stable custom IDs after removal/reload;
- default credential path and explicit override;
- removing custom without reusing IDs;
- malformed raw JSON fallback.

### Discovery adapter tests

Retain `tests/test-discovery.sh` for real filesystem scanning, inode deduplication, stable IDs, junk filtering, path preference, and output schema. Feed representative production-shaped discovery output and local fake candidates into identical registry tests.

### Integration/source contracts

Verify:

- `ProfileController` imports/calls the registry and contains no `blankProfileRow`, `mergeDiscovered`, `reapplyConfig`, `toUiProfile`, or index-based `updateProfile` lifecycle;
- `main.qml` contains no dirty-category knowledge;
- `configGeneral.qml` delegates enabled/name/custom rules;
- discovery executable adapter remains thin and unchanged;
- I002 transaction outcomes patch through registry ID/generation interface after P1.M2 completes.

Existing refresh, visibility, discovery, cache, layout, and Qt Quick tests remain regression gates.

## Migration Sequence

1. Implement central schema, clone, safe public projection, and patch-by-ID/generation tests.
2. Implement discovery/custom reconciliation, legacy rules, live-state preservation, visibility adapter, and effects.
3. Implement shared enabled/name/custom configuration editing and migrate KCM.
4. Integrate registry state/public snapshots/patching into post-I002 `ProfileController`.
5. Move config impact/coalescing from `main.qml` into controller/registry and migrate discovery/config effects.
6. Delete old registry choreography and run complete verification.

## Acceptance Criteria

- Production discovery and local candidate fixtures cross the same pure registry transition.
- Exact ID is the sole runtime identity; no patch/reconcile callback uses array index.
- Reconciliation preserves post-I002 live state and refreshes metadata/config once.
- Runtime and KCM share enabled/name/custom semantics.
- Main no longer knows rediscover/membership/soft categories.
- ProfileController no longer owns blank schema, merge/reapply copy loops, public snapshot denylist, or index-based patching.
- Public snapshots expose only the 12 currently consumed fields and deep-copy windows.
- Global refresh/discovery orchestration interprets registry effects without moving into the pure module.
- Visibility is an injected seam and raw migration/editing remains I004.
- I002 refresh, I005 cache, discovery shell, and existing UI behaviour remain intact.
- Pure registry/config tests, production discovery tests, and all existing regressions pass.
- No product code changes occur during planning/ingestion.

## Backlog Decomposition Direction

Create `P1.M3 — Profile Registry` under Architecture Deepening, dependent on completion of `P1.M2.E1.T006`, with one epic and six sequential tasks:

1. central schema, safe projection, and ID/generation patching;
2. discovery/custom reconciliation and effects;
3. shared profile configuration editing and KCM migration;
4. post-I002 controller store integration;
5. main/config impact and discovery-effect integration;
6. deletion test, cleanup, and full verification.

--- SUMMARY ---

- Add a pure `ProfileRegistry` with runtime `transition()` and KCM `editConfig()` interfaces.
- Centralise exact-ID identity, row schema, reconciliation, live-state preservation, configuration semantics, refresh effects, stable patching, and safe snapshots.
- Keep discovery filesystem work, refresh transport/scheduling, visibility migration, and cache outside the registry through explicit adapters/effects.
- Implement after I002 to avoid conflicting controller work and to preserve the final refresh-generation schema.
- Ingest six sequential TDD tasks; do not implement during this planning intake.
