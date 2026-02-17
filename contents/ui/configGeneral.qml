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

    readonly property var providerValues: ["claude", "codex", "zai"]
    readonly property var providerNames: ["Claude (Anthropic)", "Codex (OpenAI)", "Z.ai (GLM)"]

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
    }
}
