#!/usr/bin/env node
/**
 * P1.M3.E1.T003 — ProfileRegistry.editConfig() for enabled/name/custom KCM edits.
 */
import assert from "node:assert/strict"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { loadQmlJs } from "./helpers/load-qml-js.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = join(here, "..")

const QC = loadQmlJs(join(root, "contents/ui/js/QuotaCommon.js"), {}, [
    "pathsEqual", "defaultCredPathForProvider", "defaultProfileLabel"
])

const Registry = loadQmlJs(
    join(root, "contents/ui/js/ProfileRegistry.js"),
    { QC },
    ["editConfig", "transition"]
)

assert.equal(typeof Registry.editConfig, "function", "editConfig must be exported")

function baseConfig(overrides) {
    return Object.assign({
        multiProfileMode: true,
        provider: "claude",
        opencodeSubProvider: "anthropic",
        credentialsPath: "",
        displayName: "",
        discoverOnLoad: true,
        enabledProfilesJson: "[]",
        profileDisplayNamesJson: "{}",
        customProfilesJson: "[]",
        customProfileNextId: 0,
        visibleWindowsJson: "[]"
    }, overrides || {})
}

function known(ids) {
    return ids.map(id => (typeof id === "string" ? { id } : id))
}

function parse(json, fallback) {
    try {
        return JSON.parse(json)
    } catch (e) {
        return fallback
    }
}

function freezeDeep(obj) {
    return JSON.parse(JSON.stringify(obj))
}

let passed = 0
function ok(label) {
    console.log("ok:", label)
    passed++
}

// ---------------------------------------------------------------------------
// setEnabled: [] / __none__ / partial allowlist
// ---------------------------------------------------------------------------

{
    const knownProfiles = known(["claude-default", "codex-default", "claude-custom-1"])
    const cfg = baseConfig({ enabledProfilesJson: "[]" })
    const inputCfg = freezeDeep(cfg)

    // all enabled stays [] when toggling one on (noop-ish keep all-on)
    let r = Registry.editConfig({
        config: cfg,
        knownProfiles,
        event: { type: "setEnabled", profileId: "claude-default", enabled: true }
    })
    assert.equal(r.patch.enabledProfilesJson, "[]")
    assert.equal(r.config.enabledProfilesJson, "[]")
    assert.deepEqual(inputCfg, cfg, "input config must not be mutated")
    ok("all enabled serialises []")

    // disable one → partial allowlist
    r = Registry.editConfig({
        config: baseConfig({ enabledProfilesJson: "[]" }),
        knownProfiles,
        event: { type: "setEnabled", profileId: "codex-default", enabled: false }
    })
    assert.deepEqual(parse(r.patch.enabledProfilesJson),
        ["claude-default", "claude-custom-1"])
    ok("partial selection serialises ID allowlist across discovered/custom")

    // disable the rest → __none__
    r = Registry.editConfig({
        config: baseConfig({
            enabledProfilesJson: JSON.stringify(["claude-default", "claude-custom-1"])
        }),
        knownProfiles,
        event: { type: "setEnabled", profileId: "claude-default", enabled: false }
    })
    // still have custom-1 on → partial
    assert.deepEqual(parse(r.patch.enabledProfilesJson), ["claude-custom-1"])

    r = Registry.editConfig({
        config: baseConfig({
            enabledProfilesJson: JSON.stringify(["claude-custom-1"])
        }),
        knownProfiles,
        event: { type: "setEnabled", profileId: "claude-custom-1", enabled: false }
    })
    assert.deepEqual(parse(r.patch.enabledProfilesJson), ["__none__"])
    assert.equal(r.config.enabledProfilesJson, JSON.stringify(["__none__"]))
    ok("all disabled serialises [\"__none__\"]")

    // re-enable one from __none__ → allowlist of one
    r = Registry.editConfig({
        config: baseConfig({
            enabledProfilesJson: JSON.stringify(["__none__"])
        }),
        knownProfiles,
        event: { type: "setEnabled", profileId: "claude-default", enabled: true }
    })
    assert.deepEqual(parse(r.patch.enabledProfilesJson), ["claude-default"])
    ok("re-enable from __none__ yields allowlist")

    // re-enable all → []
    r = Registry.editConfig({
        config: baseConfig({
            enabledProfilesJson: JSON.stringify(["claude-default", "codex-default"])
        }),
        knownProfiles,
        event: { type: "setEnabled", profileId: "claude-custom-1", enabled: true }
    })
    assert.equal(r.patch.enabledProfilesJson, "[]")
    ok("restoring full selection serialises []")
}

// ---------------------------------------------------------------------------
// setName: trim + empty removes
// ---------------------------------------------------------------------------

{
    const cfg = baseConfig({
        profileDisplayNamesJson: JSON.stringify({ "claude-default": "Work" })
    })
    const frozen = freezeDeep(cfg)

    let r = Registry.editConfig({
        config: cfg,
        knownProfiles: known(["claude-default"]),
        event: { type: "setName", profileId: "claude-default", name: "  Desk  " }
    })
    assert.deepEqual(parse(r.patch.profileDisplayNamesJson), { "claude-default": "Desk" })
    assert.deepEqual(frozen, cfg, "setName must not mutate input config")
    ok("names trim")

    r = Registry.editConfig({
        config: baseConfig({
            profileDisplayNamesJson: JSON.stringify({ "claude-default": "Desk" })
        }),
        knownProfiles: known(["claude-default"]),
        event: { type: "setName", profileId: "claude-default", name: "   " }
    })
    assert.deepEqual(parse(r.patch.profileDisplayNamesJson), {})
    ok("empty name removes override")

    r = Registry.editConfig({
        config: baseConfig({
            profileDisplayNamesJson: JSON.stringify({ "a": "A", "b": "B" })
        }),
        knownProfiles: known(["a", "b"]),
        event: { type: "setName", profileId: "a", name: "" }
    })
    assert.deepEqual(parse(r.patch.profileDisplayNamesJson), { "b": "B" })
    ok("empty removes only the targeted name")
}

// ---------------------------------------------------------------------------
// addCustom: default/explicit cred path, enable, name, durable allocator
// ---------------------------------------------------------------------------

{
    // Default credential path
    let r = Registry.editConfig({
        config: baseConfig({ customProfileNextId: 0 }),
        knownProfiles: known(["claude-default"]),
        event: {
            type: "addCustom",
            provider: "claude",
            path: "/home/u/.claude-work",
            credPath: "",
            displayName: ""
        }
    })
    const customs1 = parse(r.patch.customProfilesJson)
    assert.equal(customs1.length, 1)
    assert.equal(customs1[0].provider, "claude")
    assert.equal(customs1[0].path, "/home/u/.claude-work")
    assert.equal(
        customs1[0].credPath,
        QC.defaultCredPathForProvider("claude", "/home/u/.claude-work")
    )
    assert.equal(customs1[0].id, "claude-custom-1")
    assert.equal(r.patch.customProfileNextId, 2)
    assert.equal(r.config.customProfileNextId, 2)
    // all-on config stays [] after add
    assert.equal(r.patch.enabledProfilesJson === undefined
        || r.patch.enabledProfilesJson === "[]"
        || r.config.enabledProfilesJson === "[]", true)
    ok("add custom uses default cred path and allocator starts at 1")

    // Explicit credential path + display name + enable into partial allowlist.
    // Keep a disabled discovered profile so the result stays a partial allowlist
    // (if every known id ends up on, serialisation collapses to []).
    r = Registry.editConfig({
        config: baseConfig({
            enabledProfilesJson: JSON.stringify(["claude-default"]),
            customProfilesJson: "[]",
            customProfileNextId: 0
        }),
        knownProfiles: known(["claude-default", "codex-default"]),
        event: {
            type: "addCustom",
            provider: "codex",
            path: "/home/u/.codex-alt",
            credPath: "/home/u/.codex-alt/special-auth.json",
            displayName: "  Alt Codex  "
        }
    })
    const customs2 = parse(r.patch.customProfilesJson)
    assert.equal(customs2[0].credPath, "/home/u/.codex-alt/special-auth.json")
    assert.equal(customs2[0].id, "codex-custom-1")
    assert.equal(customs2[0].displayName, "Alt Codex")
    assert.deepEqual(parse(r.patch.profileDisplayNamesJson), {
        "codex-custom-1": "Alt Codex"
    })
    // new custom must be enabled; disabled discovered peer stays off
    assert.deepEqual(parse(r.patch.enabledProfilesJson).sort(),
        ["claude-default", "codex-custom-1"].sort())
    ok("add custom uses explicit cred path, enables, and names it")
}

// ---------------------------------------------------------------------------
// Allocator: max(persistedNextId, highestExistingSuffix + 1)
// ---------------------------------------------------------------------------

{
    // persisted lower than existing suffix
    let r = Registry.editConfig({
        config: baseConfig({
            customProfilesJson: JSON.stringify([
                { id: "claude-custom-5", provider: "claude", path: "/a" }
            ]),
            customProfileNextId: 2
        }),
        knownProfiles: known(["claude-custom-5"]),
        event: {
            type: "addCustom",
            provider: "grok",
            path: "/home/u/.grok-x",
            credPath: "",
            displayName: ""
        }
    })
    const c = parse(r.patch.customProfilesJson)
    assert.equal(c[c.length - 1].id, "grok-custom-6")
    assert.equal(r.patch.customProfileNextId, 7)
    ok("allocator is max(persistedNextId, highestExistingSuffix + 1)")

    // persisted higher than existing suffix
    r = Registry.editConfig({
        config: baseConfig({
            customProfilesJson: JSON.stringify([
                { id: "claude-custom-1", provider: "claude", path: "/a" }
            ]),
            customProfileNextId: 10
        }),
        knownProfiles: known(["claude-custom-1"]),
        event: {
            type: "addCustom",
            provider: "claude",
            path: "/b",
            credPath: "",
            displayName: ""
        }
    })
    const c2 = parse(r.patch.customProfilesJson)
    assert.equal(c2[c2.length - 1].id, "claude-custom-10")
    assert.equal(r.patch.customProfileNextId, 11)
    ok("allocator prefers higher persisted next id")
}

// ---------------------------------------------------------------------------
// removeCustom: never decrements; reload then add never reuses
// ---------------------------------------------------------------------------

{
    const startCustoms = [
        { id: "claude-custom-1", provider: "claude", path: "/a",
          credPath: "/a/.credentials.json" },
        { id: "claude-custom-2", provider: "claude", path: "/b",
          credPath: "/b/.credentials.json" }
    ]
    let cfg = baseConfig({
        customProfilesJson: JSON.stringify(startCustoms),
        customProfileNextId: 3
    })
    const frozen = freezeDeep(cfg)

    let r = Registry.editConfig({
        config: cfg,
        knownProfiles: known(["claude-default", "claude-custom-1", "claude-custom-2"]),
        event: { type: "removeCustom", profileId: "claude-custom-2" }
    })
    assert.deepEqual(frozen, cfg, "removeCustom must not mutate input")
    const afterRemove = parse(r.patch.customProfilesJson)
    assert.equal(afterRemove.length, 1)
    assert.equal(afterRemove[0].id, "claude-custom-1")
    // removal never decrements allocator — either omit or keep 3
    if (r.patch.customProfileNextId !== undefined)
        assert.equal(r.patch.customProfileNextId, 3)
    assert.equal(r.config.customProfileNextId, 3)
    ok("removal never decrements allocator")

    // Simulate KCM reload: only remaining customs + persisted next id
    const reloaded = baseConfig({
        customProfilesJson: r.config.customProfilesJson,
        customProfileNextId: r.config.customProfileNextId
    })
    r = Registry.editConfig({
        config: reloaded,
        knownProfiles: known(["claude-default", "claude-custom-1"]),
        event: {
            type: "addCustom",
            provider: "claude",
            path: "/c",
            credPath: "",
            displayName: ""
        }
    })
    const afterAdd = parse(r.patch.customProfilesJson)
    const newId = afterAdd[afterAdd.length - 1].id
    assert.equal(newId, "claude-custom-3")
    assert.notEqual(newId, "claude-custom-2")
    assert.equal(r.patch.customProfileNextId, 4)
    ok("remove highest custom, reload, add never reuses ID")
}

// ---------------------------------------------------------------------------
// malformed JSON uses current fallbacks
// ---------------------------------------------------------------------------

{
    let r = Registry.editConfig({
        config: baseConfig({
            enabledProfilesJson: "{not-json",
            profileDisplayNamesJson: "!!!",
            customProfilesJson: "nope"
        }),
        knownProfiles: known(["a", "b"]),
        event: { type: "setEnabled", profileId: "a", enabled: false }
    })
    // malformed enabled → fallback [] (all on), then disable a → allowlist [b]
    assert.deepEqual(parse(r.patch.enabledProfilesJson), ["b"])
    ok("malformed enabled JSON falls back to []")

    r = Registry.editConfig({
        config: baseConfig({
            profileDisplayNamesJson: "not-an-object",
            customProfilesJson: "bad"
        }),
        knownProfiles: known(["a"]),
        event: { type: "setName", profileId: "a", name: "Named" }
    })
    assert.deepEqual(parse(r.patch.profileDisplayNamesJson), { a: "Named" })
    ok("malformed names JSON falls back to {}")

    r = Registry.editConfig({
        config: baseConfig({
            customProfilesJson: "{bad",
            customProfileNextId: 0
        }),
        knownProfiles: known(["a"]),
        event: {
            type: "addCustom",
            provider: "kimi",
            path: "/token-file",
            credPath: "",
            displayName: ""
        }
    })
    const customs = parse(r.patch.customProfilesJson)
    assert.equal(customs.length, 1)
    assert.equal(customs[0].id, "kimi-custom-1")
    assert.equal(
        customs[0].credPath,
        QC.defaultCredPathForProvider("kimi", "/token-file")
    )
    ok("malformed custom JSON falls back to []")
}

// ---------------------------------------------------------------------------
// Unknown event / no mutation of knownProfiles
// ---------------------------------------------------------------------------

{
    const kp = known(["x"])
    const frozenKp = freezeDeep(kp)
    const r = Registry.editConfig({
        config: baseConfig(),
        knownProfiles: kp,
        event: { type: "notARealEvent" }
    })
    assert.deepEqual(r.patch, {})
    assert.deepEqual(kp, frozenKp)
    ok("unknown event yields empty patch without mutating knownProfiles")
}

console.log("\nAll profile-registry config tests passed (" + passed + ").")
