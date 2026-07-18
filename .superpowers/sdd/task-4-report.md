# Task 4 Report: Runtime Consumer and Shared Card Limits

## Outcome

Task 4 is implemented and verified. The widget now polls the installed Settings test-celebration bridge, consumes accepted one-shot requests through the pure request module, chooses an eligible public profile, and triggers the existing card-celebration seam. Compact and full card limits are defined once by `ProfileController` and bound into both mounted `CardsView` instances.

## TDD and Validator Evidence

### Inherited initial RED

Before the inherited production implementation, the focused structural test failed because the runtime consumer was absent: there was no test-celebration request import, bridge polling `Timer`/executable `DataSource`, replay-state consumption path, eligible-profile selection, or shared controller limits wired to both views.

### Five pre-hardening false-pass proofs

A prior validator version was explicitly exercised against five concise source mutants. Each mutant incorrectly exited 0 before hardening:

1. the target id was placed under the wrong component type / `DataSource` scope;
2. `connectSource` was moved before the busy guard and busy assignment;
3. the empty-output predicate was inverted so non-empty output returned early;
4. selection/trigger behaviour was placed before the accepted and no-selected-id guards;
5. compact/full `maxCards` tokens were moved outside their correct `CardsView` blocks.

The shared `validate()` function now rejects all five. Each `assert.throws` includes an intent-specific failure regex, proving the mutant is rejected for its intended contract rather than an incidental assertion.

### Validator-bug RED and repair

After hardening, the normal focused suite was RED with:

```text
expected exactly one Timer component with id testCelebrationPollTimer, found 0
```

Root cause: `componentBlock(source, type, id)` advanced the component regex to the closing brace of an enclosing component. This skipped lexical component starts nested inside the root `Item`, including the target `Timer` and `Plasma5Support.DataSource`.

The repair:

- masks comments, strings, and regex literals while preserving source offsets;
- inspects every lexical component-start match in source order;
- computes each candidate's own balanced-brace range;
- resumes traversal just after the candidate opening brace instead of after its closing brace;
- accepts an id only when it occurs at brace depth 1 in that candidate, excluding ids in nested children.

The regex-literal mask was necessary because QML JavaScript such as `replace(/'/g, ...)` otherwise caused the existing string/comment mask to treat the regex's apostrophe as an unterminated string and hide the remainder of the file.

## Changed Files

- `contents/ui/ProfileController.qml`
  - imports `TestCelebrationRequests.js`;
  - defines `compactCardLimit: 8` and `fullCardLimit: 12`;
  - tracks replay state and concurrent-poll busy state;
  - resolves the installed bridge path;
  - polls `bash <bridge> take` with a guarded repeating 900 ms `Timer`;
  - disconnects each executable source and releases busy state before inspecting output;
  - ignores exactly empty output;
  - consumes non-empty output, updates replay state, gates on acceptance, selects an eligible public profile with both shared limits, and directly invokes `triggerCardCelebration(selectedId)`;
  - leaves production quota-reset handling untouched.
- `contents/ui/main.qml`
  - binds compact and full `CardsView.maxCards` to the controller's shared limits.
- `tests/test-test-celebration-controller-wiring.mjs`
  - adds the focused structural runtime contract, position-preserving structural component lookup, ordered/predicate assertions, and five regression mutants.
- `.superpowers/sdd/task-4-report.md`
  - records Task 4 evidence and review.

`contents/ui/CardsView.qml` is unchanged. Its existing `maximumCards` interface (`maxCards`) already controls delegate visibility, row sizing, and the overflow count, so no production change was required there.

## Final Serial Verification

Executed in the isolated Task 4 worktree, in the requested order:

```text
node tests/test-test-celebration-controller-wiring.mjs
  All test-celebration controller wiring tests passed.

node tests/test-quota-reset-wiring.mjs
  All quota-reset wiring tests passed.

node tests/test-main-layout.mjs
  All main layout tests passed.

QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
  -input tests -import contents/ui -o -,txt
  Totals: 11 passed, 0 failed, 0 skipped, 0 blacklisted

git diff --check
  exit 0, no output
```

The Qt 6 runner is intentionally `/usr/lib/qt6/bin/qmltestrunner`. Bare `/usr/bin/qmltestrunner` is Qt 5 and can silently fail even on baseline, so it was not used.

## Acceptance-Criteria Self-Review

- [x] Shared central limits are 8 compact / 12 full.
- [x] Both mounted `CardsView` instances bind to the appropriate central limit.
- [x] Eligible-profile selection receives both central limits.
- [x] Polling interval is 900 ms, therefore no faster than 750 ms.
- [x] Concurrent polls are guarded before command construction and connection.
- [x] Failed connection releases the busy state.
- [x] Every completion disconnects its source and releases busy state before output handling.
- [x] Exactly empty trimmed output is silent; non-empty output reaches `consumeTestCelebration`.
- [x] The pure consumer receives raw input, replay state, and `Date.now()`; returned replay state is retained.
- [x] Rejected requests return before profile selection.
- [x] Accepted requests select from `publicProfileList`.
- [x] No selected/eligible profile is an acknowledged no-op.
- [x] The existing `triggerCardCelebration(selectedId)` generation seam is called directly and only after both guards.
- [x] `consumeTestCelebration` contains no reset detection, notification, reset logging, or console logging.
- [x] Existing compact/full celebration bindings remain intact.
- [x] Production `handleQuotaResets()` remains untouched.
- [x] The five known false-positive classes are rejected for their intended assertions.

## Concerns

No production concerns found. The focused contract is deliberately a bounded QML structural validator rather than a general QML parser; it handles the component nesting, comments, strings, regex literals, balanced braces, top-level ids, exact predicates, and ordering required by this task.
