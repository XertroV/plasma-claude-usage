import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami
import "js/QuotaCommon.js" as QC

// Floating detail window for one account (paths, all quotas, configure).
Window {
    id: detailWin

    property var profile: null
    property var profiles: []
    property double nowMs: Date.now()
    property string sessionColorMode: "capacity"
    property string weeklyColorMode: "efficiency"
    property var i18n: null

    signal refreshRequested()
    signal configureRequested()
    signal profileSelected(var profile)

    function tr(t) { return i18n ? i18n.tr(t) : t }

    width: Kirigami.Units.gridUnit * 28
    height: Kirigami.Units.gridUnit * 32
    minimumWidth: Kirigami.Units.gridUnit * 22
    minimumHeight: Kirigami.Units.gridUnit * 18
    title: profile
           ? ((profile.displayName || profile.id || "Account") + " — " + tr("details"))
           : tr("Account details")
    color: Kirigami.Theme.backgroundColor
    flags: Qt.Window | Qt.WindowStaysOnTopHint | Qt.WindowCloseButtonHint | Qt.WindowTitleHint | Qt.WindowMinMaxButtonsHint

    function showFor(p) {
        profile = p
        visible = true
        raise()
        requestActivate()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        // Account switcher when multiple profiles
        RowLayout {
            Layout.fillWidth: true
            visible: profiles && profiles.length > 1
            PlasmaComponents.Label {
                text: tr("Account") + ":"
                font.bold: true
            }
            QQC2.ComboBox {
                id: accountCombo
                Layout.fillWidth: true
                model: {
                    var names = []
                    var list = profiles || []
                    for (var i = 0; i < list.length; i++) {
                        if (list[i] && list[i].enabled !== false)
                            names.push(list[i].displayName || list[i].id || ("#" + i))
                    }
                    return names
                }
                onActivated: function(index) {
                    var list = profiles || []
                    var enabled = []
                    for (var i = 0; i < list.length; i++) {
                        if (list[i] && list[i].enabled !== false)
                            enabled.push(list[i])
                    }
                    if (index >= 0 && index < enabled.length) {
                        detailWin.profile = enabled[index]
                        detailWin.profileSelected(enabled[index])
                    }
                }
                Component.onCompleted: syncIndex()
                function syncIndex() {
                    if (!profile || !profiles) return
                    var enabled = []
                    for (var i = 0; i < profiles.length; i++) {
                        if (profiles[i] && profiles[i].enabled !== false)
                            enabled.push(profiles[i])
                    }
                    for (var j = 0; j < enabled.length; j++) {
                        if (enabled[j].id === profile.id) {
                            currentIndex = j
                            return
                        }
                    }
                }
                Connections {
                    target: detailWin
                    function onProfileChanged() { accountCombo.syncIndex() }
                }
            }
        }

        PlasmaComponents.Label {
            Layout.fillWidth: true
            text: {
                var p = profile
                if (!p) return ""
                var line = (p.displayName || p.id || "")
                if (p.planName) line += " · " + p.planName
                if (p.provider) line += " · " + p.provider
                return line
            }
            font.bold: true
            font.pixelSize: Kirigami.Theme.defaultFont.pixelSize * 1.1
            wrapMode: Text.WordWrap
        }

        // Paths
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Kirigami.Units.smallSpacing
            rowSpacing: Kirigami.Units.smallSpacing

            PlasmaComponents.Label {
                text: tr("Config") + ":"
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: (profile && (profile.configDir || profile.credPath)) || "—"
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                elide: Text.ElideMiddle
                wrapMode: Text.WrapAnywhere
            }
            PlasmaComponents.Label {
                text: tr("Auth") + ":"
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            }
            PlasmaComponents.Label {
                Layout.fillWidth: true
                text: (profile && profile.credPath) || "—"
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                elide: Text.ElideMiddle
                wrapMode: Text.WrapAnywhere
            }
        }

        PlasmaComponents.Label {
            visible: profile && profile.bankedResets > 0
            text: "↻ " + profile.bankedResets + " " + tr("banked reset(s)")
            color: Kirigami.Theme.highlightColor
        }

        PlasmaComponents.Label {
            visible: profile && profile.error
            Layout.fillWidth: true
            text: "⚠ " + (profile ? profile.error : "")
            color: Kirigami.Theme.negativeTextColor
            wrapMode: Text.WordWrap
        }

        PlasmaComponents.Label {
            text: tr("Primary")
            font.bold: true
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Repeater {
                model: QC.primaryWindows(profile)
                QuotaRow {
                    required property var modelData
                    Layout.fillWidth: true
                    windowData: modelData
                    nowMs: detailWin.nowMs
                    mode: "data"
                    compact: false
                    colorMode: QC.colorModeForWindow(modelData, sessionColorMode, weeklyColorMode)
                }
            }
            PlasmaComponents.Label {
                visible: QC.primaryWindows(profile).length === 0
                text: profile && profile.loading ? tr("Loading...") : "—"
                color: Kirigami.Theme.disabledTextColor
            }
        }

        PlasmaComponents.Label {
            visible: QC.extraWindows(profile).length > 0
            text: tr("Extra limits")
            font.bold: true
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            visible: QC.extraWindows(profile).length > 0
            Repeater {
                model: QC.extraWindows(profile)
                QuotaRow {
                    required property var modelData
                    Layout.fillWidth: true
                    windowData: modelData
                    nowMs: detailWin.nowMs
                    mode: "data"
                    compact: false
                    colorMode: weeklyColorMode
                }
            }
        }

        Item { Layout.fillHeight: true }

        RowLayout {
            Layout.fillWidth: true
            PlasmaComponents.Button {
                text: tr("Configure…")
                icon.name: "configure"
                onClicked: detailWin.configureRequested()
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.Button {
                text: tr("Refresh")
                icon.name: "view-refresh"
                onClicked: detailWin.refreshRequested()
            }
            PlasmaComponents.Button {
                text: tr("Close")
                onClicked: detailWin.visible = false
            }
        }
    }
}
