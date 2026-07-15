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
    // Local mirror so the checkbox stays interactive after hide (panel filters enabled)
    property bool hiddenChecked: false

    signal refreshRequested()
    signal configureRequested()
    signal profileSelected(var profile)
    // B032: hide this account/provider from the panel (persists as enabledProfilesJson)
    signal hiddenToggled(string profileId, bool hidden)

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
        hiddenChecked = !!(p && p.enabled === false)
        visible = true
        raise()
        requestActivate()
    }

    function syncHiddenFromProfile() {
        hiddenChecked = !!(profile && profile.enabled === false)
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
                // Include hidden profiles so they remain selectable for un-hide (B032)
                model: {
                    var names = []
                    var list = profiles || []
                    for (var i = 0; i < list.length; i++) {
                        if (!list[i]) continue
                        var label = list[i].displayName || list[i].id || ("#" + i)
                        if (list[i].enabled === false)
                            label = label + " (" + tr("Hidden") + ")"
                        names.push(label)
                    }
                    return names
                }
                onActivated: function(index) {
                    var list = profiles || []
                    if (index >= 0 && index < list.length && list[index]) {
                        detailWin.profile = list[index]
                        detailWin.syncHiddenFromProfile()
                        detailWin.profileSelected(list[index])
                    }
                }
                Component.onCompleted: syncIndex()
                function syncIndex() {
                    if (!profile || !profiles) return
                    for (var j = 0; j < profiles.length; j++) {
                        if (profiles[j] && profiles[j].id === profile.id) {
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

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

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

            // B032: hide this acct/provider from the panel without opening Configure
            QQC2.CheckBox {
                id: hiddenCheck
                text: tr("Hidden")
                enabled: !!(profile && profile.id)
                Accessible.name: tr("Hidden")
                Accessible.description: tr("Hide this account from the panel")
                // Avoid two-way binding break: push from hiddenChecked, pull on toggle
                Component.onCompleted: checked = detailWin.hiddenChecked
                Connections {
                    target: detailWin
                    function onHiddenCheckedChanged() {
                        if (hiddenCheck.checked !== detailWin.hiddenChecked)
                            hiddenCheck.checked = detailWin.hiddenChecked
                    }
                }
                onToggled: {
                    if (checked === detailWin.hiddenChecked)
                        return
                    detailWin.hiddenChecked = checked
                    if (profile && profile.id)
                        detailWin.hiddenToggled(profile.id, checked)
                }
                QQC2.ToolTip {
                    text: tr("Hide this account from the panel")
                    delay: 400
                }
            }
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
