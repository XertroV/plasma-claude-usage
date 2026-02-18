/*
    SPDX-FileCopyrightText: 2025 izll
    SPDX-License-Identifier: GPL-3.0-or-later
*/

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: configPage

    property string cfg_provider
    property string cfg_language
    property int cfg_refreshInterval
    property string cfg_displayName
    property string cfg_credentialsPath
    property int cfg_sessionWeeklyRatio
    property string cfg_paceFormat
    property string cfg_sessionColorMode
    property string cfg_weeklyColorMode
    property string cfg_opencodeSubProvider
    property int cfg_opencodeAccountIndex

    readonly property var providerValues: ["claude", "codex", "zai", "opencode"]
    readonly property var providerNames: ["Claude (Anthropic)", "Codex (OpenAI)", "Z.ai (GLM)", "OpenCode"]

    // Translation helper
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

    Kirigami.FormLayout {
        QQC2.ComboBox {
            id: providerCombo
            Kirigami.FormData.label: tr("Provider:")

            model: providerNames
            currentIndex: Math.max(0, providerValues.indexOf(cfg_provider))

            onActivated: index => {
                cfg_provider = providerValues[index]
            }
        }

        QQC2.ComboBox {
            id: opencodeSubProviderCombo
            Kirigami.FormData.label: tr("OpenCode provider:")
            visible: cfg_provider === "opencode"

            readonly property var subProviderValues: ["anthropic", "openai", "zai", "kimi", "gemini"]
            readonly property var subProviderNames: ["Anthropic (Claude)", "OpenAI", "Z.ai", "Kimi", "Gemini"]

            model: subProviderNames
            currentIndex: Math.max(0, subProviderValues.indexOf(cfg_opencodeSubProvider))

            onActivated: index => {
                cfg_opencodeSubProvider = subProviderValues[index]
            }
        }

        QQC2.ComboBox {
            id: accountCombo
            Kirigami.FormData.label: tr("Anthropic account:")
            visible: cfg_provider === "opencode" && cfg_opencodeSubProvider === "anthropic"

            model: accountOptions
            currentIndex: cfg_opencodeAccountIndex

            onActivated: index => {
                cfg_opencodeAccountIndex = index
            }
        }

        QQC2.TextField {
            id: displayNameField
            Kirigami.FormData.label: tr("Display name:")
            placeholderText: cfg_provider === "codex" ? "Codex" : cfg_provider === "zai" ? "Z.ai" : "Claude"
            text: cfg_displayName

            onTextChanged: {
                cfg_displayName = text
            }
        }

        QQC2.TextField {
            id: credentialsPathField
            Kirigami.FormData.label: tr("Credentials file path:")
            placeholderText: cfg_provider === "codex" ? "~/.codex/auth.json" : cfg_provider === "zai" ? "~/.local/share/opencode/auth.json" : "~/.claude/.credentials.json"
            text: cfg_credentialsPath

            onTextChanged: {
                cfg_credentialsPath = text
            }
        }

        QQC2.ComboBox {
            id: languageCombo
            Kirigami.FormData.label: tr("Language:")

            model: languageNames
            currentIndex: languageValues.indexOf(cfg_language)

            onActivated: index => {
                cfg_language = languageValues[index]
            }
        }

        RowLayout {
            Kirigami.FormData.label: tr("Refresh interval:")

            QQC2.SpinBox {
                id: refreshSpinBox
                from: 1
                to: 999
                stepSize: 1
                value: cfg_refreshInterval

                onValueChanged: {
                    cfg_refreshInterval = value
                }
            }

            QQC2.Label {
                text: tr("minutes")
            }
        }

        RowLayout {
            Kirigami.FormData.label: tr("Session/weekly ratio (%):")

            QQC2.SpinBox {
                id: ratioSpinBox
                from: 1
                to: 100
                stepSize: 1
                value: cfg_sessionWeeklyRatio

                onValueChanged: {
                    cfg_sessionWeeklyRatio = value
                }
            }

            QQC2.Label {
                text: tr("% weekly per 5hr session")
            }
        }

        QQC2.ComboBox {
            id: paceFormatCombo
            Kirigami.FormData.label: tr("Pace format:")

            readonly property var formatValues: ["percent", "sessions", "hours"]
            readonly property var formatNames: [
                tr("Percentage (73%)"),
                tr("Sessions (3.2 / 8.4)"),
                tr("Hours (16h / 22h)")
            ]

            model: formatNames
            currentIndex: Math.max(0, formatValues.indexOf(cfg_paceFormat))

            onActivated: index => {
                cfg_paceFormat = formatValues[index]
            }
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

            onActivated: index => {
                cfg_sessionColorMode = colorModeValues[index]
            }
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

            onActivated: index => {
                cfg_weeklyColorMode = colorModeValues[index]
            }
        }
    }
}
