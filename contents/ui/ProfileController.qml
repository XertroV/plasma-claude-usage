import QtQuick
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.notification as KNotification
import "js/QuotaCommon.js" as QC
import "js/VisibleQuotaConfig.js" as VQ
import "js/ProfileRefresh.js" as ProfileRefresh
import "js/ProfileRegistry.js" as Registry
import "js/QuotaResetEvents.js" as QuotaReset
import "js/TestCelebrationRequests.js" as TestCelebrationRequests

Item {
    id: controller

    property var plasmoid
    property var i18n
    property var profiles: []
    // Safe 12-field public snapshots for views (built by registry; no secrets)
    property var publicProfileList: []
    property bool discovering: false
    // User-visible discovery failure (parse/exit/path); empty when OK (B017)
    property string discoveryError: ""
    property string lastGlobalUpdate: ""
    // Must be double/real — QML int is 32-bit and overflows Date.now() (~1.7e12)
    property double nowMs: Date.now()
    // Bumped on every profile mutation so UI can re-sync reliably
    property int dataEpoch: 0
    // I006 card celebration: cards watching celebrateGeneration play a fun anim
    // when their profile.id matches celebrateProfileId.
    property string celebrateProfileId: ""
    property int celebrateGeneration: 0

    // One source of truth for mounted CardsView caps and test-request selection.
    readonly property int compactCardLimit: 8
    readonly property int fullCardLimit: 12
    property var testCelebrationReplayState: ({})
    property bool testCelebrationPollBusy: false

    // Config-impact coalescing (moved from main.qml in T005): accumulate kcfg keys
    // then classify via ProfileRegistry.configurationChanged (rediscover > membership > soft).
    property var dirtyConfigKeys: ({})
    property bool configWatchReady: false

    // Staggered refresh queue: [{ id, manual }, ...] — used by refresh-all and autoRefresh (B002)
    property var refreshQueue: []
    // Monotonic fetch generation — never reset on merge, so stale XHR cannot collide (B008)
    property int nextFetchGen: 1
    // Resolved $HOME for safe path expansion (B006) — never trust user path in shell
    property string homeDir: ""
    property bool homeReady: false

    // Auth cool-down between auto retries after OAuth/401 failures (B029)
    readonly property int authRetryHoldMs: 5 * 60 * 1000
    // Absolute ceiling for 429-backed refresh interval (B013)
    readonly property int maxBackoffIntervalMs: 60 * 60 * 1000
    // Auto auth failures before suspending usage API until token change or manual (B029)
    readonly property int maxAuthAutoAttempts: 2
    // Max concurrent credential cat processes (B001: parallel OK when keyed by sourceName)
    readonly property int maxCredInflight: 3

    function allocFetchGen() {
        var g = nextFetchGen
        nextFetchGen = g + 1
        return g
    }

    Component.onCompleted: {
        // Fixed command — no user input (B006)
        homeProbe.connectSource("printf %s \"$HOME\"")
    }

    readonly property string discoverScript: {
        var u = Qt.resolvedUrl("../scripts/discover-profiles.sh").toString()
        if (u.indexOf("file://") === 0) return u.substring(7)
        return u
    }

    readonly property string testCelebrationBridgeScript: {
        var u = Qt.resolvedUrl("../scripts/test-celebration-bridge.sh").toString()
        if (u.indexOf("file://") === 0) return u.substring(7)
        return u
    }

    function tr(text) { return i18n ? i18n.tr(text) : text }

    function cfgValue(key, fallback) {
        if (!plasmoid || !plasmoid.configuration) return fallback
        var v = plasmoid.configuration[key]
        return (v === undefined || v === null) ? fallback : v
    }

    function cfgTruthy(key, defaultTrue) {
        var v = cfgValue(key, defaultTrue !== false)
        if (v === false || v === 0 || v === "false" || v === "0")
            return false
        if (v === true || v === 1 || v === "true" || v === "1")
            return true
        // unset / empty → honour defaultTrue
        if (v === undefined || v === null || v === "")
            return defaultTrue !== false
        return !!v
    }

    readonly property string resetLogScript: {
        var u = Qt.resolvedUrl("../scripts/log-reset.sh").toString()
        if (u.indexOf("file://") === 0) return u.substring(7)
        return u
    }

    /**
     * Snapshot windows for a profile id before a usageResult transition.
     * Empty when the profile is new or has never received windows (first poll).
     */
    function snapshotProfileWindows(profileId) {
        if (!profileId) return []
        for (var i = 0; i < profiles.length; i++) {
            var p = profiles[i]
            if (p && p.id === profileId)
                return QuotaReset.snapshotWindows(p.windows)
        }
        return []
    }

    function findProfileById(profileId) {
        if (!profileId) return null
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i] && profiles[i].id === profileId)
                return profiles[i]
        }
        return null
    }

    /**
     * Grace window for "natural" reset classification: at least one full poll
     * interval plus skew so Claude's default 15m refresh is not marked late.
     */
    function resetClassifyGraceMs(profile) {
        var base = 20 * 60 * 1000
        var interval = 0
        try {
            interval = refreshIntervalMs(profile && profile.provider)
        } catch (e) {
            interval = 0
        }
        // interval + 2m skew, never below the 20m floor
        var fromPoll = (interval > 0 ? interval : 0) + 2 * 60 * 1000
        return fromPoll > base ? fromPoll : base
    }

    /**
     * After an accepted usageResult: detect window resets, celebrate, log.
     * Batches multi-window resets into one notification; logs one file per window.
     */
    function handleQuotaResets(profileId, prevWindows, nextWindows) {
        if (!profileId) return
        var profile = findProfileById(profileId)
        if (!profile) return

        var result = QuotaReset.detectResets({
            prevWindows: prevWindows,
            nextWindows: nextWindows,
            profile: profile,
            nowMs: Date.now(),
            graceMs: resetClassifyGraceMs(profile)
        })
        if (!result || !result.events || !result.events.length)
            return

        var kinds = []
        for (var i = 0; i < result.events.length; i++)
            kinds.push(result.events[i].windowId + "=" + result.events[i].kind)
        console.log("Claude Usage: quota reset", profileId, kinds.join(","))

        // Always pulse the matching account card (local, free, delightful).
        triggerCardCelebration(profileId)

        if (cfgTruthy("notifyOnQuotaReset", true) && result.notification)
            sendQuotaResetNotification(result.notification.title, result.notification.text)

        if (cfgTruthy("logQuotaResets", true) && result.envelopes)
            logQuotaResetEnvelopes(result.envelopes)
    }

    /**
     * Bump celebrateGeneration so any AccountCard bound to this id can party.
     * Also usable from a future in-widget test control.
     */
    function triggerCardCelebration(profileId) {
        if (!profileId) return
        celebrateProfileId = String(profileId)
        celebrateGeneration = celebrateGeneration + 1
    }

    function pollTestCelebration() {
        if (testCelebrationPollBusy) return
        testCelebrationPollBusy = true
        var command = "bash " + QuotaReset.shellQuote(testCelebrationBridgeScript) + " take"
        try {
            testCelebrationSource.connectSource(command)
        } catch (e) {
            testCelebrationPollBusy = false
        }
    }

    function consumeTestCelebration(raw) {
        var result = TestCelebrationRequests.consume(
            raw, testCelebrationReplayState, Date.now())
        testCelebrationReplayState = result.state
        if (!result.accepted) return

        var selectedId = TestCelebrationRequests.selectProfileId(
            publicProfileList,
            {
                compactMaxCards: compactCardLimit,
                fullMaxCards: fullCardLimit
            },
            Math.random)
        if (!selectedId) return
        triggerCardCelebration(selectedId)
    }

    function sendQuotaResetNotification(title, text) {
        if (!title) return
        try {
            var n = resetNotificationComponent.createObject(controller, {
                title: String(title),
                text: String(text || ""),
                iconName: "face-smile-big",
                componentName: "plasma_workspace",
                eventId: "notification"
            })
            if (n)
                n.sendEvent()
        } catch (e) {
            console.log("Claude Usage: reset notification failed", e)
        }
    }

    function logQuotaResetEnvelopes(envelopes) {
        if (!envelopes || !envelopes.length) return
        var settings = {
            enabled: true,
            configuredRoot: String(cfgValue("responseCachePath", "") || ""),
            homeDir: homeDir || "",
            logScript: resetLogScript
        }
        for (var i = 0; i < envelopes.length; i++) {
            var cmd = QuotaReset.buildLogCommand(settings, envelopes[i], envelopes[i].observedAtMs)
            if (!cmd) continue
            // B006: uniqueness tag is shell no-op with fully quoted payload;
            // never interpolate raw profileId/windowId into unquoted shell words.
            var tag = "RESET_LOG=" + String(envelopes[i].profileId || "p")
                    + ":" + String(envelopes[i].windowId || "w")
                    + ":" + String(envelopes[i].observedAtMs || Date.now())
                    + ":" + i
            var src = ": " + shellQuote(tag) + "; " + cmd
            try {
                resetLogWriter.connectSource(src)
            } catch (e) {
                console.log("Claude Usage: reset log connect failed", e)
            }
        }
    }

    /**
     * Multi-profile dashboard is the default (B004).
     * Legacy single-profile mode only when multiProfileMode is explicitly false.
     * (Old trap: any credentialsPath / displayName / non-claude provider forced legacy.)
     * Filtering/matching for discovery candidates lives in ProfileRegistry.
     */
    function isLegacySingleInstance() {
        var multi = cfgValue("multiProfileMode", true)
        // Kcfg bool may arrive as string in some Plasma paths
        if (multi === false || multi === "false" || multi === 0 || multi === "0")
            return true
        return false
    }

    /**
     * Hide/show a profile on the panel (B032). Registry setHidden owns allowlist
     * serialisation, immediate membership, and optional re-enable refresh.
     * Persist effect writes enabledProfilesJson; config watch may re-apply membership.
     */
    function setProfileHidden(profileId, hidden) {
        if (!profileId) return
        applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: {
                type: "setHidden",
                profileId: profileId,
                hidden: !!hidden
            },
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))
    }

    /**
     * Main reports a single changed kcfg key; controller coalesces and classifies.
     */
    function noteRegistryConfigChanged(key) {
        if (!key || !configWatchReady) return
        var map = dirtyConfigKeys || {}
        // QML may give a frozen/var map — copy then reassign
        var next = {}
        for (var k in map) {
            if (map.hasOwnProperty(k))
                next[k] = map[k]
        }
        next[key] = true
        dirtyConfigKeys = next
        configCoalesceTimer.restart()
    }

    function flushRegistryConfigDirty() {
        var map = dirtyConfigKeys || {}
        var keys = []
        for (var k in map) {
            if (map.hasOwnProperty(k) && map[k])
                keys.push(k)
        }
        dirtyConfigKeys = ({})
        if (keys.length === 0)
            return
        applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: { type: "configurationChanged", keys: keys },
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))
    }

    /**
     * Production visibility adapter for I003 ProfileRegistry.
     * Opaque specs from VisibleQuotaConfig; time percentages stay outside VQ.
     */
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

    /**
     * Exact kcfg snapshot consumed by ProfileRegistry.transition / editConfig.
     * Always re-read live configuration (never cache visibleWindowsJson policy).
     */
    function registryConfigSnapshot() {
        return {
            multiProfileMode: cfgValue("multiProfileMode", true),
            provider: cfgValue("provider", "claude"),
            opencodeSubProvider: cfgValue("opencodeSubProvider", "anthropic"),
            credentialsPath: cfgValue("credentialsPath", ""),
            displayName: cfgValue("displayName", ""),
            discoverOnLoad: cfgValue("discoverOnLoad", true),
            enabledProfilesJson: cfgValue("enabledProfilesJson", "[]"),
            profileDisplayNamesJson: cfgValue("profileDisplayNamesJson", "{}"),
            customProfilesJson: cfgValue("customProfilesJson", "[]"),
            customProfileNextId: cfgValue("customProfileNextId", 0),
            visibleWindowsJson: cfgValue("visibleWindowsJson", "[]")
        }
    }

    /**
     * Single registry result adapter: assign internal/public arrays once on
     * accepted state change, then interpret effects (discover/refresh/persist/warning).
     */
    function applyRegistryResult(result) {
        if (!result)
            return false
        if (result.accepted) {
            if (result.state && result.state.profiles)
                profiles = result.state.profiles
            publicProfileList = result.publicProfiles || []
            dataEpoch++
        }
        var effects = result.effects || []
        for (var i = 0; i < effects.length; i++) {
            var effect = effects[i]
            if (!effect || !effect.type)
                continue
            switch (effect.type) {
            case "discover":
                // Preserve legacy bootstrap row while discovery runs (empty legacy)
                if (isLegacySingleInstance() && profiles.length === 0)
                    bootstrapLegacyProfiles()
                discoverProfiles()
                break
            case "refreshAll":
                staggerRefreshAll()
                break
            case "refresh":
                var ids = effect.ids || []
                for (var j = 0; j < ids.length; j++) {
                    if (ids[j])
                        queueProfileRefresh(ids[j], effect.manual !== false)
                }
                kickRefreshQueue()
                break
            case "persist":
                if (effect.values && plasmoid && plasmoid.configuration) {
                    var vals = effect.values
                    for (var key in vals) {
                        if (!vals.hasOwnProperty(key))
                            continue
                        // Only assign when value actually changes (avoid config storms)
                        if (plasmoid.configuration[key] !== undefined
                                && String(plasmoid.configuration[key]) !== String(vals[key]))
                            plasmoid.configuration[key] = vals[key]
                    }
                }
                break
            case "warning":
                console.log("Claude Usage: registry warning",
                            effect.code || "", effect.profileId || "")
                break
            }
        }
        return !!result.accepted
    }

    /**
     * Stable ID patch through the registry (optional generation precondition).
     * Rejects patches that carry windows — those must use usageResult.
     */
    function registryPatch(profileId, patch, expectedGeneration) {
        if (!profileId || !patch)
            return false
        var event = {
            type: "patch",
            profileId: profileId,
            patch: patch
        }
        if (expectedGeneration !== undefined && expectedGeneration !== null)
            event.expectedGeneration = expectedGeneration
        return applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: event,
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))
    }

    function refreshIntervalMs(provider) {
        if (provider === "claude") {
            var cm = cfgValue("claudeRefreshMinutes", 15)
            if (cm < 10) cm = 10
            return cm * 60000
        }
        return cfgValue("refreshInterval", 5) * 60000
    }

    function bootstrapLegacyProfiles() {
        if (!isLegacySingleInstance() || profiles.length > 0) return

        var credPath = cfgValue("credentialsPath", "")
        var provider = cfgValue("provider", "claude")
        var effectiveProvider = provider
        var isFlat = false

        if (credPath) {
            if (credPath.indexOf("/.kimi-for-coding") >= 0 || credPath.indexOf("/.api-zai") >= 0
                    || credPath.indexOf("/.minimax") >= 0) {
                isFlat = true
            }
            if (provider === "opencode") {
                var subCfg = cfgValue("opencodeSubProvider", "anthropic")
                if (subCfg === "kimi") effectiveProvider = "kimi"
                else if (subCfg === "zai") effectiveProvider = "zai"
                else if (subCfg === "openai") effectiveProvider = "codex"
                else if (subCfg === "anthropic") effectiveProvider = "claude"
            }
            applyDiscoveredCandidates([{
                id: "legacy-config",
                provider: effectiveProvider,
                profileKey: "legacy",
                configDir: "",
                credPath: credPath,
                credInode: "legacy-config",
                isFlatFile: isFlat
            }])
            return
        } else if (provider === "codex") {
            credPath = "$HOME/.codex/auth.json"
        } else if (provider === "zai") {
            // Parity with pre-refactor + OpenCode layout (not a bare ~/.api-zai file)
            credPath = "$HOME/.local/share/opencode/auth.json"
            isFlat = false
            effectiveProvider = "zai"
        } else if (provider === "opencode") {
            var sub = cfgValue("opencodeSubProvider", "anthropic")
            if (sub === "kimi") {
                credPath = "$HOME/.kimi-for-coding"
                isFlat = true
                effectiveProvider = "kimi"
            } else if (sub === "zai") {
                credPath = "$HOME/.local/share/opencode/auth.json"
                isFlat = false
                effectiveProvider = "zai"
            } else if (sub === "openai") {
                credPath = "$HOME/.codex/auth.json"
                effectiveProvider = "codex"
            } else if (sub === "anthropic") {
                credPath = "$HOME/.config/opencode/anthropic-accounts.json"
                effectiveProvider = "claude"
            } else {
                credPath = "$HOME/.local/share/opencode/auth.json"
            }
        } else if (provider === "grok") {
            // Prefer default grok path; discovery/filter will match grok-N when present
            credPath = "$HOME/.grok/auth.json"
            effectiveProvider = "grok"
        } else {
            return
        }

        applyDiscoveredCandidates([{
            id: "legacy-bootstrap",
            provider: effectiveProvider,
            profileKey: "legacy",
            configDir: "",
            credPath: credPath,
            credInode: "legacy-bootstrap",
            isFlatFile: isFlat
        }])
    }

    function discoverProfiles() {
        discovering = true
        discoveryError = ""
        discoverSource.connectSource("bash " + shellQuote(discoverScript))
    }

    /** Set discoveryError from exit/stderr and stop the discovering spinner (B017). */
    function failDiscovery(shortMsg, exitCode, stderr) {
        var snip = String(stderr || "").replace(/\s+/g, " ").trim()
        if (snip.length > 120)
            snip = snip.substring(0, 117) + "..."
        var msg = shortMsg || "Discovery failed"
        // Common install/runtime hints when stderr is unhelpful
        if (!snip) {
            if (exitCode === 127)
                snip = "command not found"
            else if (exitCode && exitCode !== 0)
                snip = "exit " + exitCode
        }
        discoveryError = snip ? (msg + ": " + snip) : msg
        discovering = false
        dataEpoch++
        console.log("Claude Usage: discovery failed —", discoveryError)
    }

    /**
     * Thin discovery adapter: valid candidate list crosses registry `discovered`.
     * Failure must not call this (failDiscovery leaves registry state unchanged).
     */
    function applyDiscoveredCandidates(candidates) {
        var result = Registry.transition({
            state: { profiles: profiles },
            event: { type: "discovered", candidates: candidates || [] },
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        })
        discoveryError = ""
        discovering = false
        console.log("Claude Usage: discovered",
                    (result && result.state && result.state.profiles)
                        ? result.state.profiles.length : 0,
                    "profile(s)")
        applyRegistryResult(result)
    }

    function findProfileIndex(id) {
        for (var i = 0; i < profiles.length; i++) {
            if (profiles[i].id === id) return i
        }
        return -1
    }

    function loadingStats() {
        var total = 0
        var done = 0
        var loading = 0
        for (var i = 0; i < profiles.length; i++) {
            var p = profiles[i]
            if (!p || p.enabled === false) continue
            total++
            if (p.loading)
                loading++
            else if (p.error || (p.windows && p.windows.length) || p.lastFetchMs)
                done++
        }
        return { total: total, done: done, loading: loading }
    }

    function effectiveRefreshIntervalMs(p) {
        var base = refreshIntervalMs(p.provider)
        var mult = p.backoffMultiplier || 1
        return Math.min(base * mult, maxBackoffIntervalMs)
    }

    function isAutoRefreshHeld(p, now) {
        if (!p) return true
        // Hold only — authSuspended still allows credential re-read so a rotated
        // token can resume without a manual click (B029). Usage API is gated later.
        if (p.autoRefreshHoldUntilMs && now < p.autoRefreshHoldUntilMs) return true
        return false
    }

    function queueProfileRefresh(profileId, manual) {
        if (!profileId) return
        var q = refreshQueue.slice()
        for (var i = 0; i < q.length; i++) {
            if (q[i].id === profileId) {
                if (manual)
                    q[i] = { id: profileId, manual: true }
                refreshQueue = q
                return
            }
        }
        q.push({ id: profileId, manual: !!manual })
        refreshQueue = q
    }

    function kickRefreshQueue() {
        if (refreshQueue.length === 0) return
        if (staggerRefresh.running) return
        // First item immediately; remainder every stagger interval (B002)
        if (drainOneRefresh() && refreshQueue.length > 0)
            staggerRefresh.start()
    }

    function drainOneRefresh() {
        // One pass over current queue length so a loading head cannot starve others
        var skippedLoading = 0
        var maxLook = refreshQueue.length
        while (refreshQueue.length > 0 && skippedLoading < maxLook) {
            var item = refreshQueue[0]
            var idx = findProfileIndex(item.id)
            if (idx < 0 || !profiles[idx]) {
                refreshQueue = refreshQueue.slice(1)
                maxLook = refreshQueue.length
                skippedLoading = 0
                continue
            }
            var p = profiles[idx]
            if (p.loading) {
                refreshQueue = refreshQueue.slice(1).concat([item])
                skippedLoading++
                continue
            }
            if (!item.manual && isAutoRefreshHeld(p, Date.now())) {
                refreshQueue = refreshQueue.slice(1)
                maxLook = refreshQueue.length
                skippedLoading = 0
                continue
            }
            // Only dequeue if the refresh transaction accepted the job
            if (!startProfileRefresh(idx, !!item.manual)) {
                // Reader busy or row already loading — rotate to end
                refreshQueue = refreshQueue.slice(1).concat([item])
                skippedLoading++
                continue
            }
            refreshQueue = refreshQueue.slice(1)
            return true
        }
        // Still have loading items — keep timer alive so we retry after they settle
        return refreshQueue.length > 0
    }

    function staggerRefreshAll() {
        staggerRefresh.stop()
        refreshQueue = []
        if (profiles.length === 0) return
        // Manual full refresh: clear per-profile auto holds so user can force retry (B029)
        // Skip hidden profiles (enabled:false) — they stay off the panel (B032).
        for (var i = 0; i < profiles.length; i++) {
            if (!profiles[i] || profiles[i].enabled === false) continue
            queueProfileRefresh(profiles[i].id, true)
        }
        kickRefreshQueue()
    }

    function refreshAll() {
        staggerRefreshAll()
    }

    function refreshProfile(profileId) {
        var idx = findProfileIndex(profileId)
        if (idx < 0) return
        // Manual single-profile refresh — queue so we don't drop when credReader busy
        queueProfileRefresh(profileId, true)
        kickRefreshQueue()
    }

    function shellQuote(path) {
        return "'" + String(path).replace(/'/g, "'\\''") + "'"
    }

    /**
     * Build a unique executable source that always shell-quotes the path (B006)
     * and embeds the profile id so onNewData cannot mis-attribute (B001).
     * Format:  : 'cu-id=<profileId>'; cat '<absolute-path>' 2>/dev/null
     */
    function catCommand(path, profileId) {
        var abs = QC.expandToAbsolute(path, homeDir)
        if (!abs) {
            // Home not resolved yet for a home-relative path
            return ""
        }
        // Always quote — path may contain spaces, ;, $, etc. (literal filename only)
        var cat = "cat " + shellQuote(abs) + " 2>/dev/null"
        if (profileId) {
            // Unique sourceName per profile; shell no-op with fully quoted tag
            return ": " + shellQuote("cu-id=" + String(profileId)) + "; " + cat
        }
        return cat
    }

    function pendingCredCount() {
        var n = 0
        var m = credReader._pendingBySource
        if (!m) return 0
        for (var k in m) {
            if (m.hasOwnProperty(k) && m[k]) n++
        }
        return n
    }

    /**
     * Thin cache port: forward settled exchange to LocalResponseCache.
     */
    function recordRefreshExchange(exchange) {
        responseCache.recordExchange(exchange)
    }

    /**
     * I002 production entry: snapshot profile, allocate generation, run transaction.
     * Returns false when the credential port cannot start (busy / home / path)
     * so the global queue can rotate. Holds and loading are checked by drainOneRefresh.
     */
        /**
     * Cache/metadata helper: map opencode profile rows to their concrete sub-provider.
     * Retained for any non-transaction callers; I005 pipeline has its own copy for cache.
     */
    function effectiveProvider(profile) {
        if (profile.provider === "opencode") return profile.opencodeSlot || "anthropic"
        return profile.provider
    }


    function startProfileRefresh(idx, manual) {
        if (idx < 0 || idx >= profiles.length) return true
        var p = profiles[idx]
        if (!p) return true
        // Avoid stacking concurrent loads for the same row (B001/B002)
        if (p.loading) return false
        if (!manual && isAutoRefreshHeld(p, Date.now())) return true

        // Shallow snapshot for the refresh transaction (do not share mutable arrays)
        var snapshot = {}
        for (var snapK in p) {
            if (!p.hasOwnProperty(snapK)) continue
            if (Array.isArray(p[snapK])) snapshot[snapK] = p[snapK].slice()
            else snapshot[snapK] = p[snapK]
        }
        // Providers.prepare uses profile.opencodeAccountIndex (was cfgValue in extractOpencodeAuth)
        var ocIdx = parseInt(cfgValue("opencodeAccountIndex", 0), 10)
        if (isNaN(ocIdx) || ocIdx < 0)
            ocIdx = 0
        snapshot.opencodeAccountIndex = ocIdx

        var generation = allocFetchGen()
        console.log("Claude Usage: startProfileRefresh", snapshot.id, snapshot.provider,
                    "manual=", !!manual, "gen=", generation)

        return ProfileRefresh.run({
            profile: snapshot,
            generation: generation,
            manual: !!manual,
            policy: {
                authRetryHoldMs: authRetryHoldMs,
                maxBackoffIntervalMs: maxBackoffIntervalMs,
                maxAuthAutoAttempts: maxAuthAutoAttempts,
                baseRefreshIntervalMs: refreshIntervalMs(snapshot.provider)
            }
        }, {
            readCredentials: readRefreshCredentials,
            requestHttp: requestRefreshHttp,
            recordExchange: recordRefreshExchange,
            now: function() { return Date.now() }
        }, applyRefreshTransition)
    }

    /**
     * Thin credential port: capacity / HOME / path / shell safety only.
     * Stores sourceName → { profileId, generation, callback }; no provider policy.
     */
    function readRefreshCredentials(request, callback) {
        if (!request || typeof callback !== "function")
            return false
        if (pendingCredCount() >= maxCredInflight)
            return false

        var rawPath = String(request.path || "")
        var needsHome = false
        if (rawPath.indexOf("~/") === 0 || rawPath === "~"
                || rawPath.indexOf("$HOME") === 0 || rawPath.indexOf("${HOME}") === 0)
            needsHome = true
        if (needsHome && !homeReady)
            return false

        var cmd = catCommand(request.path, request.profileId)
        if (!cmd)
            return false

        var map = {}
        var prev = credReader._pendingBySource
        if (prev) {
            for (var k in prev) {
                if (prev.hasOwnProperty(k)) map[k] = prev[k]
            }
        }
        // B001: key by full sourceName → request/callback (never array index)
        map[cmd] = {
            profileId: request.profileId,
            generation: request.generation,
            callback: callback
        }
        credReader._pendingBySource = map
        console.log("Claude Usage: readRefreshCredentials", request.profileId,
                    "gen=", request.generation, "cmd=", cmd)
        credReader.connectSource(cmd)
        return true
    }

    /**
     * Thin HTTP port: one XHR from a request spec, once-only settlement.
     * No provider/status/JSON/auth/retry policy.
     */
    function requestRefreshHttp(request, callback) {
        if (!request || typeof callback !== "function")
            return
        var method = request.method || "GET"
        var url = request.url || ""
        var headers = request.headers || {}
        var timeoutMs = request.timeoutMs > 0 ? request.timeoutMs : 25000
        var settled = false
        var xhr = new XMLHttpRequest()
        xhr.open(method, url)
        xhr.timeout = timeoutMs
        for (var h in headers) {
            if (headers.hasOwnProperty(h) && headers[h] !== undefined && headers[h] !== null)
                xhr.setRequestHeader(h, headers[h])
        }

        function settle(status, responseText, fromTimeout) {
            if (settled) return
            settled = true
            callback({
                key: request.key,
                profileId: request.profileId,
                generation: request.generation,
                provider: request.provider,
                opencodeSlot: request.opencodeSlot,
                endpoint: request.endpoint,
                url: url,
                status: status || 0,
                responseText: responseText || "",
                fromTimeout: !!fromTimeout
            })
        }

        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            settle(xhr.status || 0, xhr.responseText || "", false)
        }
        xhr.ontimeout = function() {
            settle(0, "", true)
        }
        xhr.send()
    }

    /**
     * Map transaction error metadata to existing translated UI strings.
     */
    function translateRefreshError(transition, fallback) {
        var err = transition && transition.error ? transition.error : {}
        var code = err.code || ""
        if (code === "not_logged_in") return tr("Not logged in")
        if (code === "token_expired") return tr("Token expired")
        if (code === "rate_limited") return tr("Rate limited")
        if (code === "timeout") return tr("API error") + " (timeout)"
        if (code === "network") return tr("API error") + " (network error)"
        if (code === "http") return tr("API error") + " (" + (err.status || 0) + ")"
        if (code === "parse") return "Parse error"
        if (code === "auth_suspended")
            return fallback || tr("Token expired")
        // Fallback: re-translate known English patches from ProfileRefresh.js
        var msg = fallback !== undefined && fallback !== null ? String(fallback) : ""
        if (msg === "Not logged in") return tr("Not logged in")
        if (msg === "Token expired") return tr("Token expired")
        if (msg === "Rate limited") return tr("Rate limited")
        if (msg === "Parse error") return "Parse error"
        if (msg.indexOf("API error (") === 0) {
            var detail = msg.substring("API error (".length, msg.length - 1)
            if (detail === "timeout") return tr("API error") + " (timeout)"
            if (detail === "network error") return tr("API error") + " (network error)"
            return tr("API error") + " (" + detail + ")"
        }
        return msg || tr("API error")
    }

    /**
     * Mechanical store adapter for ProfileRefresh transitions.
     * Resolves by stable profile ID + generation (never by mutable array index across async).
     * Success → registry usageResult (visibility/time inside the registry);
     * started/credentials/failures → registry patch.
     */
    function applyRefreshTransition(transition) {
        if (!transition || !transition.profileId)
            return
        var idx = findProfileIndex(transition.profileId)
        if (idx < 0)
            return
        var p = profiles[idx]
        if (!p)
            return

        if (transition.type === "started") {
            var started = {}
            var sp = transition.patch || {}
            for (var sk in sp) {
                if (sp.hasOwnProperty(sk))
                    started[sk] = sp[sk]
            }
            started.refreshGeneration = transition.generation
            // No expectedGeneration: started *assigns* the generation for this run
            applyRegistryResult(Registry.transition({
                state: { profiles: profiles },
                event: {
                    type: "patch",
                    profileId: transition.profileId,
                    patch: started
                },
                config: registryConfigSnapshot(),
                visibility: registryVisibilityAdapter(),
                nowMs: nowMs
            }))
            return
        }

        // credentials + all terminal outcomes require a current generation
        if (p.refreshGeneration !== transition.generation) {
            console.log("Claude Usage: drop stale transition", transition.type,
                        transition.profileId, "gen=", transition.generation,
                        "cur=", p.refreshGeneration)
            return
        }

        if (transition.type === "credentials") {
            applyRegistryResult(Registry.transition({
                state: { profiles: profiles },
                event: {
                    type: "patch",
                    profileId: transition.profileId,
                    expectedGeneration: transition.generation,
                    patch: transition.patch || {}
                },
                config: registryConfigSnapshot(),
                visibility: registryVisibilityAdapter(),
                nowMs: nowMs
            }))
            return
        }

        if (transition.type === "success") {
            if (transition.usageResult) {
                var successPatch = {}
                var us = transition.patch || {}
                for (var uk in us) {
                    if (us.hasOwnProperty(uk) && uk !== "windows")
                        successPatch[uk] = us[uk]
                }
                successPatch.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
                if (successPatch.lastFetchMs === undefined)
                    successPatch.lastFetchMs = Date.now()
                // I006: snapshot prior windows before registry replaces them
                var prevWinsSuccess = snapshotProfileWindows(transition.profileId)
                var usageAccepted = applyRegistryResult(Registry.transition({
                    state: { profiles: profiles },
                    event: {
                        type: "usageResult",
                        profileId: transition.profileId,
                        expectedGeneration: transition.generation,
                        usageResult: transition.usageResult,
                        patch: successPatch
                    },
                    config: registryConfigSnapshot(),
                    visibility: registryVisibilityAdapter(),
                    nowMs: nowMs
                }))
                if (usageAccepted)
                    lastGlobalUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
                var wins = transition.usageResult.windows || []
                var primaryCount = 0
                for (var pi = 0; pi < wins.length; pi++) {
                    if (wins[pi] && wins[pi].role === "primary")
                        primaryCount++
                }
                console.log("Claude Usage: usageResult", transition.profileId,
                            "accepted=", usageAccepted,
                            "windows=", wins.length, "primary=", primaryCount)
                if (usageAccepted)
                    handleQuotaResets(transition.profileId, prevWinsSuccess, wins)
            } else {
                // Defensive: never leave loading stuck if a success lacks a body
                var emptyPatch = {}
                var es = transition.patch || {}
                for (var ek in es) {
                    if (es.hasOwnProperty(ek) && ek !== "windows")
                        emptyPatch[ek] = es[ek]
                }
                if (emptyPatch.loading === undefined)
                    emptyPatch.loading = false
                applyRegistryResult(Registry.transition({
                    state: { profiles: profiles },
                    event: {
                        type: "patch",
                        profileId: transition.profileId,
                        expectedGeneration: transition.generation,
                        patch: emptyPatch
                    },
                    config: registryConfigSnapshot(),
                    visibility: registryVisibilityAdapter(),
                    nowMs: nowMs
                }))
            }
            return
        }

        // Terminal failure / suspension: apply patch with translated error strings
        var patch = {}
        var src = transition.patch || {}
        for (var pk in src) {
            if (src.hasOwnProperty(pk) && pk !== "windows")
                patch[pk] = src[pk]
        }
        if (patch.error !== undefined)
            patch.error = translateRefreshError(transition, patch.error)
        applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: {
                type: "patch",
                profileId: transition.profileId,
                expectedGeneration: transition.generation,
                patch: patch
            },
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))

        if (transition.type === "auth_error")
            console.log("Claude Usage: auth failure via transaction", transition.profileId,
                        "count=", patch.authFailCount, "suspended=", !!patch.authSuspended)
        else if (transition.type === "rate_limited")
            console.log("Claude Usage: 429 backoff via transaction", transition.profileId,
                        "mult=", patch.backoffMultiplier)
        else if (transition.type === "auth_suspended")
            console.log("Claude Usage: auth still suspended, skip API", transition.profileId)
        else
            console.log("Claude Usage: terminal", transition.type, transition.profileId,
                        "error=", patch.error)
    }


    /**
     * Apply normalised usage through the registry usageResult transition.
     * Optional `patch` carries loading/error/auth/backoff fields (never windows).
     * Visibility/time always run inside ProfileRegistry via the production adapter.
     * Legacy callers (fetchUsage/fetchGrok) omit patch.
     */
    function applyUsageResult(idx, result, patch) {
        if (idx < 0 || idx >= profiles.length || !result) return
        var p = profiles[idx]
        if (!p || !p.id) return

        var out = {}
        if (patch) {
            for (var k in patch) {
                if (patch.hasOwnProperty(k) && k !== "windows")
                    out[k] = patch[k]
            }
        } else {
            var clear = clearFailureStatePatch()
            out.loading = false
            out.error = ""
            out.lastFetchMs = Date.now()
            out.backoffMultiplier = clear.backoffMultiplier
            out.authFailCount = clear.authFailCount
            out.authSuspended = clear.authSuspended
            out.autoRefreshHoldUntilMs = clear.autoRefreshHoldUntilMs
            out.lastFailedToken = clear.lastFailedToken
        }
        out.lastUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
        if (out.lastFetchMs === undefined)
            out.lastFetchMs = Date.now()

        var gen = p.refreshGeneration
        if (gen === undefined || gen === null)
            gen = 0

        // I006: snapshot prior windows before registry replaces them
        var prevWinsApply = QuotaReset.snapshotWindows(p.windows)
        var accepted = applyRegistryResult(Registry.transition({
            state: { profiles: profiles },
            event: {
                type: "usageResult",
                profileId: p.id,
                expectedGeneration: gen,
                usageResult: {
                    windows: result.windows,
                    planName: result.planName,
                    bankedResets: result.bankedResets
                },
                patch: out
            },
            config: registryConfigSnapshot(),
            visibility: registryVisibilityAdapter(),
            nowMs: nowMs
        }))
        if (accepted)
            lastGlobalUpdate = Qt.formatTime(new Date(), "hh:mm:ss")
        var winCount = (result.windows && result.windows.length) || 0
        console.log("Claude Usage: applyUsageResult id=", p.id,
                    "accepted=", accepted, "windows=", winCount)
        if (accepted)
            handleQuotaResets(p.id, prevWinsApply, result.windows)
    }


    // B027: only advance the clock. Do NOT reassign `profiles` (or bump dataEpoch).
    // Replacing the array every second forced CardsView/Repeaters to rebuild delegates,
    // which destroyed ToolTips mid-hover. Countdown + pace bars bind to nowMs instead.
    function tickWindows() {
        nowMs = Date.now()
        // Keep stored timePercent roughly current for any non-binding consumers, but
        // mutate in place — never replace profiles/windows arrays on the tick path.
        for (var i = 0; i < profiles.length; i++) {
            var wins = profiles[i] && profiles[i].windows
            if (!wins || !wins.length) continue
            for (var j = 0; j < wins.length; j++) {
                if (wins[j])
                    QC.updateTimePercent(wins[j], nowMs)
            }
        }
        // B018 intent (notify UI of tick) is satisfied without profiles reassignment
        // or dataEpoch bump — B027 keeps tooltips stable; UI binds to nowMs instead.
    }

    function dueProfiles() {
        var due = []
        var now = Date.now()
        for (var i = 0; i < profiles.length; i++) {
            var p = profiles[i]
            if (!p || p.enabled === false) continue
            if (p.loading) continue
            // Hard cool-down (auth retry spacing or 429 hold)
            if (isAutoRefreshHeld(p, now)) continue
            // After first auth fail, next attempt is gated by hold only (~5m), not full provider interval
            if ((p.authFailCount || 0) > 0 && !p.authSuspended) {
                due.push(p.id)
                continue
            }
            // authSuspended: still re-cat on normal interval to detect token rotation (no API if same)
            var interval = effectiveRefreshIntervalMs(p)
            if (!p.lastFetchMs || (now - p.lastFetchMs) >= interval)
                due.push(p.id)
        }
        return due
    }

    Plasma5Support.DataSource {
        id: discoverSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""
            var exitCode = data["exit code"] !== undefined ? data["exit code"] : data["exitCode"]
            disconnectSource(sourceName)
            var trimmed = String(stdout).replace(/^\s+|\s+$/g, "")
            // Non-zero exit with empty/invalid body → surface to panel (B017)
            if (!trimmed) {
                if (exitCode && exitCode !== 0) {
                    failDiscovery("Discovery failed", exitCode, stderr)
                    return
                }
                // Empty stdout + success → no profiles found
                discoveryError = ""
                applyDiscoveredCandidates([])
                return
            }
            try {
                var list = JSON.parse(trimmed)
                if (!Array.isArray(list)) {
                    failDiscovery("Discovery returned invalid data", exitCode, stderr)
                    return
                }
                if (exitCode && exitCode !== 0)
                    console.log("Claude Usage: discovery exit=", exitCode, "stderr=", stderr)
                applyDiscoveredCandidates(list)
            } catch (e) {
                console.log("Claude Usage: discovery parse error", e, stderr)
                failDiscovery("Discovery failed", exitCode, stderr || String(e))
            }
        }
    }

    // Atomic one-shot bridge claim. The payload is data only and is never evaluated.
    Plasma5Support.DataSource {
        id: testCelebrationSource
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            disconnectSource(sourceName)
            controller.testCelebrationPollBusy = false
            if (String(stdout).trim() === "") return
            controller.consumeTestCelebration(String(stdout))
        }
    }

    // Resolve $HOME once with a fixed command (B006) — never interpolate user strings here
    Plasma5Support.DataSource {
        id: homeProbe
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var stdout = (data["stdout"] || "").trim()
            disconnectSource(sourceName)
            if (stdout && stdout.charAt(0) === "/") {
                controller.homeDir = stdout
                controller.homeReady = true
                console.log("Claude Usage: homeDir=", controller.homeDir)
                // Resume any queued credential loads waiting on HOME
                controller.kickRefreshQueue()
            } else {
                console.log("Claude Usage: home probe failed, stdout=", stdout)
                // Best-effort fallback so absolute paths still work
                controller.homeReady = true
            }
        }
    }

    LocalResponseCache {
        id: responseCache
        enabled: controller.cfgValue("cacheResponses", true) !== false
                 && controller.cfgValue("cacheResponses", true) !== 0
                 && controller.cfgValue("cacheResponses", true) !== "false"
                 && controller.cfgValue("cacheResponses", true) !== "0"
        configuredRoot: String(controller.cfgValue("responseCachePath", "") || "")
        homeDir: controller.homeDir
    }

    // I006: celebratory Plasma notifications on quota window reset
    Component {
        id: resetNotificationComponent
        KNotification.Notification {
            autoDelete: true
        }
    }

    // I006: durable reset event log (hist + latest + events.jsonl)
    Plasma5Support.DataSource {
        id: resetLogWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var exitCode = data["exit code"] !== undefined
                    ? data["exit code"] : data["exitCode"]
            var stderr = data["stderr"] || ""
            disconnectSource(sourceName)
            if (exitCode && exitCode !== 0)
                console.log("Claude Usage: reset log exit=", exitCode, "stderr=", stderr)
        }
    }

    Plasma5Support.DataSource {
        id: credReader
        engine: "executable"
        connectedSources: []
        // B001: sourceName → { profileId, generation, callback } (never array index)
        property var _pendingBySource: ({})

        // Thin credential port completion: disconnect, deliver raw stdout, kick queue.
        // Provider/auth/retry/fetch decisions live in ProfileRefresh (I002).
        onNewData: function(sourceName, data) {
            var stdout = data["stdout"] || ""
            var stderr = data["stderr"] || ""
            var exitCode = data["exit code"] !== undefined ? data["exit code"] : data["exitCode"]
            disconnectSource(sourceName)

            var map = credReader._pendingBySource || {}
            var pending = map[sourceName] || null
            // Remove this source from the pending map
            var nextMap = {}
            for (var k in map) {
                if (map.hasOwnProperty(k) && k !== sourceName)
                    nextMap[k] = map[k]
            }
            credReader._pendingBySource = nextMap

            if (!pending || typeof pending !== "object" || typeof pending.callback !== "function") {
                console.log("Claude Usage: drop unmatched cred reply for", sourceName)
                kickRefreshQueue()
                return
            }

            console.log("Claude Usage: credentials stdout len=", stdout.length,
                        "exit=", exitCode, "id=", pending.profileId, "gen=", pending.generation)
            try {
                pending.callback({
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode
                })
            } catch (e) {
                console.log("Claude Usage: credential callback error", e)
            }
            // Next profile can start cat while XHR runs (loading still true on this row)
            kickRefreshQueue()
        }
    }

    // Coalesce multi-key KCM Apply storms (50ms) before registry classification
    Timer {
        id: configCoalesceTimer
        interval: 50
        repeat: false
        onTriggered: controller.flushRegistryConfigDirty()
    }

    Timer {
        id: staggerRefresh
        interval: 2000
        repeat: true
        onTriggered: {
            if (!controller.drainOneRefresh() || controller.refreshQueue.length === 0)
                stop()
        }
    }

    Timer {
        id: testCelebrationPollTimer
        interval: 900
        running: true
        repeat: true
        onTriggered: controller.pollTestCelebration()
    }

    Timer {
        id: liveClock
        interval: 1000
        running: profiles.length > 0
        repeat: true
        onTriggered: controller.tickWindows()
    }

    Timer {
        id: autoRefresh
        interval: 60000
        running: profiles.length > 0
        repeat: true
        onTriggered: {
            // B002: enqueue due profiles and stagger; never burst refresh starts
            var due = controller.dueProfiles()
            for (var i = 0; i < due.length; i++)
                controller.queueProfileRefresh(due[i], false)
            controller.kickRefreshQueue()
        }
    }

}