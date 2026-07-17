#!/usr/bin/env node
/**
 * Unit tests for QuotaResetEvents — pure detection, classification,
 * notification copy, log envelope, and shell command construction.
 */
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")
const QR = loadQmlJs(
    join(root, "contents/ui/js/QuotaResetEvents.js"), {},
    [
        "snapshotWindows",
        "detectResets",
        "buildLogEnvelope",
        "formatNotification",
        "buildResetPaths",
        "buildLogCommand",
        "classifyKind",
        "isWindowReset",
        "requiredResetJumpMs",
        "cacheRoot",
        "slug",
        "shellQuote"
    ])

const MS_5H = 5 * 60 * 60 * 1000
const MS_7D = 7 * 24 * 60 * 60 * 1000
const NOW = Date.parse("2026-07-18T12:00:00.000Z")
const EXPECTED = NOW // natural when now ≈ expected

function win(id, usage, resetAtMs, periodMs, label) {
    return {
        id,
        label: label || id,
        usagePercent: usage,
        resetAtMs,
        periodMs: periodMs || MS_5H,
        role: id === "weekly" ? "primary" : "primary"
    }
}

// --- first poll: no prior windows → no events --------------------------------
{
    const r = QR.detectResets({
        prevWindows: [],
        nextWindows: [win("5h", 0, NOW + MS_5H, MS_5H)],
        profile: { id: "claude-1", provider: "claude", displayName: "Claude" },
        nowMs: NOW
    })
    assert.equal(r.events.length, 0)
    assert.equal(r.notification, null)
}

// --- no change → no events ---------------------------------------------------
{
    const w = win("5h", 42, NOW + 3600000, MS_5H)
    const r = QR.detectResets({
        prevWindows: [w],
        nextWindows: [w],
        profile: { id: "p", provider: "claude" },
        nowMs: NOW
    })
    assert.equal(r.events.length, 0)
}

// --- natural session reset (resetAt jumped, usage dropped) -------------------
{
    const prev = [win("5h", 87, EXPECTED, MS_5H, "5h")]
    const next = [win("5h", 1, EXPECTED + MS_5H, MS_5H, "5h")]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: {
            id: "claude-home",
            provider: "claude",
            displayName: "Claude",
            planName: "Max 5x",
            bankedResets: 0
        },
        nowMs: NOW,
        graceMs: 5 * 60 * 1000
    })
    assert.equal(r.events.length, 1)
    assert.equal(r.events[0].kind, "natural")
    assert.equal(r.events[0].unexpected, false)
    assert.equal(r.events[0].windowId, "5h")
    assert.equal(r.events[0].previousUsagePercent, 87)
    assert.equal(r.events[0].newUsagePercent, 1)
    assert.equal(r.events[0].expectedResetAtMs, EXPECTED)
    assert.equal(r.events[0].planName, "Max 5x")
    assert.ok(r.notification)
    assert.match(r.notification.title, /Woo-hoo/)
    assert.match(r.notification.title, /Claude/)
    assert.match(r.notification.text, /5h/)
    assert.equal(r.envelopes.length, 1)
    assert.equal(r.envelopes[0].kind, "natural")
    assert.equal(r.envelopes[0].provider, "claude")
    assert.ok(r.envelopes[0].observedAt)
    assert.ok(r.envelopes[0].expectedResetAt)
}

// --- early (unexpected) reset ------------------------------------------------
{
    const expected = NOW + 2 * 60 * 60 * 1000 // 2h in the future
    const prev = [win("5h", 50, expected, MS_5H)]
    const next = [win("5h", 0, expected + MS_5H, MS_5H)]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "c", provider: "claude", displayName: "Claude" },
        nowMs: NOW,
        graceMs: 5 * 60 * 1000
    })
    assert.equal(r.events.length, 1)
    assert.equal(r.events[0].kind, "early")
    assert.equal(r.events[0].unexpected, true)
    assert.ok(r.events[0].deltaMs < 0)
    assert.match(r.notification.text, /earlier than expected|expected/)
}

// --- late observation --------------------------------------------------------
{
    const expected = NOW - 30 * 60 * 1000 // expected 30m ago
    const prev = [win("weekly", 99, expected, MS_7D, "7d")]
    const next = [win("weekly", 0, expected + MS_7D, MS_7D, "7d")]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "codex", provider: "codex", displayName: "Codex" },
        nowMs: NOW,
        graceMs: 5 * 60 * 1000
    })
    assert.equal(r.events[0].kind, "late")
    assert.equal(r.events[0].unexpected, true)
}

// --- surprise: no prior resetAt ----------------------------------------------
{
    const prev = [{ id: "mo", label: "mo", usagePercent: 90, resetAtMs: 0, periodMs: MS_7D }]
    const next = [{ id: "mo", label: "mo", usagePercent: 0, resetAtMs: NOW + MS_7D, periodMs: MS_7D }]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "g", provider: "grok", displayName: "Grok" },
        nowMs: NOW
    })
    assert.equal(r.events.length, 1)
    assert.equal(r.events[0].kind, "surprise")
    assert.equal(r.events[0].unexpected, true)
}

// --- multi-window batch → one notification -----------------------------------
{
    const prev = [
        win("5h", 80, NOW, MS_5H, "5h"),
        win("weekly", 60, NOW, MS_7D, "7d")
    ]
    const next = [
        win("5h", 0, NOW + MS_5H, MS_5H, "5h"),
        win("weekly", 0, NOW + MS_7D, MS_7D, "7d")
    ]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "multi", provider: "claude", displayName: "Work" },
        nowMs: NOW
    })
    assert.equal(r.events.length, 2)
    assert.ok(r.notification)
    assert.match(r.notification.text, /5h/)
    assert.match(r.notification.text, /7d/)
    assert.match(r.notification.text, /\+/)
}

// --- opencode effective provider ---------------------------------------------
{
    const prev = [win("5h", 40, NOW, MS_5H)]
    const next = [win("5h", 0, NOW + MS_5H, MS_5H)]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "oc", provider: "opencode", opencodeSlot: "zhipu", displayName: "Z.ai" },
        nowMs: NOW
    })
    assert.equal(r.events[0].provider, "zhipu")
    assert.equal(r.envelopes[0].provider, "zhipu")
}

// --- usage-only noise without reset jump → no event --------------------------
{
    // Small usage noise / correction without period roll
    const prev = [win("5h", 50, NOW + MS_5H, MS_5H)]
    const next = [win("5h", 48, NOW + MS_5H, MS_5H)]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "n", provider: "claude" },
        nowMs: NOW
    })
    assert.equal(r.events.length, 0)
}

// --- small resetAt clock correction (90s) must not celebrate -----------------
{
    const prev = [win("5h", 50, NOW + MS_5H, MS_5H)]
    const next = [win("5h", 49, NOW + MS_5H + 90_000, MS_5H)]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "drift", provider: "claude" },
        nowMs: NOW
    })
    assert.equal(r.events.length, 0, "90s resetAt drift is not a period roll")
}

// --- period-scale jump with already-zero usage still counts ------------------
{
    const prev = [win("5h", 0, NOW, MS_5H)]
    const next = [win("5h", 0, NOW + MS_5H, MS_5H)]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "z", provider: "claude" },
        nowMs: NOW,
        graceMs: 20 * 60 * 1000
    })
    assert.equal(r.events.length, 1)
    assert.equal(r.events[0].kind, "natural")
}

// --- Claude 15m poll lag still natural with 20m grace ------------------------
{
    const expected = NOW - 12 * 60 * 1000 // observed 12m after expected
    const prev = [win("5h", 90, expected, MS_5H)]
    const next = [win("5h", 0, expected + MS_5H, MS_5H)]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "lag", provider: "claude" },
        nowMs: NOW,
        graceMs: 20 * 60 * 1000
    })
    assert.equal(r.events.length, 1)
    assert.equal(r.events[0].kind, "natural", "12m poll lag within 20m grace")
    assert.equal(r.events[0].unexpected, false)
}

// --- truly late: multi-interval overdue --------------------------------------
{
    const expected = NOW - 45 * 60 * 1000
    const prev = [win("5h", 90, expected, MS_5H)]
    const next = [win("5h", 0, expected + MS_5H, MS_5H)]
    const r = QR.detectResets({
        prevWindows: prev,
        nextWindows: next,
        profile: { id: "late", provider: "claude" },
        nowMs: NOW,
        graceMs: 20 * 60 * 1000
    })
    assert.equal(r.events[0].kind, "late")
    assert.equal(r.events[0].unexpected, true)
}

// --- paths + log command -----------------------------------------------------
{
    const env = QR.buildLogEnvelope({
        observedAtMs: NOW,
        provider: "claude",
        profileId: "open/code one",
        windowId: "5h",
        kind: "natural",
        unexpected: false,
        expectedResetAtMs: NOW,
        previousUsagePercent: 10,
        newUsagePercent: 0,
        previousResetAtMs: NOW,
        newResetAtMs: NOW + MS_5H,
        periodMs: MS_5H
    })
    const paths = QR.buildResetPaths({
        homeDir: "/home/me",
        configuredRoot: ""
    }, env, NOW)
    assert.match(paths.hist, /\/home\/me\/\.cache\/plasma-claude-usage\/resets\//)
    assert.match(paths.hist, /claude-open-code-one-5h\.json$/)
    assert.match(paths.latest, /\/resets\/latest\/claude-open-code-one-5h\.json$/)
    assert.match(paths.jsonl, /\/resets\/events\.jsonl$/)

    const cmd = QR.buildLogCommand({
        homeDir: "/home/me",
        logScript: "/opt/log-reset.sh"
    }, env, NOW)
    assert.match(cmd, /log-reset\.sh/)
    assert.match(cmd, /printf %s/)
    assert.match(cmd, /events\.jsonl/)
    assert.ok(cmd.indexOf("bash '/opt/log-reset.sh'") >= 0)
}

// --- classifyKind unit -------------------------------------------------------
{
    assert.equal(QR.classifyKind({ resetAtMs: NOW }, NOW, 60000), "natural")
    assert.equal(QR.classifyKind({ resetAtMs: NOW + 600000 }, NOW, 60000), "early")
    assert.equal(QR.classifyKind({ resetAtMs: NOW - 600000 }, NOW, 60000), "late")
    assert.equal(QR.classifyKind({ resetAtMs: 0 }, NOW, 60000), "surprise")
}

// --- snapshot ignores null / missing ids -------------------------------------
{
    const snaps = QR.snapshotWindows([
        null,
        { usagePercent: 1 },
        { id: "x", usagePercent: 2, resetAtMs: 3, periodMs: 4, label: "X", role: "extra" }
    ])
    assert.equal(snaps.length, 1)
    assert.deepEqual(snaps[0], {
        id: "x", label: "X", usagePercent: 2, resetAtMs: 3, periodMs: 4, role: "extra"
    })
}

console.log("All quota-reset-events tests passed.")
