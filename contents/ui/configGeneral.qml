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
    property bool cfg_cacheResponses
    property string cfg_responseCachePath

    readonly property var providerValues: ["claude", "codex", "grok", "zai", "opencode", "minimax", "kimi"]
    readonly property var providerNames: [
        "Claude (Anthropic)", "Codex (OpenAI)", "Grok (xAI)", "Z.ai (GLM)",
        "OpenCode", "MiniMax", "Kimi"
    ]

    // Common / known window ids for global visibility toggles (B005)
    // Ids must match parser window ids (QuotaParsers.js), not display labels only
    readonly property var knownWindowOptions: [
        { id: "5h", label: "5h (Claude/MiniMax)" },
        { id: "session", label: "session (Grok/Codex/Kimi)" },
        { id: "weekly", label: "weekly (Claude/Codex/Grok)" },
        { id: "weekly_fable", label: "Fable (weekly)" },
        { id: "weekly_oracle", label: "Oracle (weekly)" },
        { id: "credits", label: "credits $" },
        { id: "on_demand", label: "on-demand" },
        { id: "total_quota", label: "total quota (Kimi)" },
        { id: "spk/7d", label: "Spark / 7d" },
        { id: "wk/general", label: "wk/general (MiniMax)" },
        { id: "5h/general", label: "5h/general (MiniMax)" }
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
    property var visibleWindowMap: ({}) // id → bool (checked = force visible)
    property bool useWindowAllowlist: false // false = empty JSON (provider defaults)
    property var customProfiles: []
    property bool _hydrating: true
    property string customFormError: ""
    property int customIdSeq: 1

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

        var vis = parseJsonSafe(cfg_visibleWindowsJson, [])
        var vm = {}
        useWindowAllowlist = !!(vis && vis.length)
        if (useWindowAllowlist) {
            for (var j = 0; j < vis.length; j++)
                vm[vis[j]] = true
        }
        visibleWindowMap = vm

        customProfiles = parseJsonSafe(cfg_customProfilesJson, []) || []
        _hydrating = false
    }

    function reloadEnabledMapFromCfg() {
        var en = parseJsonSafe(cfg_enabledProfilesJson, [])
        var em = {}
        if (en && en.length) {
            for (var i = 0; i < en.length; i++)
                em[en[i]] = true
        }
        enabledMap = em
    }

    function pushEnabledJson() {
        if (_hydrating) return
        // Empty = all discovered enabled
        if (!discoveredProfiles.length) {
            // Keep existing allowlist if we haven't discovered yet
            return
        }
        var allOn = true
        var list = []
        for (var i = 0; i < discoveredProfiles.length; i++) {
            var id = discoveredProfiles[i].id
            var on = enabledMap[id] !== false
            // When enabledMap is empty/object without keys, treat as all on
            if (mapKeyCount(enabledMap) === 0)
                on = true
            else
                on = !!enabledMap[id]
            if (on) list.push(id)
            else allOn = false
        }
        // Always include custom profiles unless explicitly disabled (B003/B009)
        for (var c = 0; c < customProfiles.length; c++) {
            var cid = customProfiles[c].id || (customProfiles[c].provider + "-custom-" + c)
            var customOn = true
            if (mapKeyCount(enabledMap) > 0)
                customOn = enabledMap[cid] !== false
            if (customOn) {
                if (list.indexOf(cid) < 0) list.push(cid)
            } else {
                allOn = false
            }
        }
        var totalSlots = discoveredProfiles.length + customProfiles.length
        if (mapKeyCount(enabledMap) === 0 || (allOn && list.length >= totalSlots))
            cfg_enabledProfilesJson = "[]"
        else if (list.length === 0)
            // Same all-off sentinel as ProfileController.setProfileHidden (B032)
            cfg_enabledProfilesJson = JSON.stringify(["__none__"])
        else
            cfg_enabledProfilesJson = JSON.stringify(list)
    }

    function pushNamesJson() {
        if (_hydrating) return
        var out = {}
        for (var k in nameMap) {
            if (nameMap.hasOwnProperty(k) && nameMap[k])
                out[k] = nameMap[k]
        }
        cfg_profileDisplayNamesJson = JSON.stringify(out)
    }

    function pushVisibleJson() {
        if (_hydrating) return
        if (!useWindowAllowlist) {
            cfg_visibleWindowsJson = "[]"
            return
        }
        var list = []
        for (var k in visibleWindowMap) {
            if (visibleWindowMap.hasOwnProperty(k) && visibleWindowMap[k])
                list.push(k)
        }
        cfg_visibleWindowsJson = JSON.stringify(list)
    }

    function pushCustomJson() {
        if (_hydrating) return
        cfg_customProfilesJson = JSON.stringify(customProfiles || [])
    }

    function isProfileEnabled(id) {
        if (!id) return true
        if (mapKeyCount(enabledMap) === 0) return true
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
        var m = cloneMap(enabledMap)
        // Materialize full map from discovered + custom if empty
        if (mapKeyCount(m) === 0) {
            for (var i = 0; i < discoveredProfiles.length; i++)
                m[discoveredProfiles[i].id] = true
            for (var c = 0; c < customProfiles.length; c++) {
                var cid = customProfiles[c].id || (customProfiles[c].provider + "-custom-" + c)
                m[cid] = true
            }
        }
        m[id] = !!on
        enabledMap = m
        pushEnabledJson()
    }

    function setProfileName(id, name) {
        var m = cloneMap(nameMap)
        if (name && String(name).trim())
            m[id] = String(name).trim()
        else
            delete m[id]
        nameMap = m
        pushNamesJson()
    }

    function setWindowVisible(wid, on) {
        useWindowAllowlist = true
        var m = cloneMap(visibleWindowMap)
        m[wid] = !!on
        visibleWindowMap = m
        pushVisibleJson()
    }

    function resetWindowDefaults() {
        useWindowAllowlist = false
        visibleWindowMap = {}
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
        pushEnabledJson()
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
        var entry = {
            provider: provider,
            path: path
        }
        if (displayName) entry.displayName = displayName
        if (credPath) {
            entry.credPath = credPath
        } else {
            // B009: store resolved default so advanced JSON / controller agree
            entry.credPath = QC.defaultCredPathForProvider(provider, path)
        }
        // Stable unique id — never reuse length after removals
        entry.id = provider + "-custom-" + customIdSeq
        customIdSeq = customIdSeq + 1
        var next = customProfiles.slice()
        next.push(entry)
        customProfiles = next
        // Seed enable map so customs survive partial allowlists
        var em = cloneMap(enabledMap)
        if (mapKeyCount(em) > 0)
            em[entry.id] = true
        enabledMap = em
        pushCustomJson()
        pushEnabledJson()
        if (displayName)
            setProfileName(entry.id, displayName)
        customPathField.text = ""
        customNameField.text = ""
        customCredField.text = ""
        customFormError = ""
    }

    function removeCustomAt(index) {
        var next = customProfiles.slice()
        next.splice(index, 1)
        customProfiles = next
        pushCustomJson()
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
        // Bump custom id sequence past any existing suffix
        for (var i = 0; i < customProfiles.length; i++) {
            var id = String(customProfiles[i].id || "")
            var m = id.match(/-custom-(\d+)$/)
            if (m) {
                var n = parseInt(m[1], 10)
                if (n >= customIdSeq) customIdSeq = n + 1
            }
        }
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
            disconnectSource(sourceName)
            try {
                var list = JSON.parse(stdout)
                applyDiscovered(list)
            } catch (e) {
                discoverStatus = tr("Discovery failed") + (stderr ? (": " + stderr.substring(0, 120)) : "")
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
                text: tr("Visible quotas")
            }

            QQC2.Label {
                text: tr("Empty selection uses each provider’s defaults (session + weekly). Checking any box switches to an allowlist.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                opacity: 0.8
                font: Kirigami.Theme.smallFont
            }

            Flow {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: configPage.knownWindowOptions
                    delegate: QQC2.CheckBox {
                        required property var modelData
                        text: modelData.label
                        checked: configPage.useWindowAllowlist && !!configPage.visibleWindowMap[modelData.id]
                        onToggled: {
                            if (checked) {
                                configPage.setWindowVisible(modelData.id, true)
                            } else {
                                var m = configPage.cloneMap(configPage.visibleWindowMap)
                                delete m[modelData.id]
                                configPage.visibleWindowMap = m
                                // If none left, back to defaults
                                var any = false
                                for (var k in m) {
                                    if (m.hasOwnProperty(k) && m[k]) { any = true; break }
                                }
                                if (!any)
                                    configPage.resetWindowDefaults()
                                else {
                                    configPage.useWindowAllowlist = true
                                    configPage.pushVisibleJson()
                                }
                            }
                        }
                    }
                }
            }

            QQC2.Button {
                text: tr("Reset to provider defaults")
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
                placeholderText: '["5h","weekly","weekly_fable"] empty = defaults'
                text: cfg_visibleWindowsJson || "[]"
                onTextChanged: cfg_visibleWindowsJson = text
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
