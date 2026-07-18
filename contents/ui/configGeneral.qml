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
import org.kde.notification as KNotification
import "js/QuotaCommon.js" as QC
import "js/ProfileRegistry.js" as Registry
import "js/VisibleQuotaConfig.js" as VQ
import "js/QuotaResetEvents.js" as QuotaReset
import "js/TestCelebrationRequests.js" as TestCelebrationRequests

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
    property bool cfg_notifyOnQuotaReset
    property bool cfg_logQuotaResets

    readonly property var providerValues: ["claude", "codex", "grok", "zai", "opencode", "minimax", "kimi"]
    readonly property var providerNames: [
        "Claude (Anthropic)", "Codex (OpenAI)", "Grok (xAI)", "Z.ai (GLM)",
        "OpenCode", "MiniMax", "Kimi"
    ]

    // Visible-quota projection from VQ.configuration() — catalogue/edit/serialize live in the seam.
    property var visibleQuotaConfiguration: ({ providers: [] })

    Translations {
        id: trans
        currentLanguage: cfg_language || "system"
    }

    function tr(text) { return trans.tr(text); }

    /**
     * Preview the reset celebration in both desktop and widget UI without
     * entering the real reset detection or logging paths.
     */
    function sendTestCelebration() {
        try {
            var preview = QuotaReset.formatSettingsPreviewNotification()
            var n = testResetNotificationComponent.createObject(configPage, {
                title: String(preview.title),
                text: String(preview.text),
                iconName: "face-smile-big",
                componentName: "plasma_workspace",
                eventId: "notification"
            })
            if (n)
                n.sendEvent()
        } catch (e) {
            console.log("configGeneral: test celebration notification failed", e)
        }

        try {
            var nowMs = Date.now()
            var request = TestCelebrationRequests.createRequest(nowMs, function() {
                return nowMs.toString(36) + "-" + Math.random().toString(36).substring(2)
            })
            var payload = TestCelebrationRequests.serializeRequest(request)
            var command = "printf %s " + QuotaReset.shellQuote(payload)
                + " | bash " + QuotaReset.shellQuote(testCelebrationBridgeScript) + " write"
            testCelebrationWriter.connectSource(command)
        } catch (e) {
            console.log("configGeneral: test celebration request failed", e)
        }
    }

    // Compatibility for the existing production wiring contract.
    function sendTestQuotaResetNotification() {
        sendTestCelebration()
    }

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
    property var customProfiles: []
    property bool _hydrating: true
    property string customFormError: ""

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

    function parseJsonSafe(raw, fallback) {
        if (!raw || raw === "") return fallback
        try { return JSON.parse(raw) } catch (e) { return fallback }
    }

    function projectVisibleQuotaConfiguration(raw) {
        visibleQuotaConfiguration = VQ.configuration({ persisted: raw })
    }

    function editVisibleQuotaConfiguration(event) {
        if (_hydrating) return
        var result = VQ.configuration({
            persisted: cfg_visibleWindowsJson,
            event: event
        })
        visibleQuotaConfiguration = result
        if (result.changed)
            cfg_visibleWindowsJson = result.persisted
    }

    /**
     * Snapshot of kcfg values consumed by Registry.editConfig().
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

        projectVisibleQuotaConfiguration(cfg_visibleWindowsJson)

        customProfiles = parseJsonSafe(cfg_customProfilesJson, []) || []
        _hydrating = false
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

    function isProfileEnabled(id) {
        if (!id) return true
        if (mapKeyCount(enabledMap) === 0) return true
        return !!enabledMap[id]
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


    function runDiscover() {
        discoverStatus = tr("Discovering…")
        discoverSource.connectSource("bash " + QuotaReset.shellQuote(discoverScript))
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
        id: testCelebrationWriter
        engine: "executable"
        connectedSources: []
        onNewData: function(sourceName, data) {
            var exitCode = data["exit code"] !== undefined
                    ? data["exit code"] : data["exitCode"]
            var exitStatus = data["exit status"] !== undefined
                    ? data["exit status"] : data["exitStatus"]
            var stderr = data["stderr"] || ""
            var error = data["error"] || data["errorString"] || ""
            disconnectSource(sourceName)
            if ((exitCode !== undefined && Number(exitCode) !== 0)
                    || (exitStatus !== undefined && Number(exitStatus) !== 0)
                    || error) {
                console.log("configGeneral: test celebration writer failed",
                            "exit=", exitCode, "status=", exitStatus,
                            "error=", error, "stderr=", stderr)
            }
        }
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
                model: configPage.visibleQuotaConfiguration.providers
                delegate: ColumnLayout {
                    id: provBlock
                    required property var modelData
                    readonly property string providerId: modelData.provider
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
                            enabled: modelData.canReset
                            onClicked: configPage.editVisibleQuotaConfiguration({
                                type: "resetProvider",
                                provider: modelData.provider
                            })
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: provBlock.modelData.windows
                            delegate: QQC2.CheckBox {
                                required property var modelData
                                text: modelData.label
                                checked: modelData.checked
                                onToggled: configPage.editVisibleQuotaConfiguration({
                                    type: "set",
                                    provider: provBlock.providerId,
                                    windowId: modelData.id,
                                    visible: checked
                                })
                            }
                        }
                    }
                }
            }

            QQC2.Button {
                text: tr("Reset all providers to defaults")
                flat: true
                onClicked: configPage.editVisibleQuotaConfiguration({ type: "resetAll" })
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

            QQC2.CheckBox {
                Kirigami.FormData.label: tr("Quota resets:")
                text: tr("Celebrate with a desktop notification when a quota resets")
                checked: cfg_notifyOnQuotaReset !== false
                onCheckedChanged: cfg_notifyOnQuotaReset = checked
            }

            QQC2.Button {
                Kirigami.FormData.label: tr("Test notification:")
                text: tr("Send test celebration")
                icon.name: "notifications"
                // Still allow testing when the toggle is off so users can preview
                // before enabling automatic celebrations.
                onClicked: configPage.sendTestCelebration()
            }

            QQC2.CheckBox {
                Kirigami.FormData.label: tr("Reset log:")
                text: tr("Write structured reset events under the cache root")
                checked: cfg_logQuotaResets !== false
                onCheckedChanged: cfg_logQuotaResets = checked
            }
        }

        Component {
            id: testResetNotificationComponent
            KNotification.Notification {
                autoDelete: true
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
                        configPage.projectVisibleQuotaConfiguration(text)
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
