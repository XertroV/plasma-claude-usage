# Visible Quota Configuration Design

**Backlog source:** I004 — Deepen visible-quota configuration  
**Date:** 17 July 2026  
**Status:** Approved for autonomous implementation planning; no product implementation is included in this document.

## Problem

Visible-quota configuration is one concept implemented as three collaborating helper clusters.

- `contents/ui/js/QuotaCommon.js` classifies four persisted shapes, resolves OpenCode identities, selects a provider policy, and clones windows with effective `visible` values.
- `contents/ui/configGeneral.qml` owns a second interpretation: the provider catalogue, defaults, legacy/global materialisation, checkbox projection, immutable-looking map edits, reset behaviour, and JSON serialisation.
- `contents/ui/ProfileController.qml` repeatedly parses raw `visibleWindowsJson`, resolves profile identity, stores a policy on profile rows, and reapplies it after discovery, configuration changes, and fetch success.

The raw JSON and several internal migration modes therefore act as the interface. Callers must know whether an array is strict, whether a map is global or provider-scoped, what a missing key means, how OpenCode maps to its underlying provider, and when a KCM edit converts a legacy value. `hydrateVisibleByProvider()` alone repeats enough policy to have cyclomatic complexity 21 and cognitive complexity 53.

I001 and I003 make this fragmentation more visible rather than absorbing it:

- I001’s `QuotaPresentation` must receive windows whose `visible` field is already correct. Presentation owns filtering, labels, ordering, and colour; it does not own persisted visibility intent.
- I003’s `ProfileRegistry` owns when current visibility is reapplied, through an injected `specFor(profile, visibleWindowsJson)` / `apply(windows, spec, nowMs)` adapter. It deliberately does not own raw formats, provider aliases, or visibility editing.

## Current Behaviour

### Persisted forms

`visibleWindowsJson` remains a string kcfg entry whose default is `"[]"`. Current readers accept a string or already-parsed value:

| Form | Runtime meaning |
|---|---|
| `null`, `undefined`, `""`, `[]`, `{}`, `"[]"`, `"{}"` | Every window uses `defaultVisible !== false`. |
| `["5h", "weekly"]` | Legacy strict global allowlist; every unlisted ID is hidden for every provider. |
| `{"5h":true,"weekly":false}` | Sparse global map; explicit values win and missing IDs use window defaults. |
| `{"claude":{"weekly":false}}` | Sparse per-provider map; missing providers and IDs use defaults. |
| `{"claude":["5h"]}` | Strict per-provider allowlist; unlisted Claude IDs are hidden. |

Scalar map values are coerced with `!!value`. Empty provider arrays/objects are ignored. The private `__allowlist` marker distinguishes an expanded strict provider array from a sparse map. Invalid JSON or an unsupported root shape falls back to defaults without throwing.

### Defaults and catalogue

Runtime defaults are window-authoritative: `window.defaultVisible !== false`. The KCM separately carries this built-in editing catalogue:

| Provider | Default on | Default off |
|---|---|---|
| Claude | `5h`, `weekly` | `weekly_fable`, `weekly_oracle`, `weekly_opus`, `weekly_sonnet`, `weekly_oauth_apps` |
| Codex | `session`, `weekly` | `credits`, `extra_spk_7d` |
| Grok | `session`, `weekly` | `on_demand` |
| Z.ai | `session`, `weekly` | — |
| MiniMax | `5h/general`, `wk/general` | — |
| Kimi | `session`, `weekly` | `total_quota` |

Dynamic parser windows can be absent from that catalogue. Runtime still honours a provider-specific advanced-JSON override for their exact IDs; otherwise it honours each observed window’s `defaultVisible`. Existing per-provider unknown keys survive unrelated KCM edits because the KCM copies them through its working map. They count as customisation and prevent the provider map collapsing to defaults. They are not rendered as checkboxes because the KCM has no runtime-observation channel.

### Provider identity

Configuration is provider-scoped, not profile-ID-scoped. Non-OpenCode `profile.provider` values are used unchanged. For `provider === "opencode"`:

1. `opencodeSlot` `anthropic`, `openai`, `kimi`, or `zai` maps to `claude`, `codex`, `kimi`, or `zai`.
2. With no slot, `profileKey` is inspected in current order: `anthropic`; then `openai`/`codex`; then `kimi`; then `zai`/`z-ai`.
3. An unresolved slot defaults to Anthropic/`claude`.
4. An unknown non-empty slot maps to `opencode`.

OpenCode has no independent KCM catalogue row; its rows share the underlying parser provider’s toggles.

### KCM migration and persistence

Opening the KCM hydrates an in-memory per-provider projection but does not write configuration.

- A legacy global allowlist produces a full Boolean map only for each built-in provider with at least one matching catalogue ID. Providers with no match stay on defaults so the migration does not blank them.
- A flat global map produces sparse provider maps containing matching catalogue IDs.
- A provider allowlist expands listed IDs to `true` and missing known catalogue IDs to `false`.
- A provider map keeps sparse and unknown keys.

The first checkbox/reset edit serialises that editor projection as per-provider Boolean maps, or `"[]"` when fully default. This one-way edit-time migration is existing behaviour. Advanced JSON text is written as typed and projected immediately; invalid text shows default checkboxes but remains untouched until another KCM edit canonicalises it.

## Goals

- Establish one pure, deep visible-quota configuration module shared by KCM and runtime.
- Give raw compatibility, canonical identity, catalogue/default, migration, edit, reset, serialisation, and window-application rules locality.
- Preserve every valid persisted form and its runtime meaning.
- Preserve current KCM load, edit-time migration, reset, advanced-JSON, and unknown-key behaviour.
- Keep migration internal, deterministic, and idempotent without introducing a version envelope.
- Keep I003’s adapter substitutable and I001’s presentation interface independent.
- Test compatibility and round trips through the new interface rather than private parsing modes.
- Delete the old helper choreography after both callers migrate.

## Non-goals

- Change which quota rows I001 presents, their order, labels, roles, colours, or layout.
- Change profile identity/lifecycle, discovery, reconciliation, configuration-impact timing, or safe snapshots owned by I003.
- Change provider parsing, credentials, refresh transactions/scheduling, generation checks, or response caching.
- Add profile-specific visibility; settings remain shared by canonical provider identity.
- Add a runtime-to-KCM catalogue transport or persist observed catalogue metadata.
- Change valid existing defaults or make existing extra quotas visible by default.
- Introduce a new persisted schema/version wrapper or eagerly rewrite existing values.
- Absorb time-percentage calculation; I003’s production adapter composes that existing concern after visibility application.
- Implement product changes during this planning intake.

## Alternatives Considered

### A. Three focused entry points over one private canonical model — chosen

Create `contents/ui/js/VisibleQuotaConfig.js` with:

```js
configuration({ persisted, event }) -> ConfigurationResult
specFor(profile, persisted) -> opaqueSpec
apply(windows, opaqueSpec) -> clonedWindows
```

`configuration()` is the KCM projection/edit interface. `specFor()` and `apply()` exactly fit I003’s approved substitutable adapter. All three use the same private parser, canonical identity resolver, default resolver, and editor document.

This has high depth: three operations hide four format families, strict/sparse semantics, provider identity, the catalogue, migration, editing, reset, serialisation, cloning, and dynamic-window fallback. The split follows actual caller workflows rather than exposing parsing helpers.

### B. Generic `transition(request)` plus `apply(request)`

An opaque reducer state and a broad event grammar could support hydration, raw replacement, catalogue observations, batch edits, and future commands. It offers flexibility and could grow dynamic catalogue metadata.

It is rejected for I004 because there is no real runtime-to-KCM observation adapter, batch editing is not required, and the event/state/diagnostic grammar would be a larger interface than current callers need. It would also force I003’s simple `specFor` adapter to wrap raw configuration and profile identity itself, leaving part of the canonical seam outside the module.

### C. Stateful QML editor/model with direct runtime application

A QML object could expose reactive provider rows, mutate checkbox state, write kcfg, and apply settings to runtime windows.

It is rejected because configuration writes and reactivity would couple the pure policy to one UI adapter, Node tests would not cross the production interface, and I003’s deterministic test adapter would be harder to preserve. It would also risk merging registry timing and configuration meaning.

## Chosen Deep Module

### Seam placement

The seam sits between persisted visibility intent and its two consumers:

```text
visibleWindowsJson
       │
       ▼
VisibleQuotaConfig private canonical model
       ├── configuration() ──► KCM provider/checkbox projection + persistence effect
       └── specFor()/apply() ──► I003 adapter ──► annotated runtime windows
                                                        │
                                                        ▼
                                             I001 QuotaPresentation
```

This is an in-process dependency. No external port is needed. The real adapters remain:

1. the KCM/kcfg adapter, which reads raw text and writes only returned persistence effects;
2. I003’s production visibility adapter, which calls `specFor()`/`apply()` and then applies existing time percentages;
3. I003’s deterministic test adapter, which does not need to implement persisted-format policy.

### Interface

#### `configuration()`

```js
configuration({
    persisted: visibleWindowsJson,
    event: optionalEvent
}) -> {
    persisted: string,
    changed: boolean,
    providers: [{
        provider: string,
        title: string,
        canReset: boolean,
        windows: [{
            id: string,
            label: string,
            checked: boolean
        }]
    }]
}
```

Supported events are exactly:

```js
{ type: "set", provider, windowId, visible }
{ type: "resetProvider", provider }
{ type: "resetAll" }
```

With no event, `configuration()` is an inspection: it returns the checkbox projection, `changed:false`, and the original string representation as `persisted`; the KCM does not write it. With a valid event, it returns the updated projection and deterministic compatible JSON. `changed:true` means “write this persistence effect”, including a semantically idempotent edit that canonicalises legacy input.

The projection deliberately does not expose format modes, normalized maps, `__allowlist`, raw provider maps, or default flags. Callers need only provider groups, checked values, and whether reset is available.

#### `specFor()`

```js
specFor(profile, persisted) -> opaqueSpec
```

The spec contains the decoded runtime policy and canonical provider identity, but its shape is not part of the interface. Callers may only retain it and pass it to `apply()`. Source-contract tests prohibit property inspection.

#### `apply()`

```js
apply(windows, opaqueSpec) -> clonedWindows
```

It recalculates `visible` on fresh shallow window copies. It does not filter, order, label, colour, compute time percentages, or mutate registry state.

I003’s production adapter remains:

```js
{
    specFor: function(profile, persisted) {
        return VQ.specFor(profile, persisted)
    },
    apply: function(windows, spec, nowMs) {
        var projected = VQ.apply(windows, spec)
        for (var i = 0; i < projected.length; i++)
            QC.updateTimePercent(projected[i], nowMs)
        return projected
    }
}
```

The registry still decides when to call the adapter and retains its existing adapter-failure safety.

## One Canonical Identity and Default Model

The implementation has one private decoder and one canonical provider resolver. `configuration()`, `specFor()`, and `apply()` may not maintain separate format or alias tables.

The built-in catalogue is also private data in this module. Its provider/window IDs and labels drive the KCM projection. Its default flags drive editor materialisation and “matches defaults” collapse. Runtime application uses the same known-default lookup when an observed ID is built in and otherwise uses `window.defaultVisible !== false`; tests require those values to agree for every built-in parser window.

This distinction preserves future/dynamic behaviour:

- a runtime-observed unknown window with a provider-specific persisted override uses that override;
- without an override, it uses its own `defaultVisible` value;
- an unrelated KCM edit preserves unknown keys already present in a per-provider map;
- an unknown key prevents that provider map from collapsing to defaults;
- no hidden singleton remembers runtime observations, because the KCM and applet can use different JS engines;
- advanced JSON remains the supported editor for unknown IDs.

## Migration and Persistence Semantics

No migration runs as an external step and no new persisted format is introduced.

1. Every call decodes the supplied persisted value into a private compatibility model.
2. `specFor()` retains the exact runtime semantics of the source form.
3. `configuration()` builds the current editor document from that model.
4. Inspection returns `changed:false`; migration alone never causes a write.
5. A KCM event mutates the editor document immutably and emits per-provider Boolean maps or `"[]"`.
6. Re-decoding emitted JSON and repeating the same event yields the same JSON and projection.

Required idempotence:

```text
C1 = configuration({ persisted: raw, event: E })
C2 = configuration({ persisted: C1.persisted, event: E })
C2.persisted === C1.persisted
C2.providers deep-equal C1.providers
```

For valid canonical per-provider input, unrelated provider edits preserve provider order, unknown providers, and unknown window keys. Resetting one provider intentionally deletes its complete known/unknown override map. Reset-all intentionally writes `"[]"`.

The old schema cannot represent a global rule plus provider exceptions. Therefore the first provider-specific edit of a global form keeps the current one-way KCM materialisation:

- known matching IDs are materialised across the built-in catalogue;
- providers with no matching legacy allowlist ID remain on defaults;
- global IDs absent from the built-in catalogue cannot be represented after that edit and are dropped, matching current KCM behaviour;
- hydration without an edit never drops or rewrites them.

Advanced JSON editing remains outside the event grammar: the text area assigns its text to `cfg_visibleWindowsJson`, then calls eventless `configuration()` for projection. Invalid text stays intact until a checkbox/reset event emits canonical defaults or overrides.

## Data Flow

### KCM

```text
cfg_visibleWindowsJson
    └── VQ.configuration({persisted})
          └── providers[].windows[].checked

checkbox/reset event
    └── VQ.configuration({persisted,event})
          ├── updated providers projection
          └── changed ? assign returned persisted : no write
```

`configGeneral.qml` retains QML form/layout state and the advanced JSON field. It loses catalogue, migration, map-edit, reset, and serialisation knowledge.

### Runtime

```text
I003 configuration snapshot + profile
    └── production adapter.specFor()
          └── VQ.specFor(profile, visibleWindowsJson)

I003 discovery/configuration/usage-result transition
    └── production adapter.apply(windows, opaqueSpec, nowMs)
          ├── VQ.apply() sets effective visibility on clones
          └── adapter applies QC.updateTimePercent()
```

At accepted usage-result commit, I003 continues re-reading live `visibleWindowsJson` before `specFor()`. There is no raw-policy cache.

### Presentation

`QuotaPresentation.presentProfile()` receives the resulting windows and remains the sole owner of visible-row filtering and presentation policy. `VisibleQuotaConfig` neither imports nor calls it.

## Error Behaviour

- Invalid JSON, unsupported roots, or invalid nested provider entries produce default runtime policy and a default KCM projection without throwing.
- Eventless inspection preserves the original invalid string and reports `changed:false`.
- A valid checkbox/reset event after invalid input starts from defaults and emits canonical JSON.
- Invalid/unknown events or missing event fields return the unchanged projection with `changed:false`.
- Unknown provider keys are valid in persisted per-provider maps and use observed window defaults at runtime.
- `specFor(null, raw)` resolves global rules where applicable and otherwise defaults; it does not throw.
- Non-array `windows` input returns `[]`.
- Null/non-object window entries are skipped; valid relative order and duplicate IDs are preserved.
- A foreign/malformed opaque spec falls back to defaults.
- I003 catches unexpected adapter implementation failures, preserves prior windows where available, and emits its existing warning effect.

## Invariants

1. All public operations are pure and deterministic for the same inputs.
2. No operation mutates persisted objects, profiles, events, arrays, or windows.
3. One private decoder defines all accepted formats and strict/sparse meaning.
4. One private resolver defines all provider/OpenCode identity semantics.
5. One private catalogue/default table defines KCM groups and known defaults.
6. Runtime application recomputes `visible`; an incoming `visible` value is never a default source.
7. Sparse missing IDs use the effective default; strict missing IDs are hidden.
8. Runtime-observed unknown IDs honour exact persisted overrides or their own `defaultVisible`.
9. KCM unrelated edits preserve per-provider unknown provider/window keys.
10. Inspection never writes; persistence occurs only from a supported event or direct advanced-text editing.
11. Event-produced JSON is compatible with current/older readers and idempotent.
12. OpenCode settings remain shared with the underlying parser provider.
13. Specs are opaque outside `VisibleQuotaConfig.js`.
14. I003 owns application timing, generation safety, state, and time percentages.
15. I001 owns filtering and presentation.
16. Refresh, discovery, credentials, cache, and I/O remain outside the module.

## Testing Strategy

### Pure compatibility and application tests

Refocus `tests/test-visibility.mjs` on the new interface and preserve its baseline cases. Add table-driven coverage for:

- every default/legacy/global/per-provider persisted form, including already-parsed values;
- strict versus sparse missing-ID behaviour;
- scalar Boolean coercion and internal allowlist compatibility;
- every direct and OpenCode provider identity path;
- malformed input fallback;
- sparse overrides that reveal extras without hiding primaries;
- live reapplication after configuration changes;
- dynamic/unknown window overrides and `defaultVisible` fallback;
- immutable clones, stable order, duplicate IDs, and malformed window handling;
- opaque-spec fallback.

### Configuration and round-trip tests

Add `tests/test-visible-quota-config.mjs` for:

- exact provider/window catalogue order, labels, and checked defaults;
- eventless no-write inspection;
- first edit materialisation from each legacy/global shape;
- provider arrays becoming strict full known maps;
- first provider edit seeding catalogue defaults;
- sparse editing, provider reset, reset-all, and collapse-to-default;
- per-provider unknown provider/window preservation across unrelated edits;
- intentional unknown-key deletion on provider reset;
- current unmapped-global loss only after an edit;
- invalid advanced text projection and later canonical edit;
- deterministic serialisation and repeated-event idempotence;
- no input mutation.

Load parser fixtures and assert every built-in catalogue ID/default agrees with `QuotaParsers.js`; dynamic parser IDs remain runtime-authoritative.

### Integration and deletion tests

Add `tests/test-visible-quota-wiring.mjs` to require:

- KCM imports `VisibleQuotaConfig.js` and consumes only `configuration()` projection/effects;
- the post-I003 production adapter delegates `specFor()` and visibility `apply()` while retaining time calculation;
- `ProfileRegistry.js` retains adapter invocation/failure behaviour and does not inspect specs;
- I001 presentation callers remain unchanged by I004;
- old visibility parsing/application functions are absent from `QuotaCommon.js`;
- old catalogue/hydration/edit/serialisation helpers are absent from `configGeneral.qml`;
- controller/registry callers contain no raw format-mode branching.

Retain all I001 presentation, I003 registry, parser/discovery, refresh, cache, layout, shell, and explicit Qt Quick gates.

## Migration Sequence

1. Characterise the compatibility matrix and provider identity through failing tests; add `VisibleQuotaConfig.specFor()` and `apply()`.
2. Add the private catalogue/editor document and test `configuration()` projection, events, migration, persistence, unknown preservation, and idempotence.
3. Route KCM provider rows, checkboxes, reset buttons, and advanced-text projection through `configuration()`.
4. Route I003’s production visibility adapter through `specFor()`/`apply()` while leaving time calculation and registry timing outside.
5. Tighten the deletion/source contracts, remove the old `QuotaCommon` and QML helper clusters, and run the complete serial suite.

## Acceptance Criteria

- KCM and runtime cross `VisibleQuotaConfig.js` and share one private compatibility, identity, catalogue/default, and migration implementation.
- Every currently valid persisted form retains its runtime meaning.
- Merely opening the KCM never rewrites configuration.
- First checkbox/reset edit reproduces current edit-time migration and produces compatible deterministic JSON.
- Repeating the same edit is idempotent.
- Direct advanced JSON remains supported, including invalid-text default projection without eager rewrite.
- All current provider defaults and OpenCode identity mappings remain exact.
- Runtime-observed unknown windows preserve exact provider overrides and otherwise use their own defaults.
- Per-provider unknown keys survive unrelated KCM edits and are intentionally removed only by their provider reset/reset-all.
- Runtime application returns fresh windows, preserves order/duplicates, and only annotates `visible`.
- I003 still owns when visibility is applied, adapter failure safety, generation checks, profile state, and time percentages.
- I001 still owns visible-row selection and presentation.
- No refresh, cache, discovery, credentials, transport, or filesystem work enters the module.
- Pure, round-trip, wiring, I001, I003, existing Node/shell, and explicit Qt gates pass.
- No product code changes occur during planning/ingestion.

## Deletion Test

After implementation, deleting `VisibleQuotaConfig.js` would force all of the following to reappear across KCM and runtime: persisted-shape discrimination, strict/sparse policy, OpenCode identity, catalogue/default lookup, legacy/global materialisation, unknown-key preservation, edits, reset, deterministic serialisation, and immutable visibility application. The module therefore earns its seam.

Conversely, successful integration deletes these shallow fragments:

- from `QuotaCommon.js`: `isWindowBoolMap`, `parseVisibleWindowsConfig`, `visibilityProviderKey`, `visibilitySpecForProvider`, and `applyVisibility` (plus `objectKeyCount` if no unrelated caller remains);
- from `configGeneral.qml`: `providerWindowCatalog`, `visibleByProvider`, `hydrateVisibleByProvider`, `catalogForProvider`, `pushVisibleJson`, `isWindowChecked`, `setWindowVisible`, `providerMapMatchesDefaults`, `resetWindowDefaults`, and `resetProviderWindowDefaults`;
- from controller integration: raw mode branching and the pre-I003 parsing/spec helper choreography.

The deletion test must not remove I001’s `QuotaPresentation`, I003’s visibility adapter seam, `QC.updateTimePercent()`, or the `visibleWindowsJson` kcfg entry.

--- SUMMARY ---

- Add pure `VisibleQuotaConfig.configuration()`, `specFor()`, and `apply()` interfaces over one private canonical model.
- Preserve every valid persisted form, current provider/OpenCode identity, built-in defaults, no-write hydration, and edit-time migration.
- Keep runtime-observed and persisted unknown windows safe without inventing a cross-engine catalogue transport.
- Make the KCM consume a checkbox projection/persistence effect and make I003’s production adapter consume opaque specs/cloned visibility results.
- Keep I001 presentation, I003 lifecycle/timing, refresh, and cache outside the module.
- Implement in five TDD slices, then delete the old `QuotaCommon`, KCM, and controller helper choreography.
