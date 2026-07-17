# Visible Quota Configuration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace distributed visible-quota parsing, identity, catalogue, editing, persistence, and runtime application with one pure module shared by the KCM and I003 registry adapter.

**Architecture:** Add `VisibleQuotaConfig.configuration()`, `specFor()`, and `apply()` over one private compatibility/identity/default model. Migrate the KCM to the configuration projection/persistence effect and I003’s production adapter to opaque specs/cloned visibility, then delete the old `QuotaCommon`, KCM, and controller choreography while leaving I001 presentation and I003 lifecycle/time concerns intact.

**Tech Stack:** Qt 6 QML, QML-compatible ES5 JavaScript libraries, KDE KConfig/KCM bindings, Node.js ESM/VM tests, existing shell and Qt Quick tests.

## Global Constraints

- Follow `docs/superpowers/specs/2026-07-17-visible-quota-configuration-design.md` exactly.
- Do not begin until both `P1.M1.E1.T005` and `P1.M3.E1.T006` are done; this plan targets the future post-I001/post-I003 tree and is intentionally not executable against the current planning branch.
- Before Task 1, verify both dependency statuses and require the post-I002 `tests/helpers/load-qml-js.mjs` plus post-I003 `ProfileRegistry.js`/controller visibility-adapter seam. If any is absent, stop rather than recreating or guessing an upstream interface.
- Preserve valid `[]`/`{}`, legacy global array, flat global map, per-provider map, and per-provider array meanings.
- Preserve current provider-scoped identity and exact OpenCode slot/profile-key mapping.
- Preserve the built-in catalogue/defaults and runtime-observed unknown-window fallback.
- Do not eagerly rewrite configuration; emit persistence only for a supported KCM event or existing advanced-text assignment.
- Keep emitted JSON compatible with current/older readers; add no version envelope.
- Preserve per-provider unknown keys through unrelated KCM edits; provider reset and reset-all intentionally delete them.
- Keep I001 responsible for filtering, labels, ordering, colours, and rendering.
- Keep I003 responsible for application timing, generation safety, adapter-failure safety, profile state, and time percentages.
- Do not absorb discovery, credentials, transport, refresh scheduling, or response cache.
- Add no runtime/development dependency or network access to tests.
- Keep QML JavaScript compatible with `.pragma library`; do not add promises, classes, modules, or TypeScript syntax.
- Run tests serially or with at most two threads.
- Require explicit passing Qt output in a functioning environment; do not report a silent `qmltestrunner` exit as passing.

---

## File Structure

### Create

- `contents/ui/js/VisibleQuotaConfig.js` — pure compatibility, canonical identity/default model, KCM projection/events, opaque runtime specs, and immutable visibility application.
- `tests/test-visible-quota-config.mjs` — catalogue, migration, edit, reset, unknown-key, persistence, and idempotence tests.
- `tests/test-visible-quota-wiring.mjs` — KCM/runtime/deletion/source-contract regression.

### Modify

- `tests/test-visibility.mjs` — test runtime behaviour through `VisibleQuotaConfig.specFor()`/`apply()` rather than exporting old `QuotaCommon` helpers.
- `contents/ui/configGeneral.qml` — consume the KCM projection/persistence effect and remove local visibility policy.
- `contents/ui/ProfileController.qml` — make the post-I003 production visibility adapter delegate to the new module while retaining time calculation.
- `contents/ui/js/QuotaCommon.js` — delete obsolete visibility parsing/identity/application helpers after migration.
- `tests/test-profile-registry-controller.mjs` — require the production adapter delegation, opaque-spec non-inspection, and live config read.

### Reuse unchanged

- `contents/ui/js/ProfileRegistry.js` — continues to call the injected visibility adapter at discovery, configuration, and accepted usage-result transitions.
- `contents/ui/js/QuotaPresentation.js` and its callers/tests — continue to consume already-annotated windows.
- `contents/config/main.xml` — `visibleWindowsJson` remains a String with default `[]`.
- `tests/helpers/load-qml-js.mjs` — created by I002 and reused only after the dependency preflight confirms it exists.

---

### Task 1 (3h): Establish the Compatibility, Identity, and Runtime Interface

**Files:**
- Create: `contents/ui/js/VisibleQuotaConfig.js`
- Modify: `tests/test-visibility.mjs`
- Reuse: `tests/helpers/load-qml-js.mjs`

**Interfaces:**
- Produces: `specFor(profile, persisted) -> opaqueSpec`.
- Produces: `apply(windows, opaqueSpec) -> clonedWindows`.
- Keeps the opaque spec’s properties private to `VisibleQuotaConfig.js`.

- [ ] **Step 0: Verify the dependency-materialised implementation tree**

```bash
bl show P1.M1.E1.T005 --long | grep -q '^Status: done$'
bl show P1.M3.E1.T006 --long | grep -q '^Status: done$'
test -f tests/helpers/load-qml-js.mjs
test -f contents/ui/js/ProfileRegistry.js
rg -n 'visibility.*(specFor|apply)|specFor.*visibility|apply.*visibility' \
  contents/ui/ProfileController.qml contents/ui/js/ProfileRegistry.js
```

Expected: both backlog checks print/compare `done`, both post-I002/I003 files exist, and the final search identifies I003’s injected production visibility adapter/calls. If not, stop: subsequent commands intentionally target the dependency-materialised tree, not this planning branch.

- [ ] **Step 1: Replace the visibility test loader with the missing module interface**

In `tests/test-visibility.mjs`, use the shared loader and this setup:

```js
#!/usr/bin/env node
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const VQ = loadQmlJs(
    join(root, "contents/ui/js/VisibleQuotaConfig.js"), {},
    ["specFor", "apply"]
)

function visibleIds(windows) {
    return windows.filter(window => window.visible !== false)
        .map(window => window.id)
}

const claudeWindows = [
    { id: "5h", label: "5h", defaultVisible: true, visible: false },
    { id: "weekly", label: "7d", defaultVisible: true },
    { id: "weekly_fable", label: "Fable", defaultVisible: false }
]
const grokWindows = [
    { id: "session", label: "7d/build", defaultVisible: true },
    { id: "weekly", label: "mo", defaultVisible: true }
]
```

Add these exact compatibility assertions:

```js
for (const raw of [null, undefined, "", "[]", "{}", [], {}]) {
    assert.deepEqual(
        visibleIds(VQ.apply(claudeWindows, VQ.specFor({ provider: "claude" }, raw))),
        ["5h", "weekly"]
    )
}

assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" }, '["5h"]'))),
    ["5h"]
)
assert.deepEqual(
    visibleIds(VQ.apply(grokWindows,
        VQ.specFor({ provider: "grok" }, '["5h"]'))),
    []
)
assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" },
            '{"5h":true,"weekly":false}'))),
    ["5h"]
)
assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" },
            '{"claude":{"weekly_fable":true}}'))),
    ["5h", "weekly", "weekly_fable"]
)
assert.deepEqual(
    visibleIds(VQ.apply(grokWindows,
        VQ.specFor({ provider: "grok" },
            '{"claude":{"weekly":false}}'))),
    ["session", "weekly"]
)
assert.deepEqual(
    visibleIds(VQ.apply(claudeWindows,
        VQ.specFor({ provider: "claude" },
            '{"claude":["5h"]}'))),
    ["5h"]
)
```

Add exact provider identity cases:

```js
const identityCases = [
    [{ provider: "claude" }, "claude"],
    [{ provider: "codex" }, "codex"],
    [{ provider: "opencode", opencodeSlot: "anthropic" }, "claude"],
    [{ provider: "opencode", opencodeSlot: "openai" }, "codex"],
    [{ provider: "opencode", opencodeSlot: "kimi" }, "kimi"],
    [{ provider: "opencode", opencodeSlot: "zai" }, "zai"],
    [{ provider: "opencode", opencodeSlot: "future" }, "opencode"],
    [{ provider: "opencode", profileKey: "anthropic-accounts" }, "claude"],
    [{ provider: "opencode", profileKey: "openai" }, "codex"],
    [{ provider: "opencode", profileKey: "codex-work" }, "codex"],
    [{ provider: "opencode", profileKey: "kimi" }, "kimi"],
    [{ provider: "opencode", profileKey: "z-ai" }, "zai"],
    [{ provider: "opencode" }, "claude"]
]
for (const [profile, key] of identityCases) {
    const raw = JSON.stringify({ [key]: { dynamic: false } })
    const out = VQ.apply(
        [{ id: "dynamic", defaultVisible: true }],
        VQ.specFor(profile, raw)
    )
    assert.equal(out[0].visible, false, JSON.stringify(profile))
}
```

Add immutable/dynamic/error assertions:

```js
const source = [
    { id: "future", defaultVisible: false, visible: true, nested: { keep: true } },
    { id: "dup", defaultVisible: true },
    { id: "dup", defaultVisible: true }
]
const before = JSON.stringify(source)
const configured = VQ.apply(source, VQ.specFor(
    { provider: "claude" },
    '{"claude":{"future":true,"dup":false}}'
))
assert.deepEqual(visibleIds(configured), ["future"])
assert.equal(JSON.stringify(source), before)
assert.notEqual(configured, source)
assert.notEqual(configured[0], source[0])
assert.equal(configured[0].nested, source[0].nested)
assert.equal(configured.length, 3)
assert.deepEqual(VQ.apply("bad", VQ.specFor(null, "bad json")), [])
const foreignSpec = Object.freeze({
    implementationDetail: Object.freeze({ mode: "strict", weekly: false })
})
assert.deepEqual(VQ.apply(
    [null, { id: "x", defaultVisible: true }], foreignSpec),
    [{ id: "x", defaultVisible: true, visible: true }])

console.log("All visibility tests passed.")
```

- [ ] **Step 2: Run the test and verify the missing-module failure**

```bash
node tests/test-visibility.mjs
```

Expected: FAIL with `ENOENT` for `contents/ui/js/VisibleQuotaConfig.js`.

- [ ] **Step 3: Add the module and one shared private decoder/resolver**

Create `contents/ui/js/VisibleQuotaConfig.js` with this public skeleton:

```js
.pragma library

function specFor(profile, persisted) {
    var policy = decodePersisted(persisted)
    return {
        provider: canonicalProvider(profile),
        policy: policy
    }
}

function apply(windows, spec) {
    if (!Array.isArray(windows)) return []
    var usable = validSpec(spec) ? spec : {
        provider: "",
        policy: defaultsPolicy()
    }
    var selected = policyForProvider(usable.policy, usable.provider)
    var out = []
    for (var i = 0; i < windows.length; i++) {
        var source = windows[i]
        if (!source || typeof source !== "object" || Array.isArray(source))
            continue
        var copy = cloneOwn(source)
        copy.visible = effectiveVisible(source, selected)
        out.push(copy)
    }
    return out
}
```

Keep these private representations in the same file:

```js
{ mode: "defaults" }
{ mode: "strict", ids: { windowId: true } }
{ mode: "overrides", values: { windowId: boolean } }
{
    mode: "providers",
    byProvider: { provider: strictOrOverridesPolicy }
}
```

Implement `decodePersisted()` with the exact table from the design: empty values to defaults; non-empty arrays to strict global; flat scalar maps to sparse global; provider arrays to strict policies; provider maps to sparse policies; invalid JSON/root/nested entries ignored without throwing. Accept `__allowlist:true` on a provider map as strict and never expose it.

Implement `canonicalProvider()` in the exact current order:

```js
if (provider !== "opencode") return provider
if (!slot && profileKey contains "anthropic") slot = "anthropic"
else if (!slot && profileKey contains "openai" or "codex") slot = "openai"
else if (!slot && profileKey contains "kimi") slot = "kimi"
else if (!slot && profileKey contains "zai" or "z-ai") slot = "zai"
if (!slot) slot = "anthropic"
openai -> codex; anthropic -> claude; kimi -> kimi; zai -> zai;
other non-empty -> opencode
```

`effectiveVisible()` must ignore incoming `visible`; strict policies use exact ID membership, sparse policies use an own-key override, and all missing/default paths use `source.defaultVisible !== false`.

- [ ] **Step 4: Run the runtime interface tests**

```bash
node tests/test-visibility.mjs
```

Expected: prints `All visibility tests passed.` and exits `0`.

- [ ] **Step 5: Commit the runtime interface**

```bash
git add contents/ui/js/VisibleQuotaConfig.js tests/test-visibility.mjs
git commit -m "refactor(I004): centralize visible quota runtime policy"
```

---

### Task 2 (2h): Add the KCM Projection, Editing, and Idempotent Persistence

**Files:**
- Modify: `contents/ui/js/VisibleQuotaConfig.js`
- Create: `tests/test-visible-quota-config.mjs`
- Reference: `contents/ui/js/QuotaParsers.js`

**Interfaces:**
- Produces: `configuration({ persisted, event }) -> { persisted, changed, providers }`.
- Supported events: `set`, `resetProvider`, `resetAll`.
- Reuses Task 1’s private decoder, canonical provider keys, and default resolver.

- [ ] **Step 1: Write the failing configuration-interface test**

Create `tests/test-visible-quota-config.mjs` with this loader and helpers:

```js
#!/usr/bin/env node
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const VQ = loadQmlJs(
    join(root, "contents/ui/js/VisibleQuotaConfig.js"), {},
    ["configuration", "specFor", "apply"]
)
function provider(result, id) {
    return result.providers.find(entry => entry.provider === id)
}
function checked(result, providerId, windowId) {
    return provider(result, providerId).windows
        .find(window => window.id === windowId).checked
}
```

Assert the exact built-in order/defaults:

```js
const defaults = VQ.configuration({ persisted: "[]" })
assert.equal(defaults.changed, false)
assert.equal(defaults.persisted, "[]")
assert.deepEqual(defaults.providers.map(p => p.provider),
                 ["claude", "codex", "grok", "zai", "minimax", "kimi"])
assert.deepEqual(provider(defaults, "claude").windows.map(w => [w.id, w.checked]), [
    ["5h", true], ["weekly", true], ["weekly_fable", false],
    ["weekly_oracle", false], ["weekly_opus", false],
    ["weekly_sonnet", false], ["weekly_oauth_apps", false]
])
assert.deepEqual(provider(defaults, "codex").windows.map(w => [w.id, w.checked]), [
    ["session", true], ["weekly", true], ["credits", false],
    ["extra_spk_7d", false]
])
assert.deepEqual(provider(defaults, "grok").windows.map(w => [w.id, w.checked]), [
    ["session", true], ["weekly", true], ["on_demand", false]
])
assert.deepEqual(provider(defaults, "zai").windows.map(w => [w.id, w.checked]),
                 [["session", true], ["weekly", true]])
assert.deepEqual(provider(defaults, "minimax").windows.map(w => [w.id, w.checked]),
                 [["5h/general", true], ["wk/general", true]])
assert.deepEqual(provider(defaults, "kimi").windows.map(w => [w.id, w.checked]),
                 [["session", true], ["weekly", true], ["total_quota", false]])
```

Add an explicit parser/catalogue consistency red test. Load `QuotaCommon.js` and `QuotaParsers.js` with the same shared loader used by I002, then parse inline records that exercise every built-in ID:

```js
const QC = loadQmlJs(join(root, "contents/ui/js/QuotaCommon.js"), {}, [
    "formatWindowDuration", "makeWindow", "parseResetMs"
])
const QP = loadQmlJs(join(root, "contents/ui/js/QuotaParsers.js"), { QC }, [
    "parseClaude", "parseCodex", "parseGrok", "parseMinimax", "parseZai", "parseKimi"
])
const parsed = {
    claude: QP.parseClaude({
        five_hour: { utilization: 1 }, seven_day: { utilization: 2 },
        seven_day_fable: { utilization: 3 }, seven_day_oracle: { utilization: 4 },
        seven_day_opus: { utilization: 5 }, seven_day_sonnet: { utilization: 6 },
        seven_day_oauth_apps: { utilization: 7 },
        seven_day_future_model: { utilization: 8 }
    }),
    codex: QP.parseCodex({
        rate_limit: {
            primary_window: { used_percent: 1, reset_at: 1, limit_window_seconds: 18000 },
            secondary_window: { used_percent: 2, reset_at: 1, limit_window_seconds: 604800 }
        },
        additional_rate_limits: [{
            limit_name: "GPT-5.3-spark",
            rate_limit: { secondary_window: {
                used_percent: 3, reset_at: 1, limit_window_seconds: 604800
            }}
        }],
        credits: { unlimited: false, balance: "1.00" }
    }),
    grok: QP.parseGrok(
        { monthlyLimit: 10000, used: 1000, billingPeriodEnd: "2026-08-01T00:00:00Z" },
        { currentPeriod: { type: "USAGE_PERIOD_TYPE_WEEKLY",
                           end: "2026-07-24T00:00:00Z" },
          creditUsagePercent: 1, onDemandCap: 1000, onDemandUsed: 1 }),
    zai: QP.parseZai({ limits: [
        { type: "TOKENS_LIMIT", percentage: 1 },
        { type: "TIME_LIMIT", percentage: 2 }
    ]}),
    minimax: QP.parseMinimax({ model_remains: [{
        model_name: "general", current_interval_total_count: 10,
        current_interval_usage_count: 9, current_weekly_total_count: 10,
        current_weekly_usage_count: 8
    }]}),
    kimi: QP.parseKimi({
        usage: { limit: 10, used: 1 },
        limits: [{ window: { duration: 5, timeUnit: "HOUR" },
                   detail: { limit: 10, used: 1 } }],
        totalQuota: { used: 1 }
    })
}
for (const p of defaults.providers) {
    const actual = new Map(parsed[p.provider].windows.map(w => [w.id, w.defaultVisible]))
    for (const builtIn of p.windows) {
        assert.equal(actual.has(builtIn.id), true,
                     `${p.provider}/${builtIn.id} missing from parser fixture`)
        assert.equal(actual.get(builtIn.id), builtIn.checked,
                     `${p.provider}/${builtIn.id} default drift`)
    }
}
assert.equal(provider(defaults, "claude").windows.some(w =>
    w.id === "weekly_future_model"), false)
assert.equal(parsed.claude.windows.find(w =>
    w.id === "weekly_future_model").defaultVisible, false)
```

This contract compares canonical provider, exact ID, and `defaultVisible` only. KCM-friendly labels may intentionally differ from parser presentation labels (`OAuth apps` versus `OAuth`); label text is asserted by the catalogue projection test, not treated as parser drift. Dynamic IDs remain outside the built-in catalogue and are covered by Task 1’s runtime-authoritative fallback.

Assert event semantics and idempotence:

```js
const hiddenWeekly = VQ.configuration({
    persisted: "[]",
    event: { type: "set", provider: "claude", windowId: "weekly", visible: false }
})
assert.equal(hiddenWeekly.changed, true)
assert.equal(checked(hiddenWeekly, "claude", "weekly"), false)
assert.deepEqual(JSON.parse(hiddenWeekly.persisted), {
    claude: {
        "5h": true, weekly: false, weekly_fable: false,
        weekly_oracle: false, weekly_opus: false,
        weekly_sonnet: false, weekly_oauth_apps: false
    }
})
const repeated = VQ.configuration({
    persisted: hiddenWeekly.persisted,
    event: { type: "set", provider: "claude", windowId: "weekly", visible: false }
})
assert.equal(repeated.persisted, hiddenWeekly.persisted)
assert.deepEqual(repeated.providers, hiddenWeekly.providers)

const restored = VQ.configuration({
    persisted: hiddenWeekly.persisted,
    event: { type: "set", provider: "claude", windowId: "weekly", visible: true }
})
assert.equal(restored.persisted, "[]")
assert.equal(provider(restored, "claude").canReset, false)
```

Assert legacy migration and unknown preservation:

```js
const inspectedLegacy = VQ.configuration({ persisted: '["5h","weekly"]' })
assert.equal(inspectedLegacy.changed, false)
assert.equal(inspectedLegacy.persisted, '["5h","weekly"]')
assert.equal(checked(inspectedLegacy, "claude", "5h"), true)
assert.equal(checked(inspectedLegacy, "codex", "session"), false)
assert.equal(checked(inspectedLegacy, "minimax", "5h/general"), true)

const editedLegacy = VQ.configuration({
    persisted: '["5h","weekly"]',
    event: { type: "set", provider: "claude", windowId: "weekly", visible: false }
})
const migrated = JSON.parse(editedLegacy.persisted)
assert.equal(migrated.claude.weekly, false)
assert.equal(migrated.codex.weekly, true)
assert.equal(migrated.grok.weekly, true)
assert.equal(migrated.minimax, undefined)

const rawUnknown = JSON.stringify({
    claude: { future_model: true },
    future_provider: { quota: false }
})
const editedUnknown = VQ.configuration({
    persisted: rawUnknown,
    event: { type: "set", provider: "codex", windowId: "weekly", visible: false }
})
const unknownOut = JSON.parse(editedUnknown.persisted)
assert.equal(unknownOut.claude.future_model, true)
assert.equal(unknownOut.future_provider.quota, false)
assert.equal(unknownOut.codex.weekly, false)

const resetProvider = VQ.configuration({
    persisted: editedUnknown.persisted,
    event: { type: "resetProvider", provider: "claude" }
})
assert.equal(JSON.parse(resetProvider.persisted).claude, undefined)
assert.equal(JSON.parse(resetProvider.persisted).future_provider.quota, false)
const resetAll = VQ.configuration({
    persisted: editedUnknown.persisted,
    event: { type: "resetAll" }
})
assert.equal(resetAll.persisted, "[]")
```

Assert invalid/strict-provider behaviour:

```js
const invalid = VQ.configuration({ persisted: "{" })
assert.equal(invalid.changed, false)
assert.equal(invalid.persisted, "{")
assert.deepEqual(invalid.providers, defaults.providers)
const invalidEvent = VQ.configuration({
    persisted: rawUnknown,
    event: { type: "set", provider: "", windowId: "weekly", visible: false }
})
assert.equal(invalidEvent.changed, false)
assert.equal(invalidEvent.persisted, rawUnknown)

const strict = VQ.configuration({ persisted: '{"claude":["5h"]}' })
assert.equal(checked(strict, "claude", "5h"), true)
assert.equal(checked(strict, "claude", "weekly"), false)
assert.equal(checked(strict, "claude", "weekly_fable"), false)

console.log("All visible quota configuration tests passed.")
```

- [ ] **Step 2: Run the test and verify the missing-export failure**

```bash
node tests/test-visible-quota-config.mjs
```

Expected: FAIL because `configuration` is not defined/exported.

- [ ] **Step 3: Add the private catalogue and `configuration()`**

Add one private `CATALOG` in `VisibleQuotaConfig.js` in the exact order asserted above. Each window record is `{id,label,defaultVisible}` and each provider record is `{provider,title,windows}`. Use the labels currently in `configGeneral.qml`, including `7d`, `OAuth apps`, `credits $`, `Spark / 7d`, `session (product %)`, `mo ($ allowance)`, and `total quota`.

Add the public entry point:

```js
function configuration(input) {
    var request = input || {}
    var original = persistedText(request.persisted)
    var editor = editorDocument(decodePersisted(request.persisted))
    if (request.event !== undefined) {
        var edited = applyEditorEvent(editor, request.event)
        if (!edited.accepted)
            return configurationResult(editor, original, false)
        editor = edited.document
        return configurationResult(editor, serializeEditor(editor), true)
    }
    return configurationResult(editor, original, false)
}
```

`editorDocument()` must reproduce current KCM migration exactly:

- strict global allowlist: full known maps only for catalogue providers with at least one exact match;
- sparse global map: matching keys copied sparsely to every relevant provider;
- strict provider allowlist: listed IDs true, all missing known provider IDs false, unknown listed IDs retained true;
- sparse provider maps: known/unknown entries copied with Boolean coercion;
- provider maps absent from the catalogue retained privately and serialised unchanged.

`applyEditorEvent()` must:

- reject malformed events with `accepted:false`;
- on first `set` for a provider with no map, seed all known catalogue defaults;
- set the exact ID, including an unknown exact ID;
- delete a known provider map only when every known ID matches defaults and no unknown key exists;
- delete the complete provider map on `resetProvider`;
- clear every map on `resetAll`.

`configurationResult()` must clone catalogue/provider/window output and expose only `{provider,title,canReset,windows:[{id,label,checked}]}`. `serializeEditor()` emits `"[]"` for no maps and deterministic JSON provider maps otherwise. Never emit `__allowlist`.

- [ ] **Step 4: Run configuration and runtime tests**

```bash
node tests/test-visible-quota-config.mjs
node tests/test-visibility.mjs
```

Expected: both print passing footers and exit `0`.

- [ ] **Step 5: Commit the configuration interface**

```bash
git add contents/ui/js/VisibleQuotaConfig.js tests/test-visible-quota-config.mjs
git commit -m "refactor(I004): centralize visible quota configuration edits"
```

---

### Task 3 (2h): Route the KCM Through `configuration()`

**Files:**
- Modify: `contents/ui/configGeneral.qml`
- Create: `tests/test-visible-quota-wiring.mjs`
- Verify: `tests/test-visible-quota-config.mjs`

**Interfaces:**
- Consumes: `VQ.configuration({ persisted, event })`.
- Produces: one QML adapter that writes only `changed:true` results.

- [ ] **Step 1: Write the failing KCM source-contract test**

Create `tests/test-visible-quota-wiring.mjs`:

```js
#!/usr/bin/env node
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const kcm = readFileSync(join(root, "contents/ui/configGeneral.qml"), "utf8")

assert.match(kcm, /import "js\/VisibleQuotaConfig\.js" as VQ/)
assert.match(kcm, /property var visibleQuotaConfiguration:/)
assert.match(kcm, /function projectVisibleQuotaConfiguration\s*\(/)
assert.match(kcm, /function editVisibleQuotaConfiguration\s*\(/)
assert.match(kcm, /VQ\.configuration\s*\(/)
assert.match(kcm, /if \(result\.changed\)/)
assert.match(kcm, /cfg_visibleWindowsJson\s*=\s*result\.persisted/)
assert.match(kcm, /visibleQuotaConfiguration\.providers/)
assert.match(kcm, /editVisibleQuotaConfiguration\s*\(\s*\{/)
assert.doesNotMatch(kcm,
    /function\s+(hydrateVisibleByProvider|pushVisibleJson|setWindowVisible|resetProviderWindowDefaults)\s*\(/)

console.log("Visible quota KCM wiring passed.")
```

- [ ] **Step 2: Run the source contract and verify it fails**

```bash
node tests/test-visible-quota-wiring.mjs
```

Expected: FAIL because the KCM still imports only `QuotaCommon.js` and owns local visibility policy.

- [ ] **Step 3: Add the KCM adapter and projection state**

Add beside the existing JS imports:

```qml
import "js/VisibleQuotaConfig.js" as VQ
```

Replace `visibleByProvider` with:

```qml
property var visibleQuotaConfiguration: ({ providers: [] })

function projectVisibleQuotaConfiguration(raw) {
    visibleQuotaConfiguration = VQ.configuration({ persisted: raw })
}

function editVisibleQuotaConfiguration(event) {
    if (_hydrating) return
    var result = VQ.configuration({
        persisted: cfg_visibleWindowsJson,
        event: event
    })
    visibleQuotaConfiguration = result
    if (result.changed)
        cfg_visibleWindowsJson = result.persisted
}
```

In `hydrateFromCfg()`, replace local hydration with:

```qml
projectVisibleQuotaConfiguration(cfg_visibleWindowsJson)
```

Change the provider repeater to:

```qml
Repeater {
    model: configPage.visibleQuotaConfiguration.providers
```

The provider delegate consumes `modelData.provider`, `modelData.title`, `modelData.canReset`, and `modelData.windows`. The reset button is:

```qml
QQC2.Button {
    text: tr("Defaults")
    flat: true
    font: Kirigami.Theme.smallFont
    enabled: modelData.canReset
    onClicked: configPage.editVisibleQuotaConfiguration({
        type: "resetProvider",
        provider: modelData.provider
    })
}
```

Each checkbox is:

```qml
QQC2.CheckBox {
    required property var modelData
    text: modelData.label
    checked: modelData.checked
    onToggled: configPage.editVisibleQuotaConfiguration({
        type: "set",
        provider: provBlock.providerId,
        windowId: modelData.id,
        visible: checked
    })
}
```

Wire reset-all to `{type:"resetAll"}`. In the advanced JSON text area retain direct assignment and project without a configuration event:

```qml
onTextChanged: {
    cfg_visibleWindowsJson = text
    if (!_hydrating)
        configPage.projectVisibleQuotaConfiguration(text)
}
```

- [ ] **Step 4: Delete only the migrated KCM policy**

Remove complete definitions/references for:

```text
providerWindowCatalog
visibleByProvider
hydrateVisibleByProvider
catalogForProvider
pushVisibleJson
isWindowChecked
setWindowVisible
providerMapMatchesDefaults
resetWindowDefaults
resetProviderWindowDefaults
```

Remove visibility-only uses of `cloneMap`/`mapKeyCount`, but retain them if post-I003 KCM code still uses them for non-visibility form state.

- [ ] **Step 5: Run KCM/configuration regressions**

```bash
node tests/test-visible-quota-wiring.mjs
node tests/test-visible-quota-config.mjs
node tests/test-visibility.mjs
node tests/test-main-layout.mjs
```

Expected: all exit `0` with passing footers.

- [ ] **Step 6: Commit the KCM migration**

```bash
git add contents/ui/configGeneral.qml tests/test-visible-quota-wiring.mjs
git commit -m "refactor(I004): route KCM visibility through configuration seam"
```

---

### Task 4 (2h): Route I003’s Production Visibility Adapter Through the Module

**Files:**
- Modify: `contents/ui/ProfileController.qml`
- Modify: `tests/test-visible-quota-wiring.mjs`
- Modify: `tests/test-profile-registry-controller.mjs`
- Verify: `tests/test-profile-registry.mjs`

**Interfaces:**
- Precondition: the post-`P1.M3.E1.T006` tree contains `ProfileRegistry.transition()` calls to an injected `{specFor, apply}` object and a controller-created production adapter, whether I003 left that adapter inline or in an unnamed helper.
- Consumes: `VQ.specFor(profile, persisted)` and `VQ.apply(windows, spec)`.
- Preserves: I003 adapter `specFor(profile, visibleWindowsJson)` / `apply(windows, spec, nowMs)`.
- Preserves: `QC.updateTimePercent(window, nowMs)` in the production adapter, outside visibility policy.
- Produces: exact private controller helper `registryVisibilityAdapter()` by extracting/renaming the dependency-materialised adapter rather than assuming that name exists in the current pre-I003 source.

- [ ] **Step 1: Extend the source contract with runtime assertions**

Append to `tests/test-visible-quota-wiring.mjs`:

```js
const controller = readFileSync(
    join(root, "contents/ui/ProfileController.qml"), "utf8")
const registry = readFileSync(
    join(root, "contents/ui/js/ProfileRegistry.js"), "utf8")

assert.match(controller, /import "js\/VisibleQuotaConfig\.js" as VQ/)
assert.match(controller, /specFor:\s*function\s*\(profile,\s*persisted\)/)
assert.match(controller, /return VQ\.specFor\(profile,\s*persisted\)/)
assert.match(controller, /apply:\s*function\s*\(windows,\s*spec,\s*nowMs\)/)
assert.match(controller, /var projected\s*=\s*VQ\.apply\(windows,\s*spec\)/)
assert.match(controller, /QC\.updateTimePercent\(projected\[i\],\s*nowMs\)/)
assert.doesNotMatch(controller,
    /QC\.(parseVisibleWindowsConfig|visibilityProviderKey|visibilitySpecForProvider|applyVisibility)\s*\(/)
assert.match(registry, /visibility\.specFor\s*\(/)
assert.match(registry, /visibility\.apply\s*\(/)
const forbiddenSpecReads = []
for (const [name, source] of [
    ["ProfileController.qml", controller],
    ["ProfileRegistry.js", registry],
    ["configGeneral.qml", kcm]
]) {
    for (const match of source.matchAll(/\bspec\s*\.\s*[A-Za-z_$][\w$]*/g))
        forbiddenSpecReads.push(`${name}:${match[0]}`)
}
assert.deepEqual(forbiddenSpecReads, [],
                 "opaque visibility spec inspected outside VisibleQuotaConfig.js")

console.log("Visible quota runtime wiring passed.")
```

In `tests/test-profile-registry-controller.mjs`, require the accepted `usageResult` path to build a current config snapshot before invoking the registry and require the production adapter to delegate as above. Keep the existing adapter-failure assertions in `tests/test-profile-registry.mjs` unchanged.

- [ ] **Step 2: Run runtime wiring/registry tests and verify failure**

```bash
node tests/test-visible-quota-wiring.mjs
node tests/test-profile-registry-controller.mjs
node tests/test-profile-registry.mjs
```

Expected before migration: the first two fail because the production adapter still delegates to old `QuotaCommon` helpers; the pure registry adapter-substitution tests remain green.

- [ ] **Step 3: Import the module and replace the production adapter body**

Add to `contents/ui/ProfileController.qml`:

```qml
import "js/VisibleQuotaConfig.js" as VQ
```

First locate the concrete object that the dependency-materialised controller passes to I003 as the injected visibility adapter. If I003 left it inline or used another private helper name, extract/rename that existing object to `registryVisibilityAdapter()` and update its call sites; do not add a second adapter. Then use this exact body:

```qml
function registryVisibilityAdapter() {
    return {
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
}
```

The pre-I004 planning tree does not yet contain this factory; its absence before `P1.M3.E1.T006` is expected and is why Task 1 has a hard preflight. On the post-I003 tree, update every controller call site to the extracted `registryVisibilityAdapter()` name. Do not change `ProfileRegistry.transition()` or its failure handling.

Remove residual controller functions that parse or inspect raw visibility formats. The config snapshot continues supplying `visibleWindowsJson`, and the accepted generation-checked `usageResult` transition must continue reading that live snapshot before `visibility.specFor()`.

- [ ] **Step 4: Run runtime, registry, refresh, and presentation gates**

```bash
node tests/test-visible-quota-wiring.mjs
node tests/test-visible-quota-config.mjs
node tests/test-visibility.mjs
node tests/test-profile-registry.mjs
node tests/test-profile-registry-controller.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
node tests/test-quota-presentation.mjs
node tests/test-quota-presentation-wiring.mjs
node tests/test-main-quota-presentation.mjs
```

Expected: every present test exits `0` with a passing footer. The three I001 tests are guaranteed present because this milestone depends on `P1.M1.E1.T005`.

- [ ] **Step 5: Commit the runtime migration**

```bash
git add contents/ui/ProfileController.qml \
        tests/test-visible-quota-wiring.mjs \
        tests/test-profile-registry-controller.mjs
git commit -m "refactor(I004): route registry visibility through configuration seam"
```

---

### Task 5 (1h): Enforce the Deletion Test and Run Complete Verification

**Files:**
- Modify: `contents/ui/js/QuotaCommon.js`
- Modify: `tests/test-visible-quota-wiring.mjs`
- Modify: `tests/test-visibility.mjs` only for stale old-helper exports/comments
- Verify: complete project suite

**Interfaces:**
- Produces: one named visible-quota seam with no old parse/identity/edit/apply interface.
- Keeps: `visibleWindowsJson`, I001 presentation, I003 adapter, and `QC.updateTimePercent()`.

- [ ] **Step 1: Tighten the source-contract deletion assertions**

Append to `tests/test-visible-quota-wiring.mjs`:

```js
const common = readFileSync(
    join(root, "contents/ui/js/QuotaCommon.js"), "utf8")
for (const name of [
    "isWindowBoolMap", "parseVisibleWindowsConfig", "visibilityProviderKey",
    "visibilitySpecForProvider", "applyVisibility"
]) {
    assert.doesNotMatch(common, new RegExp(`function\\s+${name}\\s*\\(`),
                        `${name} deleted from QuotaCommon`)
}
for (const name of [
    "providerWindowCatalog", "visibleByProvider", "hydrateVisibleByProvider",
    "catalogForProvider", "pushVisibleJson", "isWindowChecked",
    "setWindowVisible", "providerMapMatchesDefaults",
    "resetWindowDefaults", "resetProviderWindowDefaults"
]) {
    assert.equal(kcm.includes(name), false, `${name} deleted from KCM`)
}
assert.match(controller, /registryVisibilityAdapter\s*\(/)
assert.match(controller, /VQ\.specFor\s*\(/)
assert.match(controller, /VQ\.apply\s*\(/)
assert.doesNotMatch(controller,
    /\.mode\s*===\s*"(?:defaults|globalAllowlist|globalMap|perProvider)"/)
assert.doesNotMatch(common, /function\s+objectKeyCount\s*\(/)
```

Delete `objectKeyCount()` with the visibility cluster. The pre-I004 source uses it only inside that cluster, and the post-I001 presentation module has no dependency on it.

- [ ] **Step 2: Verify the deletion test fails while old helpers remain**

```bash
node tests/test-visible-quota-wiring.mjs
```

Expected: FAIL on at least one old `QuotaCommon` visibility function.

- [ ] **Step 3: Delete obsolete common helpers and stale test choreography**

Remove the complete old functions from `contents/ui/js/QuotaCommon.js`:

```text
objectKeyCount
isWindowBoolMap
parseVisibleWindowsConfig
visibilityProviderKey
visibilitySpecForProvider
applyVisibility
```

Remove stale VM exports and “keep in sync with QuotaCommon” comments from `tests/test-visibility.mjs`; it must load only `VisibleQuotaConfig.js` for visibility policy.

Do not rename/remove `visibleWindowsJson`, the I003 adapter methods, `window.visible`, or I001 presentation functions.

- [ ] **Step 4: Run direct seam and whitespace checks**

```bash
if rg -n '\b(parseVisibleWindowsConfig|visibilityProviderKey|visibilitySpecForProvider|applyVisibility)\s*\(' \
    contents/ui --glob '!js/VisibleQuotaConfig.js'; then
    echo "old visible-quota policy remains outside the seam" >&2
    exit 1
fi
if rg -n '\b(providerWindowCatalog|visibleByProvider|hydrateVisibleByProvider|pushVisibleJson)\b' \
    contents/ui/configGeneral.qml; then
    echo "old KCM visible-quota choreography remains" >&2
    exit 1
fi
git diff --check
```

Expected: no old-policy matches and no whitespace errors.

- [ ] **Step 5: Run the complete serial regression suite**

```bash
node tests/test-visible-quota-config.mjs
node tests/test-visible-quota-wiring.mjs
node tests/test-visibility.mjs
node tests/test-quota-presentation.mjs
node tests/test-quota-presentation-wiring.mjs
node tests/test-main-quota-presentation.mjs
node tests/test-profile-registry.mjs
node tests/test-profile-registry-config.mjs
node tests/test-profile-registry-controller.mjs
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
node tests/test-account-card-layout.mjs
node tests/test-card-typography.mjs
node tests/test-main-layout.mjs
bash tests/test-path-utils.sh
bash tests/test-cache-response.sh
bash tests/test-discovery.sh
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_card_layout.qml \
  -import contents/ui -o -,txt
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_quota_presentation.qml \
  -import contents/ui -o -,txt
```

Expected: every Node/shell test exits `0`; both Qt commands explicitly report zero failures in a functioning Qt environment. If the host still produces the known silent Qt failure, record it as an environment blocker and obtain explicit Qt passing output before marking implementation complete.

- [ ] **Step 6: Review the behavioural matrix**

Confirm from test output that defaults, legacy strict global arrays, sparse global maps, sparse/strict provider forms, invalid raw text, every OpenCode mapping, dynamic unknown defaults/overrides, unknown-key edit preservation, reset deletion, no-write hydration, repeated-event idempotence, live usage-result application, and I001 presentation separation all pass.

- [ ] **Step 7: Commit deletion and final gates**

```bash
git add contents/ui/js/QuotaCommon.js tests/test-visibility.mjs \
        tests/test-visible-quota-wiring.mjs
git commit -m "refactor(I004): remove shallow visible quota choreography"
```

---

## Implementation Completion Gate

1. Confirm `P1.M1.E1.T005` and `P1.M3.E1.T006` were done before Task 1.
2. Run each task’s red test before implementation and green tests after it.
3. Confirm KCM/runtime use the same private decoder, canonical identity resolver, and default table.
4. Confirm inspection does not persist and event output is idempotent/current-reader compatible.
5. Confirm runtime-observed unknown windows and per-provider unknown persisted keys are preserved as specified.
6. Confirm `ProfileRegistry` still owns timing/effects/failure safety and `QuotaPresentation` still owns rendering policy.
7. Run the complete serial suite with explicit Qt results.
8. Run `git diff --check` and the direct deletion searches.
9. Review against `docs/superpowers/specs/2026-07-17-visible-quota-configuration-design.md`.

--- SUMMARY ---

- **Task 1 (3h):** create the shared compatibility/identity runtime module and refocus visibility tests on `specFor()`/`apply()`.
- **Task 2 (2h):** add the exact KCM catalogue projection, edit/reset events, unknown preservation, deterministic persistence, and idempotence tests.
- **Task 3 (2h):** replace KCM catalogue/hydration/edit/serialisation choreography with `configuration()`.
- **Task 4 (2h):** replace the post-I003 production adapter internals with opaque specs and cloned module application while retaining time calculation.
- **Task 5 (1h):** delete old helpers, enforce the seam, and run the full serial regression/Qt gates.
- Total implementation estimate is exactly **10 hours**; product implementation remains out of scope for this planning/ingestion work.
