#!/usr/bin/env node
/**
 * B034 unit tests for per-provider window visibility helpers.
 * Ports the pure algorithm from contents/ui/js/QuotaCommon.js (keep in sync).
 */
import { readFileSync } from "fs"
import { fileURLToPath } from "url"
import { dirname, join } from "path"

const __dirname = dirname(fileURLToPath(import.meta.url))
const srcPath = join(__dirname, "../contents/ui/js/QuotaCommon.js")
const src = readFileSync(srcPath, "utf8")

// Eval the library functions in a sandbox (strip nothing; QML uses plain JS here)
const sandbox = {}
// Provide minimal stubs used only if referenced during load
const fn = new Function(
    "exports",
    src
        .replace(/\.pragma library[\s\S]*?(?=function |var |$)/, "") // drop pragma if any at top
        .replace(/\.import[^\n]*\n/g, "")
    + "\nexports.objectKeyCount = typeof objectKeyCount!=='undefined'?objectKeyCount:undefined;"
    + "exports.isWindowBoolMap = typeof isWindowBoolMap!=='undefined'?isWindowBoolMap:undefined;"
    + "exports.parseVisibleWindowsConfig = parseVisibleWindowsConfig;"
    + "exports.visibilityProviderKey = visibilityProviderKey;"
    + "exports.visibilitySpecForProvider = visibilitySpecForProvider;"
    + "exports.applyVisibility = applyVisibility;"
    + "exports.visibleWindows = visibleWindows;"
    + "exports.makeWindow = makeWindow;"
)
fn(sandbox)

const {
    parseVisibleWindowsConfig,
    visibilityProviderKey,
    visibilitySpecForProvider,
    applyVisibility,
    visibleWindows: visibleQuotaWindows,
    makeWindow
} = sandbox

let failed = 0
function assert(cond, msg) {
    if (!cond) {
        console.error("FAIL:", msg)
        failed++
    } else {
        console.log("ok:", msg)
    }
}

function windowsVisible(wins) {
    return wins.filter(w => w.visible !== false).map(w => w.id)
}

// --- parse: empty ---
{
    const c = parseVisibleWindowsConfig("[]")
    assert(c.mode === "defaults", "empty array → defaults")
    assert(parseVisibleWindowsConfig("{}").mode === "defaults", "empty object → defaults")
    assert(parseVisibleWindowsConfig("").mode === "defaults", "empty string → defaults")
}

// --- parse: legacy allowlist ---
{
    const c = parseVisibleWindowsConfig('["5h","weekly"]')
    assert(c.mode === "globalAllowlist", "legacy array → globalAllowlist")
    assert(c.globalAllowlist.join(",") === "5h,weekly", "legacy ids preserved")
}

// --- parse: per-provider ---
{
    const c = parseVisibleWindowsConfig('{"claude":{"5h":true,"weekly":false},"grok":{"session":true}}')
    assert(c.mode === "perProvider", "object of providers → perProvider")
    assert(c.byProvider.claude.weekly === false, "claude weekly false")
    assert(c.byProvider.grok.session === true, "grok session true")
}

// --- parse: flat global map ---
{
    const c = parseVisibleWindowsConfig('{"5h":true,"weekly":false}')
    assert(c.mode === "globalMap", "flat bool map → globalMap")
}

// --- visibilityProviderKey ---
assert(visibilityProviderKey("claude") === "claude", "key claude")
assert(visibilityProviderKey("opencode", "anthropic") === "claude", "opencode anthropic → claude")
assert(visibilityProviderKey("opencode", "openai") === "codex", "opencode openai → codex")
assert(visibilityProviderKey("opencode", "kimi") === "kimi", "opencode kimi → kimi")
assert(visibilityProviderKey("opencode", "", "anthropic-accounts") === "claude", "opencode profileKey anthropic")
assert(visibilityProviderKey("opencode", "", "openai") === "codex", "opencode profileKey openai")

// --- sample windows ---
const claudeWins = [
    makeWindow("5h", "5h", 10, 0, 0, "primary", true),
    makeWindow("weekly", "7d", 20, 0, 0, "primary", true),
    makeWindow("weekly_fable", "Fable", 30, 0, 0, "extra", false)
]
const grokWins = [
    makeWindow("session", "7d/build", 40, 0, 0, "primary", true),
    makeWindow("weekly", "mo", 50, 0, 0, "primary", true)
]

// --- defaults ---
{
    const out = applyVisibility(claudeWins, null)
    assert(windowsVisible(out).join(",") === "5h,weekly", "defaults hide extras")
}

// --- legacy allowlist only 5h: hides weekly (old global bug reproduction when used alone) ---
{
    const out = applyVisibility(claudeWins, ["5h"])
    assert(windowsVisible(out).join(",") === "5h", "allowlist only 5h")
    const grokOut = applyVisibility(grokWins, ["5h"])
    assert(windowsVisible(grokOut).join(",") === "", "global allowlist 5h blanks grok (root cause)")
}

// --- per-provider fix: claude hide weekly, grok untouched ---
{
    const cfg = parseVisibleWindowsConfig(JSON.stringify({
        claude: { "5h": true, weekly: false, weekly_fable: false }
    }))
    const cSpec = visibilitySpecForProvider(cfg, "claude")
    const gSpec = visibilitySpecForProvider(cfg, "grok")
    assert(gSpec === null, "missing provider → null defaults")
    const cOut = applyVisibility(claudeWins, cSpec)
    const gOut = applyVisibility(grokWins, gSpec)
    assert(windowsVisible(cOut).join(",") === "5h", "claude weekly hidden only")
    assert(windowsVisible(gOut).join(",") === "session,weekly", "grok still defaults")
}

// --- show extra without hiding primaries (override map) ---
{
    const cfg = parseVisibleWindowsConfig(JSON.stringify({
        claude: { weekly_fable: true }
    }))
    const cOut = applyVisibility(claudeWins, visibilitySpecForProvider(cfg, "claude"))
    assert(windowsVisible(cOut).join(",") === "5h,weekly,weekly_fable", "show fable + keep defaults")
    assert(visibleQuotaWindows({ windows: cOut }).map(w => w.id).join(",") === "5h,weekly,weekly_fable",
        "card rows add enabled extra while keeping primaries")
}

// --- hide one primary with sparse override ---
{
    const cfg = parseVisibleWindowsConfig(JSON.stringify({
        claude: { weekly: false }
    }))
    const cOut = applyVisibility(claudeWins, visibilitySpecForProvider(cfg, "claude"))
    assert(windowsVisible(cOut).join(",") === "5h", "sparse weekly:false keeps 5h")
}

// --- re-apply after "config change" uses live spec ---
{
    let cfgRaw = "[]"
    let cfg = parseVisibleWindowsConfig(cfgRaw)
    let out = applyVisibility(claudeWins, visibilitySpecForProvider(cfg, "claude"))
    assert(windowsVisible(out).length === 2, "before config change: 2 primaries")

    cfgRaw = JSON.stringify({ claude: { "5h": true, weekly: false } })
    cfg = parseVisibleWindowsConfig(cfgRaw)
    out = applyVisibility(out, visibilitySpecForProvider(cfg, "claude"))
    assert(windowsVisible(out).join(",") === "5h", "after config change applies without refetch")
}

// --- per-provider array allowlist ---
{
    const cfg = parseVisibleWindowsConfig(JSON.stringify({ claude: ["5h"] }))
    assert(cfg.mode === "perProvider", "provider array entry")
    const cOut = applyVisibility(claudeWins, visibilitySpecForProvider(cfg, "claude"))
    assert(windowsVisible(cOut).join(",") === "5h", "provider allowlist only 5h")
}

if (failed) {
    console.error(`\n${failed} failure(s)`)
    process.exit(1)
}
console.log("\nAll visibility tests passed.")
