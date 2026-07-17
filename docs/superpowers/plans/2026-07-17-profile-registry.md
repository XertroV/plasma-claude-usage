# Profile Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace distributed profile identity/reconciliation/configuration/snapshot logic with one pure registry seam shared by runtime and KCM.

**Architecture:** `ProfileRegistry.transition()` owns runtime state transitions and effects; `ProfileRegistry.editConfig()` owns enabled/name/custom KCM edits. `ProfileController` interprets discovery/refresh/persist effects, I002 success enters a dedicated generation-checked `usageResult` transition, and views consume explicit safe public snapshots.

**Tech Stack:** Qt 6 QML, QML JavaScript libraries, Plasma executable DataSource, Node.js ESM/VM tests, existing shell and Qt Quick tests.

## Global Constraints

- Follow `docs/superpowers/specs/2026-07-17-profile-registry-design.md` exactly.
- Do not begin until `P1.M2.E1.T006` is done; this plan targets the post-I002 controller/schema.
- Preserve valid current legacy/multi-profile, ordering, enablement, naming, visibility, refresh-effect, and discovery behaviour.
- Preserve exact runtime identity by profile `id`; never patch by asynchronous array index.
- Keep filesystem discovery/dedup in `discover-profiles.sh`, refresh/scheduling in I002/controller, visibility format/editing in I004, and cache in I005.
- Add persisted monotonic `customProfileNextId`; this is the only intentional identity hardening.
- Public profiles expose only the 12 view-consumed fields and deep-copy windows.
- Add no dependency or network access to tests.
- Run tests serially or with at most two threads.
- Require explicit Qt test output in a functioning environment; the planning host’s existing `qmltestrunner` exits silently.

---

## File Structure

### Create

- `contents/ui/js/ProfileRegistry.js` — pure runtime transitions and KCM config edits.
- `tests/test-profile-registry.mjs` — schema, patch, usage-result, reconciliation, effect, snapshot tests.
- `tests/test-profile-registry-config.mjs` — enablement/name/custom config tests.
- `tests/test-profile-registry-controller.mjs` — controller/main/KCM seam source contract.

### Modify

- `contents/config/main.xml` — add `customProfileNextId`.
- `contents/ui/configGeneral.qml` — delegate enabled/name/custom edits.
- `contents/ui/ProfileController.qml` — registry state/effects/config coalescing/discovery integration.
- `contents/ui/main.qml` — remove config-impact category knowledge and consume controller public snapshots.

---

### Task 1: Centralise Schema, Public Projection, and Stable Patching

**Files:**
- Create: `contents/ui/js/ProfileRegistry.js`
- Create: `tests/test-profile-registry.mjs`
- Reuse: `tests/helpers/load-qml-js.mjs` from I002

**Interfaces:**
- Produces: `transition({ state, event, config, visibility, nowMs })` for `patch` and `usageResult` events.
- Produces: explicit internal/live/public field declarations.

- [ ] **Step 1: Write failing schema/patch/snapshot tests**

Create `tests/test-profile-registry.mjs` and load `QuotaCommon.js` plus the missing registry module. Use this internal profile:

```js
const internal = {
    id: "claude-work", provider: "claude", profileKey: "work",
    configDir: "/home/u/.claude-work", credPath: "/home/u/.claude-work/.credentials.json",
    isFlatFile: false, displayName: "Work", enabled: true,
    loading: true, error: "", planName: "Pro", bankedResets: 0,
    windows: [{ id: "5h", usagePercent: 10, visible: true }],
    lastUpdate: "10:00", lastFetchMs: 100,
    accessToken: "secret", accountId: "secret-account", resourceUrl: "secret-url",
    opencodeSlot: "", refreshGeneration: 7, backoffMultiplier: 1,
    authFailCount: 0, authSuspended: false, autoRefreshHoldUntilMs: 0,
    lastFailedToken: "secret-old", credLoadManual: false
}
```

Assert:

- patch by ID/generation clones state and leaves input unchanged;
- mismatched generation and unknown ID return `accepted:false` unchanged;
- public snapshot keys equal exactly:

```js
[
  "bankedResets", "configDir", "credPath", "displayName", "enabled", "error",
  "id", "lastFetchMs", "loading", "planName", "provider", "windows"
]
```

- public window array/object do not alias internal data;
- a `usageResult` event invokes `visibility.specFor()` and `visibility.apply()`, applies terminal patch/result, and rejects stale generation;
- visibility adapter failure preserves previous windows, applies non-window terminal state, and emits warning.

- [ ] **Step 2: Verify the test fails for the missing module**

```bash
node tests/test-profile-registry.mjs
```

Expected: FAIL with `ENOENT` for `ProfileRegistry.js`.

- [ ] **Step 3: Implement schema and transition skeleton**

Create `contents/ui/js/ProfileRegistry.js`:

```js
.pragma library
.import "QuotaCommon.js" as QC

var LIVE_FIELDS = [
    "loading", "error", "planName", "bankedResets", "windows", "lastUpdate",
    "accessToken", "accountId", "resourceUrl", "opencodeSlot",
    "refreshGeneration", "backoffMultiplier", "lastFetchMs", "authFailCount",
    "authSuspended", "autoRefreshHoldUntilMs", "lastFailedToken", "credLoadManual"
]
var PUBLIC_FIELDS = [
    "id", "provider", "configDir", "credPath", "displayName", "enabled",
    "loading", "error", "planName", "bankedResets", "windows", "lastFetchMs"
]

function transition(input) {
    var state = cloneState(input && input.state)
    var event = input && input.event ? input.event : {}
    if (event.type === "patch")
        return patchTransition(state, event)
    if (event.type === "usageResult")
        return usageResultTransition(state, event, input)
    return resultFor(state, [], false)
}
```

Implement pure `cloneObject`, `cloneWindows`, `cloneState`, `publicProfile`, `publicProfiles`, `resultFor`, ID lookup, patch, and usage-result helpers. Generic `patch` must not accept `usageResult`/raw windows as a substitute for the dedicated event.

The production visibility adapter contract used by the test is:

```js
{
  specFor(profile, rawVisibleConfig) { ... },
  apply(windows, spec, nowMs) { ... } // cloned visibility + time percentages
}
```

- [ ] **Step 4: Run the test**

```bash
node tests/test-profile-registry.mjs
```

Expected: PASS with explicit schema/patch/usage/snapshot assertions.

- [ ] **Step 5: Commit**

```bash
git add contents/ui/js/ProfileRegistry.js tests/test-profile-registry.mjs
git commit -m "refactor(I003): add profile registry schema and stable patching"
```

---

### Task 2: Implement Discovery and Custom Reconciliation

**Files:**
- Modify: `contents/ui/js/ProfileRegistry.js`
- Modify: `tests/test-profile-registry.mjs`
- Verify: `tests/test-discovery.sh`

**Interfaces:**
- Extends `transition()` with `{ type:"discovered", candidates }`.
- Produces deterministic rows, public snapshots, warning/refresh effects.

- [ ] **Step 1: Add failing reconciliation tests**

Cover:

- new/removed/same-ID rows;
- exact post-I002 live-field preservation and metadata replacement;
- discovery order followed by custom config order;
- custom default credential path/display-name hint;
- invalid custom entry ignored;
- first-wins duplicate ID + warning;
- no input/candidate/window mutation;
- any enabled empty row emits one `refreshAll` effect;
- visibility adapter invoked for preserved windows;
- legacy explicit startup `legacy-config` effective-provider/flat rules;
- legacy default startup `legacy-bootstrap` paths;
- later empty-discovery fallback `legacy-${configuredProvider}` semantics.

Use production-shaped local candidates with `credInode`, but do not invoke filesystem discovery from Node.

- [ ] **Step 2: Verify new tests fail**

```bash
node tests/test-profile-registry.mjs
```

Expected: FAIL because `discovered` is unsupported.

- [ ] **Step 3: Implement reconciliation**

Add private config JSON parsing, legacy mode/provider matching/path equality, custom materialisation, `blankRow`, exact-ID maps, duplicate guard, live-field preservation, visibility application, and effect calculation.

`blankRow` derives from the one schema declaration. Do not copy `credInode` into runtime/public rows; it remains discovery evidence. Preserve the current behaviour that soft name removal does not revert until rediscovery.

- [ ] **Step 4: Run registry and production discovery tests**

```bash
node tests/test-profile-registry.mjs
bash tests/test-discovery.sh
```

Expected: both exit `0`.

- [ ] **Step 5: Commit**

```bash
git add contents/ui/js/ProfileRegistry.js tests/test-profile-registry.mjs
git commit -m "refactor(I003): add deterministic profile reconciliation"
```

---

### Task 3: Share Profile Configuration Editing with the KCM

**Files:**
- Modify: `contents/ui/js/ProfileRegistry.js`
- Create: `tests/test-profile-registry-config.mjs`
- Modify: `contents/config/main.xml`
- Modify: `contents/ui/configGeneral.qml`

**Interfaces:**
- Produces: `editConfig({ config, knownProfiles, event }) -> { config, patch }`.
- Adds persisted `customProfileNextId`.

- [ ] **Step 1: Write failing config tests**

Test:

- all enabled serialises `[]`;
- all disabled serialises `["__none__"]`;
- partial selection serialises an ID allowlist across discovered/custom profiles;
- names trim and empty removes;
- add custom uses explicit/default cred path and enables/names it;
- allocator is `max(persistedNextId, highestExistingSuffix + 1)`;
- remove highest custom, reload config, then add never reuses ID;
- removal never decrements allocator;
- malformed JSON uses current fallbacks.

- [ ] **Step 2: Verify tests fail**

```bash
node tests/test-profile-registry-config.mjs
```

Expected: FAIL because `editConfig` is not exported.

- [ ] **Step 3: Add the persisted allocator**

In `contents/config/main.xml`, after `customProfilesJson`, add:

```xml
<entry name="customProfileNextId" type="Int">
    <label>Next monotonic custom profile id</label>
    <default>0</default>
</entry>
```

In `configGeneral.qml`, add:

```qml
property int cfg_customProfileNextId
import "js/ProfileRegistry.js" as Registry
```

- [ ] **Step 4: Implement and wire `editConfig()`**

Implement events `setEnabled`, `setName`, `addCustom`, and `removeCustom`. Replace KCM implementations of enabled allowlist/sentinel, name map, custom ID/default credential path, and custom add/remove with calls to `Registry.editConfig()` and assignments from returned `patch`.

Keep visible-quota functions untouched for I004. Keep discovery display/form validation in QML.

- [ ] **Step 5: Run config/KCM-adjacent gates**

```bash
node tests/test-profile-registry-config.mjs
node tests/test-profile-registry.mjs
node tests/test-visibility.mjs
bash tests/test-discovery.sh
```

Expected: all exit `0`.

- [ ] **Step 6: Commit**

```bash
git add contents/ui/js/ProfileRegistry.js tests/test-profile-registry-config.mjs \
        contents/config/main.xml contents/ui/configGeneral.qml
git commit -m "refactor(I003): share profile configuration editing"
```

---

### Task 4: Integrate Registry State into the Post-I002 Controller

**Files:**
- Modify: `contents/ui/ProfileController.qml`
- Create: `tests/test-profile-registry-controller.mjs`
- Modify: `tests/test-profile-registry.mjs` for any integration-shaped fixture

**Interfaces:**
- Consumes: registry transition/edit interfaces.
- Produces: controller `profiles` and `publicProfileList`, effect interpreter, ID/generation patch integration.

- [ ] **Step 1: Write failing controller seam assertions**

Require:

```js
assert.match(src, /import "js\/ProfileRegistry\.js" as Registry/)
assert.match(src, /property var publicProfileList:/)
assert.match(src, /function applyRegistryResult\s*\(/)
assert.match(src, /function registryConfigSnapshot\s*\(/)
assert.match(src, /type:\s*"usageResult"/)
```

Require I002 terminal success to call registry `usageResult`, other transitions to call registry `patch`, both with stable profile ID/generation.

- [ ] **Step 2: Verify source test fails**

```bash
node tests/test-profile-registry-controller.mjs
```

Expected: FAIL because controller still owns its store/reconciliation functions.

- [ ] **Step 3: Add registry result/effect adaptation**

Add registry import and a single `applyRegistryResult(result)` that assigns internal/public arrays, increments `dataEpoch` once for accepted state change, then interprets effects:

```qml
switch (effect.type) {
case "discover": discoverProfiles(); break
case "refreshAll": staggerRefreshAll(); break
case "refresh": queue each stable id then kickRefreshQueue(); break
case "persist": assign supported plasmoid.configuration values; break
case "warning": console.log registry warning; break
}
```

Build `registryConfigSnapshot()` from exact kcfg keys and a production visibility adapter wrapping current `QuotaCommon` functions/time update.

- [ ] **Step 4: Route I002 outcomes through registry**

Success uses:

```qml
{ type: "usageResult", profileId, expectedGeneration: generation,
  usageResult, patch }
```

Started/credentials/failure transitions use generic `patch`. Remove any post-I002 controller success code that directly applies raw windows outside the registry.

- [ ] **Step 5: Make UI sync consume `publicProfileList`**

Retain `profiles` for internal scheduling/refresh. Replace `publicProfiles()` calls with the already-generated `publicProfileList` property.

- [ ] **Step 6: Run registry, I002, and source tests**

```bash
node tests/test-profile-registry.mjs
node tests/test-profile-registry-config.mjs
node tests/test-profile-registry-controller.mjs
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
```

Expected: all exit `0`.

- [ ] **Step 7: Commit**

```bash
git add contents/ui/ProfileController.qml \
        tests/test-profile-registry.mjs tests/test-profile-registry-controller.mjs
git commit -m "refactor(I003): integrate registry state into controller"
```

---

### Task 5: Move Config Impact and Discovery Effects Behind the Seam

**Files:**
- Modify: `contents/ui/ProfileController.qml`
- Modify: `contents/ui/main.qml`
- Modify: `tests/test-profile-registry.mjs`
- Modify: `tests/test-profile-registry-controller.mjs`

**Interfaces:**
- Extends runtime events with `configurationChanged`, `setHidden`, and controller discovery success.
- Removes rediscover/membership/soft knowledge from main.

- [ ] **Step 1: Add failing impact/effect tests**

Pure tests cover exact key map and precedence, membership/soft cloning, newly enabled empty refresh IDs, empty-registry discovery effect, setHidden persistence/immediate state, and no I/O inside registry.

Source test requires main to contain no `configDirtyRediscover`, `configDirtyMembership`, `configDirtySoft`, `markConfigDirty`, `flushConfigDirty`, or literal category strings.

- [ ] **Step 2: Verify tests fail**

```bash
node tests/test-profile-registry.mjs
node tests/test-profile-registry-controller.mjs
```

- [ ] **Step 3: Implement configuration and hidden transitions**

Add registry classification/precedence and transitions. Move coalescing state/timer into `ProfileController`; configuration Connections call one `noteRegistryConfigChanged(key)` method. Main no longer classifies.

Route `setProfileHidden()` through `setHidden`; interpret its persist/refresh effects.

- [ ] **Step 4: Route discovery success through registry**

Keep executable process/error parsing unchanged. On valid list, call the `discovered` transition. Discovery failure must leave registry state unchanged and continue updating `discoveryError`.

- [ ] **Step 5: Run impact/discovery/UI source gates**

```bash
node tests/test-profile-registry.mjs
node tests/test-profile-registry-controller.mjs
bash tests/test-discovery.sh
node tests/test-main-layout.mjs
```

Expected: all exit `0`.

- [ ] **Step 6: Commit**

```bash
git add contents/ui/ProfileController.qml contents/ui/main.qml \
        tests/test-profile-registry.mjs tests/test-profile-registry-controller.mjs
git commit -m "refactor(I003): move profile lifecycle effects behind registry"
```

---

### Task 6: Delete Registry Choreography and Run Full Verification

**Files:**
- Modify: `contents/ui/ProfileController.qml`
- Modify: `contents/ui/configGeneral.qml`
- Modify: `tests/test-profile-registry-controller.mjs`
- Verify: full project suite

- [ ] **Step 1: Tighten the deletion test**

Require no controller functions:

```text
blankProfileRow, mergeDiscovered, reapplyConfig, cloneProfile,
toUiProfile, publicProfiles, updateProfile, isUiSecretKey
```

Require no duplicated KCM enabled/name/custom ID helper implementation, while visible-quota helpers remain until I004. Require discovery script unchanged.

- [ ] **Step 2: Remove dead code and stale comments**

Delete old merge/reapply/snapshot/store helpers and duplicate KCM profile-config helpers. Retain orchestration, discovery adapter, I002 refresh transaction, visibility adapter, and cache pipeline.

- [ ] **Step 3: Run the complete serial suite**

```bash
node tests/test-profile-registry.mjs
node tests/test-profile-registry-config.mjs
node tests/test-profile-registry-controller.mjs
node tests/test-profile-refresh-providers.mjs
node tests/test-profile-refresh.mjs
node tests/test-profile-refresh-controller.mjs
node tests/test-visibility.mjs
for test in tests/test-quota-presentation.mjs tests/test-quota-presentation-wiring.mjs tests/test-main-quota-presentation.mjs; do
  if [ -f "$test" ]; then node "$test"; fi
done
node tests/test-account-card-layout.mjs
node tests/test-card-typography.mjs
node tests/test-main-layout.mjs
bash tests/test-path-utils.sh
bash tests/test-cache-response.sh
bash tests/test-discovery.sh
```

In a functioning Qt environment:

```bash
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  qmltestrunner -input tests/tst_card_layout.qml -import contents/ui -o -,txt
```

- [ ] **Step 4: Run direct seam/whitespace checks**

```bash
if rg -n '\b(blankProfileRow|mergeDiscovered|reapplyConfig|toUiProfile|publicProfiles|updateProfile)\s*\(' \
  contents/ui/ProfileController.qml; then
  echo "old registry lifecycle remains" >&2
  exit 1
fi
git diff --check
```

Expected: no old lifecycle matches and no whitespace errors.

- [ ] **Step 5: Review acceptance criteria**

Confirm exact-ID/generation safety, all legacy IDs, post-I002 live preservation, refresh-success visibility/time application, enabled/name/custom parity, durable custom allocator, safe 12-field snapshots, effects, discovery substitution, and scope boundaries.

- [ ] **Step 6: Commit**

```bash
git add contents/ui/ProfileController.qml contents/ui/configGeneral.qml \
        tests/test-profile-registry-controller.mjs
git commit -m "refactor(I003): remove shallow profile registry choreography"
```

---

## Implementation Completion Gate

1. Confirm `P1.M2.E1.T006` was done before starting.
2. Run each task’s red/green tests with explicit output.
3. Verify no mutation/index identity crosses the registry seam.
4. Verify I002 success cannot bypass registry visibility/time application.
5. Verify custom IDs never reuse after removal/reload.
6. Run all present Node/shell tests and explicit Qt tests where supported.
7. Review against `docs/superpowers/specs/2026-07-17-profile-registry-design.md`.

--- SUMMARY ---

- **Task 1:** central schema, public snapshots, stable patch and usage-result transitions.
- **Task 2:** discovery/custom reconciliation, legacy identities, live-state preservation, and effects.
- **Task 3:** shared enabled/name/custom KCM editing plus durable custom-ID config.
- **Task 4:** post-I002 controller store and outcome integration.
- **Task 5:** registry-owned config impact, hidden transitions, and discovery effects.
- **Task 6:** deletion test, cleanup, and full verification.
- Implementation remains out of scope for this planning/ingestion work.
