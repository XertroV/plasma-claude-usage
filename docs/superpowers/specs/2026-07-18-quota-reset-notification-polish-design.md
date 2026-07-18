# Quota-Reset Notification Polish Design

**Date:** 18 July 2026

## Problem

A real quota reset sends a desktop notification, logs the event, and pulses a matching account card through `ProfileController`. The Settings button is labelled **Send test celebration**, but the KCM runs in a separate process and currently creates only a test desktop notification. It cannot exercise the card effects its label promises.

The card celebration is also a first-pass animation. It combines a positive tint, border pulse, scale bounce, horizontal shake, highlight wash, and a central celebration glyph, but it has not yet received a rendered, crop-zoomed polish pass across compact/full cards, repeated triggers, flow edges, and theme restoration.

## Desired Behaviour

- A real reset retains its existing detection, notification, logging, and matching-profile behaviour.
- The Settings button sends a realistic test notification and triggers the complete card celebration on one randomly selected **visible and enabled** account.
- The test path never creates a synthetic reset-history record and does not alter reset detection state.
- The running widget consumes each Settings request at most once, ignores stale/replayed requests, and works across the KCM/widget process boundary.
- If no eligible card is available, notification delivery still succeeds and the runtime safely performs no animation.
- If compact and full representations of the selected profile both exist, they receive the same production celebration pulse; hidden/overflow-only profiles are not selected.
- Motion feels celebratory rather than alarming: strong focal pop, coherent highlight/border response, controlled movement, no clipped paint, legible content, and clean restoration to live theme bindings.
- Reduced-motion preferences are honoured where the Plasma/Qt surface exposes them: retain colour/highlight feedback while avoiding excessive translation or scaling.

## Chosen Architecture

### 1. Separate the pure test-request contract

Add a small QML JavaScript module for test-celebration requests. It owns:

- creation of a versioned, nonce-bearing request payload;
- timestamp freshness and replay checks;
- extraction of eligible profile IDs from the same public profile list and card-limit constraints used by visible card surfaces;
- injected random selection so behaviour can be tested deterministically.

The module has no filesystem, notification, animation, or KConfig side effects. Node tests load it directly.

### 2. Use a transient request file as the process bridge

The KCM cannot call `ProfileController`, so after sending its desktop notification it serialises a request and invokes a small shell writer through Plasma’s executable `DataSource`. The writer atomically replaces one runtime request file in the user cache/runtime area. The payload contains no credentials or quota data.

The widget controller watches/polls that one file through an executable `DataSource`, validates freshness/version/nonce, and acknowledges it before triggering an effect. Atomic replacement prevents partial reads. Nonce replay protection prevents repeated effects if the same content is observed more than once. A short freshness window makes old requests harmless after restarts.

The bridge is deliberately test-only: consumption calls the card-celebration seam directly and bypasses `handleQuotaResets()`, notifications, and reset logging.

### 3. Reuse the production celebration pulse

Refine `triggerCardCelebration(profileId)` into the single runtime seam used by both real reset events and accepted test requests. The Settings request chooses a random profile that can render on a card surface, then increments the existing celebration generation. `CardsView` and `AccountCard` continue matching by profile ID and generation, so every mounted representation of that selected account runs the same complete effect.

Eligibility is derived from enabled profiles and the union of visible card limits. It must not choose disabled or overflow-only profiles. Selection is made when the request is consumed, not in the KCM, because only the running widget has authoritative live visibility/profile state.

## Visual Direction

Keep the existing Plasma-native card and positive theme palette, but make the effect read as one choreographed event:

1. **Anticipation:** a very short inward settle or restrained initial compression.
2. **Celebration:** a spring-like scale rise, positive border/tint emphasis, and a soft radial/highlight wash centred behind a theme-consistent celebration mark.
3. **Accent:** a small, damped lateral movement—not a long error-style shake.
4. **Resolve:** glyph and wash drift/fade while scale, border width, colour, and opacity return smoothly to their live bindings.

The effect must preserve text legibility throughout. Overflow is enabled only while celebrating, with sufficient safe spacing or internal geometry so the effect is not visibly cut off at flow edges. The glyph should use a system/theme-resilient symbol or treatment rather than depending on an unsupported colour-emoji render. Re-triggering stops and restarts the full choreography from a known state.

## Notification Copy

The test notification uses the production formatter and a natural five-hour reset fixture, but its test status is concise and explicit. It should not imply that reset detection or history logging occurred. Production early/on-time/late/surprise and batched-window copy remain unchanged unless the rendered review identifies a concrete legibility or wording defect.

## Failure Handling

- Notification creation failure remains isolated to the KCM and does not write reset history.
- Request-writer failure does not prevent the desktop notification; Settings can surface/log a concise warning without crashing.
- Invalid, unsupported, stale, or replayed request payloads are ignored and logged once at debug/warning level as appropriate.
- Missing request files are normal and silent.
- No eligible card is a safe no-op after request acknowledgement.
- Consumption must never route through reset logging.

## Testing and Verification

### Automated

Use RED/GREEN tests to cover:

- request schema, serialisation, timestamp freshness, nonce replay rejection, and deterministic random selection;
- exclusion of disabled and overflow-only profiles;
- KCM notification + bridge writer wiring;
- controller bridge consumption and direct use of the production celebration seam;
- explicit absence of reset logging from the test path;
- all visual effect phases/properties, re-trigger reset, binding restoration, and reduced-motion branch;
- compact/full propagation and matching-profile invariants;
- writer atomicity and malformed-input rejection.

Run the complete existing Node and shell suites, QML tests where available, `qmllint`, and `git diff --check`, with no more than two build/test threads.

### Visual review-and-fix

Create or adapt a deterministic render harness that presents representative account cards without requiring a live provider refresh. Capture the full artifact and targeted nearest-neighbour crop zooms for:

- compact and full cards;
- animation peak and resolve frames;
- a card at each flow edge;
- multiple profiles with only the selected account celebrating;
- repeated trigger;
- dark and light/theme-like palettes;
- reduced-motion state.

Alternate vision inspection with independent geometry/source reasoning. Commit each improving iteration, preserve symmetry/repeated-element invariants, and stop only when both modalities pass the same revision and all fixed crops are clean.

## Scope Boundaries

This work does not:

- create synthetic reset log entries;
- simulate provider refresh or quota-reset detection from Settings;
- add celebration effects to the separate detail-window UI;
- persist a test-generation counter as user configuration;
- introduce a general-purpose D-Bus service;
- change production reset classification semantics.

--- SUMMARY ---

- Bridge the separate Settings and widget processes with a versioned, nonce-bearing, atomic transient request.
- Let the running widget choose a random enabled, actually visible account and invoke the same celebration-generation seam used by production.
- Keep test notification delivery and all card effects, but deliberately bypass reset detection and reset-history logging.
- Deep-polish the choreography, clipping, theme restoration, re-triggering, glyph resilience, and reduced-motion treatment through interspersed raster vision and source-geometry review.
- Protect request validation, selection, wiring, no-log semantics, and every animation phase with RED/GREEN regression tests plus the full existing suite.
