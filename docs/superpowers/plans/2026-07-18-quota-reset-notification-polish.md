# Quota-Reset Notification Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make **Send test celebration** deliver the desktop notification and invoke every polished card effect on one randomly selected visible account, without creating fake reset history.

**Architecture:** A pure JavaScript module defines versioned request validation, freshness/replay policy, and deterministic eligible-card selection. A secure shell adapter atomically writes/takes one transient request across the KCM/widget process seam. `ProfileController` consumes a claimed request and calls the existing production celebration-generation seam directly; `AccountCard` renders a deterministic progress-based choreography with an injectable reduced-motion branch.

**Tech Stack:** Plasma 6 QML, QtQuick/Kirigami, Plasma5Support executable `DataSource`, QML JavaScript loaded by Node tests, Bash, Qt Test, offscreen QML raster capture.

## Global Constraints

- Real reset detection, notification, logging, matching-profile behaviour, classification, and copy remain unchanged.
- The Settings path sends a notification and runs the full visible celebration, but never calls reset detection or reset logging and never creates reset-history artifacts.
- Consume requests at most once. Ignore malformed, unsupported, stale, future-skewed, and replayed requests.
- Use `$XDG_RUNTIME_DIR/plasma-claude-usage` when available, otherwise `${XDG_CACHE_HOME:-$HOME/.cache}/plasma-claude-usage/runtime`; do not use the configurable response-cache/reset-log tree.
- The bridge directory is mode `0700`; payload/claim files are mode `0600`; writers use temporary files plus atomic rename; consumers atomically claim before output/removal.
- Selection uses enabled profiles in public-list order within the union of the compact/full limits; disabled and overflow-only accounts are ineligible.
- If no eligible card exists, notification delivery succeeds and the consumed request becomes a safe animation no-op.
- Every mounted compact/full representation of the selected profile receives the same generation; other profiles do not.
- Reduced motion keeps colour, border, wash, and glyph feedback but forces translation to `0` and scale to `1`.
- Bind production reduced motion to the verified Plasma convention `Kirigami.Units.longDuration <= 0`; retain an injectable property for deterministic tests.
- Use Kirigami duration tokens rather than unrelated hard-coded overall durations. Keep lateral movement bounded and damped.
- Preserve live theme bindings after completion or interrupted re-trigger.
- No test/build command may use more than two threads; this project’s tests run serially.

## File Structure

- `contents/ui/js/TestCelebrationRequests.js`: pure request, freshness/replay, eligibility, and deterministic random-selection policy.
- `contents/scripts/test-celebration-bridge.sh`: secure, atomic `write`/`take` process adapter.
- `contents/ui/configGeneral.qml`: independent notification + bridge producer.
- `contents/ui/ProfileController.qml`: request consumer and production celebration seam.
- `contents/ui/js/CelebrationMotion.js`: pure progress-to-visual-state choreography.
- `contents/ui/AccountCard.qml`: QML renderer/animator for the pure choreography.
- `contents/ui/CardsView.qml`, `contents/ui/main.qml`: shared card-limit and reduced-motion propagation.
- `tests/visual/tst_celebration_visual.qml`: deterministic QML raster fixture.
- `.visual-review/`: ignored generated raster evidence and crop zooms.

---

### Task 1: Pure Request and Selection Contract

**Files:**
- Create: `contents/ui/js/TestCelebrationRequests.js`
- Create: `tests/test-test-celebration-requests.mjs`
- Reuse: `tests/helpers/load-qml-js.mjs`

**Interfaces:**
- Produces: `createRequest(nowMs, nonceFactory) -> object`
- Produces: `serializeRequest(request) -> string`
- Produces: `consume(raw, state, nowMs) -> { accepted, reason, request, state }`
- Produces: `eligibleProfileIds(profiles, limits) -> string[]`
- Produces: `selectProfileId(profiles, limits, randomFn) -> string`
- Constants: schema `{version: 1, type: "test-celebration", createdAtMs, nonce}`, `MAX_AGE_MS = 15000`, `MAX_FUTURE_SKEW_MS = 2000`.

- [ ] **Step 1: Write the failing pure-policy tests**

Cover exact schema/serialisation, deterministic nonce injection, malformed JSON, wrong version/type, missing/oversized nonce, non-finite timestamp, 15-second freshness boundary, 2-second future boundary, replay rejection, replay-state pruning, disabled exclusion, union limit `max(8, 12)`, index ≥12 exclusion, empty eligibility, and clamped random values (`0`, `0.999`, `<0`, `>=1`, `NaN`). Assert inputs are not mutated.

```js
const first = Requests.createRequest(NOW, () => "nonce-1")
assert.deepEqual(first, {
  version: 1, type: "test-celebration", createdAtMs: NOW, nonce: "nonce-1"
})
assert.equal(Requests.consume(JSON.stringify(first), {}, NOW).accepted, true)
assert.equal(Requests.consume(JSON.stringify(first), { "nonce-1": NOW }, NOW).reason, "replay")
assert.deepEqual(
  Requests.eligibleProfileIds(profiles, { compactMaxCards: 8, fullMaxCards: 12 }),
  profiles.slice(0, 12).filter(p => p.enabled !== false).map(p => p.id)
)
```

- [ ] **Step 2: Verify RED**

Run: `node tests/test-test-celebration-requests.mjs`

Expected: FAIL because `contents/ui/js/TestCelebrationRequests.js` does not exist.

- [ ] **Step 3: Implement the pure contract**

Use `.pragma library` and ES5-compatible QML JavaScript. Validation returns explicit reasons (`empty`, `malformed`, `schema`, `nonce`, `timestamp`, `stale`, `future`, `replay`) and a pruned copied state. `eligibleProfileIds` first filters enabled/id-bearing profiles, then takes the first `Math.max(compactMaxCards, fullMaxCards)` enabled entries. `selectProfileId` injects randomness and clamps its result before computing an index.

- [ ] **Step 4: Verify GREEN**

Run: `node tests/test-test-celebration-requests.mjs`

Expected: all request/selection checks pass.

- [ ] **Step 5: Commit**

```bash
git add contents/ui/js/TestCelebrationRequests.js tests/test-test-celebration-requests.mjs
git commit -m "feat: define test celebration request contract"
```

---

### Task 2: Secure Atomic Process Bridge

**Files:**
- Create: `contents/scripts/test-celebration-bridge.sh`
- Create: `tests/test-test-celebration-bridge.sh`

**Interfaces:**
- Consumes: JSON payload on stdin for `write`.
- Produces: `test-celebration-bridge.sh write` atomically replaces `request.json`.
- Produces: `test-celebration-bridge.sh take` atomically claims, prints, and removes at most one request; a missing request exits `0` with no output.

- [ ] **Step 1: Write failing shell tests**

Use isolated temporary `HOME`, `XDG_RUNTIME_DIR`, and `XDG_CACHE_HOME`. Assert round-trip equality; directory/file modes; second write replacement; empty/malformed/non-object/oversized payload rejection; no configurable cache-root dependency; missing take silence; and exactly one non-empty output across two concurrent `take` processes.

```bash
printf '%s' "$PAYLOAD" | "$BRIDGE" write
actual="$($BRIDGE take)"
[ "$actual" = "$PAYLOAD" ]
[ "$(stat -c %a "$XDG_RUNTIME_DIR/plasma-claude-usage")" = 700 ]
```

- [ ] **Step 2: Verify RED**

Run: `bash tests/test-test-celebration-bridge.sh`

Expected: FAIL because the bridge script is absent.

- [ ] **Step 3: Implement `write` and `take`**

Use `set -euo pipefail`, `umask 077`, `mkdir -p`, `chmod 700`, a bounded stdin read, and `python3 -c` only if available; otherwise validate the schema in the pure consumer and require non-empty object-looking JSON in the adapter. `write` creates a temp file inside the destination, installs mode `0600`, then `mv -f`s it. `take` atomically `mv`s `request.json` to `claim.$$`; only the winning process prints/removes its claim. Install cleanup traps for temporary/claim files.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test-test-celebration-bridge.sh`

Expected: all bridge, permissions, replacement, and single-consumer checks pass.

- [ ] **Step 5: Commit**

```bash
git add contents/scripts/test-celebration-bridge.sh tests/test-test-celebration-bridge.sh
git commit -m "feat: add atomic test celebration bridge"
```

---

### Task 3: Settings Notification and Request Producer

**Files:**
- Modify: `contents/ui/configGeneral.qml` (`sendTestQuotaResetNotification()`, Settings button, executable DataSources)
- Create: `tests/test-test-celebration-kcm-wiring.mjs`

**Interfaces:**
- Consumes: Task 1 `createRequest()`/`serializeRequest()`.
- Consumes: Task 2 `test-celebration-bridge.sh write`.
- Produces: `sendTestCelebration()` with independent notification and bridge attempts.

- [ ] **Step 1: Write failing KCM wiring tests**

Structurally assert the request-module import, resolved bridge path, button call to `sendTestCelebration()`, natural five-hour production formatter fixture, exact suffix `Preview from Settings — no reset was logged.`, notification `try`, separate writer `try`, shell-quoted stdin command, completion/disconnect/error handling, and no reference to `handleQuotaResets`, `buildLogCommand`, `logQuotaResetEnvelopes`, or `log-reset.sh` inside the test function.

- [ ] **Step 2: Verify RED**

Run: `node tests/test-test-celebration-kcm-wiring.mjs`

Expected: FAIL because the KCM has no request producer.

- [ ] **Step 3: Implement producer wiring**

Rename the function to `sendTestCelebration()`. Preserve `QuotaReset.formatNotification()` with a natural `5h` sample. Generate the request with timestamp plus random nonce entropy. Send the KNotification independently, then pipe shell-quoted serialised JSON to `bash <resolved-script> write` through a dedicated executable `DataSource`. Disconnect on completion and log non-zero exit/status without suppressing notification delivery.

- [ ] **Step 4: Verify GREEN and no production regression**

```bash
node tests/test-test-celebration-kcm-wiring.mjs
node tests/test-quota-reset-wiring.mjs
```

Expected: both pass; production reset notification/log wiring is unchanged.

- [ ] **Step 5: Commit**

```bash
git add contents/ui/configGeneral.qml tests/test-test-celebration-kcm-wiring.mjs
git commit -m "feat: publish test celebrations from settings"
```

---

### Task 4: Runtime Consumer and Shared Card Limits

**Files:**
- Modify: `contents/ui/ProfileController.qml` (imports/properties, component startup, celebration seam, executable DataSources)
- Modify: `contents/ui/main.qml` (compact/full limits and view bindings)
- Modify: `contents/ui/CardsView.qml` (limit property use)
- Create: `tests/test-test-celebration-controller-wiring.mjs`

**Interfaces:**
- Consumes: Task 1 `consume()` and `selectProfileId()`.
- Consumes: Task 2 bridge `take` output.
- Produces: `compactCardLimit: 8`, `fullCardLimit: 12`, `consumeTestCelebration(raw)`, and unchanged `triggerCardCelebration(profileId)`.

- [ ] **Step 1: Write failing runtime wiring tests**

Assert central limits are passed into both `CardsView`s and selector options; a `Timer` invokes one-shot `take` no faster than 750 ms; concurrent polls are guarded; each source disconnects; empty output is silent; non-empty output goes through `consume`; accepted input selects from `publicProfileList` and calls `triggerCardCelebration(selectedId)` directly; no eligible profile is an acknowledged no-op; and `consumeTestCelebration` contains no reset detector, notification, or log call.

- [ ] **Step 2: Verify RED**

Run: `node tests/test-test-celebration-controller-wiring.mjs`

Expected: FAIL because controller consumption and shared limits are absent.

- [ ] **Step 3: Implement runtime consumption**

Import the request module. Add the resolved bridge path, replay state, `testCelebrationPollBusy`, and a 900 ms repeating `Timer`. Execute `bash <bridge> take`; disconnect/clear busy at completion; ignore empty stdout; call pure `consume(raw, replayState, Date.now())`; update replay state; and, only when accepted, select a random eligible public profile using `{compactMaxCards: compactCardLimit, fullMaxCards: fullCardLimit}` before calling the existing production generation seam. Keep production `handleQuotaResets()` untouched.

- [ ] **Step 4: Verify GREEN and layout/runtime compatibility**

```bash
node tests/test-test-celebration-controller-wiring.mjs
node tests/test-quota-reset-wiring.mjs
node tests/test-main-layout.mjs
QT_QPA_PLATFORM=offscreen qmltestrunner -input tests -import contents/ui
```

Expected: all pass; a benign environment skip from existing QML tests must be recorded rather than hidden.

- [ ] **Step 5: Commit**

```bash
git add contents/ui/ProfileController.qml contents/ui/main.qml contents/ui/CardsView.qml \
  tests/test-test-celebration-controller-wiring.mjs
git commit -m "feat: consume settings celebrations in widget"
```

---

### Task 5: Progress-Based Choreography and Reduced Motion

**Files:**
- Create: `contents/ui/js/CelebrationMotion.js`
- Create: `tests/test-celebration-motion.mjs`
- Modify: `contents/ui/AccountCard.qml`
- Modify: `contents/ui/CardsView.qml`
- Modify: `contents/ui/main.qml`
- Extend: `tests/tst_card_layout.qml`
- Create: `tests/test-card-celebration-wiring.mjs`

**Interfaces:**
- Produces: `CelebrationMotion.at(progress, reducedMotion) -> {scale, translateX, washOpacity, glyphOpacity, glyphScale, glyphY, borderMix, borderWidth}` for progress clamped to `0..1`.
- Produces: injectable `AccountCard.reducedMotion`, defaulted by callers from `Kirigami.Units.longDuration <= 0`.
- Produces: test-only writable `celebrationProgress` or an equivalent deterministic seam.

- [ ] **Step 1: Write failing pure motion and QML wiring tests**

Pure tests assert exact idle at `0` and `1`, anticipation before peak, scale no greater than `1.045`, damped translation no greater than `4 px`, wash/glyph/border peak visibility, smooth resolving values, clamped out-of-range input, and reduced-motion translation `0`/scale `1` at every sampled progress while non-motion feedback remains visible. Source/runtime tests assert single-progress animation, stop-reset-restart behaviour, `Qt.binding` restoration, clip only while active, selected-only generation handling, and reduced-motion propagation across compact/full cards.

- [ ] **Step 2: Verify RED**

```bash
node tests/test-celebration-motion.mjs
node tests/test-card-celebration-wiring.mjs
```

Expected: FAIL because the motion module/progress seam do not exist.

- [ ] **Step 3: Implement the pure choreography**

Use explicit segments: `0–0.12` anticipation, `0.12–0.38` peak, `0.38–0.62` damped accent, `0.62–1` resolve. Keep the pure module side-effect free. Replace the literal colour-emoji dependency with a theme-resilient `Kirigami.Icon` such as `emblem-favorite-symbolic`, drawn on a positive-colour circular nameplate/halo so it remains legible in light/dark themes.

- [ ] **Step 4: Drive QML from one progress animation**

On every matching generation: stop; restore/rebind idle state; set progress `0`; mark celebrating; start a `NumberAnimation` to `1` with a duration derived from Kirigami tokens and a lower bounded non-zero test duration. Derive transforms/wash/glyph/border from `CelebrationMotion.at`. On completion restore live theme bindings exactly. Under reduced motion, animate only non-spatial feedback or shorten the progress pass while the pure state keeps scale/translation neutral.

- [ ] **Step 5: Verify GREEN**

```bash
node tests/test-celebration-motion.mjs
node tests/test-card-celebration-wiring.mjs
QT_QPA_PLATFORM=offscreen qmltestrunner -input tests -import contents/ui
```

Expected: all progress, re-trigger, selected-only, binding restoration, and reduced-motion checks pass.

- [ ] **Step 6: Commit**

```bash
git add contents/ui/js/CelebrationMotion.js contents/ui/AccountCard.qml contents/ui/CardsView.qml \
  contents/ui/main.qml tests/test-celebration-motion.mjs tests/test-card-celebration-wiring.mjs \
  tests/tst_card_layout.qml
git commit -m "feat: polish card celebration choreography"
```

---

### Task 6: Deterministic Raster Harness and Visual Convergence

**Files:**
- Create: `tests/visual/tst_celebration_visual.qml`
- Create: `tests/test-celebration-visual-harness.mjs`
- Generate (ignored): `.visual-review/*.png`
- Modify as findings require: `contents/ui/js/CelebrationMotion.js`, `contents/ui/AccountCard.qml`, visual tests

**Interfaces:**
- Consumes: Task 5’s deterministic progress/reduced-motion seam.
- Produces: fixed-size raster matrix and 4× nearest-neighbour crops for inspection.

- [ ] **Step 1: Write a failing harness contract test**

Assert the QML fixture exists, uses fixed dimensions/fixtures, sets progress directly rather than sleeping through animation, provides compact/full, first/last edge, multi-profile selected-only, idle/peak/resolve, repeated trigger, normal/reduced-motion scenarios, and writes the exact expected PNG matrix to `.visual-review/`.

- [ ] **Step 2: Verify RED**

Run: `node tests/test-celebration-visual-harness.mjs`

Expected: FAIL because the fixture and raster outputs are absent.

- [ ] **Step 3: Implement deterministic QML captures**

Use `grabToImage()` from a fixed offscreen QtQuick scene after component completion and explicit progress assignment. Do not use a provider refresh or wall-clock animation timing. Include at least:

```text
normal-dark-idle.png        normal-dark-peak.png
normal-dark-resolve.png     normal-light-peak.png
multi-selected-only.png     flow-first-edge.png
flow-last-edge.png          reduced-motion-peak.png
retrigger-peak.png          compact-full-peak.png
```

Generate 4× crops of the glyph/header, outer border/edge clearance, and selected/non-selected neighbours with smoothing disabled or Pillow nearest-neighbour resizing.

- [ ] **Step 4: Run the first vision pass**

Render with `QT_QPA_PLATFORM=offscreen qmltestrunner -input tests/visual -import contents/ui`. Read every full PNG and suspicious crop. Record concrete findings in `.visual-review/review.md`: perceptual hierarchy, text legibility, colour contrast, focal pop, motion-state readability, edge clipping, and whether the effect feels celebratory rather than alarming.

- [ ] **Step 5: Fix, regenerate, and commit each real improvement**

Make surgical source changes, rerun motion/wiring/QML tests, regenerate the entire matrix, inspect the same crops, and commit each internally consistent improvement with prefix `fix(celebration):`. Never leave compact/full or repeated elements in different states.

- [ ] **Step 6: Run the independent geometry/source pass**

Provide the approved spec, current source, raster dimensions, generated manifest, and review artifact to a fresh reviewer. Require computed paint bounds, flow-edge clearance, compact/full symmetry, selected-only invariant, glyph/text bounds, and exact idle restoration. It must return concrete findings or `PASS`, and must not edit or notify the user.

- [ ] **Step 7: Alternate until same-revision PASS**

After any geometry fix, regenerate and repeat the vision pass. After any vision fix, repeat geometry review. Stop only when both independently return `PASS` on the same commit and every fixed crop is clean.

- [ ] **Step 8: Commit the harness**

```bash
git add tests/visual/tst_celebration_visual.qml tests/test-celebration-visual-harness.mjs
git commit -m "test: add deterministic celebration visual review"
```

---

### Task 7: Whole-Branch Verification and Review

**Files:**
- Modify only if review finds a defect.

- [ ] **Step 1: Run every automated test serially**

```bash
for f in tests/test-*.mjs; do node "$f" || exit 1; done
for f in tests/test-*.sh; do bash "$f" || exit 1; done
QT_QPA_PLATFORM=offscreen qmltestrunner -input tests -import contents/ui
```

Expected: every command exits zero; any existing environment-specific Qt skip is explicitly evidenced.

- [ ] **Step 2: Lint and inspect the change**

```bash
qmllint contents/ui/ProfileController.qml contents/ui/configGeneral.qml \
  contents/ui/AccountCard.qml contents/ui/CardsView.qml contents/ui/main.qml
git diff --check main...HEAD
git status --short
git log --oneline main..HEAD
```

Expected: no introduced QML errors, whitespace errors, accidental generated raster files, or uncommitted implementation changes.

- [ ] **Step 3: Verify no-log semantics with an isolated HOME**

Write/take a Settings request through the bridge and run the consumer harness with isolated `HOME`/XDG paths. Assert that no `resets/`, `events.jsonl`, or `latest/*reset*` artifact is created.

- [ ] **Step 4: Run whole-branch Standards + Spec review**

Review `main...HEAD` against repository instructions and `docs/superpowers/specs/2026-07-18-quota-reset-notification-polish-design.md`. Fix all Critical/Important findings in one coherent pass, rerun covering tests, and re-review until both axes pass.

- [ ] **Step 5: Final visual same-revision check**

Regenerate the raster matrix from the final reviewed commit and confirm the last vision and geometry PASS still apply.

- [ ] **Step 6: Commit final fixes if needed**

```bash
git add <reviewed-files>
git commit -m "fix: address quota celebration review findings"
```

--- SUMMARY ---

- Define and test a small pure request/selection policy with strict freshness and replay rules.
- Cross the KCM/widget process seam through a secure atomic `write`/`take` adapter, using the runtime directory rather than reset history.
- Keep notification delivery independent, then let the live controller choose one random eligible card and invoke the unchanged production generation seam directly.
- Replace scattered animation properties with one deterministic, reduced-motion-aware progress model and a theme-resilient symbolic focal mark.
- Render fixed compact/full, edge, selected-only, theme, re-trigger, and reduced-motion states; alternate raster vision and source-geometry review until both pass the same revision.
- Finish with the full serial suite, QML lint/runtime checks, explicit no-log evidence, and whole-branch Standards + Spec review.
