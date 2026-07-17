/*
    SPDX-FileCopyrightText: 2025 izll
    SPDX-License-Identifier: GPL-3.0-or-later
*/

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.plasma.plasma5support as Plasma5Support
import "js/QuotaCommon.js" as QC
import "js/ProfileRegistry.js" as Registry

KCM.SimpleKCM {
    id: configPage

    property string cfg_provider
    property string cfg_language
    property int cfg_refreshInterval
    property string cfg_displayName
    property string cfg_credentialsPath
    // Kept in kcfg for backward compat; UI removed (B015)
    property int cfg_sessionWeeklyRatio
    property string cfg_paceFormat
    property string cfg_sessionColorMode
    property string cfg_weeklyColorMode
    property string cfg_opencodeSubProvider
    property int cfg_opencodeAccountIndex
    property int cfg_claudeRefreshMinutes
    property bool cfg_showBankedBadge
    property bool cfg_discoverOnLoad
    property bool cfg_multiProfileMode
    property string cfg_profileDisplayNamesJson
    property string cfg_enabledProfilesJson
    property string cfg_visibleWindowsJson
    property string cfg_customProfilesJson
    property int cfg_customProfileNextId
    property bool cfg_cacheResponses
    property string cfg_responseCachePath

    readonly property var providerValues: ["claude", "codex", "grok", "zai", "opencode", "minimax", "kimi"]
    readonly property var providerNames: [
        "Claude (Anthropic)", "Codex (OpenAI)", "Grok (xAI)", "Z.ai (GLM)",
        "OpenCode", "MiniMax", "Kimi"
    ]

    // Per-provider window ids for column visibility (B034).
    // Ids must match parser window ids (QuotaParsers.js), not display labels only.
    // defaultVisible mirrors makeWindow(..., defaultVisible) / parser defaults.
    readonly property var providerWindowCatalog: [
        {
            provider: "claude",
            title: "Claude",
            windows: [
                { id: "5h", label: "5h", defaultVisible: true },
                { id: "weekly", label: "7d", defaultVisible: true },
                { id: "weekly_fable", label: "Fable", defaultVisible: false },
                { id: "weekly_oracle", label: "Oracle", defaultVisible: false },
                { id: "weekly_opus", label: "Opus", defaultVisible: false },
                { id: "weekly_sonnet", label: "Sonnet", defaultVisible: false },
                { id: "weekly_oauth_apps", label: "OAuth apps", defaultVisible: false }
            ]
        },
        {
            provider: "codex",
            title: "Codex",
            windows: [
                { id: "session", label: "session", defaultVisible: true },
                { id: "weekly", label: "weekly", defaultVisible: true },
                { id: "credits", label: "credits $", defaultVisible: false },
                // Codex Spark additional limit id from parser: extra_spk_7d (not "spk/7d")
                { id: "extra_spk_7d", label: "Spark / 7d", defaultVisible: false }
            ]
        },
        {
            provider: "grok",
            title: "Grok",
            windows: [
                { id: "session", label: "session (product %)", defaultVisible: true },
                { id: "weekly", label: "mo ($ allowance)", defaultVisible: true },
                { id: "on_demand", label: "on-demand", defaultVisible: false }
            ]
        },
        {
            provider: "zai",
            title: "Z.ai",
            windows: [
                { id: "session", label: "5h", defaultVisible: true },
                { id: "weekly", label: "mo", defaultVisible: true }
            ]
        },
        {
            provider: "minimax",
            title: "MiniMax",
            windows: [
                { id: "5h/general", label: "5h/general", defaultVisible: true },
                { id: "wk/general", label: "7d/general", defaultVisible: true }
            ]
        },
        {
            provider: "kimi",
            title: "Kimi",
            windows: [
                { id: "session", label: "5h", defaultVisible: true },
                { id: "weekly", label: "7d", defaultVisible: true },
                { id: "total_quota", label: "total quota", defaultVisible: false }
            ]
        }
    ]

    Translations {
        id: trans
        currentLanguage: cfg_language || "system"
    }

    function tr(text) { return trans.tr(text); }

    readonly property var languageValues: [
        "system", "en_US", "hu_HU", "de_DE", "fr_FR", "es_ES",
        "it_IT", "pt_BR", "ru_RU", "pl_PL", "nl_NL", "tr_TR",
        "ja_JP", "ko_KR", "zh_CN", "zh_TW"
    ]

    readonly property var languageNames: [
        tr("System default"), "English", "Magyar", "Deutsch",
        "Français", "Español", "Italiano", "Português (Brasil)",
        "Русский", "Polski", "Nederlands", "Türkçe",
        "日本語", "한국어", "简体中文", "繁體中文"
    ]

    property var accountOptions: ["Account 1", "Account 2", "Account 3"]

    // --- Multi-profile working state (synced to JSON cfg_* ) ---
    property var discoveredProfiles: []
    property string discoverStatus: ""
    property var enabledMap: ({})       // id → bool (true if enabled)
    property var nameMap: ({})          // id → display name override
    // B034: per-provider window visibility overrides
    // shape: { claude: { "5h": true, "weekly": false }, grok: { ... }, ... }
    // empty / missing provider → that provider uses parser defaultVisible
    property var visibleByProvider: ({})
    property var customProfiles: []
    property bool _hydrating: true
    property string customFormError: ""

    readonly property string discoverScript: {
        var u = Qt.resolvedUrl("../scripts/discover-profiles.sh").toString()
        if (u.indexOf("file://") === 0) return u.substring(7)
        return u
    }

    function shellQuote(path) {
        return "'" + String(path).replace(/'/g, "'\\''") + "'"
    }

    function parseJsonSafe(raw, fallback) {
        if (!raw || raw === "") return fallback
        try { return JSON.parse(raw) } catch (e) { return fallback }
    }

    /**
     * Snapshot of kcfg values consumed by Registry.editConfig().
     * Visibility remains local until I004.
     */
    function registryConfigSnapshot() {
        return {
            multiProfileMode: cfg_multiProfileMode,
            provider: cfg_provider,
            opencodeSubProvider: cfg_opencodeSubProvider,
            credentialsPath: cfg_credentialsPath,
            displayName: cfg_displayName,
            discoverOnLoad: cfg_discoverOnLoad,
            enabledProfilesJson: cfg_enabledProfilesJson || "[]",
            profileDisplayNamesJson: cfg_profileDisplayNamesJson || "{}",
            customProfilesJson: cfg_customProfilesJson || "[]",
            customProfileNextId: cfg_customProfileNextId || 0,
            visibleWindowsJson: cfg_visibleWindowsJson || "[]"
        }
    }

    /** Discovered + custom ids for enablement serialisation. */
    function knownProfileList() {
        var list = []
        var seen = {}
        var i
        for (i = 0; i < discoveredProfiles.length; i++) {
            var did = discoveredProfiles[i] && discoveredProfiles[i].id
            if (!did || seen[did]) continue
            seen[did] = true
            list.push({ id: did })
        }
        for (i = 0; i < customProfiles.length; i++) {
            var c = customProfiles[i]
            var cid = (c && c.id) || (c && c.provider ? (c.provider + "-custom-" + i) : "")
            if (!cid || seen[cid]) continue
            seen[cid] = true
            list.push({ id: cid })
        }
        return list
    }

    /** Apply only patch keys returned by Registry.editConfig(). */
    function applyRegistryConfigPatch(patch) {
        if (!patch) return
        if (patch.hasOwnProperty("enabledProfilesJson"))
            cfg_enabledProfilesJson = patch.enabledProfilesJson
        if (patch.hasOwnProperty("profileDisplayNamesJson"))
            cfg_profileDisplayNamesJson = patch.profileDisplayNamesJson
        if (patch.hasOwnProperty("customProfilesJson")) {
            cfg_customProfilesJson = patch.customProfilesJson
            customProfiles = parseJsonSafe(patch.customProfilesJson, []) || []
        }
        if (patch.hasOwnProperty("customProfileNextId"))
            cfg_customProfileNextId = patch.customProfileNextId
    }

    /** Refresh working maps from current cfg strings after a registry edit. */
    function refreshWorkingMapsFromCfg() {
        nameMap = parseJsonSafe(cfg_profileDisplayNamesJson, {}) || {}
        var en = parseJsonSafe(cfg_enabledProfilesJson, [])
        var em = {}
        if (en && en.length) {
            for (var i = 0; i < en.length; i++)
                em[en[i]] = true
        }
        enabledMap = em
    }

    function hydrateFromCfg() {
        _hydrating = true
        // multiProfileMode: treat unset as true in UI only — do not write cfg on open

        nameMap = parseJsonSafe(cfg_profileDisplayNamesJson, {}) || {}
        var en = parseJsonSafe(cfg_enabledProfilesJson, [])
        var em = {}
        if (en && en.length) {
            for (var i = 0; i < en.length; i++)
                em[en[i]] = true
        }
        enabledMap = em

        visibleByProvider = hydrateVisibleByProvider(cfg_visibleWindowsJson)

        customProfiles = parseJsonSafe(cfg_customProfilesJson, []) || []
        _hydrating = false
    }

    /**
     * Load cfg into per-provider maps. Migrates legacy array allowlist into
     * per-provider bool maps so each provider only gets ids it actually uses.
     */
    function hydrateVisibleByProvider(raw) {
        var cfg = QC.parseVisibleWindowsConfig(raw)
        var out = {}
        if (cfg.mode === "defaults")
            return out

        if (cfg.mode === "globalAllowlist") {
            // Legacy: ["5h","weekly"] → apply only ids known for each provider
            var list = cfg.globalAllowlist || []
            for (var pi = 0; pi < providerWindowCatalog.length; pi++) {
                var cat = providerWindowCatalog[pi]
                var pm = {}
                var any = false
                for (var wi = 0; wi < cat.windows.length; wi++) {
                    var wid = cat.windows[wi].id
                    var on = list.indexOf(wid) >= 0
                    pm[wid] = on
                    if (on) any = true
                }
                // Only store if at least one listed id matched this provider
                // (otherwise leave defaults — avoid blanking every provider)
                if (any)
                    out[cat.provider] = pm
            }
            return out
        }

        if (cfg.mode === "globalMap") {
            var gm = cfg.globalMap || {}
            for (var gi = 0; gi < providerWindowCatalog.length; gi++) {
                var gcat = providerWindowCatalog[gi]
                var gpm = {}
                var gany = false
                for (var gwi = 0; gwi < gcat.windows.length; gwi++) {
                    var gid = gcat.windows[gwi].id
                    if (gm.hasOwnProperty(gid)) {
                        gpm[gid] = !!gm[gid]
                        gany = true
                    }
                }
                if (gany)
                    out[gcat.provider] = gpm
            }
            return out
        }

        // perProvider
        var bp = cfg.byProvider || {}
        for (var prov in bp) {
            if (!bp.hasOwnProperty(prov)) continue
            var entry = bp[prov]
            if (!entry || typeof entry !== "object") continue
            var m = {}
            for (var k in entry) {
                if (!entry.hasOwnProperty(k) || k === "__allowlist") continue
                m[k] = !!entry[k]
            }
            // Strict allowlist arrays were expanded with only trues — materialize
            // full catalog so unchecked defaults (hidden extras) stay explicit.
            if (entry.__allowlist) {
                var cat2 = catalogForProvider(prov)
                if (cat2) {
                    for (var ci = 0; ci < cat2.windows.length; ci++) {
                        var cid = cat2.windows[ci].id
                        if (!m.hasOwnProperty(cid))
                            m[cid] = false
                    }
                }
            }
            if (mapKeyCount(m) > 0)
                out[prov] = m
        }
        return out
    }

    function catalogForProvider(provider) {
        for (var i = 0; i < providerWindowCatalog.length; i++) {
            if (providerWindowCatalog[i].provider === provider)
                return providerWindowCatalog[i]
        }
        return null
    }

    function reloadEnabledMapFromCfg() {
        refreshWorkingMapsFromCfg()
    }

    /**
     * Re-project enabledProfilesJson through Registry after discovery expands
     * the known set. No-ops while hydrating or before discovery yields rows
     * (keeps existing allowlist until discovered profiles exist — prior KCM).
     */
    function reprojectEnabledJson() {
        if (_hydrating) return
        // Keep existing allowlist if we haven't discovered yet
        if (!discoveredProfiles.length) return
        var ids = knownProfileList()
        if (!ids.length) return
        var first = ids[0].id
        var on = isProfileEnabled(first)
        var result = Registry.editConfig({
            config: registryConfigSnapshot(),
            knownProfiles: ids,
            event: { type: "setEnabled", profileId: first, enabled: on }
        })
        applyRegistryConfigPatch(result.patch)
        refreshWorkingMapsFromCfg()
    }

    function pushVisibleJson() {
        if (_hydrating) return
        // Serialize only providers that have overrides; empty object → "[]" (defaults)
        // Visible-quota editing stays local until I004.
        var out = {}
        var anyProv = false
        for (var prov in visibleByProvider) {
            if (!visibleByProvider.hasOwnProperty(prov)) continue
            var m = visibleByProvider[prov]
            if (!m || typeof m !== "object") continue
            var pm = {}
            var anyKey = false
            for (var k in m) {
                if (!m.hasOwnProperty(k)) continue
                pm[k] = !!m[k]
                anyKey = true
            }
            if (anyKey) {
                out[prov] = pm
                anyProv = true
            }
        }
        // Keep "[]" for fully-default so older readers stay happy; also "{}" is fine
        cfg_visibleWindowsJson = anyProv ? JSON.stringify(out) : "[]"
    }

    function isProfileEnabled(id) {
        if (!id) return true
        if (mapKeyCount(enabledMap) === 0) return true
        // __none__ sentinel means all off
        if (enabledMap["__none__"] && mapKeyCount(enabledMap) === 1)
            return false
        return !!enabledMap[id]
    }

    function cloneMap(src) {
        var m = {}
        if (!src) return m
        for (var k in src) {
            if (src.hasOwnProperty(k))
                m[k] = src[k]
        }
        return m
    }

    function mapKeyCount(src) {
        var n = 0
        if (!src) return 0
        for (var k in src) {
            if (src.hasOwnProperty(k)) n++
        }
        return n
    }

    function setProfileEnabled(id, on) {
        if (_hydrating || !id) return
        var result = Registry.editConfig({
            config: registryConfigSnapshot(),
            knownProfiles: knownProfileList(),
            event: { type: "setEnabled", profileId: id, enabled: !!on }
        })
        applyRegistryConfigPatch(result.patch)
        refreshWorkingMapsFromCfg()
    }

    function setProfileName(id, name) {
        if (_hydrating || !id) return
        var result = Registry.editConfig({
            config: registryConfigSnapshot(),
            knownProfiles: knownProfileList(),
            event: { type: "setName", profileId: id, name: name }
        })
        applyRegistryConfigPatch(result.patch)
        refreshWorkingMapsFromCfg()
    }

    /**
     * Effective checkbox state for a provider window:
     * override if present, else catalog defaultVisible.
     */
    function isWindowChecked(provider, wid, defaultVisible) {
        var m = visibleByProvider[provider]
        if (m && m.hasOwnProperty(wid))
            return !!m[wid]
        return defaultVisible !== false
    }

    /**
     * Toggle one window for one provider. Materializes a full override map for
     * that provider (defaults + change) so other columns keep their defaults.
     */
    function setWindowVisible(provider, wid, on) {
        var root = cloneMap(visibleByProvider)
        var cat = catalogForProvider(provider)
        var m = root[provider] ? cloneMap(root[provider]) : {}
        // First edit: seed all catalog defaults so unchecking one doesn't rely on
        // sparse override semantics alone (and advanced JSON is self-describing).
        if (mapKeyCount(m) === 0 && cat) {
            for (var i = 0; i < cat.windows.length; i++) {
                var w = cat.windows[i]
                m[w.id] = w.defaultVisible !== false
            }
        }
        m[wid] = !!on
        // If every value matches catalog defaults, drop the provider key (back to defaults)
        if (cat && providerMapMatchesDefaults(m, cat))
            delete root[provider]
        else
            root[provider] = m
        visibleByProvider = root
        pushVisibleJson()
    }

    function providerMapMatchesDefaults(m, cat) {
        if (!cat || !m) return true
        for (var i = 0; i < cat.windows.length; i++) {
            var w = cat.windows[i]
            var def = w.defaultVisible !== false
            if (m.hasOwnProperty(w.id)) {
                if (!!m[w.id] !== def) return false
            }
        }
        // Extra keys not in catalog count as customization
        for (var k in m) {
            if (!m.hasOwnProperty(k)) continue
            var known = false
            for (var j = 0; j < cat.windows.length; j++) {
                if (cat.windows[j].id === k) { known = true; break }
            }
            if (!known) return false
        }
        return true
    }

    function resetWindowDefaults() {
        visibleByProvider = {}
        pushVisibleJson()
    }

    function resetProviderWindowDefaults(provider) {
        var root = cloneMap(visibleByProvider)
        delete root[provider]
        visibleByProvider = root
        pushVisibleJson()
    }

    function runDiscover() {
        discoverStatus = tr("Discovering…")
        discoverSource.connectSource("bash " + shellQuote(discoverScript))
    }

    function applyDiscovered(list) {
        discoveredProfiles = list || []
        // Seed enabledMap keys for new profiles as enabled when map was empty
        // If cfg had an allowlist, rebuild map from it
        var en = parseJsonSafe(cfg_enabledProfilesJson, [])
        if (en && en.length) {
            var m = {}
            for (var i = 0; i < discoveredProfiles.length; i++)
                m[discoveredProfiles[i].id] = en.indexOf(discoveredProfiles[i].id) >= 0
            for (var j = 0; j < en.length; j++)
                m[en[j]] = true
            enabledMap = m
        }
        discoverStatus = discoveredProfiles.length + " " + tr("profile(s) found")
        // Re-serialise through shared registry semantics with the expanded known set
        reprojectEnabledJson()
    }

    function defaultLabelFor(meta) {
        return QC.defaultProfileLabel(meta.provider, meta.profileKey)
    }

    function addCustomProfile() {
        customFormError = ""
        var provider = customProviderCombo.selectedProvider
            || providerValues[customProviderCombo.currentIndex] || "claude"
        var path = (customPathField.text || "").trim()
        var displayName = (customNameField.text || "").trim()
        var credPath = (customCredField.text || "").trim()
        if (!path) {
            customFormError = tr("Path is required")
            return
        }
        if (!provider) {
            customFormError = tr("Provider is required")
            return
        }
        if (_hydrating) return
        var result = Registry.editConfig({
            config: registryConfigSnapshot(),
            knownProfiles: knownProfileList(),
            event: {
                type: "addCustom",
                provider: provider,
                path: path,
                credPath: credPath,
                displayName: displayName
            }
        })
        applyRegistryConfigPatch(result.patch)
        refreshWorkingMapsFromCfg()
        customPathField.text = ""
        customNameField.text = ""
        customCredField.text = ""
        customFormError = ""
    }

    function removeCustomAt(index) {
        if (_hydrating) return
        var entry = customProfiles[index]
        if (!entry) return
        var profileId = entry.id || (entry.provider + "-custom-" + index)
        var result = Registry.editConfig({
            config: registryConfigSnapshot(),
            knownProfiles: knownProfileList(),
            event: { type: "removeCustom", profileId: profileId }
        })
        applyRegistryConfigPatch(result.patch)
        refreshWorkingMapsFromCfg()
    }

    function enableMultiMode(on) {
        cfg_multiProfileMode = !!on
        // Keep legacy field values in cfg while multi is on (ignored by controller);
        // only clear when user explicitly wants a clean multi install via advanced.
        if (on)
            runDiscover()
    }

    Component.onCompleted: {
        hydrateFromCfg()
        // Durable allocator lives in cfg_customProfileNextId (Registry.editConfig).
        if (cfg_multiProfileMode !== false)
            runDiscover()
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
            try {
                if (!trimmed) {
                    if (exitCode && exitCode !== 0) {
                        var snip = String(stderr || "").replace(/\s+/g, " ").trim()
                        discoverStatus = tr("Discovery failed")
                            + (snip ? (": " + snip.substring(0, 120))
                                : (exitCode ? (" (exit " + exitCode + ")") : ""))
                        return
                    }
                    applyDiscovered([])
                    return
                }
                var list = JSON.parse(trimmed)
                if (!Array.isArray(list)) {
                    discoverStatus = tr("Discovery failed") + ": invalid data"
                    return
                }
                applyDiscovered(list)
            } catch (e) {
                var errSnip = String(stderr || "").replace(/\s+/g, " ").trim()
                discoverStatus = tr("Discovery failed")
                    + (errSnip ? (": " + errSnip.substring(0, 120)) : "")
                console.log("configGeneral discovery error", e, stderr)
            }
        }
    }

    // Scrollable form
    ColumnLayout {
        width: parent.width
        spacing: Kirigami.Units.smallSpacing

        Kirigami.FormLayout {
            Layout.fillWidth: true

            QQC2.CheckBox {
                id: multiModeCheck
                Kirigami.FormData.label: tr("Mode:")
                text: tr("Multi-profile dashboard (recommended)")
                checked: cfg_multiProfileMode !== false
                onToggled: enableMultiMode(checked)
            }

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                visible: cfg_multiProfileMode !== false
                text: tr("Discovers Claude, Codex, Grok, and other accounts under your home directory. Enable or rename rows below.")
                opacity: 0.8
                font: Kirigami.Theme.smallFont
            }
        }

        // ========== MULTI-PROFILE ==========
        ColumnLayout {
            Layout.fillWidth: true
            visible: cfg_multiProfileMode !== false
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Separator { Layout.fillWidth: true }

            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading {
                    level: 3
                    text: tr("Profiles")
                    Layout.fillWidth: true
                }
                QQC2.Button {
                    text: tr("Rediscover")
                    icon.name: "view-refresh"
                    onClicked: runDiscover()
                }
            }

            QQC2.Label {
                text: discoverStatus
                opacity: 0.75
                font: Kirigami.Theme.smallFont
            }

            // Header
            RowLayout {
                Layout.fillWidth: true
                visible: discoveredProfiles.length > 0
                QQC2.Label {
                    text: tr("On")
                    font.bold: true
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                }
                QQC2.Label {
                    text: tr("Display name")
                    font.bold: true
                    Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                }
                QQC2.Label {
                    text: tr("Id / path")
                    font.bold: true
                    Layout.fillWidth: true
                }
            }

            Repeater {
                model: discoveredProfiles
                delegate: RowLayout {
                    Layout.fillWidth: true
                    required property var modelData
                    required property int index

                    QQC2.CheckBox {
                        checked: configPage.isProfileEnabled(modelData.id)
                        onToggled: configPage.setProfileEnabled(modelData.id, checked)
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                    }
                    QQC2.TextField {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 10
                        placeholderText: configPage.defaultLabelFor(modelData)
                        text: configPage.nameMap[modelData.id] || ""
                        onEditingFinished: configPage.setProfileName(modelData.id, text)
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        QQC2.Label {
                            text: modelData.id + " · " + modelData.provider
                            font: Kirigami.Theme.smallFont
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        QQC2.Label {
                            text: modelData.credPath || modelData.configDir || ""
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                            elide: Text.ElideMiddle
                            Layout.fillWidth: true
                        }
                    }
                }
            }

            QQC2.Label {
                visible: discoveredProfiles.length === 0 && discoverStatus.indexOf("…") < 0
                text: tr("No profiles discovered. Install a CLI (claude, codex, grok) or add a custom path below.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                opacity: 0.8
            }

            Kirigami.Separator { Layout.fillWidth: true }

            Kirigami.Heading {
                level: 3
                text: tr("Visible quotas (per provider)")
            }

            QQC2.Label {
                text: tr("Toggle columns independently for each provider. Unchanged providers use defaults (primaries on, extras off). OpenCode rows follow the underlying slot (Claude/Codex/…).")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                opacity: 0.8
                font: Kirigami.Theme.smallFont
            }

            Repeater {
                model: configPage.providerWindowCatalog
                delegate: ColumnLayout {
                    id: provBlock
                    required property var modelData
                    readonly property string providerId: modelData.provider
                    readonly property var windowList: modelData.windows
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        Kirigami.Heading {
                            level: 4
                            text: modelData.title
                            Layout.fillWidth: true
                        }
                        QQC2.Button {
                            text: tr("Defaults")
                            flat: true
                            font: Kirigami.Theme.smallFont
                            enabled: !!configPage.visibleByProvider[provBlock.providerId]
                            onClicked: configPage.resetProviderWindowDefaults(provBlock.providerId)
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: provBlock.windowList
                            delegate: QQC2.CheckBox {
                                required property var modelData
                                text: modelData.label
                                // Reference visibleByProvider so the binding re-evaluates on edit
                                checked: {
                                    var _ = configPage.visibleByProvider
                                    return configPage.isWindowChecked(
                                        provBlock.providerId, modelData.id, modelData.defaultVisible)
                                }
                                onToggled: configPage.setWindowVisible(
                                    provBlock.providerId, modelData.id, checked)
                            }
                        }
                    }
                }
            }

            QQC2.Button {
                text: tr("Reset all providers to defaults")
                flat: true
                onClicked: resetWindowDefaults()
            }

            Kirigami.Separator { Layout.fillWidth: true }

            Kirigami.Heading {
                level: 3
                text: tr("Custom profiles")
            }

            QQC2.Label {
                text: tr("Non-standard config directories. If credentials file is left empty, it is inferred (claude → .credentials.json, codex/grok → auth.json, minimax → config.json).")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                opacity: 0.8
                font: Kirigami.Theme.smallFont
            }

            Repeater {
                model: customProfiles
                delegate: RowLayout {
                    Layout.fillWidth: true
                    required property var modelData
                    required property int index
                    QQC2.CheckBox {
                        checked: configPage.isProfileEnabled(modelData.id)
                        onToggled: configPage.setProfileEnabled(modelData.id, checked)
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 2
                    }
                    QQC2.TextField {
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                        text: configPage.nameMap[modelData.id] || modelData.displayName || ""
                        placeholderText: modelData.id || modelData.provider
                        onEditingFinished: configPage.setProfileName(modelData.id, text)
                    }
                    QQC2.Label {
                        text: (modelData.credPath || modelData.path || "")
                        Layout.fillWidth: true
                        elide: Text.ElideMiddle
                        font: Kirigami.Theme.smallFont
                        opacity: 0.8
                    }
                    QQC2.Button {
                        icon.name: "list-remove"
                        onClicked: configPage.removeCustomAt(index)
                    }
                }
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Kirigami.Units.smallSpacing
                rowSpacing: Kirigami.Units.smallSpacing

                QQC2.Label { text: tr("Provider") }
                QQC2.ComboBox {
                    id: customProviderCombo
                    Layout.fillWidth: true
                    model: providerNames
                    // Do NOT name this currentValue — QQC2.ComboBox already has FINAL currentValue (Qt 6)
                    readonly property string selectedProvider: providerValues[currentIndex] || "claude"
                }

                QQC2.Label { text: tr("Config path") }
                QQC2.TextField {
                    id: customPathField
                    Layout.fillWidth: true
                    placeholderText: "/home/me/.claude-work"
                }

                QQC2.Label { text: tr("Display name") }
                QQC2.TextField {
                    id: customNameField
                    Layout.fillWidth: true
                    placeholderText: tr("Optional")
                }

                QQC2.Label { text: tr("Credentials file") }
                QQC2.TextField {
                    id: customCredField
                    Layout.fillWidth: true
                    placeholderText: tr("Optional — auto from provider")
                }
            }

            RowLayout {
                QQC2.Button {
                    text: tr("Add custom profile")
                    icon.name: "list-add"
                    onClicked: addCustomProfile()
                }
                QQC2.Label {
                    text: customFormError
                    color: Kirigami.Theme.negativeTextColor
                    visible: customFormError !== ""
                }
            }
        }

        // ========== LEGACY SINGLE ==========
        ColumnLayout {
            Layout.fillWidth: true
            visible: cfg_multiProfileMode === false
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Separator { Layout.fillWidth: true }

            Kirigami.Heading {
                level: 3
                text: tr("Legacy single profile")
            }

            QQC2.Label {
                text: tr("Only one provider/account is shown. Prefer multi-profile mode unless you need a single fixed credentials path.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                opacity: 0.8
                font: Kirigami.Theme.smallFont
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true

                QQC2.ComboBox {
                    id: providerCombo
                    Kirigami.FormData.label: tr("Provider:")
                    model: providerNames
                    currentIndex: Math.max(0, providerValues.indexOf(cfg_provider))
                    onActivated: index => { cfg_provider = providerValues[index] }
                }

                QQC2.ComboBox {
                    id: opencodeSubProviderCombo
                    Kirigami.FormData.label: tr("OpenCode provider:")
                    visible: cfg_provider === "opencode"
                    readonly property var subProviderValues: ["anthropic", "openai", "zai", "kimi", "gemini"]
                    readonly property var subProviderNames: ["Anthropic (Claude)", "OpenAI", "Z.ai", "Kimi", "Gemini"]
                    model: subProviderNames
                    currentIndex: Math.max(0, subProviderValues.indexOf(cfg_opencodeSubProvider))
                    onActivated: index => { cfg_opencodeSubProvider = subProviderValues[index] }
                }

                QQC2.ComboBox {
                    id: accountCombo
                    Kirigami.FormData.label: tr("Anthropic account:")
                    visible: cfg_provider === "opencode" && cfg_opencodeSubProvider === "anthropic"
                    model: accountOptions
                    currentIndex: cfg_opencodeAccountIndex
                    onActivated: index => { cfg_opencodeAccountIndex = index }
                }

                QQC2.TextField {
                    id: displayNameField
                    Kirigami.FormData.label: tr("Display name:")
                    placeholderText: cfg_provider === "codex" ? "Codex"
                                   : cfg_provider === "grok" ? "Grok"
                                   : cfg_provider === "zai" ? "Z.ai"
                                   : "Claude"
                    text: cfg_displayName
                    onTextChanged: cfg_displayName = text
                }

                QQC2.TextField {
                    id: credentialsPathField
                    Kirigami.FormData.label: tr("Credentials file path:")
                    placeholderText: cfg_provider === "codex" ? "~/.codex/auth.json"
                                   : cfg_provider === "grok" ? "~/.grok/auth.json"
                                   : cfg_provider === "zai" ? "~/.local/share/opencode/auth.json"
                                   : "~/.claude/.credentials.json"
                    text: cfg_credentialsPath
                    onTextChanged: cfg_credentialsPath = text
                }

                QQC2.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: tr("Paths may use ~ or $HOME; they are matched against discovered absolute paths.")
                    font: Kirigami.Theme.smallFont
                    opacity: 0.75
                }
            }
        }

        // ========== SHARED ==========
        Kirigami.Separator { Layout.fillWidth: true }

        Kirigami.Heading {
            level: 3
            text: tr("General")
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true

            QQC2.ComboBox {
                id: languageCombo
                Kirigami.FormData.label: tr("Language:")
                model: languageNames
                currentIndex: Math.max(0, languageValues.indexOf(cfg_language))
                onActivated: index => { cfg_language = languageValues[index] }
            }

            RowLayout {
                Kirigami.FormData.label: tr("Refresh interval:")
                QQC2.SpinBox {
                    id: refreshSpinBox
                    from: 1
                    to: 999
                    stepSize: 1
                    value: cfg_refreshInterval
                    onValueChanged: cfg_refreshInterval = value
                }
                QQC2.Label { text: tr("minutes") }
            }

            RowLayout {
                Kirigami.FormData.label: tr("Claude refresh:")
                QQC2.SpinBox {
                    from: 10
                    to: 120
                    value: Math.max(10, cfg_claudeRefreshMinutes || 15)
                    onValueChanged: cfg_claudeRefreshMinutes = value
                }
                QQC2.Label { text: tr("minutes (10 min floor)") }
            }

            QQC2.ComboBox {
                id: sessionColorCombo
                Kirigami.FormData.label: tr("Session bar color:")
                readonly property var colorModeValues: ["capacity", "efficiency"]
                readonly property var colorModeNames: [
                    tr("Capacity (green = under pace)"),
                    tr("Efficiency (green = on pace)")
                ]
                model: colorModeNames
                currentIndex: Math.max(0, colorModeValues.indexOf(cfg_sessionColorMode))
                onActivated: index => { cfg_sessionColorMode = colorModeValues[index] }
            }

            QQC2.ComboBox {
                id: weeklyColorCombo
                Kirigami.FormData.label: tr("Weekly bar color:")
                readonly property var colorModeValues: ["capacity", "efficiency"]
                readonly property var colorModeNames: [
                    tr("Capacity (green = under pace)"),
                    tr("Efficiency (green = on pace)")
                ]
                model: colorModeNames
                currentIndex: Math.max(0, colorModeValues.indexOf(cfg_weeklyColorMode))
                onActivated: index => { cfg_weeklyColorMode = colorModeValues[index] }
            }

            QQC2.CheckBox {
                Kirigami.FormData.label: tr("Codex banked badge:")
                text: tr("Show ↻N banked resets on Codex rows")
                checked: cfg_showBankedBadge !== false
                onCheckedChanged: cfg_showBankedBadge = checked
            }

            QQC2.CheckBox {
                Kirigami.FormData.label: tr("Discovery:")
                text: tr("Discover profiles on load")
                checked: cfg_discoverOnLoad !== false
                onCheckedChanged: cfg_discoverOnLoad = checked
            }

            QQC2.CheckBox {
                Kirigami.FormData.label: tr("Response cache:")
                text: tr("Save every provider API response to disk")
                checked: cfg_cacheResponses !== false
                onCheckedChanged: cfg_cacheResponses = checked
            }

            QQC2.TextField {
                Kirigami.FormData.label: tr("Cache path:")
                placeholderText: "~/.cache/plasma-claude-usage"
                text: cfg_responseCachePath || ""
                enabled: cfg_cacheResponses !== false
                onTextChanged: cfg_responseCachePath = text
            }
        }

        // Advanced: raw JSON for power users
        Kirigami.Separator { Layout.fillWidth: true }

        QQC2.CheckBox {
            id: showAdvanced
            text: tr("Show advanced JSON (import/export)")
            checked: false
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true
            visible: showAdvanced.checked

            QQC2.TextArea {
                Kirigami.FormData.label: tr("Profile names (JSON):")
                placeholderText: '{"claude-w":"Work","codex-default":"Codex"}'
                text: cfg_profileDisplayNamesJson || "{}"
                onTextChanged: {
                    cfg_profileDisplayNamesJson = text
                    if (!_hydrating) {
                        nameMap = parseJsonSafe(text, {}) || {}
                    }
                }
            }

            QQC2.TextArea {
                Kirigami.FormData.label: tr("Enabled profiles (JSON):")
                placeholderText: '[] = all discovered'
                text: cfg_enabledProfilesJson || "[]"
                onTextChanged: {
                    cfg_enabledProfilesJson = text
                    if (!_hydrating)
                        reloadEnabledMapFromCfg()
                }
            }

            QQC2.TextArea {
                Kirigami.FormData.label: tr("Visible windows (JSON):")
                placeholderText: '{"claude":{"5h":true,"weekly":false},"grok":{"session":true}}  [] = defaults'
                text: cfg_visibleWindowsJson || "[]"
                onTextChanged: {
                    cfg_visibleWindowsJson = text
                    if (!_hydrating)
                        visibleByProvider = hydrateVisibleByProvider(text)
                }
            }

            QQC2.TextArea {
                Kirigami.FormData.label: tr("Custom profiles (JSON):")
                placeholderText: '[{"provider":"claude","path":"/home/me/.claude-custom","displayName":"Custom"}]'
                text: cfg_customProfilesJson || "[]"
                onTextChanged: {
                    cfg_customProfilesJson = text
                    if (!_hydrating)
                        customProfiles = parseJsonSafe(text, []) || []
                }
            }
        }
    }
}
